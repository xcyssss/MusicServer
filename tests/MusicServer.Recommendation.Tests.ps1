<##
    Hardening v2 Phase 4 recommendation state tests.

    Every test uses a fresh scratch root and real sqlite3.exe. The suite does
    not call the network, yt-dlp, ffprobe, Bilibili, Navidrome, or production
    state.
##>

$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $ProjectRoot 'MusicServer.Core.psm1') -Force
Import-Module (Join-Path $ProjectRoot 'MusicServer.Database.psm1') -Force
Import-Module (Join-Path $ProjectRoot 'MusicServer.State.psm1') -Force
Import-Module (Join-Path $ProjectRoot 'MusicServer.Migration.psm1') -Force

$script:RecommendationTestRoot = $null
$script:RecommendationTestConfig = $null
$script:RecommendationApiProcess = $null

function New-RecommendationTestTrack {
    param([string]$Title, [string]$Artist = '测试艺术家', [int]$Duration = 180)
    return (New-CanonicalTrack -Title $Title -Artist $Artist -Duration $Duration -Status 'REMOTE')
}

function New-RecommendationTestRow {
    param(
        [Parameter(Mandatory)][psobject]$Track,
        [Parameter(Mandatory)][string]$Date,
        [Parameter(Mandatory)][int]$Rank,
        [string]$NeteaseId = '',
        [string]$RecId = ''
    )
    if (-not $NeteaseId) { $NeteaseId = "netease_$Rank" }
    if (-not $RecId) { $RecId = "rec_${Date}_$Rank" }
    return [pscustomobject]@{
        id = $RecId; date = $Date; track_id = [string]$Track.id; netease_id = $NeteaseId
        title = [string]$Track.title; artist = [string]$Track.artist; album = 'Phase4'
        duration = [int]$Track.duration; rank = $Rank; reason = 'fixture'; seed_source = 'fixture'
        playback_source = "netease:$NeteaseId"; preview_sources = @(); liked = $false
        created_at = Get-NowIso; updated_at = Get-NowIso
    }
}

function Initialize-RecommendationScratchDb {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('musicserver_recommendation_' + [guid]::NewGuid().ToString('N'))
    $script:RecommendationOldAppHome = [Environment]::GetEnvironmentVariable('MUSICSERVER_APP_HOME', 'Process')
    [Environment]::SetEnvironmentVariable('MUSICSERVER_APP_HOME', $root)
    $cfg = New-MusicServerConfig -Root $ProjectRoot -AppHome $root
    Initialize-MusicServerState -Config $cfg
    $db = Join-Path $cfg.StateDir 'musicserver.db'
    Initialize-MusicServerDatabase -DbPath $db -SqliteExe $cfg.Sqlite
    Initialize-MusicServerSchema
    $script:RecommendationTestRoot = $root
    $script:RecommendationTestConfig = $cfg
}

function Add-FeedbackValue {
    param([string]$TrackId, [string]$Type, [string]$Value, [string]$Source = 'test')
    Write-FeedbackDb -TrackId $TrackId -FeedbackType $Type -Source $Source -Value $Value
}

function Get-SeedForTrack {
    param([string]$TrackId)
    return @(Get-RecommendationSeedCandidatesDb -SeedCount 25 -RandomSeed 7 | Where-Object { [string]$_.TrackId -eq $TrackId }) | Select-Object -First 1
}

function Get-RecommendationTestPowerShell {
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        return (Get-Command powershell.exe -ErrorAction Stop).Source
    }
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($pwsh) { return $pwsh.Source }
    return (Get-Command powershell.exe -ErrorAction Stop).Source
}

function Start-RecommendationTestApi {
    param([Parameter(Mandatory)][string]$Root)
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = [int]$listener.LocalEndpoint.Port
    $listener.Stop()
    $prefix = "http://127.0.0.1:$port/"
    $log = Join-Path $Root 'recommendation_api.log'
    $err = Join-Path $Root 'recommendation_api.err.log'
    $args = @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $ProjectRoot 'music_api.ps1'),'-Prefix',$prefix,'-Root',$Root)
    $process = Start-Process -FilePath (Get-RecommendationTestPowerShell) -ArgumentList $args -WindowStyle Hidden -PassThru -RedirectStandardOutput $log -RedirectStandardError $err
    $script:RecommendationApiProcess = $process
    $deadline = [DateTime]::UtcNow.AddSeconds(40)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (Test-Path -LiteralPath $log) {
            $text = Get-Content -LiteralPath $log -Raw -ErrorAction SilentlyContinue
            if ($text -match 'API v2 ready') { return $prefix.TrimEnd('/') }
        }
        if ($process.HasExited) { break }
        Start-Sleep -Milliseconds 200
    }
    $errText = if (Test-Path -LiteralPath $err) { Get-Content -LiteralPath $err -Raw -ErrorAction SilentlyContinue } else { '' }
    throw "scratch API failed to start: $errText"
}

function Stop-RecommendationTestApi {
    if ($script:RecommendationApiProcess) {
        try {
            if (-not $script:RecommendationApiProcess.HasExited) {
                & taskkill.exe /PID $script:RecommendationApiProcess.Id /T /F 2>$null | Out-Null
                $script:RecommendationApiProcess.WaitForExit(5000) | Out-Null
            }
        } catch {}
        try { $script:RecommendationApiProcess.Dispose() } catch {}
        $script:RecommendationApiProcess = $null
    }
}

function Invoke-RecommendationTestHttp {
    param([Parameter(Mandatory)][string]$BaseUrl, [Parameter(Mandatory)][string]$Method, [Parameter(Mandatory)][string]$Path)
    $request = [System.Net.HttpWebRequest]::Create($BaseUrl + $Path)
    $request.Method = $Method
    $request.Timeout = 20000
    $request.ReadWriteTimeout = 20000
    $request.ContentType = 'application/json; charset=utf-8'
    if ($request.GetType().GetProperty('ContentLength64')) { $request.ContentLength64 = 0 } else { $request.ContentLength = 0 }
    try {
        $response = $request.GetResponse()
        $stream = $response.GetResponseStream()
        $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8)
        $text = $reader.ReadToEnd()
        $status = [int]$response.StatusCode
        $reader.Dispose(); $response.Dispose()
        return [pscustomobject]@{ Status = $status; Json = ($text | ConvertFrom-Json) }
    } catch [System.Net.WebException] {
        throw $_
    }
}

