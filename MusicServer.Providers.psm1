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
    # HALF_OPEN means the cooldown elapsed and one probe is permitted. Exclusivity
    # is enforced by Claim-ProviderRequest -> Claim-HalfOpenProbeDb, so reporting
    # availability here is what lets the probe actually happen. Returning
    # probe_pending instead deadlocked the circuit: nobody claims the probe that
    # would set it.
    if ($state -eq 'HALF_OPEN') { return $true }
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
        }
        # Only reach for NetEase discovery when the healthy path has nothing to
        # offer yet; a track that already carries a NetEase id never searches.
        if ($candidates.Count -eq 0) {
            $discovered = Search-NeteaseCandidate -Config $Config -Track $Track
            if ($discovered) { $candidates += $discovered; $neteaseCandidate = $discovered }
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

function Select-NeteaseSearchMatch {
    <#
    .SYNOPSIS
      Picks the best NetEase search result for a track, or $null when nothing
      passes the shared identity checks. Pure (no HTTP) so it can be tested
      deterministically.
    #>
    param([Parameter(Mandatory)][psobject]$Track, [psobject]$Songs)

    $match = $null
    $matchScore = [int]::MinValue
    foreach ($song in @($Songs)) {
        if (-not $song) { continue }
        $songId = [string](Get-OptionalProperty $song 'id' '')
        if (-not $songId) { continue }
        $artistNames = @(@(Get-OptionalProperty $song 'artists' @()) | ForEach-Object { [string](Get-OptionalProperty $_ 'name' '') } | Where-Object { $_ })
        $durationSeconds = [int][Math]::Round(([double](Get-OptionalProperty $song 'duration' 0)) / 1000)
        $candidate = New-DownloadCandidate -Provider 'netease' -Url "netease:$songId" -Title ([string](Get-OptionalProperty $song 'name' '')) `
            -Artist ($artistNames -join ',') -Duration $durationSeconds -Priority 50 -RequiresSearch $true `
            -Metadata ([pscustomobject]@{ netease_id = $songId })
        if (-not (Test-DownloadCandidateIdentity -Track $Track -Candidate $candidate)) { continue }
        $score = [int](Get-CandidateScore -Track $Track -Candidate $candidate).score
        if (-not $match -or $score -gt $matchScore) { $match = $candidate; $matchScore = $score }
    }
    return $match
}

function Search-NeteaseCandidate {
    <#
    .SYNOPSIS
      Bounded NetEase discovery for a track that carries no NetEase id.

      Bilibili search is subject to HTTP 412 risk control, so tracks seeded from
      the local library or Navidrome stars could end up with zero candidates and
      were eventually parked as UNAVAILABLE. This helper performs at most ONE
      NetEase search request per call, charged against the existing `netease`
      provider circuit, and returns a normal download candidate when the best
      match passes the same identity checks used everywhere else. Set
      MUSICSERVER_DISABLE_NETEASE_SEARCH=1 to disable it (hermetic tests).
    #>
    param([Parameter(Mandatory)][psobject]$Config, [Parameter(Mandatory)][psobject]$Track)

    if ($env:MUSICSERVER_DISABLE_NETEASE_SEARCH -eq '1') { return $null }
    if (Get-NeteaseIdFromTrack -Track $Track) { return $null }
    $keyword = "$($Track.title) $(($Track.artist -split '[,，、/&]')[0])".Trim()
    if (-not $keyword) { return $null }
    if (-not (Test-ProviderRequestAvailable -Config $Config -Provider 'netease')) { return $null }
    if (-not (Claim-ProviderRequest -Config $Config -Provider 'netease')) { return $null }

    $headers = @{
        'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0 Safari/537.36'
        'Referer'    = 'https://music.163.com/'
    }
    $started = [Diagnostics.Stopwatch]::StartNew()
    try {
        $url = "https://music.163.com/api/search/get?s=$([uri]::EscapeDataString($keyword))&type=1&limit=5"
        $response = Invoke-RestMethod -Uri $url -Headers $headers -TimeoutSec 20
    } catch {
        Record-ProviderFailure -Config $Config -Provider 'netease' -ErrorType 'SEARCH_FAILED' -Message $_.Exception.Message | Out-Null
        return $null
    }
    $started.Stop()

    $songs = @()
    try { if ($response.result.songs) { $songs = @($response.result.songs) } } catch { $songs = @() }
    $match = Select-NeteaseSearchMatch -Track $Track -Songs $songs
    Record-ProviderSuccess -Config $Config -Provider 'netease' -LatencyMs $started.Elapsed.TotalMilliseconds
    return $match
}

function Get-SharedTitlePrefixes {
    <#
    .SYNOPSIS
      Runs of text shared by several titles in one library.

      A prefix repeated at the start of many titles is channel branding, not part
      of any artist's name ("在百万豪装录音棚大声听 ..."). It must end on a boundary
      character, otherwise a repeated real artist name ("许嵩《...》" several times)
      would be mistaken for branding and stripped.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Titles,
        [int]$MinimumCount = 4,
        [int]$MinimumLength = 4,
        [int]$MaximumLength = 30
    )

    $counts = @{}
    foreach ($entry in @($Titles)) {
        $text = [string]$entry
        if ([string]::IsNullOrEmpty($text)) { continue }
        $upper = [Math]::Min($MaximumLength, $text.Length)
        for ($length = $MinimumLength; $length -le $upper; $length++) {
            $prefix = $text.Substring(0, $length)
            if (-not [regex]::IsMatch($prefix, '[】\]）)\s\-–—｜|：:·、,，。!！?？]$')) { continue }
            if ($counts.ContainsKey($prefix)) { $counts[$prefix] = $counts[$prefix] + 1 } else { $counts[$prefix] = 1 }
        }
    }
    return @($counts.Keys | Where-Object { $counts[$_] -ge $MinimumCount } | Sort-Object -Property Length -Descending)
}

