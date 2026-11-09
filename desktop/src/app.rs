//! State shared between the UI (main thread), the pairing server and the control loop.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, MutexGuard};

use tray_icon::menu::MenuEvent;

use crate::config::{Config, PairedDevice};
use crate::protocol::{DeviceId, SessionKey};

/// Events delivered to the main-thread event loop.
pub enum UiEvent {
    /// Status changed (connections, pairings, pause): rebuild the tray menu.
    Refresh,
    /// A tray menu item was clicked.
    Menu(MenuEvent),
    /// macOS only: show the Allow/Deny dialog on the main thread (AppKit requirement).
    #[cfg(target_os = "macos")]
    Prompt(PairPrompt),
}

#[cfg(target_os = "macos")]
pub struct PairPrompt {
    pub device_name: String,
    pub code: String,
    /// Skip the dialog if the pairing already timed out while the main thread was busy.
    pub deadline: std::time::Instant,
    pub reply: std::sync::mpsc::Sender<bool>,
}

type Notifier = Box<dyn Fn(UiEvent) + Send>;

pub struct App {
    config: Mutex<Config>,
    connected: Mutex<Vec<String>>,
    notifier: Mutex<Option<Notifier>>,
    pub paused: AtomicBool,
    pub shutdown: AtomicBool,
    pub released: AtomicBool,
    pub input_permitted: AtomicBool,
}

/// Locks a mutex, recovering the data if another thread panicked while holding it.
pub fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

impl App {
    pub fn new(config: Config) -> Self {
        App {
            config: Mutex::new(config),
            connected: Mutex::new(Vec::new()),
            notifier: Mutex::new(None),
            paused: AtomicBool::new(false),
            shutdown: AtomicBool::new(false),
            released: AtomicBool::new(false),
            input_permitted: AtomicBool::new(true),
        }
    }

    pub fn set_notifier(&self, f: Notifier) {
        *lock(&self.notifier) = Some(f);
    }

    pub fn notify(&self, event: UiEvent) {
        if let Some(f) = lock(&self.notifier).as_ref() {
            f(event);
        }
    }

    pub fn config(&self) -> MutexGuard<'_, Config> {
        lock(&self.config)
    }

    pub fn host_id(&self) -> [u8; 16] {
        self.config().host_id
    }

    pub fn host_name(&self) -> String {
        self.config().host_name.clone()
    }

    pub fn invert_scroll(&self) -> bool {
        self.config().invert_scroll
    }

    /// Key and name of a paired device.
    pub fn lookup(&self, id: &DeviceId) -> Option<(SessionKey, String)> {
        self.config().find(id).map(|d| (d.key, d.name.clone()))
    }

    pub fn paired_devices(&self) -> Vec<PairedDevice> {
        self.config().paired.clone()
    }

    pub fn add_paired(&self, device: PairedDevice) -> anyhow::Result<()> {
        let mut cfg = self.config();
        cfg.upsert(device);
        cfg.save()
    }

    pub fn forget_all(&self) -> anyhow::Result<()> {
        let mut cfg = self.config();
        cfg.forget_all();
        cfg.save()
    }

    pub fn set_connected(&self, names: Vec<String>) {
        *lock(&self.connected) = names;
    }

    pub fn connected_names(&self) -> Vec<String> {
        lock(&self.connected).clone()
    }

    pub fn is_paused(&self) -> bool {
        self.paused.load(Ordering::Relaxed)
    }

    pub fn toggle_pause(&self) -> bool {
        let now = !self.paused.load(Ordering::Relaxed);
        self.paused.store(now, Ordering::Relaxed);
        now
    }

    /// One-line status for the tray: "Connected: iPhone 17 Pro" / "Waiting for devices".
    pub fn status_line(&self) -> String {
        let names = self.connected_names();
        let base = if names.is_empty() {
            "Waiting for devices".to_string()
        } else {
            format!("Connected: {}", names.join(", "))
        };
        if self.is_paused() {
            format!("Paused · {base}")
        } else {
            base
        }
    }
}
