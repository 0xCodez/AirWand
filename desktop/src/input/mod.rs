//! Input injection: turns protocol messages into OS mouse / keyboard events.
//!
//! `Injector` holds the platform-neutral logic (held-state tracking for safety release,
//! gesture tables, AIM mapping + 1€ smoothing, text handling). A platform `Backend`
//! (`mac.rs`, `win.rs`, `generic.rs`) does the actual event posting:
//!
//! | | macOS | Windows | other |
//! |---|---|---|---|
//! | pointer move / AIM | CGEvent (drag-aware, clamped to displays) | SendInput absolute on the virtual desktop | enigo |
//! | scroll | CGEvent pixel scroll | SendInput WHEEL/HWHEEL (fractional WHEEL_DELTA) | enigo lines |
//! | keys | CGEvent with explicit modifier flags | enigo (printable keys as scan codes) | enigo |
//! | buttons, text, media | enigo | enigo | enigo |

use std::time::{Duration, Instant};

use crate::one_euro::OneEuro;
use crate::smoother::{AbsFollower, RelSmoother};
use crate::protocol::{key_action, mods, Message, AIM_PITCH_HALF_RANGE, AIM_YAW_HALF_RANGE};

pub mod keymap;

#[cfg(target_os = "macos")]
mod mac;
#[cfg(target_os = "macos")]
use mac as platform;

#[cfg(windows)]
mod win;
#[cfg(windows)]
use win as platform;

#[cfg(not(any(target_os = "macos", windows)))]
mod generic;
#[cfg(not(any(target_os = "macos", windows)))]
use generic as platform;

use platform::Backend;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MouseButton {
    Left,
    Right,
    Middle,
}

impl MouseButton {
    pub fn from_wire(b: u8) -> Option<Self> {
        match b {
            0 => Some(MouseButton::Left),
            1 => Some(MouseButton::Right),
            2 => Some(MouseButton::Middle),
            _ => None,
        }
    }

    pub fn index(self) -> usize {
        match self {
            MouseButton::Left => 0,
            MouseButton::Right => 1,
            MouseButton::Middle => 2,
        }
    }

    pub const ALL: [MouseButton; 3] = [MouseButton::Left, MouseButton::Right, MouseButton::Middle];
}

/// A rectangle in the backend's absolute pointer coordinate space.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

impl Rect {
    pub fn contains(&self, x: f64, y: f64) -> bool {
        x >= self.x && y >= self.y && x < self.x + self.w && y < self.y + self.h
    }

    pub fn clamp(&self, x: f64, y: f64) -> (f64, f64) {
        let max_x = self.x + (self.w - 1.0).max(0.0);
        let max_y = self.y + (self.h - 1.0).max(0.0);
        (x.clamp(self.x, max_x), y.clamp(self.y, max_y))
    }
}

/// Accumulates fractional deltas and hands out whole units, keeping the remainder.
#[derive(Debug, Default, Clone, Copy)]
pub struct Accum {
    x: f64,
    y: f64,
}

impl Accum {
    pub fn add(&mut self, dx: f64, dy: f64) -> (i32, i32) {
        self.x += dx;
        self.y += dy;
        let ix = self.x.trunc();
        let iy = self.y.trunc();
        self.x -= ix;
        self.y -= iy;
        (ix as i32, iy as i32)
    }

    pub fn reset(&mut self) {
        *self = Accum::default();
    }
}

/// Logs (at debug level) and swallows an injection error; a dropped event is not fatal.
pub(crate) fn soft<T, E: std::fmt::Debug>(r: Result<T, E>, what: &str) {
    if let Err(e) = r {
        log::debug!("{what} failed: {e:?}");
    }
}

/// Maps a protocol modifier mask to the individual bits in press order.
pub(crate) fn modifier_bits(mask: u8) -> impl DoubleEndedIterator<Item = u8> {
    keymap::MODIFIER_ORDER.into_iter().filter(move |b| mask & b != 0)
}

