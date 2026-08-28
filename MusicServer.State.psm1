Set-StrictMode -Version 3.0

# MusicServer.State.psm1 - Transactional state layer backed by SQLite
# Provides: schema, migration, CAS, worker claim/lease, crash recovery,
#           transactional like/unlike/download-completion, provider health.

Import-Module (Join-Path $PSScriptRoot 'MusicServer.Database.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'MusicServer.Core.psm1') -Force

$script:SchemaVersion = 1
$script:LeaseMinutes = 30

# ================================================================
# Schema
# ================================================================

function Initialize-MusicServerSchema {
    Invoke-MusicServerSqlNonQuery -Query @"
CREATE TABLE IF NOT EXISTS canonical_tracks (
    id TEXT PRIMARY KEY,
    title TEXT NOT NULL DEFAULT '',
    artist TEXT NOT NULL DEFAULT '',
    album TEXT NOT NULL DEFAULT '',
    duration INTEGER NOT NULL DEFAULT 0,
    cover_url TEXT DEFAULT '',
    identifiers_json TEXT DEFAULT '[]',
    preview_sources_json TEXT DEFAULT '[]',
    download_candidates_json TEXT DEFAULT '[]',
    local_song_id TEXT DEFAULT '',
    status TEXT NOT NULL DEFAULT 'REMOTE',
    created_at TEXT NOT NULL DEFAULT '',
    updated_at TEXT DEFAULT '',
    revision INTEGER NOT NULL DEFAULT 0
);
"@
    Invoke-MusicServerSqlNonQuery -Query @"
CREATE TABLE IF NOT EXISTS daily_recommendations (
    date TEXT NOT NULL,
    rank INTEGER NOT NULL,
    rec_id TEXT NOT NULL DEFAULT '',
    track_id TEXT NOT NULL,
    netease_id TEXT NOT NULL DEFAULT '',
    title TEXT NOT NULL DEFAULT '',
    artist TEXT NOT NULL DEFAULT '',
    album TEXT NOT NULL DEFAULT '',
    duration INTEGER NOT NULL DEFAULT 0,
    reason TEXT NOT NULL DEFAULT '',
    seed_source TEXT NOT NULL DEFAULT '',
    playback_source TEXT NOT NULL DEFAULT '',
    preview_sources_json TEXT NOT NULL DEFAULT '[]',
    liked INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL DEFAULT '',
    PRIMARY KEY(date, rank)
);
"@
    Invoke-MusicServerSqlNonQuery -Query @"
CREATE TABLE IF NOT EXISTS recommendation_feedback (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    track_id TEXT NOT NULL,
    feedback_type TEXT NOT NULL,
    source TEXT NOT NULL DEFAULT '',
    value TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL
);
"@
    Invoke-MusicServerSqlNonQuery -Query @"
CREATE TABLE IF NOT EXISTS wanted_queue (
    track_id TEXT PRIMARY KEY,
    wanted_id TEXT NOT NULL DEFAULT '',
    state TEXT NOT NULL DEFAULT 'WANTED',
    attempt_count INTEGER NOT NULL DEFAULT 0,
    max_attempts INTEGER NOT NULL DEFAULT 5,
    next_retry_at TEXT,
    selected_candidate_json TEXT,
    last_error TEXT NOT NULL DEFAULT '',
    claimed_by TEXT NOT NULL DEFAULT '',
    claimed_at TEXT,
    lease_expires_at TEXT,
    revision INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL DEFAULT ''
);
"@
    Invoke-MusicServerSqlNonQuery -Query @"
CREATE TABLE IF NOT EXISTS provider_health (
    provider TEXT PRIMARY KEY,
    state TEXT NOT NULL DEFAULT 'CLOSED',
    success_count INTEGER NOT NULL DEFAULT 0,
    failure_count INTEGER NOT NULL DEFAULT 0,
    consecutive_failures INTEGER NOT NULL DEFAULT 0,
    consecutive_412 INTEGER NOT NULL DEFAULT 0,
    last_success TEXT,
    last_failure TEXT,
    last_412_at TEXT,
    blocked_until TEXT,
    average_latency_ms REAL NOT NULL DEFAULT 0,
    half_open_probe_claimed INTEGER NOT NULL DEFAULT 0,
    last_error TEXT NOT NULL DEFAULT '',
    revision INTEGER NOT NULL DEFAULT 0,
    updated_at TEXT NOT NULL DEFAULT ''
);
"@
    Invoke-MusicServerSqlNonQuery -Query @"
CREATE TABLE IF NOT EXISTS events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    event_type TEXT NOT NULL,
    track_id TEXT NOT NULL DEFAULT '',
    provider TEXT NOT NULL DEFAULT '',
    from_state TEXT NOT NULL DEFAULT '',
    to_state TEXT NOT NULL DEFAULT '',
    attempt INTEGER NOT NULL DEFAULT 0,
    duration_ms REAL NOT NULL DEFAULT 0,
    result TEXT NOT NULL DEFAULT '',
    error_type TEXT NOT NULL DEFAULT '',
    http_status INTEGER NOT NULL DEFAULT 0,
    message TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL
);
"@
    Invoke-MusicServerSqlNonQuery -Query @"
CREATE INDEX IF NOT EXISTS idx_wanted_state ON wanted_queue(state);
CREATE INDEX IF NOT EXISTS idx_wanted_lease ON wanted_queue(lease_expires_at);
CREATE INDEX IF NOT EXISTS idx_events_track ON events(track_id);
CREATE INDEX IF NOT EXISTS idx_events_type ON events(event_type);
CREATE INDEX IF NOT EXISTS idx_events_created ON events(created_at);
CREATE INDEX IF NOT EXISTS idx_daily_date ON daily_recommendations(date);
CREATE INDEX IF NOT EXISTS idx_feedback_track ON recommendation_feedback(track_id);
"@
}

