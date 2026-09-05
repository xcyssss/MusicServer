Import-Module (Join-Path $PSScriptRoot 'MusicServer.Core.psm1') -Force
Set-StrictMode -Version 3.0
Import-Module (Join-Path $PSScriptRoot 'MusicServer.State.psm1') -Force

function New-DownloadCandidate {
    param(
        [Parameter(Mandatory)][string]$Provider,
        [string]$Url = '',
        [string]$Bvid = '',
        [string]$Title = '',
        [string]$Artist = '',
        [int]$Duration = 0,
        [int]$Priority = 0,
        [bool]$RequiresSearch = $false,
        [object]$Metadata = $null
    )
    return [pscustomobject]@{
        provider = $Provider; url = $Url; bvid = $Bvid; title = $Title; artist = $Artist
        duration = $Duration; priority = $Priority; requires_search = $RequiresSearch
        metadata = $Metadata
    }
}

function Ensure-ProviderDatabase {
    param([Parameter(Mandatory)][psobject]$Config)
    $dbPath = Join-Path $Config.StateDir 'musicserver.db'
    Initialize-MusicServerDatabase -DbPath $dbPath -SqliteExe $Config.Sqlite
    Initialize-MusicServerSchema
}

function Get-ProviderHealth {
    param([Parameter(Mandatory)][psobject]$Config, [Parameter(Mandatory)][string]$Provider)
    Ensure-ProviderDatabase -Config $Config | Out-Null
    return (Get-ProviderHealthDb -Provider $Provider)
}

function Save-ProviderHealth {
    param([Parameter(Mandatory)][psobject]$Config, [Parameter(Mandatory)][psobject]$Health)
    Ensure-ProviderDatabase -Config $Config | Out-Null
    if ($Health.PSObject.Properties['probe_pending']) {
        $Health | Add-Member -NotePropertyName half_open_probe_claimed -NotePropertyValue ([int]([bool]$Health.probe_pending)) -Force
    }
    Save-ProviderHealthDb -Health $Health | Out-Null
    return $Health
}

function Get-ProviderStatuses {
    param([Parameter(Mandatory)][psobject]$Config)
    $names = @('local','bilibili_search','bilibili_download')
    return @($names | ForEach-Object { Get-ProviderHealth -Config $Config -Provider $_ })
}

function Test-ProviderRequestAvailable {
    param([Parameter(Mandatory)][psobject]$Config, [Parameter(Mandatory)][string]$Provider)
    $health = Get-ProviderHealth -Config $Config -Provider $Provider
    $state = [string]$health.state
    if ($state -eq 'CLOSED') { return $true }
    if ($state -eq 'HALF_OPEN') { return [bool]$health.probe_pending }
    if ($state -ne 'OPEN') { return $true }
    if (-not $health.blocked_until) { return $true }
    $blocked = Convert-ToUtcDateTime $health.blocked_until
    return (-not $blocked -or $blocked -le [DateTime]::UtcNow)
}

function Claim-ProviderRequest {
    param(
        [Parameter(Mandatory)][psobject]$Config,
        [Parameter(Mandatory)][string]$Provider,
        [int]$ProbeCooldownMinutes = 15
    )
    Ensure-ProviderDatabase -Config $Config | Out-Null
    $health = Get-ProviderHealth -Config $Config -Provider $Provider
    $now = [DateTime]::UtcNow
    if ([string]$health.state -eq 'OPEN') {
        $blocked = $null
        if ($health.blocked_until) { $blocked = Convert-ToUtcDateTime $health.blocked_until }
        if ($blocked -and $blocked -gt $now) { return $false }
        if (-not (Claim-HalfOpenProbeDb -Provider $Provider)) { return $false }
        Write-MusicServerEventDb -Provider $Provider -EventType 'CIRCUIT_HALF_OPEN' -Message 'cooldown elapsed; one real request probe permitted'
        return $true
    }
    if ([string]$health.state -eq 'HALF_OPEN') {
        return [bool](Claim-HalfOpenProbeDb -Provider $Provider)
    }
    return $true
}

