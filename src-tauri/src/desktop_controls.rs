use serde::{Deserialize, Serialize};
use std::sync::Mutex;
use tauri::{Emitter, Manager};

pub const DOCK: &str = "taskbar-player";

#[derive(Clone, Copy, Default, Deserialize, Serialize)]
pub struct Preferences {
    pub tray_only: bool,
    pub taskbar_lyrics: bool,
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
}

#[derive(Default)]
pub struct DesktopControls {
    pub preferences: Mutex<Preferences>,
    snapshot: Mutex<PlayerSnapshot>,
    horizontal: Mutex<f64>,
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

// Physical coordinates include negative monitor origins; scale only dimensions.
fn dock_bounds(
    x: i32,
    y: i32,
    width: u32,
    height: u32,
    scale: f64,
    offset: f64,
) -> (i32, i32, u32, u32) {
    let inset = (6.0 * scale).round() as i32;
    let w = ((540.0 * scale).round() as u32)
        .min(width.saturating_sub((inset * 2) as u32))
        .max(1);
    let h = ((74.0 * scale).round() as u32).min(height).max(1);
    let room = (width as i32 - w as i32 - inset * 2).max(0);
    let fraction = if offset.is_finite() {
        (offset + 0.5).clamp(0.0, 1.0)
    } else {
        0.5
    };
    (
        x + inset + (f64::from(room) * fraction).round() as i32,
        y + (height as i32 - h as i32 - inset).max(0),
        w,
        h,
    )
}

pub fn position_dock(app: &tauri::AppHandle) -> Result<(), String> {
    let state = app.state::<DesktopControls>();
    if !state
        .preferences
        .lock()
        .map_err(|_| "STATE_LOCKED")?
        .taskbar_lyrics
    {
        return Ok(());
    }
    let main = app
        .get_webview_window(super::MAIN_WINDOW)
        .ok_or("MAIN_WINDOW_MISSING")?;
    let monitor = main
        .current_monitor()
        .map_err(|e| e.to_string())?
        .or(app.primary_monitor().map_err(|e| e.to_string())?)
        .ok_or("MONITOR_MISSING")?;
    let work = monitor.work_area();
    let offset = *state.horizontal.lock().map_err(|_| "STATE_LOCKED")?;
    let (x, y, w, h) = dock_bounds(
        work.position.x,
        work.position.y,
        work.size.width,
        work.size.height,
        monitor.scale_factor(),
        offset,
    );
    let dock = app.get_webview_window(DOCK).ok_or("DOCK_MISSING")?;
    let size = tauri::PhysicalSize::new(w, h);
    let position = tauri::PhysicalPosition::new(x, y);
    if dock.outer_size().ok() != Some(size) {
        dock.set_size(size).map_err(|e| e.to_string())?;
    }
    if dock.outer_position().ok() != Some(position) {
        dock.set_position(position).map_err(|e| e.to_string())?;
    }
    Ok(())
}

#[tauri::command]
pub fn apply_desktop_preferences(
    window: tauri::WebviewWindow,
    preferences: Preferences,
) -> Result<(), String> {
    main_only(&window)?;
    let app = window.app_handle();
    *app.state::<DesktopControls>()
        .preferences
        .lock()
        .map_err(|_| "STATE_LOCKED")? = preferences;
    let dock = app.get_webview_window(DOCK).ok_or("DOCK_MISSING")?;
    if preferences.taskbar_lyrics {
        position_dock(app)?;
        dock.show().map_err(|e| e.to_string())?;
    } else {
        dock.hide().map_err(|e| e.to_string())?;
    }
    if preferences.tray_only && window.is_minimized().unwrap_or(false) {
        // Missing tray is a safe fallback to ordinary taskbar minimization.
        let _ = hide_to_tray(app);
    }
    Ok(())
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
    if !["previous", "toggle", "next", "like", "hide", "toggle-dock"].contains(&action.as_str())
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
    position_dock(app)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn dock_respects_work_area_dpi_negative_monitor_and_drag_bounds() {
        assert_eq!(dock_bounds(0, 0, 1920, 1040, 1.0, 0.0), (690, 960, 540, 74));
        let (x, y, w, h) = dock_bounds(-1920, -200, 1920, 1000, 1.5, -9.0);
        assert!(x >= -1920 && x + w as i32 <= 0 && y >= -200 && y + h as i32 <= 800);
        let (x, y, w, h) = dock_bounds(0, 0, 400, 300, 2.0, 9.0);
        assert!(x >= 0 && x + w as i32 <= 400 && y + h as i32 <= 300);
    }
}