function Remove-SharedTitlePrefix {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Title,
        [AllowEmptyCollection()][string[]]$Prefixes = @()
    )

    if ([string]::IsNullOrWhiteSpace($Title)) { return $Title }
    if (@($Prefixes).Count -eq 0) { return $Title }
    $longest = ''
    foreach ($prefix in @($Prefixes)) {
        if ($prefix -and $prefix.Length -gt $longest.Length -and $Title.StartsWith($prefix, [StringComparison]::Ordinal)) { $longest = $prefix }
    }
    if (-not $longest) { return $Title }
    $separators = [char[]]@(' ', '-', [char]0x2013, [char]0x2014, [char]0xFF0D, '|', [char]0xFF5C, [char]0x00B7, [char]0x3001, ',', [char]0xFF0C, '.', [char]0x3002, '!', [char]0xFF01, '?', [char]0xFF1F, ':', [char]0xFF1A, '+', '~', [char]0xFF5E, '*', '"', [char]0x201C, [char]0x201D, [char]0x2018, [char]0x2019)
    return $Title.Substring($longest.Length).TrimStart($separators)
}

function Get-TitleCreditAfterSeriesLabel {
    <#
    .SYNOPSIS
      The credit that follows the last series/format label in a title fragment.

      Uploads name the series before the singer ("爱情公寓3ost 陈韵若&陈每文",
      "东宫ost 余昭源&叶里"), so everything after the last `ost`/`ep`/`op`/`ed`
      label is the credit. Only a token that really is a label counts -- the token
      must carry CJK text or be the bare marker -- so a performer whose name
      merely ends in those letters is left alone. Returns '' when there is no
      label or nothing follows it.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $tokens = @([regex]::Split($Text.Trim(), '\s+') | Where-Object { $_ })
    if ($tokens.Count -lt 2) { return '' }
    $last = -1
    for ($i = 0; $i -lt ($tokens.Count - 1); $i++) {
        $token = [string]$tokens[$i]
        if (-not [regex]::IsMatch($token, '(?i)(ost|ep|op|ed)$')) { continue }
        if ([regex]::IsMatch($token, '[\u3400-\u9fff]') -or [regex]::IsMatch($token, '^(?i)(ost|ep|op|ed)$')) { $last = $i }
    }
    if ($last -lt 0) { return '' }
    return ([string](@($tokens[($last + 1)..($tokens.Count - 1)]) -join ' ')).Trim()
}