# ================================================================
# Canonical Tracks
# ================================================================

function Get-CanonicalTrackDb {
    param([Parameter(Mandatory)][string]$TrackId)
    $rows = @(Invoke-MusicServerParamSql -Template 'SELECT * FROM canonical_tracks WHERE id = @track_id LIMIT 1;' -Params @{ track_id = $TrackId })
    if ($rows.Count -eq 0) { return $null }
    return Convert-DbTrackRow -Row $rows[0]
}

function Save-CanonicalTrackDb {
    param(
        [Parameter(Mandatory)][psobject]$Track,
        [switch]$CAS,
        [int]$ExpectedRevision = -1
    )
    $now = Get-NowIso
    $identifiers = ConvertTo-Json -InputObject @(Get-OptionalProperty $Track 'identifiers' @()) -Compress -Depth 10
    $preview = ConvertTo-Json -InputObject @(Get-OptionalProperty $Track 'preview_sources' @()) -Compress -Depth 10
    $candidates = ConvertTo-Json -InputObject @(Get-OptionalProperty $Track 'download_candidates' @()) -Compress -Depth 10
    $existing = @(Invoke-MusicServerParamSql -Template 'SELECT revision FROM canonical_tracks WHERE id = @id LIMIT 1;' -Params @{ id = [string]$Track.id })
    if ($existing.Count -gt 0) {
        $currentRevision = [int]$existing[0].revision
        if ($CAS -and $currentRevision -ne $ExpectedRevision) {
            return @{ Success = $false; Reason = 'CAS_MISMATCH'; CurrentRevision = $currentRevision }
        }
        $newRevision = $currentRevision + 1
        $created = [string](Get-OptionalProperty $Track 'created_at')
        if (-not $created) {
            $oldRows = @(Invoke-MusicServerParamSql -Template 'SELECT created_at FROM canonical_tracks WHERE id = @id LIMIT 1;' -Params @{ id = [string]$Track.id })
            if ($oldRows.Count -gt 0) { $created = [string]$oldRows[0].created_at }
        }
        if (-not $created) { $created = $now }
        Invoke-MusicServerParamNonQuery -Template @"
UPDATE canonical_tracks SET
    title = @title, artist = @artist, album = @album, duration = @duration,
    cover_url = @cover_url, identifiers_json = @identifiers, preview_sources_json = @preview,
    download_candidates_json = @candidates, local_song_id = @local_song_id,
    status = @status, updated_at = @updated_at, revision = @revision
WHERE id = @id;
"@ -Params @{
            id = [string]$Track.id; title = [string]$Track.title; artist = [string](Get-OptionalProperty $Track 'artist')
            album = [string](Get-OptionalProperty $Track 'album'); duration = [int](Get-OptionalProperty $Track 'duration')
            cover_url = [string](Get-OptionalProperty $Track 'cover_url'); identifiers = $identifiers
            preview = $preview; candidates = $candidates; local_song_id = [string](Get-OptionalProperty $Track 'local_song_id')
            status = [string](Get-OptionalProperty $Track 'status' 'REMOTE'); updated_at = $now; revision = $newRevision
        }
        return @{ Success = $true; Revision = $newRevision }
    } else {
        $created = [string](Get-OptionalProperty $Track 'created_at' $now)
        Invoke-MusicServerParamNonQuery -Template @"
INSERT INTO canonical_tracks (id, title, artist, album, duration, cover_url,
    identifiers_json, preview_sources_json, download_candidates_json,
    local_song_id, status, created_at, updated_at, revision)
VALUES (@id, @title, @artist, @album, @duration, @cover_url,
    @identifiers, @preview, @candidates,
    @local_song_id, @status, @created_at, @updated_at, 1);
"@ -Params @{
            id = [string]$Track.id; title = [string]$Track.title; artist = [string](Get-OptionalProperty $Track 'artist')
            album = [string](Get-OptionalProperty $Track 'album'); duration = [int](Get-OptionalProperty $Track 'duration')
            cover_url = [string](Get-OptionalProperty $Track 'cover_url'); identifiers = $identifiers
            preview = $preview; candidates = $candidates; local_song_id = [string](Get-OptionalProperty $Track 'local_song_id')
            status = [string](Get-OptionalProperty $Track 'status' 'REMOTE'); created_at = $created; updated_at = $now
        }
        return @{ Success = $true; Revision = 1 }
    }
}

