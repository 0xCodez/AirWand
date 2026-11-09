//! USB HID keyboard usage IDs (page 0x07) → platform keys.
//!
//! Both tables are pure data and compiled on every platform so they can be unit tested
//! anywhere; each backend uses the one it needs.

#![allow(dead_code)]

use enigo::Key;

use crate::protocol::mods;

/// Usages PROTOCOL.md requires every host to understand.
pub const REQUIRED_USAGES: &[u16] = &[
    // a..z
    0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15,
    0x16, 0x17, 0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D, //
    // 1..9, 0
    0x1E, 0x1F, 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, //
    // Enter, Esc, Backspace, Tab, Space
    0x28, 0x29, 0x2A, 0x2B, 0x2C, //
    // F1..F12
    0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F, 0x40, 0x41, 0x42, 0x43, 0x44, 0x45, //
    // Home, PageUp, Delete, End, PageDown, Right, Left, Down, Up
    0x4A, 0x4B, 0x4C, 0x4D, 0x4E, 0x4F, 0x50, 0x51, 0x52,
];

/// Extra usages we also map (punctuation, CapsLock, Insert, modifiers) because shortcut
/// chips and the GESTURE table use them.
pub const EXTRA_USAGES: &[u16] = &[
    0x2D, 0x2E, 0x2F, 0x30, 0x31, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0xE0, 0xE1, 0xE2, 0xE3, 0xE4, 0xE5,
    0xE6, 0xE7,
];

pub const USAGE_ENTER: u16 = 0x28;
pub const USAGE_TAB: u16 = 0x2B;
pub const USAGE_MINUS: u16 = 0x2D;
pub const USAGE_EQUAL: u16 = 0x2E;
pub const USAGE_LEFT_BRACKET: u16 = 0x2F;
pub const USAGE_RIGHT_BRACKET: u16 = 0x30;
pub const USAGE_D: u16 = 0x07;
pub const USAGE_F11: u16 = 0x44;
pub const USAGE_RIGHT: u16 = 0x4F;
pub const USAGE_LEFT: u16 = 0x50;
pub const USAGE_DOWN: u16 = 0x51;
pub const USAGE_UP: u16 = 0x52;

/// Character produced by a printable usage on a US layout (unshifted).
pub fn hid_to_char(usage: u16) -> Option<char> {
    Some(match usage {
        0x04..=0x1D => (b'a' + (usage - 0x04) as u8) as char,
        0x1E..=0x26 => (b'1' + (usage - 0x1E) as u8) as char,
        0x27 => '0',
        0x2D => '-',
        0x2E => '=',
        0x2F => '[',
        0x30 => ']',
        0x31 => '\\',
        0x33 => ';',
        0x34 => '\'',
        0x35 => '`',
        0x36 => ',',
        0x37 => '.',
        0x38 => '/',
        _ => return None,
    })
}

/// HID modifier usages (0xE0..0xE7) as a protocol modifier bit.
pub fn hid_modifier_bit(usage: u16) -> Option<u8> {
    Some(match usage {
        0xE0 | 0xE4 => mods::CTRL,
        0xE1 | 0xE5 => mods::SHIFT,
        0xE2 | 0xE6 => mods::ALT,
        0xE3 | 0xE7 => mods::META,
        _ => return None,
    })
}

