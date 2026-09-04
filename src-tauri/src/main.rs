// MusicServer 桌面端
// Tauri v2 壳：负责拉起/停止本地 PowerShell 后端服务，并把窗口指向
// start_musicserver_ui.ps1 提供的完整 Web UI。正常情况下使用 8790/8787；
// 如果旧版服务占用了默认端口，则使用隔离端口，避免桌面 APP 静默加载旧资源。

#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::io::{Read, Write};
use std::net::TcpStream;
use std::process::{Child, Command, Stdio};
use std::sync::Mutex;
use std::time::Duration;

use tauri::Manager;

const DEFAULT_UI_PORT: u16 = 8790;
const DEFAULT_API_PORT: u16 = 8787;
const FALLBACK_PAIRS: &[(u16, u16)] = &[(8791, 8788), (8792, 8789)];
const BUILD_MARKER: &str = "musicserver-listening-stats-v2";

/// 启动器脚本（与桌面快捷方式一致，但 -NoBrowser 避免弹浏览器窗口；
/// launcher 的 -NoBrowser 分支不会自动停机，由本应用退出时主动停止）。
const LAUNCHER: &str = "start_musicserver_ui.ps1";

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

/// 拉起指定端口的 launcher 并返回子进程。失败返回 None（调用方会继续尝试）。
fn spawn_launcher(root: &str, ui_port: u16, api_port: u16) -> Option<Child> {
    let launcher_path = std::path::Path::new(root).join(LAUNCHER);
    if !launcher_path.exists() {
        eprintln!("launcher not found: {}", launcher_path.display());
        return None;
    }
    let ui_prefix = endpoint_url(ui_port);
    let api_prefix = endpoint_url(api_port);
    // powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass
    // -File <root>\start_musicserver_ui.ps1 -ApiPrefix <api> -UiPrefix <ui> -NoBrowser
    let child = Command::new("powershell.exe")
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
        .stderr(Stdio::null())
        .spawn()
        .ok();
    child
}

fn stop_owned_launcher(state: &AppState) {
    let child = state.child.lock().unwrap().take();
    if let Some(child) = child {
        let _ = kill_process_tree(child.id());
    }
}

/// 确保当前版本的 UI/API 可用。旧版服务只要缺少 build marker，就不会被
/// 静默复用；桌面 APP 会在隔离端口拉起自己的服务树。
fn ensure_ui_ready(root: &str, state: &AppState) -> Option<String> {
    let mut pairs = vec![(DEFAULT_UI_PORT, DEFAULT_API_PORT)];
    pairs.extend_from_slice(FALLBACK_PAIRS);

    for (ui_port, api_port) in pairs {
        if service_is_current(ui_port, api_port) {
            return Some(endpoint_url(ui_port));
        }

        // Never compete with a listener we cannot identify. A current API is
        // safe to reuse when only its UI port is free.
        if port_open(ui_port) || (port_open(api_port) && !api_is_current(api_port)) {
            continue;
        }

        let mut guard = state.child.lock().unwrap();
        if guard.is_none() {
            *guard = spawn_launcher(root, ui_port, api_port);
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
    // 项目根：src-tauri 的上一级（E:\Project\MusicServer）
    let manifest_dir = env!("CARGO_MANIFEST_DIR");
    let root = std::path::Path::new(manifest_dir)
        .parent()
        .and_then(|p| p.to_str())
        .unwrap_or(".")
        .to_string();

    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .manage(AppState {
            child: Mutex::new(None),
        })
        .setup(move |app| {
            let state: tauri::State<AppState> = app.state();

            // 先拉起/确认服务，再让主窗口跳转到 UI。首次启动可能稍慢，
            // 窗口初始内容用本地 loading 页避免白屏。
            let ui_url = ensure_ui_ready(&root, &state);

            if let Some(window) = app.get_webview_window("main") {
                if let Some(ui_url) = ui_url {
                    let _ = window.navigate(
                        ui_url.parse::<tauri::Url>().expect("invalid ui url"),
                    );
                } else {
                    let _ = window.eval(&format!(
                        "document.body.innerHTML='<div style=\"font-family:system-ui;display:flex;align-items:center;justify-content:center;height:100vh;background:#0b0f14;color:#f4f7fb;\">MusicServer 服务启动超时，请手动运行 start_musicserver_ui.bat</div>';"
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
                    // 结束整个 launcher 进程树（powershell 会派生 music_api）
                    let _ = kill_process_tree(child.id());
                }
            }
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

#[cfg(windows)]
fn kill_process_tree(pid: u32) -> std::io::Result<()> {
    // taskkill /PID <pid> /T /F 结束进程树
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
    // 非 Windows 直接杀进程（本应用面向 Windows，保留占位）
    let _ = pid;
    Ok(())
}