function Convert-DbTrackRow {
    param([Parameter(Mandatory)][psobject]$Row)
    $identifiers = @()
    $preview = @()
    $candidates = @()
    try { if ($Row.identifiers_json) { $identifiers = @(ConvertFrom-Json -InputObject ([string]$Row.identifiers_json)) } } catch {}
    try { if ($Row.preview_sources_json) { $preview = @(ConvertFrom-Json -InputObject ([string]$Row.preview_sources_json)) } } catch {}
    try { if ($Row.download_candidates_json) { $candidates = @(ConvertFrom-Json -InputObject ([string]$Row.download_candidates_json)) } } catch {}
    return [pscustomobject]@{
        id = [string]$Row.id; title = [string]$Row.title; artist = [string]$Row.artist
        album = [string]$Row.album; duration = [int]$Row.duration; cover_url = [string]$Row.cover_url
        identifiers = $identifiers; preview_sources = $preview; download_candidates = $candidates
        local_song_id = [string]$Row.local_song_id; status = [string]$Row.status
        created_at = [string]$Row.created_at; updated_at = [string]$Row.updated_at
        revision = [int]$Row.revision
    }
}

# ================================================================
# Daily Recommendations
# ================================================================

function Save-DailyRecommendationsDb {
    param(
        [Parameter(Mandatory)][object[]]$Recommendations,
        [string]$Date = (Get-TodayDate),
        [switch]$DryRun
    )
    if ($DryRun) { return }
    foreach ($rec in $Recommendations) {
        $preview = ConvertTo-Json -InputObject @(Get-OptionalProperty $rec 'preview_sources' @()) -Compress -Depth 10
        $liked = if (Get-OptionalProperty $rec 'liked' $false) { 1 } else { 0 }
        $recId = [string](Get-OptionalProperty $rec 'id')
        $trackId = [string](Get-OptionalProperty $rec 'track_id')
        $existing = @(Invoke-MusicServerParamSql -Template 'SELECT rec_id FROM daily_recommendations WHERE date = @d AND rank = @r LIMIT 1;' -Params @{ d = $Date; r = [int](Get-OptionalProperty $rec 'rank') })
        if ($existing.Count -gt 0) {
            Invoke-MusicServerParamNonQuery -Template @"
UPDATE daily_recommendations SET rec_id = @rec_id, track_id = @track_id, netease_id = @nid,
    title = @title, artist = @artist, album = @album, duration = @dur,
    reason = @reason, seed_source = @ss, playback_source = @ps,
    preview_sources_json = @preview, liked = @liked, updated_at = @now
WHERE date = @d AND rank = @r;
"@ -Params @{
                d = $Date; r = [int](Get-OptionalProperty $rec 'rank'); rec_id = $recId; track_id = $trackId
                nid = [string](Get-OptionalProperty $rec 'netease_id'); title = [string](Get-OptionalProperty $rec 'title')
                artist = [string](Get-OptionalProperty $rec 'artist'); album = [string](Get-OptionalProperty $rec 'album')
                dur = [int](Get-OptionalProperty $rec 'duration'); reason = [string](Get-OptionalProperty $rec 'reason')
                ss = [string](Get-OptionalProperty $rec 'seed_source'); ps = [string](Get-OptionalProperty $rec 'playback_source')
                preview = $preview; liked = $liked; now = (Get-NowIso)
            }
        } else {
            Invoke-MusicServerParamNonQuery -Template @"
INSERT INTO daily_recommendations (date, rank, rec_id, track_id, netease_id, title, artist,
    album, duration, reason, seed_source, playback_source, preview_sources_json, liked, created_at, updated_at)
VALUES (@d, @r, @rec_id, @track_id, @nid, @title, @artist,
    @album, @dur, @reason, @ss, @ps, @preview, @liked, @now, @now);
"@ -Params @{
                d = $Date; r = [int](Get-OptionalProperty $rec 'rank'); rec_id = $recId; track_id = $trackId
                nid = [string](Get-OptionalProperty $rec 'netease_id'); title = [string](Get-OptionalProperty $rec 'title')
                artist = [string](Get-OptionalProperty $rec 'artist'); album = [string](Get-OptionalProperty $rec 'album')
                dur = [int](Get-OptionalProperty $rec 'duration'); reason = [string](Get-OptionalProperty $rec 'reason')
                ss = [string](Get-OptionalProperty $rec 'seed_source'); ps = [string](Get-OptionalProperty $rec 'playback_source')
                preview = $preview; liked = $liked; now = (Get-NowIso)
            }
        }
    }
}

