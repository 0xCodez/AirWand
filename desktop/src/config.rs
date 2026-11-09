//! Persistent host state: hostId, host name and paired devices, stored as JSON in the
//! platform config dir (`~/Library/Application Support/Orbit/config.json`,
//! `%APPDATA%\Orbit\config.json`).

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

use anyhow::{anyhow, Context, Result};
use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine as _;
use serde::{Deserialize, Serialize};

use crate::crypto;
use crate::protocol::{DeviceId, HostId, SessionKey, ID_LEN, KEY_LEN};

const APP_DIR: &str = "Orbit";
const FILE_NAME: &str = "config.json";

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ConfigFile {
    host_id: String,
    host_name: String,
    #[serde(default)]
    invert_scroll: bool,
    #[serde(default)]
    paired: Vec<PairedFile>,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PairedFile {
    device_id: String,
    name: String,
    #[serde(default)]
    platform: String,
    /// base64 of the 32-byte ChaCha20-Poly1305 key
    key: String,
}

#[derive(Debug, Clone)]
pub struct PairedDevice {
    pub id: DeviceId,
    pub name: String,
    pub platform: String,
    pub key: SessionKey,
}

#[derive(Debug)]
pub struct Config {
    pub host_id: HostId,
    pub host_name: String,
    /// Flips both scroll axes (escape hatch if an OS setting double-inverts).
    pub invert_scroll: bool,
    pub paired: Vec<PairedDevice>,
    path: PathBuf,
}

pub fn config_dir() -> Result<PathBuf> {
    let base = dirs::config_dir().ok_or_else(|| anyhow!("no platform config directory"))?;
    Ok(base.join(APP_DIR))
}

pub fn parse_id(hex_str: &str) -> Option<DeviceId> {
    let mut id = [0u8; ID_LEN];
    if hex_str.len() != ID_LEN * 2 {
        return None;
    }
    hex::decode_to_slice(hex_str, &mut id).ok()?;
    Some(id)
}

pub fn id_hex(id: &[u8; ID_LEN]) -> String {
    hex::encode(id)
}

fn default_host_name() -> String {
    #[cfg(target_os = "macos")]
    {
        // The user-facing "Computer Name" ("Lev's MacBook Pro"), not the DNS host name.
        if let Ok(out) = std::process::Command::new("/usr/sbin/scutil").args(["--get", "ComputerName"]).output() {
            if out.status.success() {
                let name = String::from_utf8_lossy(&out.stdout).trim().to_string();
                if !name.is_empty() {
                    return name;
                }
            }
        }
    }
    let raw = gethostname::gethostname().to_string_lossy().to_string();
    let name = raw.trim().trim_end_matches(".local").to_string();
    if name.is_empty() {
        "My Computer".to_string()
    } else {
        name
    }
}

impl Config {
    pub fn load_or_create() -> Result<Self> {
        let dir = config_dir()?;
        create_private_dir(&dir)?;
        let path = dir.join(FILE_NAME);
        if path.exists() {
            match Self::load(&path) {
                Ok(cfg) => return Ok(cfg),
                Err(e) => {
                    let backup = dir.join("config.json.bad");
                    log::error!("config {} is unreadable ({e:#}); moving it to {}", path.display(), backup.display());
                    let _ = fs::rename(&path, &backup);
                }
            }
        }
        let cfg = Config {
            host_id: crypto::random_bytes::<ID_LEN>(),
            host_name: default_host_name(),
            invert_scroll: false,
            paired: Vec::new(),
            path,
        };
        cfg.save()?;
        log::info!("created new host identity {} ({})", id_hex(&cfg.host_id), cfg.host_name);
        Ok(cfg)
    }

    fn load(path: &Path) -> Result<Self> {
        let text = fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))?;
        let file: ConfigFile = serde_json::from_str(&text).context("parsing config JSON")?;
        let host_id = parse_id(&file.host_id).ok_or_else(|| anyhow!("invalid hostId"))?;
        let mut paired = Vec::new();
        for p in file.paired {
            let Some(id) = parse_id(&p.device_id) else {
                log::warn!("skipping paired device with invalid id {:?}", p.device_id);
                continue;
            };
            let key_bytes = match B64.decode(p.key.as_bytes()) {
                Ok(k) if k.len() == KEY_LEN => k,
                _ => {
                    log::warn!("skipping paired device {} with invalid key", p.name);
                    continue;
                }
            };
            let mut key = [0u8; KEY_LEN];
            key.copy_from_slice(&key_bytes);
            paired.push(PairedDevice { id, name: p.name, platform: p.platform, key });
        }
        let host_name = if file.host_name.trim().is_empty() { default_host_name() } else { file.host_name };
        Ok(Config { host_id, host_name, invert_scroll: file.invert_scroll, paired, path: path.to_path_buf() })
    }

    pub fn save(&self) -> Result<()> {
        let file = ConfigFile {
            host_id: id_hex(&self.host_id),
            host_name: self.host_name.clone(),
            invert_scroll: self.invert_scroll,
            paired: self
                .paired
                .iter()
                .map(|d| PairedFile {
                    device_id: id_hex(&d.id),
                    name: d.name.clone(),
                    platform: d.platform.clone(),
                    key: B64.encode(d.key),
                })
                .collect(),
        };
        let json = serde_json::to_string_pretty(&file)?;
        let tmp = self.path.with_extension("json.tmp");
        {
            let mut f = open_private_file(&tmp)?;
            f.write_all(json.as_bytes())?;
            f.sync_all()?;
        }
        fs::rename(&tmp, &self.path).with_context(|| format!("writing {}", self.path.display()))?;
        Ok(())
    }

    pub fn find(&self, id: &DeviceId) -> Option<&PairedDevice> {
        self.paired.iter().find(|d| &d.id == id)
    }

    /// Adds a device or replaces the key/name of an already known deviceId.
    pub fn upsert(&mut self, device: PairedDevice) {
        if let Some(existing) = self.paired.iter_mut().find(|d| d.id == device.id) {
            *existing = device;
        } else {
            self.paired.push(device);
        }
    }

    pub fn forget_all(&mut self) {
        self.paired.clear();
    }
}

