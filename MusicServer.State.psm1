Set-StrictMode -Version 3.0

# MusicServer.State.psm1 - Transactional state layer backed by SQLite
# Provides: schema, migration, CAS, worker claim/lease, crash recovery,
#           transactional like/unlike/download-completion, provider health.

Import-Module (Join-Path $PSScriptRoot 'MusicServer.Database.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'MusicServer.Core.psm1') -Force

$script:SchemaVersion = 3
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
CREATE TABLE IF NOT EXISTS migration_markers (
    source_key TEXT PRIMARY KEY,
    imported_at TEXT NOT NULL,
    result_json TEXT NOT NULL DEFAULT ''
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
    Invoke-MusicServerSqlNonQuery -Query @"
UPDATE wanted_queue
SET lease_expires_epoch = CAST(strftime('%s', lease_expires_at) AS INTEGER)
WHERE lease_expires_epoch IS NULL
  AND lease_expires_at IS NOT NULL
  AND lease_expires_at != '';
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
CREATE INDEX IF NOT EXISTS idx_wanted_lease_epoch ON wanted_queue(lease_expires_epoch);
CREATE INDEX IF NOT EXISTS idx_events_track ON events(track_id);
CREATE INDEX IF NOT EXISTS idx_events_type ON events(event_type);
CREATE INDEX IF NOT EXISTS idx_events_created ON events(created_at);
CREATE INDEX IF NOT EXISTS idx_daily_date ON daily_recommendations(date);
CREATE INDEX IF NOT EXISTS idx_feedback_track ON recommendation_feedback(track_id);
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
        }
        if ($CAS) { $updateParams['expected_revision'] = $ExpectedRevision }
        $affected = Invoke-MusicServerParamNonQuery -Template @"
UPDATE canonical_tracks SET
    title = @title, artist = @artist, album = @album, duration = @duration,
    cover_url = @cover_url, identifiers_json = @identifiers, preview_sources_json = @preview,
    download_candidates_json = @candidates, local_song_id = @local_song_id,
    status = @status, updated_at = @updated_at, revision = @revision
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
        [int]$RandomSeed = -1
    )

    if ($RandomSeed -ge 0) { Get-Random -SetSeed $RandomSeed | Out-Null }
    $signals = @{}
    $feedback = @(Get-RecommendationFeedbackDb)
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
        }
        [void]$statements.Add("INSERT INTO canonical_tracks (id,title,artist,album,duration,cover_url,identifiers_json,preview_sources_json,download_candidates_json,local_song_id,status,created_at,updated_at,revision) VALUES ($($lit.id),$($lit.title),$($lit.artist),$($lit.album),$($lit.dur),$($lit.cover),$($lit.ident),$($lit.prev),$($lit.cand),$($lit.local),$($lit.status),$($lit.created),$($lit.updated),1) ON CONFLICT(id) DO UPDATE SET title=excluded.title, artist=excluded.artist, album=excluded.album, duration=excluded.duration, cover_url=excluded.cover_url, identifiers_json=excluded.identifiers_json, preview_sources_json=excluded.preview_sources_json, download_candidates_json=excluded.download_candidates_json, local_song_id=CASE WHEN canonical_tracks.local_song_id IS NULL OR canonical_tracks.local_song_id='' THEN excluded.local_song_id ELSE canonical_tracks.local_song_id END, status=CASE WHEN canonical_tracks.status='REMOTE' THEN excluded.status ELSE canonical_tracks.status END, created_at=canonical_tracks.created_at, updated_at=excluded.updated_at, revision=canonical_tracks.revision")
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
        lease_expires_at = [string]$Row.lease_expires_at
        lease_expires_epoch = if ($null -eq $Row.lease_expires_epoch) { $null } else { [long]$Row.lease_expires_epoch }
        revision = [int]$Row.revision
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
    if ($NextRetryAt) { $setClauses += 'next_retry_at = @nrt'; $params['nrt'] = $NextRetryAt }
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
    $rows = @(Invoke-MusicServerParamSql -Template 'SELECT feedback_type FROM recommendation_feedback WHERE track_id = @tid ORDER BY id DESC LIMIT 1;' -Params @{ tid = $TrackId })
    if ($rows.Count -eq 0) { return $null }
    return [string]$rows[0].feedback_type
}

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

Export-ModuleMember -Function *
