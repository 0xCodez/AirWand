//! Orbit desktop host agent.
//!
//! Threads:
//! * main — tao event loop, tray icon/menu, macOS pairing dialogs (AppKit wants them here)
//! * `orbit-pairing` — TCP 47821 pairing server (one short-lived thread per connection)
//! * `orbit-control` — UDP 47821: discovery probe replies, encrypted control packets,
//!   input injection and the 3 s safety watchdog
//! * mdns-sd's own daemon thread — `_orbit._tcp` advertisement

#![cfg_attr(all(windows, not(debug_assertions)), windows_subsystem = "windows")]

mod app;
mod config;
mod control;
mod crypto;
mod dialog;
mod discovery;
mod input;
mod one_euro;
mod pairing;
mod protocol;
mod smoother;
mod tray;

use std::net::{Ipv4Addr, TcpListener, UdpSocket};
use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use anyhow::{Context, Result};
use tao::event::{Event, StartCause};
use tao::event_loop::{ControlFlow, EventLoopBuilder};
use tray_icon::menu::MenuEvent;
use tray_icon::TrayIconEvent;

use crate::app::{App, UiEvent};
use crate::config::Config;
use crate::protocol::PORT;
use crate::tray::{MenuAction, Tray};

fn init_logging() {
    let mut builder = env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info"));
    #[cfg(all(windows, not(debug_assertions)))]
    if let Some(file) = config::open_log_file() {
        builder.target(env_logger::Target::Pipe(Box::new(file)));
    }
    builder.init();
}

fn main() {
    init_logging();
    if let Err(e) = run() {
        log::error!("{e:#}");
        eprintln!("orbit: {e:#}");
        std::process::exit(1);
    }
}

fn run() -> Result<()> {
    log::info!("Orbit {} starting", env!("CARGO_PKG_VERSION"));
    let config = Config::load_or_create().context("loading configuration")?;
    let app = Arc::new(App::new(config));
    log::info!("host \"{}\" id {}", app.host_name(), config::id_hex(&app.host_id()));

    // macOS: posting events needs the Accessibility permission. Ask now (shows the system
    // prompt once); the control loop re-checks periodically and the tray shows a hint.
    let permitted = input::check_permission(true);
    app.input_permitted.store(permitted, Ordering::Relaxed);
    if !permitted {
        log::warn!(
            "Accessibility permission is missing: Orbit cannot move the pointer or type. \
             Enable Orbit in System Settings → Privacy & Security → Accessibility, then restart Orbit."
        );
    }

    // Bind both sockets up front so a second instance fails loudly instead of half-working.
    let udp = UdpSocket::bind((Ipv4Addr::UNSPECIFIED, PORT))
        .with_context(|| format!("binding UDP port {PORT} (is Orbit already running?)"))?;
    let tcp = TcpListener::bind((Ipv4Addr::UNSPECIFIED, PORT))
        .with_context(|| format!("binding TCP port {PORT} (is Orbit already running?)"))?;

    #[allow(unused_mut)]
    let mut event_loop = EventLoopBuilder::<UiEvent>::with_user_event().build();
    #[cfg(target_os = "macos")]
    {
        // Menu bar only: no Dock icon even when run outside the .app bundle.
        use tao::platform::macos::{ActivationPolicy, EventLoopExtMacOS};
        event_loop.set_activation_policy(ActivationPolicy::Accessory);
    }

    let proxy = Mutex::new(event_loop.create_proxy());
    app.set_notifier(Box::new(move |event| {
        let _ = app::lock(&proxy).send_event(event);
    }));
    {
        let app = app.clone();
        MenuEvent::set_event_handler(Some(move |event: MenuEvent| app.notify(UiEvent::Menu(event))));
    }
    // Icon clicks / hovers are not used. Without a handler tray-icon queues every one of
    // them (Windows sends a Move event per mouse move over the icon) in an unbounded
    // channel that nobody drains.
    TrayIconEvent::set_event_handler(Some(|_event: TrayIconEvent| {}));

    let mdns = match discovery::advertise(&app) {
        Ok(daemon) => Some(daemon),
        Err(e) => {
            log::error!("mDNS advertisement unavailable ({e:#}); phones can still use broadcast or a typed IP");
            None
        }
    };

    {
        let app = app.clone();
        std::thread::Builder::new()
            .name("orbit-pairing".into())
            .spawn(move || pairing::serve(tcp, app))
            .context("spawning pairing thread")?;
    }
    {
        let app = app.clone();
        std::thread::Builder::new()
            .name("orbit-control".into())
            .spawn(move || control::run(udp, app))
            .context("spawning control thread")?;
    }
    log::info!("listening on TCP/UDP {PORT}");

    let mut tray: Option<Tray> = None;
    let mut mdns = mdns;
    event_loop.run(move |event, _target, control_flow| {
        *control_flow = ControlFlow::Wait;
        match event {
            // tray-icon: on macOS the icon may only be created once the loop is running.
            Event::NewEvents(StartCause::Init) => match Tray::new(&app) {
                Ok(t) => tray = Some(t),
                Err(e) => log::error!("cannot create tray icon: {e:#}"),
            },
            Event::UserEvent(UiEvent::Refresh) => {
                if let Some(t) = tray.as_mut() {
                    t.refresh(&app);
                }
            }
            Event::UserEvent(UiEvent::Menu(menu_event)) => {
                let action = tray.as_ref().and_then(|t| t.action_for(&menu_event.id));
                match action {
                    Some(MenuAction::TogglePause) => {
                        let paused = app.toggle_pause();
                        log::info!("control {}", if paused { "paused" } else { "resumed" });
                        if let Some(t) = tray.as_mut() {
                            t.refresh(&app);
                        }
                    }
                    Some(MenuAction::ForgetAll) => {
                        match app.forget_all() {
                            Ok(()) => log::info!("forgot all paired devices"),
                            Err(e) => log::error!("cannot save configuration: {e:#}"),
                        }
                        if let Some(t) = tray.as_mut() {
                            t.refresh(&app);
                        }
                    }
                    Some(MenuAction::Quit) => {
                        shutdown(&app);
                        if let Some(daemon) = mdns.take() {
                            let _ = daemon.shutdown();
                        }
                        tray = None;
                        *control_flow = ControlFlow::Exit;
                    }
                    None => {}
                }
            }
            #[cfg(target_os = "macos")]
            Event::UserEvent(UiEvent::Prompt(prompt)) => pairing::run_prompt(prompt),
            _ => {}
        }
    });
}

/// Asks the control thread to release held input and waits briefly for it.
fn shutdown(app: &App) {
    log::info!("quitting");
    app.shutdown.store(true, Ordering::SeqCst);
    let deadline = Instant::now() + Duration::from_millis(500);
    while !app.released.load(Ordering::SeqCst) && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(10));
    }
}
