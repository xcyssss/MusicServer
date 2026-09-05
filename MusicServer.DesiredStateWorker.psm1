#Requires -Version 5.1
<#
.SYNOPSIS
  MusicServer.DesiredStateWorker — desired-state worker pipeline for Bilibili downloads.

.DESCRIPTION
  Claims WANTED_QUEUE items under a lease, resolves ranked download candidates,
  invokes the Bilibili download, validates the local duration, and atomically
  updates BOTH canonical_tracks and wanted_queue using CAS (compare-and-swap on
  `revision`) so that a crash or a concurrent writer cannot corrupt state.

  Public surface:
    Invoke-WantedDownloadPass -Config -TrackIds -WorkerId [-LeaseMinutes 30]
    Get-BackoffSeconds -Attempt <0..N>          # bounded exponential (30s, 60s, 120s, ... 600s cap)
    Resolve-WantedRetry -Attempt -MaxAttempts [-BlockedUntil]

  The State module exposes bare SQL functions (no -Config); the Database module
  holds the DB path after Initialize-MusicServerDatabase is called. The
  Providers/Core modules take -Config for tool paths and directory layout.

  All leaf operations (download, validate, Navidrome song-id lookup, DB CAS)
  are called by unqualified name so Pester `Mock -ModuleName` can intercept
  them from unit tests without touching the real DB or the network.
#>

Import-Module (Join-Path $PSScriptRoot 'MusicServer.Core.psm1') -Force -PassThru | Out-Null
Import-Module (Join-Path $PSScriptRoot 'MusicServer.State.psm1') -Force -PassThru | Out-Null
Import-Module (Join-Path $PSScriptRoot 'MusicServer.Providers.psm1') -Force -PassThru | Out-Null


function Get-BackoffSeconds {
    <#
    .SYNOPSIS
      Bounded exponential backoff: 30s * 2^Attempt, capped at 600s.
    .PARAMETER Attempt
      Zero-indexed failure number (first failure = 0 → 30s).
    #>
    param([int]$Attempt)
    if ($Attempt -lt 0) { $Attempt = 0 }
    $base = 30; $cap = 600
    return [long]([Math]::Min($cap, $base * [Math]::Pow(2, $Attempt)))
}


function Resolve-WantedRetry {
    <#
    .SYNOPSIS
      Computes the next WANT_QUEUE state (RETRY_WAIT vs UNAVAILABLE) and the
      next_retry_at ISO timestamp.
    .PARAMETER Attempt
      Current attempt_count (already-counted failures).
    .PARAMETER MaxAttempts
      Item's max_attempts (<= 0 treated as unset → default 3).
    .PARAMETER BlockedUntil
      Optional UTC ISO-8601 from the provider's blocked_until (for provider-block
      412 waits). Overrides the computed backoff.
    .OUTPUTS
      @{ NextState = 'RETRY_WAIT'|'UNAVAILABLE'; NextRetryAt = <ISO8601|''> }
    #>
    param(
        [int]$Attempt,
        [int]$MaxAttempts,
        [string]$BlockedUntil = ''
    )
    if ($MaxAttempts -le 0) { $MaxAttempts = 3 }
    if (($Attempt + 1) -ge $MaxAttempts) {
        return @{ NextState = 'UNAVAILABLE'; NextRetryAt = '' }
    }
    if ($BlockedUntil) {
        return @{ NextState = 'RETRY_WAIT'; NextRetryAt = [string]$BlockedUntil }
    }
    $sec = Get-BackoffSeconds -Attempt $Attempt
    $next = ([DateTimeOffset]::UtcNow.AddSeconds($sec)).UtcDateTime.ToString('o')
    return @{ NextState = 'RETRY_WAIT'; NextRetryAt = $next }
}


function Test-TrackAlreadyBound {
    <#
    .SYNOPSIS
      True if the canonical track is already bound to a Navidrome song.
    #>
    param([psobject]$Track)
    if ($null -ceq $Track) { return $false }
    return ([string]$Track.status -eq 'LOCAL') -and (-not [string]::IsNullOrWhiteSpace([string]$Track.local_song_id))
}


