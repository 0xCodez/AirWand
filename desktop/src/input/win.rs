//! Windows backend: SendInput for pointer motion (absolute, on the virtual desktop, so
//! Windows' own "Enhance pointer precision" curve is not applied on top of the phone's
//! acceleration) and for high-resolution wheel scrolling; enigo for buttons, keys (printable
//! keys as positional scan codes), text and media keys.

use std::time::{Duration, Instant};

use anyhow::{anyhow, Result};
use enigo::{Button, Direction, Enigo, Key, Keyboard, Mouse, Settings};
use windows::Win32::Foundation::POINT;
use windows::Win32::Graphics::Gdi::{MonitorFromPoint, MONITOR_DEFAULTTONEAREST};
use windows::Win32::UI::HiDpi::{GetDpiForMonitor, MDT_EFFECTIVE_DPI};
use windows::Win32::UI::Input::KeyboardAndMouse::{
    SendInput, INPUT, INPUT_0, INPUT_MOUSE, MOUSEEVENTF_ABSOLUTE, MOUSEEVENTF_HWHEEL, MOUSEEVENTF_MOVE,
    MOUSEEVENTF_VIRTUALDESK, MOUSEEVENTF_WHEEL, MOUSEINPUT, MOUSE_EVENT_FLAGS,
};
use windows::Win32::UI::WindowsAndMessaging::{
    GetCursorPos, GetSystemMetrics, SM_CXVIRTUALSCREEN, SM_CYVIRTUALSCREEN, SM_XVIRTUALSCREEN, SM_YVIRTUALSCREEN,
};

use super::{keymap, modifier_bits, soft, Accum, MouseButton, Rect};

/// Wheel units per protocol pixel. One notch (WHEEL_DELTA = 120) scrolls ~100 px in
/// browsers and modern apps, which accept sub-notch deltas for smooth scrolling.
const WHEEL_UNITS_PER_PX: f64 = 1.2;

/// Within this window we trust our own last injected position over GetCursorPos, because
/// SendInput is processed asynchronously and the cursor may not have caught up yet.
const OWN_POSITION_TTL: Duration = Duration::from_millis(60);

pub struct Backend {
    enigo: Enigo,
    motion: Accum,
    wheel: Accum,
    last_target: Option<((i32, i32), Instant)>,
}

fn send_mouse(dx: i32, dy: i32, data: i32, flags: MOUSE_EVENT_FLAGS) {
    let input = INPUT {
        r#type: INPUT_MOUSE,
        Anonymous: INPUT_0 {
            mi: MOUSEINPUT { dx, dy, mouseData: data as _, dwFlags: flags, time: 0, dwExtraInfo: 0 },
        },
    };
    let sent = unsafe { SendInput(&[input], std::mem::size_of::<INPUT>() as i32) };
    if sent != 1 {
        log::debug!("SendInput rejected a mouse event (blocked by UIPI or the secure desktop?)");
    }
}

fn virtual_screen() -> Rect {
    let (x, y, w, h) = unsafe {
        (
            GetSystemMetrics(SM_XVIRTUALSCREEN),
            GetSystemMetrics(SM_YVIRTUALSCREEN),
            GetSystemMetrics(SM_CXVIRTUALSCREEN),
            GetSystemMetrics(SM_CYVIRTUALSCREEN),
        )
    };
    if w <= 0 || h <= 0 {
        return Rect { x: 0.0, y: 0.0, w: 1920.0, h: 1080.0 };
    }
    Rect { x: x as f64, y: y as f64, w: w as f64, h: h as f64 }
}

fn cursor_pos() -> Option<(i32, i32)> {
    let mut p = POINT::default();
    unsafe { GetCursorPos(&mut p) }.ok()?;
    Some((p.x, p.y))
}

/// Physical pixels per logical point of the monitor under `p` (1.0 when the process is not
/// DPI aware, because Windows then virtualizes coordinates and reports 96 dpi).
fn dpi_scale(p: (i32, i32)) -> f64 {
    let mut dpi_x = 96u32;
    let mut dpi_y = 96u32;
    unsafe {
        let mon = MonitorFromPoint(POINT { x: p.0, y: p.1 }, MONITOR_DEFAULTTONEAREST);
        if GetDpiForMonitor(mon, MDT_EFFECTIVE_DPI, &mut dpi_x, &mut dpi_y).is_err() {
            dpi_x = 96;
        }
    }
    (dpi_x.max(48) as f64) / 96.0
}