function Get-TodayRecommendationsDb {
    param([string]$Date = (Get-TodayDate))
    $rows = @(Invoke-MusicServerParamSql -Template 'SELECT * FROM daily_recommendations WHERE date = @d ORDER BY rank;' -Params @{ d = $Date })
    return @($rows | ForEach-Object { Convert-DbRecRow -Row $_ })
}

function Convert-DbRecRow {
    param([Parameter(Mandatory)][psobject]$Row)
    $preview = @()
    try { if ($Row.preview_sources_json) { $preview = @(ConvertFrom-Json -InputObject ([string]$Row.preview_sources_json)) } } catch {}
    return [pscustomobject]@{
        id = [string]$Row.rec_id; date = [string]$Row.date; track_id = [string]$Row.track_id
        netease_id = [string]$Row.netease_id; title = [string]$Row.title; artist = [string]$Row.artist
        album = [string]$Row.album; duration = [int]$Row.duration; rank = [int]$Row.rank
        reason = [string]$Row.reason; seed_source = [string]$Row.seed_source
        playback_source = [string]$Row.playback_source; preview_sources = $preview
        liked = ([int]$Row.liked -eq 1); created_at = [string]$Row.created_at; updated_at = [string]$Row.updated_at
    }
}

# ================================================================
# Recommendation Feedback
# ================================================================

function Write-FeedbackDb {
    param(
        [Parameter(Mandatory)][string]$TrackId,
        [Parameter(Mandatory)][string]$FeedbackType,
        [string]$Source = '', [string]$Value = ''
    )
    Invoke-MusicServerParamNonQuery -Template @"
INSERT INTO recommendation_feedback (track_id, feedback_type, source, value, created_at)
VALUES (@tid, @ft, @src, @val, @now);
"@ -Params @{ tid = $TrackId; ft = $FeedbackType; src = $Source; val = $Value; now = (Get-NowIso) }
}

# ================================================================
# Wanted Queue - CAS + Worker Claim + Lease
# ================================================================

function Get-WantedItemDb {
    param([Parameter(Mandatory)][string]$TrackId)
    $rows = @(Invoke-MusicServerParamSql -Template 'SELECT * FROM wanted_queue WHERE track_id = @tid LIMIT 1;' -Params @{ tid = $TrackId })
    if ($rows.Count -eq 0) { return $null }
    return Convert-DbWantedRow -Row $rows[0]
}

function Convert-DbWantedRow {
    param([Parameter(Mandatory)][psobject]$Row)
    $selected = $null
    try { if ($Row.selected_candidate_json) { $selected = ConvertFrom-Json -InputObject ([string]$Row.selected_candidate_json) } } catch {}
    return [pscustomobject]@{
        track_id = [string]$Row.track_id; wanted_id = [string]$Row.wanted_id
        state = [string]$Row.state; attempt_count = [int]$Row.attempt_count
        max_attempts = [int]$Row.max_attempts; next_retry_at = [string]$Row.next_retry_at
        selected_candidate = $selected; last_error = [string]$Row.last_error
        claimed_by = [string]$Row.claimed_by; claimed_at = [string]$Row.claimed_at
        lease_expires_at = [string]$Row.lease_expires_at; revision = [int]$Row.revision
        created_at = [string]$Row.created_at; updated_at = [string]$Row.updated_at
    }
}

function Add-WantedItemDb {
    param(
        [Parameter(Mandatory)][string]$TrackId,
        [int]$MaxAttempts = 5
    )
    $existing = Get-WantedItemDb -TrackId $TrackId
    if ($existing) {
        if ([string]$existing.state -in @('UNAVAILABLE','LOCAL','CANCEL_REQUESTED')) {
            $result = Invoke-MusicServerParamNonQuery -Template @"
UPDATE wanted_queue SET state = 'WANTED', attempt_count = 0, next_retry_at = NULL,
    last_error = '', updated_at = @now, revision = revision + 1
WHERE track_id = @tid;
"@ -Params @{ tid = $TrackId; now = (Get-NowIso) }
            return (Get-WantedItemDb -TrackId $TrackId)
        }
        return $existing
    }
    $wantedId = "wanted_$([guid]::NewGuid().ToString('N'))"
    $now = Get-NowIso
    Invoke-MusicServerParamNonQuery -Template @"
INSERT INTO wanted_queue (track_id, wanted_id, state, attempt_count, max_attempts, revision, created_at, updated_at)
VALUES (@tid, @wid, 'WANTED', 0, @ma, 1, @now, @now);
"@ -Params @{ tid = $TrackId; wid = $wantedId; ma = $MaxAttempts; now = $now }
    return (Get-WantedItemDb -TrackId $TrackId)
}