function Invoke-WantedDownloadPass {
    <#
    .SYNOPSIS
      Runs one worker pass over the given WANT_QUEUE items.
    .DESCRIPTION
      For each eligible item:
        1. Re-read the row; if CANCEL_REQUESTED, complete the cancellation (DELETE row).
        2. If already bound (track.status LOCAL with local_song_id), close the want as LOCAL.
        3. Claim under a lease (only WANTED / RETRY_WAIT items become RESOLVING).
        4. Resolve ranked candidates (Resolve-DownloadCandidates).
        5. Local candidate path: bind the Navidrome song id directly.
        6. Bilibili path: Renew-Lease → invoke download → validate → bind.
        7. Failure paths: UNAVAILABLE when max_attempts exhausted, else RETRY_WAIT
           with next_retry_at = max(backoff, provider blocked_until).
        8. All terminal CAS transitions are guarded by the revision captured right
           after the claim; a CAS conflict is reported and becomes a RETRY_WAIT.
    #>
    param(
        [Parameter(Mandatory)][psobject]$Config,
        [Parameter(Mandatory)][object]$TrackIds,
        [Parameter(Mandatory)][string]$WorkerId,
        [int]$LeaseMinutes = 30
    )

    $results = [System.Collections.Generic.List[object]]::new()
    if ($null -ceq $TrackIds) { return @($results) }
    $wantedSet = @{}
    foreach ($id in $TrackIds) { $wantedSet[[string]$id] = $true }

    $eligible = @(Get-WantedTracksDb -EligibleOnly)
    foreach ($item in $eligible) {
        $tid = [string]$item.track_id
        if (-not $wantedSet.ContainsKey($tid)) { continue }

        # --- Pre-claim: check state without claiming (cancel + already-bound fast paths) ---
        $cur = Get-WantedItemDb -TrackId $tid
        if ($null -ceq $cur) {
            $results.Add([pscustomobject]@{ TrackId = $tid; Status = 'SKIPPED'; Reason = 'NOT_FOUND' })
            continue
        }
        $state = [string]$cur.state

        # 1. CANCEL_REQUESTED → complete the cancellation (row deleted) and move on.
        if ($state -eq 'CANCEL_REQUESTED') {
            Complete-WantedCancellationDb -TrackId $tid | Out-Null
            $results.Add([pscustomobject]@{ TrackId = $tid; Status = 'CANCELLED'; Reason = 'CANCEL_REQUESTED' })
            continue
        }

        # --- Load the canonical track, used by most branches below ---
        $track = Get-CanonicalTrackDb -TrackId $tid
        if ($null -ceq $track) {
            $results.Add([pscustomobject]@{ TrackId = $tid; Status = 'SKIPPED'; Reason = 'TRACK_NOT_FOUND' })
            continue
        }
        $trackRev = [int]$track.revision

        # 2. Already bound? Close the want as LOCAL without another download.
        if (Test-TrackAlreadyBound -Track $track) {
            $upd = Update-WantedStateCasDb -TrackId $tid -WorkerId $WorkerId `
                -ExpectedRevision [int]$cur.revision -NewState 'LOCAL'
            $results.Add([pscustomobject]@{ TrackId = $tid; Status = 'ALREADY_LOCAL'; Reason = 'OK' })
            continue
        }

        # --- Claim (only WANTED / RETRY_WAIT items can become RESOLVING) ---
        $claim = Claim-WantedItemDb -TrackId $tid -WorkerId $WorkerId -LeaseMinutes $LeaseMinutes
        if (-not $claim.Success) {
            $results.Add([pscustomobject]@{ TrackId = $tid; Status = 'SKIPPED'; Reason = [string]$claim.Reason })
            continue
        }

        # Re-read the post-claim revision for the CAS below.
        $cur = Get-WantedItemDb -TrackId $tid
        if ($null -ceq $cur) {
            $results.Add([pscustomobject]@{ TrackId = $tid; Status = 'SKIPPED'; Reason = 'NOT_FOUND' })
            continue
        }
        $rev = [int]$cur.revision
        $attempt = [int]$cur.attempt_count
        $maxAttempts = [int]$cur.max_attempts

        try {
            # 4. Resolve candidates.
            $cands = @(Resolve-DownloadCandidates -Config $Config -Track $track)
            if ($cands.Count -eq 0) {
                $retry = Resolve-WantedRetry -Attempt $attempt -MaxAttempts $maxAttempts
                Update-WantedStateCasDb -TrackId $tid -WorkerId $WorkerId `
                    -ExpectedRevision $rev -NewState $retry.NextState `
                    -AttemptCount ($attempt + 1) -LastError 'No candidates' `
                    -NextRetryAt ([string]$retry.NextRetryAt) | Out-Null
                $results.Add([pscustomobject]@{ TrackId = $tid; Status = $retry.NextState; Reason = 'NO_CANDIDATES' })
                continue
            }
            $candidate = $cands[0].Candidate

            # 5. Local fast path.
            if ([string]$candidate.provider -eq 'local') {
                $songId = [string](Get-NavidromeSongIdForPath -Config $Config -Path ([string]$candidate.url))
                $upd = Add-TrackLocalBinding -Track $track -SongId $songId -TrackRevisionsExpected $trackRev
                if (-not $upd.Success) {
                    $retry = Resolve-WantedRetry -Attempt $attempt -MaxAttempts $maxAttempts
                    Update-WantedStateCasDb -TrackId $tid -WorkerId $WorkerId `
                        -ExpectedRevision $rev -NewState $retry.NextState `
                        -AttemptCount ($attempt + 1) -LastError 'TRACK_CAS_CONFLICT' `
                        -NextRetryAt ([string]$retry.NextRetryAt) | Out-Null
                    $results.Add([pscustomobject]@{ TrackId = $tid; Status = $retry.NextState; Reason = 'TRACK_CAS_CONFLICT' })
                    continue
                }
                Update-WantedStateCasDb -TrackId $tid -WorkerId $WorkerId `
                    -ExpectedRevision $rev -NewState 'LOCAL' -AttemptCount ($attempt + 1) | Out-Null
                $results.Add([pscustomobject]@{ TrackId = $tid; Status = 'LOCAL_BOUND'; SongId = $songId; Reason = 'LOCAL' })
                continue
            }

            # 6. Bilibili path.
            # Renew-lease before the long op so the lease covers the download.
            Renew-LeaseDb -TrackId $tid -WorkerId $WorkerId -LeaseMinutes $LeaseMinutes | Out-Null

            # Cancel check after the long wait (cancel may have landed already).
            $cur2 = Get-WantedItemDb -TrackId $tid
            if (([string]$cur2.state) -eq 'CANCEL_REQUESTED') {
                Complete-WantedCancellationDb -TrackId $tid | Out-Null
                $results.Add([pscustomobject]@{ TrackId = $tid; Status = 'CANCELLED'; Reason = 'CANCEL_REQUESTED' })
                continue
            }

            $dl = Invoke-BilibiliDownload -Config $Config -Track $track -Candidate $candidate

            # Cancel can land even DURING the download; re-check.
            $cur3 = Get-WantedItemDb -TrackId $tid
            if ($null -ceq $cur3) {
                # The wanted row was deleted under us (rare) — bail out of this item.
                $results.Add([pscustomobject]@{ TrackId = $tid; Status = 'SKIPPED'; Reason = 'WANT_DELETED' })
                continue
            }
            if ([string]$cur3.state -eq 'CANCEL_REQUESTED') {
                Complete-WantedCancellationDb -TrackId $tid -TemporaryPath ([string]$dl.Path) | Out-Null
                $results.Add([pscustomobject]@{ TrackId = $tid; Status = 'CANCELLED'; Reason = 'CANCEL_REQUESTED' })
                continue
            }

            # Download failed → compute next state (backoff or blocked_until).
            if (-not $dl.Success) {
                $blockedUntil = ''
                if ([bool]$dl.Blocked -and ($null -ne $dl.blocked_until) -and -not [string]::IsNullOrWhiteSpace([string]$dl.blocked_until)) {
                    $blockedUntil = [string]$dl.blocked_until
                }
                if (-not $blockedUntil) {
                    try {
                        $health = Get-ProviderHealthDb -Provider 'bilibili_download'
                        $blockedUntil = [string]$health.blocked_until
                    } catch { $blockedUntil = '' }
                }
                $retry = Resolve-WantedRetry -Attempt $attempt -MaxAttempts $maxAttempts -BlockedUntil $blockedUntil
                Update-WantedStateCasDb -TrackId $tid -WorkerId $WorkerId `
                    -ExpectedRevision $rev -NewState $retry.NextState `
                    -AttemptCount ($attempt + 1) -LastError ([string]$dl.Error) `
                    -NextRetryAt ([string]$retry.NextRetryAt) | Out-Null
                $results.Add([pscustomobject]@{
                    TrackId = $tid; Status = $retry.NextState
                    Reason = [string]$dl.Error; Blocked = [bool]$dl.Blocked
                })
                continue
            }

            # Validate the downloaded file (duration vs NetEase).
            $val = Validate-DownloadedCandidate -Config $Config -Track $track -Path ([string]$dl.Path)
            if (-not $val.Valid) {
                $retry = Resolve-WantedRetry -Attempt $attempt -MaxAttempts $maxAttempts
                Update-WantedStateCasDb -TrackId $tid -WorkerId $WorkerId `
                    -ExpectedRevision $rev -NewState $retry.NextState `
                    -AttemptCount ($attempt + 1) -LastError ([string]$val.Reason) `
                    -NextRetryAt ([string]$retry.NextRetryAt) | Out-Null
                $results.Add([pscustomobject]@{
                    TrackId = $tid; Status = $retry.NextState
                    Reason = [string]$val.Reason; Detail = 'VALIDATE_FAILED'
                })
                continue
            }

            # Bind the Navidrome song id.
            $songId = [string](Get-NavidromeSongIdForPath -Config $Config -Path ([string]$dl.Path))
            $upd = Add-TrackLocalBinding -Track $track -SongId $songId -TrackRevisionsExpected $trackRev
            if (-not $upd.Success) {
                # Track row moved under us (concurrent writer). The downloaded file is
                # still staged in DailyMix/; a later retry can re-look-up the song id.
                $retry = Resolve-WantedRetry -Attempt $attempt -MaxAttempts $maxAttempts
                Update-WantedStateCasDb -TrackId $tid -WorkerId $WorkerId `
                    -ExpectedRevision $rev -NewState $retry.NextState `
                    -AttemptCount ($attempt + 1) -LastError 'TRACK_CAS_CONFLICT' `
                    -NextRetryAt ([string]$retry.NextRetryAt) | Out-Null
                $results.Add([pscustomobject]@{ TrackId = $tid; Status = $retry.NextState; Reason = 'TRACK_CAS_CONFLICT' })
                continue
            }
            # Finalize: LOCAL.
            Update-WantedStateCasDb -TrackId $tid -WorkerId $WorkerId `
                -ExpectedRevision $rev -NewState 'LOCAL' -AttemptCount ($attempt + 1) | Out-Null
            $results.Add([pscustomobject]@{ TrackId = $tid; Status = 'LOCAL_BOUND'; SongId = $songId; Reason = 'OK' })
        }
        catch {
            $errMsg = if ($_.Exception) { $_.Exception.Message } else { [string]$_ }
            $retry = Resolve-WantedRetry -Attempt $attempt -MaxAttempts $maxAttempts
            try {
                Update-WantedStateCasDb -TrackId $tid -WorkerId $WorkerId `
                    -ExpectedRevision $rev -NewState $retry.NextState `
                    -AttemptCount ($attempt + 1) -LastError ("EXCEPTION: " + $errMsg) `
                    -NextRetryAt ([string]$retry.NextRetryAt) | Out-Null
            } catch { }
            $results.Add([pscustomobject]@{ TrackId = $tid; Status = $retry.NextState; Reason = 'EXCEPTION'; Detail = $errMsg })
        }
    }
    return @($results)
}


function Add-TrackLocalBinding {
    <#
    .SYNOPSIS
      Writes the canonical_tracks row to status=LOCAL, local_song_id=<id>,
      guarded by CAS on the expected revision.
    .OUTPUTS
      @{ Success=$bool; Reason=$string }
    #>
    param(
        [psobject]$Track,
        [string]$SongId,
        [int]$TrackRevisionsExpected
    )
    $updated = $Track | Add-Member -MemberType NoteProperty -Name 'status' -Value 'LOCAL' -Force -PassThru
    $updated = $updated | Add-Member -MemberType NoteProperty -Name 'local_song_id' -Value [string]$SongId -Force -PassThru
    $result = Save-CanonicalTrackDb -Track $updated -CAS -ExpectedRevision $TrackRevisionsExpected
    if ($null -ceq $result) {
        return @{ Success = $true; Reason = 'OK' }
    }
    if ($result.PSObject.Properties['Success']) {
        return @{ Success = [bool]$result.Success; Reason = [string]$result.Reason }
    }
    return @{ Success = $false; Reason = 'UNKNOWN' }
}


Export-ModuleMember -Function Invoke-WantedDownloadPass, Get-BackoffSeconds, Resolve-WantedRetry, Test-TrackAlreadyBound, Add-TrackLocalBinding
