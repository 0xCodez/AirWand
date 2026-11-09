//! Pairing server (PROTOCOL.md §2): TCP 47821, newline-delimited JSON, one connection per
//! pairing attempt.
//!
//! 1. device → host `hello` (deviceId, name, platform, X25519 pub)
//! 2. host → device `hello` (hostId, name, os, ephemeral X25519 pub)
//! 3. both derive key + 6-digit code with HKDF-SHA256
//! 4. host asks the user (native dialog, 60 s timeout)
//! 5. host → device `paired` ok / denied / timeout; on success the key is persisted.

use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::mpsc::{self, RecvTimeoutError};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::{anyhow, bail, Context, Result};
use base64::engine::general_purpose::{STANDARD, STANDARD_NO_PAD};
use base64::Engine as _;
use serde::{Deserialize, Serialize};

use crate::app::{lock, App, UiEvent};
use crate::config::{id_hex, parse_id, PairedDevice};
use crate::crypto::{self, Handshake};
use crate::dialog;
use crate::protocol::{HOST_OS, PROTOCOL_VERSION};

const DECISION_TIMEOUT: Duration = Duration::from_secs(60);
const HELLO_TIMEOUT: Duration = Duration::from_secs(15);
const MAX_LINE: u64 = 8 * 1024;
const MAX_NAME_CHARS: usize = 64;

/// Only one pairing dialog at a time; further attempts wait their turn.
static PAIRING_TURN: Mutex<()> = Mutex::new(());

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct DeviceHello {
    t: String,
    v: u32,
    device_id: String,
    name: String,
    #[serde(default)]
    platform: String,
    #[serde(rename = "pub")]
    public_key: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct HostHello<'a> {
    t: &'static str,
    v: u8,
    host_id: String,
    name: &'a str,
    os: &'static str,
    #[serde(rename = "pub")]
    public_key: String,
}

#[derive(Serialize)]
struct Paired<'a> {
    t: &'static str,
    ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    reason: Option<&'a str>,
}

pub fn serve(listener: TcpListener, app: Arc<App>) {
    for stream in listener.incoming() {
        match stream {
            Ok(stream) => {
                let app = app.clone();
                std::thread::Builder::new()
                    .name("orbit-pairing-conn".into())
                    .spawn(move || {
                        let peer = stream.peer_addr().map(|a| a.to_string()).unwrap_or_else(|_| "?".into());
                        if let Err(e) = handle(stream, &app) {
                            log::warn!("pairing with {peer} failed: {e:#}");
                        }
                    })
                    .map(|_| ())
                    .unwrap_or_else(|e| log::error!("cannot spawn pairing thread: {e}"));
            }
            Err(e) => {
                log::warn!("pairing accept failed: {e}");
                std::thread::sleep(Duration::from_millis(100));
            }
        }
    }
}

fn decode_b64(s: &str) -> Option<Vec<u8>> {
    let s = s.trim();
    STANDARD.decode(s).or_else(|_| STANDARD_NO_PAD.decode(s)).ok()
}

/// Control, zero-width and bidi-override characters could make a name render misleadingly.
fn is_unsafe_char(c: char) -> bool {
    c.is_control()
        || matches!(c, '\u{200B}'..='\u{200F}' | '\u{202A}'..='\u{202E}' | '\u{2060}'..='\u{2069}' | '\u{FEFF}')
}

/// Strips unsafe characters and limits length so a hostile name cannot spoof the dialog.
fn sanitize_name(raw: &str) -> String {
    let cleaned: String = raw.chars().filter(|&c| !is_unsafe_char(c)).take(MAX_NAME_CHARS).collect();
    let trimmed = cleaned.trim();
    if trimmed.is_empty() {
        "Unnamed device".to_string()
    } else {
        trimmed.to_string()
    }
}

fn send_line<T: Serialize>(stream: &mut TcpStream, value: &T) -> Result<()> {
    let mut line = serde_json::to_vec(value)?;
    line.push(b'\n');
    stream.write_all(&line)?;
    stream.flush()?;
    Ok(())
}

fn send_result(stream: &mut TcpStream, ok: bool, reason: Option<&str>) -> Result<()> {
    send_line(stream, &Paired { t: "paired", ok, reason })
}