function Get-WantedTracksDb {
    param([switch]$EligibleOnly)
    if (-not $EligibleOnly) {
        $rows = @(Invoke-MusicServerSqlJson -Query 'SELECT * FROM wanted_queue ORDER BY created_at;')
        return @($rows | ForEach-Object { Convert-DbWantedRow -Row $_ })
    }
    $now = (Get-NowIso)
    $rows = @(Invoke-MusicServerParamSql -Template @"
SELECT * FROM wanted_queue
WHERE state IN ('WANTED','CANCEL_REQUESTED')
   OR (state = 'RETRY_WAIT' AND (next_retry_at IS NULL OR next_retry_at <= @now))
ORDER BY created_at;
"@ -Params @{ now = $now })
    return @($rows | ForEach-Object { Convert-DbWantedRow -Row $_ })
}

function Claim-WantedItemDb {
    param(
        [Parameter(Mandatory)][string]$TrackId,
        [Parameter(Mandatory)][string]$WorkerId,
        [int]$LeaseMinutes = 30
    )
    $now = Get-NowIso
    $leaseExpiry = [DateTime]::UtcNow.AddMinutes($LeaseMinutes).ToString('o')
    $result = Invoke-MusicServerParamNonQuery -Template @"
UPDATE wanted_queue SET
    state = 'RESOLVING', claimed_by = @worker, claimed_at = @now,
    lease_expires_at = @lease, revision = revision + 1, updated_at = @now
WHERE track_id = @tid
  AND state IN ('WANTED','RETRY_WAIT')
  AND (claimed_by = '' OR lease_expires_at IS NULL OR lease_expires_at <= @now);
"@ -Params @{ tid = $TrackId; worker = $WorkerId; now = $now; lease = $leaseExpiry }
    $check = @(Invoke-MusicServerParamSql -Template 'SELECT state, claimed_by FROM wanted_queue WHERE track_id = @tid LIMIT 1;' -Params @{ tid = $TrackId })
    if ($check.Count -gt 0 -and [string]$check[0].claimed_by -eq $WorkerId -and [string]$check[0].state -eq 'RESOLVING') {
        return @{ Success = $true; LeaseExpiresAt = $leaseExpiry }
    }
    return @{ Success = $false; Reason = 'CLAIM_CONFLICT' }
}

function Update-WantedStateCasDb {
    param(
        [Parameter(Mandatory)][string]$TrackId,
        [Parameter(Mandatory)][string]$NewState,
        [Parameter(Mandatory)][int]$ExpectedRevision,
        [Parameter(Mandatory)][string]$WorkerId,
        [string]$LastError = '',
        [string]$NextRetryAt = '',
        [int]$AttemptCount = -1
    )
    $now = Get-NowIso
    $setClauses = @('state = @state', 'revision = revision + 1', 'updated_at = @now')
    $params = @{ tid = $TrackId; state = $NewState; now = $now; rev = $ExpectedRevision; worker = $WorkerId }
    if ($LastError) { $setClauses += 'last_error = @err'; $params['err'] = $LastError }
    if ($NextRetryAt) { $setClauses += 'next_retry_at = @nrt'; $params['nrt'] = $NextRetryAt }
    if ($AttemptCount -ge 0) { $setClauses += 'attempt_count = @ac'; $params['ac'] = $AttemptCount }
    if ($NewState -ne 'RESOLVING') { $setClauses += "claimed_by = ''"; $setClauses += 'lease_expires_at = NULL' }
    $setSql = ($setClauses -join ', ')
    $result = Invoke-MusicServerParamNonQuery -Template @"
UPDATE wanted_queue SET $setSql
WHERE track_id = @tid AND revision = @rev AND claimed_by = @worker;
"@ -Params $params
    $check = @(Invoke-MusicServerParamSql -Template 'SELECT revision, state FROM wanted_queue WHERE track_id = @tid LIMIT 1;' -Params @{ tid = $TrackId })
    if ($check.Count -eq 0) { return @{ Success = $false; Reason = 'NOT_FOUND' } }
    $newRevision = [int]$check[0].revision
    if ($newRevision -eq $ExpectedRevision) {
        return @{ Success = $false; Reason = 'CAS_FAILED' }
    }
    return @{ Success = $true; Revision = $newRevision; CurrentState = [string]$check[0].state }
}

function Request-WantedCancellationDb {
    param(
        [Parameter(Mandatory)][string]$TrackId,
        [int]$CurrentRevision = -1
    )
    $now = Get-NowIso
    $activeStates = @('RESOLVING','DOWNLOADING','VALIDATING')
    $idleStates = @('WANTED','RETRY_WAIT','UNAVAILABLE')
    $item = Get-WantedItemDb -TrackId $TrackId
    if (-not $item) { return @{ Success = $false; Reason = 'NOT_FOUND' } }
    if ([string]$item.state -eq 'CANCEL_REQUESTED') { return @{ Success = $true; Reason = 'ALREADY_CANCELLED' } }
    if ([string]$item.state -eq 'LOCAL') { return @{ Success = $false; Reason = 'ALREADY_LOCAL' } }
    if ([string]$item.state -in $idleStates) {
        Invoke-MusicServerParamNonQuery -Template @"
DELETE FROM wanted_queue WHERE track_id = @tid;
"@ -Params @{ tid = $TrackId }
        Invoke-MusicServerParamNonQuery -Template @"
UPDATE canonical_tracks SET status = 'REMOTE', updated_at = @now, revision = revision + 1
WHERE id = @tid AND status != 'LOCAL';
"@ -Params @{ tid = $TrackId; now = $now }
        Write-FeedbackDb -TrackId $TrackId -FeedbackType 'UNLIKE'
        Write-MusicServerEventDb -EventType 'WANTED_CANCELLED' -TrackId $TrackId -Message 'idle item removed'
        return @{ Success = $true; Reason = 'IDLE_REMOVED' }
    }
    if ([string]$item.state -in $activeStates) {
        $newRev = $item.revision + 1
        Invoke-MusicServerParamNonQuery -Template @"
UPDATE wanted_queue SET state = 'CANCEL_REQUESTED', last_error = 'USER_CANCELLED',
    revision = @rev, updated_at = @now, claimed_by = '', lease_expires_at = NULL
WHERE track_id = @tid AND revision = @currev;
"@ -Params @{ tid = $TrackId; rev = $newRev; now = $now; currev = $item.revision }
        Write-FeedbackDb -TrackId $TrackId -FeedbackType 'UNLIKE'
        Write-MusicServerEventDb -EventType 'WANTED_CANCEL_REQUESTED' -TrackId $TrackId -Message "active item marked cancel; state=$($item.state)"
        return @{ Success = $true; Reason = 'CANCEL_REQUESTED' }
    }
    return @{ Success = $false; Reason = "UNKNOWN_STATE:$($item.state)" }
}

function Complete-WantedCancellationDb {
    param(
        [Parameter(Mandatory)][string]$TrackId,
        [string]$TemporaryPath = ''
    )
    if ($TemporaryPath -and (Test-Path -LiteralPath $TemporaryPath)) {
        Remove-Item -LiteralPath $TemporaryPath -Force -ErrorAction SilentlyContinue
        $tempLrc = [IO.Path]::ChangeExtension($TemporaryPath, '.lrc')
        Remove-Item -LiteralPath $tempLrc -Force -ErrorAction SilentlyContinue
    }
    $now = Get-NowIso
    Invoke-MusicServerParamNonQuery -Template @"
DELETE FROM wanted_queue WHERE track_id = @tid;
"@ -Params @{ tid = $TrackId }
    Invoke-MusicServerParamNonQuery -Template @"
UPDATE canonical_tracks SET status = 'REMOTE', updated_at = @now, revision = revision + 1
WHERE id = @tid AND status != 'LOCAL';
"@ -Params @{ tid = $TrackId; now = $now }
    Write-MusicServerEventDb -EventType 'WANTED_CANCELLED' -TrackId $TrackId -Message 'cancellation completed'
}

function Renew-LeaseDb {
    param(
        [Parameter(Mandatory)][string]$TrackId,
        [Parameter(Mandatory)][string]$WorkerId,
        [int]$LeaseMinutes = 30
    )
    $leaseExpiry = [DateTime]::UtcNow.AddMinutes($LeaseMinutes).ToString('o')
    Invoke-MusicServerParamNonQuery -Template @"
UPDATE wanted_queue SET lease_expires_at = @lease, updated_at = @now
WHERE track_id = @tid AND claimed_by = @worker AND state IN ('RESOLVING','DOWNLOADING','VALIDATING');
"@ -Params @{ tid = $TrackId; worker = $WorkerId; lease = $leaseExpiry; now = (Get-NowIso) }
}

# ================================================================
# Crash Recovery
# ================================================================

function Invoke-CrashRecoveryDb {
    $nowIso = Get-NowIso
    $nowUnix = [long]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
    $staleRows = @(Invoke-MusicServerParamSql -Template @"
SELECT track_id, state, attempt_count, lease_expires_at FROM wanted_queue
WHERE state IN ('RESOLVING','DOWNLOADING','VALIDATING')
  AND lease_expires_at IS NOT NULL AND lease_expires_at != '';
"@ -Params @{ })
    $recovered = 0
    foreach ($row in $staleRows) {
        $tid = [string]$row.track_id
        $state = [string]$row.state
        $leaseExpiry = Convert-ToUtcDateTime ([string]$row.lease_expires_at)
        if (-not $leaseExpiry) { continue }
        $leaseTicks = $leaseExpiry.ToUniversalTime().Ticks
        $leaseUnix = [long]($leaseTicks / 10000000 - 62135596800)
        if ($leaseUnix -ge $nowUnix) { continue }
        $cancelCheck = @(Invoke-MusicServerParamSql -Template 'SELECT state FROM wanted_queue WHERE track_id = @tid LIMIT 1;' -Params @{ tid = $tid })
        if ($cancelCheck.Count -gt 0 -and [string]$cancelCheck[0].state -eq 'CANCEL_REQUESTED') {
            Complete-WantedCancellationDb -TrackId $tid
            Write-MusicServerEventDb -EventType 'WANTED_LEASE_RECOVERED' -TrackId $tid -Message "stale $state + CANCEL_REQUESTED -> cancel cleanup"
            $recovered++
            continue
        }
        $newAttempts = [int]$row.attempt_count + 1
        $nowUpdate = Get-NowIso
        Invoke-MusicServerParamNonQuery -Template @"
UPDATE wanted_queue SET state = 'RETRY_WAIT', attempt_count = @ac, claimed_by = '',
    lease_expires_at = NULL, last_error = 'STALE_LEASE_RECOVERY', updated_at = @now,
    revision = revision + 1
WHERE track_id = @tid;
"@ -Params @{ tid = $tid; ac = $newAttempts; now = $nowUpdate }
        Write-MusicServerEventDb -EventType 'WANTED_LEASE_RECOVERED' -TrackId $tid -Message "stale $state -> RETRY_WAIT; attempts=$newAttempts"
        $recovered++
    }
    return $recovered
}

# ================================================================
# Provider Health
# ================================================================

function Get-ProviderHealthDb {
    param([Parameter(Mandatory)][string]$Provider)
    $rows = @(Invoke-MusicServerParamSql -Template 'SELECT * FROM provider_health WHERE provider = @p LIMIT 1;' -Params @{ p = $Provider })
    if ($rows.Count -gt 0) { return Convert-DbProviderRow -Row $rows[0] }
    return [pscustomobject]@{
        provider = $Provider; state = 'CLOSED'; success_count = 0; failure_count = 0
        consecutive_failures = 0; consecutive_412 = 0; last_success = $null; last_failure = $null
        last_412_at = $null; blocked_until = $null; average_latency_ms = 0
        half_open_probe_claimed = 0; last_error = ''; revision = 0; updated_at = ''
    }
}

function Convert-DbProviderRow {
    param([Parameter(Mandatory)][psobject]$Row)
    return [pscustomobject]@{
        provider = [string]$Row.provider; state = [string]$Row.state
        success_count = [int]$Row.success_count; failure_count = [int]$Row.failure_count
        consecutive_failures = [int]$Row.consecutive_failures; consecutive_412 = [int]$Row.consecutive_412
        last_success = [string]$Row.last_success; last_failure = [string]$Row.last_failure
        last_412_at = [string]$Row.last_412_at; blocked_until = [string]$Row.blocked_until
        average_latency_ms = [double]$Row.average_latency_ms
        half_open_probe_claimed = [int]$Row.half_open_probe_claimed
        last_error = [string]$Row.last_error; revision = [int]$Row.revision
        updated_at = [string]$Row.updated_at
    }
}

function Save-ProviderHealthDb {
    param([Parameter(Mandatory)][psobject]$Health)
    $now = Get-NowIso
    $existing = @(Invoke-MusicServerParamSql -Template 'SELECT revision FROM provider_health WHERE provider = @p LIMIT 1;' -Params @{ p = [string]$Health.provider })
    if ($existing.Count -gt 0) {
        $newRev = [int]$existing[0].revision + 1
        Invoke-MusicServerParamNonQuery -Template @"
UPDATE provider_health SET state = @state, success_count = @sc, failure_count = @fc,
    consecutive_failures = @cf, consecutive_412 = @c412, last_success = @ls,
    last_failure = @lf, last_412_at = @l412, blocked_until = @bu,
    average_latency_ms = @alm, half_open_probe_claimed = @hpp,
    last_error = @err, revision = @rev, updated_at = @now
WHERE provider = @p;
"@ -Params @{
            p = [string]$Health.provider; state = [string]$Health.state
            sc = [int]$Health.success_count; fc = [int]$Health.failure_count
            cf = [int]$Health.consecutive_failures; c412 = [int]$Health.consecutive_412
            ls = [string](Get-OptionalProperty $Health 'last_success')
            lf = [string](Get-OptionalProperty $Health 'last_failure')
            l412 = [string](Get-OptionalProperty $Health 'last_412_at')
            bu = [string](Get-OptionalProperty $Health 'blocked_until')
            alm = [double](Get-OptionalProperty $Health 'average_latency_ms')
            hpp = [int](Get-OptionalProperty $Health 'half_open_probe_claimed')
            err = [string](Get-OptionalProperty $Health 'last_error')
            rev = $newRev; now = $now
        }
    } else {
        Invoke-MusicServerParamNonQuery -Template @"
INSERT INTO provider_health (provider, state, success_count, failure_count,
    consecutive_failures, consecutive_412, last_success, last_failure, last_412_at,
    blocked_until, average_latency_ms, half_open_probe_claimed, last_error, revision, updated_at)
VALUES (@p, @state, @sc, @fc, @cf, @c412, @ls, @lf, @l412, @bu, @alm, @hpp, @err, 1, @now);
"@ -Params @{
            p = [string]$Health.provider; state = [string]$Health.state
            sc = [int]$Health.success_count; fc = [int]$Health.failure_count
            cf = [int]$Health.consecutive_failures; c412 = [int]$Health.consecutive_412
            ls = [string](Get-OptionalProperty $Health 'last_success')
            lf = [string](Get-OptionalProperty $Health 'last_failure')
            l412 = [string](Get-OptionalProperty $Health 'last_412_at')
            bu = [string](Get-OptionalProperty $Health 'blocked_until')
            alm = [double](Get-OptionalProperty $Health 'average_latency_ms')
            hpp = [int](Get-OptionalProperty $Health 'half_open_probe_claimed')
            err = [string](Get-OptionalProperty $Health 'last_error')
            now = $now
        }
    }
}

