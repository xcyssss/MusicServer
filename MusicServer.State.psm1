Set-StrictMode -Version 3.0

# MusicServer.State.psm1 - Transactional state layer backed by SQLite
# Provides: schema, migration, CAS, worker claim/lease, crash recovery,
#           transactional like/unlike/download-completion, provider health.

Import-Module (Join-Path $PSScriptRoot 'MusicServer.Database.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'MusicServer.Core.psm1') -Force

$script:SchemaVersion = 6

# Local files carry uploader tags rather than the singer, so the real artist is
# resolved once and cached here. Rows are keyed by normalized file path because
# that is the fact that survives re-indexing; a NOT_FOUND row records that the
# lookup ran so the next start does not repeat the same network search. Kept as
# one definition because the launcher bootstraps this table on its own: it
# connects to an existing database without running the full schema script.
$script:LocalTrackArtistDdl = @"
CREATE TABLE IF NOT EXISTS local_track_artists (
    path_key TEXT PRIMARY KEY,
    artist TEXT NOT NULL DEFAULT '',
    album TEXT NOT NULL DEFAULT '',
    status TEXT NOT NULL DEFAULT '',
    source TEXT NOT NULL DEFAULT '',
    release_year INTEGER NOT NULL DEFAULT 0,
    updated_at TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS idx_local_track_artists_status ON local_track_artists(status);
"@

function Initialize-LocalTrackArtistSchema {
    <#
    .SYNOPSIS
      Creates (and upgrades) the resolved-artist cache table.

      Initialize-MusicServerSchema creates the whole schema, but the launcher
      binds an existing database with Connect-MusicServerDatabase, which by design
      changes nothing. The artist backfill runs in the launcher, so it ensures its
      own table instead of depending on the API process having started first.

      CREATE TABLE IF NOT EXISTS does not add columns to an existing database, so
      a column added to the DDL above must also be added here or upgraded
      installs would keep the old shape and silently write nothing.
    #>
    Invoke-MusicServerSqlNonQuery -Query $script:LocalTrackArtistDdl
    $columns = @(Invoke-MusicServerSqlJson -Query 'PRAGMA table_info(local_track_artists);')
    if (-not ($columns | Where-Object { [string]$_.name -eq 'release_year' })) {
        Invoke-MusicServerSqlNonQuery -Query 'ALTER TABLE local_track_artists ADD COLUMN release_year INTEGER NOT NULL DEFAULT 0;'
    }
}
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
    -- NetEase's album.publishTime. The local file's own `year` tag is NOT used
    -- for this: Bilibili downloads carry the upload/encode year there, so a
    -- 1990s song uploaded in 2024 would claim 2024. 0 means unknown.
    release_year INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT '',
    updated_at TEXT DEFAULT '',
    revision INTEGER NOT NULL DEFAULT 0
);
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
CREATE TABLE IF NOT EXISTS recommendation_feedback (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    track_id TEXT NOT NULL,
    feedback_type TEXT NOT NULL,
    source TEXT NOT NULL DEFAULT '',
    value TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS recommendation_files (
    file_name TEXT PRIMARY KEY,
    track_id TEXT NOT NULL DEFAULT '',
    date TEXT NOT NULL DEFAULT '',
    netease_id TEXT NOT NULL DEFAULT '',
    title TEXT NOT NULL DEFAULT '',
    artist TEXT NOT NULL DEFAULT '',
    album TEXT NOT NULL DEFAULT '',
    duration INTEGER NOT NULL DEFAULT 0,
    seed_source TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS migration_markers (
    source_key TEXT PRIMARY KEY,
    imported_at TEXT NOT NULL,
    result_json TEXT NOT NULL DEFAULT ''
);
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
    lease_expires_epoch INTEGER,
    revision INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL DEFAULT ''
);
"@
    # CREATE TABLE IF NOT EXISTS does not add columns to an existing state DB.
    # Keep this upgrade local and idempotent; the TEXT timestamp remains as a
    # human-readable diagnostic while all lease decisions use the INTEGER.
    $wantedColumns = @(Invoke-MusicServerSqlJson -Query 'PRAGMA table_info(wanted_queue);')
    if (-not ($wantedColumns | Where-Object { [string]$_.name -eq 'lease_expires_epoch' })) {
        Invoke-MusicServerSqlNonQuery -Query 'ALTER TABLE wanted_queue ADD COLUMN lease_expires_epoch INTEGER;'
    }
    $trackColumns = @(Invoke-MusicServerSqlJson -Query 'PRAGMA table_info(canonical_tracks);')
    if (-not ($trackColumns | Where-Object { [string]$_.name -eq 'release_year' })) {
        Invoke-MusicServerSqlNonQuery -Query 'ALTER TABLE canonical_tracks ADD COLUMN release_year INTEGER NOT NULL DEFAULT 0;'
    }
    # The launcher bootstraps this table itself, so its own upgrader is the single
    # implementation; calling it here keeps both paths on the same shape.
    Initialize-LocalTrackArtistSchema
    Invoke-MusicServerSqlNonQuery -Query @"
UPDATE wanted_queue
SET lease_expires_epoch = CAST(strftime('%s', lease_expires_at) AS INTEGER)
WHERE lease_expires_epoch IS NULL
  AND lease_expires_at IS NOT NULL
  AND lease_expires_at != '';
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
CREATE TABLE IF NOT EXISTS listening_stats (
    identity TEXT PRIMARY KEY,
    track_id TEXT NOT NULL DEFAULT '',
    library_id TEXT NOT NULL DEFAULT '',
    play_count INTEGER NOT NULL DEFAULT 0,
    last_played_at TEXT,
    first_played_at TEXT,
    updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS listening_play_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    identity TEXT NOT NULL,
    session_id TEXT NOT NULL,
    track_id TEXT NOT NULL DEFAULT '',
    library_id TEXT NOT NULL DEFAULT '',
    played_at TEXT NOT NULL,
    UNIQUE(identity, session_id)
);
CREATE TRIGGER IF NOT EXISTS trg_listening_play_event_stats
AFTER INSERT ON listening_play_events
BEGIN
    INSERT OR IGNORE INTO listening_stats (identity, track_id, library_id, play_count, last_played_at, first_played_at, updated_at)
    VALUES (NEW.identity, NEW.track_id, NEW.library_id, 0, NULL, NULL, NEW.played_at);
    UPDATE listening_stats
       SET track_id = CASE WHEN NEW.track_id != '' THEN NEW.track_id ELSE track_id END,
           library_id = CASE WHEN NEW.library_id != '' THEN NEW.library_id ELSE library_id END,
           play_count = play_count + 1,
           last_played_at = NEW.played_at,
           first_played_at = COALESCE(first_played_at, NEW.played_at),
           updated_at = NEW.played_at
     WHERE identity = NEW.identity;
END;
CREATE TABLE IF NOT EXISTS app_settings (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL DEFAULT '',
    updated_at TEXT NOT NULL DEFAULT ''
);
-- Local files carry uploader tags rather than the singer, so the real artist is
-- resolved once and cached here. Rows are keyed by normalized file path because
-- that is the fact that survives re-indexing; a NOT_FOUND row records that the
-- lookup ran so the next start does not repeat the same network search. The
-- definition is shared with the launcher, which creates this table on its own.
$script:LocalTrackArtistDdl
CREATE INDEX IF NOT EXISTS idx_wanted_state ON wanted_queue(state);
CREATE INDEX IF NOT EXISTS idx_wanted_lease ON wanted_queue(lease_expires_at);
CREATE INDEX IF NOT EXISTS idx_wanted_lease_epoch ON wanted_queue(lease_expires_epoch);
CREATE INDEX IF NOT EXISTS idx_events_track ON events(track_id);
CREATE INDEX IF NOT EXISTS idx_events_type ON events(event_type);
CREATE INDEX IF NOT EXISTS idx_events_created ON events(created_at);
CREATE INDEX IF NOT EXISTS idx_daily_date ON daily_recommendations(date);
CREATE INDEX IF NOT EXISTS idx_feedback_track ON recommendation_feedback(track_id);
CREATE INDEX IF NOT EXISTS idx_recommendation_files_track ON recommendation_files(track_id);
CREATE INDEX IF NOT EXISTS idx_recommendation_files_date ON recommendation_files(date);
CREATE INDEX IF NOT EXISTS idx_listening_stats_track ON listening_stats(track_id);
CREATE INDEX IF NOT EXISTS idx_listening_stats_last_played ON listening_stats(last_played_at);
CREATE INDEX IF NOT EXISTS idx_listening_play_events_identity ON listening_play_events(identity);
"@
    Set-SchemaVersion -Version $script:SchemaVersion
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

function Get-CanonicalLocalTrackMapDb {
    $map = @{}
    foreach ($row in @(Invoke-MusicServerSqlJson -Query "SELECT id, local_song_id, status FROM canonical_tracks WHERE local_song_id IS NOT NULL AND local_song_id != '';")) {
        $localSongId = [string]$row.local_song_id
        if ($localSongId) { $map[$localSongId] = $row }
    }
    return $map
}

# ================================================================
# Local track artists
# ================================================================

function Get-LocalTrackArtistMapDb {
    <#
    .SYNOPSIS
      Cached resolved artists keyed by normalized file path.
    #>
    $map = @{}
    foreach ($row in @(Invoke-MusicServerSqlJson -Query 'SELECT path_key, artist, album, status, source, release_year, updated_at FROM local_track_artists;')) {
        $key = [string]$row.path_key
        if ($key) { $map[$key] = $row }
    }
    return $map
}

function Get-LocalTrackArtistDb {
    param([Parameter(Mandatory)][string]$PathKey)
    $rows = @(Invoke-MusicServerParamSql -Template 'SELECT path_key, artist, album, status, source, release_year, updated_at FROM local_track_artists WHERE path_key = @path_key LIMIT 1;' -Params @{ path_key = $PathKey })
    if ($rows.Count -eq 0) { return $null }
    return $rows[0]
}

function Save-LocalTrackArtistDb {
    <#
    .SYNOPSIS
      Records the outcome of one artist lookup, including a negative result, so a
      library that cannot be resolved is not re-queried on every start.
    #>
    param(
        [Parameter(Mandatory)][string]$PathKey,
        [AllowEmptyString()][string]$Artist = '',
        [AllowEmptyString()][string]$Album = '',
        [Parameter(Mandatory)][string]$Status,
        [AllowEmptyString()][string]$Source = '',
        [int]$ReleaseYear = 0
    )
    # The template expands parameters as SQL literals, so the timestamp has to be
    # evaluated here; passing the command name would store it verbatim.
    $now = Get-NowIso
    $affected = Invoke-MusicServerParamNonQuery -Template @"
INSERT INTO local_track_artists (path_key, artist, album, status, source, release_year, updated_at)
VALUES (@path_key, @artist, @album, @status, @source, @release_year, @updated_at)
ON CONFLICT(path_key) DO UPDATE SET
    artist = excluded.artist, album = excluded.album, status = excluded.status,
    source = excluded.source, release_year = excluded.release_year, updated_at = excluded.updated_at;
"@ -Params @{
        path_key = $PathKey; artist = $Artist; album = $Album
        status = $Status; source = $Source; release_year = $ReleaseYear; updated_at = $now
    }
    return [int]$affected
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
        $revisionPredicate = if ($CAS) { ' AND revision = @expected_revision' } else { '' }
        $updateParams = @{
            id = [string]$Track.id; title = [string]$Track.title; artist = [string](Get-OptionalProperty $Track 'artist')
            album = [string](Get-OptionalProperty $Track 'album'); duration = [int](Get-OptionalProperty $Track 'duration')
            cover_url = [string](Get-OptionalProperty $Track 'cover_url'); identifiers = $identifiers
            preview = $preview; candidates = $candidates; local_song_id = [string](Get-OptionalProperty $Track 'local_song_id')
            status = [string](Get-OptionalProperty $Track 'status' 'REMOTE'); updated_at = $now; revision = $newRevision
            release_year = [int](Get-OptionalProperty $Track 'release_year' 0)
        }
        if ($CAS) { $updateParams['expected_revision'] = $ExpectedRevision }
        $affected = Invoke-MusicServerParamNonQuery -Template @"
UPDATE canonical_tracks SET
    title = @title, artist = @artist, album = @album, duration = @duration,
    cover_url = @cover_url, identifiers_json = @identifiers, preview_sources_json = @preview,
    download_candidates_json = @candidates, local_song_id = @local_song_id,
    status = @status, release_year = CASE WHEN @release_year > 0 THEN @release_year ELSE release_year END,
    updated_at = @updated_at, revision = @revision
WHERE id = @id$revisionPredicate;
"@ -Params $updateParams -ReturnChanges
        if ($affected -ne 1) {
            $latest = @(Invoke-MusicServerParamSql -Template 'SELECT revision FROM canonical_tracks WHERE id = @id LIMIT 1;' -Params @{ id = [string]$Track.id })
            return @{
                Success = $false; Reason = 'CAS_MISMATCH'; AffectedRows = [long]$affected
                CurrentRevision = if ($latest.Count -gt 0) { [int]$latest[0].revision } else { -1 }
            }
        }
        return @{ Success = $true; Revision = $newRevision; AffectedRows = [long]$affected }
    } else {
        $created = [string](Get-OptionalProperty $Track 'created_at' $now)
        Invoke-MusicServerParamNonQuery -Template @"
INSERT INTO canonical_tracks (id, title, artist, album, duration, cover_url,
    identifiers_json, preview_sources_json, download_candidates_json,
    local_song_id, status, release_year, created_at, updated_at, revision)VALUES (@id, @title, @artist, @album, @duration, @cover_url,
    @identifiers, @preview, @candidates,
    @local_song_id, @status, @release_year, @created_at, @updated_at, 1);
"@ -Params @{
            id = [string]$Track.id; title = [string]$Track.title; artist = [string](Get-OptionalProperty $Track 'artist')
            album = [string](Get-OptionalProperty $Track 'album'); duration = [int](Get-OptionalProperty $Track 'duration')
            cover_url = [string](Get-OptionalProperty $Track 'cover_url'); identifiers = $identifiers
            preview = $preview; candidates = $candidates; local_song_id = [string](Get-OptionalProperty $Track 'local_song_id')
            status = [string](Get-OptionalProperty $Track 'status' 'REMOTE'); created_at = $created; updated_at = $now
            release_year = [int](Get-OptionalProperty $Track 'release_year' 0)
        }
        return @{ Success = $true; Revision = 1 }
    }
}

