// MusicServer 桌面端
// Tauri v2 壳：负责部署/拉起/停止本地 PowerShell runtime，并把窗口指向
// start_musicserver_ui.ps1 提供的完整 Web UI。发布版从安装包 resources 读取
// runtime，再同步到独立的 LOCALAPPDATA 目录；不依赖编译机源码路径。

#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::env;
use std::fs;
use std::net::TcpStream;
use std::path::{Path, PathBuf};
use std::process::Child;
use std::sync::Mutex;
use std::time::{Duration, Instant};

mod background_process;
mod runtime_manifest;
mod startup_probe;

use tauri::Manager;

const DEFAULT_UI_PORT: u16 = 8790;
const DEFAULT_API_PORT: u16 = 8787;
const FALLBACK_PAIRS: &[(u16, u16)] = &[(8791, 8788), (8792, 8789)];
const BUILD_MARKER: &str = env!("MUSICSERVER_BUILD_ID");
const LAUNCHER: &str = "start_musicserver_ui.ps1";
const APP_HOME_ENV: &str = "MUSICSERVER_APP_HOME";
const PACKAGED_APP_HOME_DIR: &str = "com.musicserver.desktop";

struct AppState {
    /// 由本应用拉起的 launcher 进程（若有）。
    child: Mutex<Option<Child>>,
}

fn port_open(port: u16) -> bool {
    TcpStream::connect_timeout(
        &format!("127.0.0.1:{port}").parse().unwrap(),
        Duration::from_millis(400),
    )
    .is_ok()
}

fn endpoint_url(port: u16) -> String {
    format!("http://127.0.0.1:{port}/")
}

/// Read a small HTTP response without adding another runtime dependency. This
/// is only used for startup identity checks, not for normal application API
/// traffic.
fn http_contains(port: u16, path: &str, marker: &str) -> bool {
    startup_probe::contains(
        port,
        path,
        marker,
        Instant::now() + Duration::from_millis(1200),
    )
}

fn api_is_current(port: u16) -> bool {
    http_contains(port, "/health", BUILD_MARKER)
}

fn service_is_current(ui_port: u16, api_port: u16) -> bool {
    http_contains(ui_port, "/app.js", BUILD_MARKER) && api_is_current(api_port)
}

fn has_launcher(path: &Path) -> bool {
    path.join(LAUNCHER).is_file()
}

/// Tauri bundle resources preserve their relative `resources/runtime` path.
/// Keep a second candidate for compatibility with alternate Tauri resource
/// layouts and a debug-only working-directory fallback for `tauri dev`.
fn resolve_bundled_runtime(resource_dir: Option<PathBuf>) -> Option<PathBuf> {
    if let Some(resource_dir) = resource_dir {
        let candidates = [
            resource_dir.join("resources").join("runtime"),
            resource_dir.join("runtime"),
        ];
        for candidate in candidates {
            if has_launcher(&candidate) {
                return Some(candidate);
            }
        }
    }

    #[cfg(debug_assertions)]
    {
        if let Ok(cwd) = env::current_dir() {
            let candidates = [
                cwd.join("resources").join("runtime"),
                cwd.join("src-tauri").join("resources").join("runtime"),
                cwd.parent()
                    .map(|p| p.join("src-tauri").join("resources").join("runtime"))
                    .unwrap_or_default(),
            ];
            for candidate in candidates {
                if has_launcher(&candidate) {
                    return Some(candidate);
                }
            }
        }
    }

    None
}

/// Stable writable application home. An explicit environment override wins;
/// otherwise use the identifier-scoped LOCALAPPDATA directory. The executable
/// location is deliberately not consulted, so a checkout can be deleted or
/// replaced without changing persistent state.
fn resolve_app_home() -> PathBuf {
    if let Some(configured) = env::var_os(APP_HOME_ENV) {
        if !configured.is_empty() {
            return PathBuf::from(configured);
        }
    }
    if let Some(local_app_data) = env::var_os("LOCALAPPDATA") {
        return PathBuf::from(local_app_data).join(PACKAGED_APP_HOME_DIR);
    }
    env::temp_dir().join(PACKAGED_APP_HOME_DIR)
}

fn copy_runtime_tree(source: &Path, destination: &Path) -> std::io::Result<()> {
    copy_runtime_tree_into(source, destination, destination)
}