function Record-ProviderSuccess {
    param(
        [Parameter(Mandatory)][psobject]$Config,
        [Parameter(Mandatory)][string]$Provider,
        [double]$LatencyMs = 0
    )
    $health = Get-ProviderHealth -Config $Config -Provider $Provider
    $oldCount = [int]$health.success_count
    $health.success_count = $oldCount + 1
    $health.consecutive_failures = 0
    $health.consecutive_412 = 0
    $health.last_success = Get-NowIso
    $health.state = 'CLOSED'
    $health.blocked_until = $null
    $health.probe_pending = $false
    if ($LatencyMs -gt 0) {
        if ([double]$health.average_latency_ms -le 0) { $health.average_latency_ms = $LatencyMs }
        else { $health.average_latency_ms = (([double]$health.average_latency_ms * $oldCount) + $LatencyMs) / ($oldCount + 1) }
    }
    Save-ProviderHealth -Config $Config -Health $health | Out-Null
}

function Record-ProviderFailure {
    param(
        [Parameter(Mandatory)][psobject]$Config,
        [Parameter(Mandatory)][string]$Provider,
        [int]$HttpStatus = 0,
        [string]$ErrorType = 'PROVIDER_ERROR',
        [string]$Message = '',
        [int]$BaseCooldownMinutes = 15,
        [int]$MaxCooldownMinutes = 360
    )
    $health = Get-ProviderHealth -Config $Config -Provider $Provider
    $health.failure_count = [int]$health.failure_count + 1
    $health.consecutive_failures = [int]$health.consecutive_failures + 1
    $health.last_failure = Get-NowIso
    if ($HttpStatus -eq 412) {
        $health.consecutive_412 = [int]$health.consecutive_412 + 1
        $health.last_412_at = Get-NowIso
        $minutes = [Math]::Min($MaxCooldownMinutes, $BaseCooldownMinutes * [Math]::Pow(2, [int]$health.consecutive_412 - 1))
        $health.blocked_until = [DateTime]::UtcNow.AddMinutes($minutes).ToString('o')
        $health.state = 'OPEN'
        $health.probe_pending = $false
        Save-ProviderHealth -Config $Config -Health $health | Out-Null
        Write-MusicServerEventDb -Provider $Provider -EventType 'CIRCUIT_OPEN' -ErrorType 'HTTP_412' -HttpStatus 412 -Message "blocked_until=$($health.blocked_until); cooldown_minutes=$minutes"
    } else {
        Save-ProviderHealth -Config $Config -Health $health | Out-Null
    }
    return $health
}

function Get-AllowedDurationDrift {
    param([int]$ExpectedDuration)
    if ($ExpectedDuration -le 0) { return 20 }
    return [int][Math]::Max(8, [Math]::Min(20, [Math]::Ceiling($ExpectedDuration * 0.05)))
}

function Get-CandidateScore {
    param([Parameter(Mandatory)][psobject]$Track, [Parameter(Mandatory)][psobject]$Candidate, [psobject]$Health = $null)

    $titleKey = Normalize-MusicText $Track.title
    $artistKey = Normalize-MusicText $Track.artist
    $candidateTitle = Normalize-MusicText $Candidate.title
    $candidateArtist = Normalize-MusicText $Candidate.artist
    $identity = 0
    if ($Candidate.provider -eq 'local') { $identity += 100 }
    if ($titleKey -and $candidateTitle) {
        if ($candidateTitle -eq $titleKey) { $identity += 45 }
        elseif ($candidateTitle.Contains($titleKey) -or $titleKey.Contains($candidateTitle)) { $identity += 25 }
        else { $identity -= 40 }
    }
    if ($artistKey -and $candidateArtist) {
        if ($candidateArtist.Contains($artistKey) -or $artistKey.Contains($candidateArtist)) { $identity += 35 }
        else { $identity -= 25 }
    }
    $durationDiff = 0
    if ([int]$Track.duration -gt 0 -and [int]$Candidate.duration -gt 0) {
        $durationDiff = [Math]::Abs([int]$Track.duration - [int]$Candidate.duration)
        if ($durationDiff -le 5) { $identity += 20 }
        elseif ($durationDiff -le (Get-AllowedDurationDrift -ExpectedDuration ([int]$Track.duration))) { $identity += 8 }
        else { $identity -= 100 }
    }

    $reliability = switch ([string]$Candidate.provider) {
        'local' { 100 }
        'bilibili_direct' { 70 }
        'bilibili_search' { 30 }
        default { 40 }
    }
    $cost = switch ([string]$Candidate.provider) {
        'local' { 0 }
        'bilibili_direct' { 5 }
        'bilibili_search' { 35 }
        default { 20 }
    }
    $healthPenalty = 0
    if ($Health) {
        $healthPenalty = [Math]::Min(40, [int]$Health.consecutive_failures * 5)
        if ([string]$Health.state -eq 'OPEN') { $healthPenalty += 1000 }
    }
    $score = $identity + $reliability - $cost - $healthPenalty + [int]$Candidate.priority
    return [pscustomobject]@{ score = [double]$score; identity_confidence = $identity; duration_diff = $durationDiff; request_cost = $cost; rate_limit_penalty = $healthPenalty }
}