function Set-CanonicalTrackStatusDb {
    param(
        [Parameter(Mandatory)][string]$TrackId,
        [Parameter(Mandatory)][ValidateSet('REMOTE','WANTED','RESOLVING','DOWNLOADING','VALIDATING','RETRY_WAIT','UNAVAILABLE','LOCAL','CANCEL_REQUESTED')][string]$Status,
        [string]$LocalSongId = '',
        [switch]$CAS,
        [int]$ExpectedRevision = -1
    )
    $track = Get-CanonicalTrackDb -TrackId $TrackId
    if ($null -eq $track) { return $null }
    if ($CAS -and $ExpectedRevision -lt 0) { $ExpectedRevision = [int]$track.revision }
    $track.status = $Status
    if ($PSBoundParameters.ContainsKey('LocalSongId')) { $track.local_song_id = $LocalSongId }
    $saved = if ($CAS) {
        Save-CanonicalTrackDb -Track $track -CAS -ExpectedRevision $ExpectedRevision
    } else {
        Save-CanonicalTrackDb -Track $track
    }
    if (-not $saved.Success) { return $null }
    return (Get-CanonicalTrackDb -TrackId $TrackId)
}

function Reset-CanonicalTrackToRemoteDb {
    param([Parameter(Mandatory)][string]$TrackId)
    $track = Get-CanonicalTrackDb -TrackId $TrackId
    if ($null -eq $track) { return $null }
    if ([string]$track.status -ne 'LOCAL') {
        $track.status = 'REMOTE'
        Save-CanonicalTrackDb -Track $track | Out-Null
    }
    return (Get-CanonicalTrackDb -TrackId $TrackId)
}

function Add-CanonicalTrackIdentifierDb {
    # Persist a discovered identifier (e.g. a NetEase id found by provider search)
    # so later download attempts, lyrics and recommendation assembly reuse it
    # instead of searching again. Idempotent per (type, value).
    param(
        [Parameter(Mandatory)][string]$TrackId,
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)][string]$Value
    )
    if (-not $Type -or -not $Value) { return $false }
    $rows = @(Invoke-MusicServerParamSql -Template 'SELECT identifiers_json FROM canonical_tracks WHERE id = @id LIMIT 1;' -Params @{ id = $TrackId })
    if ($rows.Count -eq 0) { return $false }
    # Windows PowerShell 5.1 can hand back a nested array from ConvertFrom-Json
    # inside a module scope, so flatten defensively instead of trusting the shape.
    $identifiers = New-Object System.Collections.ArrayList
    $parsed = $null
    try { if ($rows[0].identifiers_json) { $parsed = ConvertFrom-Json -InputObject ([string]$rows[0].identifiers_json) } } catch { $parsed = $null }
    $pending = New-Object System.Collections.Queue
    foreach ($entry in @($parsed)) { $pending.Enqueue($entry) }
    while ($pending.Count -gt 0) {
        $entry = $pending.Dequeue()
        if ($null -eq $entry) { continue }
        # PS 5.1 can hand back Object[], ArrayList or List wrappers here, so treat
        # any non-string enumerable as a container and keep flattening.
        if (($entry -is [System.Collections.IEnumerable]) -and -not ($entry -is [string])) {
            foreach ($inner in $entry) { $pending.Enqueue($inner) }
            continue
        }
        # ConvertTo-Json renders a list wrapper as {value:[...],Count:n}; unwrap it
        # so an already corrupted row still reports its real identifiers.
        if (-not (Get-OptionalProperty $entry 'type' '') -and $entry.PSObject.Properties['value'] -and ($entry.value -is [System.Collections.IEnumerable]) -and -not ($entry.value -is [string])) {
            foreach ($inner in $entry.value) { $pending.Enqueue($inner) }
            continue
        }
        [void]$identifiers.Add($entry)
    }
    foreach ($existing in $identifiers) {
        if ([string](Get-OptionalProperty $existing 'type' '') -eq $Type -and [string](Get-OptionalProperty $existing 'value' '') -eq $Value) { return $false }
    }
    [void]$identifiers.Add([pscustomobject]@{ type = $Type; value = $Value })
    $json = ConvertTo-Json -InputObject @($identifiers.ToArray()) -Compress -Depth 10
    $affected = Invoke-MusicServerParamNonQuery -Template @"
UPDATE canonical_tracks
SET identifiers_json = @ident, updated_at = @now, revision = revision + 1
WHERE id = @id;
"@ -Params @{ ident = $json; now = (Get-NowIso); id = $TrackId } -ReturnChanges
    return ([int]$affected -gt 0)
}

function Set-CanonicalTrackStatusForWantedDb {
    param(
        [Parameter(Mandatory)][string]$TrackId,
        [Parameter(Mandatory)][string]$WorkerId,
        [Parameter(Mandatory)][string]$WantedState,
        [Parameter(Mandatory)][ValidateSet('REMOTE','WANTED','RESOLVING','DOWNLOADING','VALIDATING','RETRY_WAIT','UNAVAILABLE','LOCAL','CANCEL_REQUESTED')][string]$Status,
        [string]$LocalSongId = ''
    )
    $nowEpoch = [long][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $affected = Invoke-MusicServerParamNonQuery -Template @"
UPDATE canonical_tracks
SET status = @status,
    local_song_id = CASE WHEN @has_local = 1 THEN @local_song_id ELSE local_song_id END,
    updated_at = @now, revision = revision + 1
WHERE id = @tid
  AND EXISTS (
      SELECT 1 FROM wanted_queue q
      WHERE q.track_id = @tid AND q.state = @wanted_state
        AND (q.state NOT IN ('RESOLVING','DOWNLOADING','VALIDATING')
             OR (q.claimed_by = @worker AND (q.lease_expires_epoch IS NULL OR q.lease_expires_epoch > @now_epoch)))
  );
"@ -Params @{
        tid = $TrackId; status = $Status; has_local = if ($PSBoundParameters.ContainsKey('LocalSongId')) { 1 } else { 0 }
        local_song_id = $LocalSongId; now = Get-NowIso; wanted_state = $WantedState
        worker = $WorkerId; now_epoch = $nowEpoch
    } -ReturnChanges
    return ([int]$affected -eq 1)
}

function Finalize-WantedLocalDb {
    <#
    .SYNOPSIS
      Atomically transition wanted_queue + canonical_tracks to LOCAL in one
      SQLite transaction.  Eliminates the two-step half-state risk where
      queue=LOCAL but canonical is still non-LOCAL after a crash.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TrackId,
        [Parameter(Mandatory)][string]$WorkerId,
        [Parameter(Mandatory)][string]$ExpectedState,
        [string]$LocalSongId = '',
        [int]$FailAfterStep = 0
    )

    $item = Get-WantedItemDb -TrackId $TrackId
    if ($null -eq $item) {
        return @{ Success = $false; Reason = 'NOT_FOUND' }
    }
    if ([string]$item.state -eq 'CANCEL_REQUESTED') {
        return @{ Success = $false; Reason = 'CANCEL_REQUESTED' }
    }
    $nowEpoch = [long][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if ([string]$item.state -in @('RESOLVING','DOWNLOADING','VALIDATING') -and
        ($null -ne $item.lease_expires_epoch -and [long]$item.lease_expires_epoch -le $nowEpoch)) {
        return @{ Success = $false; Reason = 'LEASE_EXPIRED' }
    }

    $hasLocal = [bool]($PSBoundParameters.ContainsKey('LocalSongId') -and $LocalSongId)
    $localSongLiteral = if ($hasLocal) { ConvertTo-MusicServerSqlLiteral $LocalSongId } else { "''" }

    $queueSql = @"
UPDATE wanted_queue
SET state = 'LOCAL', claimed_by = '', lease_expires_at = NULL,
    lease_expires_epoch = NULL, revision = revision + 1, updated_at = datetime('now')
WHERE track_id = $(ConvertTo-MusicServerSqlLiteral $TrackId)
  AND state = $(ConvertTo-MusicServerSqlLiteral $ExpectedState)
  AND claimed_by = $(ConvertTo-MusicServerSqlLiteral $WorkerId);
"@

    $canonicalSql = @"
UPDATE canonical_tracks
SET status = 'LOCAL',
    local_song_id = CASE WHEN $(if ($hasLocal) { '1' } else { '0' }) = 1 THEN $localSongLiteral ELSE local_song_id END,
    updated_at = datetime('now'), revision = revision + 1
WHERE id = $(ConvertTo-MusicServerSqlLiteral $TrackId)
  AND EXISTS (
      SELECT 1 FROM wanted_queue q
      WHERE q.track_id = $(ConvertTo-MusicServerSqlLiteral $TrackId)
        AND q.state = 'LOCAL'
        AND q.claimed_by = ''
  );
"@

    try {
        Invoke-ApiAtomicSql -Statements @($queueSql, $canonicalSql) -FailAfterStep $FailAfterStep | Out-Null
    } catch {
        return @{ Success = $false; Reason = 'TRANSACTION_FAILED'; Error = "$($_.Exception.Message)" }
    }

    $updated = Get-WantedItemDb -TrackId $TrackId
    $updatedCanonical = Get-CanonicalTrackDb -TrackId $TrackId
    if ($updated -and [string]$updated.state -eq 'LOCAL' -and
        $updatedCanonical -and [string]$updatedCanonical.status -eq 'LOCAL') {
        return @{
            Success = $true; Revision = [int]$updated.revision
            LocalSongId = [string]$updatedCanonical.local_song_id
        }
    }
    return @{ Success = $false; Reason = 'POST_CHECK_FAILED' }
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
        release_year = [int](Get-OptionalProperty $Row 'release_year' 0)
        created_at = [string]$Row.created_at; updated_at = [string]$Row.updated_at
        revision = [int]$Row.revision
    }
}

# ================================================================
# Daily Recommendations
# ================================================================

function Invoke-StateAtomicSql {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Statements,
        [int]$FailAfterStep = 0
    )

    $sb = New-Object Text.StringBuilder
    [void]$sb.AppendLine('.bail on')
    [void]$sb.AppendLine('BEGIN IMMEDIATE;')
    $step = 0
    foreach ($raw in @($Statements)) {
        if ($null -eq $raw) { continue }
        $stmt = ([string]$raw).Trim()
        if ([string]::IsNullOrWhiteSpace($stmt)) { continue }
        while ($stmt.EndsWith(';')) { $stmt = $stmt.Substring(0, $stmt.Length - 1) }
        $step++
        [void]$sb.AppendLine("$stmt;")
        if ($FailAfterStep -gt 0 -and $step -eq $FailAfterStep) {
            [void]$sb.AppendLine('INSERT INTO ms_injected_state_failure_probe (x) VALUES (1);')
        }
    }
    [void]$sb.AppendLine('COMMIT;')
    Invoke-MusicServerSqliteScript -Sql $sb.ToString() | Out-Null
    return $step
}

function Test-RecommendationPositiveValue {
    param([AllowNull()]$Value)
    if ($Value -is [bool]) { return [bool]$Value }
    if ($null -eq $Value) { return $false }
    return ([string]$Value -match '^(?i:true|1|yes)$')
}

