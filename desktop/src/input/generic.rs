//! Fallback backend for platforms without a native implementation (development only):
//! everything goes through enigo, scrolling is converted to whole lines.

use anyhow::{anyhow, Result};
use enigo::{Axis, Button, Coordinate, Direction, Enigo, Key, Keyboard, Mouse, Settings};

use super::{keymap, modifier_bits, soft, Accum, MouseButton, Rect};

/// Pixels per scroll line for the line-based fallback.
const PX_PER_LINE: f64 = 40.0;

pub struct Backend {
    enigo: Enigo,
    motion: Accum,
    lines: Accum,
}

impl Backend {
    pub fn new() -> Result<Self> {
        let enigo = Enigo::new(&Settings::default()).map_err(|e| anyhow!("enigo init failed: {e:?}"))?;
        Ok(Backend { enigo, motion: Accum::default(), lines: Accum::default() })
    }

    pub fn move_rel(&mut self, dx: f64, dy: f64) {
        let (ix, iy) = self.motion.add(dx, dy);
        if ix != 0 || iy != 0 {
            soft(self.enigo.move_mouse(ix, iy, Coordinate::Rel), "move");
        }
    }

    pub fn desktop(&mut self) -> Rect {
        let (w, h) = self.enigo.main_display().unwrap_or((1920, 1080));
        Rect { x: 0.0, y: 0.0, w: w as f64, h: h as f64 }
    }

    pub fn move_abs(&mut self, x: f64, y: f64) {
        soft(self.enigo.move_mouse(x.round() as i32, y.round() as i32, Coordinate::Abs), "move");
    }

    pub fn button(&mut self, b: MouseButton, down: bool) {
        let dir = if down { Direction::Press } else { Direction::Release };
        soft(self.enigo.button(enigo_button(b), dir), "mouse button");
    }

    pub fn click(&mut self, b: MouseButton, count: u8) {
        for _ in 0..count {
            soft(self.enigo.button(enigo_button(b), Direction::Click), "mouse click");
        }
    }

    /// enigo: positive lengths scroll down / right, matching the protocol's signs.
    pub fn scroll(&mut self, dx: f64, dy: f64) {
        let (h, v) = self.lines.add(dx / PX_PER_LINE, dy / PX_PER_LINE);
        if v != 0 {
            soft(self.enigo.scroll(v, Axis::Vertical), "scroll");
        }
        if h != 0 {
            soft(self.enigo.scroll(h, Axis::Horizontal), "scroll");
        }
    }

    pub fn key(&mut self, usage: u16, _mask: u8, down: bool) {
        let Some(k) = keymap::hid_to_enigo(usage) else { return };
        let dir = if down { Direction::Press } else { Direction::Release };
        soft(self.enigo.key(k, dir), "key");
    }

    pub fn modifiers(&mut self, mask: u8, down: bool) {
        let bits: Vec<u8> = if down { modifier_bits(mask).collect() } else { modifier_bits(mask).rev().collect() };
        for bit in bits {
            let dir = if down { Direction::Press } else { Direction::Release };
            soft(self.enigo.key(keymap::modifier_to_enigo(bit), dir), "modifier");
        }
    }

    pub fn text(&mut self, s: &str) {
        soft(self.enigo.text(s), "text");
    }

    pub fn media(&mut self, id: u8) {
        let k = match id {
            1 => Key::MediaPlayPause,
            2 => Key::MediaNextTrack,
            3 => Key::MediaPrevTrack,
            4 => Key::VolumeUp,
            5 => Key::VolumeDown,
            6 => Key::VolumeMute,
            _ => return,
        };
        soft(self.enigo.key(k, Direction::Click), "media key");
    }

    pub fn reset_accumulators(&mut self) {
        self.motion.reset();
        self.lines.reset();
    }
}

fn enigo_button(b: MouseButton) -> Button {
    match b {
        MouseButton::Left => Button::Left,
        MouseButton::Right => Button::Right,
        MouseButton::Middle => Button::Middle,
    }
}
