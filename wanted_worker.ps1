<#
.SYNOPSIS
    异步处理 Wanted Queue：本地匹配 -> 精确候选 -> 其他 Provider -> Bilibili 搜索兜底。
.PARAMETER Once
    只处理一轮后退出；适合计划任务。
.PARAMETER MaxItems
    一轮最多处理多少条，默认 5。
.PARAMETER PollSeconds
    常驻模式的轮询间隔，默认 30 秒。
.PARAMETER DryRun
    展示将处理的队列，不下载或写状态。
.PARAMETER Root
    项目根目录；默认当前脚本所在目录，主要用于测试和迁移。
#>
param(
    [switch]$Once,
    [int]$MaxItems = 5,
    [int]$PollSeconds = 30,
    [switch]$DryRun,
    [string]$Root = $PSScriptRoot
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Import-Module (Join-Path $PSScriptRoot 'MusicServer.Core.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'MusicServer.State.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'MusicServer.Providers.psm1') -Force
$Config = New-MusicServerConfig -Root $Root
Initialize-MusicServerState -Config $Config
Initialize-MusicServerDatabase -DbPath (Join-Path $Config.StateDir 'musicserver.db') -SqliteExe $Config.Sqlite
Initialize-MusicServerSchema
$WorkerMutex = [Threading.Mutex]::new($false, 'MusicServer_WantedWorker')
$OwnsWorkerMutex = $false
try {
    $OwnsWorkerMutex = $WorkerMutex.WaitOne(0)
} catch {
    $OwnsWorkerMutex = $true
}
if (-not $OwnsWorkerMutex) {
    Write-Host '已有 Wanted worker 正在运行，本次跳过，避免重复下载。' -ForegroundColor DarkYellow
    $WorkerMutex.Dispose()
    exit 0
}

# Worker identity used for owned leases and CAS writes in wanted_queue.
# The INTEGER column lease_expires_epoch is the only machine comparison source
# for lease validity; TEXT lease_expires_at is diagnostic and never compared here.
$WorkerId = "wanted_worker_$([Environment]::MachineName)_$$"
$ActiveQueueStates = @('RESOLVING','DOWNLOADING','VALIDATING')

# Hardened helpers: wanted_queue (SQLite) is the concurrency authority. The legacy
# JSON state stays the UI-facing record (music_api reads/writes it); every queue
# transition below is mirrored into wanted_queue with a revision-guarded CAS so a
# crashed/stale worker can never overwrite a cancel or steal a live lease.
function Test-OwnsActiveLease {
    param([psobject]$Wanted)
    try {
        $row = Get-WantedItemDb -TrackId ([string]$Wanted.track_id)
        if ($null -ceq $row) { return $false }
        if ([string]$row.state -ne 'CANCEL_REQUESTED' -and [string]$row.claimed_by -ceq $WorkerId) {
            $epoch = $null
            if ($row.PSObject.Properties['lease_expires_epoch']) {
                $e = $row.lease_expires_epoch
                if ($null -ne $e) { $epoch = [long]$e }
            }
            # Epoch is the sole lease clock; null epoch for an owned active row is treated as held.
            if ($null -eq $epoch) { return $true }
            return ($epoch -gt [long][DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
        }
        return $false
    } catch {
        # DB unavailable: fail closed. A worker must never make a runtime state
        # decision from a legacy mirror or continue without lease authority.
        return $false
    }
}

function Complete-CancellationInDb {
    param([psobject]$Wanted, [string]$TemporaryPath = '')
    try {
        $tid = [string]$Wanted.track_id
        $cur = $null
        try { $cur = Get-WantedItemDb -TrackId $tid } catch {}
        if ($null -ceq $cur) {
            # Never resurrect a completed cancellation; keep the canonical track consistent.
            Reset-CanonicalTrackToRemoteDb -TrackId $tid | Out-Null
            return
        }
        if ([string]$cur.state -ne 'CANCEL_REQUESTED') {
            # Active/idle row: mark CANCEL_REQUESTED (this also clears any lease we hold).
            Request-WantedCancellationDb -TrackId $tid | Out-Null
        }
        # Finish: remove the queue row and reset the canonical track (guarded to LOCAL).
        Complete-WantedCancellationDb -TrackId $tid -TemporaryPath $TemporaryPath | Out-Null
    } catch {
        Write-Host "  [warn] DB 取消同步失败：$_" -ForegroundColor DarkYellow
    }
}

function Release-WantedLease {
    param([psobject]$Wanted, [string]$State, [string]$Error = '', [string]$NextRetryAt = '', [int]$AttemptCount = -1)
    try {
        $tid = [string]$Wanted.track_id
        $cur = Get-WantedItemDb -TrackId $tid
        if ($null -ceq $cur) {
            # Row already completed (e.g. cancellation cleanup): keep the canonical track consistent.
            if ($State -ne 'LOCAL') { Reset-CanonicalTrackToRemoteDb -TrackId $tid | Out-Null }
            return
        }
        $ok = Update-WantedStateCasDb -TrackId $tid -WorkerId $WorkerId -ExpectedRevision ([int]$cur.revision) `
            -NewState $State -LastError $Error -NextRetryAt $NextRetryAt -AttemptCount $AttemptCount
        if ($ok.Success) { return }
        # Lost the CAS race (e.g. crash recovery reclaimed our expired lease): never
        # let a stale writer force its own terminal state into the canonical track.
        if ($State -ne 'LOCAL') { Reset-CanonicalTrackToRemoteDb -TrackId $tid | Out-Null }
    } catch {
        Write-Host "  [warn] DB 状态同步失败：$_" -ForegroundColor DarkYellow
    }
}

function Reassert-WantedLease {
    param([psobject]$Wanted)
    try {
        $tid = [string]$Wanted.track_id
        $cur = Get-WantedItemDb -TrackId $tid
        if ($null -ceq $cur) { return }
        if ([string]$cur.state -ne 'CANCEL_REQUESTED' -and [string]$cur.claimed_by -ceq $WorkerId) {
            return
        }
        # Crash recovery can reclaim an expired lease while we were blocked a long time.
        # Re-claim against the current revision: this is a no-op if another worker took
        # over the item in the meantime, and Test-OwnsActiveLease then stops this pass
        # instead of letting a stale writer finish the job.
        $nowInstant = [DateTimeOffset]::UtcNow
        $leaseInstant = $nowInstant.AddMinutes(30)
        $resumed = Invoke-MusicServerParamNonQuery -Template @"
UPDATE wanted_queue SET state = 'RESOLVING', claimed_by = @me, claimed_at = @now,
    lease_expires_at = @lease, lease_expires_epoch = @lease_epoch, updated_at = @now,
    revision = revision + 1
WHERE track_id = @tid AND state = 'RETRY_WAIT' AND claimed_by = ''
  AND revision = @rev;
"@ -Params @{
            tid = $tid; me = $WorkerId; rev = [int]$cur.revision
            now = $nowInstant.UtcDateTime.ToString('o')
            lease = $leaseInstant.UtcDateTime.ToString('o')
            lease_epoch = [long]$leaseInstant.ToUnixTimeSeconds()
        } -ReturnChanges
        if ([int]$resumed -ne 1) { return }
        Renew-LeaseDb -TrackId $tid -WorkerId $WorkerId -LeaseMinutes 30 | Out-Null
    } catch {
        Write-Host "  [warn] 租约恢复失败：$_" -ForegroundColor DarkYellow
    }
}

function Get-LiveWanted {
    param([psobject]$Wanted)
    return (Get-WantedItemDb -TrackId ([string]$Wanted.track_id))
}

function Test-WantedCancellation {
    param([psobject]$Wanted)
    $live = Get-LiveWanted -Wanted $Wanted
    if (-not $live) { return $true }
    return ([string]$live.state -eq 'CANCEL_REQUESTED')
}

function Complete-WantedCancellation {
    param([psobject]$Wanted, [string]$TemporaryPath = '')
    if ($TemporaryPath -and (Test-Path -LiteralPath $TemporaryPath)) {
        Remove-Item -LiteralPath $TemporaryPath -Force -ErrorAction SilentlyContinue
        $tempLrc = [IO.Path]::ChangeExtension($TemporaryPath, '.lrc')
        Remove-Item -LiteralPath $tempLrc -Force -ErrorAction SilentlyContinue
    }
    Complete-CancellationInDb -Wanted $Wanted -TemporaryPath $TemporaryPath
}

function Set-QueueState {
    param([psobject]$Wanted, [string]$State, [string]$Error = '', [string]$NextRetryAt = '')
    $live = Get-LiveWanted -Wanted $Wanted
    if ($null -eq $live) { return $false }
    if ([string]$live.state -eq 'CANCEL_REQUESTED' -and $State -ne 'CANCEL_REQUESTED') {
        $Wanted.state = 'CANCEL_REQUESTED'
        $Wanted.last_error = 'USER_CANCELLED'
        return $false
    }
    $attemptCount = if ($Wanted.PSObject.Properties['attempt_count']) { [int]$Wanted.attempt_count } else { [int]$Wanted.attempts }
    $result = Update-WantedStateCasDb -TrackId ([string]$live.track_id) -WorkerId $WorkerId -ExpectedRevision ([int]$live.revision) `
        -NewState $State -LastError $Error -NextRetryAt $NextRetryAt -AttemptCount $attemptCount
    if (-not $result.Success) {
        if ([string]$result.CurrentState -eq 'CANCEL_REQUESTED') {
            $Wanted.state = 'CANCEL_REQUESTED'
            $Wanted.last_error = 'USER_CANCELLED'
        }
        return $false
    }
    $Wanted.state = $State
    $Wanted.attempt_count = $attemptCount
    $Wanted.attempts = $attemptCount
    $Wanted.last_error = $Error
    $Wanted.next_retry_at = if ($NextRetryAt) { $NextRetryAt } else { $null }
    $Wanted.revision = [int]$result.Revision
    Write-MusicServerEventDb -TrackId $Wanted.track_id -EventType 'STATE_TRANSITION' -FromState ([string]$live.state) -ToState $State -Attempt $attemptCount -ErrorType $Error
    return $true
}

function Get-RetryTime {
    param([psobject]$Wanted, [string]$Provider = '')
    if ($Provider) {
        $health = Get-ProviderHealth -Config $Config -Provider $Provider
        if ($health.blocked_until) { return (Convert-ToUtcIso $health.blocked_until) }
    }
    $minutes = [Math]::Min(120, [Math]::Pow(2, [Math]::Max(0, [int]$Wanted.attempts - 1)) * 5)
    return [DateTime]::UtcNow.AddMinutes($minutes).ToString('o')
}

function Increment-WantedAttempt {
    param([Parameter(Mandatory)][psobject]$Wanted)
    $current = if ($Wanted.PSObject.Properties['attempt_count']) { [int]$Wanted.attempt_count } else { [int]$Wanted.attempts }
    $next = $current + 1
    if ($Wanted.PSObject.Properties['attempt_count']) { $Wanted.attempt_count = $next }
    else { $Wanted | Add-Member -NotePropertyName attempt_count -NotePropertyValue $next -Force }
    if ($Wanted.PSObject.Properties['attempts']) { $Wanted.attempts = $next }
    else { $Wanted | Add-Member -NotePropertyName attempts -NotePropertyValue $next -Force }
    return $next
}

function Get-BilibiliBlockedUntil {
    $blockedDates = @()
    foreach ($provider in @('bilibili_search','bilibili_download')) {
        $health = Get-ProviderHealth -Config $Config -Provider $provider
        if ([string]$health.state -eq 'OPEN' -and $health.blocked_until) {
            $date = Convert-ToUtcDateTime $health.blocked_until
            if ($date) { $blockedDates += $date }
        }
    }
    if ($blockedDates.Count -eq 0) { return '' }
    return ($blockedDates | Sort-Object -Descending | Select-Object -First 1).ToString('o')
}

function Get-NeteaseIdFromTrack {
    param([psobject]$Track)
    $id = @($Track.identifiers) | Where-Object { [string]$_.type -eq 'netease' } | Select-Object -First 1
    if ($id) { return [string]$id.value }
    return ''
}

function Write-TrackLyrics {
    param([psobject]$Track, [string]$AudioPath)
    $neteaseId = Get-NeteaseIdFromTrack -Track $Track
    if (-not $neteaseId) { return $false }
    $headers = @{ 'User-Agent' = 'Mozilla/5.0'; 'Referer' = 'https://music.163.com/' }
    try {
        $url = "https://music.163.com/api/song/lyric?id=$neteaseId&lv=1&kv=1&tv=-1"
        $response = Invoke-RestMethod -Uri $url -Headers $headers -TimeoutSec 20
        if (-not $response.lrc -or -not $response.lrc.lyric -or $response.lrc.lyric -notmatch '\[\d+:') { return $false }
        $content = [string]$response.lrc.lyric
        if ($response.tlyric -and $response.tlyric.lyric -match '\[\d+:') { $content = $content.TrimEnd() + "`n" + $response.tlyric.lyric }
        $lrcPath = [IO.Path]::ChangeExtension($AudioPath, '.lrc')
        [IO.File]::WriteAllText($lrcPath, $content, (New-Object Text.UTF8Encoding($false)))
        return $true
    } catch {
        Write-MusicServerEventDb -TrackId $Track.id -Provider 'netease' -EventType 'LYRICS_FAILED' -ErrorType 'LYRICS_REQUEST_FAILED' -Message $_.Exception.Message
        return $false
    }
}

function Add-LegacyAcceptedRow {
    param([psobject]$Track, [string]$Path)
    $acceptedPath = Join-Path $Config.DataDir 'accepted.csv'
    $neteaseId = Get-NeteaseIdFromTrack -Track $Track
    $fileName = [IO.Path]::GetFileName($Path)
    $acceptedAt = Get-Date -Format 'yyyy-MM-dd'
    $value = ConvertTo-Json -InputObject ([ordered]@{
            legacy_key = "accepted:$fileName`:$neteaseId"; title = [string]$Track.title
            artist = [string]$Track.artist; netease_id = $neteaseId; file = $fileName
            accepted_at = $acceptedAt; positive = $true
        }) -Compress -Depth 10
    $added = Write-FeedbackIfAbsentDb -TrackId ([string]$Track.id) -FeedbackType 'ACCEPTED' -Source 'wanted_worker' -Value $value -CreatedAt $acceptedAt
    Save-RecommendationFileDb -FileName $fileName -TrackId ([string]$Track.id) -Date $acceptedAt `
        -NeteaseId $neteaseId -Title ([string]$Track.title) -Artist ([string]$Track.artist) `
        -Album ([string](Get-OptionalProperty $Track 'album')) -Duration ([int](Get-OptionalProperty $Track 'duration' 0)) -SeedSource 'wanted_worker' | Out-Null
    if (-not $added) { return }
    $row = [pscustomobject]@{
        AcceptedAt = $acceptedAt; NeteaseId = $neteaseId
        Title = $Track.title; Artist = $Track.artist; File = $fileName
    }
    if (Test-Path -LiteralPath $acceptedPath) { $row | Export-Csv -LiteralPath $acceptedPath -NoTypeInformation -Encoding UTF8 -Append }
    else { $row | Export-Csv -LiteralPath $acceptedPath -NoTypeInformation -Encoding UTF8 }
}

function Move-LegacyDailyMixToLibrary {
    param([string]$Path)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $dailyRoot = ([IO.Path]::GetFullPath($Config.DailyDir)).TrimEnd('\') + '\'
    if (-not $fullPath.StartsWith($dailyRoot, [StringComparison]::OrdinalIgnoreCase)) { return $Path }
    $target = Join-Path $Config.MusicDir ([IO.Path]::GetFileName($Path))
    if (-not (Test-Path -LiteralPath $target)) { Move-Item -LiteralPath $Path -Destination $target -Force }
    else { Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue }
    $oldLrc = [IO.Path]::ChangeExtension($Path, '.lrc')
    $newLrc = [IO.Path]::ChangeExtension($target, '.lrc')
    if (Test-Path -LiteralPath $oldLrc) {
        if (-not (Test-Path -LiteralPath $newLrc)) { Move-Item -LiteralPath $oldLrc -Destination $newLrc -Force }
        else { Remove-Item -LiteralPath $oldLrc -Force -ErrorAction SilentlyContinue }
    }
    return $target
}

function Bind-LocalTrack {
    param([psobject]$Track, [psobject]$Wanted, [string]$Path)
    if (Test-WantedCancellation -Wanted $Wanted) { Complete-WantedCancellation -Wanted $Wanted; return }
    if (-not (Test-OwnsActiveLease -Wanted $Wanted)) { Write-Host "  [abandon] $([string]$Wanted.title)：租约已丢失，放弃本次处理。" -ForegroundColor DarkYellow; return }
    $Path = Move-LegacyDailyMixToLibrary -Path $Path
    $songId = Get-NavidromeSongIdForPath -Config $Config -Path $Path
    $Wanted.selected_candidate = [pscustomobject]@{ provider = 'local'; path = $Path }
    $finResult = Finalize-WantedLocalDb -TrackId $Track.id -WorkerId $WorkerId -ExpectedState 'RESOLVING' -LocalSongId $songId
    if (-not $finResult.Success) {
        Write-Host "  [error] $([string]$Wanted.title)：LOCAL finalization failed: $($finResult.Reason)" -ForegroundColor Red
        return
    }
    Add-LegacyAcceptedRow -Track $Track -Path $Path
    Write-MusicServerEventDb -TrackId $Track.id -Provider 'local' -EventType 'LOCAL_BOUND' -Result 'SUCCESS' -Message "path=$Path; navidrome_id=$songId"
}

function Complete-DownloadedTrack {
    param([psobject]$Track, [psobject]$Wanted, [string]$Path, [psobject]$Validation, [psobject]$Candidate, [psobject]$Score)
    if (Test-WantedCancellation -Wanted $Wanted) { Complete-WantedCancellation -Wanted $Wanted -TemporaryPath $Path; return }
    if (-not (Test-OwnsActiveLease -Wanted $Wanted)) { Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue; return }

    $target = Join-Path $Config.MusicDir ([IO.Path]::GetFileName($Path))
    if ($Path -ne $target) {
        if (Test-Path -LiteralPath $target) {
            $stem = [IO.Path]::GetFileNameWithoutExtension($target)
            $target = Join-Path $Config.MusicDir "$stem [$($Track.id.Substring(6, 8))].mp3"
        }
        Move-Item -LiteralPath $Path -Destination $target -Force
        $oldLrc = [IO.Path]::ChangeExtension($Path, '.lrc')
        $newLrc = [IO.Path]::ChangeExtension($target, '.lrc')
        if (Test-Path -LiteralPath $oldLrc) { Move-Item -LiteralPath $oldLrc -Destination $newLrc -Force }
    } else { $target = $Path }

    if (Test-WantedCancellation -Wanted $Wanted) {
        Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
        Complete-WantedCancellation -Wanted $Wanted
        return
    }
    if (-not (Test-OwnsActiveLease -Wanted $Wanted)) {
        Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
        return
    }

    [void](Write-TrackLyrics -Track $Track -AudioPath $target)
    $Wanted.selected_candidate = [pscustomobject]@{ provider = $Candidate.provider; url = $Candidate.url; score = $Score.score }
    $finResult = Finalize-WantedLocalDb -TrackId $Track.id -WorkerId $WorkerId -ExpectedState 'VALIDATING'
    if (-not $finResult.Success) {
        Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
        $targetLrc = [IO.Path]::ChangeExtension($target, '.lrc')
        Remove-Item -LiteralPath $targetLrc -Force -ErrorAction SilentlyContinue
        Complete-WantedCancellation -Wanted $Wanted
        return
    }
    Add-LegacyAcceptedRow -Track $Track -Path $target
    Write-MusicServerEventDb -TrackId $Track.id -Provider $Candidate.provider -EventType 'LOCAL' -Result 'SUCCESS' -Message "path=$target; duration=$($Validation.Duration); duration_diff=$($Validation.DurationDiff); allowed_diff=$($Validation.AllowedDiff)"
    if ((Test-Path -LiteralPath $Config.NdExe) -and (Test-Path -LiteralPath $Config.NdConfig)) {
        & $Config.NdExe -c $Config.NdConfig scan --nobanner 2>$null | Out-Null
    }
    $songId = Get-NavidromeSongIdForPath -Config $Config -Path $target
    $track = Get-CanonicalTrackDb -TrackId $Track.id
    if ($track) {
        $known = @($track.download_candidates) | Where-Object { [string](Get-OptionalProperty $_ 'url') -eq [string]$Candidate.url }
        if ($known.Count -eq 0) {
            $track.download_candidates = @($track.download_candidates) + @([pscustomobject]@{
                provider = 'bilibili_direct'; bvid = $Candidate.bvid; url = $Candidate.url
                priority = 80; requires_search = $false; duration = $Validation.Duration
            })
        }
        $track.local_song_id = $songId
        $track.status = 'LOCAL'
        Save-CanonicalTrackDb -Track $track | Out-Null
    }
}

function Process-WantedTrack {
    param([psobject]$Wanted)

    if (Test-WantedCancellation -Wanted $Wanted) {
        Complete-WantedCancellation -Wanted $Wanted
        return
    }
    if (-not (Test-OwnsActiveLease -Wanted $Wanted)) {
        Write-Host "  [abandon] $([string]$Wanted.title)：租约已丢失，放弃本次处理。" -ForegroundColor DarkYellow
        return
    }

    $track = Get-CanonicalTrackDb -TrackId ([string]$Wanted.track_id)
    if (-not $track) {
        [void](Increment-WantedAttempt -Wanted $Wanted)
        [void](Set-QueueState -Wanted $Wanted -State 'UNAVAILABLE' -Error 'TRACK_NOT_FOUND')
        return
    }
    if ($DryRun) {
        Write-Host "  $($Wanted.track_id) | $($track.title) - $($track.artist) | state=$($Wanted.state)" -ForegroundColor DarkGray
        return
    }

    $local = Find-LocalTrack -Config $Config -Title $track.title -Artist $track.artist
    if ($local) {
        Bind-LocalTrack -Track $track -Wanted $Wanted -Path $local.File.FullName
        return
    }

    if (-not (Set-QueueState -Wanted $Wanted -State 'RESOLVING')) { Complete-WantedCancellation -Wanted $Wanted; return }
    Set-CanonicalTrackStatusForWantedDb -TrackId $track.id -WorkerId $WorkerId -WantedState 'RESOLVING' -Status 'RESOLVING' | Out-Null
    [void](Reassert-WantedLease -Wanted $Wanted)
    $ranked = @(Resolve-DownloadCandidates -Config $Config -Track $track)

    if (Test-WantedCancellation -Wanted $Wanted) { Complete-WantedCancellation -Wanted $Wanted; return }
    if (-not (Test-OwnsActiveLease -Wanted $Wanted)) { Write-Host "  [abandon] $([string]$Wanted.title)：候选解析期间租约丢失，放弃本次处理。" -ForegroundColor DarkYellow; return }

    if ($ranked.Count -eq 0) {
        [void](Increment-WantedAttempt -Wanted $Wanted)
        $blockedUntil = Get-BilibiliBlockedUntil
        if ($blockedUntil) {
            [void](Set-QueueState -Wanted $Wanted -State 'RETRY_WAIT' -Error 'BILIBILI_CIRCUIT_OPEN' -NextRetryAt $blockedUntil)
            Set-CanonicalTrackStatusForWantedDb -TrackId $track.id -WorkerId $WorkerId -WantedState 'RETRY_WAIT' -Status 'RETRY_WAIT' | Out-Null
        } elseif ([int]$Wanted.attempts -ge [int]$Wanted.max_attempts) {
            [void](Set-QueueState -Wanted $Wanted -State 'UNAVAILABLE' -Error 'NO_CANDIDATE')
            Set-CanonicalTrackStatusForWantedDb -TrackId $track.id -WorkerId $WorkerId -WantedState 'UNAVAILABLE' -Status 'UNAVAILABLE' | Out-Null
        } else {
            [void](Set-QueueState -Wanted $Wanted -State 'RETRY_WAIT' -Error 'NO_CANDIDATE' -NextRetryAt (Get-RetryTime -Wanted $Wanted))
            Set-CanonicalTrackStatusForWantedDb -TrackId $track.id -WorkerId $WorkerId -WantedState 'RETRY_WAIT' -Status 'RETRY_WAIT' | Out-Null
        }
        return
    }

    foreach ($entry in $ranked) {
        if (Test-WantedCancellation -Wanted $Wanted) { Complete-WantedCancellation -Wanted $Wanted; return }
        if (-not (Test-OwnsActiveLease -Wanted $Wanted)) { return }

        $candidate = $entry.Candidate
        $score = $entry.Score
        $Wanted.selected_candidate = $candidate
        Write-MusicServerEventDb -TrackId $track.id -Provider $candidate.provider -EventType 'CANDIDATE_SELECTED' -Attempt ([int]$Wanted.attempts) -Message "score=$($score.score); identity=$($score.identity_confidence); duration_diff=$($score.duration_diff)"
        if ($candidate.provider -eq 'local') {
            Bind-LocalTrack -Track $track -Wanted $Wanted -Path $candidate.url
            return
        }

        if (-not (Set-QueueState -Wanted $Wanted -State 'DOWNLOADING')) { Complete-WantedCancellation -Wanted $Wanted; return }
        Set-CanonicalTrackStatusForWantedDb -TrackId $track.id -WorkerId $WorkerId -WantedState 'DOWNLOADING' -Status 'DOWNLOADING' | Out-Null
        if (Test-WantedCancellation -Wanted $Wanted) { Complete-WantedCancellation -Wanted $Wanted; return }
        if (-not (Test-OwnsActiveLease -Wanted $Wanted)) { return }
        [void](Reassert-WantedLease -Wanted $Wanted)

        $download = Invoke-BilibiliDownload -Config $Config -Track $track -Candidate $candidate
        if (Test-WantedCancellation -Wanted $Wanted) {
            Complete-WantedCancellation -Wanted $Wanted -TemporaryPath ([string]$download.Path)
            return
        }
        if ($download.Success -and -not (Test-OwnsActiveLease -Wanted $Wanted)) {
            Remove-Item -LiteralPath ([string]$download.Path) -Force -ErrorAction SilentlyContinue
            return
        }

        if (-not $download.Success) {
            if ($download.Blocked) {
                [void](Increment-WantedAttempt -Wanted $Wanted)
                [void](Set-QueueState -Wanted $Wanted -State 'RETRY_WAIT' -Error $download.Error -NextRetryAt (Get-RetryTime -Wanted $Wanted -Provider 'bilibili_download'))
                Set-CanonicalTrackStatusForWantedDb -TrackId $track.id -WorkerId $WorkerId -WantedState 'RETRY_WAIT' -Status 'RETRY_WAIT' | Out-Null
                return
            }
            Write-MusicServerEventDb -TrackId $track.id -Provider $candidate.provider -EventType 'DOWNLOAD_FAILED' -Attempt ([int]$Wanted.attempts) -ErrorType $download.Error
            continue
        }

        if (-not (Set-QueueState -Wanted $Wanted -State 'VALIDATING')) {
            Complete-WantedCancellation -Wanted $Wanted -TemporaryPath $download.Path
            return
        }
        Set-CanonicalTrackStatusForWantedDb -TrackId $track.id -WorkerId $WorkerId -WantedState 'VALIDATING' -Status 'VALIDATING' | Out-Null
        if (-not (Test-OwnsActiveLease -Wanted $Wanted)) { Remove-Item -LiteralPath $download.Path -Force -ErrorAction SilentlyContinue; return }
        [void](Reassert-WantedLease -Wanted $Wanted)
        $validation = Validate-DownloadedCandidate -Config $Config -Track $track -Path $download.Path
        Write-MusicServerEventDb -TrackId $track.id -Provider $candidate.provider -EventType 'VALIDATION' -Result $validation.Reason -Message "duration=$($validation.Duration); expected=$($track.duration); diff=$($validation.DurationDiff); allowed=$($validation.AllowedDiff)"

        if (Test-WantedCancellation -Wanted $Wanted) {
            Complete-WantedCancellation -Wanted $Wanted -TemporaryPath $download.Path
            return
        }
        if (-not (Test-OwnsActiveLease -Wanted $Wanted)) { Remove-Item -LiteralPath $download.Path -Force -ErrorAction SilentlyContinue; return }
        if (-not $validation.Valid) {
            Remove-Item -LiteralPath $download.Path -Force -ErrorAction SilentlyContinue
            if ($validation.Reason -eq 'WRONG_DURATION') { continue }
            break
        }
        Complete-DownloadedTrack -Track $track -Wanted $Wanted -Path $download.Path -Validation $validation -Candidate $candidate -Score $score
        return
    }

    if (Test-WantedCancellation -Wanted $Wanted) { Complete-WantedCancellation -Wanted $Wanted; return }
    if (-not (Test-OwnsActiveLease -Wanted $Wanted)) { return }
    [void](Increment-WantedAttempt -Wanted $Wanted)
    if ([int]$Wanted.attempts -ge [int]$Wanted.max_attempts) {
        [void](Set-QueueState -Wanted $Wanted -State 'UNAVAILABLE' -Error 'ALL_CANDIDATES_FAILED')
        Set-CanonicalTrackStatusForWantedDb -TrackId $track.id -WorkerId $WorkerId -WantedState 'UNAVAILABLE' -Status 'UNAVAILABLE' | Out-Null
    } else {
        [void](Set-QueueState -Wanted $Wanted -State 'RETRY_WAIT' -Error 'ALL_CANDIDATES_FAILED' -NextRetryAt (Get-RetryTime -Wanted $Wanted))
        Set-CanonicalTrackStatusForWantedDb -TrackId $track.id -WorkerId $WorkerId -WantedState 'RETRY_WAIT' -Status 'RETRY_WAIT' | Out-Null
    }
}

function Invoke-WorkerPass {
    # Crash recovery first: reclaim expired leases (lease_expires_epoch < now) and
    # finish queued CANCEL_REQUESTED cleanups before anyone else touches the queue.
    try { Invoke-CrashRecoveryDb | Out-Null } catch {
        Write-Host "  [warn] 崩溃恢复跳过：$_" -ForegroundColor DarkYellow
    }
    $queue = @(Get-WantedTracksDb -EligibleOnly)
    if ($queue.Count -eq 0) {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Wanted Queue 为空。" -ForegroundColor DarkGray
        return
    }
    $selected = @()
    foreach ($wanted in $queue) {
        if ($selected.Count -ge $MaxItems) { break }
        [string]$tid = [string]$wanted.track_id
        if ([string]$wanted.state -eq 'CANCEL_REQUESTED') {
            # 取消收尾是幂等的，不需要持有租约，直接处理。
            $selected += $wanted
            continue
        }
        $claimed = $false
        try {
            [void](Add-WantedItemDb -TrackId $tid -MaxAttempts ([int]$wanted.max_attempts))
            $claim = Claim-WantedItemDb -TrackId $tid -WorkerId $WorkerId
            $claimed = [bool]$claim.Success
        } catch {
            Write-Host "  [warn] claim 失败（回退到旧的取消检查保护）：$_" -ForegroundColor DarkYellow
        }
        if (-not $claimed) {
            if ($null -ne $claim) {
                Write-Host "  [skip] $([string]$wanted.title)：claim 竞争失败（$($claim.Reason)），其他 worker 持有活跃租约。" -ForegroundColor DarkYellow
            } else {
                Write-Host "  [skip] $([string]$wanted.title)：claim 未取得，本轮跳过。" -ForegroundColor DarkYellow
            }
            continue
        }
        $selected += $wanted
    }
    if ($selected.Count -eq 0) {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Wanted Queue 无可处理条目（全部被其他 worker 持有租约）。" -ForegroundColor DarkGray
        return
    }
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] 处理 Wanted Queue：$($selected.Count) 条（worker=$WorkerId）" -ForegroundColor Cyan
    foreach ($wanted in $selected) { Process-WantedTrack -Wanted $wanted }
}

try {
    do {
        Invoke-WorkerPass
        if (-not $Once) { Start-Sleep -Seconds ([Math]::Max(5, $PollSeconds)) }
    } while (-not $Once)
} finally {
    if ($OwnsWorkerMutex) { $WorkerMutex.ReleaseMutex() }
    $WorkerMutex.Dispose()
}
