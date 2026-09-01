# This Describe needs a LIVE MusicServer UI host plus this machine's library and
# lyrics_report.csv (git-ignored), so it can never pass on a clean CI checkout.
# Tagged RequiresLocalRuntime and excluded in .github/workflows/core-tests.yml.
Describe 'MusicServer web playback safeguards' -Tag @('RequiresLocalRuntime') {
    BeforeAll {
        $script:uiRoot = 'http://127.0.0.1:8790'
        $script:library = @(Invoke-RestMethod -Uri "$uiRoot/api/library" -TimeoutSec 10).items
        $script:suspectFile = '『菁华浮梦』10年前的古风歌有多美，用低吟的唱法品品.mp3'
        $script:suspect = $library | Where-Object {
            $displayTitle = if ($_.title) { [string]$_.title } else { [string]$_.name }
            $displayTitle -eq [IO.Path]::GetFileNameWithoutExtension($suspectFile)
        } | Select-Object -First 1
        if (-not $script:suspect) {
            throw "Library is missing '$suspectFile'. This suite asserts against a live local library; skip it via -ExcludeTag RequiresLocalRuntime."
        }
    }

    It 'does not expose a known low-confidence lyric match as valid' {
        $report = Import-Csv -LiteralPath (Join-Path $PSScriptRoot '..\lyrics_report.csv') |
            Where-Object { $_.File -eq $suspectFile } | Select-Object -First 1
        $report.Status | Should Be 'SUSPECT'
        $lyrics = Invoke-RestMethod -Uri "$uiRoot$($suspect.lyrics_url)" -TimeoutSec 10
        $lyrics.available | Should Be $false
        $lyrics.quality | Should Be 'SUSPECT'
    }
}

# Static markup assertions. These read web/launcher files only and are safe on a clean checkout.
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

    It 'normalizes Navidrome name to title and counts the real local library' {
        $js = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\web\app.js') -Raw
        $js | Should Match 'normalizeLibraryItem'
        $js | Should Match 'title:\s*item\?\.title\s*\|\|\s*item\?\.name'
        $js | Should Match 'items\.map\(normalizeLibraryItem\)'
        $js | Should Match "\$\('#local-count'\)\.textContent\s*=\s*state\.library\.length"
    }

    It 'hydrates old recommendation metadata and recovers the Netease playback id before giving up' {
        $js = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\web\app.js') -Raw
        $js | Should Match 'function neteasePreviewFromTrack'
        $js | Should Match 'function neteasePreviewFromRecommendation'
        $js | Should Match 'recommendation\.netease_id'
        $js | Should Match 'recommendation\.playback_source'
        $js | Should Match 'music\.163\.com/song/media/outer/url'
        $js | Should Match 'function resolvePlaybackSource'
        $js | Should Match 'function hydrateRecommendationPlayback'
        $js | Should Match '/api/tracks/'
        $js | Should Match 'encodeURIComponent\(item\.track_id\)'
        $js | Should Match 'await hydrateRecommendationPlayback\(item\)'
        $js | Should Match 'source = resolvePlaybackSource\(item\)'
    }

    It 'ships a one-command launcher that serves the UI and maps the legacy recommendation route' {
        $launcherPath = Join-Path $PSScriptRoot '..\start_musicserver_ui.ps1'
        $launcher = Get-Content -LiteralPath $launcherPath -Raw
        $launcher | Should Match "UiPrefix = 'http://127\.0\.0\.1:8790/'"
        $launcher | Should Match 'Send-IndexHtml'
        $launcher | Should Match "\^/api/recommendations/today"
        $launcher | Should Match "'/api/today'"
        $launcher | Should Match 'Proxy-ApiRequest'

        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($launcherPath, [ref]$tokens, [ref]$errors)
        @($errors).Count | Should Be 0
        (Test-Path -LiteralPath (Join-Path $PSScriptRoot '..\start_musicserver_ui.bat')) | Should Be $true
    }

    It 'runs silently and stops owned services after the last browser client closes' {
        $launcher = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\start_musicserver_ui.ps1') -Raw
        $bat = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\start_musicserver_ui.bat') -Raw
        $bat | Should Match '-WindowStyle Hidden'
        $launcher | Should Match '-WindowStyle Hidden'
        $launcher | Should Match 'RedirectStandardOutput'
        $launcher | Should Match 'RedirectStandardError'
        $launcher | Should Match '/ui/heartbeat'
        $launcher | Should Match '/ui/goodbye'
        $launcher | Should Match 'Register-ClientHeartbeat'
        $launcher | Should Match 'Remove-StaleClients'
        $launcher | Should Match 'Should-AutoStop'
        $launcher | Should Match 'BeginGetContext'
        $launcher | Should Not Match '\$listener\.GetContext\('
        $launcher | Should Match 'Stop-Process -Id \$ApiProcess\.Id'
    }

    It 'serves the local library through a safe sqlite invocation instead of the broken flattened argument list' {
        $launcher = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\start_musicserver_ui.ps1') -Raw
        $launcher | Should Match 'function Invoke-NavidromeSqliteJson'
        $launcher | Should Match '& \$sqlite.*-readonly.*-json.*\$Config\.NdDb.*\$Sql'
        $launcher | Should Match "'/api/library'"
        $launcher | Should Match 'function Send-LibraryStream'
        $launcher | Should Match 'function Send-LibraryLyrics'
        $launcher | Should Match 'Get-UiLibrary'
    }
}