/// GESTURE id → (modifier mask, HID usage).
///
/// macOS: 1 Mission Control ^↑, 2 app switcher ⌘⇥, 3 Show Desktop F11 (the system default
/// hotkey; synthesized events need no Fn key — we send kVK_F11 with the SecondaryFn flag
/// exactly like a real keyboard), 4/5 Spaces ^← / ^→, 6/7 back/forward ⌘[ / ⌘],
/// 8/9 zoom ⌘= / ⌘-.
#[cfg(target_os = "macos")]
pub fn gesture_shortcut(id: u8) -> Option<(u8, u16)> {
    use keymap::*;
    Some(match id {
        1 => (mods::CTRL, USAGE_UP),
        2 => (mods::META, USAGE_TAB),
        3 => (0, USAGE_F11),
        4 => (mods::CTRL, USAGE_LEFT),
        5 => (mods::CTRL, USAGE_RIGHT),
        6 => (mods::META, USAGE_LEFT_BRACKET),
        7 => (mods::META, USAGE_RIGHT_BRACKET),
        8 => (mods::META, USAGE_EQUAL),
        9 => (mods::META, USAGE_MINUS),
        _ => return None,
    })
}

/// Windows: 1 Task View Win+Tab, 2 Alt+Tab, 3 Win+D, 4/5 Ctrl+Win+←/→,
/// 6/7 Alt+←/→, 8/9 Ctrl+= / Ctrl+-.
#[cfg(not(target_os = "macos"))]
pub fn gesture_shortcut(id: u8) -> Option<(u8, u16)> {
    use keymap::*;
    Some(match id {
        1 => (mods::META, USAGE_TAB),
        2 => (mods::ALT, USAGE_TAB),
        3 => (mods::META, USAGE_D),
        4 => (mods::CTRL | mods::META, USAGE_LEFT),
        5 => (mods::CTRL | mods::META, USAGE_RIGHT),
        6 => (mods::ALT, USAGE_LEFT),
        7 => (mods::ALT, USAGE_RIGHT),
        8 => (mods::CTRL, USAGE_EQUAL),
        9 => (mods::CTRL, USAGE_MINUS),
        _ => return None,
    })
}

/// Checks (and on macOS requests) the OS permission needed to post input events.
pub fn check_permission(prompt: bool) -> bool {
    #[cfg(target_os = "macos")]
    {
        mac::accessibility_trusted(prompt)
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = prompt;
        true
    }
}

struct AimState {
    fx: OneEuro,
    fy: OneEuro,
    start: Instant,
    last: Instant,
}

/// After this much silence an AIM stream is considered a new "hold" and the filter restarts.
const AIM_RESTART_GAP: Duration = Duration::from_millis(250);
// 1€ parameters for pixel-space pointer data.
const AIM_MIN_CUTOFF: f64 = 1.0;
const AIM_BETA: f64 = 0.007;
const AIM_D_CUTOFF: f64 = 1.0;

pub struct Injector {
    backend: Option<Backend>,
    held_buttons: [bool; 3],
    held_keys: Vec<(u16, u8)>,
    aim: Option<AimState>,
    invert_scroll: bool,
    /// Relative MOVE deltas waiting to be emitted by the motion thread (`smoother.rs`).
    rel: RelSmoother,
    /// AIM absolute target, followed at the motion thread's tick rate.
    abs: AbsFollower,
}

impl Injector {
    pub fn new(invert_scroll: bool) -> Self {
        let backend = match Backend::new() {
            Ok(b) => Some(b),
            Err(e) => {
                log::error!("input injection unavailable: {e:#}");
                None
            }
        };
        Injector {
            backend,
            held_buttons: [false; 3],
            held_keys: Vec::new(),
            aim: None,
            invert_scroll,
            rel: RelSmoother::default(),
            abs: AbsFollower::default(),
        }
    }

    /// Handles one message. `now` is the motion thread's clock in seconds. MOVE and AIM are
    /// queued for `tick_motion`; everything else is injected immediately.
    pub fn handle(&mut self, msg: &Message, now: f64) {
        if self.backend.is_none() {
            return;
        }
        match *msg {
            Message::Move { dx, dy } => {
                self.rel.push(dx as f64, dy as f64, now);
                return;
            }
            Message::Button { .. } | Message::Click { .. } => self.flush_motion(),
            _ => {}
        }
        let Some(be) = self.backend.as_mut() else { return };
        match *msg {
            Message::Move { .. } => {}
            Message::Button { button, down } => {
                if let Some(b) = MouseButton::from_wire(button) {
                    if self.held_buttons[b.index()] != down {
                        be.button(b, down);
                        self.held_buttons[b.index()] = down;
                    }
                }
            }
            Message::Click { button, count } => {
                if let Some(b) = MouseButton::from_wire(button) {
                    if self.held_buttons[b.index()] {
                        be.button(b, false);
                        self.held_buttons[b.index()] = false;
                    }
                    be.click(b, count.clamp(1, 3));
                }
            }
            Message::Scroll { dx, dy } => {
                let s = if self.invert_scroll { -1.0 } else { 1.0 };
                be.scroll(dx as f64 * s, dy as f64 * s);
            }
            Message::Gesture(id) => match gesture_shortcut(id) {
                Some((m, usage)) => self.key(key_action::TAP, m, usage),
                None => log::debug!("unknown gesture id {id}"),
            },
            Message::Key { action, mods, usage } => self.key(action, mods, usage),
            Message::Text(ref s) => self.text(s),
            Message::Media(id) => be.media(id),
            Message::Aim { yaw, pitch } => self.aim(yaw, pitch),
            Message::Ping | Message::Pong { .. } | Message::Bye => {}
        }
    }

