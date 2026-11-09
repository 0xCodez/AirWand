//! Discovery (PROTOCOL.md §1): mDNS/Bonjour advertisement of `_orbit._tcp` and the JSON
//! reply to the `ORBIT?1` UDP broadcast probe (the probe itself arrives on the control
//! socket, see control.rs).

use std::collections::HashMap;

use anyhow::{Context, Result};
use mdns_sd::{ServiceDaemon, ServiceInfo};
use serde::Serialize;

use crate::app::App;
use crate::config::id_hex;
use crate::protocol::{HOST_OS, PORT, PROTOCOL_VERSION, SERVICE_TYPE};

/// mDNS instance names are limited to 63 bytes.
fn instance_name(name: &str) -> String {
    let mut out = String::new();
    for c in name.chars().filter(|c| !c.is_control()) {
        if out.len() + c.len_utf8() > 63 {
            break;
        }
        out.push(c);
    }
    if out.trim().is_empty() {
        "Orbit".to_string()
    } else {
        out
    }
}

/// Our own `.local.` host label, derived from the hostId so it never collides with the
/// operating system's own mDNS host name.
fn mdns_host_name(host_id_hex: &str) -> String {
    format!("orbit-{}.local.", &host_id_hex[..12])
}

/// Registers the service; keep the returned daemon alive for as long as we advertise.
pub fn advertise(app: &App) -> Result<ServiceDaemon> {
    let host_id = id_hex(&app.host_id());
    let name = app.host_name();
    let daemon = ServiceDaemon::new().context("starting mDNS daemon")?;

    let mut txt = HashMap::new();
    txt.insert("id".to_string(), host_id.clone());
    txt.insert("name".to_string(), name.clone());
    txt.insert("os".to_string(), HOST_OS.to_string());
    txt.insert("v".to_string(), PROTOCOL_VERSION.to_string());

    // Empty address list + enable_addr_auto: answer with every interface address and follow
    // address changes (Wi-Fi roaming, VPNs coming up, ...).
    let info = ServiceInfo::new(SERVICE_TYPE, &instance_name(&name), &mdns_host_name(&host_id), "", PORT, txt)
        .context("building mDNS service info")?
        .enable_addr_auto();
    daemon.register(info).context("registering mDNS service")?;
    log::info!("advertising {SERVICE_TYPE} \"{name}\" on port {PORT}");
    Ok(daemon)
}

#[derive(Serialize)]
struct Here<'a> {
    t: &'static str,
    v: u8,
    id: &'a str,
    name: &'a str,
    os: &'static str,
    port: u16,
}

/// `{"t":"here","v":1,"id":"<hostId>","name":"Lev's MacBook","os":"mac","port":47821}`
pub fn here_message(host_id_hex: &str, name: &str) -> Vec<u8> {
    serde_json::to_vec(&Here { t: "here", v: PROTOCOL_VERSION, id: host_id_hex, name, os: HOST_OS, port: PORT })
        .expect("serializing a plain struct cannot fail")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn here_json_shape() {
        let msg = here_message(&"0f".repeat(16), "Lev's MacBook");
        let v: serde_json::Value = serde_json::from_slice(&msg).unwrap();
        assert_eq!(v["t"], "here");
        assert_eq!(v["v"], 1);
        assert_eq!(v["id"], "0f".repeat(16));
        assert_eq!(v["name"], "Lev's MacBook");
        assert_eq!(v["os"], HOST_OS);
        assert_eq!(v["port"], 47821);
    }

    #[test]
    fn instance_names_fit() {
        assert_eq!(instance_name("Lev's MacBook"), "Lev's MacBook");
        assert!(instance_name(&"Ж".repeat(100)).len() <= 63);
        assert_eq!(instance_name("\n"), "Orbit");
        assert_eq!(mdns_host_name(&"ab".repeat(16)), "orbit-abababababab.local.");
    }
}
