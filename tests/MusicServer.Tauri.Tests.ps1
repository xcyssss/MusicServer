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
        $web | Should Match 'musicserver-single-page-v3'
        $api | Should Match "BuildMarker = 'musicserver-single-page-v3'"
        $smoke | Should Match 'CloseLaunchedApp'
        $smoke | Should Match 'ServicesStopped'
    }

    It 'packages a writable portable runtime instead of embedding the source-tree path' {
        $configText = Get-Content -LiteralPath (Join-Path $ProjectRoot 'src-tauri\tauri.conf.json') -Raw
        $config = ConvertFrom-Json -InputObject $configText
        $main = Get-Content -LiteralPath (Join-Path $ProjectRoot 'src-tauri\src\main.rs') -Raw
        $prepare = Get-Content -LiteralPath (Join-Path $ProjectRoot 'scripts\prepare_tauri_runtime.ps1') -Raw

        $config.build.beforeBuildCommand | Should Match 'prepare_tauri_runtime\.ps1'
        @($config.bundle.resources) -join ' ' | Should Match 'resources/runtime'
        $main | Should Not Match 'CARGO_MANIFEST_DIR'
        $main | Should Match 'LOCALAPPDATA'
        $main | Should Match 'stage_runtime'
        $main | Should Match 'MUSICSERVER_SQLITE'
        $prepare | Should Match 'start_musicserver_ui\.ps1'
        $prepare | Should Match 'music_api\.ps1'
        $prepare | Should Match 'wanted_worker\.ps1'
        $prepare | Should Match 'sqlite3\.exe'
        $prepare | Should Not Match 'cookies\.txt'
    }

    It 'keeps installed CI smoke and desktop service markers in sync with the served UI' {
        $web = Get-Content -LiteralPath (Join-Path $ProjectRoot 'web\app.js') -Raw -Encoding UTF8
        $marker = [regex]::Match($web, "MUSICSERVER_BUILD_MARKER\s*=\s*'([^']+)'").Groups[1].Value
        [string]::IsNullOrWhiteSpace($marker) | Should Be $false
        foreach ($relative in @('music_api.ps1', 'src-tauri\src\main.rs', 'tests\verify_tauri_desktop.ps1', '.github\workflows\core-tests.yml')) {
            $text = Get-Content -LiteralPath (Join-Path $ProjectRoot $relative) -Raw -Encoding UTF8
            $actual = [regex]::Match($text, '(?i)(?:BuildMarker|BUILD_MARKER)(?:\s*:\s*&str)?\s*=\s*[''"]([^''"]+)[''"]').Groups[1].Value
            $actual | Should Be $marker
        }
    }

    It 'stages an executable runtime containing the shared HTTP input module' {
        $tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        $packageRoot = [IO.Path]::GetFullPath((Join-Path $tempParent ('musicserver_package_' + [guid]::NewGuid().ToString('N'))))
        if (-not $packageRoot.StartsWith($tempParent, [StringComparison]::OrdinalIgnoreCase)) { throw 'Package fixture escaped the temporary directory.' }
        try {
            & (Join-Path $ProjectRoot 'scripts\prepare_tauri_runtime.ps1') -ProjectRoot $ProjectRoot -Destination $packageRoot | Out-Null
            $manifest = Get-Content -LiteralPath (Join-Path $packageRoot 'runtime-manifest.json') -Raw | ConvertFrom-Json
            ($manifest.runtime_files -contains 'MusicServer.Http.psm1') | Should Be $true
            foreach ($relative in $manifest.runtime_files) { (Test-Path -LiteralPath (Join-Path $packageRoot $relative) -PathType Leaf) | Should Be $true }
            Import-Module (Join-Path $packageRoot 'MusicServer.Http.psm1') -Force
            $stream = New-Object IO.MemoryStream(,[Text.Encoding]::UTF8.GetBytes('{}'))
            try {
                $request = [pscustomobject]@{ Headers = @{}; ContentLength64 = 2; InputStream = $stream }
                (Read-MusicServerJsonRequest -Request $request).Text | Should Be '{}'
            } finally { $stream.Dispose() }
        } finally {
            Remove-Module MusicServer.Http -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $packageRoot) { Remove-Item -LiteralPath $packageRoot -Recurse -Force }
        }
    }
}