Describe 'MusicServer Hardening v2 - Recommendation State' {
    BeforeEach {
        Initialize-RecommendationScratchDb
    }

    AfterEach {
        Stop-RecommendationTestApi
        [Environment]::SetEnvironmentVariable('MUSICSERVER_APP_HOME', $script:RecommendationOldAppHome)
        if ($script:RecommendationTestRoot -and (Test-Path -LiteralPath $script:RecommendationTestRoot)) {
            Remove-Item -LiteralPath $script:RecommendationTestRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        $script:RecommendationTestRoot = $null
        $script:RecommendationTestConfig = $null
        $script:RecommendationOldAppHome = $null
    }

    It 'assembles recommendations with four reads and preserves latest feedback and missing wanted rows' {
        $date = Get-TodayDate
        $tracks = @(); $rows = @()
        foreach ($rank in 1..25) {
            $track = New-RecommendationTestTrack -Title "Batch $rank"
            $row = New-RecommendationTestRow -Track $track -Date $date -Rank $rank
            $tracks += $track; $rows += $row
        }
        Save-DailyRecommendationsDb -Recommendations $rows -Tracks $tracks -Date $date | Out-Null
        $lastId = [string]$track.id
        Write-FeedbackDb -TrackId $lastId -FeedbackType 'LIKE'
        Write-FeedbackDb -TrackId $lastId -FeedbackType 'UNLIKE'
        Write-FeedbackDb -TrackId $lastId -FeedbackType 'SKIP'
        $before = Get-MusicServerSqliteInvocationCount
        $batch = @(Get-TodayRecommendationBatchDb -Date $date)
        ((Get-MusicServerSqliteInvocationCount) - $before) | Should Be 4
        $batch.Count | Should Be 25
        $batch[-1].Feedback | Should Be 'UNLIKE'
        $batch[-1].Wanted | Should BeNullOrEmpty
        $batch[-1].Track.title | Should Be 'Batch 25'
        $batch[-1].Recommendation.rank | Should Be 25
        $before = Get-MusicServerSqliteInvocationCount
        @(Get-TodayRecommendationBatchDb -Date '1900-01-01').Count | Should Be 0
        ((Get-MusicServerSqliteInvocationCount) - $before) | Should Be 1
    }

    It 'turns explicit LIKE into a weight 5 positive seed' {
        $track = New-RecommendationTestTrack -Title 'Like Seed'
        Save-CanonicalTrackDb -Track $track | Out-Null
        Add-FeedbackValue -TrackId $track.id -Type 'LIKE' -Value 'true' -Source 'music_api'
        $seed = Get-SeedForTrack -TrackId $track.id
        $seed.Source | Should Be 'explicit_like'
        $seed.Weight | Should Be 5
    }

    It 'accepts all supported string forms of a positive LIKE' {
        foreach ($value in @('true','1','yes')) {
            $track = New-RecommendationTestTrack -Title "String LIKE $value"
            Save-CanonicalTrackDb -Track $track | Out-Null
            Add-FeedbackValue -TrackId $track.id -Type 'LIKE' -Value $value -Source 'music_api'
            $seed = Get-SeedForTrack -TrackId $track.id
            $seed.Source | Should Be 'explicit_like'
            $seed.Weight | Should Be 5
        }
    }

    It 'does not treat UNLIKE as a positive seed' {
        $track = New-RecommendationTestTrack -Title 'Unlike Seed'
        Save-CanonicalTrackDb -Track $track | Out-Null
        Add-FeedbackValue -TrackId $track.id -Type 'UNLIKE' -Value 'false' -Source 'music_api'
        @(Get-RecommendationSeedCandidatesDb -SeedCount 25) | Where-Object { $_.TrackId -eq $track.id } | Should BeNullOrEmpty
    }

    It 'does not treat DISPLAY as a positive seed' {
        $track = New-RecommendationTestTrack -Title 'Display Seed'
        Save-CanonicalTrackDb -Track $track | Out-Null
        Add-FeedbackValue -TrackId $track.id -Type 'DISPLAY' -Value 'true' -Source 'legacy_json'
        @(Get-RecommendationSeedCandidatesDb -SeedCount 25) | Where-Object { $_.TrackId -eq $track.id } | Should BeNullOrEmpty
    }

    It 'keeps one hundred neutral DISPLAY rows out of seed selection' {
        $track = New-RecommendationTestTrack -Title 'Neutral History'
        Save-CanonicalTrackDb -Track $track | Out-Null
        for ($i = 1; $i -le 100; $i++) { Add-FeedbackValue -TrackId $track.id -Type 'DISPLAY' -Value "display:$i" -Source 'legacy_json' }
        @(Get-RecommendationSeedCandidatesDb -SeedCount 25) | Where-Object { $_.TrackId -eq $track.id } | Should BeNullOrEmpty
    }

    It 'turns accepted feedback into a weight 4 seed' {
        $track = New-RecommendationTestTrack -Title 'Accepted Seed'
        Save-CanonicalTrackDb -Track $track | Out-Null
        Add-FeedbackValue -TrackId $track.id -Type 'ACCEPTED' -Value '{"title":"Accepted Seed","artist":"测试艺术家","netease_id":"a1","positive":true}' -Source 'legacy_accepted_csv'
        $seed = Get-SeedForTrack -TrackId $track.id
        $seed.Source | Should Be 'accepted'
        $seed.Weight | Should Be 4
    }

    It 'turns a positive Navidrome star into a weight 5 seed' {
        $track = New-RecommendationTestTrack -Title 'Star Seed'
        Save-CanonicalTrackDb -Track $track | Out-Null
        Add-FeedbackValue -TrackId $track.id -Type 'NAVIDROME_STAR' -Value '1' -Source 'navidrome'
        $seed = Get-SeedForTrack -TrackId $track.id
        $seed.Source | Should Be 'navidrome_star'
        $seed.Weight | Should Be 5
    }

    It 'uses the library fallback at weight 1' {
        $track = New-RecommendationTestTrack -Title '弱发现种子'
        Add-FeedbackValue -TrackId $track.id -Type 'LIBRARY_FALLBACK' -Value '{"title":"弱发现种子","artist":"测试艺术家","positive":true}' -Source 'legacy_lyrics_report'
        $seed = @(Get-RecommendationSeedCandidatesDb -SeedCount 25 -RandomSeed 7 | Where-Object { $_.Title -eq '弱发现种子' }) | Select-Object -First 1
        $seed.Source | Should Be 'library_fallback'
        $seed.Weight | Should Be 1
    }

    It 'seeds a fresh install from the local library when no preference exists' {
        $seed = @(Get-RecommendationSeedCandidatesDb -SeedCount 25 -LibraryFallback @('霜雪千年 - 双笙&封茗囧菌') -RandomSeed 7) | Select-Object -First 1
        $seed.Source | Should Be 'library_fallback'
        $seed.Weight | Should Be 1
        $seed.Title | Should Be '霜雪千年'
        $seed.Artist | Should Be '双笙&封茗囧菌'
    }

    It 'keeps the local library fallback out of a pool that already has taste signals' {
        $track = New-RecommendationTestTrack -Title 'Explicit Seed'
        Save-CanonicalTrackDb -Track $track | Out-Null
        Add-FeedbackValue -TrackId $track.id -Type 'LIKE' -Value 'true' -Source 'music_api'
        $seeds = @(Get-RecommendationSeedCandidatesDb -SeedCount 25 -LibraryFallback @('霜雪千年 - 双笙&封茗囧菌') -RandomSeed 7)
        @($seeds | Where-Object { $_.Source -eq 'library_fallback' }).Count | Should Be 0
    }

    It 'seeds from structured library rows and keeps their resolved artist' {
        # The launcher passes rows, not "title - artist" strings, so the seed keeps
        # the singer that artist resolution worked out instead of the uploader.
        $seed = @(Get-RecommendationSeedCandidatesDb -SeedCount 25 -LibraryFallback @(
            [pscustomobject]@{ Title = '胡萝卜须'; Artist = '许嵩'; File = 'c:\m\a.mp3'; LibraryId = 'library-A' }
        ) -RandomSeed 7) | Select-Object -First 1
        $seed.Source | Should Be 'library_fallback'
        $seed.Title | Should Be '胡萝卜须'
        $seed.Artist | Should Be '许嵩'
    }

    It 'does not parse the string False as a positive LIKE' {
        $track = New-RecommendationTestTrack -Title 'False Like'
        Save-CanonicalTrackDb -Track $track | Out-Null
        Add-FeedbackValue -TrackId $track.id -Type 'LIKE' -Value 'False' -Source 'legacy_json'
        @(Get-RecommendationSeedCandidatesDb -SeedCount 25) | Where-Object { $_.TrackId -eq $track.id } | Should BeNullOrEmpty
    }

    It 'keeps independent feedback facts but exposes the strongest source' {
        $track = New-RecommendationTestTrack -Title 'Mixed Feedback'
        Save-CanonicalTrackDb -Track $track | Out-Null
        Add-FeedbackValue -TrackId $track.id -Type 'ACCEPTED' -Value 'true' -Source 'test'
        Add-FeedbackValue -TrackId $track.id -Type 'LIKE' -Value 'yes' -Source 'music_api'
        Add-FeedbackValue -TrackId $track.id -Type 'DISPLAY' -Value 'display' -Source 'daily_recommendation'
        $facts = @(Get-RecommendationFeedbackDb -TrackId $track.id)
        $facts.Count | Should Be 3
        $seed = Get-SeedForTrack -TrackId $track.id
        $seed.Source | Should Be 'explicit_like'
        $seed.Weight | Should Be 5
    }

    It 'lets a later UNLIKE revoke an earlier explicit LIKE' {
        $track = New-RecommendationTestTrack -Title 'Like Then Unlike'
        Save-CanonicalTrackDb -Track $track | Out-Null
        Add-FeedbackValue -TrackId $track.id -Type 'LIKE' -Value 'true' -Source 'music_api'
        Add-FeedbackValue -TrackId $track.id -Type 'UNLIKE' -Value 'false' -Source 'music_api'
        @(Get-RecommendationSeedCandidatesDb -SeedCount 25) | Where-Object { $_.TrackId -eq $track.id } | Should BeNullOrEmpty
    }

    It 'uses feedback event time rather than insertion order for latest explicit state' {
        $track = New-RecommendationTestTrack -Title 'Out Of Order Facts'
        Save-CanonicalTrackDb -Track $track | Out-Null
        Invoke-MusicServerParamSql -Template 'INSERT INTO recommendation_feedback (track_id,feedback_type,source,value,created_at) VALUES (@tid,@type,@src,@value,@at);' -Params @{ tid = $track.id; type = 'UNLIKE'; src = 'music_api'; value = 'false'; at = '2026-08-29T00:00:00.0000000Z' } | Out-Null
        Invoke-MusicServerParamSql -Template 'INSERT INTO recommendation_feedback (track_id,feedback_type,source,value,created_at) VALUES (@tid,@type,@src,@value,@at);' -Params @{ tid = $track.id; type = 'LIKE'; src = 'legacy_json'; value = 'true'; at = '2026-08-01T00:00:00.0000000Z' } | Out-Null
        (Get-LatestRecommendationFeedbackDb -TrackId $track.id) | Should Be 'UNLIKE'
        Write-RecommendationDisplayFeedbackDb -TrackId $track.id -Date '2026-08-30' -Rank 1 -RecommendationId 'display_after_unlike' | Out-Null
        (Get-LatestRecommendationFeedbackDb -TrackId $track.id) | Should Be 'UNLIKE'
        $seed = Get-SeedForTrack -TrackId $track.id
        $seed | Should Be $null
    }

    It 'excludes recent recommendation rows and keeps the correct identity' {
        $track = New-RecommendationTestTrack -Title 'Recent Cooldown'
        $row = New-RecommendationTestRow -Track $track -Date '2026-08-17' -Rank 1 -NeteaseId 'cool_recent'
        Save-DailyRecommendationsDb -Recommendations @($row) -Tracks @($track) -Date '2026-08-17' | Out-Null
        $cooldown = @(Get-RecommendationCooldownTrackIdsDb -AsOfDate '2026-08-30' -CooldownDays 14)
        $cooldown.Count | Should Be 1
        $cooldown[0].track_id | Should Be $track.id
        $cooldown[0].netease_id | Should Be 'cool_recent'
    }

    It 'keeps a recommendation from fifteen days ago eligible' {
        $track = New-RecommendationTestTrack -Title 'Old Cooldown'
        $row = New-RecommendationTestRow -Track $track -Date '2026-08-15' -Rank 1
        Save-DailyRecommendationsDb -Recommendations @($row) -Tracks @($track) -Date '2026-08-15' | Out-Null
        @(Get-RecommendationCooldownTrackIdsDb -AsOfDate '2026-08-30' -CooldownDays 14) | Where-Object { $_.track_id -eq $track.id } | Should BeNullOrEmpty
    }

    It 'includes the existing fourteen-day boundary' {
        $track = New-RecommendationTestTrack -Title 'Boundary Cooldown'
        $row = New-RecommendationTestRow -Track $track -Date '2026-08-16' -Rank 1
        Save-DailyRecommendationsDb -Recommendations @($row) -Tracks @($track) -Date '2026-08-16' | Out-Null
        @(Get-RecommendationCooldownTrackIdsDb -AsOfDate '2026-08-30' -CooldownDays 14) | Where-Object { $_.track_id -eq $track.id } | Should Not BeNullOrEmpty
    }

    It 'ignores future recommendation dates safely' {
        $track = New-RecommendationTestTrack -Title 'Future Cooldown'
        $row = New-RecommendationTestRow -Track $track -Date '2026-09-01' -Rank 1
        Save-DailyRecommendationsDb -Recommendations @($row) -Tracks @($track) -Date '2026-09-01' | Out-Null
        @(Get-RecommendationCooldownTrackIdsDb -AsOfDate '2026-08-30' -CooldownDays 14) | Where-Object { $_.track_id -eq $track.id } | Should BeNullOrEmpty
    }

    It 'deduplicates a repeated DISPLAY feedback key' {
        $track = New-RecommendationTestTrack -Title 'Display Idempotent'
        Write-RecommendationDisplayFeedbackDb -TrackId $track.id -Date '2026-08-30' -Rank 1 -RecommendationId 'rec_one'
        Write-RecommendationDisplayFeedbackDb -TrackId $track.id -Date '2026-08-30' -Rank 1 -RecommendationId 'rec_one'
        @(Get-RecommendationFeedbackDb -TrackId $track.id -FeedbackType 'DISPLAY').Count | Should Be 1
    }

    It 'writes a complete day with canonical rows and DISPLAY rows' {
        $t1 = New-RecommendationTestTrack -Title '完整推荐一' -Artist '甲'
        $t2 = New-RecommendationTestTrack -Title '完整推荐二' -Artist '乙'
        $rows = @(
            (New-RecommendationTestRow -Track $t1 -Date '2026-08-30' -Rank 2)
            (New-RecommendationTestRow -Track $t2 -Date '2026-08-30' -Rank 1)
        )
        Save-DailyRecommendationsDb -Recommendations $rows -Tracks @($t1,$t2) -Date '2026-08-30' | Out-Null
        @(Get-TodayRecommendationsDb -Date '2026-08-30').Count | Should Be 2
        @(Get-RecommendationFeedbackDb -FeedbackType 'DISPLAY').Count | Should Be 2
        @(Get-EventsDb -Limit 20 | Where-Object { $_.event_type -eq 'RECOMMENDATION_DISPLAY' }).Count | Should Be 2
        (Get-CanonicalTrackDb -TrackId $t1.id) | Should Not Be $null
        (Get-TodayRecommendationsDb -Date '2026-08-30')[0].rank | Should Be 1
    }

    It 'rolls back the old complete day when a write fails mid-transaction' {
        $oldTrack = New-RecommendationTestTrack -Title '旧完整集合'
        $old = New-RecommendationTestRow -Track $oldTrack -Date '2026-08-30' -Rank 1 -NeteaseId 'old'
        Save-DailyRecommendationsDb -Recommendations @($old) -Tracks @($oldTrack) -Date '2026-08-30' | Out-Null
        $newTracks = @(); $newRows = @()
        for ($i = 1; $i -le 4; $i++) {
            $track = New-RecommendationTestTrack -Title "新集合$i" -Artist "艺术家$i"
            $newTracks += $track
            $newRows += New-RecommendationTestRow -Track $track -Date '2026-08-30' -Rank $i -NeteaseId "new$i"
        }
        try { Save-DailyRecommendationsDb -Recommendations $newRows -Tracks $newTracks -Date '2026-08-30' -FailAfterStep 8 | Out-Null } catch { $failed = $true }
        $failed | Should Be $true
        $after = @(Get-TodayRecommendationsDb -Date '2026-08-30')
        $after.Count | Should Be 1
        $after[0].netease_id | Should Be 'old'
        @(Get-RecommendationFeedbackDb -FeedbackType 'DISPLAY').Count | Should Be 1
    }

    It 'rolls back canonical and daily rows when DISPLAY feedback fails' {
        $track = New-RecommendationTestTrack -Title 'Feedback Failure'
        $row = New-RecommendationTestRow -Track $track -Date '2026-08-30' -Rank 1 -NeteaseId 'feedback_failure'
        try { Save-DailyRecommendationsDb -Recommendations @($row) -Tracks @($track) -Date '2026-08-30' -FailAfterStep 6 | Out-Null; $failed = $false } catch { $failed = $true }
        $failed | Should Be $true
        @(Get-TodayRecommendationsDb -Date '2026-08-30').Count | Should Be 0
        (Get-CanonicalTrackDb -TrackId $track.id) | Should Be $null
        @(Get-RecommendationFeedbackDb -FeedbackType 'DISPLAY').Count | Should Be 0
    }

    It 'rejects duplicate ranks before touching the existing day' {
        $oldTrack = New-RecommendationTestTrack -Title 'Duplicate Baseline'
        $old = New-RecommendationTestRow -Track $oldTrack -Date '2026-08-30' -Rank 1
        Save-DailyRecommendationsDb -Recommendations @($old) -Tracks @($oldTrack) -Date '2026-08-30' | Out-Null
        $newTrack = New-RecommendationTestTrack -Title 'Duplicate New'
        try {
            Save-DailyRecommendationsDb -Recommendations @(
                (New-RecommendationTestRow -Track $newTrack -Date '2026-08-30' -Rank 1 -NeteaseId 'dup1'),
                (New-RecommendationTestRow -Track $newTrack -Date '2026-08-30' -Rank 1 -NeteaseId 'dup2')
            ) -Tracks @($newTrack) -Date '2026-08-30' | Out-Null
            $failed = $false
        } catch { $failed = $true }
        $failed | Should Be $true
        (Get-TodayRecommendationsDb -Date '2026-08-30')[0].netease_id | Should Be 'netease_1'
    }

    It 'replaces a same-day set atomically and remains idempotent' {
        $t1 = New-RecommendationTestTrack -Title 'Replace One'
        $t2 = New-RecommendationTestTrack -Title 'Replace Two'
        Save-DailyRecommendationsDb -Recommendations @((New-RecommendationTestRow -Track $t1 -Date '2026-08-30' -Rank 1)) -Tracks @($t1) -Date '2026-08-30' | Out-Null
        Save-DailyRecommendationsDb -Recommendations @((New-RecommendationTestRow -Track $t2 -Date '2026-08-30' -Rank 1 -NeteaseId 'replacement')) -Tracks @($t2) -Date '2026-08-30' | Out-Null
        Save-DailyRecommendationsDb -Recommendations @((New-RecommendationTestRow -Track $t2 -Date '2026-08-30' -Rank 1 -NeteaseId 'replacement')) -Tracks @($t2) -Date '2026-08-30' | Out-Null
        @(Get-TodayRecommendationsDb -Date '2026-08-30').Count | Should Be 1
        @(Get-RecommendationFeedbackDb -FeedbackType 'DISPLAY').Count | Should Be 1
        (Get-TodayRecommendationsDb -Date '2026-08-30')[0].netease_id | Should Be 'replacement'
    }

    It 'round-trips Chinese, Japanese, and apostrophe metadata' {
        $track = New-RecommendationTestTrack -Title "月の歌 / 夜" -Artist "O'Brien さくら"
        $row = New-RecommendationTestRow -Track $track -Date '2026-08-30' -Rank 1 -NeteaseId 'unicode_1'
        Save-DailyRecommendationsDb -Recommendations @($row) -Tracks @($track) -Date '2026-08-30' | Out-Null
        $read = Get-TodayRecommendationsDb -Date '2026-08-30'
        $read[0].title | Should Be $track.title
        $read[0].artist | Should Be $track.artist
    }

    It 'keeps SQLite seed state when legacy JSON deliberately disagrees' {
        $track = New-RecommendationTestTrack -Title 'SQLite Wins Seed'
        Save-CanonicalTrackDb -Track $track | Out-Null
        Add-FeedbackValue -TrackId $track.id -Type 'LIKE' -Value 'true' -Source 'music_api'
        Write-StateCollection -Config $script:RecommendationTestConfig -Name recommendation_history -Items @([pscustomobject]@{ track_id=$track.id; title=$track.title; artist=$track.artist; liked=$false; date='2026-08-30' })
        $seed = Get-SeedForTrack -TrackId $track.id
        $seed.Source | Should Be 'explicit_like'
    }

    It 'keeps SQLite cooldown state when legacy JSON deliberately disagrees' {
        $track = New-RecommendationTestTrack -Title 'SQLite Wins Cooldown'
        $row = New-RecommendationTestRow -Track $track -Date '2026-08-29' -Rank 1 -NeteaseId 'cool_sqlite'
        Save-DailyRecommendationsDb -Recommendations @($row) -Tracks @($track) -Date '2026-08-29' | Out-Null
        Write-StateCollection -Config $script:RecommendationTestConfig -Name recommendation_history -Items @()
        @(Get-RecommendationCooldownTrackIdsDb -AsOfDate '2026-08-30') | Where-Object { $_.netease_id -eq 'cool_sqlite' } | Should Not BeNullOrEmpty
    }

    It 'keeps API recommendation reads on SQLite when JSON deliberately disagrees' {
        $trackC = New-RecommendationTestTrack -Title 'API SQLite C'
        $trackD = New-RecommendationTestTrack -Title 'API Legacy D'
        $rowC = New-RecommendationTestRow -Track $trackC -Date '2026-08-30' -Rank 1 -NeteaseId 'C'
        Save-DailyRecommendationsDb -Recommendations @($rowC) -Tracks @($trackC) -Date '2026-08-30' | Out-Null
        Write-StateCollection -Config $script:RecommendationTestConfig -Name recommendations -Items @((New-RecommendationTestRow -Track $trackD -Date '2026-08-30' -Rank 1 -NeteaseId 'D'))
        (Get-TodayRecommendationsDb -Date '2026-08-30')[0].netease_id | Should Be 'C'
        $apiSource = Get-Content -LiteralPath (Join-Path $ProjectRoot 'music_api.ps1') -Raw
        ($apiSource -match 'Get-TodayRecommendationsDb') | Should Be $true
        ($apiSource -match 'Read-StateCollection') | Should Be $false
    }

    It 'integrates a SQLite daily set with the real API and feedback seed flow' {
        $today = Get-TodayDate
        $track = New-RecommendationTestTrack -Title 'HTTP 推荐曲' -Artist 'HTTP 作者'
        $row = New-RecommendationTestRow -Track $track -Date $today -Rank 1 -NeteaseId 'http_1'
        Save-DailyRecommendationsDb -Recommendations @($row) -Tracks @($track) -Date $today | Out-Null
        $base = Start-RecommendationTestApi -Root $script:RecommendationTestRoot

        $listed = Invoke-RecommendationTestHttp -BaseUrl $base -Method 'GET' -Path '/api/today'
        $listed.Status | Should Be 200
        $listed.Json.items[0].title | Should Be 'HTTP 推荐曲'
        $listed.Json.items[0].rank | Should Be 1

        $like = Invoke-RecommendationTestHttp -BaseUrl $base -Method 'POST' -Path ("/api/tracks/{0}/like" -f $track.id)
        $like.Status | Should Be 200
        $like.Json.liked | Should Be $true
        $seed = Get-SeedForTrack -TrackId $track.id
        $seed.Source | Should Be 'explicit_like'

        $unlike = Invoke-RecommendationTestHttp -BaseUrl $base -Method 'DELETE' -Path ("/api/tracks/{0}/like" -f $track.id)
        $unlike.Status | Should Be 200
        $unlike.Json.liked | Should Be $false
        (Get-CanonicalTrackDb -TrackId $track.id).status | Should Be 'REMOTE'
        (Get-WantedItemDb -TrackId $track.id) | Should Be $null
    }

    It 'does not activate legacy migration during API startup' {
        $track = New-RecommendationTestTrack -Title 'API Does Not Migrate'
        Write-StateCollection -Config $script:RecommendationTestConfig -Name tracks -Items @($track)
        Write-StateCollection -Config $script:RecommendationTestConfig -Name recommendations -Items @(New-RecommendationTestRow -Track $track -Date '2026-08-30' -Rank 1)
        $null = Start-RecommendationTestApi -Root $script:RecommendationTestRoot
        $marker = @(Invoke-MusicServerParamSql -Template 'SELECT COUNT(*) AS cnt FROM migration_markers;' -Params @{})
        [int]$marker[0].cnt | Should Be 0
        $daily = @(Invoke-MusicServerParamSql -Template 'SELECT COUNT(*) AS cnt FROM daily_recommendations;' -Params @{})
        [int]$daily[0].cnt | Should Be 0
        @(Get-ChildItem -LiteralPath $script:RecommendationTestConfig.StateDir -Filter 'migration_backup_*' -ErrorAction SilentlyContinue).Count | Should Be 0
    }

    It 'imports recommendation display, explicit like, accepted, and rejected facts' {
        $track = New-RecommendationTestTrack -Title '迁移歌曲' -Artist '移行 कलाकार'
        Write-StateCollection -Config $script:RecommendationTestConfig -Name tracks -Items @($track)
        $legacy = New-RecommendationTestRow -Track $track -Date '2026-08-29' -Rank 1 -NeteaseId 'legacy_1'
        $legacy.liked = $true
        Write-StateCollection -Config $script:RecommendationTestConfig -Name recommendations -Items @($legacy)
        Write-StateCollection -Config $script:RecommendationTestConfig -Name recommendation_history -Items @($legacy)
        $legacyEvent = [ordered]@{ timestamp = '2026-08-29T00:00:00Z'; track_id = $track.id; provider = ''; event = 'TRACK_LIKED'; from_state = 'REMOTE'; to_state = 'WANTED'; attempt = 0; duration_ms = 0; result = 'SUCCESS'; error_type = ''; http_status = 0; message = 'legacy event' }
        [IO.File]::WriteAllText((Join-Path $script:RecommendationTestConfig.StateDir 'events.jsonl'), ((ConvertTo-Json $legacyEvent -Compress) + [Environment]::NewLine), (New-Object Text.UTF8Encoding($false)))
        $acceptedPath = Join-Path $script:RecommendationTestConfig.DataDir 'accepted.csv'
        $rejectedPath = Join-Path $script:RecommendationTestConfig.DataDir 'rejected.csv'
        @([pscustomobject]@{ AcceptedAt='2026-08-20'; NeteaseId='accepted_1'; Title='採用曲'; Artist='アーティスト'; File='x.mp3' }) | Export-Csv -LiteralPath $acceptedPath -NoTypeInformation -Encoding UTF8
        @([pscustomobject]@{ RejectedAt='2026-08-20'; NeteaseId='rejected_1'; Title='拒否曲'; Artist='艺术家'; FromSeed='x' }) | Export-Csv -LiteralPath $rejectedPath -NoTypeInformation -Encoding UTF8
        $report = Invoke-MusicServerMigration -Config $script:RecommendationTestConfig
        $report.status | Should Be 'SUCCESS'
        $report.imported.accepted | Should Be 1
        $report.imported.rejected | Should Be 1
        $report.imported.explicit_likes | Should BeGreaterThan 0
        $report.imported.events | Should Be 1
        @(Get-RecommendationFeedbackDb -FeedbackType 'DISPLAY').Count | Should Be 1
        @(Get-RecommendationFeedbackDb -FeedbackType 'LIKE').Count | Should Be 2
        @(Get-RecommendationFeedbackDb -FeedbackType 'ACCEPTED').Count | Should Be 1
        @(Get-RecommendationFeedbackDb -FeedbackType 'REJECTED').Count | Should Be 1
    }

    It 'reports malformed legacy rows without aborting valid migration' {
        Write-StateCollection -Config $script:RecommendationTestConfig -Name recommendations -Items @([pscustomobject]@{ date='2026-08-29'; rank=1; track_id=''; title=''; artist='' })
        $acceptedPath = Join-Path $script:RecommendationTestConfig.DataDir 'accepted.csv'
        @(
            [pscustomobject]@{ AcceptedAt='2026-08-20'; NeteaseId='valid_1'; Title='有效曲'; Artist='作者'; File='ok.mp3' }
            [pscustomobject]@{ AcceptedAt='2026-08-20'; NeteaseId=''; Title=''; Artist=''; File='' }
        ) | Export-Csv -LiteralPath $acceptedPath -NoTypeInformation -Encoding UTF8
        $report = Invoke-MusicServerMigration -Config $script:RecommendationTestConfig
        $report.status | Should Be 'SUCCESS'
        $report.imported.accepted | Should Be 1
        $report.legacy_ignored.Count | Should BeGreaterThan 0
    }

    It 'creates canonical metadata when a legacy recommendation has no track row' {
        $track = New-RecommendationTestTrack -Title 'Orphan Recommendation'
        $row = New-RecommendationTestRow -Track $track -Date '2026-08-29' -Rank 1 -NeteaseId 'orphan_1'
        Write-StateCollection -Config $script:RecommendationTestConfig -Name recommendations -Items @($row)
        $report = Invoke-MusicServerMigration -Config $script:RecommendationTestConfig
        $report.status | Should Be 'SUCCESS'
        (Get-CanonicalTrackDb -TrackId $track.id).title | Should Be $track.title
        @(Get-TodayRecommendationsDb -Date '2026-08-29').Count | Should Be 1
    }

    It 'reports a daily rank conflict without replacing the SQLite row' {
        $existingTrack = New-RecommendationTestTrack -Title 'Existing Recommendation'
        $existingRow = New-RecommendationTestRow -Track $existingTrack -Date '2026-08-29' -Rank 1 -NeteaseId 'sqlite_existing'
        Save-DailyRecommendationsDb -Recommendations @($existingRow) -Tracks @($existingTrack) -Date '2026-08-29' | Out-Null
        $legacyRow = New-RecommendationTestRow -Track $existingTrack -Date '2026-08-29' -Rank 1 -NeteaseId 'legacy_conflict'
        $legacyRow.title = 'Legacy Divergent Title'
        $legacyRow.artist = 'Legacy Divergent Artist'
        $legacyRow.liked = $true
        Write-StateCollection -Config $script:RecommendationTestConfig -Name recommendations -Items @($legacyRow)
        $report = Invoke-MusicServerMigration -Config $script:RecommendationTestConfig
        $report.status | Should Be 'SUCCESS'
        $report.imported.recommendations | Should Be 0
        $report.conflicts | Should BeGreaterThan 0
        $report.conflict_details -contains 'daily:2026-08-29:1' | Should Be $true
        (Get-TodayRecommendationsDb -Date '2026-08-29')[0].netease_id | Should Be 'sqlite_existing'
        (Get-CanonicalTrackDb -TrackId $existingTrack.id).title | Should Be 'Existing Recommendation'
        @(Get-RecommendationFeedbackDb -TrackId $existingTrack.id -FeedbackType 'LIKE').Count | Should Be 1
    }

    It 'reports existing canonical and wanted rows as skipped in DryRun' {
        $track = New-RecommendationTestTrack -Title 'Existing DryRun State'
        Save-CanonicalTrackDb -Track $track | Out-Null
        Add-WantedItemDb -TrackId $track.id | Out-Null
        Write-StateCollection -Config $script:RecommendationTestConfig -Name tracks -Items @($track)
        Write-StateCollection -Config $script:RecommendationTestConfig -Name wanted -Items @([pscustomobject]@{ track_id = $track.id; id = 'wanted_existing'; state = 'WANTED' })
        $report = Invoke-MusicServerMigration -Config $script:RecommendationTestConfig -DryRun
        $report.status | Should Be 'DRY_RUN'
        $report.imported.tracks | Should Be 0
        $report.imported.wanted | Should Be 0
        $report.skipped | Should BeGreaterThan 1
        $report.conflict_details -contains "canonical:$($track.id)" | Should Be $true
        $report.conflict_details -contains "wanted:$($track.id)" | Should Be $true
    }

    It 'does not overwrite an existing provider health row during migration' {
        Invoke-MusicServerParamSql -Template "INSERT INTO provider_health (provider,state,failure_count,consecutive_failures,consecutive_412,last_error,revision,updated_at) VALUES ('bilibili_search','OPEN',9,4,2,'keep-me',7,'2026-08-29T00:00:00Z');" -Params @{} | Out-Null
        Write-StateCollection -Config $script:RecommendationTestConfig -Name providers -Items @([pscustomobject]@{ provider='bilibili_search'; state='CLOSED'; success_count=99; failure_count=0; consecutive_failures=0; consecutive_412=0; average_latency_ms=1 })
        $report = Invoke-MusicServerMigration -Config $script:RecommendationTestConfig
        $report.status | Should Be 'SUCCESS'
        $report.imported.providers | Should Be 0
        $report.skipped | Should BeGreaterThan 0
        $health = @(Invoke-MusicServerParamSql -Template 'SELECT state,failure_count,last_error,revision FROM provider_health WHERE provider = @provider;' -Params @{ provider = 'bilibili_search' })[0]
        $health.state | Should Be 'OPEN'
        [int]$health.failure_count | Should Be 9
        $health.last_error | Should Be 'keep-me'
        [int]$health.revision | Should Be 7
    }

    It 'reports invalid numeric legacy fields without aborting migration' {
        $track = New-RecommendationTestTrack -Title 'Bad Numeric Track'
        $row = New-RecommendationTestRow -Track $track -Date '2026-08-29' -Rank 1 -NeteaseId 'bad_numeric_1'
        $track.duration = 'not-a-number'
        $row.duration = 'also-not-a-number'
        Write-StateCollection -Config $script:RecommendationTestConfig -Name tracks -Items @($track)
        Write-StateCollection -Config $script:RecommendationTestConfig -Name recommendations -Items @($row)
        Write-StateCollection -Config $script:RecommendationTestConfig -Name wanted -Items @([pscustomobject]@{ track_id='bad-wanted'; id='w1'; state='WANTED'; attempts='bad'; max_attempts='bad'; created_at=Get-NowIso; updated_at=Get-NowIso })
        Write-StateCollection -Config $script:RecommendationTestConfig -Name providers -Items @([pscustomobject]@{ provider='bilibili_search'; state='OPEN'; success_count='bad'; failure_count='bad'; consecutive_failures='bad'; consecutive_412='bad'; average_latency_ms='bad' })
        $report = Invoke-MusicServerMigration -Config $script:RecommendationTestConfig
        $report.status | Should Be 'SUCCESS'
        $report.legacy_ignored.Count | Should BeGreaterThan 0
        (Get-CanonicalTrackDb -TrackId $track.id).duration | Should Be 0
        (Get-TodayRecommendationsDb -Date '2026-08-29')[0].duration | Should Be 0
    }

    It 'is idempotent after importing legacy recommendation state' {
        $track = New-RecommendationTestTrack -Title '迁移幂等'
        $row = New-RecommendationTestRow -Track $track -Date '2026-08-29' -Rank 1 -NeteaseId 'idem_1'
        $row.liked = $true
        Write-StateCollection -Config $script:RecommendationTestConfig -Name tracks -Items @($track)
        Write-StateCollection -Config $script:RecommendationTestConfig -Name recommendations -Items @($row)
        $first = Invoke-MusicServerMigration -Config $script:RecommendationTestConfig
        $second = Invoke-MusicServerMigration -Config $script:RecommendationTestConfig
        $first.status | Should Be 'SUCCESS'
        $second.status | Should Be 'ALREADY_MIGRATED'
        $second.idempotent | Should Be $true
        @(Get-RecommendationFeedbackDb -TrackId $track.id).Count | Should Be 2
    }

    It 'rolls back migration writes when failure is injected' {
        $track = New-RecommendationTestTrack -Title 'Migration Rollback'
        Write-StateCollection -Config $script:RecommendationTestConfig -Name tracks -Items @($track)
        $failedReport = Invoke-MusicServerMigration -Config $script:RecommendationTestConfig -FailAfterStep 1
        $failedReport.status | Should Be 'FAILED'
        (Get-CanonicalTrackDb -TrackId $track.id) | Should Be $null
        $secondReport = Invoke-MusicServerMigration -Config $script:RecommendationTestConfig
        $secondReport.status | Should Be 'SUCCESS'
        (Get-CanonicalTrackDb -TrackId $track.id) | Should Not Be $null
    }

    It 'keeps daily_recommend.ps1 metadata-only and free of legacy runtime reads' {
        $source = Get-Content -LiteralPath (Join-Path $ProjectRoot 'daily_recommend.ps1') -Raw
        ($source -match 'Start-Process.*YtDlp|&\s+\$Config\.YtDlp|Invoke-WebRequest.*bilibili') | Should Be $false
        ($source -match 'Import-LegacyRecommendationState|Read-StateCollection|recommendation_history\.json|accepted\.csv|rejected\.csv|lyrics_report\.csv') | Should Be $false
        ($source -match 'Get-RecommendationSeedCandidatesDb') | Should Be $true
        ($source -match 'Get-RecommendationCooldownTrackIdsDb') | Should Be $true
        ($source -match 'Save-DailyRecommendationsDb') | Should Be $true
    }

    It 'never filters the library seed query on the Navidrome missing column' {
        # missing is only refreshed by a Navidrome scan, which the packaged runtime
        # never runs, so every row stays flagged and the filter returned nothing --
        # silently degrading every seed to a bare ".mp3" basename with no artist.
        $source = Get-Content -LiteralPath (Join-Path $ProjectRoot 'daily_recommend.ps1') -Raw
        ($source -match 'missing\s*=\s*0') | Should Be $false
        ($source -match 'Get-LocalLibraryRows') | Should Be $true
    }
}

Describe 'Local library recommendation source' {

    $script:affinityStats = @(
        [pscustomobject]@{ artist = '许嵩'; play_count = 9 }
        [pscustomobject]@{ artist = '许嵩'; play_count = 3 }
        [pscustomobject]@{ artist = 'Roselia'; play_count = 2 }
    )

    function New-LocalCandidate {
        param([string]$Title, [string]$Artist, [string]$LibraryId = 'library-A', [string]$LastPlayedAt = '')
        return [pscustomobject]@{
            Title = $Title; Artist = $Artist; File = "c:\music\$Title.mp3"
            LibraryId = $LibraryId; LastPlayedAt = $LastPlayedAt
        }
    }

    It 'weighs explicit positives above incidental play counts' {
        $affinity = Get-LocalArtistAffinity -ListeningStats @() -PositiveTracks @([pscustomobject]@{ Artist = '陈奕迅' })
        $affinity[[string](Normalize-MusicText '陈奕迅')] | Should Be 6
    }

    It 'caps the weight one looped track can contribute' {
        $many = @(1..50 | ForEach-Object { [pscustomobject]@{ artist = '许嵩'; play_count = 100 } })
        $affinity = Get-LocalArtistAffinity -ListeningStats $many -PositiveTracks @() -MaxPlayWeight 1
        # 50 rows x (1 x 2), not 50 x 100 x 2.
        $affinity[[string](Normalize-MusicText '许嵩')] | Should Be 100
    }

    It 'splits a multi-artist credit into separate affinity keys' {
        $affinity = Get-LocalArtistAffinity -ListeningStats @([pscustomobject]@{ artist = 'Alan Walker,Sabrina Carpenter'; play_count = 1 }) -PositiveTracks @()
        $affinity.ContainsKey([string](Normalize-MusicText 'Alan Walker')) | Should Be $true
        $affinity.ContainsKey([string](Normalize-MusicText 'Sabrina Carpenter')) | Should Be $true
    }

    It 'recommends an owned track by an artist the listener actually plays' {
        $picks = @(Select-LocalRecommendationTracks -Candidates @(
            (New-LocalCandidate -Title '有何不可' -Artist '许嵩')
        ) -Affinity (Get-LocalArtistAffinity -ListeningStats $script:affinityStats -PositiveTracks @()) -Limit 5)
        $picks.Count | Should Be 1
        $picks[0].Title | Should Be '有何不可'
        $picks[0].AffinityArtist | Should Be '许嵩'
    }

    It 'never recommends an artist the listener has shown no interest in' {
        # The library itself is not a taste signal: a large untouched collection
        # must not turn the day into a dump of its own files.
        $picks = @(Select-LocalRecommendationTracks -Candidates @(
            (New-LocalCandidate -Title '无关歌曲' -Artist '从未听过的歌手')
        ) -Affinity (Get-LocalArtistAffinity -ListeningStats $script:affinityStats -PositiveTracks @()) -Limit 5)
        $picks.Count | Should Be 0
    }

    It 'skips a track with no library id because it could not be streamed' {
        $picks = @(Select-LocalRecommendationTracks -Candidates @(
            (New-LocalCandidate -Title '九尾妖狐' -Artist '许嵩' -LibraryId '')
        ) -Affinity (Get-LocalArtistAffinity -ListeningStats $script:affinityStats -PositiveTracks @()) -Limit 5)
        $picks.Count | Should Be 0
    }

    It 'returns at most one track per artist per day' {
        $picks = @(Select-LocalRecommendationTracks -Candidates @(
            (New-LocalCandidate -Title 'A1' -Artist '许嵩')
            (New-LocalCandidate -Title 'A2' -Artist '许嵩')
            (New-LocalCandidate -Title 'A3' -Artist '许嵩')
        ) -Affinity (Get-LocalArtistAffinity -ListeningStats $script:affinityStats -PositiveTracks @()) -Limit 5)
        $picks.Count | Should Be 1
    }

    It 'prefers a never-played track over one played long ago' {
        $picks = @(Select-LocalRecommendationTracks -Candidates @(
            (New-LocalCandidate -Title '去年听过' -Artist '许嵩' -LibraryId 'l-old' -LastPlayedAt '2026-01-01T00:00:00Z')
            (New-LocalCandidate -Title '从未听过' -Artist '许嵩' -LibraryId 'l-new')
        ) -Affinity (Get-LocalArtistAffinity -ListeningStats $script:affinityStats -PositiveTracks @()) -Limit 5)
        $picks.Count | Should Be 1
        $picks[0].Title | Should Be '从未听过'
    }

    It 'leaves a recently played track alone' {
        $picks = @(Select-LocalRecommendationTracks -Candidates @(
            (New-LocalCandidate -Title '刚听过' -Artist '许嵩' -LibraryId 'l-hot' -LastPlayedAt (Get-NowIso))
        ) -Affinity (Get-LocalArtistAffinity -ListeningStats $script:affinityStats -PositiveTracks @()) -Limit 5)
        $picks.Count | Should Be 0
    }

    It 'excludes an already recommended or accepted track by any of its keys' {
        $affinity = Get-LocalArtistAffinity -ListeningStats $script:affinityStats -PositiveTracks @()
        @(Select-LocalRecommendationTracks -Candidates @((New-LocalCandidate -Title '有何不可' -Artist '许嵩')) -Affinity $affinity -ExcludedKeys @('有何不可') -Limit 5).Count | Should Be 0
        @(Select-LocalRecommendationTracks -Candidates @((New-LocalCandidate -Title '有何不可' -Artist '许嵩' -LibraryId 'library-XyZ-9')) -Affinity $affinity -ExcludedKeys @('library-XyZ-9') -Limit 5).Count | Should Be 0
        @(Select-LocalRecommendationTracks -Candidates @((New-LocalCandidate -Title '有何不可' -Artist '许嵩' -LibraryId 'library-Q')) -Affinity $affinity -ExcludedKeys @('track_9225fa1258aa953c5115ff46') -Limit 5).Count | Should Be 1
    }

    It 'excludes a whole artist when asked to' {
        $affinity = Get-LocalArtistAffinity -ListeningStats $script:affinityStats -PositiveTracks @()
        @(Select-LocalRecommendationTracks -Candidates @((New-LocalCandidate -Title '有何不可' -Artist '许嵩')) -Affinity $affinity -ExcludedKeys @('artist:许嵩') -Limit 5).Count | Should Be 0
    }

    It 'honours the limit and returns nothing for a zero limit' {
        $affinity = Get-LocalArtistAffinity -ListeningStats $script:affinityStats -PositiveTracks @()
        $many = @(1..10 | ForEach-Object { New-LocalCandidate -Title "T$_" -Artist "歌手$_" -LibraryId "library-$_" })
        $wide = Get-LocalArtistAffinity -ListeningStats @(1..10 | ForEach-Object { [pscustomobject]@{ artist = "歌手$_"; play_count = 5 } }) -PositiveTracks @()
        @(Select-LocalRecommendationTracks -Candidates $many -Affinity $wide -Limit 3).Count | Should Be 3
        @(Select-LocalRecommendationTracks -Candidates $many -Affinity $wide -Limit 0).Count | Should Be 0
    }
}

Describe 'Disliked tracks and release year' {

    BeforeEach {
        Initialize-RecommendationScratchDb
    }

    AfterEach {
        [Environment]::SetEnvironmentVariable('MUSICSERVER_APP_HOME', $script:RecommendationOldAppHome)
        if ($script:RecommendationTestRoot -and (Test-Path -LiteralPath $script:RecommendationTestRoot)) {
            Remove-Item -LiteralPath $script:RecommendationTestRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        $script:RecommendationTestRoot = $null
        $script:RecommendationTestConfig = $null
    }

    It 'creates the release_year column on both tables' {
        # CREATE TABLE IF NOT EXISTS cannot add a column to an existing database, so
        # the DDL and the explicit ALTER both have to agree; this pins the shape a
        # fresh install gets.
        $trackCols = @(Invoke-MusicServerSqlJson -Query 'PRAGMA table_info(canonical_tracks);') | ForEach-Object { [string]$_.name }
        $artistCols = @(Invoke-MusicServerSqlJson -Query 'PRAGMA table_info(local_track_artists);') | ForEach-Object { [string]$_.name }
        ($trackCols -contains 'release_year') | Should Be $true
        ($artistCols -contains 'release_year') | Should Be $true
        # Idempotent: re-running the bootstrap and the launcher's own upgrader works.
        Initialize-MusicServerSchema
        Initialize-LocalTrackArtistSchema
    }

    It 'round-trips the release year on a canonical track' {
        $track = New-CanonicalTrack -Title '有何不可' -Artist '许嵩' -Album '自定义' -ReleaseYear 2009
        $track.release_year | Should Be 2009
        Save-CanonicalTrackDb -Track $track | Out-Null
        (Get-CanonicalTrackDb -TrackId $track.id).release_year | Should Be 2009
    }

    It 'defaults an unknown release year to 0 rather than guessing' {
        $track = New-CanonicalTrack -Title 'Unknown Year' -Artist '测试艺术家'
        $track.release_year | Should Be 0
        Save-CanonicalTrackDb -Track $track | Out-Null
        (Get-CanonicalTrackDb -TrackId $track.id).release_year | Should Be 0
    }

    It 'does not let a later track save wipe an already known year' {
        $track = New-CanonicalTrack -Title 'Keep Year' -Artist '测试艺术家' -ReleaseYear 1999
        Save-CanonicalTrackDb -Track $track | Out-Null
        # A re-save from a source that carries no year must not blank it.
        $again = New-CanonicalTrack -Title 'Keep Year' -Artist '测试艺术家'
        Save-CanonicalTrackDb -Track $again | Out-Null
        (Get-CanonicalTrackDb -TrackId $track.id).release_year | Should Be 1999
    }

    It 'treats dislike as preference-only and turns the heart off' {
        $track = New-CanonicalTrack -Title 'Disliked Song' -Artist '测试艺术家'
        Save-CanonicalTrackDb -Track $track | Out-Null
        (Get-LatestTrackPreferenceDb -TrackId $track.id) | Should Be ''
        Write-TrackDislikeDb -TrackId $track.id -Title 'Disliked Song' -Artist '测试艺术家' -NeteaseId 'n1' | Out-Null
        (Get-LatestTrackPreferenceDb -TrackId $track.id) | Should Be 'DISLIKE'
        # Disliking must not queue a download or delete anything.
        (Get-LatestRecommendationFeedbackDb -TrackId $track.id) | Should Be 'UNLIKE'
        (Get-WantedItemDb -TrackId $track.id) | Should BeNullOrEmpty
        ($null -eq (Get-CanonicalTrackDb -TrackId $track.id)) | Should Be $false
    }

    It 'lets the most recent like and dislike win' {
        $track = New-CanonicalTrack -Title 'Axis Song' -Artist '测试艺术家'
        Save-CanonicalTrackDb -Track $track | Out-Null
        Write-TrackDislikeDb -TrackId $track.id -Title 'Axis Song' -Artist '测试艺术家' | Out-Null
        (Get-LatestTrackPreferenceDb -TrackId $track.id) | Should Be 'DISLIKE'
        # A like records both LIKE and the queue action; the LIKE must win.
        Add-FeedbackValue -TrackId $track.id -Type 'LIKE' -Value 'true' -Source 'music_api'
        (Get-LatestTrackPreferenceDb -TrackId $track.id) | Should Be 'LIKE'
        Write-TrackDislikeDb -TrackId $track.id -Title 'Axis Song' -Artist '测试艺术家' | Out-Null
        (Get-LatestTrackPreferenceDb -TrackId $track.id) | Should Be 'DISLIKE'
    }

    It 'returns to neutral when a dislike is withdrawn' {
        $track = New-CanonicalTrack -Title 'Undislike Song' -Artist '测试艺术家'
        Save-CanonicalTrackDb -Track $track | Out-Null
        Write-TrackDislikeDb -TrackId $track.id -Title 'Undislike Song' -Artist '测试艺术家' | Out-Null
        Write-TrackUndislikeDb -TrackId $track.id | Out-Null
        (Get-LatestTrackPreferenceDb -TrackId $track.id) | Should Be ''
        @(Get-DislikedTrackKeysDb).Count | Should Be 0
    }

    It 'lists a disliked track with every key a candidate can be matched on' {
        $track = New-CanonicalTrack -Title 'Key Song' -Artist '许嵩' -Identifiers @([pscustomobject]@{ type = 'netease'; value = '167876' })
        Save-CanonicalTrackDb -Track $track | Out-Null
        Write-TrackDislikeDb -TrackId $track.id -Title 'Key Song' -Artist '许嵩' -NeteaseId '167876' | Out-Null
        $keys = Get-DislikePenaltyKeys -Disliked @(Get-DislikedTrackKeysDb)
        $keys.ContainsKey($track.id) | Should Be $true
        $keys.ContainsKey('netease:167876') | Should Be $true
        $keys.ContainsKey([string](Normalize-MusicText 'Key Song')) | Should Be $true
        $keys.ContainsKey([string](Normalize-MusicText 'Key Song许嵩')) | Should Be $true
    }

    It 'matches a candidate by NetEase id, track id, name, or name+artist' {
        $track = New-CanonicalTrack -Title 'Match Song' -Artist '许嵩' -Identifiers @([pscustomobject]@{ type = 'netease'; value = '999' })
        Save-CanonicalTrackDb -Track $track | Out-Null
        Write-TrackDislikeDb -TrackId $track.id -Title 'Match Song' -Artist '许嵩' -NeteaseId '999' | Out-Null
        $keys = Get-DislikePenaltyKeys -Disliked @(Get-DislikedTrackKeysDb)

        (Test-CandidateDisliked -Title 'Other' -Artist 'Other' -NeteaseId '999' -PenaltyKeys $keys) | Should Be $true
        (Test-CandidateDisliked -Title 'Other' -Artist 'Other' -TrackId $track.id -PenaltyKeys $keys) | Should Be $true
        (Test-CandidateDisliked -Title 'Match Song' -Artist 'Other' -PenaltyKeys $keys) | Should Be $true
        (Test-CandidateDisliked -Title 'Match Song' -Artist '许嵩' -PenaltyKeys $keys) | Should Be $true
        # A different recording of a different song must not be caught.
        (Test-CandidateDisliked -Title '无关歌曲' -Artist '其他歌手' -NeteaseId '111' -PenaltyKeys $keys) | Should Be $false
    }

    It 'never matches when nothing is disliked' {
        (Test-CandidateDisliked -Title 'Anything' -Artist 'Anyone' -NeteaseId '1' -PenaltyKeys @{}) | Should Be $false
    }

    It 'normalizes penalty keys so a separator cannot defeat the match' {
        # The disliked title is raw; the candidate arrives from NetEase with
        # different punctuation. Both must normalize to the same key.
        $track = New-CanonicalTrack -Title 'On My Way（Live）' -Artist 'Alan Walker'
        Save-CanonicalTrackDb -Track $track | Out-Null
        Write-TrackDislikeDb -TrackId $track.id -Title 'On My Way（Live）' -Artist 'Alan Walker' | Out-Null
        $keys = Get-DislikePenaltyKeys -Disliked @(Get-DislikedTrackKeysDb)
        (Test-CandidateDisliked -Title 'On My Way(Live)' -Artist 'Alan Walker' -PenaltyKeys $keys) | Should Be $true
    }
}
