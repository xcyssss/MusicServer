// MusicServer 桌面端
// Tauri v2 壳：负责部署/拉起/停止本地 PowerShell runtime，并把窗口指向
// start_musicserver_ui.ps1 提供的完整 Web UI。发布版从安装包 resources 读取
// runtime，再同步到 %LOCALAPPDATA%\MusicServer；不依赖编译机源码路径。

#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::env;
use std::fs;
use std::io::{Read, Write};
use std::net::TcpStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::Mutex;
use std::time::Duration;

use tauri::Manager;

const DEFAULT_UI_PORT: u16 = 8790;
const DEFAULT_API_PORT: u16 = 8787;
const FALLBACK_PAIRS: &[(u16, u16)] = &[(8791, 8788), (8792, 8789)];
const BUILD_MARKER: &str = "musicserver-listening-stats-v2";
const LAUNCHER: &str = "start_musicserver_ui.ps1";
const APP_HOME_ENV: &str = "MUSICSERVER_APP_HOME";

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
    let address: std::net::SocketAddr = match format!("127.0.0.1:{port}").parse() {
        Ok(address) => address,
        Err(_) => return false,
    };
    let mut stream = match TcpStream::connect_timeout(&address, Duration::from_millis(400)) {
        Ok(stream) => stream,
        Err(_) => return false,
    };
    let _ = stream.set_read_timeout(Some(Duration::from_millis(1200)));
    let _ = stream.set_write_timeout(Some(Duration::from_millis(1200)));
    let request =
        format!("GET {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nConnection: close\r\n\r\n");
    if stream.write_all(request.as_bytes()).is_err() {
        return false;
    }
    let mut response = Vec::new();
    let _ = stream.read_to_end(&mut response);
    !response.is_empty() && String::from_utf8_lossy(&response).contains(marker)
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

/// Stable writable application home. Users may override this explicitly for a
/// migrated library, but no compile-time or source-tree path is ever embedded.
fn resolve_app_home() -> PathBuf {
    if let Some(configured) = env::var_os(APP_HOME_ENV) {
        if !configured.is_empty() {
            return PathBuf::from(configured);
        }
    }
    if let Some(local_app_data) = env::var_os("LOCALAPPDATA") {
        return PathBuf::from(local_app_data).join("MusicServer");
    }
    env::temp_dir().join("MusicServer")
}

fn copy_runtime_tree(source: &Path, destination: &Path) -> std::io::Result<()> {
    fs::create_dir_all(destination)?;
    for entry in fs::read_dir(source)? {
        let entry = entry?;
        if entry.file_name() == ".gitkeep" {
            continue;
        }
        let source_path = entry.path();
        let destination_path = destination.join(entry.file_name());
        if entry.file_type()?.is_dir() {
            copy_runtime_tree(&source_path, &destination_path)?;
        } else {
            if let Some(parent) = destination_path.parent() {
                fs::create_dir_all(parent)?;
            }
            fs::copy(&source_path, &destination_path)?;
        }
    }
    Ok(())
}

/// Synchronize only packaged runtime files into the writable APP home. Existing
/// Music/, DailyMix_data/, Navidrome/, logs/ and user files are not deleted.
fn stage_runtime(bundle_runtime: &Path, app_home: &Path) -> std::io::Result<()> {
    copy_runtime_tree(bundle_runtime, app_home)?;
    if !has_launcher(app_home) {
        return Err(std::io::Error::new(
            std::io::ErrorKind::NotFound,
            "staged MusicServer launcher is missing",
        ));
    }
    Ok(())
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

    let mut command = Command::new("powershell.exe");
    command
        .args([
            "-NoProfile",
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
        .current_dir(root)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());

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
        if service_is_current(ui_port, api_port) {
            return Some(endpoint_url(ui_port));
        }

        // Never compete with a listener we cannot identify. A current API is
        // safe to reuse when only its UI port is free.
        if port_open(ui_port) || (port_open(api_port) && !api_is_current(api_port)) {
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

        // 轮询最多 ~30s（launcher 启动 API 需要几秒）
        for _ in 0..60 {
            if service_is_current(ui_port, api_port) {
                return Some(endpoint_url(ui_port));
            }
            std::thread::sleep(Duration::from_millis(500));
        }
        stop_owned_launcher(state);
    }

    None
}

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
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
    Command::new("taskkill")
        .args(["/PID", &pid.to_string(), "/T", "/F"])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .and_then(|mut c| c.wait())
        .map(|_| ())
}

#[cfg(not(windows))]
fn kill_process_tree(pid: u32) -> std::io::Result<()> {
    let _ = pid;
    Ok(())
}