function Get-TitleDeclaredArtist {
    <#
    .SYNOPSIS
      Reads the artist the uploader declared in the file name.

      Local files downloaded from Bilibili are titled the way the uploader wrote
      them, and "<artist>《<song>》" is the dominant convention. That label is more
      trustworthy than a folder name and is used when the online lookup cannot
      confirm a match.

      A wrong name is worse than none: anything that still looks like a sentence,
      a lyric, channel branding or a series tag is refused so the caller can fall
      back to the library index.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Title,
        [AllowEmptyCollection()][string[]]$KnownPrefixes = @()
    )

    if ([string]::IsNullOrWhiteSpace($Title)) { return '' }
    $Title = Remove-SharedTitlePrefix -Title $Title -Prefixes $KnownPrefixes
    if ([string]::IsNullOrWhiteSpace($Title)) { return '' }
    $pairs = @(@('《', '》'), @('「', '」'), @('『', '』'))
    foreach ($pair in $pairs) {
        $open = [string]$pair[0]; $close = [string]$pair[1]
        $from = 0
        while ($true) {
            $start = $Title.IndexOf($open, $from)
            if ($start -lt 0) { break }
            $end = $Title.IndexOf($close, $start + 1)
            if ($end -lt 0) { break }
            $before = $Title.Substring(0, $start).Trim()
            # Drop a quoted lyric sitting in front of the artist.
            $before = [regex]::Replace($before, '^[\u201c"''][^\u201d"'']{0,80}[\u201d"'']\s*', '').Trim()
            # `爱情公寓3ost 陈韵若&陈每文《爱的回归线》`: the credit follows the series
            # label, and keeping the label glued to it made the "CJK with spaces"
            # rule refuse the whole run. That refusal is not neutral: the caller
            # then falls back to the indexed artist, which for a Bilibili download
            # is the uploader (this file displayed `JLRS-LeoFM`).
            $afterLabel = Get-TitleCreditAfterSeriesLabel -Text $before
            if ($afterLabel) { $before = $afterLabel }
            # A lyric, a sentence, or another bracketed block is not an artist.
            # This runs before the trailing cleanup, which would otherwise erase
            # the punctuation ("仙气空灵！") that proves it is not a name.
            $isSentence = [regex]::IsMatch($before, '[，。！？、丨｜\u201c\u201d\u2018\u2019]')
            $isBracketed = [regex]::IsMatch($before, '[《》「」『』【】]')
            if (-not $isSentence -and -not $isBracketed) {
                # "artist - song" in front of the bracket: keep the artist side.
                if ([regex]::IsMatch($before, '\s+-\s+')) {
                    $before = [string](@([regex]::Split($before, '\s+-\s+') | Where-Object { $_ })[0])
                } elseif ($before.Contains('-') -and [regex]::IsMatch($before, '[\u3400-\u9fff]')) {
                    # CJK titles often glue it as "artist-song-series" with no
                    # spaces, e.g. "小树-不安的前方-动漫"; the first part is the singer.
                    $before = [string](@($before.Split('-') | Where-Object { $_ })[0])
                }
                $before = [regex]::Replace($before, '[\s\-–—－|｜·、,，。!！?？:：+~～*"' + [char]0x201c + [char]0x201d + [char]0x2018 + [char]0x2019 + ']+$', '').Trim()
                # Accept only a single credit, never a phrase. Text mixing CJK with
                # spaces is a comment or channel branding; a long CJK run with no
                # separator is branding glued straight onto the name. A Latin credit
                # may contain spaces ("Alan Walker&Sabrina Carpenter&Farruko").
                $hasCjk = [regex]::IsMatch($before, '[\u3400-\u9fff\u3040-\u30ff]')
                $hasSpace = [regex]::IsMatch($before, '\s')
                $hasSeparator = [regex]::IsMatch($before, '[&,，、×]|\bfeat\.?\b|\bft\.?\b')
                $acceptable = $true
                if ($hasCjk -and $hasSpace) { $acceptable = $false }
                elseif ($hasCjk -and -not $hasSeparator -and $before.Length -gt 12) { $acceptable = $false }
                if ($acceptable -and $before.Length -gt 0 -and $before.Length -le 40) {
                    return $before
                }
            }
            $from = $end + 1
        }
    }

    # The other common upload shape is "Song - Artist" with no bracketed block at
    # all, which the online lookup cannot resolve: searching an artist name never
    # yields a song name that matches, so the file-name gate rejects every hit.
    # Both orders occur in the wild, so the tail is only trusted when neither side
    # carries marketing or series noise. Getting this wrong displays a song name
    # as an artist, which is worse than showing none.
    $head = ''
    $tail = ''
    if ([regex]::IsMatch($Title, '\s+-\s+')) {
        $parts = @([regex]::Split($Title, '\s+-\s+') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($parts.Count -ge 2) {
            $head = [string]$parts[0]
            $tail = [string]$parts[$parts.Count - 1]
        }
    }
    if ($tail) {
        $cleanHead = -not [regex]::IsMatch($head, '[《》「」『』【】，。！？]')
        $cleanTail = -not [regex]::IsMatch($tail, '[《》「」『』【】（）()，。！？、丨｜|]|Hi-?Res|无损|音质')
        if ($cleanHead -and $cleanTail -and $tail.Length -le 40) { return $tail }
    }
    return ''
}