function Test-DownloadCandidateIdentity {
    param([Parameter(Mandatory)][psobject]$Track, [Parameter(Mandatory)][psobject]$Candidate)

    if ([string]$Candidate.provider -eq 'local') { return $true }
    $expectedDuration = [int]$Track.duration
    $candidateDuration = [int]$Candidate.duration
    if ($expectedDuration -gt 0 -and $candidateDuration -gt 0) {
        $diff = [Math]::Abs($expectedDuration - $candidateDuration)
        if ($diff -gt (Get-AllowedDurationDrift -ExpectedDuration $expectedDuration)) { return $false }
    }
    if ([string]$Candidate.provider -eq 'bilibili_direct') { return $true }

    $titleKey = Normalize-MusicText ([string]$Track.title)
    $candidateTitle = Normalize-MusicText ([string]$Candidate.title)
    if (-not $titleKey -or -not $candidateTitle) { return $false }
    $titleEvidence = ($candidateTitle -eq $titleKey) -or $candidateTitle.Contains($titleKey) -or $titleKey.Contains($candidateTitle)
    if (-not $titleEvidence) { return $false }

    $artistKeys = @([string]$Track.artist -split '[,，、/&]' | ForEach-Object { Normalize-MusicText $_ } | Where-Object { $_ })
    if ($artistKeys.Count -eq 0) { return $true }
    $candidateArtist = Normalize-MusicText ([string]$Candidate.artist)
    $artistEvidence = $false
    foreach ($artistKey in $artistKeys) {
        if (($candidateArtist -and $candidateArtist.Contains($artistKey)) -or $candidateTitle.Contains($artistKey)) {
            $artistEvidence = $true
            break
        }
    }
    if ($artistEvidence) { return $true }

    # Some clean music uploads use an exact song title but the uploader is not the artist.
    # Only accept that fallback when duration is also extremely close.
    if ($candidateTitle -eq $titleKey -and $expectedDuration -gt 0 -and $candidateDuration -gt 0) {
        return ([Math]::Abs($expectedDuration - $candidateDuration) -le 5)
    }
    return $false
}

function Get-SafeDownloadName {
    param([Parameter(Mandatory)][psobject]$Track)
    $artist = if ($Track.artist) { ($Track.artist -split '[,，、]')[0] } else { 'Unknown Artist' }
    $name = "$($Track.title) - $artist" -replace '[\\/:*?"<>|]', '_'
    return $name.Trim().TrimEnd('.')
}

