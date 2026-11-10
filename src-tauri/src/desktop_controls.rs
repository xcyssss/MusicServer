use serde::{Deserialize, Serialize};
use std::sync::Mutex;
use tauri::{Emitter, Manager};

pub const DOCK: &str = "taskbar-player";

#[derive(Clone, Copy, Deserialize, Serialize)]
pub struct Preferences {
    pub tray_only: bool,
    pub taskbar_lyrics: bool,
    #[serde(default = "default_width")]
    pub taskbar_width: u32,
}

fn default_width() -> u32 {
    420
}
impl Default for Preferences {
    fn default() -> Self {
        Self {
            tray_only: false,
            taskbar_lyrics: false,
            taskbar_width: default_width(),
        }
    }
}

#[derive(Clone, Default, Deserialize, Serialize)]
pub struct PlayerSnapshot {
    pub key: String,
    pub title: String,
    pub artist: String,
    pub lyric: String,
    pub playing: bool,
    pub can_play: bool,
    pub can_like: bool,
    pub liked: bool,
    #[serde(default)]
    pub random: bool,
}

#[derive(Default)]
pub struct DesktopControls {
    pub preferences: Mutex<Preferences>,
    snapshot: Mutex<PlayerSnapshot>,
    horizontal: Mutex<f64>,
    host_status: Mutex<Option<HostStatus>>,
}

#[derive(Clone, PartialEq, Serialize)]
pub struct HostStatus {
    enabled: bool,
    width: u32,
    requested_width: u32,
    error: Option<String>,
}

fn report_host(app: &tauri::AppHandle, status: HostStatus) -> HostStatus {
    if let Ok(mut previous) = app.state::<DesktopControls>().host_status.lock() {
        if previous.as_ref() != Some(&status) {
            *previous = Some(status.clone());
            // Publish transitions only, including recovery after Explorer relayout.
            let _ = app.emit_to(super::MAIN_WINDOW, "desktop-player-host", &status);
        }
    }
    status
}

fn main_only(window: &tauri::WebviewWindow) -> Result<(), String> {
    if window.label() == super::MAIN_WINDOW {
        Ok(())
    } else {
        Err("MAIN_WINDOW_REQUIRED".into())
    }
}

pub fn hide_to_tray(app: &tauri::AppHandle) -> Result<(), String> {
    let window = app
        .get_webview_window(super::MAIN_WINDOW)
        .ok_or("MAIN_WINDOW_MISSING")?;
    if app.tray_by_id(super::TRAY_ID).is_none() {
        return Err("TRAY_UNAVAILABLE".into());
    }
    window.hide().map_err(|e| e.to_string())
}

#[tauri::command]
pub fn minimize_to_tray(window: tauri::WebviewWindow) -> Result<(), String> {
    main_only(&window)?;
    hide_to_tray(window.app_handle())
}

pub fn position_dock(app: &tauri::AppHandle) -> Result<HostStatus, String> {
    let state = app.state::<DesktopControls>();
    let preferences = *state.preferences.lock().map_err(|_| "STATE_LOCKED")?;
    if !preferences.taskbar_lyrics {
        return Ok(report_host(
            app,
            HostStatus {
                enabled: false,
                width: 0,
                requested_width: preferences.taskbar_width,
                error: None,
            },
        ));
    }
    let dock = app.get_webview_window(DOCK).ok_or("DOCK_MISSING")?;
    let width = preferences.taskbar_width;
    let offset = *state.horizontal.lock().map_err(|_| "STATE_LOCKED")?;
    #[cfg(windows)]
    {
        let result = super::taskbar_host::attach(
            dock.hwnd().map_err(|e| e.to_string())?.0 as _,
            offset,
            width,
        );
        if result.is_err() {
            let _ = dock.hide();
            super::taskbar_host::detach();
        }
        let status = report_host(
            app,
            HostStatus {
                enabled: true,
                width: result.as_ref().copied().unwrap_or(0),
                requested_width: width,
                error: result.as_ref().err().cloned(),
            },
        );
        result.map(|_| status)
    }
    #[cfg(not(windows))]
    {
        let _ = (dock, offset, width);
        Err("TASKBAR_LAYOUT_UNSUPPORTED".into())
    }
}