function Claim-HalfOpenProbeDb {
    param([Parameter(Mandatory)][string]$Provider)
    $now = Get-NowIso
    $result = Invoke-MusicServerParamNonQuery -Template @"
UPDATE provider_health SET half_open_probe_claimed = 1, revision = revision + 1, updated_at = @now
WHERE provider = @p AND state = 'HALF_OPEN' AND half_open_probe_claimed = 0;
"@ -Params @{ p = $Provider; now = $now }
    $check = @(Invoke-MusicServerParamSql -Template 'SELECT half_open_probe_claimed FROM provider_health WHERE provider = @p LIMIT 1;' -Params @{ p = $Provider })
    if ($check.Count -gt 0 -and [int]$check[0].half_open_probe_claimed -eq 1) {
        return $true
    }
    return $false
}

function Get-ProviderStatusesDb {
    $providers = @('local','bilibili_search','bilibili_download')
    return @($providers | ForEach-Object { Get-ProviderHealthDb -Provider $_ })
}

# ================================================================
# Events
# ================================================================

function Write-MusicServerEventDb {
    param(
        [string]$EventType = '', [string]$TrackId = '', [string]$Provider = '',
        [string]$FromState = '', [string]$ToState = '', [int]$Attempt = 0,
        [double]$DurationMs = 0, [string]$Result = '', [string]$ErrorType = '',
        [int]$HttpStatus = 0, [string]$Message = ''
    )
    Invoke-MusicServerParamNonQuery -Template @"
INSERT INTO events (event_type, track_id, provider, from_state, to_state,
    attempt, duration_ms, result, error_type, http_status, message, created_at)
VALUES (@et, @tid, @prov, @fs, @ts, @att, @dur, @res, @err, @hs, @msg, @now);
"@ -Params @{
        et = $EventType; tid = $TrackId; prov = $Provider; fs = $FromState; ts = $ToState
        att = $Attempt; dur = $DurationMs; res = $Result; err = $ErrorType; hs = $HttpStatus
        msg = $Message; now = (Get-NowIso)
    }
}