function Search-BilibiliCandidates {
    param([Parameter(Mandatory)][psobject]$Config, [Parameter(Mandatory)][psobject]$Track)
    if (-not (Claim-ProviderRequest -Config $Config -Provider 'bilibili_search')) {
        return [pscustomobject]@{ Candidates = @(); Blocked = $true; Error = 'CIRCUIT_OPEN'; HttpStatus = 0 }
    }
    $keyword = "$($Track.title) $(($Track.artist -split '[,，、]')[0])".Trim()
    $args = @(
        "bilisearch10:$keyword", '--flat-playlist', '--dump-single-json', '--playlist-end', '10',
        '--no-warnings', '--skip-download', '--socket-timeout', '20'
    )
    if (Test-Path -LiteralPath $Config.CookieFile) { $args += @('--cookies', $Config.CookieFile) }
    $started = [Diagnostics.Stopwatch]::StartNew()
    $output = @(& $Config.YtDlp @args 2>&1)
    $started.Stop()
    $joined = ($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
    if ($joined -match '412|Precondition Failed') {
        Record-ProviderFailure -Config $Config -Provider 'bilibili_search' -HttpStatus 412 -ErrorType 'HTTP_412' -Message 'search metadata request blocked' | Out-Null
        return [pscustomobject]@{ Candidates = @(); Blocked = $true; Error = 'HTTP_412'; HttpStatus = 412 }
    }
    if ($LASTEXITCODE -ne 0) {
        Record-ProviderFailure -Config $Config -Provider 'bilibili_search' -ErrorType 'SEARCH_FAILED' -Message ($joined | Select-Object -Last 1) | Out-Null
        return [pscustomobject]@{ Candidates = @(); Blocked = $false; Error = 'SEARCH_FAILED'; HttpStatus = 0 }
    }
    try {
        $json = $joined | ConvertFrom-Json
        $entries = if ($json.entries) { @($json.entries) } else { @($json) }
        $results = foreach ($entry in $entries) {
            if (-not $entry.id) { continue }
            $url = if ($entry.webpage_url) { [string]$entry.webpage_url } else { "https://www.bilibili.com/video/$($entry.id)" }
            # uploader is an UP account, not reliable song-artist metadata. Keep it in metadata only.
            New-DownloadCandidate -Provider 'bilibili_search' -Url $url -Bvid ([string]$entry.id) `
                -Title ([string]$entry.title) -Artist '' -Duration ([int]$entry.duration) -Priority 10 -Metadata $entry
        }
        Record-ProviderSuccess -Config $Config -Provider 'bilibili_search' -LatencyMs $started.Elapsed.TotalMilliseconds
        return [pscustomobject]@{ Candidates = @($results); Blocked = $false; Error = ''; HttpStatus = 0 }
    } catch {
        Record-ProviderFailure -Config $Config -Provider 'bilibili_search' -ErrorType 'INVALID_SEARCH_RESPONSE' -Message $_.Exception.Message | Out-Null
        return [pscustomobject]@{ Candidates = @(); Blocked = $false; Error = 'INVALID_SEARCH_RESPONSE'; HttpStatus = 0 }
    }
}

function Get-DirectCandidates {
    param([Parameter(Mandatory)][psobject]$Track)
    $items = @($Track.download_candidates) | Where-Object {
        [string](Get-OptionalProperty $_ 'provider') -eq 'bilibili_direct' -and
        ((Get-OptionalProperty $_ 'url') -or (Get-OptionalProperty $_ 'bvid'))
    }
    return @($items | ForEach-Object {
        $urlValue = Get-OptionalProperty $_ 'url'
        $bvidValue = Get-OptionalProperty $_ 'bvid'
        $url = if ($urlValue) { [string]$urlValue } else { "https://www.bilibili.com/video/$bvidValue" }
        $durationValue = Get-OptionalProperty $_ 'duration' 0
        $duration = if ($durationValue) { [int]$durationValue } else { [int]$Track.duration }
        $priority = [int](Get-OptionalProperty $_ 'priority' 0)
        New-DownloadCandidate -Provider 'bilibili_direct' -Url $url -Bvid ([string]$bvidValue) `
            -Title ([string]$Track.title) -Artist ([string]$Track.artist) -Duration $duration -Priority $priority -Metadata $_
    })
}

function Resolve-DownloadCandidates {
    param([Parameter(Mandatory)][psobject]$Config, [Parameter(Mandatory)][psobject]$Track)
    $candidates = @()
    $local = Find-LocalTrack -Config $Config -Title $Track.title -Artist $Track.artist
    if ($local) {
        $localCandidate = New-DownloadCandidate -Provider 'local' -Url $local.File.FullName -Title $Track.title -Artist $Track.artist -Duration ([int]$Track.duration) -Priority 100 -Metadata $local
        return @([pscustomobject]@{ Candidate = $localCandidate; Score = (Get-CandidateScore -Track $Track -Candidate $localCandidate -Health $null) })
    }

    # NetEase direct download first when the track has a NetEase id: free songs
    # are served as full 320kbps audio without Bilibili's 412 risk control.
    $neteaseCandidate = Get-NeteaseCandidate -Config $Config -Track $Track
    if ($neteaseCandidate) { $candidates += $neteaseCandidate }

    # Direct candidates are known resources. Resolving them must stay metadata-only:
    # do not consume a search request, require yt-dlp, or claim a download probe yet.
    $direct = @(Get-DirectCandidates -Track $Track)
    $hasDirectCandidates = ($direct.Count -gt 0)
    if ($hasDirectCandidates) {
        if (-not (Test-ProviderRequestAvailable -Config $Config -Provider 'bilibili_download')) { return @() }
        $candidates += $direct
    }

    # Search is a fallback only when no known direct Bilibili candidate exists.
    # A NetEase candidate is still only a try (VIP/paid tracks can have no URL),
    # so pair it with search when the search circuit is available.
    if (-not $hasDirectCandidates) {
        if (Test-ProviderRequestAvailable -Config $Config -Provider 'bilibili_search') {
            $search = Search-BilibiliCandidates -Config $Config -Track $Track
            if (-not $search.Blocked) { $candidates += $search.Candidates }
        } elseif (-not $neteaseCandidate) {
            return @()
        }
    }

    $downloadHealth = Get-ProviderHealth -Config $Config -Provider 'bilibili_download'
    $ranked = foreach ($candidate in $candidates) {
        if ($candidate.provider -like 'bilibili*' -and -not (Test-ProviderRequestAvailable -Config $Config -Provider 'bilibili_download')) { continue }
        if (-not (Test-DownloadCandidateIdentity -Track $Track -Candidate $candidate)) { continue }
        $score = Get-CandidateScore -Track $Track -Candidate $candidate -Health $(if ($candidate.provider -like 'bilibili*') { $downloadHealth } else { $null })
        [pscustomobject]@{ Candidate = $candidate; Score = $score }
    }
    return @($ranked | Sort-Object @{Expression={$_.Score.score};Descending=$true})
}

function Validate-DownloadedCandidate {
    param([Parameter(Mandatory)][psobject]$Config, [Parameter(Mandatory)][psobject]$Track, [Parameter(Mandatory)][string]$Path, [int]$ToleranceSeconds = 0)
    $duration = 0
    if (Test-Path -LiteralPath $Config.FFprobe) {
        try {
            $raw = & $Config.FFprobe -v error -show_entries format=duration -of csv=p=0 $Path 2>$null
            if ($raw) { $duration = [int][double]$raw }
        } catch {}
    }
    if ($duration -le 0) { return [pscustomobject]@{ Valid = $false; Duration = 0; DurationDiff = 0; AllowedDiff = 0; Reason = 'FFPROBE_FAILED' } }
    $diff = if ([int]$Track.duration -gt 0) { [Math]::Abs($duration - [int]$Track.duration) } else { 0 }
    $allowed = if ($ToleranceSeconds -gt 0) { $ToleranceSeconds } else { Get-AllowedDurationDrift -ExpectedDuration ([int]$Track.duration) }
    return [pscustomobject]@{ Valid = ($diff -le $allowed); Duration = $duration; DurationDiff = $diff; AllowedDiff = $allowed; Reason = if ($diff -le $allowed) { 'PASS' } else { 'WRONG_DURATION' } }
}

function Invoke-BilibiliDownload {
    param([Parameter(Mandatory)][psobject]$Config, [Parameter(Mandatory)][psobject]$Track, [Parameter(Mandatory)][psobject]$Candidate)
    if (-not (Claim-ProviderRequest -Config $Config -Provider 'bilibili_download')) { return [pscustomobject]@{ Success = $false; Blocked = $true; Error = 'CIRCUIT_OPEN'; Path = '' } }
    Initialize-MusicServerState -Config $Config
    $target = Join-Path $Config.DailyDir "$(Get-SafeDownloadName -Track $Track).mp3"
    # DailyDir is a staging area. Never let a stale partial file masquerade as a successful new download.
    if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue }
    $args = @(
        '--extract-audio', '--audio-format', 'mp3', '--audio-quality', '0', '-o', $target,
        '--embed-thumbnail', '--embed-metadata', '--no-overwrites', '--no-playlist',
        '-f', 'bestaudio/best', '--no-progress', '--no-warnings',
        '--retries', '1', '--fragment-retries', '1', '--extractor-retries', '1', '--socket-timeout', '30',
        $Candidate.url
    )
    if (Test-Path -LiteralPath $Config.CookieFile) { $args += @('--cookies', $Config.CookieFile) }
    $started = [Diagnostics.Stopwatch]::StartNew()
    $output = @(& $Config.YtDlp @args 2>&1)
    $started.Stop()
    $joined = ($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
    if ($joined -match '412|Precondition Failed') {
        Record-ProviderFailure -Config $Config -Provider 'bilibili_download' -HttpStatus 412 -ErrorType 'HTTP_412' -Message 'download request blocked' | Out-Null
        return [pscustomobject]@{ Success = $false; Blocked = $true; Error = 'HTTP_412'; Path = ''; Output = $joined }
    }
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $target)) {
        Record-ProviderFailure -Config $Config -Provider 'bilibili_download' -ErrorType 'DOWNLOAD_FAILED' -Message ($joined | Select-Object -Last 1) | Out-Null
        return [pscustomobject]@{ Success = $false; Blocked = $false; Error = 'DOWNLOAD_FAILED'; Path = ''; Output = $joined }
    }
    Record-ProviderSuccess -Config $Config -Provider 'bilibili_download' -LatencyMs $started.Elapsed.TotalMilliseconds
    return [pscustomobject]@{ Success = $true; Blocked = $false; Error = ''; Path = $target; Output = $joined }
}

