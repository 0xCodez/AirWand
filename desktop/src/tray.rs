//! Menu bar (macOS) / notification area (Windows) icon and menu.
//! Must be created and updated on the main thread, after the event loop has started.

use std::sync::atomic::Ordering;

use anyhow::Result;
use tray_icon::menu::{Menu, MenuId, MenuItem, PredefinedMenuItem, Submenu};
use tray_icon::{Icon, TrayIcon, TrayIconBuilder};

use crate::app::App;

pub enum MenuAction {
    TogglePause,
    ForgetAll,
    Quit,
}

struct MenuIds {
    pause: MenuId,
    forget_all: MenuId,
    quit: MenuId,
}

pub struct Tray {
    icon: TrayIcon,
    ids: MenuIds,
}

impl Tray {
    pub fn new(app: &App) -> Result<Self> {
        let (menu, ids) = build_menu(app)?;
        let builder = TrayIconBuilder::new()
            .with_menu(Box::new(menu))
            .with_tooltip(tooltip(app))
            .with_icon(make_icon()?);
        #[cfg(target_os = "macos")]
        let builder = builder.with_icon_as_template(true);
        let icon = builder.build()?;
        Ok(Tray { icon, ids })
    }

    /// Rebuilds the menu so status, pause label and device list are current.
    pub fn refresh(&mut self, app: &App) {
        match build_menu(app) {
            Ok((menu, ids)) => {
                self.icon.set_menu(Some(Box::new(menu)));
                self.ids = ids;
            }
            Err(e) => log::warn!("cannot rebuild tray menu: {e:#}"),
        }
        if let Err(e) = self.icon.set_tooltip(Some(tooltip(app))) {
            log::debug!("cannot update tooltip: {e}");
        }
    }

    pub fn action_for(&self, id: &MenuId) -> Option<MenuAction> {
        if *id == self.ids.pause {
            Some(MenuAction::TogglePause)
        } else if *id == self.ids.forget_all {
            Some(MenuAction::ForgetAll)
        } else if *id == self.ids.quit {
            Some(MenuAction::Quit)
        } else {
            None
        }
    }
}

fn tooltip(app: &App) -> String {
    format!("Orbit — {}", app.status_line())
}

fn build_menu(app: &App) -> Result<(Menu, MenuIds)> {
    let menu = Menu::new();

    let status = MenuItem::new(app.status_line(), false, None);
    menu.append(&status)?;
    let host = MenuItem::new(format!("This computer: {}", app.host_name()), false, None);
    menu.append(&host)?;
    if !app.input_permitted.load(Ordering::Relaxed) {
        let warn = MenuItem::new("⚠ Allow Orbit in Settings → Privacy & Security → Accessibility", false, None);
        menu.append(&warn)?;
    }
    menu.append(&PredefinedMenuItem::separator())?;

    let pause_label = if app.is_paused() { "Resume control" } else { "Pause control" };
    let pause = MenuItem::new(pause_label, true, None);
    menu.append(&pause)?;

    let devices = Submenu::new("Paired devices", true);
    let paired = app.paired_devices();
    let connected = app.connected_names();
    if paired.is_empty() {
        devices.append(&MenuItem::new("No paired devices — open Orbit on your phone", false, None))?;
    } else {
        for d in &paired {
            let dot = if connected.contains(&d.name) { "● " } else { "○ " };
            let platform = match d.platform.as_str() {
                "ios" => " (iOS)",
                "android" => " (Android)",
                _ => "",
            };
            devices.append(&MenuItem::new(format!("{dot}{}{platform}", d.name), false, None))?;
        }
    }
    devices.append(&PredefinedMenuItem::separator())?;
    let forget_all = MenuItem::new("Forget all", !paired.is_empty(), None);
    devices.append(&forget_all)?;
    menu.append(&devices)?;

    menu.append(&PredefinedMenuItem::separator())?;
    let quit = MenuItem::new("Quit Orbit", true, None);
    menu.append(&quit)?;

    let ids = MenuIds { pause: pause.id().clone(), forget_all: forget_all.id().clone(), quit: quit.id().clone() };
    Ok((menu, ids))
}

/// Draws the Orbit mark (a ring with a small satellite) into an RGBA buffer, so the app
/// ships no binary assets. macOS: black + alpha, used as a template image (the menu bar
/// tints it). Windows: the orbit-blue → violet accent gradient.
fn draw_icon(size: u32) -> Vec<u8> {
    let s = size as f64;
    let c = s / 2.0;
    let ring_r = s * 0.34;
    let ring_half = s * 0.075;
    let angle = -std::f64::consts::FRAC_PI_4; // satellite at the upper right
    let (sx, sy) = (c + ring_r * angle.cos(), c + ring_r * angle.sin());
    let sat_r = s * 0.13;
    let gap_r = sat_r + s * 0.06; // clear ring around the satellite

    let mut px = vec![0u8; (size * size * 4) as usize];
    for y in 0..size {
        for x in 0..size {
            let (fx, fy) = (x as f64 + 0.5, y as f64 + 0.5);
            let d = ((fx - c).powi(2) + (fy - c).powi(2)).sqrt();
            let ds = ((fx - sx).powi(2) + (fy - sy).powi(2)).sqrt();
            let ring = (ring_half - (d - ring_r).abs() + 0.5).clamp(0.0, 1.0);
            let gap = (ds - gap_r + 0.5).clamp(0.0, 1.0);
            let sat = (sat_r - ds + 0.5).clamp(0.0, 1.0);
            let alpha = (ring * gap).max(sat);
            if alpha <= 0.0 {
                continue;
            }
            let i = ((y * size + x) * 4) as usize;
            let (r, g, b) = if cfg!(target_os = "macos") {
                (0.0, 0.0, 0.0)
            } else if sat > 0.0 {
                (143.0, 219.0, 255.0) // flare #8FDBFF
            } else {
                // accentA #5B8CFF → accentB #A06BFF along the 135° diagonal
                let t = ((fx + fy) / (2.0 * s)).clamp(0.0, 1.0);
                (91.0 + (160.0 - 91.0) * t, 140.0 + (107.0 - 140.0) * t, 255.0)
            };
            px[i] = r as u8;
            px[i + 1] = g as u8;
            px[i + 2] = b as u8;
            px[i + 3] = (alpha * 255.0).round() as u8;
        }
    }
    px
}

fn make_icon() -> Result<Icon> {
    let size = if cfg!(target_os = "macos") { 44 } else { 32 };
    Ok(Icon::from_rgba(draw_icon(size), size, size)?)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn icon_has_ring_and_transparent_center() {
        let size = 32;
        let px = draw_icon(size);
        assert_eq!(px.len(), (size * size * 4) as usize);
        let alpha = |x: u32, y: u32| px[((y * size + x) * 4 + 3) as usize];
        assert_eq!(alpha(16, 16), 0, "center is empty");
        assert_eq!(alpha(0, 0), 0, "corner is empty");
        // Left side of the ring (radius 0.34 * 32 ≈ 10.9 px from the center).
        assert!(alpha(5, 16) > 200, "ring is opaque");
    }
}
