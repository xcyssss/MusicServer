//! Own only our window and a reversible task-list reservation. No Explorer injection.
use std::{ptr::null_mut, sync::Mutex};
use windows_sys::Win32::{
    Foundation::{HWND, RECT},
    UI::{HiDpi::*, WindowsAndMessaging::*},
};

#[derive(Clone, Copy, Default)]
struct Reservation {
    child: isize,
    bar: isize,
    list: isize,
    original: RECT,
    applied: RECT,
    style: isize,
}
static HOST: Mutex<Option<Reservation>> = Mutex::new(None);
fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(Some(0)).collect()
}
unsafe fn find(parent: HWND, name: &str) -> HWND {
    FindWindowExW(parent, null_mut(), wide(name).as_ptr(), std::ptr::null())
}
unsafe fn bounds(hwnd: HWND) -> Result<RECT, String> {
    let mut r = RECT::default();
    if GetWindowRect(hwnd, &mut r) == 0 {
        return Err("TASKBAR_BOUNDS_UNAVAILABLE".into());
    }
    Ok(r)
}
fn same(a: RECT, b: RECT) -> bool {
    a.left == b.left && a.top == b.top && a.right == b.right && a.bottom == b.bottom
}
fn layout(
    original: RECT,
    bar: RECT,
    scale: f64,
    offset: f64,
    width: u32,
) -> Result<(RECT, RECT), String> {
    if bar.bottom - bar.top > bar.right - bar.left {
        return Err("TASKBAR_VERTICAL_UNSUPPORTED".into());
    }
    let width = (width.clamp(360, 800) as f64 * scale).round() as i32;
    if original.right - original.left < width + (180.0 * scale) as i32 {
        return Err("TASKBAR_NO_SPACE".into());
    }
    let mut applied = original;
    let mut dock = original;
    if offset < -0.15 {
        applied.left += width;
        dock.right = applied.left;
    } else {
        applied.right -= width;
        dock.left = applied.right;
    }
    dock.top = bar.top + 2;
    dock.bottom = bar.bottom - 2;
    Ok((applied, dock))
}
unsafe fn place(hwnd: HWND, parent: HWND, r: RECT) -> bool {
    let origin = if parent.is_null() {
        RECT::default()
    } else {
        bounds(parent).unwrap_or_default()
    };
    SetWindowPos(
        hwnd,
        HWND_TOP,
        r.left - origin.left,
        r.top - origin.top,
        r.right - r.left,
        r.bottom - r.top,
        SWP_NOACTIVATE | SWP_NOOWNERZORDER,
    ) != 0
}

pub fn detach() {
    let Ok(mut slot) = HOST.lock() else { return };
    if let Some(r) = slot.take() {
        unsafe {
            let child = r.child as HWND;
            if IsWindow(child) != 0 {
                ShowWindow(child, SW_HIDE);
                SetParent(child, null_mut());
                SetWindowLongPtrW(child, GWL_STYLE, r.style);
            }
            let list = r.list as HWND;
            // Do not overwrite a new layout applied by Explorer or another tool.
            if IsWindow(list) != 0 && bounds(list).is_ok_and(|now| same(now, r.applied)) {
                place(list, GetParent(list), r.original);
            }
        }
    }
}

pub fn attach(child: HWND, offset: f64, width: u32) -> Result<(), String> {
    let mut slot = HOST.lock().map_err(|_| "TASKBAR_STATE_LOCKED")?;
    unsafe {
        let bar = FindWindowW(wide("Shell_TrayWnd").as_ptr(), std::ptr::null());
        if bar.is_null() {
            return Err("TASKBAR_NOT_READY".into());
        }
        // An already-running copy owns its reservation. Never shrink its area again.
        let other = FindWindowExW(
            bar,
            null_mut(),
            std::ptr::null(),
            wide("MusicServer 任务栏歌词").as_ptr(),
        );
        if !other.is_null() && other != child {
            return Err("TASKBAR_ALREADY_IN_USE".into());
        }
        let rebar = find(bar, "ReBarWindow32");
        let list = find(rebar, "MSTaskSwWClass");
        if rebar.is_null() || list.is_null() {
            return Err("TASKBAR_LAYOUT_UNSUPPORTED".into());
        }
        if AreDpiAwarenessContextsEqual(
            GetWindowDpiAwarenessContext(child),
            GetWindowDpiAwarenessContext(bar),
        ) == 0
        {
            return Err("TASKBAR_DPI_INCOMPATIBLE".into());
        }
        let br = bounds(bar)?;
        if br.bottom - br.top > br.right - br.left {
            return Err("TASKBAR_VERTICAL_UNSUPPORTED".into());
        }
        let current = bounds(list)?;
        let previous = slot.filter(|r| {
            r.bar == bar as isize && r.list == list as isize && r.child == child as isize
        });
        let original = previous
            .filter(|r| same(current, r.applied))
            .map(|r| r.original)
            .unwrap_or(current);
        let scale = GetDpiForWindow(bar) as f64 / 96.0;
        let (applied, dock) = layout(original, br, scale, offset, width)?;
        let style = previous
            .map(|r| r.style)
            .unwrap_or_else(|| GetWindowLongPtrW(child, GWL_STYLE));
        if GetParent(child) != bar {
            ShowWindow(child, SW_HIDE);
            SetWindowLongPtrW(
                child,
                GWL_STYLE,
                (style & !(WS_POPUP as isize)) | WS_CHILD as isize,
            );
            SetParent(child, bar);
            if GetParent(child) != bar {
                SetWindowLongPtrW(child, GWL_STYLE, style);
                return Err("TASKBAR_ATTACH_FAILED".into());
            }
        }
        // Drag chooses the leading/trailing end, so task buttons always keep one contiguous area.
        if !place(list, GetParent(list), applied) || !place(child, bar, dock) {
            place(list, GetParent(list), original);
            SetParent(child, null_mut());
            SetWindowLongPtrW(child, GWL_STYLE, style);
            return Err("TASKBAR_POSITION_FAILED".into());
        }
        *slot = Some(Reservation {
            child: child as isize,
            bar: bar as isize,
            list: list as isize,
            original,
            applied,
            style,
        });
        ShowWindow(child, SW_SHOWNOACTIVATE);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn reservation_is_inside_taskbar_and_never_overlaps_task_buttons() {
        for scale in [1.0, 1.25, 1.5, 2.0] {
            for offset in [-0.5, 0.0, 0.5] {
                let bar = RECT {
                    left: -2560,
                    top: 1400,
                    right: 0,
                    bottom: 1448,
                };
                let original = RECT {
                    left: -2400,
                    top: 1400,
                    right: -300,
                    bottom: 1448,
                };
                let (list, dock) = layout(original, bar, scale, offset, 420).unwrap();
                assert!(dock.left >= original.left && dock.right <= original.right);
                assert!(dock.top >= bar.top && dock.bottom <= bar.bottom);
                assert!(list.right <= dock.left || list.left >= dock.right);
                assert_eq!(
                    list.right - list.left + dock.right - dock.left,
                    original.right - original.left
                );
            }
        }
    }
    #[test]
    fn crowded_or_vertical_taskbar_is_not_replaced_by_a_floating_window() {
        let narrow = RECT {
            left: 0,
            top: 0,
            right: 300,
            bottom: 40,
        };
        assert!(layout(narrow, narrow, 1.0, 0.0, 420).is_err());
        let vertical = RECT {
            left: 0,
            top: 0,
            right: 40,
            bottom: 1080,
        };
        assert!(layout(vertical, vertical, 1.0, 0.0, 420).is_err());
    }
}