function Get-NeteaseIdFromTrack {
    param([Parameter(Mandatory)][psobject]$Track)
    try {
        $ids = @($Track.identifiers) | Where-Object { $_ -and $_.PSObject.Properties['type'] -and [string]$_.type -eq 'netease' -and [string]$_.value } | Select-Object -First 1
        if ($ids) { return [string]$ids.value }
    } catch {}
    try {
        if ($Track.PSObject.Properties['netease_id'] -and [string]$Track.netease_id) { return [string]$Track.netease_id }
    } catch {}
    return ''
}

function Get-NeteaseCandidate {
    <#
    .SYNOPSIS
      Builds a download candidate for the track's NetEase id (if any). The
      NetEase open API (api/song/enhance/player/url) returns full 320kbps
      audio for free songs and is not subject to Bilibili's 412 risk control,
      so it is tried before any Bilibili search.
    #>
    param([Parameter(Mandatory)][psobject]$Config, [Parameter(Mandatory)][psobject]$Track)
    $neteaseId = Get-NeteaseIdFromTrack -Track $Track
    if (-not $neteaseId) { return $null }
    return New-DownloadCandidate -Provider 'netease' -Url "netease:$neteaseId" -Title $Track.title -Artist $Track.artist -Duration ([int]$Track.duration) -Priority 60 -RequiresSearch $false -Metadata ([pscustomobject]@{ netease_id = $neteaseId })
}