function Convert-RecommendationFeedbackValue {
    param([AllowNull()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    try { return ConvertFrom-Json -InputObject $Value } catch { return $null }
}

function Get-RecommendationFeedbackDb {
    param(
        [string]$TrackId = '',
        [string]$FeedbackType = ''
    )
    $where = @()
    $params = @{}
    if ($TrackId) { $where += 'track_id = @tid'; $params.tid = $TrackId }
    if ($FeedbackType) { $where += 'feedback_type = @ft'; $params.ft = $FeedbackType }
    $predicate = if ($where.Count -gt 0) { ' WHERE ' + ($where -join ' AND ') } else { '' }
    return @(Invoke-MusicServerParamSql -Template ("SELECT * FROM recommendation_feedback$predicate ORDER BY id;" ) -Params $params)
}

function Get-RecommendationSeedCandidatesDb {
    [CmdletBinding()]
    param(
        [int]$SeedCount = 25,
        [AllowEmptyCollection()][object[]]$NavidromeStars = @(),
        [AllowEmptyCollection()][object[]]$LibraryFallback = @(),
        [int]$RandomSeed = -1
    )

    if ($RandomSeed -ge 0) { Get-Random -SetSeed $RandomSeed | Out-Null }
    $signals = @{}
    # Temporal facts must be folded by their event time, not merely by the
    # SQLite insertion id. Legacy migration can append an older LIKE/UNLIKE
    # after a newer API fact already exists in the database.
    $feedback = @(Invoke-MusicServerParamSql -Template 'SELECT * FROM recommendation_feedback ORDER BY created_at ASC, id ASC;' -Params @{})
    $latestExplicit = @{}
    $latestStars = @{}

    foreach ($row in $feedback) {
        $trackId = [string](Get-OptionalProperty $row 'track_id')
        if (-not $trackId) { continue }
        $type = ([string](Get-OptionalProperty $row 'feedback_type')).ToUpperInvariant()
        if ($type -in @('LIKE','UNLIKE')) { $latestExplicit[$trackId] = $row; continue }
        if ($type -eq 'NAVIDROME_STAR') { $latestStars[$trackId] = $row; continue }
        if ($type -notin @('ACCEPTED','LIBRARY_FALLBACK')) { continue }

        $positive = $false
        $valueObject = Convert-RecommendationFeedbackValue -Value ([string](Get-OptionalProperty $row 'value'))
        if ($type -eq 'ACCEPTED' -or $type -eq 'LIBRARY_FALLBACK') {
            $positive = $true
        } else {
            $positive = Test-RecommendationPositiveValue (Get-OptionalProperty $row 'value')
        }
        if (-not $positive) { continue }
        $canonical = Get-CanonicalTrackDb -TrackId $trackId
        $title = if ($canonical) { [string]$canonical.title } elseif ($valueObject) { [string](Get-OptionalProperty $valueObject 'title') } else { '' }
        $artist = if ($canonical) { [string]$canonical.artist } elseif ($valueObject) { [string](Get-OptionalProperty $valueObject 'artist') } else { '' }
        if (-not $title) { continue }
        $weight = if ($type -eq 'ACCEPTED') { 4 } else { 1 }
        $source = if ($type -eq 'ACCEPTED') { 'accepted' } else { 'library_fallback' }
        $key = if ($canonical) { $trackId } else { "text:$(Normalize-MusicText $title)|$(Normalize-MusicText $artist)" }
        if (-not $signals.ContainsKey($key) -or [int]$signals[$key].Weight -lt $weight) {
            $signals[$key] = [pscustomobject]@{ TrackId = $trackId; Title = $title; Artist = $artist; Weight = $weight; Source = $source }
        }
    }

    foreach ($trackId in @($latestExplicit.Keys)) {
        $row = $latestExplicit[$trackId]
        $explicitType = ([string](Get-OptionalProperty $row 'feedback_type')).ToUpperInvariant()
        $explicitValue = [string](Get-OptionalProperty $row 'value')
        $explicitObject = Convert-RecommendationFeedbackValue -Value $explicitValue
        $isPositiveLike = (Test-RecommendationPositiveValue $explicitValue)
        if (-not $isPositiveLike -and $explicitObject) { $isPositiveLike = (Test-RecommendationPositiveValue (Get-OptionalProperty $explicitObject 'positive' $false)) }
        if ($explicitType -ne 'LIKE' -or -not $isPositiveLike) { continue }
        $canonical = Get-CanonicalTrackDb -TrackId $trackId
        $title = if ($canonical) { [string]$canonical.title } elseif ($explicitObject) { [string](Get-OptionalProperty $explicitObject 'title') } else { '' }
        $artist = if ($canonical) { [string]$canonical.artist } elseif ($explicitObject) { [string](Get-OptionalProperty $explicitObject 'artist') } else { '' }
        if (-not $title) { continue }
        $key = $trackId
        $signals[$key] = [pscustomobject]@{ TrackId = $trackId; Title = $title; Artist = $artist; Weight = 5; Source = 'explicit_like' }
    }

    foreach ($trackId in @($latestStars.Keys)) {
        $row = $latestStars[$trackId]
        if (-not (Test-RecommendationPositiveValue (Get-OptionalProperty $row 'value'))) { continue }
        $canonical = Get-CanonicalTrackDb -TrackId $trackId
        if (-not $canonical -or -not $canonical.title) { continue }
        $key = $trackId
        if (-not $signals.ContainsKey($key) -or [int]$signals[$key].Weight -lt 5) {
            $signals[$key] = [pscustomobject]@{ TrackId = $trackId; Title = [string]$canonical.title; Artist = [string]$canonical.artist; Weight = 5; Source = 'navidrome_star' }
        }
    }

    foreach ($star in @($NavidromeStars)) {
        $title = ''; $artist = ''; $trackId = ''
        if ($star -is [string]) {
            $parts = [string]$star -split ' - ', 2
            $title = [string]$parts[0]; if ($parts.Count -gt 1) { $artist = [string]$parts[1] }
        } else {
            $title = [string](Get-OptionalProperty $star 'Title' (Get-OptionalProperty $star 'title'))
            $artist = [string](Get-OptionalProperty $star 'Artist' (Get-OptionalProperty $star 'artist'))
            $trackId = [string](Get-OptionalProperty $star 'TrackId' (Get-OptionalProperty $star 'track_id'))
        }
        if (-not $title) { continue }
        if (-not $trackId) { $trackId = Get-CanonicalTrackId -Title $title -Artist $artist }
        $key = "text:$(Normalize-MusicText $title)|$(Normalize-MusicText $artist)"
        $signals[$key] = [pscustomobject]@{ TrackId = $trackId; Title = $title; Artist = $artist; Weight = 5; Source = 'navidrome_star' }
    }

    # A fresh install has no likes, no stars and no legacy import, so the
    # preference-only pool is empty and the daily generator would save zero
    # recommendations every day. The local library is the weakest signal and is
    # only consulted when nothing stronger exists, so it cannot dilute a pool
    # that already reflects the user's taste.
    if ($signals.Count -eq 0) {
        foreach ($fallback in @($LibraryFallback)) {
            $title = ''; $artist = ''; $trackId = ''
            if ($fallback -is [string]) {
                $parts = [string]$fallback -split ' - ', 2
                $title = [string]$parts[0]; if ($parts.Count -gt 1) { $artist = [string]$parts[1] }
            } else {
                $title = [string](Get-OptionalProperty $fallback 'Title' (Get-OptionalProperty $fallback 'title'))
                $artist = [string](Get-OptionalProperty $fallback 'Artist' (Get-OptionalProperty $fallback 'artist'))
                $trackId = [string](Get-OptionalProperty $fallback 'TrackId' (Get-OptionalProperty $fallback 'track_id'))
            }
            if (-not $title) { continue }
            if (-not $trackId) { $trackId = Get-CanonicalTrackId -Title $title -Artist $artist }
            $key = "text:$(Normalize-MusicText $title)|$(Normalize-MusicText $artist)"
            if ($signals.ContainsKey($key)) { continue }
            $signals[$key] = [pscustomobject]@{ TrackId = $trackId; Title = $title; Artist = $artist; Weight = 1; Source = 'library_fallback' }
        }
    }

    $expanded = foreach ($seed in @($signals.Values)) {
        for ($i = 0; $i -lt [Math]::Max(1, [int]$seed.Weight); $i++) { $seed }
    }
    $picked = @(); $artists = @{}
    foreach ($seed in @($expanded | Sort-Object { Get-Random })) {
        if (-not $seed.Title) { continue }
        $artistKey = Normalize-MusicText (([string]$seed.Artist -split '[,，、]')[0])
        if ($artistKey -and $artists.ContainsKey($artistKey) -and $artists[$artistKey] -ge 3) { continue }
        if (@($picked | Where-Object { (Normalize-MusicText $_.Title) -eq (Normalize-MusicText $seed.Title) -and (Normalize-MusicText $_.Artist) -eq (Normalize-MusicText $seed.Artist) }).Count -gt 0) { continue }
        $picked += $seed
        if ($artistKey) { if ($artists.ContainsKey($artistKey)) { $artists[$artistKey]++ } else { $artists[$artistKey] = 1 } }
        if ($picked.Count -ge $SeedCount) { break }
    }
    return @($picked)
}

# ================================================================
# Local-library recommendations
# ================================================================
#
# NetEase drives discovery, which means every recommended track is one the user
# does not own yet. This second source answers the opposite question: which of the
# tracks already in the library does this listener most likely want to hear again?
# It is deliberately preference-led rather than library-led -- a recommendation
# only exists when the listener has shown interest in that artist, so a large
# untouched library cannot turn the day into an arbitrary dump of its own files.

function Get-LocalArtistAffinity {
    <#
    .SYNOPSIS
      Artist -> interest weight, from listening history and explicit positives.

      Explicit taste (a like, a star, an accepted download) outranks incidental
      play counts, and repeated plays add to the weight with a cap so one looped
      track cannot dominate the whole day.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][object[]]$ListeningStats = @(),
        [AllowEmptyCollection()][object[]]$PositiveTracks = @(),
        [int]$MaxPlayWeight = 5
    )

    $affinity = @{}
    $bump = {
        param([string]$Artist, [int]$Weight)
        foreach ($name in @(Split-LocalArtistNames -Artist $Artist)) {
            $key = Normalize-MusicText $name
            if (-not $key) { continue }
            if ($affinity.ContainsKey($key)) { $affinity[$key] = $affinity[$key] + $Weight } else { $affinity[$key] = $Weight }
        }
    }

    # Explicit positives are the strongest signal the product records.
    foreach ($track in @($PositiveTracks)) {
        $artist = [string](Get-OptionalProperty $track 'Artist' (Get-OptionalProperty $track 'artist'))
        if ($artist) { & $bump $artist 6 }
    }

    foreach ($row in @($ListeningStats)) {
        $plays = [int](Get-OptionalProperty $row 'play_count' 0)
        if ($plays -le 0) { continue }
        $artist = [string](Get-OptionalProperty $row 'artist' (Get-OptionalProperty $row 'Artist'))
        if (-not $artist) { continue }
        $weight = [Math]::Min($plays, [Math]::Max(1, $MaxPlayWeight)) * 2
        & $bump $artist $weight
    }

    return $affinity
}

function Split-LocalArtistNames {
    <#
    .SYNOPSIS
      Individual artist names from a credit string.
    #>
    param([AllowEmptyString()][string]$Artist)
    if ([string]::IsNullOrWhiteSpace($Artist)) { return @() }
    return @($Artist -split '[,，、/&;；]|\s+feat\.?\s+|\s+ft\.?\s+|\s+×\s+' |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_.Length -ge 2 })
}

function Select-LocalRecommendationTracks {
    <#
    .SYNOPSIS
      Owned tracks to surface today, ranked by how much the listener likes the artist.

      Ordering is least-recently-played first inside each affinity tier: a track the
      listener has never touched beats one they played last week, and both beat the
      one still ringing in their ears. Everything already recommended, accepted or
      cooled down is excluded by the caller's key set, so the caller keeps a single
      definition of what must not repeat.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][object[]]$Candidates = @(),
        [Parameter(Mandatory)][hashtable]$Affinity = @{},
        [AllowEmptyCollection()][string[]]$ExcludedKeys = @(),
        [int]$Limit = 6,
        [double]$RecentlyPlayedDays = 14
    )

    if ($Limit -le 0) { return @() }
    # Keys must be normalized on BOTH sides. Comparing a normalized lookup against
    # raw keys silently failed for anything normalization rewrites -- a track id or
    # library id containing a hyphen or separator was never excluded.
    $excluded = @{}
    $excludedArtists = @{}
    foreach ($key in @($ExcludedKeys)) {
        $text = [string]$key
        if (-not $text) { continue }
        if ($text.StartsWith('artist:')) {
            $name = Normalize-MusicText $text.Substring('artist:'.Length)
            if ($name) { $excludedArtists[$name] = $true }
            continue
        }
        $normalized = Normalize-MusicText $text
        if ($normalized) { $excluded[$normalized] = $true }
    }

    $cutoff = [DateTime]::UtcNow.AddDays(-1 * [Math]::Abs($RecentlyPlayedDays))
    $scored = New-Object System.Collections.ArrayList
    foreach ($candidate in @($Candidates)) {
        $artist = [string](Get-OptionalProperty $candidate 'Artist' (Get-OptionalProperty $candidate 'artist'))
        $artistKey = ''
        $best = 0
        foreach ($name in @(Split-LocalArtistNames -Artist $artist)) {
            $key = Normalize-MusicText $name
            if ($key -and $Affinity.ContainsKey($key) -and [int]$Affinity[$key] -gt $best) {
                $best = [int]$Affinity[$key]
                $artistKey = $name
            }
        }
        # No demonstrated interest in this artist: the library alone is not a taste
        # signal, so the track is not recommended.
        if ($best -le 0) { continue }

        $file = [string](Get-OptionalProperty $candidate 'File' (Get-OptionalProperty $candidate 'file'))
        $title = [string](Get-OptionalProperty $candidate 'Title' (Get-OptionalProperty $candidate 'title'))
        $trackId = [string](Get-OptionalProperty $candidate 'TrackId' (Get-OptionalProperty $candidate 'track_id'))
        $libraryId = [string](Get-OptionalProperty $candidate 'LibraryId' (Get-OptionalProperty $candidate 'library_id'))
        # A track with no library id cannot be streamed: playback resolves through
        # the index, so a file that is on disk but absent from it would be
        # recommended as something the user cannot actually play.
        if (-not $libraryId) { continue }
        $blocked = $false
        foreach ($key in @($title, $artist, $libraryId, $trackId)) {
            if (-not $key) { continue }
            if ($excluded.ContainsKey((Normalize-MusicText $key))) { $blocked = $true; break }
        }
        if ($blocked) { continue }
        if ($artistKey -and $excludedArtists.ContainsKey((Normalize-MusicText $artistKey))) { continue }

        $lastPlayed = Get-OptionalProperty $candidate 'LastPlayedAt' (Get-OptionalProperty $candidate 'last_played_at')
        $playedAt = Convert-ToUtcDateTime $lastPlayed
        if ($playedAt -and $playedAt -gt $cutoff) { continue }


        [void]$scored.Add([pscustomobject]@{
            Title = $title; Artist = $artist; File = $file; LibraryId = $libraryId
            TrackId = $trackId; AffinityArtist = $artistKey; Weight = $best
            LastPlayedAt = $lastPlayed
        })
    }

    # Deterministic: affinity, then never-played before old, then title.
    $ordered = @($scored | Sort-Object `
        @{ Expression = { [int]$_.Weight }; Descending = $true }, `
        @{ Expression = { if ($_.LastPlayedAt) { 1 } else { 0 } }; Descending = $false }, `
        @{ Expression = { [string]$_.LastPlayedAt }; Descending = $false }, `
        @{ Expression = { [string]$_.Title }; Descending = $false })

    # One track per artist per day keeps the list varied instead of returning five
    # songs by whichever artist the listener happens to loop most.
    $picked = New-Object System.Collections.ArrayList
    $usedArtists = @{}
    foreach ($row in $ordered) {
        $key = Normalize-MusicText ([string]$row.AffinityArtist)
        if ($key -and $usedArtists.ContainsKey($key)) { continue }
        if ($key) { $usedArtists[$key] = $true }
        [void]$picked.Add($row)
        if ($picked.Count -ge $Limit) { break }
    }
    return @($picked)
}

