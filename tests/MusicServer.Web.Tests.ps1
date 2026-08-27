Describe 'MusicServer web playback safeguards' {
    BeforeAll {
        $script:apiRoot = 'http://127.0.0.1:8787'
        $script:library = @(Invoke-RestMethod -Uri "$apiRoot/api/library" -TimeoutSec 10).items
        $script:suspectFile = '『菁华浮梦』10年前的古风歌有多美，用低吟的唱法品品.mp3'
        $script:suspect = $library | Where-Object { $_.title -eq [IO.Path]::GetFileNameWithoutExtension($suspectFile) } | Select-Object -First 1
    }

    It 'does not expose a known low-confidence lyric match as valid' {
        $report = Import-Csv -LiteralPath (Join-Path $PSScriptRoot '..\lyrics_report.csv') |
            Where-Object { $_.File -eq $suspectFile } | Select-Object -First 1
        $report.Status | Should Be 'SUSPECT'
        $lyrics = Invoke-RestMethod -Uri "$apiRoot$($suspect.lyrics_url)" -TimeoutSec 10
        $lyrics.available | Should Be $false
        $lyrics.quality | Should Be 'SUSPECT'
    }

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
}