fn copy_runtime_tree_into(
    source: &Path,
    destination: &Path,
    staging_root: &Path,
) -> std::io::Result<()> {
    fs::create_dir_all(destination)?;
    for entry in fs::read_dir(source)? {
        let entry = entry?;
        if entry.file_name() == ".gitkeep" {
            continue;
        }
        let source_path = entry.path();
        let destination_path = destination.join(entry.file_name());
        if entry.file_type()?.is_dir() {
            copy_runtime_tree_into(&source_path, &destination_path, staging_root)?;
        } else {
            if let Some(parent) = destination_path.parent() {
                fs::create_dir_all(parent)?;
            }
            // Same-version launches must not rewrite every packaged file (and
            // retrigger antivirus scans). Compare content, not timestamps: a
            // damaged or same-size upgraded file must still be replaced.
            if !destination_path.is_file()
                || fs::metadata(&source_path)?.len() != fs::metadata(&destination_path)?.len()
                || fs::read(&source_path)? != fs::read(&destination_path)?
            {
                replace_runtime_file(&source_path, &destination_path, staging_root)?;
            }
        }
    }
    Ok(())
}

fn replace_runtime_file(
    source: &Path,
    destination: &Path,
    staging_root: &Path,
) -> std::io::Result<()> {
    static SEQUENCE: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let sequence = SEQUENCE.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let temporary = staging_root.join(format!(
        ".musicserver-update-{}-{sequence}",
        std::process::id()
    ));
    let mut input = fs::File::open(source)?;
    // create_new ensures an existing user file can never be overwritten here.
    let mut output = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&temporary)?;
    let prepared = std::io::copy(&mut input, &mut output).and_then(|_| output.sync_all());
    drop(output);
    let result = prepared.and_then(|_| fs::rename(&temporary, destination));
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

