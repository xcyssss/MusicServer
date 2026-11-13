//! An explicit sidecar makes a portable installation relocatable without guessing
//! data locations from the executable's ancestors or the caller's working directory.
use serde::Deserialize;
use std::fs;
use std::path::{Component, Path, PathBuf};

pub const CONFIG_FILE: &str = "musicserver.paths.json";
const DEFAULT_HOME: &str = "com.musicserver.desktop";

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Paths {
    schema: u32,
    app_home: String,
}

fn anchored(value: &str, base: &Path) -> Result<PathBuf, String> {
    let path = Path::new(value.trim());
    if value.trim().is_empty() || !base.is_absolute() {
        return Err("数据目录配置不能为空，且必须有明确的基准目录。".into());
    }
    if !path.is_absolute()
        && path
            .components()
            .any(|c| matches!(c, Component::Prefix(_) | Component::RootDir))
    {
        return Err(format!("数据目录不能使用依赖当前盘符的路径：{value}"));
    }
    let joined = if path.is_absolute() {
        path.to_path_buf()
    } else {
        base.join(path)
    };
    let mut normalized = PathBuf::new();
    for part in joined.components() {
        match part {
            Component::CurDir => {}
            Component::ParentDir => {
                normalized.pop();
            }
            other => normalized.push(other.as_os_str()),
        }
    }
    Ok(normalized)
}

fn existing(value: &str, base: &Path, source: &str) -> Result<PathBuf, String> {
    let path = anchored(value, base)?;
    if !path.is_dir() {
        return Err(format!(
            "找不到已配置的数据目录：{}。请恢复该目录或更新 {} 后重新启动。为保护原数据，本次启动已停止。",
            path.display(), source
        ));
    }
    Ok(path)
}

pub fn resolve(
    base: &Path,
    configured: Option<String>,
    pinned: Option<String>,
    local: Option<String>,
) -> Result<PathBuf, String> {
    let sidecar = base.join(CONFIG_FILE);
    match fs::read_to_string(&sidecar) {
        Ok(text) => {
            let paths: Paths = serde_json::from_str(text.trim_start_matches('\u{feff}'))
                .map_err(|e| format!("无法读取路径配置 {}：{e}", sidecar.display()))?;
            if paths.schema != 1 {
                return Err(format!("路径配置版本不支持：{}", sidecar.display()));
            }
            return existing(&paths.app_home, base, &sidecar.display().to_string());
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => return Err(format!("无法读取路径配置 {}：{e}", sidecar.display())),
    }
    if let Some(value) = configured.filter(|v| !v.trim().is_empty()) {
        return existing(&value, base, "MUSICSERVER_APP_HOME");
    }
    if let Some(value) = pinned.filter(|v| !v.trim().is_empty()) {
        return existing(&value, base, "注册表 AppHome 配置");
    }
    // Only an unconfigured first launch may create a new default home.
    Ok(local
        .filter(|v| !v.trim().is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(std::env::temp_dir)
        .join(DEFAULT_HOME))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    struct Fixture(PathBuf);
    impl Fixture {
        fn new() -> Self {
            static NEXT: AtomicUsize = AtomicUsize::new(0);
            let root = std::env::temp_dir().join(format!(
                "musicserver-paths-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir_all(root.join("程序")).unwrap();
            fs::create_dir_all(root.join("音乐 data")).unwrap();
            Self(root)
        }
        fn config(&self, text: &str) {
            fs::write(self.0.join("程序").join(CONFIG_FILE), text).unwrap();
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn portable_home_survives_parent_move_and_overrides_stale_machine_settings() {
        let mut f = Fixture::new();
        f.config(r#"{"schema":1,"app_home":"../音乐 data"}"#);
        fs::write(f.0.join("音乐 data/history.txt"), "keep").unwrap();
        let old = f.0.clone();
        let moved = old.with_extension("moved");
        fs::rename(&old, &moved).unwrap();
        f.0 = moved;
        let home = resolve(
            &f.0.join("程序"),
            Some(old.join("音乐 data").display().to_string()),
            Some("missing".into()),
            None,
        )
        .unwrap();
        assert_eq!(home, f.0.join("音乐 data"));
        assert_eq!(
            fs::read_to_string(home.join("history.txt")).unwrap(),
            "keep"
        );
        assert!(!old.exists());
    }

    #[test]
    fn missing_explicit_homes_never_create_or_fall_back() {
        let f = Fixture::new();
        let base = f.0.join("程序");
        for (configured, pinned) in [
            (Some("missing".into()), None),
            (None, Some("missing".into())),
        ] {
            assert!(resolve(&base, configured, pinned, Some(f.0.display().to_string())).is_err());
        }
        f.config(r#"{"schema":1,"app_home":"../missing"}"#);
        assert!(resolve(&base, Some(f.0.display().to_string()), None, None).is_err());
        assert!(!f.0.join("missing").exists());
        assert!(!base.join("missing").exists());
    }

    #[test]
    fn invalid_sidecar_fails_even_with_valid_environment() {
        let f = Fixture::new();
        for text in [
            "broken",
            r#"{"schema":2,"app_home":".."}"#,
            r#"{"schema":1,"app_home":" "}"#,
            r#"{"schema":1,"app_home":"..","typo":true}"#,
        ] {
            f.config(text);
            assert!(resolve(
                &f.0.join("程序"),
                Some(f.0.display().to_string()),
                None,
                None
            )
            .is_err());
        }
    }

    #[test]
    fn legacy_precedence_and_first_use_default_remain_supported() {
        let f = Fixture::new();
        let base = f.0.join("程序");
        assert_eq!(
            resolve(
                &base,
                Some("../音乐 data".into()),
                Some("missing".into()),
                None
            )
            .unwrap(),
            f.0.join("音乐 data")
        );
        assert_eq!(
            resolve(&base, None, Some(f.0.display().to_string()), None).unwrap(),
            f.0
        );
        assert_eq!(
            resolve(&base, None, None, Some(f.0.display().to_string())).unwrap(),
            f.0.join(DEFAULT_HOME)
        );
    }
}