/// Moves the pointer to a virtual-desktop pixel with an absolute SendInput event.
fn send_absolute(x: f64, y: f64) {
    let vs = virtual_screen();
    let nx = ((x - vs.x) * 65535.0 / (vs.w - 1.0).max(1.0)).round().clamp(0.0, 65535.0) as i32;
    let ny = ((y - vs.y) * 65535.0 / (vs.h - 1.0).max(1.0)).round().clamp(0.0, 65535.0) as i32;
    send_mouse(nx, ny, 0, MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK);
}

impl Backend {
    pub fn new() -> Result<Self> {
        let enigo = Enigo::new(&Settings::default()).map_err(|e| anyhow!("enigo init failed: {e:?}"))?;
        Ok(Backend { enigo, motion: Accum::default(), wheel: Accum::default(), last_target: None })
    }

    fn current_position(&self) -> Option<(i32, i32)> {
        if let Some((p, at)) = self.last_target {
            if at.elapsed() < OWN_POSITION_TTL {
                return Some(p);
            }
        }
        cursor_pos()
    }

    pub fn move_rel(&mut self, dx: f64, dy: f64) {
        let Some(p) = self.current_position() else { return };
        let scale = dpi_scale(p);
        let (ix, iy) = self.motion.add(dx * scale, dy * scale);
        if ix == 0 && iy == 0 {
            return;
        }
        let vs = virtual_screen();
        let (tx, ty) = vs.clamp((p.0 + ix) as f64, (p.1 + iy) as f64);
        send_absolute(tx, ty);
        self.last_target = Some(((tx as i32, ty as i32), Instant::now()));
    }

    pub fn desktop(&mut self) -> Rect {
        virtual_screen()
    }

    pub fn move_abs(&mut self, x: f64, y: f64) {
        send_absolute(x, y);
        self.last_target = Some(((x.round() as i32, y.round() as i32), Instant::now()));
    }

    pub fn button(&mut self, b: MouseButton, down: bool) {
        let dir = if down { Direction::Press } else { Direction::Release };
        soft(self.enigo.button(enigo_button(b), dir), "mouse button");
    }

    pub fn click(&mut self, b: MouseButton, count: u8) {
        // Windows derives double / triple clicks from timing and distance.
        for _ in 0..count {
            soft(self.enigo.button(enigo_button(b), Direction::Click), "mouse click");
        }
    }

    /// Protocol semantics: +dy reveals content further down (negative WHEEL),
    /// +dx reveals content further right (positive HWHEEL).
    pub fn scroll(&mut self, dx: f64, dy: f64) {
        let (h, v) = self.wheel.add(dx * WHEEL_UNITS_PER_PX, -dy * WHEEL_UNITS_PER_PX);
        if v != 0 {
            send_mouse(0, 0, v, MOUSEEVENTF_WHEEL);
        }
        if h != 0 {
            send_mouse(0, 0, h, MOUSEEVENTF_HWHEEL);
        }
    }

    pub fn key(&mut self, usage: u16, _mask: u8, down: bool) {
        let dir = if down { Direction::Press } else { Direction::Release };
        // Printable keys: positional scan codes (layout independent, like a real keyboard).
        if let Some(scan) = keymap::hid_to_win_scancode(usage) {
            soft(self.enigo.raw(scan, dir), "key");
            return;
        }
        let Some(k) = keymap::hid_to_enigo(usage) else {
            log::debug!("unmapped HID usage 0x{usage:02X}");
            return;
        };
        soft(self.enigo.key(k, dir), "key");
    }

    pub fn modifiers(&mut self, mask: u8, down: bool) {
        if down {
            for bit in modifier_bits(mask) {
                soft(self.enigo.key(keymap::modifier_to_enigo(bit), Direction::Press), "modifier");
            }
        } else {
            for bit in modifier_bits(mask).rev() {
                soft(self.enigo.key(keymap::modifier_to_enigo(bit), Direction::Release), "modifier");
            }
        }
    }

    pub fn text(&mut self, s: &str) {
        soft(self.enigo.text(s), "text");
    }

    pub fn media(&mut self, id: u8) {
        if let Some(k) = media_key(id) {
            soft(self.enigo.key(k, Direction::Click), "media key");
        }
    }

    pub fn reset_accumulators(&mut self) {
        self.motion.reset();
        self.wheel.reset();
        self.last_target = None;
    }
}

fn enigo_button(b: MouseButton) -> Button {
    match b {
        MouseButton::Left => Button::Left,
        MouseButton::Right => Button::Right,
        MouseButton::Middle => Button::Middle,
    }
}

fn media_key(id: u8) -> Option<Key> {
    Some(match id {
        1 => Key::MediaPlayPause,
        2 => Key::MediaNextTrack,
        3 => Key::MediaPrevTrack,
        4 => Key::VolumeUp,
        5 => Key::VolumeDown,
        6 => Key::VolumeMute,
        _ => return None,
    })
}