function Resolve-DisplayArtist {
    <#
    .SYNOPSIS
      The artist (and release year) to display for one library item, given its
      cache row.

      A resolved online match is final and expensive, so it is always reused. A
      value derived from the title costs nothing to recompute and is therefore
      recomputed on every read: that lets improved parsing rules heal rows an
      older build already wrote, with no migration. When the rules now refuse a
      title, the caller's indexed value stays in place rather than being blanked.

      The year is only ever NetEase's album publish date. The file's own `year`
      tag is deliberately ignored: for Bilibili downloads it holds the upload or
      encode year, so a 1990s song uploaded in 2024 would be labelled 2024.
    #>
    param(
        [AllowEmptyString()][string]$Title = '',
        [AllowEmptyString()][string]$Indexed = '',
        [AllowNull()]$CachedRow = $null,
        [AllowEmptyCollection()][string[]]$KnownPrefixes = @()
    )

    if ($CachedRow) {
        $source = [string](Get-OptionalProperty $CachedRow 'source' '')
        $cached = [string](Get-OptionalProperty $CachedRow 'artist' '')
        if ($source -ne 'title' -and $cached) {
            return [pscustomobject]@{
                artist = $cached
                album = [string](Get-OptionalProperty $CachedRow 'album' '')
                year = [int](Get-OptionalProperty $CachedRow 'release_year' 0)
                source = $source
            }
        }
    }
    $declared = ''
    try { $declared = Get-TitleDeclaredArtist -Title $Title -KnownPrefixes $KnownPrefixes } catch { $declared = '' }
    if ($declared) {
        return [pscustomobject]@{ artist = $declared; album = ''; year = 0; source = 'title' }
    }
    if ($Indexed) {
        return [pscustomobject]@{ artist = $Indexed; album = ''; year = 0; source = '' }
    }
    return $null
}