// Called only by the background host loop: synchronous WebView construction
// inside a window-event handler can deadlock the Windows event loop.
pub fn recover_dock(app: &tauri::AppHandle) {
    let enabled = app
        .state::<DesktopControls>()
        .preferences
        .lock()
        .map(|p| p.taskbar_lyrics)
        .unwrap_or(false);
    if enabled
        && app.get_webview_window(DOCK).is_none()
        && app.get_webview_window(super::MAIN_WINDOW).is_some()
    {
        #[cfg(windows)]
        let _ = app.run_on_main_thread(super::taskbar_host::detach);
        let _ = tauri::WebviewWindowBuilder::new(
            app,
            DOCK,
            tauri::WebviewUrl::App("taskbar-player.html".into()),
        )
        .title("MusicServer 任务栏歌词")
        .inner_size(420.0, 36.0)
        .visible(false)
        .focused(false)
        .decorations(false)
        .transparent(true)
        .shadow(false)
        .resizable(false)
        .skip_taskbar(true)
        .build();
    }
}

#[tauri::command]
pub fn apply_desktop_preferences(
    window: tauri::WebviewWindow,
    preferences: Preferences,
) -> Result<HostStatus, String> {
    main_only(&window)?;
    if !(360..=800).contains(&preferences.taskbar_width) {
        return Err("INVALID_TASKBAR_WIDTH".into());
    }
    let app = window.app_handle();
    *app.state::<DesktopControls>()
        .preferences
        .lock()
        .map_err(|_| "STATE_LOCKED")? = preferences;
    let status = if preferences.taskbar_lyrics {
        position_dock(app)?
    } else {
        #[cfg(windows)]
        super::taskbar_host::detach();
        if let Some(dock) = app.get_webview_window(DOCK) {
            dock.hide().map_err(|e| e.to_string())?;
        }
        report_host(
            app,
            HostStatus {
                enabled: false,
                width: 0,
                requested_width: preferences.taskbar_width,
                error: None,
            },
        )
    };
    if preferences.tray_only && window.is_minimized().unwrap_or(false) {
        // Missing tray is a safe fallback to ordinary taskbar minimization.
        let _ = hide_to_tray(app);
    }
    Ok(status)
}

#[tauri::command]
pub fn publish_desktop_player(
    window: tauri::WebviewWindow,
    snapshot: PlayerSnapshot,
) -> Result<(), String> {
    main_only(&window)?;
    if snapshot.key.len() > 1024
        || snapshot.title.len() > 2048
        || snapshot.artist.len() > 2048
        || snapshot.lyric.len() > 8192
    {
        return Err("SNAPSHOT_TOO_LARGE".into());
    }
    let app = window.app_handle();
    *app.state::<DesktopControls>()
        .snapshot
        .lock()
        .map_err(|_| "STATE_LOCKED")? = snapshot.clone();
    app.emit_to(DOCK, "desktop-player-state", snapshot)
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub fn desktop_player_snapshot(app: tauri::AppHandle) -> Result<PlayerSnapshot, String> {
    Ok(app
        .state::<DesktopControls>()
        .snapshot
        .lock()
        .map_err(|_| "STATE_LOCKED")?
        .clone())
}

#[derive(Clone, Serialize)]
pub struct PlayerAction {
    pub action: String,
    pub key: String,
}

#[tauri::command]
pub fn desktop_player_action(
    app: tauri::AppHandle,
    action: String,
    key: String,
) -> Result<(), String> {
    if action == "restore" {
        super::restore_main_window(&app);
        return Ok(());
    }
    if ![
        "previous",
        "toggle",
        "next",
        "like",
        "mode",
        "hide",
        "toggle-dock",
    ]
    .contains(&action.as_str())
        || key.len() > 1024
    {
        return Err("INVALID_PLAYER_ACTION".into());
    }
    app.emit_to(
        super::MAIN_WINDOW,
        "desktop-player-action",
        PlayerAction { action, key },
    )
    .map_err(|e| e.to_string())
}

#[tauri::command]
pub fn shift_desktop_player(window: tauri::WebviewWindow, delta: f64) -> Result<(), String> {
    if window.label() != DOCK || !delta.is_finite() {
        return Err("INVALID_DOCK_DRAG".into());
    }
    let app = window.app_handle();
    let state = app.state::<DesktopControls>();
    let mut horizontal = state.horizontal.lock().map_err(|_| "STATE_LOCKED")?;
    *horizontal = (*horizontal + delta.clamp(-0.1, 0.1)).clamp(-0.5, 0.5);
    drop(horizontal);
    position_dock(app).map(|_| ())
}