function Invoke-NeteaseDownload {
    <#
    .SYNOPSIS
      Downloads the full audio for a NetEase track id using the legacy open API
      endpoint that does not require encrypted weapi params. Free songs (fee=0)
      return a full-length 320kbps mp3 URL; VIP/paid songs return no usable URL
      and are reported as a normal failure so the caller can fall through to
      Bilibili. Mirrors the result shape of Invoke-BilibiliDownload.
    #>
    param([Parameter(Mandatory)][psobject]$Config, [Parameter(Mandatory)][psobject]$Track, [Parameter(Mandatory)][psobject]$Candidate)
    $neteaseId = Get-NeteaseIdFromTrack -Track $Track
    if (-not $neteaseId) {
        $m = $Candidate.metadata
        if ($m -and $m.PSObject.Properties['netease_id']) { $neteaseId = [string]$m.netease_id }
    }
    if (-not $neteaseId) {
        return [pscustomobject]@{ Success = $false; Blocked = $false; Error = 'NO_NETEASE_ID'; Path = ''; Output = '' }
    }
    $headers = @{
        'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/124 Safari/537.36'
        'Referer' = 'https://music.163.com/'
        'Accept' = 'application/json,text/plain,*/*'
    }
    $target = Join-Path $Config.DailyDir "$(Get-SafeDownloadName -Track $Track).mp3"
    if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue }
    $started = [Diagnostics.Stopwatch]::StartNew()
    try {
        $resp = Invoke-RestMethod -Uri "https://music.163.com/api/song/enhance/player/url?ids=%5B$neteaseId%5D&br=320000" -Headers $headers -TimeoutSec 20
        $started.Stop()
        $datum = $null
        if ($resp.data -and $resp.data.Count -gt 0) { $datum = $resp.data[0] }
        $audioUrl = if ($datum) { [string]$datum.url } else { '' }
        if (-not $audioUrl) {
            # VIP/paid or region-locked: report NOT_AVAILABLE, caller falls back to Bilibili.
            return [pscustomobject]@{ Success = $false; Blocked = $false; Error = 'NETEASE_NOT_AVAILABLE'; Path = ''; Output = '' }
        }
        Invoke-WebRequest -Uri $audioUrl -Headers @{ 'User-Agent' = $headers['User-Agent']; 'Referer' = 'https://music.163.com/' } -OutFile $target -TimeoutSec 120
        if (-not (Test-Path -LiteralPath $target) -or (Get-Item -LiteralPath $target).Length -lt 10000) {
            Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
            return [pscustomobject]@{ Success = $false; Blocked = $false; Error = 'NETEASE_DOWNLOAD_EMPTY'; Path = ''; Output = '' }
        }
        Record-ProviderSuccess -Config $Config -Provider 'netease' -LatencyMs $started.Elapsed.TotalMilliseconds
        return [pscustomobject]@{ Success = $true; Blocked = $false; Error = ''; Path = $target; Output = '' }
    } catch {
        $started.Stop()
        Record-ProviderFailure -Config $Config -Provider 'netease' -ErrorType 'NETEASE_REQUEST_FAILED' -Message $_.Exception.Message | Out-Null
        return [pscustomobject]@{ Success = $false; Blocked = $false; Error = 'NETEASE_REQUEST_FAILED'; Path = ''; Output = $_.Exception.Message }
    }
}

