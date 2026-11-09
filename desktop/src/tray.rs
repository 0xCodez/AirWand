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
    format!("AirWand — {}", app.status_line())
}

fn build_menu(app: &App) -> Result<(Menu, MenuIds)> {
    let menu = Menu::new();

    let status = MenuItem::new(app.status_line(), false, None);
    menu.append(&status)?;
    let host = MenuItem::new(format!("This computer: {}", app.host_name()), false, None);
    menu.append(&host)?;
    if !app.input_permitted.load(Ordering::Relaxed) {
        let warn = MenuItem::new("⚠ Allow AirWand in Settings → Privacy & Security → Accessibility", false, None);
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
        devices.append(&MenuItem::new("No paired devices — open AirWand on your phone", false, None))?;
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
    let quit = MenuItem::new("Quit AirWand", true, None);
    menu.append(&quit)?;

    let ids = MenuIds { pause: pause.id().clone(), forget_all: forget_all.id().clone(), quit: quit.id().clone() };
    Ok((menu, ids))
}

/// Draws the AirWand mark (a diagonal wand with a four-point sparkle at its tip) into an
/// RGBA buffer, so the tray needs no image decoder. macOS: black + alpha, used as a
/// template image (the menu bar tints it). Windows: the Prism spectrum, cobalt → violet
/// wand with a cyan sparkle, readable on both light and dark taskbars.
fn draw_icon(size: u32) -> Vec<u8> {
    const SS: u32 = 4; // supersampling per axis
    let s = size as f64;
    let (ax, ay, bx, by) = (0.14 * s, 0.86 * s, 0.50 * s, 0.50 * s);
    let half_w = 0.06 * s;
    let (cx, cy) = (0.68 * s, 0.32 * s);
    let star_r = (0.32 * s).sqrt();
    let gap_r = 0.19 * s;

    let wand_dist = |x: f64, y: f64| {
        let (dx, dy) = (bx - ax, by - ay);
        let t = (((x - ax) * dx + (y - ay) * dy) / (dx * dx + dy * dy)).clamp(0.0, 1.0);
        ((x - ax - t * dx).powi(2) + (y - ay - t * dy).powi(2)).sqrt()
    };

    let mut px = vec![0u8; (size * size * 4) as usize];
    for y in 0..size {
        for x in 0..size {
            let (mut wand, mut star) = (0u32, 0u32);
            for sy in 0..SS {
                for sx in 0..SS {
                    let fx = x as f64 + (sx as f64 + 0.5) / SS as f64;
                    let fy = y as f64 + (sy as f64 + 0.5) / SS as f64;
                    let (dx, dy) = ((fx - cx).abs(), (fy - cy).abs());
                    // sqrt|x| + sqrt|y| <= sqrt r: a concave four-point sparkle.
                    if dx.sqrt() + dy.sqrt() <= star_r {
                        star += 1;
                    } else if wand_dist(fx, fy) <= half_w && (dx * dx + dy * dy).sqrt() > gap_r {
                        wand += 1;
                    }
                }
            }
            let n = (SS * SS) as f64;
            let alpha = (wand + star) as f64 / n;
            if alpha <= 0.0 {
                continue;
            }
            let i = ((y * size + x) * 4) as usize;
            let (r, g, b) = if cfg!(target_os = "macos") {
                (0.0, 0.0, 0.0)
            } else if star >= wand {
                (38.0, 200.0, 255.0) // #26C8FF
            } else {
                // #2E5CFF → #9646FF from the handle to the tip
                let t = (x as f64 / s).clamp(0.0, 1.0);
                (46.0 + (150.0 - 46.0) * t, 92.0 + (70.0 - 92.0) * t, 255.0)
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
    fn icon_has_wand_and_sparkle() {
        let size = 32;
        let px = draw_icon(size);
        assert_eq!(px.len(), (size * size * 4) as usize);
        let alpha = |x: u32, y: u32| px[((y * size + x) * 4 + 3) as usize];
        assert_eq!(alpha(0, 0), 0, "top-left corner is empty");
        assert_eq!(alpha(31, 31), 0, "bottom-right corner is empty");
        assert_eq!(alpha(6, 6), 0, "area above the wand is empty");
        assert!(alpha(22, 10) > 200, "sparkle center is opaque");
        assert!(alpha(10, 22) > 200, "wand shaft is opaque");
    }
}
