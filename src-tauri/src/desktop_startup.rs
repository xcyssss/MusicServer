//! Desktop ownership and bounded recovery when legacy listeners fill the fixed ports.
use sha2::{Digest, Sha256};
use std::net::{Ipv4Addr, TcpListener};
use std::path::Path;

pub fn runtime_scope(home: &Path) -> String {
    let normalized = home
        .to_string_lossy()
        .replace('\\', "/")
        .trim_end_matches('/')
        .to_lowercase();
    format!("{:x}", Sha256::digest(normalized.as_bytes()))
}

pub fn vacant_pair() -> std::io::Result<(u16, u16)> {
    // Keep both bound until both numbers are known. HttpListener must bind them
    // itself after this function returns; startup still verifies identity and
    // bounds retries if another process wins that small bind race.
    let ui = TcpListener::bind((Ipv4Addr::LOCALHOST, 0))?;
    let api = TcpListener::bind((Ipv4Addr::LOCALHOST, 0))?;
    Ok((ui.local_addr()?.port(), api.local_addr()?.port()))
}

pub fn record(home: &Path, state: &str, message: &str, pair: Option<(u16, u16)>, build: &str) {
    let result = || -> std::io::Result<()> {
        let folder = home.join("logs");
        std::fs::create_dir_all(&folder)?;
        let report = serde_json::json!({
            "state":state, "message":message, "build":build,
            "ui_port":pair.map(|p|p.0), "api_port":pair.map(|p|p.1),
            "pid":std::process::id(),
            "at":std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_secs()
        });
        let pending = folder.join(format!("desktop-startup-{}.tmp", std::process::id()));
        std::fs::write(&pending, serde_json::to_vec(&report)?)?;
        std::fs::rename(pending, folder.join("desktop-startup.json"))
    };
    let _ = result(); // Diagnostics must not prevent startup.
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn vacant_pair_avoids_occupied_ports_and_uses_distinct_endpoints() {
        let occupied: Vec<_> = (0..6)
            .map(|_| TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap())
            .collect();
        let (ui, api) = vacant_pair().unwrap();
        assert_ne!(ui, api);
        assert!(occupied.iter().all(|s| {
            let port = s.local_addr().unwrap().port();
            port != ui && port != api
        }));
    }

    #[test]
    fn services_from_another_home_have_a_different_scope() {
        assert_eq!(
            runtime_scope(Path::new("C:\\Music\\")),
            runtime_scope(Path::new("c:/music"))
        );
        assert_ne!(
            runtime_scope(Path::new("C:/Music")),
            runtime_scope(Path::new("C:/Other"))
        );
    }
}