function Get-TitleSearchKeywords {
    <#
    .SYNOPSIS
      Search keywords for a song title, most precise first.

      Uploader titles wrap the real song name in 《》/「」/『』 and pad it with
      channel branding, so the bracketed block is tried alongside the cleaned
      name. Every keyword is only a search hint: the caller still requires the
      returned artist to appear in the original file name.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Title)

    $keywords = New-Object System.Collections.ArrayList
    $add = {
        param([string]$Value)
        $value = [regex]::Replace([string]$Value, '\s+', ' ').Trim()
        if ($value.Length -ge 2 -and $value.Length -le 60 -and -not $keywords.Contains($value)) { [void]$keywords.Add($value) }
    }

    foreach ($pair in @(@('《', '》'), @('「', '」'), @('『', '』'))) {
        $open = [string]$pair[0]; $close = [string]$pair[1]
        $m = [regex]::Match($Title, [regex]::Escape($open) + '([^' + [regex]::Escape($open) + [regex]::Escape($close) + ']{2,40})' + [regex]::Escape($close))
        if ($m.Success) { & $add $m.Groups[1].Value }
    }

    $stripped = $Title
    foreach ($noise in @('【[^【】]{0,40}】', '\[[^\[\]]{0,40}\]', '（[^（）]{0,40}）', '\([^()]{0,40}\)')) {
        $stripped = [regex]::Replace($stripped, $noise, ' ')
    }
    # The parent folder of a flat library is the library itself, so only an
    # explicit "song - artist" split is useful here.
    foreach ($part in @($stripped -split '\s+[-\u2013\u2014]\s+|\s*[|｜]\s*')) {
        & $add ([regex]::Replace([string]$part, '[《》「」『』]', ' '))
    }
    & $add $stripped

    return @($keywords | Select-Object -First 3)
}

function Get-SongSearchQueries {
    <#
    .SYNOPSIS
      Ordered NetEase search queries for one library track.

      A seeded track stores whatever the uploader titled it, so searching the raw
      string wastes the lookup: the query has to be the song name, and the artist
      belongs beside it. Each cleaned song name is tried with the artist first
      ("空山新雨后 音阙诗听") and alone second, because an artist name can itself be
      misspelled in the uploader's title while the song name is exact. The plain
      artist-less form stays last so a track with no resolved artist still works.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Title,
        [AllowEmptyString()][string]$Artist = '',
        [int]$Max = 4
    )

    if ([string]::IsNullOrWhiteSpace($Title)) { return @() }
    if ($Max -le 0) { return @() }

    $queries = New-Object System.Collections.ArrayList
    $add = {
        param([string]$Value)
        $value = [regex]::Replace([string]$Value, '\s+', ' ').Trim()
        if ($value.Length -ge 2 -and $value.Length -le 80 -and -not $queries.Contains($value)) { [void]$queries.Add($value) }
    }

    # Only the first credited artist is a useful hint; a long featured-artist list
    # makes the query too specific to match.
    $leadArtist = ''
    if (-not [string]::IsNullOrWhiteSpace($Artist)) {
        $leadArtist = ([string](@($Artist -split '[,，、/&;；]|\s+feat\.?\s+|\s+ft\.?\s+' | Where-Object { $_.Trim() })[0])).Trim()
    }
    $keywords = @(Get-TitleSearchKeywords -Title $Title)
    $artistKey = ConvertTo-MusicServerKey -Value $leadArtist
    foreach ($keyword in $keywords) {
        $keywordKey = ConvertTo-MusicServerKey -Value $keyword
        # Skip a keyword that is only the artist again ("陈奕迅" + "陈奕迅"), and skip
        # re-appending an artist the keyword already names: that produces
        # "Roselia Always recall. Roselia", which is more specific than any real
        # NetEase title and therefore matches nothing.
        $namesArtist = $artistKey -and ($keywordKey -eq $artistKey -or $keywordKey.Contains($artistKey))
        if ($leadArtist -and -not $namesArtist) { & $add "$keyword $leadArtist" }
        & $add $keyword
    }
    return @($queries | Select-Object -First $Max)
}