/// Synchronize only packaged runtime files into the writable APP home. Existing
/// Music/, DailyMix_data/, Navidrome/, logs/ and user files are not deleted.
fn stage_runtime(bundle_runtime: &Path, app_home: &Path) -> std::io::Result<()> {
    let files = runtime_manifest::verify(bundle_runtime, BUILD_MARKER)?;
    runtime_manifest::verify_destination(app_home, &files)?;
    copy_runtime_tree(bundle_runtime, app_home)?;
    if !has_launcher(app_home) {
        return Err(std::io::Error::new(
            std::io::ErrorKind::NotFound,
            "staged MusicServer launcher is missing",
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn corrupt_package_never_changes_existing_runtime() {
        let root = env::temp_dir().join(format!("musicserver-corrupt-{}", std::process::id()));
        let source = root.join("source");
        let target = root.join("target");
        runtime_manifest::fixture(&source, BUILD_MARKER);
        fs::create_dir_all(&target).unwrap();
        fs::write(target.join(LAUNCHER), b"old runtime").unwrap();
        fs::write(source.join("web/app.js"), b"corruption").unwrap();
        assert!(stage_runtime(&source, &target).is_err());
        assert_eq!(fs::read(target.join(LAUNCHER)).unwrap(), b"old runtime");
        fs::remove_dir_all(root).unwrap();
    }

    #[cfg(windows)]
    #[test]
    fn locked_destination_preserves_old_bytes_and_removes_temporary_file() {
        use std::os::windows::fs::OpenOptionsExt;
        let root = env::temp_dir().join(format!("musicserver-locked-{}", std::process::id()));
        fs::create_dir_all(&root).unwrap();
        let source = root.join("source");
        let target = root.join("target");
        fs::write(&source, b"new runtime").unwrap();
        fs::write(&target, b"old runtime").unwrap();
        let lock = fs::OpenOptions::new()
            .read(true)
            .share_mode(0)
            .open(&target)
            .unwrap();
        assert!(replace_runtime_file(&source, &target, &root).is_err());
        drop(lock);
        assert_eq!(fs::read(&target).unwrap(), b"old runtime");
        assert_eq!(fs::read_dir(&root).unwrap().count(), 2);
        replace_runtime_file(&source, &target, &root).unwrap();
        assert_eq!(fs::read(&target).unwrap(), b"new runtime");
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn staging_skips_equal_files_and_repairs_same_size_changes() {
        let unique = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root =
            env::temp_dir().join(format!("musicserver-stage-{}-{unique}", std::process::id()));
        let source = root.join("source");
        let target = root.join("target");
        fs::create_dir_all(&source).unwrap();
        fs::write(source.join(LAUNCHER), b"first").unwrap();
        runtime_manifest::fixture(&source, BUILD_MARKER);
        stage_runtime(&source, &target).unwrap();
        let launcher = target.join(LAUNCHER);
        let before = fs::metadata(&launcher).unwrap().modified().unwrap();
        let original_permissions = fs::metadata(&launcher).unwrap().permissions();
        let mut read_only = original_permissions.clone();
        read_only.set_readonly(true);
        fs::set_permissions(&launcher, read_only).unwrap();
        fs::write(target.join("user-data"), b"preserve").unwrap();
        runtime_manifest::fixture(&source, BUILD_MARKER);
        stage_runtime(&source, &target).unwrap();
        fs::set_permissions(&launcher, original_permissions).unwrap();
        assert_eq!(before, fs::metadata(&launcher).unwrap().modified().unwrap());
        fs::write(&launcher, b"wrong").unwrap();
        runtime_manifest::fixture(&source, BUILD_MARKER);
        stage_runtime(&source, &target).unwrap();
        assert_eq!(fs::read(&launcher).unwrap(), b"first");
        fs::write(source.join(LAUNCHER), b"newer").unwrap();
        runtime_manifest::fixture(&source, BUILD_MARKER);
        stage_runtime(&source, &target).unwrap();
        assert_eq!(fs::read(&launcher).unwrap(), b"newer");
        assert_eq!(fs::read(target.join("user-data")).unwrap(), b"preserve");
        fs::remove_dir_all(root).unwrap();
    }
}

/// 拉起指定端口的 launcher 并返回子进程。失败返回 None（调用方会继续尝试）。
fn spawn_launcher(root: &Path, ui_port: u16, api_port: u16) -> Option<Child> {
    let launcher_path = root.join(LAUNCHER);
    if !launcher_path.exists() {
        eprintln!("launcher not found: {}", launcher_path.display());
        return None;
    }
    let ui_prefix = endpoint_url(ui_port);
    let api_prefix = endpoint_url(api_port);
    let sqlite_path = root.join("tools").join("sqlite3.exe");

    let mut command = background_process::command("powershell.exe");
    command
        .args([
            "-NoProfile",
            "-NonInteractive",
            "-WindowStyle",
            "Hidden",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
        ])
        .arg(&launcher_path)
        .arg("-ApiPrefix")
        .arg(&api_prefix)
        .arg("-UiPrefix")
        .arg(&ui_prefix)
        .arg("-NoBrowser")
        .current_dir(root);

    if sqlite_path.is_file() {
        command.env("MUSICSERVER_SQLITE", sqlite_path);
    }

    command.spawn().ok()
}

fn stop_owned_launcher(state: &AppState) {
    let child = state.child.lock().unwrap().take();
    if let Some(child) = child {
        let _ = kill_process_tree(child.id());
    }
}

/// 确保当前版本的 UI/API 可用。若已有当前版本服务则直接复用，不触碰
/// runtime 文件；只有需要启动自己的服务树时才把 bundle runtime 同步到
/// APP home。旧版服务占用默认端口时使用隔离端口。
fn ensure_ui_ready(bundle_runtime: &Path, app_home: &Path, state: &AppState) -> Option<String> {
    let mut pairs = vec![(DEFAULT_UI_PORT, DEFAULT_API_PORT)];
    pairs.extend_from_slice(FALLBACK_PAIRS);
    let mut runtime_staged = false;

    for (ui_port, api_port) in pairs {
        // Probe ownership once. A closed UI needs no HTTP identity request;
        // repeated closed-port connects on Windows each consume their timeout.
        let (ui_open, api_open) = std::thread::scope(|scope| {
            let ui = scope.spawn(|| port_open(ui_port));
            let api = port_open(api_port);
            (ui.join().unwrap_or(false), api)
        });
        if ui_open {
            if api_open && service_is_current(ui_port, api_port) {
                return Some(endpoint_url(ui_port));
            }
            continue;
        }

        // Never compete with a listener we cannot identify. A current API is
        // safe to reuse when only its UI port is free.
        if api_open && !api_is_current(api_port) {
            continue;
        }

        if !runtime_staged {
            if let Err(error) = stage_runtime(bundle_runtime, app_home) {
                eprintln!("failed to stage MusicServer runtime: {error}");
                return None;
            }
            runtime_staged = true;
        }

        let mut guard = state.child.lock().unwrap();
        if guard.is_none() {
            *guard = spawn_launcher(app_home, ui_port, api_port);
        }
        drop(guard);

        // Include network time in the per-pair budget, not just sleep time.
        let deadline = Instant::now() + Duration::from_secs(30);
        while Instant::now() < deadline {
            let probe_deadline = deadline.min(Instant::now() + Duration::from_millis(1200));
            if startup_probe::contains(ui_port, "/app.js", BUILD_MARKER, probe_deadline)
                && startup_probe::contains(
                    api_port,
                    "/health",
                    BUILD_MARKER,
                    deadline.min(Instant::now() + Duration::from_millis(1200)),
                )
            {
                return Some(endpoint_url(ui_port));
            }
            std::thread::sleep(
                Duration::from_millis(500).min(deadline.saturating_duration_since(Instant::now())),
            );
        }
        stop_owned_launcher(state);
    }

    None
}

#[tauri::command]
fn open_folder(path: String) -> Result<(), String> {
    let p = std::path::Path::new(&path);
    if !p.is_dir() {
        return Err(format!("Path is not a directory: {}", path));
    }
    #[cfg(windows)]
    {
        std::process::Command::new("explorer")
            .arg(&path)
            .spawn()
            .map_err(|e| format!("Failed to open folder: {e}"))?;
    }
    #[cfg(not(windows))]
    {
        return Err("open_folder is only supported on Windows".to_string());
    }
    Ok(())
}

#[tauri::command]
async fn pick_folder(app: tauri::AppHandle) -> Result<Option<String>, String> {
    use tauri_plugin_dialog::DialogExt;
    let (tx, rx) = std::sync::mpsc::channel();
    app.dialog()
        .file()
        .set_title("选择音乐文件夹")
        .pick_folder(move |result| {
            let _ = tx.send(result);
        });
    let result = rx
        .recv()
        .map_err(|e| format!("Dialog channel error: {e}"))?;
    match result {
        Some(path) => Ok(Some(path.to_string())),
        None => Ok(None),
    }
}

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_dialog::init())
        .invoke_handler(tauri::generate_handler![open_folder, pick_folder])
        .manage(AppState {
            child: Mutex::new(None),
        })
        .setup(|app| {
            let state: tauri::State<AppState> = app.state();
            let resource_dir = app.path().resource_dir().ok();
            let bundle_runtime = resolve_bundled_runtime(resource_dir);
            let app_home = resolve_app_home();

            let ui_url = bundle_runtime
                .as_deref()
                .and_then(|runtime| ensure_ui_ready(runtime, &app_home, &state));

            if let Some(window) = app.get_webview_window("main") {
                if let Some(ui_url) = ui_url {
                    let _ = window.navigate(
                        ui_url.parse::<tauri::Url>().expect("invalid ui url"),
                    );
                } else {
                    let app_home_text = app_home.to_string_lossy().replace('\\', "\\\\");
                    let _ = window.eval(&format!(
                        "document.body.innerHTML='<div style=\"font-family:system-ui;display:flex;align-items:center;justify-content:center;height:100vh;background:#0b0f14;color:#f4f7fb;text-align:center;padding:32px;\">MusicServer runtime 启动失败。<br><small style=\"opacity:.65\">APP home: {app_home_text}</small></div>';"
                    ));
                }
            }
            Ok(())
        })
        .on_window_event(|window, event| {
            // 主窗口关闭时，停掉本应用拉起的 launcher（其 finally 会停掉 API）。
            if let tauri::WindowEvent::Destroyed = event {
                let app = window.app_handle();
                let state: tauri::State<AppState> = app.state();
                let mut guard = state.child.lock().unwrap();
                if let Some(child) = guard.take() {
                    let _ = kill_process_tree(child.id());
                }
            }
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

#[cfg(windows)]
fn kill_process_tree(pid: u32) -> std::io::Result<()> {
    background_process::command("taskkill")
        .args(["/PID", &pid.to_string(), "/T", "/F"])
        .spawn()
        .and_then(|mut c| c.wait())
        .map(|_| ())
}

#[cfg(not(windows))]
fn kill_process_tree(pid: u32) -> std::io::Result<()> {
    let _ = pid;
    Ok(())
}
