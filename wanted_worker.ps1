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
Import-Module (Join-Path $PSScriptRoot 'MusicServer.Providers.psm1') -Force
$Config = New-MusicServerConfig -Root $Root
Initialize-MusicServerState -Config $Config
Import-LegacyRecommendationState -Config $Config | Out-Null
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

function Get-LiveWanted {
    param([psobject]$Wanted)
    return @(Get-WantedTracks -Config $Config | Where-Object { [string]$_.id -eq [string]$Wanted.id } | Select-Object -First 1) | Select-Object -First 1
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
    Remove-WantedTrack -Config $Config -WantedId ([string]$Wanted.id)
    Reset-TrackToRemote -Config $Config -TrackId ([string]$Wanted.track_id) | Out-Null
    Write-StructuredEvent -Config $Config -TrackId $Wanted.track_id -Event 'WANTED_CANCELLED' -Result 'SUCCESS' -Message 'user cancelled before localization completed'
}

function Set-QueueState {
    param([psobject]$Wanted, [string]$State, [string]$Error = '', [string]$NextRetryAt = '')
    $live = Get-LiveWanted -Wanted $Wanted
    if ($live -and [string]$live.state -eq 'CANCEL_REQUESTED' -and $State -ne 'CANCEL_REQUESTED') {
        $Wanted.state = 'CANCEL_REQUESTED'
        $Wanted.last_error = 'USER_CANCELLED'
        return $false
    }
    $from = [string]$Wanted.state
    $Wanted.state = $State
    $Wanted.last_error = $Error
    $Wanted.next_retry_at = if ($NextRetryAt) { $NextRetryAt } else { $null }
    Save-WantedTrack -Config $Config -Wanted $Wanted | Out-Null
    Write-StructuredEvent -Config $Config -TrackId $Wanted.track_id -Event 'STATE_TRANSITION' -FromState $from -ToState $State -Attempt ([int]$Wanted.attempts) -ErrorType $Error
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
        Write-StructuredEvent -Config $Config -TrackId $Track.id -Provider 'netease' -Event 'LYRICS_FAILED' -ErrorType 'LYRICS_REQUEST_FAILED' -Message $_.Exception.Message
        return $false
    }
}

function Add-LegacyAcceptedRow {
    param([psobject]$Track, [string]$Path)
    $acceptedPath = Join-Path $Config.DataDir 'accepted.csv'
    $neteaseId = Get-NeteaseIdFromTrack -Track $Track
    $existing = @()
    if (Test-Path -LiteralPath $acceptedPath) { $existing = @(Import-Csv -LiteralPath $acceptedPath -Encoding UTF8) }
    if (@($existing | Where-Object { ($neteaseId -and [string]$_.NeteaseId -eq $neteaseId) -or [string]$_.File -eq [IO.Path]::GetFileName($Path) }).Count -gt 0) { return }
    $row = [pscustomobject]@{
        AcceptedAt = (Get-Date -Format 'yyyy-MM-dd'); NeteaseId = $neteaseId
        Title = $Track.title; Artist = $Track.artist; File = [IO.Path]::GetFileName($Path)
    }
    if ($existing.Count -gt 0) { $row | Export-Csv -LiteralPath $acceptedPath -NoTypeInformation -Encoding UTF8 -Append }
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
    $Path = Move-LegacyDailyMixToLibrary -Path $Path
    $songId = Get-NavidromeSongIdForPath -Config $Config -Path $Path
    Set-TrackStatus -Config $Config -TrackId $Track.id -Status 'LOCAL' -LocalSongId $songId | Out-Null
    $Wanted.selected_candidate = [pscustomobject]@{ provider = 'local'; path = $Path }
    [void](Set-QueueState -Wanted $Wanted -State 'LOCAL')
    Add-LegacyAcceptedRow -Track $Track -Path $Path
    Write-StructuredEvent -Config $Config -TrackId $Track.id -Provider 'local' -Event 'LOCAL_BOUND' -Result 'SUCCESS' -Message "path=$Path; navidrome_id=$songId"
}