function Test-FileVouchesForArtist {
    <#
    .SYNOPSIS
      Whether the file name itself confirms a candidate artist.

      This is the precision gate for online artist lookup. Searching NetEase by
      song name alone happily returns a different recording of the same song --
      "EXO-M - MAMA" for a file named "EXO-K《mama》", or "XG - RUDE!" for
      "Hearts2Hearts《RUDE!》" -- so a candidate is only accepted when the file
      name already contains every artist it credits.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Artist,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Title
    )

    if ([string]::IsNullOrWhiteSpace($Artist)) { return $false }
    $fileKey = ConvertTo-MusicServerKey -Value $Title
    $names = @($Artist -split '[,，、/&;；]|\s+feat\.?\s+|\s+ft\.?\s+' | ForEach-Object { $_.Trim() } | Where-Object { $_.Length -ge 2 })
    if ($names.Count -eq 0) { return $false }
    foreach ($name in $names) {
        if (-not $fileKey.Contains((ConvertTo-MusicServerKey -Value $name))) { return $false }
    }
    return $true
}

function ConvertTo-MusicServerKey {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    return ([regex]::Replace($Value.ToLowerInvariant(), '[\s\-_·、,，。.!！?？:：;；''"\u201c\u201d\u2018\u2019()（）\[\]【】《》「」『』|｜/\\~～+*&]', ''))
}

function Get-NeteasePublishYear {
    <#
    .SYNOPSIS
      The release year from a NetEase album.publishTime value, or 0 when unknown.

      publishTime is epoch milliseconds. Values outside a plausible range are
      rejected rather than clamped: a wrong year is worse than no year, and 0 lets
      the UI show nothing.
    #>
    param([AllowNull()]$PublishTime)

    $raw = 0L
    try { $raw = [long]$PublishTime } catch { return 0 }
    if ($raw -le 0) { return 0 }
    # Some fields arrive in seconds; normalize to milliseconds.
    if ($raw -lt 100000000000L) { $raw = $raw * 1000L }
    try {
        $year = ([DateTimeOffset]::FromUnixTimeMilliseconds($raw)).UtcDateTime.Year
    } catch { return 0 }
    if ($year -lt 1900 -or $year -gt ([DateTime]::UtcNow.Year + 1)) { return 0 }
    return [int]$year
}

function Select-NeteaseArtistForTitle {
    <#
    .SYNOPSIS
      Best NetEase artist for one search response.

      Duration is a tie-breaker only. Bilibili uploads prepend narration or pad
      the tail and sometimes carry a whole single as one file, so a duration gate
      rejects correct matches; the file-name gate is what keeps precision.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Title,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Keyword,
        [int]$DurationSeconds = 0,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Songs = @()
    )

    $want = ConvertTo-MusicServerKey -Value $Keyword
    if ($want.Length -lt 2) { return $null }
    $best = $null; $bestDelta = [int]::MaxValue
    foreach ($song in @($Songs)) {
        if (-not $song) { continue }
        $got = ConvertTo-MusicServerKey -Value ([string](Get-OptionalProperty $song 'name' ''))
        if ($got.Length -lt 2) { continue }
        if (-not ($got -eq $want -or $got.Contains($want) -or $want.Contains($got))) { continue }
        $artist = (@(@(Get-OptionalProperty $song 'artists' @()) | ForEach-Object { [string](Get-OptionalProperty $_ 'name' '') } | Where-Object { $_ }) -join ',')
        if (-not (Test-FileVouchesForArtist -Artist $artist -Title $Title)) { continue }
        $seconds = [int][Math]::Round(([double](Get-OptionalProperty $song 'duration' 0)) / 1000)
        $delta = if ($DurationSeconds -gt 0 -and $seconds -gt 0) { [Math]::Abs($seconds - $DurationSeconds) } else { 0 }
        if (-not $best -or $delta -lt $bestDelta) {
            $best = [pscustomobject]@{
                artist = $artist
                album = [string](Get-OptionalProperty (Get-OptionalProperty $song 'album' $null) 'name' '')
                song = [string](Get-OptionalProperty $song 'name' '')
                # album.publishTime is epoch milliseconds. This is the real release
                # year, unlike the file's own `year` tag, which for Bilibili
                # downloads holds the upload/encode year.
                publish_year = Get-NeteasePublishYear -PublishTime (Get-OptionalProperty (Get-OptionalProperty $song 'album' $null) 'publishTime' 0)
            }
            $bestDelta = $delta
        }
    }
    return $best
}

