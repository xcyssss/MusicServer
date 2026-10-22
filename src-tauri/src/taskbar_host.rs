//! Own only our window and a reversible task-list reservation. No Explorer injection.
use std::{ptr::null_mut, sync::Mutex};
use windows_sys::Win32::{
    Foundation::{HWND, POINT, RECT},
    Graphics::Gdi::MapWindowPoints,
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
fn same_horizontal(a: RECT, b: RECT) -> bool {
    a.left == b.left && a.right == b.right
}
struct DpiScope(DPI_AWARENESS_CONTEXT);
impl DpiScope {
    unsafe fn for_window(window: HWND) -> Self {
        Self(SetThreadDpiAwarenessContext(GetWindowDpiAwarenessContext(
            window,
        )))
    }
}
impl Drop for DpiScope {
    fn drop(&mut self) {
        if !self.0.is_null() {
            unsafe {
                SetThreadDpiAwarenessContext(self.0);
            }
        }
    }
}
fn original_bounds(current: RECT, previous: Option<Reservation>) -> RECT {
    previous
        // Explorer can change height without undoing our horizontal reservation.
        // Comparing the whole RECT would subtract the dock width on every poll.
        .filter(|r| same_horizontal(current, r.applied))
        .map(|r| RECT {
            left: r.original.left,
            right: r.original.right,
            ..current
        })
        .unwrap_or(current)
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
    if !scale.is_finite() || scale <= 0.0 || bar.bottom <= bar.top {
        return Err("TASKBAR_BOUNDS_UNAVAILABLE".into());
    }
    if original.left < bar.left || original.right > bar.right {
        return Err("TASKBAR_BOUNDS_UNAVAILABLE".into());
    }
    let available = original.right - original.left;
    let icon_space = (180.0 * scale).round() as i32;
    let minimum = (224.0 * scale).round() as i32;
    let width = ((width.clamp(360, 800) as f64 * scale).round() as i32).min(available - icon_space);
    if width < minimum {
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
    let mut origin = POINT {
        x: r.left,
        y: r.top,
    };
    if !parent.is_null() {
        MapWindowPoints(null_mut(), parent, &mut origin, 1);
    }
    SetWindowPos(
        hwnd,
        HWND_TOP,
        origin.x,
        origin.y,
        r.right - r.left,
        r.bottom - r.top,
        SWP_NOACTIVATE | SWP_NOOWNERZORDER,
    ) != 0
}

pub fn detach() {
    let Ok(mut slot) = HOST.lock() else { return };
    if let Some(r) = slot.take() {
        unsafe {
            let _dpi = DpiScope::for_window(r.bar as HWND);
            let child = r.child as HWND;
            if IsWindow(child) != 0 {
                ShowWindow(child, SW_HIDE);
                SetParent(child, null_mut());
                SetWindowLongPtrW(child, GWL_STYLE, r.style);
            }
            let list = r.list as HWND;
            // Do not overwrite a new layout applied by Explorer or another tool.
            if IsWindow(list) != 0 {
                if let Ok(now) = bounds(list) {
                    if same_horizontal(now, r.applied) {
                        place(list, GetParent(list), original_bounds(now, Some(r)));
                    }
                }
            }
        }
    }
}

pub fn attach(child: HWND, offset: f64, width: u32) -> Result<u32, String> {
    let mut slot = HOST.lock().map_err(|_| "TASKBAR_STATE_LOCKED")?;
    unsafe {
        let bar = FindWindowW(wide("Shell_TrayWnd").as_ptr(), std::ptr::null());
        if bar.is_null() {
            return Err("TASKBAR_NOT_READY".into());
        }
        // Both IPC and the polling thread must measure in the taskbar's context.
        let _dpi = DpiScope::for_window(bar);
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
        let original = original_bounds(current, previous);
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
        Ok(((dock.right - dock.left) as f64 / scale).round() as u32)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn requested_width_shrinks_to_fit_before_rejecting_the_taskbar() {
        for scale in [1.0, 1.25, 1.5, 2.0] {
            let bar = RECT {
                left: 0,
                top: 0,
                right: (650.0_f64 * scale).round() as i32,
                bottom: (40.0_f64 * scale).round() as i32,
            };
            let (list, dock) = layout(bar, bar, scale, 0.0, 800)
                .expect("A 650px task list can fit compact lyrics and 180px of icons");
            assert_eq!(list.right - list.left, (180.0 * scale).round() as i32);
            assert_eq!(dock.right - dock.left, (470.0 * scale).round() as i32);
        }
    }
    #[test]
    fn explorer_height_changes_do_not_reserve_the_same_width_again() {
        let original = RECT {
            left: 100,
            top: 1000,
            right: 1500,
            bottom: 1040,
        };
        let bar = RECT {
            left: 0,
            top: 1000,
            right: 1920,
            bottom: 1040,
        };
        let (applied, _) = layout(original, bar, 1.0, 0.0, 420).unwrap();
        let current = RECT {
            top: 999,
            ..applied
        };
        let source = original_bounds(
            current,
            Some(Reservation {
                original,
                applied,
                ..Reservation::default()
            }),
        );
        let (next, _) = layout(source, bar, 1.0, 0.0, 420).unwrap();
        assert_eq!(
            next.right - next.left,
            applied.right - applied.left,
            "Explorer's vertical relayout must not consume another 420px"
        );
        assert_eq!(next.top, current.top);
    }
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