/// HID usage → enigo key (fallback backend; on Windows only for keys without a scan code
/// in `hid_to_win_scancode`). Letters, digits and punctuation map to `Key::Unicode`, which
/// enigo resolves through the active keyboard layout.
pub fn hid_to_enigo(usage: u16) -> Option<Key> {
    if let Some(c) = hid_to_char(usage) {
        return Some(Key::Unicode(c));
    }
    Some(match usage {
        0x28 => Key::Return,
        0x29 => Key::Escape,
        0x2A => Key::Backspace,
        0x2B => Key::Tab,
        0x2C => Key::Space,
        0x39 => Key::CapsLock,
        0x3A => Key::F1,
        0x3B => Key::F2,
        0x3C => Key::F3,
        0x3D => Key::F4,
        0x3E => Key::F5,
        0x3F => Key::F6,
        0x40 => Key::F7,
        0x41 => Key::F8,
        0x42 => Key::F9,
        0x43 => Key::F10,
        0x44 => Key::F11,
        0x45 => Key::F12,
        #[cfg(not(target_os = "macos"))]
        0x49 => Key::Insert,
        0x4A => Key::Home,
        0x4B => Key::PageUp,
        0x4C => Key::Delete,
        0x4D => Key::End,
        0x4E => Key::PageDown,
        0x4F => Key::RightArrow,
        0x50 => Key::LeftArrow,
        0x51 => Key::DownArrow,
        0x52 => Key::UpArrow,
        0xE0 | 0xE4 => Key::Control,
        0xE1 | 0xE5 => Key::Shift,
        0xE2 | 0xE6 => Key::Alt,
        0xE3 | 0xE7 => Key::Meta,
        _ => return None,
    })
}

/// HID usage → PC/AT scan code set 1 (make code) for the printable keys, i.e. every usage
/// `hid_to_char` knows. Windows backend: these go through `enigo.raw` (KEYEVENTF_SCANCODE)
/// so they are positional like a real keyboard and work on every layout. `Key::Unicode`
/// would go through `VkKeyScanW`, which fails for Latin letters on e.g. a Russian layout,
/// breaking Ctrl+C, Win+D and friends.
pub fn hid_to_win_scancode(usage: u16) -> Option<u16> {
    Some(match usage {
        0x04 => 0x1E, // A
        0x05 => 0x30, // B
        0x06 => 0x2E, // C
        0x07 => 0x20, // D
        0x08 => 0x12, // E
        0x09 => 0x21, // F
        0x0A => 0x22, // G
        0x0B => 0x23, // H
        0x0C => 0x17, // I
        0x0D => 0x24, // J
        0x0E => 0x25, // K
        0x0F => 0x26, // L
        0x10 => 0x32, // M
        0x11 => 0x31, // N
        0x12 => 0x18, // O
        0x13 => 0x19, // P
        0x14 => 0x10, // Q
        0x15 => 0x13, // R
        0x16 => 0x1F, // S
        0x17 => 0x14, // T
        0x18 => 0x16, // U
        0x19 => 0x2F, // V
        0x1A => 0x11, // W
        0x1B => 0x2D, // X
        0x1C => 0x15, // Y
        0x1D => 0x2C, // Z
        0x1E => 0x02, // 1
        0x1F => 0x03, // 2
        0x20 => 0x04, // 3
        0x21 => 0x05, // 4
        0x22 => 0x06, // 5
        0x23 => 0x07, // 6
        0x24 => 0x08, // 7
        0x25 => 0x09, // 8
        0x26 => 0x0A, // 9
        0x27 => 0x0B, // 0
        0x2D => 0x0C, // -
        0x2E => 0x0D, // =
        0x2F => 0x1A, // [
        0x30 => 0x1B, // ]
        0x31 => 0x2B, // \
        0x33 => 0x27, // ;
        0x34 => 0x28, // '
        0x35 => 0x29, // `
        0x36 => 0x33, // ,
        0x37 => 0x34, // .
        0x38 => 0x35, // /
        _ => return None,
    })
}

/// Protocol modifier bit → enigo key.
pub fn modifier_to_enigo(bit: u8) -> Key {
    match bit {
        mods::SHIFT => Key::Shift,
        mods::CTRL => Key::Control,
        mods::ALT => Key::Alt,
        _ => Key::Meta,
    }
}

/// Modifier bits in press order (release in reverse).
pub const MODIFIER_ORDER: [u8; 4] = [mods::CTRL, mods::ALT, mods::SHIFT, mods::META];