fn handle(mut stream: TcpStream, app: &App) -> Result<()> {
    stream.set_nodelay(true).ok();
    stream.set_read_timeout(Some(HELLO_TIMEOUT))?;
    stream.set_write_timeout(Some(Duration::from_secs(5)))?;

    // 1. Device hello.
    let mut line = String::new();
    {
        let mut reader = BufReader::new(stream.try_clone()?).take(MAX_LINE);
        reader.read_line(&mut line).context("reading hello")?;
    }
    if line.trim().is_empty() {
        bail!("connection closed before hello");
    }
    let hello: DeviceHello = serde_json::from_str(line.trim()).context("parsing hello")?;
    if hello.t != "hello" {
        bail!("expected hello, got {:?}", hello.t);
    }
    if hello.v != u32::from(PROTOCOL_VERSION) {
        let _ = send_result(&mut stream, false, Some("version"));
        bail!("unsupported protocol version {}", hello.v);
    }
    let device_id = parse_id(&hello.device_id).ok_or_else(|| anyhow!("invalid deviceId"))?;
    let peer_pub: [u8; 32] = decode_b64(&hello.public_key)
        .and_then(|v| v.try_into().ok())
        .ok_or_else(|| anyhow!("invalid X25519 public key"))?;
    let device_name = sanitize_name(&hello.name);
    let platform = match hello.platform.as_str() {
        "ios" | "android" => hello.platform.clone(),
        _ => String::new(),
    };

    // Wait for our turn before revealing a code, so codes and dialogs never interleave.
    let _turn = lock(&PAIRING_TURN);

    // 2. Host hello with a fresh ephemeral key.
    let host_id = app.host_id();
    let host_name = app.host_name();
    let handshake = Handshake::new();
    send_line(
        &mut stream,
        &HostHello {
            t: "hello",
            v: PROTOCOL_VERSION,
            host_id: id_hex(&host_id),
            name: &host_name,
            os: HOST_OS,
            public_key: STANDARD.encode(handshake.public_bytes()),
        },
    )?;

    // 3. Derive.
    let secrets = handshake.finish(peer_pub, &device_id, &host_id)?;
    let code = crypto::code_display(secrets.code);
    log::info!("pairing request from {device_name} ({}), code {code}", id_hex(&device_id));

    // 4. Ask the user.
    let answer = ask_user(app, &device_name, &code);
    let decision = answer.recv_timeout(DECISION_TIMEOUT);

    // 5. Reply and persist.
    match decision {
        Ok(true) => {
            app.add_paired(PairedDevice { id: device_id, name: device_name.clone(), platform, key: secrets.key })
                .context("saving paired device")?;
            send_result(&mut stream, true, None)?;
            log::info!("paired with {device_name}");
            app.notify(UiEvent::Refresh);
        }
        Ok(false) | Err(RecvTimeoutError::Disconnected) => {
            send_result(&mut stream, false, Some("denied"))?;
            log::info!("pairing with {device_name} denied");
        }
        Err(RecvTimeoutError::Timeout) => {
            send_result(&mut stream, false, Some("timeout"))?;
            log::info!("pairing with {device_name} timed out");
        }
    }
    Ok(())
}

/// Starts the confirmation dialog and returns the channel its answer arrives on.
fn ask_user(app: &App, device_name: &str, code: &str) -> mpsc::Receiver<bool> {
    let (tx, rx) = mpsc::channel();

    #[cfg(target_os = "macos")]
    {
        // AppKit: dialogs must run on the main thread → hand it to the event loop.
        app.notify(UiEvent::Prompt(crate::app::PairPrompt {
            device_name: device_name.to_string(),
            code: code.to_string(),
            deadline: std::time::Instant::now() + DECISION_TIMEOUT,
            reply: tx,
        }));
    }

    #[cfg(not(target_os = "macos"))]
    {
        let _ = app;
        let name = device_name.to_string();
        let code = code.to_string();
        let spawned = std::thread::Builder::new().name("orbit-pairing-dialog".into()).spawn(move || {
            let ok = dialog::confirm_pairing(&name, &code);
            let _ = tx.send(ok);
        });
        if let Err(e) = spawned {
            log::error!("cannot show pairing dialog: {e}");
        }
    }

    rx
}

/// Main-thread side of the macOS prompt.
#[cfg(target_os = "macos")]
pub fn run_prompt(prompt: crate::app::PairPrompt) {
    if std::time::Instant::now() >= prompt.deadline {
        return;
    }
    let ok = dialog::confirm_pairing(&prompt.device_name, &prompt.code);
    let _ = prompt.reply.send(ok);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_device_hello() {
        let json = r#"{"t":"hello","v":1,"deviceId":"000102030405060708090a0b0c0d0e0f","name":"iPhone 17 Pro","platform":"ios","pub":"e06Qm75//kTEZaIgA31gjuNYl9Me+XLwf3SJLLD3PxM="}"#;
        let h: DeviceHello = serde_json::from_str(json).unwrap();
        assert_eq!(h.t, "hello");
        assert_eq!(h.v, 1);
        assert_eq!(h.name, "iPhone 17 Pro");
        assert_eq!(h.platform, "ios");
        let key = decode_b64(&h.public_key).unwrap();
        assert_eq!(hex::encode(key), "7b4e909bbe7ffe44c465a220037d608ee35897d31ef972f07f74892cb0f73f13");
        assert!(parse_id(&h.device_id).is_some());
    }

    #[test]
    fn host_messages_match_protocol() {
        let hello = HostHello {
            t: "hello",
            v: 1,
            host_id: "ab".repeat(16),
            name: "Lev's MacBook",
            os: "mac",
            public_key: "AAAA".into(),
        };
        let v: serde_json::Value = serde_json::to_value(&hello).unwrap();
        assert_eq!(v["t"], "hello");
        assert_eq!(v["hostId"], "ab".repeat(16));
        assert_eq!(v["pub"], "AAAA");
        assert_eq!(v["os"], "mac");

        let ok = serde_json::to_string(&Paired { t: "paired", ok: true, reason: None }).unwrap();
        assert_eq!(ok, r#"{"t":"paired","ok":true}"#);
        let no = serde_json::to_string(&Paired { t: "paired", ok: false, reason: Some("timeout") }).unwrap();
        assert_eq!(no, r#"{"t":"paired","ok":false,"reason":"timeout"}"#);
    }

    #[test]
    fn names_are_sanitized() {
        assert_eq!(sanitize_name("  Pixel\n9\u{202e} "), "Pixel9");
        assert_eq!(sanitize_name(""), "Unnamed device");
        assert_eq!(sanitize_name(&"x".repeat(200)).chars().count(), MAX_NAME_CHARS);
    }
}
