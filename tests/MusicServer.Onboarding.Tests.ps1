$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'MusicServer.RuntimeFixture.ps1')

Describe 'First-use state and safe starter recommendations' {
    BeforeEach {
        $script:GuideFixture = New-MusicServerRuntimeFixture -ProjectRoot $ProjectRoot
        Import-Module (Join-Path $ProjectRoot 'MusicServer.Onboarding.psm1') -Force
    }
    AfterEach { Remove-MusicServerRuntimeFixture -Fixture $script:GuideFixture }

    It 'prepares fourteen playable identities without a library or download work' {
        Initialize-StarterRecommendationsDb | Should Be $true
        $rows = @(Get-TodayRecommendationsDb)
        $rows.Count | Should Be 14
        @($rows | Select-Object -ExpandProperty netease_id -Unique).Count | Should Be 14
        $track = Get-CanonicalTrackDb -TrackId $rows[0].track_id
        @($track.identifiers).Count | Should Be 1
        $track.preview_sources[0].media_url | Should Match '^https://music.163.com/'
        @(Get-WantedTracksDb).Count | Should Be 0
        Initialize-StarterRecommendationsDb | Should Be $false
        @(Get-TodayRecommendationsDb).Count | Should Be 14
    }

    It 'does not replace an existing day even if the initial empty check loses a race' {
        Initialize-StarterRecommendationsDb | Out-Null
        $before = @(Get-TodayRecommendationsDb)
        $new = New-CanonicalTrack -Title 'not inserted' -Artist 'fixture'
        $row = [pscustomobject]@{id='race';track_id=$new.id;title=$new.title;rank=1}
        $result = Save-DailyRecommendationsDb -Recommendations @($row) -Tracks @($new) -OnlyIfEmpty
        $result.Skipped | Should Be $true
        @(Get-TodayRecommendationsDb).Count | Should Be 14
        (Get-TodayRecommendationsDb)[0].track_id | Should Be $before[0].track_id
        (Get-CanonicalTrackDb -TrackId $new.id) | Should BeNullOrEmpty
    }

    It 'keeps existing preferences and resumes the selected song after restart' {
        Set-LibraryDisplayModeDb -Mode raw
        Initialize-StarterRecommendationsDb | Out-Null
        $id = (Get-TodayRecommendationsDb)[0].track_id
        Set-OnboardingStateDb -Phase download -Dismissed $false -TrackId $id -AutoLyrics $false
        $state = Get-OnboardingStateDb -Config $script:GuideFixture.Config
        $state.normalize | Should Be $false
        $state.auto_lyrics | Should Be $false
        $state.phase | Should Be 'download'
        $state.track.track_id | Should Be $id
        Set-OnboardingStateDb -Phase done -Dismissed $true -Normalize $true
        (Get-OnboardingStateDb -Config $script:GuideFixture.Config).dismissed | Should Be $true
        Get-LibraryDisplayModeDb | Should Be 'canonical'
    }

    It 'does not show an unsolicited guide to an existing listener' {
        Initialize-StarterRecommendationsDb | Out-Null
        $id = (Get-TodayRecommendationsDb)[0].track_id
        Write-FeedbackDb -TrackId $id -FeedbackType LIKE -Source fixture -Value true
        $state = Get-OnboardingStateDb -Config $script:GuideFixture.Config
        $state.dismissed | Should Be $true
        $state.normalize | Should Be $false
    }

    It 'reports missing download dependencies without claiming readiness' {
        $cfg = $script:GuideFixture.Config.PSObject.Copy()
        $cfg.YtDlp = ''; $cfg.FFmpeg = ''; $cfg.FFprobe = ''
        $state = Get-OnboardingStateDb -Config $cfg
        $state.download_ready | Should Be $false
        @($state.missing_components).Count | Should Be 3
    }
}

