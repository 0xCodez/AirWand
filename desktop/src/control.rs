//! Control channel (PROTOCOL.md §3): one UDP socket on 47821 carries
//! * the unencrypted `ORBIT?1` discovery probe (answered with the JSON `here` message),
//! * encrypted control packets from paired devices.
//!
//! Input is injected by the motion thread (`smoother.rs`), which owns the `Injector` and
//! eases MOVE / AIM at ~240 Hz. This thread is the safety watchdog: the socket has a short
//! read timeout, and on every wake-up devices silent for 3 s are marked disconnected and
//! every held button / key is released (and pending motion dropped).

use std::collections::HashMap;
use std::io::ErrorKind;
use std::net::{SocketAddr, UdpSocket};
use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::time::{Duration, Instant};

use crate::app::{App, UiEvent};
use crate::config::id_hex;
use crate::crypto;
use crate::discovery;
use crate::input;
use crate::protocol::{
    self, DeviceId, Message, Plaintext, ReplayGuard, CONNECTED_WINDOW_MS, DISCOVERY_PROBE, HOST_OS_CODE,
    MAX_PACKET_LEN,
};
use crate::smoother::Smoother;

const TICK: Duration = Duration::from_millis(100);
const CONNECTED_WINDOW: Duration = Duration::from_millis(CONNECTED_WINDOW_MS);
/// How often the macOS Accessibility status is re-checked for the tray.
const PERMISSION_RECHECK: Duration = Duration::from_secs(5);

struct DeviceSession {
    name: String,
    replay: ReplayGuard,
    last_seen: Instant,
    connected: bool,
}

struct Control {
    app: Arc<App>,
    socket: UdpSocket,
    injector: Smoother,
    sessions: HashMap<DeviceId, DeviceSession>,
    /// The host's own counters for PONG packets (independent of the devices').
    host_session: u32,
    host_seq: u32,
    was_paused: bool,
    permission_checked: Instant,
}

pub fn run(socket: UdpSocket, app: Arc<App>) {
    if let Err(e) = socket.set_read_timeout(Some(TICK)) {
        log::error!("cannot set UDP read timeout: {e}");
    }
    let injector = match Smoother::spawn(app.invert_scroll()) {
        Ok(s) => s,
        Err(e) => {
            log::error!("cannot start the motion thread: {e}");
            app.released.store(true, Ordering::SeqCst);
            return;
        }
    };
    let mut ctl = Control {
        app,
        socket,
        injector,
        sessions: HashMap::new(),
        host_session: crypto::random_u32(),
        host_seq: 0,
        was_paused: false,
        permission_checked: Instant::now(),
    };
    ctl.run_loop();
}

impl Control {
    fn run_loop(&mut self) {
        // Larger than any UDP datagram: on Windows a datagram that does not fit fails the
        // receive with WSAEMSGSIZE, which would otherwise stall the loop (oversized packets
        // are dropped below instead).
        let mut buf = vec![0u8; 65_536];
        loop {
            if self.app.shutdown.load(Ordering::SeqCst) {
                self.injector.shutdown(); // releases held input, then joins the thread
                self.app.released.store(true, Ordering::SeqCst);
                return;
            }

            let paused = self.app.is_paused();
            if paused && !self.was_paused {
                self.injector.release_all();
            }
            self.was_paused = paused;

            match self.socket.recv_from(&mut buf) {
                Ok((n, from)) => self.on_datagram(&buf[..n], from),
                // Timeouts are our watchdog tick. ConnectionReset: Windows reports ICMP
                // "port unreachable" for an earlier send on the next recv; harmless.
                Err(e)
                    if matches!(
                        e.kind(),
                        ErrorKind::WouldBlock | ErrorKind::TimedOut | ErrorKind::Interrupted | ErrorKind::ConnectionReset
                    ) => {}
                Err(e) => {
                    log::warn!("UDP receive error: {e}");
                    std::thread::sleep(TICK);
                }
            }

            self.watchdog();
            self.recheck_permission();
        }
    }