/// HID usage → macOS virtual key code (`kVK_*` from Carbon `Events.h`). ANSI positional
/// codes, which matches the positional meaning of HID usages.
pub fn hid_to_mac_keycode(usage: u16) -> Option<u16> {
    Some(match usage {
        0x04 => 0x00, // A
        0x05 => 0x0B, // B
        0x06 => 0x08, // C
        0x07 => 0x02, // D
        0x08 => 0x0E, // E
        0x09 => 0x03, // F
        0x0A => 0x05, // G
        0x0B => 0x04, // H
        0x0C => 0x22, // I
        0x0D => 0x26, // J
        0x0E => 0x28, // K
        0x0F => 0x25, // L
        0x10 => 0x2E, // M
        0x11 => 0x2D, // N
        0x12 => 0x1F, // O
        0x13 => 0x23, // P
        0x14 => 0x0C, // Q
        0x15 => 0x0F, // R
        0x16 => 0x01, // S
        0x17 => 0x11, // T
        0x18 => 0x20, // U
        0x19 => 0x09, // V
        0x1A => 0x0D, // W
        0x1B => 0x07, // X
        0x1C => 0x10, // Y
        0x1D => 0x06, // Z
        0x1E => 0x12, // 1
        0x1F => 0x13, // 2
        0x20 => 0x14, // 3
        0x21 => 0x15, // 4
        0x22 => 0x17, // 5
        0x23 => 0x16, // 6
        0x24 => 0x1A, // 7
        0x25 => 0x1C, // 8
        0x26 => 0x19, // 9
        0x27 => 0x1D, // 0
        0x28 => 0x24, // Return
        0x29 => 0x35, // Escape
        0x2A => 0x33, // Delete (backspace)
        0x2B => 0x30, // Tab
        0x2C => 0x31, // Space
        0x2D => 0x1B, // -
        0x2E => 0x18, // =
        0x2F => 0x21, // [
        0x30 => 0x1E, // ]
        0x31 => 0x2A, // \
        0x33 => 0x29, // ;
        0x34 => 0x27, // '
        0x35 => 0x32, // `
        0x36 => 0x2B, // ,
        0x37 => 0x2F, // .
        0x38 => 0x2C, // /
        0x39 => 0x39, // CapsLock
        0x3A => 0x7A, // F1
        0x3B => 0x78, // F2
        0x3C => 0x63, // F3
        0x3D => 0x76, // F4
        0x3E => 0x60, // F5
        0x3F => 0x61, // F6
        0x40 => 0x62, // F7
        0x41 => 0x64, // F8
        0x42 => 0x65, // F9
        0x43 => 0x6D, // F10
        0x44 => 0x67, // F11
        0x45 => 0x6F, // F12
        0x49 => 0x72, // Insert → Help
        0x4A => 0x73, // Home
        0x4B => 0x74, // PageUp
        0x4C => 0x75, // Forward delete
        0x4D => 0x77, // End
        0x4E => 0x79, // PageDown
        0x4F => 0x7C, // Right
        0x50 => 0x7B, // Left
        0x51 => 0x7D, // Down
        0x52 => 0x7E, // Up
        0xE0 => 0x3B, // Left control
        0xE1 => 0x38, // Left shift
        0xE2 => 0x3A, // Left option
        0xE3 => 0x37, // Left command
        0xE4 => 0x3E, // Right control
        0xE5 => 0x3C, // Right shift
        0xE6 => 0x3D, // Right option
        0xE7 => 0x36, // Right command
        _ => return None,
    })
}

/// macOS keycode for a protocol modifier bit.
pub fn modifier_to_mac_keycode(bit: u8) -> u16 {
    match bit {
        mods::SHIFT => 0x38,
        mods::CTRL => 0x3B,
        mods::ALT => 0x3A,
        _ => 0x37,
    }
}

/// Keys that real Apple keyboards send with extra event flags: arrows carry
/// NumericPad + SecondaryFn, the F-keys and the navigation block carry SecondaryFn.
/// System hotkeys such as ^↑ (Mission Control) and F11 (Show Desktop) are registered
/// with these flags, so synthesized events must carry them too.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MacKeyClass {
    Plain,
    Function,
    Arrow,
}