Describe 'Automatic lyrics with local precedence and owned cache' {
    BeforeEach {
        $script:GuideFixture = New-MusicServerRuntimeFixture -ProjectRoot $ProjectRoot
        Import-Module (Join-Path $ProjectRoot 'MusicServer.Providers.psm1') -Force
        Initialize-MusicServerDatabase -DbPath $script:GuideFixture.Database -SqliteExe $script:GuideFixture.Config.Sqlite
        $script:LyricFile = Join-Path $script:GuideFixture.Config.MusicDir '陈鸿宇《理想三旬》.mp3'
        [IO.File]::WriteAllText($script:LyricFile, 'fixture')
    }
    AfterEach { Remove-MusicServerRuntimeFixture -Fixture $script:GuideFixture }

    It 'finds exact names in Lyrics but prefers the adjacent original' {
        $dir = Join-Path $script:GuideFixture.Config.MusicDir 'Lyrics'
        New-Item -ItemType Directory -Path $dir | Out-Null
        $nearby = Join-Path $dir '陈鸿宇《理想三旬》.lrc'
        [IO.File]::WriteAllText($nearby, '[00:01]nearby')
        Find-MusicServerLyricFile -File $script:LyricFile | Should Be $nearby
        $adjacent = [IO.Path]::ChangeExtension($script:LyricFile, '.lrc')
        [IO.File]::WriteAllText($adjacent, '[00:01]original')
        Find-MusicServerLyricFile -File $script:LyricFile | Should Be $adjacent
        Find-MusicServerLyricFile -File ($script:LyricFile + 'different.mp3') | Should BeNullOrEmpty
    }

    It 'allows one fetch and refuses a stale owner after the audio file changes' {
        Claim-LocalLyricLookupDb -PathKey fixture -Fingerprint original -Owner first | Should Be $true
        Claim-LocalLyricLookupDb -PathKey fixture -Fingerprint original -Owner second | Should Be $false
        Claim-LocalLyricLookupDb -PathKey fixture -Fingerprint replaced -Owner second | Should Be $true
        Save-LocalLyricCacheDb -PathKey fixture -Owner first -Status READY -Text 'wrong recording'
        (Get-LocalLyricCacheDb -PathKey fixture -Fingerprint replaced).status | Should Be 'FETCHING'
        Save-LocalLyricCacheDb -PathKey fixture -Owner second -Status READY -Text 'right recording'
        (Get-LocalLyricCacheDb -PathKey fixture -Fingerprint replaced).text | Should Be 'right recording'
    }

    It 'caches reliable lyrics, preserves offline reuse, and bounds uncertain lookup retries' {
        Mock Test-ProviderRequestAvailable { $true } -ModuleName MusicServer.Providers
        Mock Claim-ProviderRequest { $true } -ModuleName MusicServer.Providers
        Mock Search-NeteaseCandidate { if ($Track.title -eq '理想三旬') { [pscustomobject]@{metadata=@{netease_id='31445772'}} } } -ModuleName MusicServer.Providers
        Mock Invoke-RestMethod { [pscustomobject]@{lrc=[pscustomobject]@{lyric='[00:01]fixture lyric'}} } -ModuleName MusicServer.Providers
        $result = Resolve-MusicServerLocalLyrics -Config $script:GuideFixture.Config -File $script:LyricFile
        $result.available | Should Be $true
        Set-AppSettingDb -Key auto_lyrics -Value false
        (Resolve-MusicServerLocalLyrics -Config $script:GuideFixture.Config -File $script:LyricFile).text | Should Be '[00:01]fixture lyric'
        Assert-MockCalled Invoke-RestMethod -ModuleName MusicServer.Providers -Times 1 -Exactly -Scope It
        Test-Path ([IO.Path]::ChangeExtension($script:LyricFile, '.lrc')) | Should Be $false
        Set-AppSettingDb -Key auto_lyrics -Value true
        $unavailable = Join-Path $script:GuideFixture.Config.MusicDir '陈鸿宇《测试歌曲》.mp3'
        [IO.File]::WriteAllText($unavailable, 'fixture')
        $null = Resolve-MusicServerLocalLyrics -Config $script:GuideFixture.Config -File $unavailable
        $null = Resolve-MusicServerLocalLyrics -Config $script:GuideFixture.Config -File $unavailable
        Assert-MockCalled Search-NeteaseCandidate -ModuleName MusicServer.Providers -Times 2 -Exactly -Scope It
        $unknown = Join-Path $script:GuideFixture.Config.MusicDir 'UnknownSong.mp3'
        [IO.File]::WriteAllText($unknown, 'fixture')
        (Resolve-MusicServerLocalLyrics -Config $script:GuideFixture.Config -File $unknown).available | Should Be $false
        Assert-MockCalled Invoke-RestMethod -ModuleName MusicServer.Providers -Times 1 -Exactly -Scope It
    }
}
