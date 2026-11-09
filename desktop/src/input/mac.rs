//! macOS backend: Quartz CGEvents for pointer, scroll and keys; enigo for buttons
//! (it tracks the click-state field for double/triple clicks), text and media keys.
//!
//! Posting events requires the Accessibility permission (System Settings → Privacy &
//! Security → Accessibility).

use std::time::{Duration, Instant};

use anyhow::{anyhow, Result};
use core_foundation::base::TCFType;
use core_foundation::boolean::CFBoolean;
use core_foundation::dictionary::{CFDictionary, CFDictionaryRef};
use core_foundation::string::{CFString, CFStringRef};
use core_graphics::display::CGDisplay;
use core_graphics::event::{
    CGEvent, CGEventFlags, CGEventTapLocation, CGEventType, CGMouseButton, ScrollEventUnit,
};
use core_graphics::event_source::{CGEventSource, CGEventSourceStateID};
use core_graphics::geometry::CGPoint;
use enigo::{Button, Direction, Enigo, Key, Keyboard, Mouse, Settings};

use super::{keymap, modifier_bits, soft, Accum, MouseButton, Rect};
use crate::protocol::mods;

#[link(name = "ApplicationServices", kind = "framework")]
extern "C" {
    fn AXIsProcessTrusted() -> u8;
    fn AXIsProcessTrustedWithOptions(options: CFDictionaryRef) -> u8;
    static kAXTrustedCheckOptionPrompt: CFStringRef;
}

/// `AXIsProcessTrustedWithOptions({kAXTrustedCheckOptionPrompt: true})` shows the system
/// "Orbit would like to control this computer" prompt the first time.
pub fn accessibility_trusted(prompt: bool) -> bool {
    unsafe {
        if !prompt {
            return AXIsProcessTrusted() != 0;
        }
        let key = CFString::wrap_under_get_rule(kAXTrustedCheckOptionPrompt);
        let value = CFBoolean::true_value();
        let options = CFDictionary::from_CFType_pairs(&[(key, value)]);
        AXIsProcessTrustedWithOptions(options.as_concrete_TypeRef()) != 0
    }
}

// CGEventField numbers (CGEventTypes.h).
const FIELD_MOUSE_DELTA_X: u32 = 4;
const FIELD_MOUSE_DELTA_Y: u32 = 5;

const DISPLAY_REFRESH: Duration = Duration::from_secs(2);

fn source() -> Option<CGEventSource> {
    CGEventSource::new(CGEventSourceStateID::CombinedSessionState).ok()
}

fn flags_for(mask: u8) -> CGEventFlags {
    let mut f = CGEventFlags::empty();
    if mask & mods::SHIFT != 0 {
        f |= CGEventFlags::CGEventFlagShift;
    }
    if mask & mods::CTRL != 0 {
        f |= CGEventFlags::CGEventFlagControl;
    }
    if mask & mods::ALT != 0 {
        f |= CGEventFlags::CGEventFlagAlternate;
    }
    if mask & mods::META != 0 {
        f |= CGEventFlags::CGEventFlagCommand;
    }
    f
}

pub struct Backend {
    enigo: Enigo,
    held: [bool; 3],
    scroll: Accum,
    displays: Vec<Rect>,
    displays_at: Option<Instant>,
}

impl Backend {
    pub fn new() -> Result<Self> {
        let mut settings = Settings::default();
        // enigo sleeps `mac_delay` ms after events; keep latency low.
        settings.mac_delay = 2;
        let enigo = Enigo::new(&settings).map_err(|e| anyhow!("enigo init failed: {e:?}"))?;
        Ok(Backend { enigo, held: [false; 3], scroll: Accum::default(), displays: Vec::new(), displays_at: None })
    }

    fn refresh_displays(&mut self) {
        let fresh = self.displays_at.map_or(false, |t| t.elapsed() < DISPLAY_REFRESH);
        if fresh && !self.displays.is_empty() {
            return;
        }
        let mut rects = Vec::new();
        if let Ok(ids) = CGDisplay::active_displays() {
            for id in ids {
                let b = CGDisplay::new(id).bounds();
                rects.push(Rect { x: b.origin.x, y: b.origin.y, w: b.size.width, h: b.size.height });
            }
        }
        if rects.is_empty() {
            let b = CGDisplay::main().bounds();
            rects.push(Rect { x: b.origin.x, y: b.origin.y, w: b.size.width, h: b.size.height });
        }
        self.displays = rects;
        self.displays_at = Some(Instant::now());
    }

    fn cursor(&self) -> Option<(f64, f64)> {
        let ev = CGEvent::new(source()?).ok()?;
        let p = ev.location();
        Some((p.x, p.y))
    }

    /// Keeps the pointer on a real display: a target inside any display is fine, otherwise it
    /// is clamped to the display the pointer is currently on (so it stops at outer edges).
    fn clamp_to_displays(&mut self, from: (f64, f64), to: (f64, f64)) -> (f64, f64) {
        self.refresh_displays();
        if self.displays.iter().any(|r| r.contains(to.0, to.1)) {
            return to;
        }
        let base = self
            .displays
            .iter()
            .find(|r| r.contains(from.0, from.1))
            .or_else(|| self.displays.first())
            .copied();
        match base {
            Some(r) => r.clamp(to.0, to.1),
            None => to,
        }
    }

