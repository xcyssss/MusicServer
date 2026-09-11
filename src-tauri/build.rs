fn main() {
    // The same PS5.1 helper is used by runtime services and release checks.
    // Only its digest is embedded; no build-machine path enters the executable.
    println!("cargo:rerun-if-changed=../web");
    for name in [
        "start_musicserver_ui.ps1",
        "watchdog_ui.ps1",
        "music_api.ps1",
        "wanted_worker.ps1",
        "daily_recommend.ps1",
        "register_daily_recommend.ps1",
        "MusicServer.Core.psm1",
        "MusicServer.Database.psm1",
        "MusicServer.Http.psm1",
        "MusicServer.State.psm1",
        "MusicServer.Providers.psm1",
        "MusicServer.Migration.psm1",
        "MusicServer.Identity.psm1",
    ] {
        println!("cargo:rerun-if-changed=../{name}");
    }
    let result = std::process::Command::new("powershell.exe")
        .args(["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", "Import-Module ../MusicServer.Identity.psm1 -Force; Get-MusicServerBuildIdentity -Root (Resolve-Path ..).Path"])
        .output().expect("compute runtime identity with Windows PowerShell");
    let marker = String::from_utf8(result.stdout).expect("UTF-8 identity");
    let marker = marker.trim();
    assert!(
        result.status.success()
            && marker.starts_with("musicserver-")
            && marker.len() == 76
            && marker[12..].bytes().all(|b| b.is_ascii_hexdigit()),
        "invalid runtime identity"
    );
    println!("cargo:rustc-env=MUSICSERVER_BUILD_ID={marker}");
    tauri_build::build()
}