function Get-RecommendationCooldownTrackIdsDb {
    param(
        [string]$AsOfDate = (Get-TodayDate),
        [int]$CooldownDays = 14
    )
    $asOf = [DateTime]::ParseExact($AsOfDate, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    $cutoff = $asOf.AddDays(-$CooldownDays).ToString('yyyy-MM-dd')
    return @(Invoke-MusicServerParamSql -Template @"
SELECT DISTINCT track_id, netease_id, date, rank, rec_id
FROM daily_recommendations
WHERE date >= @cutoff AND date <= @asof
ORDER BY date, rank;
"@ -Params @{ cutoff = $cutoff; asof = $AsOfDate })
}

function Get-RecommendationExcludedKeysDb {
    $rows = @(Invoke-MusicServerParamSql -Template "SELECT track_id, feedback_type, value FROM recommendation_feedback WHERE feedback_type IN ('ACCEPTED','REJECTED') ORDER BY id;" -Params @{})
    $result = @()
    foreach ($row in $rows) {
        $valueObject = Convert-RecommendationFeedbackValue -Value ([string](Get-OptionalProperty $row 'value'))
        $result += [pscustomobject]@{
            TrackId = [string](Get-OptionalProperty $row 'track_id')
            NeteaseId = if ($valueObject) { [string](Get-OptionalProperty $valueObject 'netease_id' (Get-OptionalProperty $valueObject 'NeteaseId')) } else { '' }
            Title = if ($valueObject) { [string](Get-OptionalProperty $valueObject 'title' (Get-OptionalProperty $valueObject 'Title')) } else { '' }
            FeedbackType = [string](Get-OptionalProperty $row 'feedback_type')
        }
    }
    return @($result)
}

# ================================================================
# Dislike ("讨厌")
# ================================================================
#
# Disliking is a statement about what to RECOMMEND, not about what to keep, so it
# is deliberately preference-only: unlike LIKE it never queues a download, and
# unlike UNLIKE it never cancels or deletes anything. It records feedback plus an
# audit event, and the generator turns it into a reduced weight. "少推荐" is a soft
# penalty, not an exclusion -- a disliked track sinks below fresh candidates but
# can still surface when there is nothing better, which is what the user asked for.

function Write-TrackDislikeDb {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TrackId,
        [AllowEmptyString()][string]$Title = '',
        [AllowEmptyString()][string]$Artist = '',
        [AllowEmptyString()][string]$NeteaseId = '',
        [string]$Source = 'music_api'
    )

    $value = ConvertTo-Json -InputObject ([ordered]@{
        title = $Title; artist = $Artist; netease_id = $NeteaseId; positive = $false
    }) -Compress
    $now = Get-NowIso
    $lit = @{
        tid = ConvertTo-MusicServerSqlLiteral $TrackId
        src = ConvertTo-MusicServerSqlLiteral $Source
        val = ConvertTo-MusicServerSqlLiteral $value
        now = ConvertTo-MusicServerSqlLiteral $now
        msg = ConvertTo-MusicServerSqlLiteral "dislike; title=$Title; artist=$Artist"
    }
    $statements = @(
        # Order matters. Like and dislike are one axis, so disliking also records
        # the UNLIKE that turns the heart off; both rows share a timestamp, so the
        # fold in Get-TrackPreferenceMapDb breaks the tie on id and DISLIKE must be
        # written last to win. Preference-only: this does not cancel a download or
        # touch a file the way a real UNLIKE does.
        "INSERT INTO recommendation_feedback (track_id, feedback_type, source, value, created_at) VALUES ($($lit.tid), 'UNLIKE', $($lit.src), 'false', $($lit.now))"
        "INSERT INTO recommendation_feedback (track_id, feedback_type, source, value, created_at) VALUES ($($lit.tid), 'DISLIKE', $($lit.src), $($lit.val), $($lit.now))"
        "INSERT INTO events (event_type, track_id, provider, from_state, to_state, attempt, duration_ms, result, error_type, http_status, message, created_at) VALUES ('TRACK_DISLIKED', $($lit.tid), '', '', '', 0, 0.0, 'SUCCESS', '', 0, $($lit.msg), $($lit.now))"
    )
    $steps = Invoke-StateAtomicSql -Statements $statements
    return [pscustomobject]@{ track_id = $TrackId; disliked = $true; steps = $steps }
}

function Write-TrackUndislikeDb {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TrackId,
        [string]$Source = 'music_api'
    )

    $now = Get-NowIso
    $lit = @{
        tid = ConvertTo-MusicServerSqlLiteral $TrackId
        src = ConvertTo-MusicServerSqlLiteral $Source
        now = ConvertTo-MusicServerSqlLiteral $now
    }
    $statements = @(
        "INSERT INTO recommendation_feedback (track_id, feedback_type, source, value, created_at) VALUES ($($lit.tid), 'UNDISLIKE', $($lit.src), 'false', $($lit.now))"
        "INSERT INTO events (event_type, track_id, provider, from_state, to_state, attempt, duration_ms, result, error_type, http_status, message, created_at) VALUES ('TRACK_UNDISLIKED', $($lit.tid), '', '', '', 0, 0.0, 'SUCCESS', '', 0, 'undislike', $($lit.now))"
    )
    $steps = Invoke-StateAtomicSql -Statements $statements
    return [pscustomobject]@{ track_id = $TrackId; disliked = $false; steps = $steps }
}

function Get-TrackPreferenceMapDb {
    <#
    .SYNOPSIS
      Effective like/dislike state per track: 'LIKE', 'DISLIKE', or absent.

      Like and dislike are one axis, so the most recent action wins and the other
      side is cleared -- a track liked last week and disliked today is disliked.
      Folding is ordered by (created_at, id) exactly like the seed pool, because
      legacy migration can append an older fact after a newer one.
    #>
    [CmdletBinding()]
    param()

    $map = @{}
    $rows = @(Invoke-MusicServerParamSql -Template "SELECT track_id, feedback_type, created_at, id FROM recommendation_feedback WHERE feedback_type IN ('LIKE','UNLIKE','DISLIKE','UNDISLIKE') ORDER BY created_at ASC, id ASC;" -Params @{})
    foreach ($row in $rows) {
        $trackId = [string](Get-OptionalProperty $row 'track_id')
        if (-not $trackId) { continue }
        $type = ([string](Get-OptionalProperty $row 'feedback_type')).ToUpperInvariant()
        switch ($type) {
            'LIKE' { $map[$trackId] = 'LIKE' }
            'DISLIKE' { $map[$trackId] = 'DISLIKE' }
            default { [void]$map.Remove($trackId) }
        }
    }
    return $map
}

function Get-LatestTrackPreferenceDb {
    <#
    .SYNOPSIS
      Effective state for one track: 'LIKE', 'DISLIKE', or '' when neutral.

      Targeted rather than folded over the whole table, because this runs on every
      track response.
    #>
    param([Parameter(Mandatory)][string]$TrackId)
    $rows = @(Invoke-MusicServerParamSql -Template "SELECT feedback_type FROM recommendation_feedback WHERE track_id = @tid AND feedback_type IN ('LIKE','UNLIKE','DISLIKE','UNDISLIKE') ORDER BY created_at DESC, id DESC LIMIT 1;" -Params @{ tid = $TrackId })
    if ($rows.Count -eq 0) { return '' }
    $type = ([string](Get-OptionalProperty $rows[0] 'feedback_type')).ToUpperInvariant()
    if ($type -eq 'LIKE') { return 'LIKE' }
    if ($type -eq 'DISLIKE') { return 'DISLIKE' }
    return ''
}

function Get-DislikedTrackKeysDb {
    <#
    .SYNOPSIS
      Every currently disliked track, with the keys a candidate can be matched on.

      The identifying fields are read back from the feedback value written at
      dislike time and backfilled from the canonical track, so a candidate can be
      recognised by NetEase id, canonical track id, or normalized title+artist
      even when the same song arrives from a different seed.
    #>
    [CmdletBinding()]
    param()

    $preference = Get-TrackPreferenceMapDb
    $values = @{}
    foreach ($row in @(Invoke-MusicServerParamSql -Template "SELECT track_id, value, created_at, id FROM recommendation_feedback WHERE feedback_type = 'DISLIKE' ORDER BY created_at ASC, id ASC;" -Params @{})) {
        $trackId = [string](Get-OptionalProperty $row 'track_id')
        if ($trackId) { $values[$trackId] = [string](Get-OptionalProperty $row 'value') }
    }

    $result = @()
    foreach ($trackId in @($preference.Keys)) {
        if ([string]$preference[$trackId] -ne 'DISLIKE') { continue }
        $title = ''; $artist = ''; $neteaseId = ''
        if ($values.ContainsKey($trackId)) {
            $valueObject = Convert-RecommendationFeedbackValue -Value ([string]$values[$trackId])
            if ($valueObject) {
                $title = [string](Get-OptionalProperty $valueObject 'title' (Get-OptionalProperty $valueObject 'Title'))
                $artist = [string](Get-OptionalProperty $valueObject 'artist' (Get-OptionalProperty $valueObject 'Artist'))
                $neteaseId = [string](Get-OptionalProperty $valueObject 'netease_id' (Get-OptionalProperty $valueObject 'NeteaseId'))
            }
        }
        $canonical = Get-CanonicalTrackDb -TrackId $trackId
        if ($canonical) {
            if (-not $title) { $title = [string]$canonical.title }
            if (-not $artist) { $artist = [string]$canonical.artist }
        }
        $result += [pscustomobject]@{
            TrackId = $trackId; Title = $title; Artist = $artist; NeteaseId = $neteaseId
        }
    }
    return @($result)
}

function Test-CandidateDisliked {
    <#
    .SYNOPSIS
      Whether a recommendation candidate is one the listener marked as disliked.

      Matching uses every key a candidate can be recognised by, because the same
      song reaches the pool from different seeds and recordings: the NetEase id,
      the canonical track id, the normalized song name, and the normalized
      song+artist pair.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$Title = '',
        [AllowEmptyString()][string]$Artist = '',
        [AllowEmptyString()][string]$NeteaseId = '',
        [AllowEmptyString()][string]$TrackId = '',
        [Parameter(Mandatory)][hashtable]$PenaltyKeys = @{}
    )

    if ($PenaltyKeys.Count -eq 0) { return $false }
    if ($NeteaseId -and $PenaltyKeys.ContainsKey("netease:$NeteaseId")) { return $true }
    if ($TrackId -and $PenaltyKeys.ContainsKey($TrackId)) { return $true }
    if ($Title) {
        if ($PenaltyKeys.ContainsKey((Normalize-MusicText $Title))) { return $true }
        if ($Artist -and $PenaltyKeys.ContainsKey((Normalize-MusicText "$Title$Artist"))) { return $true }
        if ($PenaltyKeys.ContainsKey([string](Get-CanonicalTrackId -Title $Title -Artist $Artist))) { return $true }
    }
    return $false
}

function Get-DislikePenaltyKeys {
    <#
    .SYNOPSIS
      Normalized key set used to recognise a disliked track in a candidate list.

      Normalizing on BOTH sides matters: comparing a normalized lookup against raw
      keys silently fails for any key that normalization rewrites.
    #>
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Disliked = @())

    $keys = @{}
    foreach ($row in @($Disliked)) {
        $trackId = [string](Get-OptionalProperty $row 'TrackId' (Get-OptionalProperty $row 'track_id'))
        $neteaseId = [string](Get-OptionalProperty $row 'NeteaseId' (Get-OptionalProperty $row 'netease_id'))
        $title = [string](Get-OptionalProperty $row 'Title' (Get-OptionalProperty $row 'title'))
        $artist = [string](Get-OptionalProperty $row 'Artist' (Get-OptionalProperty $row 'artist'))
        if ($trackId) { $keys[[string]$trackId] = $true }
        if ($neteaseId) { $keys["netease:$neteaseId"] = $true }
        if ($title) {
            $keys[(Normalize-MusicText $title)] = $true
            if ($artist) { $keys[(Normalize-MusicText "$title$artist")] = $true }
        }
    }
    return $keys
}

function Write-RecommendationDisplayFeedbackDb {
    param(
        [Parameter(Mandatory)][string]$TrackId,
        [Parameter(Mandatory)][string]$Date,
        [int]$Rank = 0,
        [string]$RecommendationId = '',
        [string]$Source = 'daily_recommendation'
    )
    $value = "display:$Date`:$Rank`:$RecommendationId"
    Invoke-MusicServerParamNonQuery -Template @"
INSERT INTO recommendation_feedback (track_id, feedback_type, source, value, created_at)
SELECT @tid, 'DISPLAY', @src, @val, @now
WHERE NOT EXISTS (
    SELECT 1 FROM recommendation_feedback
    WHERE track_id = @tid AND feedback_type = 'DISPLAY' AND source = @src AND value = @val
);
"@ -Params @{ tid = $TrackId; src = $Source; val = $value; now = (Get-NowIso) }
}