function Resolve-NeteaseTrackArtist {
    <#
    .SYNOPSIS
      Resolves the singer for one local file, bounded and circuit-aware.

      Uses at most three NetEase searches, each charged against the existing
      `netease` provider circuit, and stops as soon as the circuit refuses. Set
      MUSICSERVER_DISABLE_NETEASE_SEARCH=1 to disable (hermetic tests).
    #>
    param(
        [Parameter(Mandatory)][psobject]$Config,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Title,
        [int]$DurationSeconds = 0
    )

    if ($env:MUSICSERVER_DISABLE_NETEASE_SEARCH -eq '1') { return $null }
    if ([string]::IsNullOrWhiteSpace($Title)) { return $null }

    $headers = @{
        'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0 Safari/537.36'
        'Referer'    = 'https://music.163.com/'
    }
    foreach ($keyword in @(Get-TitleSearchKeywords -Title $Title)) {
        if (-not (Test-ProviderRequestAvailable -Config $Config -Provider 'netease')) { return $null }
        if (-not (Claim-ProviderRequest -Config $Config -Provider 'netease')) { return $null }
        $started = [Diagnostics.Stopwatch]::StartNew()
        try {
            $url = "https://music.163.com/api/search/get?s=$([uri]::EscapeDataString($keyword))&type=1&limit=10"
            $response = Invoke-RestMethod -Uri $url -Headers $headers -TimeoutSec 20
        } catch {
            Record-ProviderFailure -Config $Config -Provider 'netease' -ErrorType 'SEARCH_FAILED' -Message $_.Exception.Message | Out-Null
            return $null
        }
        $started.Stop()
        $songs = @()
        try { if ($response.result.songs) { $songs = @($response.result.songs) } } catch { $songs = @() }
        $match = Select-NeteaseArtistForTitle -Title $Title -Keyword $keyword -DurationSeconds $DurationSeconds -Songs $songs
        Record-ProviderSuccess -Config $Config -Provider 'netease' -LatencyMs $started.Elapsed.TotalMilliseconds
        if ($match) { return $match }
    }
    return $null
}

function Get-NeteaseSimilarSongs {
    <#
    .SYNOPSIS
      Songs NetEase considers similar to one NetEase id, for dislike relations.

      Bounded like every other NetEase call: at most ONE request, charged against
      the `netease` circuit, and refused outright when the circuit is blocked. Set
      MUSICSERVER_DISABLE_NETEASE_SEARCH=1 to disable it (hermetic tests).

      Returns whatever the endpoint provides (id, name, artists); the caller maps
      it into relation keys so this stays a transport helper.
    #>
    param(
        [Parameter(Mandatory)][psobject]$Config,
        [AllowEmptyString()][string]$NeteaseId = '',
        [int]$Limit = 10
    )

    if ($env:MUSICSERVER_DISABLE_NETEASE_SEARCH -eq '1') { return @() }
    if (-not $NeteaseId) { return @() }
    if (-not (Test-ProviderRequestAvailable -Config $Config -Provider 'netease')) { return @() }
    if (-not (Claim-ProviderRequest -Config $Config -Provider 'netease')) { return @() }

    $headers = @{
        'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0 Safari/537.36'
        'Referer'    = 'https://music.163.com/'
    }
    $started = [Diagnostics.Stopwatch]::StartNew()
    try {
        $url = "https://music.163.com/api/v1/discovery/simiSong?songid=$([uri]::EscapeDataString($NeteaseId))&limit=$Limit"
        $response = Invoke-RestMethod -Uri $url -Headers $headers -TimeoutSec 20
    } catch {
        Record-ProviderFailure -Config $Config -Provider 'netease' -ErrorType 'SIMI_FAILED' -Message $_.Exception.Message | Out-Null
        return @()
    }
    $started.Stop()
    Record-ProviderSuccess -Config $Config -Provider 'netease' -LatencyMs $started.Elapsed.TotalMilliseconds
    $songs = @()
    try { if ($response.songs) { $songs = @($response.songs) } } catch { $songs = @() }
    return @($songs)
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