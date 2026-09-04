$ProjectRoot = Split-Path -Parent $PSScriptRoot

Describe 'MusicServer Tauri desktop shell' {
    It 'uses Tauri v2 and the shared web directory' {
        $config = ConvertFrom-Json -InputObject (Get-Content -LiteralPath (Join-Path $ProjectRoot 'src-tauri\tauri.conf.json') -Raw)
        $config.'$schema' | Should Match 'schema.tauri.app/config/2'
        $config.build.devUrl | Should Match '127\.0\.0\.1:8790'
        $config.build.frontendDist | Should Be '../web'
        (Get-Content -LiteralPath (Join-Path $ProjectRoot 'src-tauri\Cargo.toml') -Raw) | Should Match 'tauri = \{ version = "2"'
    }

    It 'rejects stale UI/API services and carries the smoke verifier' {
        $main = Get-Content -LiteralPath (Join-Path $ProjectRoot 'src-tauri\src\main.rs') -Raw
        $web = Get-Content -LiteralPath (Join-Path $ProjectRoot 'web\app.js') -Raw
        $api = Get-Content -LiteralPath (Join-Path $ProjectRoot 'music_api.ps1') -Raw
        $smoke = Get-Content -LiteralPath (Join-Path $ProjectRoot 'tests\verify_tauri_desktop.ps1') -Raw

        $main | Should Match 'BUILD_MARKER'
        $main | Should Match 'service_is_current'
        $main | Should Match 'FALLBACK_PAIRS'
        $main | Should Match '-UiPrefix'
        $main | Should Match '-ApiPrefix'
        $web | Should Match 'musicserver-listening-stats-v2'
        $api | Should Match "BuildMarker = 'musicserver-listening-stats-v2'"
        $smoke | Should Match 'CloseLaunchedApp'
        $smoke | Should Match 'ServicesStopped'
    }
}