function Save-DailyRecommendationsDb {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][object[]]$Recommendations = @(),
        [AllowEmptyCollection()][object[]]$Tracks = @(),
        [string]$Date = (Get-TodayDate),
        [switch]$DryRun,
        [int]$FailAfterStep = 0
    )
    if ($DryRun) { return [pscustomobject]@{ Date = $Date; Count = @($Recommendations).Count; DryRun = $true } }

    $recs = @($Recommendations)
    $rankSet = New-Object System.Collections.Generic.HashSet[int]
    foreach ($rec in $recs) {
        $rank = [int](Get-OptionalProperty $rec 'rank' 0)
        if ($rank -le 0 -or -not $rankSet.Add($rank)) { throw "Duplicate or invalid recommendation rank: $rank" }
    }
    $trackMap = @{}
    foreach ($track in @($Tracks)) {
        $trackId = [string](Get-OptionalProperty $track 'id' (Get-OptionalProperty $track 'track_id'))
        if ($trackId) { $trackMap[$trackId] = $track }
    }
    foreach ($rec in $recs) {
        $trackId = [string](Get-OptionalProperty $rec 'track_id')
        if (-not $trackId) { throw 'Recommendation track_id is required.' }
        if (-not $trackMap.ContainsKey($trackId)) {
            $trackMap[$trackId] = [pscustomobject]@{
                id = $trackId; title = [string](Get-OptionalProperty $rec 'title'); artist = [string](Get-OptionalProperty $rec 'artist')
                album = [string](Get-OptionalProperty $rec 'album'); duration = [int](Get-OptionalProperty $rec 'duration' 0); cover_url = ''
                identifiers = @(); preview_sources = @(Get-OptionalProperty $rec 'preview_sources' @()); download_candidates = @()
                local_song_id = ''; status = 'REMOTE'; created_at = [string](Get-OptionalProperty $rec 'created_at' (Get-NowIso)); updated_at = [string](Get-OptionalProperty $rec 'updated_at' (Get-NowIso))
            }
        }
    }

    $now = Get-NowIso
    $statements = New-Object System.Collections.Generic.List[string]
    [void]$statements.Add(("DELETE FROM daily_recommendations WHERE date = " + (ConvertTo-MusicServerSqlLiteral $Date)))
    [void]$statements.Add(("DELETE FROM recommendation_feedback WHERE feedback_type = 'DISPLAY' AND source = 'daily_recommendation' AND value LIKE " + (ConvertTo-MusicServerSqlLiteral "display:${Date}:%")))
    [void]$statements.Add(("DELETE FROM events WHERE event_type = 'RECOMMENDATION_DISPLAY' AND message LIKE " + (ConvertTo-MusicServerSqlLiteral "date=${Date};rank=%")))
    foreach ($track in @($trackMap.Values)) {
        $trackId = [string](Get-OptionalProperty $track 'id')
        $identifiers = ConvertTo-Json -InputObject @(Get-OptionalProperty $track 'identifiers' @()) -Compress -Depth 10
        $preview = ConvertTo-Json -InputObject @(Get-OptionalProperty $track 'preview_sources' @()) -Compress -Depth 10
        $candidates = ConvertTo-Json -InputObject @(Get-OptionalProperty $track 'download_candidates' @()) -Compress -Depth 10
        $lit = @{
            id = ConvertTo-MusicServerSqlLiteral $trackId; title = ConvertTo-MusicServerSqlLiteral ([string](Get-OptionalProperty $track 'title'))
            artist = ConvertTo-MusicServerSqlLiteral ([string](Get-OptionalProperty $track 'artist')); album = ConvertTo-MusicServerSqlLiteral ([string](Get-OptionalProperty $track 'album'))
            dur = ConvertTo-MusicServerSqlLiteral ([int](Get-OptionalProperty $track 'duration' 0)); cover = ConvertTo-MusicServerSqlLiteral ([string](Get-OptionalProperty $track 'cover_url'))
            ident = ConvertTo-MusicServerSqlLiteral $identifiers; prev = ConvertTo-MusicServerSqlLiteral $preview; cand = ConvertTo-MusicServerSqlLiteral $candidates
            local = ConvertTo-MusicServerSqlLiteral ([string](Get-OptionalProperty $track 'local_song_id')); status = ConvertTo-MusicServerSqlLiteral ([string](Get-OptionalProperty $track 'status' 'REMOTE'))
            created = ConvertTo-MusicServerSqlLiteral ([string](Get-OptionalProperty $track 'created_at' $now)); updated = ConvertTo-MusicServerSqlLiteral $now
            year = ConvertTo-MusicServerSqlLiteral ([int](Get-OptionalProperty $track 'release_year' 0))
        }
        [void]$statements.Add("INSERT INTO canonical_tracks (id,title,artist,album,duration,cover_url,identifiers_json,preview_sources_json,download_candidates_json,local_song_id,status,release_year,created_at,updated_at,revision) VALUES ($($lit.id),$($lit.title),$($lit.artist),$($lit.album),$($lit.dur),$($lit.cover),$($lit.ident),$($lit.prev),$($lit.cand),$($lit.local),$($lit.status),$($lit.year),$($lit.created),$($lit.updated),1) ON CONFLICT(id) DO UPDATE SET title=excluded.title, artist=excluded.artist, album=excluded.album, duration=excluded.duration, cover_url=excluded.cover_url, identifiers_json=excluded.identifiers_json, preview_sources_json=excluded.preview_sources_json, download_candidates_json=excluded.download_candidates_json, local_song_id=CASE WHEN canonical_tracks.local_song_id IS NULL OR canonical_tracks.local_song_id='' THEN excluded.local_song_id ELSE canonical_tracks.local_song_id END, status=CASE WHEN canonical_tracks.status='REMOTE' THEN excluded.status ELSE canonical_tracks.status END, release_year=CASE WHEN excluded.release_year > 0 THEN excluded.release_year ELSE canonical_tracks.release_year END, created_at=canonical_tracks.created_at, updated_at=excluded.updated_at, revision=canonical_tracks.revision")
    }
    foreach ($rec in @($recs | Sort-Object { [int](Get-OptionalProperty $_ 'rank') })) {
        $preview = ConvertTo-Json -InputObject @(Get-OptionalProperty $rec 'preview_sources' @()) -Compress -Depth 10
        $lit = @{
            d = ConvertTo-MusicServerSqlLiteral $Date; r = ConvertTo-MusicServerSqlLiteral ([int](Get-OptionalProperty $rec 'rank')); rid = ConvertTo-MusicServerSqlLiteral ([string](Get-OptionalProperty $rec 'id'))
            tid = ConvertTo-MusicServerSqlLiteral ([string](Get-OptionalProperty $rec 'track_id')); nid = ConvertTo-MusicServerSqlLiteral ([string](Get-OptionalProperty $rec 'netease_id'))
            title = ConvertTo-MusicServerSqlLiteral ([string](Get-OptionalProperty $rec 'title')); artist = ConvertTo-MusicServerSqlLiteral ([string](Get-OptionalProperty $rec 'artist')); album = ConvertTo-MusicServerSqlLiteral ([string](Get-OptionalProperty $rec 'album'))
            dur = ConvertTo-MusicServerSqlLiteral ([int](Get-OptionalProperty $rec 'duration' 0)); reason = ConvertTo-MusicServerSqlLiteral ([string](Get-OptionalProperty $rec 'reason')); ss = ConvertTo-MusicServerSqlLiteral ([string](Get-OptionalProperty $rec 'seed_source')); ps = ConvertTo-MusicServerSqlLiteral ([string](Get-OptionalProperty $rec 'playback_source')); prev = ConvertTo-MusicServerSqlLiteral $preview; now = ConvertTo-MusicServerSqlLiteral $now
        }
        [void]$statements.Add("INSERT INTO daily_recommendations (date,rank,rec_id,track_id,netease_id,title,artist,album,duration,reason,seed_source,playback_source,preview_sources_json,liked,created_at,updated_at) VALUES ($($lit.d),$($lit.r),$($lit.rid),$($lit.tid),$($lit.nid),$($lit.title),$($lit.artist),$($lit.album),$($lit.dur),$($lit.reason),$($lit.ss),$($lit.ps),$($lit.prev),0,$($lit.now),$($lit.now))")
        $displayValue = "display:$Date`:$([int](Get-OptionalProperty $rec 'rank'))`:$([string](Get-OptionalProperty $rec 'id'))"
        [void]$statements.Add("INSERT INTO recommendation_feedback (track_id,feedback_type,source,value,created_at) VALUES ($($lit.tid),'DISPLAY','daily_recommendation',$(ConvertTo-MusicServerSqlLiteral $displayValue),$($lit.now))")
        $displayMessage = "date=${Date};rank=$([int](Get-OptionalProperty $rec 'rank'));rec_id=$([string](Get-OptionalProperty $rec 'id'))"
        [void]$statements.Add("INSERT INTO events (event_type,track_id,result,message,created_at) VALUES ('RECOMMENDATION_DISPLAY',$($lit.tid),'SUCCESS',$(ConvertTo-MusicServerSqlLiteral $displayMessage),$($lit.now))")
    }
    $steps = Invoke-StateAtomicSql -Statements $statements.ToArray() -FailAfterStep $FailAfterStep
    return [pscustomobject]@{ Date = $Date; Count = $recs.Count; Steps = $steps; DryRun = $false }
}

function Get-TodayRecommendationsDb {
    param([string]$Date = (Get-TodayDate))
    $rows = @(Invoke-MusicServerParamSql -Template 'SELECT * FROM daily_recommendations WHERE date = @d ORDER BY rank;' -Params @{ d = $Date })
    return @($rows | ForEach-Object { Convert-DbRecRow -Row $_ })
}