function New-DownloadProviderRegistry {
    return @(
        [pscustomobject]@{
            name = 'local'; health_provider = 'local'
            can_handle = { param($track) $true }
            search = { param($config, $track) $local = Find-LocalTrack -Config $config -Title $track.title -Artist $track.artist; if ($local) { ,(New-DownloadCandidate -Provider 'local' -Url $local.File.FullName -Title $track.title -Artist $track.artist -Duration ([int]$track.duration) -Priority 100 -Metadata $local) } }
            score = { param($track, $candidate) Get-CandidateScore -Track $track -Candidate $candidate }
            download = { param($config, $track, $candidate) [pscustomobject]@{ Success = $true; Path = $candidate.url; Blocked = $false; Error = '' } }
            validate = { param($config, $track, $path) Validate-DownloadedCandidate -Config $config -Track $track -Path $path }
        }
        [pscustomobject]@{
            name = 'bilibili_direct'; health_provider = 'bilibili_download'
            can_handle = { param($track) @(Get-DirectCandidates -Track $track).Count -gt 0 }
            search = { param($config, $track) Get-DirectCandidates -Track $track }
            score = { param($track, $candidate) Get-CandidateScore -Track $track -Candidate $candidate -Health (Get-ProviderHealth -Config $config -Provider 'bilibili_download') }
            download = { param($config, $track, $candidate) Invoke-BilibiliDownload -Config $config -Track $track -Candidate $candidate }
            validate = { param($config, $track, $path) Validate-DownloadedCandidate -Config $config -Track $track -Path $path }
        }
        [pscustomobject]@{
            name = 'bilibili_search'; health_provider = 'bilibili_search'
            can_handle = { param($track) $true }
            search = { param($config, $track) (Search-BilibiliCandidates -Config $config -Track $track).Candidates }
            score = { param($track, $candidate) Get-CandidateScore -Track $track -Candidate $candidate -Health (Get-ProviderHealth -Config $config -Provider 'bilibili_download') }
            download = { param($config, $track, $candidate) Invoke-BilibiliDownload -Config $config -Track $track -Candidate $candidate }
            validate = { param($config, $track, $path) Validate-DownloadedCandidate -Config $config -Track $track -Path $path }
        }
    )
}

Export-ModuleMember -Function *