    fn on_datagram(&mut self, data: &[u8], from: SocketAddr) {
        if data == DISCOVERY_PROBE {
            let reply = discovery::here_message(&id_hex(&self.app.host_id()), &self.app.host_name());
            if let Err(e) = self.socket.send_to(&reply, from) {
                log::debug!("cannot answer discovery probe from {from}: {e}");
            }
            return;
        }
        if data.len() > MAX_PACKET_LEN {
            return;
        }
        // Anything that is not a well-formed packet from a paired device that authenticates
        // is dropped silently, without a reply.
        let Ok(device_id) = protocol::peek_device_id(data) else { return };
        let Some((key, name)) = self.app.lookup(&device_id) else { return };
        let Ok(plain) = protocol::open(data, &key) else { return };

        let now = Instant::now();
        let session = self.sessions.entry(device_id).or_insert_with(|| DeviceSession {
            name: name.clone(),
            replay: ReplayGuard::default(),
            last_seen: now,
            connected: false,
        });
        if !session.replay.accept(plain.session, plain.seq) {
            return;
        }
        session.last_seen = now;
        session.name = name;
        let mut changed = false;
        if !session.connected && plain.msg != Message::Bye {
            session.connected = true;
            changed = true;
            log::info!("{} connected from {from}", session.name);
        }

        match plain.msg {
            Message::Ping => self.send_pong(&device_id, &key, plain.seq, from),
            Message::Bye => {
                self.injector.release_all();
                if session.connected {
                    session.connected = false;
                    changed = true;
                }
                log::info!("{} said goodbye", session.name);
            }
            Message::Pong { .. } => {}
            ref msg => {
                if !self.app.is_paused() {
                    self.injector.send(msg.clone());
                }
            }
        }

        if changed {
            self.publish_connections();
        }
    }

    fn send_pong(&mut self, device_id: &DeviceId, key: &protocol::SessionKey, echo_seq: u32, to: SocketAddr) {
        self.host_seq = self.host_seq.wrapping_add(1);
        if self.host_seq == 0 {
            // Start a new host session instead of wrapping (keeps seq strictly increasing).
            self.host_session = crypto::random_u32();
            self.host_seq = 1;
        }
        let plain = Plaintext {
            session: self.host_session,
            seq: self.host_seq,
            msg: Message::Pong { echo_seq, os: HOST_OS_CODE },
        };
        let packet = protocol::seal(device_id, key, &plain, &crypto::random_bytes());
        if let Err(e) = self.socket.send_to(&packet, to) {
            log::debug!("cannot send PONG to {to}: {e}");
        }
    }

    fn watchdog(&mut self) {
        let now = Instant::now();
        let mut changed = false;
        let mut went_quiet = false;
        for s in self.sessions.values_mut() {
            if s.connected && now.duration_since(s.last_seen) > CONNECTED_WINDOW {
                s.connected = false;
                changed = true;
                went_quiet = true;
                log::info!("{} went quiet", s.name);
            }
        }
        if went_quiet {
            self.injector.release_all();
        }
        if changed {
            self.publish_connections();
        }
    }

    fn publish_connections(&self) {
        let mut names: Vec<String> = self.sessions.values().filter(|s| s.connected).map(|s| s.name.clone()).collect();
        names.sort();
        self.app.set_connected(names);
        self.app.notify(UiEvent::Refresh);
    }

    fn recheck_permission(&mut self) {
        if self.permission_checked.elapsed() < PERMISSION_RECHECK {
            return;
        }
        self.permission_checked = Instant::now();
        let ok = input::check_permission(false);
        if self.app.input_permitted.swap(ok, Ordering::Relaxed) != ok {
            log::info!("input permission is now {}", if ok { "granted" } else { "missing" });
            self.app.notify(UiEvent::Refresh);
        }
    }
}