    /// True while relative or AIM motion is still being eased out.
    pub fn motion_active(&self) -> bool {
        self.backend.is_some() && (self.rel.is_active() || self.abs.is_active())
    }

    /// One motion-thread tick: emits the eased share of pending motion.
    pub fn tick_motion(&mut self, now: f64) {
        let Some(be) = self.backend.as_mut() else { return };
        let (ix, iy) = self.rel.tick(now);
        if ix != 0 || iy != 0 {
            be.move_rel(ix as f64, iy as f64);
        }
        if let Some((x, y)) = self.abs.tick(now) {
            // Targets are already clamped; interpolating between them stays inside.
            be.move_abs(x, y);
        }
    }

    /// Emits all pending motion immediately (before button events).
    fn flush_motion(&mut self) {
        let Some(be) = self.backend.as_mut() else { return };
        let (ix, iy) = self.rel.flush();
        if ix != 0 || iy != 0 {
            be.move_rel(ix as f64, iy as f64);
        }
        if let Some((x, y)) = self.abs.target() {
            if self.abs.position() != Some((x, y)) {
                be.move_abs(x, y);
            }
            self.abs.reset();
            self.abs.set_target(x, y);
        }
    }

    /// Drops motion that has not been emitted yet.
    pub fn clear_motion(&mut self) {
        self.rel.clear();
        self.abs.reset();
    }

    fn key(&mut self, action: u8, mask: u8, usage: u16) {
        let Some(be) = self.backend.as_mut() else { return };
        let mask = mask & (mods::SHIFT | mods::CTRL | mods::ALT | mods::META);
        match action {
            key_action::TAP => {
                be.modifiers(mask, true);
                if usage != 0 {
                    be.key(usage, mask, true);
                    be.key(usage, mask, false);
                }
                be.modifiers(mask, false);
            }
            key_action::DOWN => {
                if self.held_keys.contains(&(usage, mask)) {
                    return; // ignore duplicate downs (auto-repeat is the OS's job)
                }
                be.modifiers(mask, true);
                if usage != 0 {
                    be.key(usage, mask, true);
                }
                self.held_keys.push((usage, mask));
            }
            key_action::UP => {
                let pos = self.held_keys.iter().position(|&(u, _)| u == usage);
                let held_mask = pos.map(|i| self.held_keys.remove(i).1).unwrap_or(mask);
                if usage != 0 {
                    be.key(usage, held_mask, false);
                }
                be.modifiers(held_mask, false);
            }
            other => log::debug!("unknown key action {other}"),
        }
    }

    /// Types text. Newlines and tabs become real Enter / Tab key taps (unicode injection of
    /// control characters is ignored by many apps).
    fn text(&mut self, s: &str) {
        let normalized = s.replace("\r\n", "\n").replace('\r', "\n");
        let mut segment = String::new();
        for c in normalized.chars() {
            let usage = match c {
                '\n' => keymap::USAGE_ENTER,
                '\t' => keymap::USAGE_TAB,
                c if c.is_control() => continue,
                c => {
                    segment.push(c);
                    continue;
                }
            };
            self.flush_text(&mut segment);
            self.key(key_action::TAP, 0, usage);
        }
        self.flush_text(&mut segment);
    }

    fn flush_text(&mut self, segment: &mut String) {
        if segment.is_empty() {
            return;
        }
        if let Some(be) = self.backend.as_mut() {
            be.text(segment);
        }
        segment.clear();
    }