#[cfg(unix)]
fn create_private_dir(dir: &Path) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;
    fs::create_dir_all(dir).with_context(|| format!("creating {}", dir.display()))?;
    fs::set_permissions(dir, fs::Permissions::from_mode(0o700))?;
    Ok(())
}

#[cfg(not(unix))]
fn create_private_dir(dir: &Path) -> Result<()> {
    // %APPDATA% is already private to the user account.
    fs::create_dir_all(dir).with_context(|| format!("creating {}", dir.display()))?;
    Ok(())
}

#[cfg(unix)]
fn open_private_file(path: &Path) -> Result<fs::File> {
    use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
    let f = fs::OpenOptions::new().write(true).create(true).truncate(true).mode(0o600).open(path)?;
    // `mode` only applies on creation; enforce it for pre-existing files too.
    f.set_permissions(fs::Permissions::from_mode(0o600))?;
    Ok(f)
}

#[cfg(not(unix))]
fn open_private_file(path: &Path) -> Result<fs::File> {
    Ok(fs::OpenOptions::new().write(true).create(true).truncate(true).open(path)?)
}

/// Log file used by release builds on Windows, where there is no console.
#[cfg(all(windows, not(debug_assertions)))]
pub fn open_log_file() -> Option<fs::File> {
    let dir = config_dir().ok()?;
    fs::create_dir_all(&dir).ok()?;
    let path = dir.join("orbit.log");
    // Keep it small: start over once it passes 1 MiB.
    let too_big = fs::metadata(&path).map(|m| m.len() > 1 << 20).unwrap_or(false);
    let mut opts = fs::OpenOptions::new();
    opts.create(true);
    if too_big {
        opts.write(true).truncate(true);
    } else {
        opts.append(true);
    }
    opts.open(path).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn id_parsing() {
        let id = [0xabu8; 16];
        let s = id_hex(&id);
        assert_eq!(s.len(), 32);
        assert_eq!(parse_id(&s), Some(id));
        assert_eq!(parse_id(&s.to_uppercase()), Some(id));
        assert_eq!(parse_id("abcd"), None);
        assert_eq!(parse_id(&"zz".repeat(16)), None);
    }

    #[test]
    fn save_and_load_round_trip() {
        let dir = std::env::temp_dir().join(format!("orbit-test-{}", hex::encode(crypto::random_bytes::<6>())));
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join(FILE_NAME);
        let mut cfg = Config {
            host_id: [1u8; 16],
            host_name: "Test Mac".into(),
            invert_scroll: false,
            paired: vec![],
            path: path.clone(),
        };
        cfg.upsert(PairedDevice { id: [2u8; 16], name: "Phone".into(), platform: "ios".into(), key: [3u8; 32] });
        cfg.upsert(PairedDevice { id: [2u8; 16], name: "Phone 2".into(), platform: "ios".into(), key: [4u8; 32] });
        assert_eq!(cfg.paired.len(), 1, "re-pairing replaces");
        cfg.save().unwrap();
        let loaded = Config::load(&path).unwrap();
        assert_eq!(loaded.host_id, [1u8; 16]);
        assert_eq!(loaded.paired.len(), 1);
        assert_eq!(loaded.paired[0].name, "Phone 2");
        assert_eq!(loaded.paired[0].key, [4u8; 32]);
        let _ = fs::remove_dir_all(&dir);
    }
}