function Complete-DownloadedTrack {
    param([psobject]$Track, [psobject]$Wanted, [string]$Path, [psobject]$Validation, [psobject]$Candidate, [psobject]$Score)
    if (Test-WantedCancellation -Wanted $Wanted) { Complete-WantedCancellation -Wanted $Wanted -TemporaryPath $Path; return }

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

    [void](Write-TrackLyrics -Track $Track -AudioPath $target)
    Add-LegacyAcceptedRow -Track $Track -Path $target
    Set-TrackStatus -Config $Config -TrackId $Track.id -Status 'LOCAL' | Out-Null
    $Wanted.selected_candidate = [pscustomobject]@{ provider = $Candidate.provider; url = $Candidate.url; score = $Score.score }
    [void](Set-QueueState -Wanted $Wanted -State 'LOCAL')
    Write-StructuredEvent -Config $Config -TrackId $Track.id -Provider $Candidate.provider -Event 'LOCAL' -Result 'SUCCESS' -Message "path=$target; duration=$($Validation.Duration); duration_diff=$($Validation.DurationDiff); allowed_diff=$($Validation.AllowedDiff)"
    if ((Test-Path -LiteralPath $Config.NdExe) -and (Test-Path -LiteralPath $Config.NdConfig)) {
        & $Config.NdExe -c $Config.NdConfig scan --nobanner 2>$null | Out-Null
    }
    $songId = Get-NavidromeSongIdForPath -Config $Config -Path $target
    $track = Get-CanonicalTrack -Config $Config -TrackId $Track.id
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
        Save-CanonicalTrack -Config $Config -Track $track | Out-Null
    }
}

