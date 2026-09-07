//! Validate the complete package before any writable runtime file is changed.
use serde::Deserialize;
use sha2::{Digest, Sha256};
use std::{collections::BTreeSet, fs, io, path::Path};

const REQUIRED: &[&str] = &[
    "start_musicserver_ui.ps1",
    "watchdog_ui.ps1",
    "music_api.ps1",
    "wanted_worker.ps1",
    "MusicServer.Core.psm1",
    "MusicServer.Database.psm1",
    "MusicServer.Http.psm1",
    "MusicServer.State.psm1",
    "MusicServer.Providers.psm1",
    "MusicServer.Identity.psm1",
    "web/app.js",
    "web/index.html",
    "web/styles.css",
    "tools/sqlite3.exe",
];

#[derive(Deserialize)]
struct Manifest {
    schema: u32,
    build_id: String,
    files: Vec<Entry>,
}

#[derive(Deserialize)]
struct Entry {
    path: String,
    size: u64,
    sha256: String,
}

fn invalid(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message)
}

fn managed(path: &str) -> bool {
    if path.contains('\\')
        || path.contains(':')
        || path
            .split('/')
            .any(|s| s.is_empty() || s == "." || s == "..")
    {
        return false;
    }
    REQUIRED.contains(&path) || path.starts_with("web/")
}

fn inventory(root: &Path, folder: &Path, names: &mut BTreeSet<String>) -> io::Result<()> {
    for entry in fs::read_dir(folder)? {
        let entry = entry?;
        let metadata = fs::symlink_metadata(entry.path())?;
        #[cfg(windows)]
        {
            use std::os::windows::fs::MetadataExt;
            if metadata.file_attributes() & 0x400 != 0 {
                return Err(invalid("runtime reparse point is not allowed"));
            }
        }
        if metadata.file_type().is_symlink() {
            return Err(invalid("runtime symlink is not allowed"));
        }
        if metadata.is_dir() {
            let relative = entry
                .path()
                .strip_prefix(root)
                .unwrap()
                .to_string_lossy()
                .replace('\\', "/");
            if relative != "web" && relative != "tools" && !relative.starts_with("web/") {
                return Err(invalid("unmanaged runtime directory"));
            }
            inventory(root, &entry.path(), names)?;
        } else {
            let name = entry
                .path()
                .strip_prefix(root)
                .map_err(|_| invalid("invalid runtime path"))?
                .to_string_lossy()
                .replace('\\', "/");
            if name != ".gitkeep" && name != "runtime-manifest.json" {
                names.insert(name);
            }
        }
    }
    Ok(())
}

pub fn verify(root: &Path, expected_identity: &str) -> io::Result<()> {
    let bytes = fs::read(root.join("runtime-manifest.json"))?;
    let manifest: Manifest =
        serde_json::from_slice(&bytes).map_err(|_| invalid("invalid runtime manifest"))?;
    if manifest.schema != 2 || manifest.build_id != expected_identity {
        return Err(invalid(
            "runtime manifest version or build identity mismatch",
        ));
    }
    let mut actual = BTreeSet::new();
    inventory(root, root, &mut actual)?;
    let mut declared = BTreeSet::new();
    let mut folded = BTreeSet::new();
    for entry in manifest.files {
        if !managed(&entry.path)
            || !folded.insert(entry.path.to_ascii_lowercase())
            || !declared.insert(entry.path.clone())
        {
            return Err(invalid("unsafe or duplicate runtime path"));
        }
        let path = root.join(&entry.path);
        if fs::metadata(&path)?.len() != entry.size {
            return Err(invalid("runtime size mismatch"));
        }
        let content = fs::read(path)?;
        let digest = format!("{:x}", Sha256::digest(&content));
        if digest != entry.sha256 {
            return Err(invalid("runtime content hash mismatch"));
        }
    }
    if actual != declared || REQUIRED.iter().any(|name| !declared.contains(*name)) {
        return Err(invalid(
            "runtime payload is missing or has undeclared files",
        ));
    }
    Ok(())
}

#[cfg(test)]
pub fn fixture(root: &Path, identity: &str) {
    fs::create_dir_all(root).unwrap();
    for name in REQUIRED {
        let path = root.join(name);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        if !path.exists() {
            fs::write(path, b"first").unwrap();
        }
    }
    let entries: Vec<_> = REQUIRED.iter().map(|name| {
        let content = fs::read(root.join(name)).unwrap();
        serde_json::json!({"path": name, "size": content.len(), "sha256": format!("{:x}", Sha256::digest(&content))})
    }).collect();
    fs::write(
        root.join("runtime-manifest.json"),
        serde_json::to_vec(
            &serde_json::json!({"schema": 2, "build_id": identity, "files": entries}),
        )
        .unwrap(),
    )
    .unwrap();
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn validates_before_writing_and_rejects_corruption_missing_extra_and_unsafe_files() {
        let root = std::env::temp_dir().join(format!(
            "musicserver-manifest-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fixture(&root, "current");
        verify(&root, "current").unwrap();
        assert!(verify(&root, "old").is_err());
        fs::write(root.join("web/app.js"), b"wrong").unwrap();
        assert!(verify(&root, "current").is_err());
        fixture(&root, "current");
        fs::write(root.join("cookies.txt"), b"private").unwrap();
        assert!(verify(&root, "current").is_err());
        fs::remove_file(root.join("cookies.txt")).unwrap();
        fs::remove_file(root.join("music_api.ps1")).unwrap();
        assert!(verify(&root, "current").is_err());
        assert!(!managed("web/../../music.db"));
        assert!(!managed("C:/user.db"));
        assert!(!managed("web/file:stream"));
        fs::remove_dir_all(root).unwrap();
    }
}
