# This Describe needs a LIVE MusicServer API plus this machine's library and
# lyrics_report.csv (git-ignored), so it can never pass on a clean CI checkout.
# Tagged RequiresLocalRuntime and excluded in .github/workflows/core-tests.yml.
Describe 'MusicServer web playback safeguards' -Tag @('RequiresLocalRuntime') {
    BeforeAll {
        $script:apiRoot = 'http://127.0.0.1:8787'
        $script:library = @(Invoke-RestMethod -Uri "$apiRoot/api/library" -TimeoutSec 10).items
        $script:suspectFile = '『菁华浮梦』10年前的古风歌有多美，用低吟的唱法品品.mp3'
        $script:suspect = $library | Where-Object { $_.title -eq [IO.Path]::GetFileNameWithoutExtension($suspectFile) } | Select-Object -First 1
        if (-not $script:suspect) {
            throw "Library is missing '$script:suspectFile'. This suite asserts against a live local library; skip it via -ExcludeTag RequiresLocalRuntime."
        }
    }

    It 'does not expose a known low-confidence lyric match as valid' {
        $report = Import-Csv -LiteralPath (Join-Path $PSScriptRoot '..\lyrics_report.csv') |
            Where-Object { $_.File -eq $suspectFile } | Select-Object -First 1
        $report.Status | Should Be 'SUSPECT'
        $lyrics = Invoke-RestMethod -Uri "$apiRoot$($suspect.lyrics_url)" -TimeoutSec 10
        $lyrics.available | Should Be $false
        $lyrics.quality | Should Be 'SUSPECT'
    }
}

# Static markup assertions. These read web/ files only and are safe on a clean checkout.
Describe 'MusicServer web UI safeguards' {

    It 'ships explicit previous and next controls with queue navigation' {
        $html = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\web\index.html') -Raw
        $js = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\web\app.js') -Raw
        $html | Should Match 'id="previous-button"'
        $html | Should Match 'id="next-button"'
        $js | Should Match 'function previousItem'
        $js | Should Match 'function nextItem'
    }

    It 'keeps the page fixed and scrolls only the music lists' {
        $css = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\web\styles.css') -Raw
        $js = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\web\app.js') -Raw
        $html = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\web\index.html') -Raw
        $css | Should Match '\.library-list\s*\{[^}]*overflow-y'
        $css | Should Match '\.recommendation-section \.track-list\s*\{[^}]*overflow-y'
        $css | Should Match 'html, body \{ height: 100%; overflow: hidden; \}'
        $js | Should Match 'function shuffled'
        $js | Should Match 'state\.librarySequence'
        $js | Should Match 'function setPlaybackMode'
        $js | Should Match 'function reshuffleLibrary'
        $js | Should Match "\$\('#shuffle-button'\)\.addEventListener"
        $html | Should Match 'id="shuffle-button"'
    }

    It 'ships a one-command launcher that serves the UI and maps the legacy recommendation route' {
        $launcherPath = Join-Path $PSScriptRoot '..\start_musicserver_ui.ps1'
        $launcher = Get-Content -LiteralPath $launcherPath -Raw
        $launcher | Should Match "UiPrefix = 'http://127\.0\.0\.1:8790/'"
        $launcher | Should Match "Send-StaticFile -Context \$context -RelativePath 'index\.html'"
        $launcher | Should Match "\^/api/recommendations/today"
        $launcher | Should Match "'/api/today'"
        $launcher | Should Match 'Proxy-ApiRequest'

        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($launcherPath, [ref]$tokens, [ref]$errors)
        @($errors).Count | Should Be 0
        (Test-Path -LiteralPath (Join-Path $PSScriptRoot '..\start_musicserver_ui.bat')) | Should Be $true
    }
}