function Process-WantedTrack {
    param([psobject]$Wanted)

    if (Test-WantedCancellation -Wanted $Wanted) {
        Complete-WantedCancellation -Wanted $Wanted
        return
    }

    $track = Get-CanonicalTrack -Config $Config -TrackId ([string]$Wanted.track_id)
    if (-not $track) {
        $Wanted.attempts = [int]$Wanted.attempts + 1
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

    Set-TrackStatus -Config $Config -TrackId $track.id -Status 'RESOLVING' | Out-Null
    if (-not (Set-QueueState -Wanted $Wanted -State 'RESOLVING')) { Complete-WantedCancellation -Wanted $Wanted; return }
    $ranked = @(Resolve-DownloadCandidates -Config $Config -Track $track)

    if (Test-WantedCancellation -Wanted $Wanted) { Complete-WantedCancellation -Wanted $Wanted; return }

    if ($ranked.Count -eq 0) {
        $Wanted.attempts = [int]$Wanted.attempts + 1
        $blockedUntil = Get-BilibiliBlockedUntil
        if ($blockedUntil) {
            Set-TrackStatus -Config $Config -TrackId $track.id -Status 'RETRY_WAIT' | Out-Null
            [void](Set-QueueState -Wanted $Wanted -State 'RETRY_WAIT' -Error 'BILIBILI_CIRCUIT_OPEN' -NextRetryAt $blockedUntil)
        } elseif ([int]$Wanted.attempts -ge [int]$Wanted.max_attempts) {
            Set-TrackStatus -Config $Config -TrackId $track.id -Status 'UNAVAILABLE' | Out-Null
            [void](Set-QueueState -Wanted $Wanted -State 'UNAVAILABLE' -Error 'NO_CANDIDATE')
        } else {
            Set-TrackStatus -Config $Config -TrackId $track.id -Status 'RETRY_WAIT' | Out-Null
            [void](Set-QueueState -Wanted $Wanted -State 'RETRY_WAIT' -Error 'NO_CANDIDATE' -NextRetryAt (Get-RetryTime -Wanted $Wanted))
        }
        return
    }

    foreach ($entry in $ranked) {
        if (Test-WantedCancellation -Wanted $Wanted) { Complete-WantedCancellation -Wanted $Wanted; return }

        $candidate = $entry.Candidate
        $score = $entry.Score
        $Wanted.selected_candidate = $candidate
        Write-StructuredEvent -Config $Config -TrackId $track.id -Provider $candidate.provider -Event 'CANDIDATE_SELECTED' -Attempt ([int]$Wanted.attempts) -Message "score=$($score.score); identity=$($score.identity_confidence); duration_diff=$($score.duration_diff)"
        if ($candidate.provider -eq 'local') {
            Bind-LocalTrack -Track $track -Wanted $Wanted -Path $candidate.url
            return
        }

        Set-TrackStatus -Config $Config -TrackId $track.id -Status 'DOWNLOADING' | Out-Null
        if (-not (Set-QueueState -Wanted $Wanted -State 'DOWNLOADING')) { Complete-WantedCancellation -Wanted $Wanted; return }
        if (Test-WantedCancellation -Wanted $Wanted) { Complete-WantedCancellation -Wanted $Wanted; return }

        $download = Invoke-BilibiliDownload -Config $Config -Track $track -Candidate $candidate
        if (Test-WantedCancellation -Wanted $Wanted) {
            Complete-WantedCancellation -Wanted $Wanted -TemporaryPath ([string]$download.Path)
            return
        }

        if (-not $download.Success) {
            if ($download.Blocked) {
                $Wanted.attempts = [int]$Wanted.attempts + 1
                Set-TrackStatus -Config $Config -TrackId $track.id -Status 'RETRY_WAIT' | Out-Null
                [void](Set-QueueState -Wanted $Wanted -State 'RETRY_WAIT' -Error $download.Error -NextRetryAt (Get-RetryTime -Wanted $Wanted -Provider 'bilibili_download'))
                return
            }
            Write-StructuredEvent -Config $Config -TrackId $track.id -Provider $candidate.provider -Event 'DOWNLOAD_FAILED' -Attempt ([int]$Wanted.attempts) -ErrorType $download.Error
            continue
        }

        Set-TrackStatus -Config $Config -TrackId $track.id -Status 'VALIDATING' | Out-Null
        if (-not (Set-QueueState -Wanted $Wanted -State 'VALIDATING')) {
            Complete-WantedCancellation -Wanted $Wanted -TemporaryPath $download.Path
            return
        }
        $validation = Validate-DownloadedCandidate -Config $Config -Track $track -Path $download.Path
        Write-StructuredEvent -Config $Config -TrackId $track.id -Provider $candidate.provider -Event 'VALIDATION' -Result $validation.Reason -Message "duration=$($validation.Duration); expected=$($track.duration); diff=$($validation.DurationDiff); allowed=$($validation.AllowedDiff)"

        if (Test-WantedCancellation -Wanted $Wanted) {
            Complete-WantedCancellation -Wanted $Wanted -TemporaryPath $download.Path
            return
        }
        if (-not $validation.Valid) {
            Remove-Item -LiteralPath $download.Path -Force -ErrorAction SilentlyContinue
            if ($validation.Reason -eq 'WRONG_DURATION') { continue }
            break
        }
        Complete-DownloadedTrack -Track $track -Wanted $Wanted -Path $download.Path -Validation $validation -Candidate $candidate -Score $score
        return
    }

    if (Test-WantedCancellation -Wanted $Wanted) { Complete-WantedCancellation -Wanted $Wanted; return }
    $Wanted.attempts = [int]$Wanted.attempts + 1
    if ([int]$Wanted.attempts -ge [int]$Wanted.max_attempts) {
        Set-TrackStatus -Config $Config -TrackId $track.id -Status 'UNAVAILABLE' | Out-Null
        [void](Set-QueueState -Wanted $Wanted -State 'UNAVAILABLE' -Error 'ALL_CANDIDATES_FAILED')
    } else {
        Set-TrackStatus -Config $Config -TrackId $track.id -Status 'RETRY_WAIT' | Out-Null
        [void](Set-QueueState -Wanted $Wanted -State 'RETRY_WAIT' -Error 'ALL_CANDIDATES_FAILED' -NextRetryAt (Get-RetryTime -Wanted $Wanted))
    }
}

function Invoke-WorkerPass {
    $queue = @(Get-WantedTracks -Config $Config -EligibleOnly)
    if ($queue.Count -eq 0) {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Wanted Queue 为空。" -ForegroundColor DarkGray
        return
    }
    $selected = @($queue | Select-Object -First $MaxItems)
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] 处理 Wanted Queue：$($selected.Count) 条" -ForegroundColor Cyan
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