function Get-EventsDb {
    param([int]$Limit = 50, [string]$TrackId = '')
    if ($TrackId) {
        $rows = @(Invoke-MusicServerParamSql -Template 'SELECT * FROM events WHERE track_id = @tid ORDER BY id DESC LIMIT @lim;' -Params @{ tid = $TrackId; lim = $Limit })
    } else {
        $rows = @(Invoke-MusicServerParamSql -Template 'SELECT * FROM events ORDER BY id DESC LIMIT @lim;' -Params @{ lim = $Limit })
    }
    return $rows
}

# ================================================================
# Stats / Counts
# ================================================================

function Get-DbStats {
    $stats = @{}
    foreach ($table in @('canonical_tracks','daily_recommendations','recommendation_feedback','wanted_queue','provider_health','events')) {
        $rows = @(Invoke-MusicServerSqlJson -Query "SELECT COUNT(*) as cnt FROM $table;")
        if ($rows.Count -gt 0) {
            $cnt = 0
            if ($rows[0] -is [pscustomobject]) {
                $p = $rows[0].PSObject.Properties['cnt']
                if ($p) { $cnt = [int]$p.Value }
            } else { $cnt = [int]$rows[0] }
            $stats[$table] = $cnt
        } else { $stats[$table] = 0 }
    }
    return $stats
}

Export-ModuleMember -Function *