# Four bounded reads regardless of recommendation count. Use the existing row
# converters so JSON fields, missing wanted items and feedback semantics agree
# with the single-track endpoints. As before, writes may occur between reads.
function Get-TodayRecommendationBatchDb {
    param([string]$Date = (Get-TodayDate))
    $recs = @(Get-TodayRecommendationsDb -Date $Date)
    if (-not $recs.Count) { return @() }
    $tracks = @{}
    foreach ($row in @(Invoke-MusicServerParamSql -Template 'SELECT c.* FROM canonical_tracks c WHERE c.id IN (SELECT track_id FROM daily_recommendations WHERE date = @d);' -Params @{ d = $Date })) {
        $tracks[[string]$row.id] = Convert-DbTrackRow -Row $row
    }
    $wanted = @{}
    foreach ($row in @(Invoke-MusicServerParamSql -Template 'SELECT w.* FROM wanted_queue w WHERE w.track_id IN (SELECT track_id FROM daily_recommendations WHERE date = @d);' -Params @{ d = $Date })) {
        $wanted[[string]$row.track_id] = Convert-DbWantedRow -Row $row
    }
    $feedback = @{}
    foreach ($row in @(Invoke-MusicServerParamSql -Template "SELECT DISTINCT r.track_id, (SELECT feedback_type FROM recommendation_feedback f WHERE f.track_id = r.track_id AND feedback_type IN ('LIKE','UNLIKE') ORDER BY created_at DESC, id DESC LIMIT 1) AS feedback_type FROM daily_recommendations r WHERE date = @d;" -Params @{ d = $Date })) {
        $feedback[[string]$row.track_id] = [string]$row.feedback_type
    }
    return @(foreach ($rec in $recs) {
        $id = [string]$rec.track_id
        if ($tracks.ContainsKey($id)) {
            [pscustomobject]@{ Recommendation = $rec; Track = $tracks[$id]; Wanted = $wanted[$id]; Feedback = $feedback[$id] }
        }
    })
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

function Write-FeedbackIfAbsentDb {
    param(
        [Parameter(Mandatory)][string]$TrackId,
        [Parameter(Mandatory)][string]$FeedbackType,
        [string]$Source = '', [string]$Value = '', [string]$CreatedAt = ''
    )
    if (-not $CreatedAt) { $CreatedAt = Get-NowIso }
    $existing = @(Invoke-MusicServerParamSql -Template @"
SELECT id FROM recommendation_feedback
WHERE track_id = @tid AND feedback_type = @ft AND source = @src AND value = @val
LIMIT 1;
"@ -Params @{ tid = $TrackId; ft = $FeedbackType; src = $Source; val = $Value })
    if ($existing.Count -gt 0) { return $false }
    [void](Invoke-MusicServerParamNonQuery -Template @"
INSERT INTO recommendation_feedback (track_id, feedback_type, source, value, created_at)
VALUES (@tid, @ft, @src, @val, @created);
"@ -Params @{ tid = $TrackId; ft = $FeedbackType; src = $Source; val = $Value; created = $CreatedAt })
    return $true
}

function Save-RecommendationFileDb {
    param(
        [Parameter(Mandatory)][string]$FileName,
        [string]$TrackId = '', [string]$Date = '', [string]$NeteaseId = '',
        [string]$Title = '', [string]$Artist = '', [string]$Album = '',
        [int]$Duration = 0, [string]$SeedSource = '', [string]$CreatedAt = ''
    )
    if (-not $CreatedAt) { $CreatedAt = Get-NowIso }
    Invoke-MusicServerParamNonQuery -Template @"
INSERT INTO recommendation_files
    (file_name, track_id, date, netease_id, title, artist, album, duration, seed_source, created_at, updated_at)
VALUES (@file, @tid, @date, @nid, @title, @artist, @album, @duration, @seed, @created, @created)
ON CONFLICT(file_name) DO UPDATE SET
    track_id = excluded.track_id, date = excluded.date, netease_id = excluded.netease_id,
    title = excluded.title, artist = excluded.artist, album = excluded.album,
    duration = excluded.duration, seed_source = excluded.seed_source, updated_at = excluded.updated_at;
"@ -Params @{
        file = $FileName; tid = $TrackId; date = $Date; nid = $NeteaseId; title = $Title
        artist = $Artist; album = $Album; duration = $Duration; seed = $SeedSource
        created = $CreatedAt
    }
    return (Get-RecommendationFileDb -FileName $FileName)
}

function Get-RecommendationFileDb {
    param([Parameter(Mandatory)][string]$FileName)
    $rows = @(Invoke-MusicServerParamSql -Template 'SELECT * FROM recommendation_files WHERE file_name = @file LIMIT 1;' -Params @{ file = $FileName })
    if ($rows.Count -eq 0) { return $null }
    return $rows[0]
}

function Get-RecommendationFilesDb {
    return @(Invoke-MusicServerSqlJson -Query 'SELECT * FROM recommendation_files ORDER BY date, file_name;')
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
        id = [string]$Row.wanted_id
        state = [string]$Row.state; attempt_count = [int]$Row.attempt_count
        attempts = [int]$Row.attempt_count
        max_attempts = [int]$Row.max_attempts; next_retry_at = [string]$Row.next_retry_at
        selected_candidate = $selected; last_error = [string]$Row.last_error
        claimed_by = [string]$Row.claimed_by; claimed_at = [string]$Row.claimed_at
        lease_expires_at = [string]$Row.lease_expires_at
        lease_expires_epoch = if ($null -eq $Row.lease_expires_epoch) { $null } else { [long]$Row.lease_expires_epoch }
        revision = [int]$Row.revision
        created_at = [string]$Row.created_at; updated_at = [string]$Row.updated_at
        title = if ($Row.PSObject.Properties['track_title']) { [string]$Row.track_title } else { '' }
        artist = if ($Row.PSObject.Properties['track_artist']) { [string]$Row.track_artist } else { '' }
        duration = if ($Row.PSObject.Properties['track_duration']) { [int]$Row.track_duration } else { 0 }
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
        # Join the canonical row so the UI can render queue entries that are no
        # longer part of today's recommendation list.
        $rows = @(Invoke-MusicServerSqlJson -Query 'SELECT w.*, c.title AS track_title, c.artist AS track_artist, c.duration AS track_duration, c.status AS track_status FROM wanted_queue w LEFT JOIN canonical_tracks c ON c.id = w.track_id ORDER BY w.created_at;')
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
    $nowInstant = [DateTimeOffset]::UtcNow
    $now = $nowInstant.UtcDateTime.ToString('o')
    $nowEpoch = [long]$nowInstant.ToUnixTimeSeconds()
    $leaseInstant = $nowInstant.AddMinutes($LeaseMinutes)
    $leaseExpiry = $leaseInstant.UtcDateTime.ToString('o')
    $leaseExpiryEpoch = [long]$leaseInstant.ToUnixTimeSeconds()
    $affected = Invoke-MusicServerParamNonQuery -Template @"
UPDATE wanted_queue SET
    state = 'RESOLVING', claimed_by = @worker, claimed_at = @now,
    lease_expires_at = @lease, lease_expires_epoch = @lease_epoch,
    revision = revision + 1, updated_at = @now
WHERE track_id = @tid
  AND state IN ('WANTED','RETRY_WAIT')
  AND (claimed_by = '' OR lease_expires_epoch IS NULL OR lease_expires_epoch <= @now_epoch);
"@ -Params @{
        tid = $TrackId; worker = $WorkerId; now = $now; now_epoch = $nowEpoch
        lease = $leaseExpiry; lease_epoch = $leaseExpiryEpoch
    } -ReturnChanges
    if ($affected -eq 1) {
        return @{ Success = $true; LeaseExpiresAt = $leaseExpiry; AffectedRows = [long]$affected }
    }
    return @{ Success = $false; Reason = 'CLAIM_CONFLICT'; AffectedRows = [long]$affected }
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
    if ($PSBoundParameters.ContainsKey('NextRetryAt')) {
        $setClauses += 'next_retry_at = @nrt'
        $params['nrt'] = if ($NextRetryAt) { $NextRetryAt } else { $null }
    }
    if ($AttemptCount -ge 0) { $setClauses += 'attempt_count = @ac'; $params['ac'] = $AttemptCount }
    if ($NewState -notin @('RESOLVING','DOWNLOADING','VALIDATING')) {
        $setClauses += "claimed_by = ''"
        $setClauses += 'lease_expires_at = NULL'
        $setClauses += 'lease_expires_epoch = NULL'
    }
    $setSql = ($setClauses -join ', ')
    $affected = Invoke-MusicServerParamNonQuery -Template @"
UPDATE wanted_queue SET $setSql
WHERE track_id = @tid AND revision = @rev AND claimed_by = @worker;
"@ -Params $params -ReturnChanges
    $current = @(Invoke-MusicServerParamSql -Template 'SELECT revision, state FROM wanted_queue WHERE track_id = @tid LIMIT 1;' -Params @{ tid = $TrackId })
    if ($current.Count -eq 0) { return @{ Success = $false; Reason = 'NOT_FOUND'; AffectedRows = [long]$affected } }
    if ($affected -eq 0) {
        return @{
            Success = $false; Reason = 'CAS_FAILED'; AffectedRows = [long]$affected
            CurrentRevision = [int]$current[0].revision; CurrentState = [string]$current[0].state
        }
    }
    return @{
        Success = $true; Revision = [int]$current[0].revision; AffectedRows = [long]$affected
        CurrentState = [string]$current[0].state
    }
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
        $affected = Invoke-MusicServerParamNonQuery -Template @"
UPDATE wanted_queue SET state = 'CANCEL_REQUESTED', last_error = 'USER_CANCELLED',
    revision = @rev, updated_at = @now, claimed_by = '',
    lease_expires_at = NULL, lease_expires_epoch = NULL
WHERE track_id = @tid AND revision = @currev;
"@ -Params @{ tid = $TrackId; rev = $newRev; now = $now; currev = $item.revision } -ReturnChanges
        if ($affected -ne 1) {
            $latest = Get-WantedItemDb -TrackId $TrackId
            if ($latest -and [string]$latest.state -eq 'CANCEL_REQUESTED') {
                return @{ Success = $true; Reason = 'ALREADY_CANCELLED'; AffectedRows = [long]$affected }
            }
            return @{ Success = $false; Reason = 'CAS_CONFLICT'; AffectedRows = [long]$affected }
        }
        Write-FeedbackDb -TrackId $TrackId -FeedbackType 'UNLIKE'
        Write-MusicServerEventDb -EventType 'WANTED_CANCEL_REQUESTED' -TrackId $TrackId -Message "active item marked cancel; state=$($item.state)"
        return @{ Success = $true; Reason = 'CANCEL_REQUESTED'; AffectedRows = [long]$affected }
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
    $nowInstant = [DateTimeOffset]::UtcNow
    $leaseInstant = $nowInstant.AddMinutes($LeaseMinutes)
    $leaseExpiry = $leaseInstant.UtcDateTime.ToString('o')
    $leaseExpiryEpoch = [long]$leaseInstant.ToUnixTimeSeconds()
    return Invoke-MusicServerParamNonQuery -Template @"
UPDATE wanted_queue SET lease_expires_at = @lease, lease_expires_epoch = @lease_epoch, updated_at = @now
WHERE track_id = @tid AND claimed_by = @worker AND state IN ('RESOLVING','DOWNLOADING','VALIDATING');
"@ -Params @{
        tid = $TrackId; worker = $WorkerId; lease = $leaseExpiry
        lease_epoch = $leaseExpiryEpoch; now = $nowInstant.UtcDateTime.ToString('o')
    } -ReturnChanges
}

# ================================================================
# Crash Recovery
# ================================================================