    fn post_pointer(&self, x: f64, y: f64, dx: f64, dy: f64) {
        let Some(src) = source() else { return };
        let (ty, button) = if self.held[0] {
            (CGEventType::LeftMouseDragged, CGMouseButton::Left)
        } else if self.held[1] {
            (CGEventType::RightMouseDragged, CGMouseButton::Right)
        } else if self.held[2] {
            (CGEventType::OtherMouseDragged, CGMouseButton::Center)
        } else {
            (CGEventType::MouseMoved, CGMouseButton::Left)
        };
        if let Ok(ev) = CGEvent::new_mouse_event(src, ty, CGPoint::new(x, y), button) {
            ev.set_integer_value_field(FIELD_MOUSE_DELTA_X, dx.round() as i64);
            ev.set_integer_value_field(FIELD_MOUSE_DELTA_Y, dy.round() as i64);
            ev.post(CGEventTapLocation::HID);
        }
    }

    pub fn move_rel(&mut self, dx: f64, dy: f64) {
        let Some(from) = self.cursor() else { return };
        let to = self.clamp_to_displays(from, (from.0 + dx, from.1 + dy));
        self.post_pointer(to.0, to.1, dx, dy);
    }

    /// Bounding box of all displays, in global display points.
    pub fn desktop(&mut self) -> Rect {
        self.refresh_displays();
        let mut it = self.displays.iter();
        let Some(first) = it.next() else {
            return Rect { x: 0.0, y: 0.0, w: 1440.0, h: 900.0 };
        };
        let (mut x0, mut y0, mut x1, mut y1) = (first.x, first.y, first.x + first.w, first.y + first.h);
        for r in it {
            x0 = x0.min(r.x);
            y0 = y0.min(r.y);
            x1 = x1.max(r.x + r.w);
            y1 = y1.max(r.y + r.h);
        }
        Rect { x: x0, y: y0, w: x1 - x0, h: y1 - y0 }
    }

    pub fn move_abs(&mut self, x: f64, y: f64) {
        let from = self.cursor().unwrap_or((x, y));
        let to = self.clamp_to_displays(from, (x, y));
        self.post_pointer(to.0, to.1, to.0 - from.0, to.1 - from.1);
    }

    pub fn button(&mut self, b: MouseButton, down: bool) {
        let dir = if down { Direction::Press } else { Direction::Release };
        soft(self.enigo.button(enigo_button(b), dir), "mouse button");
        self.held[b.index()] = down;
    }

    pub fn click(&mut self, b: MouseButton, count: u8) {
        // enigo sets kCGMouseEventClickState from its own press timing, so consecutive
        // clicks within the system double-click interval become double / triple clicks.
        for _ in 0..count {
            soft(self.enigo.button(enigo_button(b), Direction::Click), "mouse click");
        }
    }

    /// Protocol semantics: +dy reveals content further down, +dx further right.
    /// Quartz wheel1 (vertical) and wheel2 (horizontal) are positive for up / left.
    pub fn scroll(&mut self, dx: f64, dy: f64) {
        let (ix, iy) = self.scroll.add(dx, dy);
        if ix == 0 && iy == 0 {
            return;
        }
        let Some(src) = source() else { return };
        if let Ok(ev) = CGEvent::new_scroll_event(src, ScrollEventUnit::PIXEL, 2, -iy, -ix, 0) {
            ev.post(CGEventTapLocation::HID);
        }
    }

    fn post_key(&self, keycode: u16, down: bool, flags: CGEventFlags) {
        let Some(src) = source() else { return };
        if let Ok(ev) = CGEvent::new_keyboard_event(src, keycode, down) {
            ev.set_flags(flags);
            ev.post(CGEventTapLocation::HID);
        }
    }

    pub fn key(&mut self, usage: u16, mask: u8, down: bool) {
        let Some(code) = keymap::hid_to_mac_keycode(usage) else {
            log::debug!("unmapped HID usage 0x{usage:02X}");
            return;
        };
        let mut flags = flags_for(mask);
        match keymap::mac_key_class(usage) {
            keymap::MacKeyClass::Arrow => {
                flags |= CGEventFlags::CGEventFlagNumericPad | CGEventFlags::CGEventFlagSecondaryFn;
            }
            keymap::MacKeyClass::Function => flags |= CGEventFlags::CGEventFlagSecondaryFn,
            keymap::MacKeyClass::Plain => {}
        }
        if down {
            if let Some(bit) = keymap::hid_modifier_bit(usage) {
                flags |= flags_for(bit);
            }
        }
        self.post_key(code, down, flags);
    }

    /// Presses (in order) or releases (in reverse) the modifier keys of `mask`; each event
    /// carries the flags of the modifiers that are down after it.
    pub fn modifiers(&mut self, mask: u8, down: bool) {
        if down {
            let mut acc = 0u8;
            for bit in modifier_bits(mask) {
                acc |= bit;
                self.post_key(keymap::modifier_to_mac_keycode(bit), true, flags_for(acc));
            }
        } else {
            let mut acc = mask;
            for bit in modifier_bits(mask).rev() {
                acc &= !bit;
                self.post_key(keymap::modifier_to_mac_keycode(bit), false, flags_for(acc));
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
        self.scroll.reset();
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