    fn aim(&mut self, yaw: f32, pitch: f32) {
        let Some(be) = self.backend.as_mut() else { return };
        let now = Instant::now();
        let restart = self.aim.as_ref().map_or(true, |a| now.duration_since(a.last) > AIM_RESTART_GAP);
        if restart {
            self.abs.reset(); // a new hold jumps straight to its first target
            self.aim = Some(AimState {
                fx: OneEuro::new(AIM_MIN_CUTOFF, AIM_BETA, AIM_D_CUTOFF),
                fy: OneEuro::new(AIM_MIN_CUTOFF, AIM_BETA, AIM_D_CUTOFF),
                start: now,
                last: now,
            });
        }
        let state = self.aim.as_mut().expect("aim state was just initialized");
        state.last = now;

        let desk = be.desktop();
        let (u, v) = aim_to_unit(yaw, pitch);
        let x = desk.x + u * (desk.w - 1.0).max(0.0);
        let y = desk.y + v * (desk.h - 1.0).max(0.0);
        let t = now.duration_since(state.start).as_secs_f64();
        let fx = state.fx.filter(x, t);
        let fy = state.fy.filter(y, t);
        let (cx, cy) = desk.clamp(fx, fy);
        // Emitted by the motion thread, eased between packets.
        self.abs.set_target(cx, cy);
    }

    /// Releases every held button and key. Called on BYE, on silence, on pause and on quit.
    pub fn release_all(&mut self) {
        let Some(be) = self.backend.as_mut() else { return };
        for b in MouseButton::ALL {
            if self.held_buttons[b.index()] {
                be.button(b, false);
                self.held_buttons[b.index()] = false;
            }
        }
        while let Some((usage, mask)) = self.held_keys.pop() {
            if usage != 0 {
                be.key(usage, mask, false);
            }
            be.modifiers(mask, false);
        }
        self.aim = None;
        self.rel.clear();
        self.abs.reset();
        be.reset_accumulators();
    }

    pub fn has_held_input(&self) -> bool {
        self.held_buttons.iter().any(|&b| b) || !self.held_keys.is_empty()
    }
}

/// Maps AIM angles to unit coordinates (0..1, origin top-left): yaw ±0.35 rad → full width
/// (+yaw = right), pitch ±0.20 rad → full height (+pitch = up). Clamped.
pub fn aim_to_unit(yaw: f32, pitch: f32) -> (f64, f64) {
    let u = 0.5 + yaw as f64 / (2.0 * AIM_YAW_HALF_RANGE as f64);
    let v = 0.5 - pitch as f64 / (2.0 * AIM_PITCH_HALF_RANGE as f64);
    (u.clamp(0.0, 1.0), v.clamp(0.0, 1.0))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn aim_mapping() {
        assert_eq!(aim_to_unit(0.0, 0.0), (0.5, 0.5));
        let (u, v) = aim_to_unit(0.35, 0.20);
        assert!((u - 1.0).abs() < 1e-6 && v.abs() < 1e-6, "right edge, top edge");
        let (u, v) = aim_to_unit(-0.35, -0.20);
        assert!(u.abs() < 1e-6 && (v - 1.0).abs() < 1e-6, "left edge, bottom edge");
        assert_eq!(aim_to_unit(5.0, -5.0), (1.0, 1.0), "clamped");
    }

    #[test]
    fn accumulator_keeps_fractions() {
        let mut a = Accum::default();
        assert_eq!(a.add(0.4, -0.4), (0, 0));
        assert_eq!(a.add(0.4, -0.4), (0, 0));
        assert_eq!(a.add(0.4, -0.4), (1, -1));
        let (x, _) = a.add(10.0, 0.0);
        assert_eq!(x, 10);
    }

    #[test]
    fn modifier_bits_order() {
        let v: Vec<u8> = modifier_bits(mods::META | mods::SHIFT | mods::CTRL).collect();
        assert_eq!(v, vec![mods::CTRL, mods::SHIFT, mods::META]);
        let r: Vec<u8> = modifier_bits(mods::META | mods::CTRL).rev().collect();
        assert_eq!(r, vec![mods::META, mods::CTRL]);
    }

    #[test]
    fn all_gestures_map_to_known_keys() {
        for id in 1..=9u8 {
            let (_, usage) = gesture_shortcut(id).expect("gesture mapped");
            assert!(keymap::hid_to_mac_keycode(usage).is_some());
            assert!(keymap::hid_to_enigo(usage).is_some());
        }
        assert!(gesture_shortcut(0).is_none());
        assert!(gesture_shortcut(10).is_none());
    }

    #[test]
    fn rect_clamp() {
        let r = Rect { x: -1920.0, y: 0.0, w: 3840.0, h: 1080.0 };
        assert_eq!(r.clamp(-5000.0, 5000.0), (-1920.0, 1079.0));
        assert!(r.contains(0.0, 0.0));
        assert!(!r.contains(1920.0, 0.0));
    }
}