function Invoke-CrashRecoveryDb {
    $nowIso = Get-NowIso
    $nowEpoch = [long][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $recovered = 0

    # Cancellation is a higher-priority terminal intent. Claim the cleanup with
    # a revision-guarded DELETE so a concurrent state change cannot be erased.
    $cancelRows = @(Invoke-MusicServerSqlJson -Query @"
SELECT track_id, revision FROM wanted_queue WHERE state = 'CANCEL_REQUESTED';
"@)
    foreach ($row in $cancelRows) {
        $tid = [string]$row.track_id
        $deleted = Invoke-MusicServerParamNonQuery -Template @"
DELETE FROM wanted_queue
WHERE track_id = @tid AND state = 'CANCEL_REQUESTED' AND revision = @revision;
"@ -Params @{ tid = $tid; revision = [int]$row.revision } -ReturnChanges
        if ($deleted -ne 1) { continue }

        Invoke-MusicServerParamNonQuery -Template @"
UPDATE canonical_tracks SET status = 'REMOTE', updated_at = @now, revision = revision + 1
WHERE id = @tid AND status != 'LOCAL';
"@ -Params @{ tid = $tid; now = $nowIso }
        Write-MusicServerEventDb -EventType 'WANTED_CANCELLED' -TrackId $tid -Message 'cancellation completed during recovery'
        Write-MusicServerEventDb -EventType 'WANTED_LEASE_RECOVERED' -TrackId $tid -Message 'CANCEL_REQUESTED won recovery cleanup'
        $recovered++
    }

    $staleRows = @(Invoke-MusicServerParamSql -Template @"
SELECT track_id, state, attempt_count, revision FROM wanted_queue
WHERE state IN ('RESOLVING','DOWNLOADING','VALIDATING')
  AND lease_expires_epoch IS NOT NULL
  AND lease_expires_epoch < @now_epoch;
"@ -Params @{ now_epoch = $nowEpoch })
    foreach ($row in $staleRows) {
        $tid = [string]$row.track_id
        $state = [string]$row.state
        $newAttempts = [int]$row.attempt_count + 1
        $affected = Invoke-MusicServerParamNonQuery -Template @"
UPDATE wanted_queue SET state = 'RETRY_WAIT', attempt_count = @ac, claimed_by = '',
    lease_expires_at = NULL, lease_expires_epoch = NULL,
    last_error = 'STALE_LEASE_RECOVERY', updated_at = @now,
    revision = revision + 1
WHERE track_id = @tid AND state = @state AND revision = @revision
  AND lease_expires_epoch IS NOT NULL AND lease_expires_epoch < @now_epoch;
"@ -Params @{
            tid = $tid; state = $state; revision = [int]$row.revision
            ac = $newAttempts; now = $nowIso; now_epoch = $nowEpoch
        } -ReturnChanges
        if ($affected -ne 1) { continue }
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
        half_open_probe_claimed = 0; probe_pending = $false
        last_error = ''; revision = 0; updated_at = ''
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
        probe_pending = ([int]$Row.half_open_probe_claimed -eq 1)
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
    $affected = Invoke-MusicServerParamNonQuery -Template @"
UPDATE provider_health
SET state = 'HALF_OPEN', half_open_probe_claimed = 1,
    revision = revision + 1, updated_at = @now
WHERE provider = @p
  AND half_open_probe_claimed = 0
  AND (
      state = 'HALF_OPEN'
      OR (state = 'OPEN' AND (blocked_until IS NULL OR blocked_until = '' OR blocked_until <= @now))
  );
"@ -Params @{ p = $Provider; now = $now } -ReturnChanges
    return ($affected -eq 1)
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

function Get-LatestRecommendationFeedbackDb {
    param([Parameter(Mandatory)][string]$TrackId)
    $rows = @(Invoke-MusicServerParamSql -Template "SELECT feedback_type FROM recommendation_feedback WHERE track_id = @tid AND feedback_type IN ('LIKE','UNLIKE') ORDER BY created_at DESC, id DESC LIMIT 1;" -Params @{ tid = $TrackId })
    if ($rows.Count -eq 0) { return $null }
    return [string]$rows[0].feedback_type
}

function Get-DbStats {
    $stats = @{}
    $parts = foreach ($table in @('canonical_tracks','daily_recommendations','recommendation_feedback','recommendation_files','wanted_queue','provider_health','events')) {
        "SELECT '$table' AS table_name, COUNT(*) AS cnt FROM $table"
    }
    foreach ($row in @(Invoke-MusicServerSqlJson -Query (($parts -join ' UNION ALL ') + ';'))) {
        $stats[[string]$row.table_name] = [int]$row.cnt
    }
    return $stats
}

# ====================================================================
# Phase 3 - API Atomic Transactions
# ====================================================================
# These functions implement the API-facing LIKE/UNLIKE state changes as
# TRUE SQLite transactions: a single `BEGIN ... COMMIT` script executed
# in one sqlite3 process (Invoke-MusicServerSqliteScript), so the
# canonical status, wanted_queue, feedback and event audit rows all land
# atomically.  Decision logic lives here (State layer); music_api.ps1
# only maps the returned result object to HTTP responses.
#
# Failure-injection: pass -FailAfterStep N (N>=1) and the script embeds
# a guaranteed "no such table" statement right after the Nth statement;
# `.bail on` aborts the script, sqlite3 exits non-zero, and the open
# transaction is rolled back on process exit.  Used by the ApiTransaction
# rollback tests only.

function Invoke-ApiAtomicSql {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Statements,
        [int]$FailAfterStep = 0
    )

    $sb = New-Object Text.StringBuilder
    [void]$sb.AppendLine('.bail on')
    [void]$sb.AppendLine('BEGIN;')
    $step = 0
    foreach ($raw in @($Statements)) {
        if ($null -eq $raw) { continue }
        $stmt = ([string]$raw).Trim()
        if ([string]::IsNullOrWhiteSpace($stmt)) { continue }
        while ($stmt.EndsWith(';')) { $stmt = $stmt.Substring(0, $stmt.Length - 1) }
        $step++
        [void]$sb.AppendLine("$stmt;")
        if ($FailAfterStep -gt 0 -and $step -eq $FailAfterStep) {
            [void]$sb.AppendLine("INSERT INTO ms_injected_api_failure_probe (x) VALUES (1);")
        }
    }
    [void]$sb.AppendLine('COMMIT;')
    Invoke-MusicServerSqliteScript -Sql $sb.ToString() | Out-Null
    return $step
}

function Invoke-LikeTrackTransactionDb {
    <#
    .SYNOPSIS
      Atomic LIKE: canonical status -> WANTED + wanted_queue upsert +
      'LIKE' feedback + TRACK_LIKED event, in ONE SQLite transaction.
    .NOTES
      Idempotent: repeated LIKE on an active queue row only writes
      feedback + event (no queue reset, no attempt/lease reset, no
      status/revision churn).  Re-queues from CANCEL_REQUESTED /
      UNAVAILABLE (attempt_count reset).  LOCAL tracks are preference
      only.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TrackId,
        [int]$MaxAttempts = 5,
        [string]$Source = 'music_api',
        [int]$FailAfterStep = 0
    )

    $canonical = Get-CanonicalTrackDb -TrackId $TrackId
    if ($null -eq $canonical) {
        throw "TRACK_NOT_FOUND: $TrackId"
    }
    $queue = Get-WantedItemDb -TrackId $TrackId

    $fromStatus = [string]$canonical.status
    $fromQueue = $null
    if ($queue) {
        $fromQueue = [string]$queue.state
    }

    $toStatus = $fromStatus
    $toQueue = $fromQueue

    $statements = [System.Collections.Generic.List[string]]::new()
    if ($fromStatus -eq 'LOCAL' -or ($fromQueue -eq 'LOCAL')) {
        $action = 'PREFERENCE_ONLY'
    } elseif ($fromQueue -in @('WANTED','RETRY_WAIT','RESOLVING','DOWNLOADING','VALIDATING')) {
        $action = 'ALREADY_QUEUED'
    } elseif ($fromQueue -in @('CANCEL_REQUESTED','UNAVAILABLE')) {
        $action = 'REQUEUED'
        $toStatus = 'WANTED'
        $toQueue = 'WANTED'
    } elseif ($null -eq $fromQueue) {
        $action = 'QUEUED'
        $toStatus = 'WANTED'
        $toQueue = 'WANTED'
    } else {
        $action = 'PREFERENCE_ONLY'
    }

    $now = Get-NowIso
    $litTid = ConvertTo-MusicServerSqlLiteral $TrackId
    $litNow = ConvertTo-MusicServerSqlLiteral $now
    $litSrc = ConvertTo-MusicServerSqlLiteral $Source

    if ($action -eq 'QUEUED') {
        [void]$statements.Add("UPDATE canonical_tracks SET status = 'WANTED', updated_at = $litNow, revision = revision + 1 WHERE id = $litTid AND status IN ('REMOTE','RETRY_WAIT','UNAVAILABLE')")
        $wantedId = "wanted_$([guid]::NewGuid().ToString('N'))"
        $litWid = ConvertTo-MusicServerSqlLiteral $wantedId
        [void]$statements.Add("INSERT INTO wanted_queue (track_id, wanted_id, state, attempt_count, max_attempts, revision, created_at, updated_at) VALUES ($litTid, $litWid, 'WANTED', 0, $MaxAttempts, 1, $litNow, $litNow)")
    }
    if ($action -eq 'REQUEUED') {
        [void]$statements.Add("UPDATE wanted_queue SET state = 'WANTED', attempt_count = 0, next_retry_at = NULL, last_error = '', claimed_by = '', claimed_at = NULL, lease_expires_at = NULL, lease_expires_epoch = NULL, revision = revision + 1, updated_at = $litNow WHERE track_id = $litTid AND state IN ('CANCEL_REQUESTED','UNAVAILABLE')")
        [void]$statements.Add("UPDATE canonical_tracks SET status = 'WANTED', updated_at = $litNow, revision = revision + 1 WHERE id = $litTid AND status IN ('REMOTE','RETRY_WAIT','UNAVAILABLE','CANCEL_REQUESTED')")
    }

    [void]$statements.Add("INSERT INTO recommendation_feedback (track_id, feedback_type, source, value, created_at) VALUES ($litTid, 'LIKE', $litSrc, 'true', $litNow)")
    $evtMsg = "action=$action; queue=$fromQueue; status=$fromStatus -> $toStatus"
    # events.to_state is NOT NULL: normalize queue-state audit columns to ''.
    $litToQueue = ConvertTo-MusicServerSqlLiteral ([string]$toQueue)
    [void]$statements.Add("INSERT INTO events (event_type, track_id, provider, from_state, to_state, attempt, duration_ms, result, error_type, http_status, message, created_at) VALUES ('TRACK_LIKED', $litTid, '', $(ConvertTo-MusicServerSqlLiteral ([string]$fromQueue)), $litToQueue, 0, 0.0, 'SUCCESS', '', 0, $(ConvertTo-MusicServerSqlLiteral $evtMsg), $litNow)")

    Invoke-ApiAtomicSql -Statements $statements.ToArray() -FailAfterStep $FailAfterStep | Out-Null

    $cAfter = Get-CanonicalTrackDb -TrackId $TrackId
    $qAfter = Get-WantedItemDb -TrackId $TrackId
    [pscustomobject]@{
        track_id         = $TrackId
        liked            = $true
        action           = $action
        from_status      = $fromStatus
        to_status        = if ($cAfter) { [string]$cAfter.status } else { '' }
        from_queue       = $fromQueue
        to_queue         = if ($qAfter) { [string]$qAfter.state } else { $null }
        queue_revision   = if ($qAfter) { [int]$qAfter.revision } else { 0 }
    }
}

function Invoke-UnlikeTrackTransactionDb {
    <#
    .SYNOPSIS
      Atomic UNLIKE in ONE SQLite transaction, branching on the
      CURRENT queue state (single source of truth: SQLite):
        - LOCAL               -> preference only (feedback + event).
                                 Never deletes MP3, never touches Navidrome identity.
        - WANTED/RETRY_WAIT/UNAVAILABLE (idle)
                              -> DELETE queue row + canonical -> REMOTE +
                                 UNLIKE feedback + TRACK_UNLIKED event.
        - RESOLVING/DOWNLOADING/VALIDATING (active)
                              -> CANCEL_REQUESTED + revision+1 + lease cleared +
                                 UNLIKE feedback + TRACK_UNLIKED +
                                 WANTED_CANCEL_REQUESTED event.  A stale worker
                                 CAS afterwards must fail with changes()=0.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TrackId,
        [string]$Source = 'music_api',
        [int]$FailAfterStep = 0
    )

    $canonical = Get-CanonicalTrackDb -TrackId $TrackId
    if ($null -eq $canonical) {
        throw "TRACK_NOT_FOUND: $TrackId"
    }
    $queue = Get-WantedItemDb -TrackId $TrackId

    $fromStatus = [string]$canonical.status
    $fromQueue = $null
    if ($queue) {
        $fromQueue = [string]$queue.state
    }

    $toStatus = $fromStatus
    $toQueue = $fromQueue

    if ($fromStatus -eq 'LOCAL' -or ($fromQueue -eq 'LOCAL')) {
        $action = 'PREFERENCE_ONLY'
    } elseif ($fromQueue -in @('RESOLVING','DOWNLOADING','VALIDATING')) {
        $action = 'CANCEL_REQUESTED'
        $toQueue = 'CANCEL_REQUESTED'
    } else {
        $action = 'IDLE_REMOVED'
        $toStatus = 'REMOTE'
        $toQueue = $null
    }

    $now = Get-NowIso
    $litTid = ConvertTo-MusicServerSqlLiteral $TrackId
    $litNow = ConvertTo-MusicServerSqlLiteral $now
    $litSrc = ConvertTo-MusicServerSqlLiteral $Source

    $statements = [System.Collections.Generic.List[string]]::new()
    if ($action -eq 'CANCEL_REQUESTED') {
        [void]$statements.Add("UPDATE wanted_queue SET state = 'CANCEL_REQUESTED', last_error = 'USER_CANCELLED', claimed_by = '', claimed_at = NULL, lease_expires_at = NULL, lease_expires_epoch = NULL, revision = revision + 1, updated_at = $litNow WHERE track_id = $litTid AND state IN ('RESOLVING','DOWNLOADING','VALIDATING')")
    }
    if ($action -eq 'IDLE_REMOVED') {
        [void]$statements.Add("DELETE FROM wanted_queue WHERE track_id = $litTid AND state IN ('WANTED','RETRY_WAIT','UNAVAILABLE','CANCEL_REQUESTED')")
        [void]$statements.Add("UPDATE canonical_tracks SET status = 'REMOTE', updated_at = $litNow, revision = revision + 1 WHERE id = $litTid AND status IN ('WANTED','RETRY_WAIT','UNAVAILABLE','CANCEL_REQUESTED')")
    }

    $evtMsg = "action=$action; queue=$fromQueue; status=$fromStatus"
    [void]$statements.Add("INSERT INTO recommendation_feedback (track_id, feedback_type, source, value, created_at) VALUES ($litTid, 'UNLIKE', $litSrc, 'false', $litNow)")
    if ($action -eq 'CANCEL_REQUESTED') {
        [void]$statements.Add("INSERT INTO events (event_type, track_id, provider, from_state, to_state, attempt, duration_ms, result, error_type, http_status, message, created_at) VALUES ('TRACK_UNLIKED', $litTid, '', $(ConvertTo-MusicServerSqlLiteral ([string]$fromQueue)), 'CANCEL_REQUESTED', 0, 0.0, 'SUCCESS', '', 0, $(ConvertTo-MusicServerSqlLiteral $evtMsg), $litNow)")
        [void]$statements.Add("INSERT INTO events (event_type, track_id, provider, from_state, to_state, attempt, duration_ms, result, error_type, http_status, message, created_at) VALUES ('WANTED_CANCEL_REQUESTED', $litTid, '', $(ConvertTo-MusicServerSqlLiteral ([string]$fromQueue)), 'CANCEL_REQUESTED', 0, 0.0, 'SUCCESS', '', 0, $(ConvertTo-MusicServerSqlLiteral $evtMsg), $litNow)")
    } else {
        $toQueueLiteral = ConvertTo-MusicServerSqlLiteral ([string]$toQueue)
        if ($action -eq 'IDLE_REMOVED') { $toQueueLiteral = '''' + 'REMOVED' + '''' }
        [void]$statements.Add("INSERT INTO events (event_type, track_id, provider, from_state, to_state, attempt, duration_ms, result, error_type, http_status, message, created_at) VALUES ('TRACK_UNLIKED', $litTid, '', $(ConvertTo-MusicServerSqlLiteral ([string]$fromQueue)), $toQueueLiteral, 0, 0.0, 'SUCCESS', '', 0, $(ConvertTo-MusicServerSqlLiteral $evtMsg), $litNow)")
    }

    Invoke-ApiAtomicSql -Statements $statements.ToArray() -FailAfterStep $FailAfterStep | Out-Null

    $cAfter = Get-CanonicalTrackDb -TrackId $TrackId
    $qAfter = Get-WantedItemDb -TrackId $TrackId
    [pscustomobject]@{
        track_id         = $TrackId
        liked            = $false
        action           = $action
        from_status      = $fromStatus
        to_status        = if ($cAfter) { [string]$cAfter.status } else { '' }
        from_queue       = $fromQueue
        to_queue         = if ($qAfter) { [string]$qAfter.state } else { $null }
        queue_revision   = if ($qAfter) { [int]$qAfter.revision } else { 0 }
    }
}

# ====================================================================
# Listening statistics
# ====================================================================
# The public interface is deliberately small: callers submit one completed
# local-play event and read the aggregate rows. Session de-duplication is
# enforced by SQLite's UNIQUE(identity, session_id) constraint; the trigger
# updates listening_stats only when a new event is inserted.

function Get-ListeningStatsDb {
    [CmdletBinding()]
    param(
        [string]$Identity = ''
    )

    if ([string]::IsNullOrWhiteSpace($Identity)) {
        $rows = @(Invoke-MusicServerSqlJson -Query @"
SELECT identity, track_id, library_id, play_count, last_played_at, first_played_at, updated_at
FROM listening_stats
ORDER BY play_count DESC, last_played_at DESC, identity ASC;
"@)
    } else {
        $rows = @(Invoke-MusicServerParamSql -Template @"
SELECT identity, track_id, library_id, play_count, last_played_at, first_played_at, updated_at
FROM listening_stats
WHERE identity = @identity
LIMIT 1;
"@ -Params @{ identity = $Identity })
    }

    return @($rows | ForEach-Object {
        [pscustomobject]@{
            identity = [string]$_.identity
            track_id = [string]$_.track_id
            library_id = [string]$_.library_id
            play_count = [int]$_.play_count
            last_played_at = if ($null -eq $_.last_played_at) { $null } else { [string]$_.last_played_at }
            first_played_at = if ($null -eq $_.first_played_at) { $null } else { [string]$_.first_played_at }
            updated_at = [string]$_.updated_at
        }
    })
}

function Record-ListeningPlayDb {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Identity,
        [string]$TrackId = '',
        [string]$LibraryId = '',
        [string]$SessionId = '',
        [string]$Now = ''
    )

    if ([string]::IsNullOrWhiteSpace($Identity)) {
        throw 'LISTENING_IDENTITY_REQUIRED'
    }
    if ([string]::IsNullOrWhiteSpace($SessionId)) {
        $SessionId = 'session_' + [guid]::NewGuid().ToString('N')
    }
    if ([string]::IsNullOrWhiteSpace($Now)) {
        $Now = Get-NowIso
    }

    $litIdentity = ConvertTo-MusicServerSqlLiteral $Identity
    $litTrackId = ConvertTo-MusicServerSqlLiteral $TrackId
    $litLibraryId = ConvertTo-MusicServerSqlLiteral $LibraryId
    $litSessionId = ConvertTo-MusicServerSqlLiteral $SessionId
    $litNow = ConvertTo-MusicServerSqlLiteral $Now

    # SELECT changes() is inside the same transaction and immediately follows
    # INSERT OR IGNORE, so it tells us whether this session was newly counted.
    $sql = @"
.bail on
BEGIN;
INSERT OR IGNORE INTO listening_play_events (identity, session_id, track_id, library_id, played_at)
VALUES ($litIdentity, $litSessionId, $litTrackId, $litLibraryId, $litNow);
SELECT changes() AS counted;
COMMIT;
"@
    $raw = Invoke-MusicServerSqliteScript -Sql $sql -Json
    $rows = @()
    if (-not [string]::IsNullOrWhiteSpace($raw)) {
        $parsed = ConvertFrom-MusicServerSqliteJson -Json ([string]$raw)
        $rows = @($parsed)
    }
    $counted = $false
    if ($rows.Count -gt 0) {
        $countRow = $rows | Where-Object { $_.PSObject.Properties['counted'] } | Select-Object -Last 1
        if ($countRow) { $counted = ([int]$countRow.counted -eq 1) }
    }

    $stat = @(Get-ListeningStatsDb -Identity $Identity) | Select-Object -First 1
    if ($null -eq $stat) {
        throw "LISTENING_STAT_NOT_FOUND: $Identity"
    }
    return [pscustomobject]@{
        identity = [string]$stat.identity
        track_id = [string]$stat.track_id
        library_id = [string]$stat.library_id
        play_count = [int]$stat.play_count
        last_played_at = $stat.last_played_at
        first_played_at = $stat.first_played_at
        updated_at = [string]$stat.updated_at
        session_id = $SessionId
        counted = $counted
    }
}

function Select-ListeningRandomSubset {
    param(
        [AllowEmptyCollection()][object[]]$Items = @(),
        [int]$Count = 0
    )

    if ($Count -le 0 -or @($Items).Count -eq 0) { return @() }
    $copy = New-Object System.Collections.ArrayList
    foreach ($item in @($Items)) { [void]$copy.Add($item) }
    for ($i = $copy.Count - 1; $i -gt 0; $i--) {
        $j = Get-Random -Minimum 0 -Maximum ($i + 1)
        $temp = $copy[$i]
        $copy[$i] = $copy[$j]
        $copy[$j] = $temp
    }
    return @($copy | Select-Object -First ([Math]::Min($Count, $copy.Count)))
}

function ConvertTo-ListeningItemResponse {
    param([Parameter(Mandatory = $true)]$Item)

    $identity = [string](Get-OptionalProperty $Item 'identity' (Get-OptionalProperty $Item 'listening_identity'))
    [pscustomobject]@{
        id = [string](Get-OptionalProperty $Item 'id')
        library_id = [string](Get-OptionalProperty $Item 'library_id' (Get-OptionalProperty $Item 'id'))
        identity = $identity
        track_id = [string](Get-OptionalProperty $Item 'track_id' $identity)
        title = [string](Get-OptionalProperty $Item 'title' (Get-OptionalProperty $Item 'name'))
        artist = [string](Get-OptionalProperty $Item 'artist')
        album = [string](Get-OptionalProperty $Item 'album')
        duration = [int](Get-OptionalProperty $Item 'duration' 0)
        cover_url = [string](Get-OptionalProperty $Item 'cover_url')
        stream_url = [string](Get-OptionalProperty $Item 'stream_url')
        lyrics_url = [string](Get-OptionalProperty $Item 'lyrics_url')
        play_count = [int](Get-OptionalProperty $Item 'play_count' 0)
        last_played_at = Get-OptionalProperty $Item 'last_played_at' $null
        first_played_at = Get-OptionalProperty $Item 'first_played_at' $null
        updated_at = [string](Get-OptionalProperty $Item 'updated_at')
    }
}

function Get-ListeningOverviewDb {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][object[]]$LibraryItems = @(),
        [int]$MostPlayedLimit = 5,
        [int]$RediscoverLimit = 5,
        [int]$RecentCooldownMinutes = 120,
        [DateTime]$AsOf = [DateTime]::UtcNow
    )

    $mostLimit = [Math]::Max(0, $MostPlayedLimit)
    $rediscoverLimit = [Math]::Max(0, $RediscoverLimit)
    $nowUtc = $AsOf.ToUniversalTime()
    $statsByIdentity = @{}
    foreach ($stat in @(Get-ListeningStatsDb)) {
        $identity = [string]$stat.identity
        if ($identity) { $statsByIdentity[$identity] = $stat }
    }

    $joined = @(
        foreach ($libraryItem in @($LibraryItems)) {
            if ($null -eq $libraryItem) { continue }
            $identity = [string](Get-OptionalProperty $libraryItem 'listening_identity')
            if (-not $identity) { $identity = [string](Get-OptionalProperty $libraryItem 'identity') }
            if (-not $identity) { $identity = [string](Get-OptionalProperty $libraryItem 'track_id') }
            if (-not $identity) { $identity = [string](Get-OptionalProperty $libraryItem 'id') }
            if (-not $identity) { continue }

            $stat = if ($statsByIdentity.ContainsKey($identity)) { $statsByIdentity[$identity] } else { $null }
            $trackId = [string](Get-OptionalProperty $libraryItem 'track_id')
            if (-not $trackId) { $trackId = $identity }
            [pscustomobject]@{
                id = [string](Get-OptionalProperty $libraryItem 'id')
                library_id = [string](Get-OptionalProperty $libraryItem 'library_id' (Get-OptionalProperty $libraryItem 'id'))
                identity = $identity
                track_id = $trackId
                title = [string](Get-OptionalProperty $libraryItem 'title' (Get-OptionalProperty $libraryItem 'name'))
                artist = [string](Get-OptionalProperty $libraryItem 'artist')
                album = [string](Get-OptionalProperty $libraryItem 'album')
                duration = [int](Get-OptionalProperty $libraryItem 'duration' 0)
                cover_url = [string](Get-OptionalProperty $libraryItem 'cover_url')
                stream_url = [string](Get-OptionalProperty $libraryItem 'stream_url')
                lyrics_url = [string](Get-OptionalProperty $libraryItem 'lyrics_url')
                play_count = if ($stat) { [int]$stat.play_count } else { 0 }
                last_played_at = if ($stat) { $stat.last_played_at } else { $null }
                first_played_at = if ($stat) { $stat.first_played_at } else { $null }
                updated_at = if ($stat) { [string]$stat.updated_at } else { '' }
            }
        }
    )

    $most = @()
    if ($mostLimit -gt 0) {
        $most = @($joined |
            Where-Object { [int]$_.play_count -gt 0 } |
            Sort-Object `
                @{ Expression = { [int]$_.play_count }; Descending = $true }, `
                @{ Expression = { [string]$_.last_played_at }; Descending = $true }, `
                @{ Expression = { [string]$_.identity }; Descending = $false } |
            Select-Object -First $mostLimit)
    }

    $rediscover = @()
    if ($rediscoverLimit -gt 0) {
        $cutoff = $nowUtc.AddMinutes(-1 * [Math]::Max(0, $RecentCooldownMinutes))
        $candidates = @(
            foreach ($item in @($joined)) {
                $last = Convert-ToUtcDateTime $item.last_played_at
                # A just-finished or currently playing song should not be sent
                # back into the rediscovery list immediately.
                if ($last -and $last -ge $cutoff) { continue }
                $priority = 3
                if ($last -and (($nowUtc - $last).TotalDays -ge 30)) {
                    $priority = 0
                } elseif ($last -and [int]$item.play_count -le 1) {
                    $priority = 1
                } elseif (-not $last -or [int]$item.play_count -eq 0) {
                    $priority = 2
                }
                [pscustomobject]@{
                    item = $item
                    priority = $priority
                    age_days = if ($last) { ($nowUtc - $last).TotalDays } else { [double]::MaxValue }
                    play_count = [int]$item.play_count
                    last_played_at = [string]$item.last_played_at
                }
            }
        )

        $poolSize = [Math]::Min($candidates.Count, [Math]::Max($rediscoverLimit * 4, 20))
        $pool = @($candidates |
            Sort-Object `
                @{ Expression = { [int]$_.priority }; Descending = $false }, `
                @{ Expression = { [int]$_.play_count }; Descending = $false }, `
                @{ Expression = { [double]$_.age_days }; Descending = $true }, `
                @{ Expression = { [string]$_.last_played_at }; Descending = $false } |
            Select-Object -First $poolSize)
        $rediscover = @(Select-ListeningRandomSubset -Items @($pool | ForEach-Object { $_.item }) -Count $rediscoverLimit |
            ForEach-Object { ConvertTo-ListeningItemResponse -Item $_ })
    }

    return [pscustomobject]@{
        most_played = @($most | ForEach-Object { ConvertTo-ListeningItemResponse -Item $_ })
        rediscover = $rediscover
    }
}

# ================================================================
# App Settings & Music Dir Resolution
# ================================================================

function Resolve-ConfiguredMusicDir {
    <#
    .SYNOPSIS
      Centralized MusicDir resolver. Priority: env var > SQLite setting > default.
      Must be called after Initialize-MusicServerDatabase + Initialize-MusicServerSchema.
    #>
    param([Parameter(Mandatory)][psobject]$Config)

    # Priority 1: Environment variable (developer/debug override)
    $envDir = [Environment]::GetEnvironmentVariable('MUSICSERVER_MUSIC_DIR')
    if (-not [string]::IsNullOrWhiteSpace($envDir)) {
        $resolved = [IO.Path]::GetFullPath($envDir)
        return $resolved
    }

    # Priority 2: SQLite persisted setting
    try {
        $saved = Get-AppSettingDb -Key 'music_library_path'
        if ($saved -and -not [string]::IsNullOrWhiteSpace($saved)) {
            return [IO.Path]::GetFullPath($saved)
        }
    } catch {}

    # Priority 3: Default. Config.MusicDir is mutable after Apply-ConfiguredMusicDir.
    return (Get-DefaultMusicDir -AppHome $Config.AppHome)
}

function Apply-ConfiguredMusicDir {
    <#
    .SYNOPSIS
      Resolves the effective MusicDir and updates Config.MusicDir + Config.DailyDir in place.
      Safe to call multiple times; idempotent.
    #>
    param([Parameter(Mandatory)][psobject]$Config)

    $resolved = Resolve-ConfiguredMusicDir -Config $Config
    $Config.MusicDir = $resolved
    $Config.DailyDir = Join-Path $resolved 'DailyMix'
    try { Sync-NavidromeMusicFolder -NdConfigPath $Config.NdConfig -NewMusicFolder $resolved | Out-Null } catch {}
    return $resolved
}

function Get-DefaultMusicDirForConfig {
    param([Parameter(Mandatory)][psobject]$Config)
    return Get-DefaultMusicDir -AppHome $Config.AppHome
}

function Test-MusicLibraryPath {
    <#
    .SYNOPSIS
      Validates a candidate music library path. Returns @{ Valid=$bool; Reason=$string }.
    #>
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return @{ Valid = $false; Reason = 'EMPTY_PATH' }
    }
    $fullPath = ''
    try { $fullPath = [IO.Path]::GetFullPath($Path) } catch {
        return @{ Valid = $false; Reason = 'INVALID_PATH' }
    }
    if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
        return @{ Valid = $false; Reason = 'IS_FILE' }
    }
    return @{ Valid = $true; Reason = 'OK'; FullPath = $fullPath }
}

function Get-AppSettingDb {
    param([Parameter(Mandatory)][string]$Key)
    $rows = @(Invoke-MusicServerParamSql -Template 'SELECT value FROM app_settings WHERE key = @key LIMIT 1;' -Params @{ key = $Key })
    if ($rows.Count -eq 0) { return $null }
    return [string]$rows[0].value
}

function Set-AppSettingDb {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Value
    )
    $now = Get-NowIso
    Invoke-MusicServerParamNonQuery -Template @"
INSERT INTO app_settings (key, value, updated_at) VALUES (@key, @value, @now)
ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at;
"@ -Params @{ key = $Key; value = $Value; now = $now }
}

function Remove-AppSettingDb {
    param([Parameter(Mandatory)][string]$Key)
    Invoke-MusicServerParamNonQuery -Template 'DELETE FROM app_settings WHERE key = @key;' -Params @{ key = $Key }
}

function Sync-NavidromeMusicFolder {
    <#
    .SYNOPSIS
      Updates navidrome.toml MusicFolder to match the effective MusicDir.
      Writes a TOML basic string with escaped Windows backslashes and quotes.
    #>
    param(
        [Parameter(Mandatory)][string]$NdConfigPath,
        [Parameter(Mandatory)][string]$NewMusicFolder
    )
    if (-not (Test-Path -LiteralPath $NdConfigPath -PathType Leaf)) { return $false }

    $content = Get-Content -LiteralPath $NdConfigPath -Raw -Encoding UTF8
    $encoded = $NewMusicFolder.Replace('\', '\\').Replace('"', '\"')
    $desiredLine = 'MusicFolder = "' + $encoded + '"'
    $pattern = '(?m)^\s*MusicFolder\s*=.*$'

    if ([regex]::IsMatch($content, $pattern)) {
        $currentLine = [regex]::Match($content, $pattern).Value.Trim()
        if ($currentLine -eq $desiredLine) { return $false }
        $updated = [regex]::Replace(
            $content,
            $pattern,
            [Text.RegularExpressions.MatchEvaluator]{ param($m) $desiredLine },
            1
        )
    } else {
        $updated = $desiredLine + [Environment]::NewLine + $content
    }

    [IO.File]::WriteAllText($NdConfigPath, $updated, (New-Object Text.UTF8Encoding($false)))
    return $true
}
Export-ModuleMember -Function *