pub fn mac_key_class(usage: u16) -> MacKeyClass {
    match usage {
        0x4F..=0x52 => MacKeyClass::Arrow,
        0x3A..=0x45 | 0x49..=0x4E => MacKeyClass::Function,
        _ => MacKeyClass::Plain,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    #[test]
    fn every_required_usage_is_mapped_on_every_backend() {
        assert_eq!(REQUIRED_USAGES.len(), 26 + 10 + 5 + 12 + 9);
        for &u in REQUIRED_USAGES {
            assert!(hid_to_enigo(u).is_some(), "enigo mapping missing for usage 0x{u:02X}");
            assert!(hid_to_mac_keycode(u).is_some(), "mac mapping missing for usage 0x{u:02X}");
        }
        for &u in EXTRA_USAGES {
            assert!(hid_to_mac_keycode(u).is_some(), "mac mapping missing for usage 0x{u:02X}");
            assert!(hid_to_enigo(u).is_some(), "enigo mapping missing for usage 0x{u:02X}");
        }
    }

    #[test]
    fn letters_and_digits_are_unicode() {
        assert_eq!(hid_to_enigo(0x04), Some(Key::Unicode('a')));
        assert_eq!(hid_to_enigo(0x1D), Some(Key::Unicode('z')));
        assert_eq!(hid_to_enigo(0x1E), Some(Key::Unicode('1')));
        assert_eq!(hid_to_enigo(0x26), Some(Key::Unicode('9')));
        assert_eq!(hid_to_enigo(0x27), Some(Key::Unicode('0')));
        assert_eq!(hid_to_enigo(0x2C), Some(Key::Space));
        assert_eq!(hid_to_enigo(0x4C), Some(Key::Delete));
        assert_eq!(hid_to_enigo(0x2A), Some(Key::Backspace));
    }

    #[test]
    fn mac_keycodes_are_unique() {
        let mut seen = HashSet::new();
        for &u in REQUIRED_USAGES.iter().chain(EXTRA_USAGES) {
            let k = hid_to_mac_keycode(u).unwrap();
            assert!(seen.insert(k), "duplicate mac keycode 0x{k:02X} for usage 0x{u:02X}");
        }
        // Spot checks against Carbon kVK_* constants.
        assert_eq!(hid_to_mac_keycode(0x04), Some(0x00)); // kVK_ANSI_A
        assert_eq!(hid_to_mac_keycode(0x06), Some(0x08)); // kVK_ANSI_C
        assert_eq!(hid_to_mac_keycode(0x52), Some(0x7E)); // kVK_UpArrow
        assert_eq!(hid_to_mac_keycode(0x44), Some(0x67)); // kVK_F11
    }

    #[test]
    fn windows_scancodes_cover_printable_keys() {
        let mut seen = HashSet::new();
        for u in 0u16..=0xFF {
            assert_eq!(hid_to_char(u).is_some(), hid_to_win_scancode(u).is_some(), "usage 0x{u:02X}");
            if let Some(sc) = hid_to_win_scancode(u) {
                assert!(sc > 0 && sc <= 0x7F, "non-extended make code");
                assert!(seen.insert(sc), "duplicate scan code 0x{sc:02X}");
            }
        }
        assert_eq!(hid_to_win_scancode(0x04), Some(0x1E)); // A
        assert_eq!(hid_to_win_scancode(0x06), Some(0x2E)); // C
        assert_eq!(hid_to_win_scancode(0x1E), Some(0x02)); // 1
        assert_eq!(hid_to_win_scancode(0x27), Some(0x0B)); // 0
    }

    #[test]
    fn unknown_usages_are_rejected() {
        for u in [0x00u16, 0x01, 0x03, 0x32, 0x46, 0x53, 0xFF, 0x1234] {
            assert!(hid_to_mac_keycode(u).is_none());
            assert!(hid_to_enigo(u).is_none());
        }
    }

    #[test]
    fn mac_flag_classes() {
        assert_eq!(mac_key_class(USAGE_UP), MacKeyClass::Arrow);
        assert_eq!(mac_key_class(USAGE_F11), MacKeyClass::Function);
        assert_eq!(mac_key_class(0x04), MacKeyClass::Plain);
        assert_eq!(hid_modifier_bit(0xE3), Some(mods::META));
    }
}
