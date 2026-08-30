Set-StrictMode -Version 3.0

# MusicServer.Migration.psm1 - legacy JSON/CSV to SQLite migration.
# Legacy files are read only before the marker is written. The import itself
# is one SQLite transaction; the source files are never deleted or rewritten.

Import-Module (Join-Path $PSScriptRoot 'MusicServer.Database.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'MusicServer.Core.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'MusicServer.State.psm1') -Force

$script:RecommendationMigrationKey = 'recommendation_state_v2'

function Read-LegacyCollectionSafe {
    param(
        [Parameter(Mandatory)][psobject]$Config,
        [Parameter(Mandatory)][ValidateSet('tracks','recommendations','recommendation_history','wanted','providers')][string]$Name,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Report
    )
    try { return @(Read-StateCollection -Config $Config -Name $Name) }
    catch {
        $Report.legacy_ignored += "malformed $Name.json: $($_.Exception.Message)"
        return @()
    }
}

function Read-LegacyCsvSafe {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Report
    )
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    try { return @(Import-Csv -LiteralPath $Path -Encoding UTF8 -ErrorAction Stop) }
    catch {
        $Report.legacy_ignored += "malformed ${Label}: $($_.Exception.Message)"
        return @()
    }
}

function Read-LegacyEventsSafe {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Report
    )
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    $rows = @()
    foreach ($line in @(Get-Content -LiteralPath $Path -Encoding UTF8)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $rows += (ConvertFrom-Json -InputObject $line) }
        catch { $Report.legacy_ignored += "malformed events.jsonl line: $($_.Exception.Message)" }
    }
    return @($rows)
}

function Test-LegacyPositive {
    param([AllowNull()]$Value)
    return (Test-RecommendationPositiveValue $Value)
}

function New-LegacyMetadataValue {
    param(
        [string]$LegacyKey,
        [string]$Title = '',
        [string]$Artist = '',
        [string]$NeteaseId = '',
        [string]$File = '',
        [string]$AcceptedAt = '',
        [bool]$Positive = $true
    )
    return (ConvertTo-Json -InputObject ([ordered]@{
        legacy_key = $LegacyKey; title = $Title; artist = $Artist; netease_id = $NeteaseId
        file = $File; accepted_at = $AcceptedAt; positive = $Positive
    }) -Compress -Depth 10)
}

function Get-LegacyTrackId {
    param([psobject]$Row)
    $title = [string](Get-OptionalProperty $Row 'title' (Get-OptionalProperty $Row 'Title'))
    $artist = [string](Get-OptionalProperty $Row 'artist' (Get-OptionalProperty $Row 'Artist'))
    $trackId = [string](Get-OptionalProperty $Row 'track_id' (Get-OptionalProperty $Row 'TrackId'))
    if ($trackId) { return $trackId }
    if ($title) { return (Get-CanonicalTrackId -Title $title -Artist $artist) }
    $neteaseId = [string](Get-OptionalProperty $Row 'netease_id' (Get-OptionalProperty $Row 'NeteaseId'))
    if ($neteaseId) { return "netease:$neteaseId" }
    return ''
}

function Convert-LegacyInt {
    param(
        [AllowNull()]$Value,
        [int]$Default = 0,
        [AllowNull()][System.Collections.IDictionary]$Report,
        [string]$Label = 'numeric field'
    )
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $Default }
    try { return [int]$Value }
    catch {
        if ($Report) { $Report.legacy_ignored += "malformed ${Label}: $Value" }
        return $Default
    }
}

function Convert-LegacyDouble {
    param(
        [AllowNull()]$Value,
        [double]$Default = 0,
        [AllowNull()][System.Collections.IDictionary]$Report,
        [string]$Label = 'numeric field'
    )
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $Default }
    try { return [double]$Value }
    catch {
        if ($Report) { $Report.legacy_ignored += "malformed ${Label}: $Value" }
        return $Default
    }
}

function Add-MigrationFeedbackStatement {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Statements,
        [string]$TrackId,
        [string]$FeedbackType,
        [string]$Source,
        [string]$Value,
        [string]$CreatedAt
    )
    if (-not $TrackId) { return }
    $litTid = ConvertTo-MusicServerSqlLiteral $TrackId
    $litType = ConvertTo-MusicServerSqlLiteral $FeedbackType
    $litSource = ConvertTo-MusicServerSqlLiteral $Source
    $litValue = ConvertTo-MusicServerSqlLiteral $Value
    $litCreated = ConvertTo-MusicServerSqlLiteral $CreatedAt
    [void]$Statements.Add("INSERT INTO recommendation_feedback (track_id,feedback_type,source,value,created_at) SELECT $litTid,$litType,$litSource,$litValue,$litCreated WHERE NOT EXISTS (SELECT 1 FROM recommendation_feedback WHERE track_id=$litTid AND feedback_type=$litType AND source=$litSource AND value=$litValue)")
}

function Add-MigrationEventStatement {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Statements,
        [Parameter(Mandatory)][psobject]$Event,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Report
    )
    $eventType = [string](Get-OptionalProperty $Event 'event' (Get-OptionalProperty $Event 'event_type'))
    if (-not $eventType) {
        $Report.legacy_ignored += 'malformed events.jsonl row: event missing'
        return $false
    }
    $trackId = [string](Get-OptionalProperty $Event 'track_id')
    $provider = [string](Get-OptionalProperty $Event 'provider')
    $fromState = [string](Get-OptionalProperty $Event 'from_state')
    $toState = [string](Get-OptionalProperty $Event 'to_state')
    $attempt = Convert-LegacyInt -Value (Get-OptionalProperty $Event 'attempt' 0) -Report $Report -Label "event attempt for $eventType"
    $duration = Convert-LegacyDouble -Value (Get-OptionalProperty $Event 'duration_ms' 0) -Report $Report -Label "event duration_ms for $eventType"
    $result = [string](Get-OptionalProperty $Event 'result')
    $errorType = [string](Get-OptionalProperty $Event 'error_type')
    $httpStatus = Convert-LegacyInt -Value (Get-OptionalProperty $Event 'http_status' 0) -Report $Report -Label "event http_status for $eventType"
    $message = [string](Get-OptionalProperty $Event 'message')
    $createdAt = [string](Get-OptionalProperty $Event 'timestamp' (Get-OptionalProperty $Event 'created_at'))
    if (-not $createdAt) { $createdAt = Get-NowIso }
    $p = @{
        type = ConvertTo-MusicServerSqlLiteral $eventType; tid = ConvertTo-MusicServerSqlLiteral $trackId; provider = ConvertTo-MusicServerSqlLiteral $provider
        from = ConvertTo-MusicServerSqlLiteral $fromState; to = ConvertTo-MusicServerSqlLiteral $toState; attempt = ConvertTo-MusicServerSqlLiteral $attempt
        duration = ConvertTo-MusicServerSqlLiteral $duration; result = ConvertTo-MusicServerSqlLiteral $result; error = ConvertTo-MusicServerSqlLiteral $errorType
        http = ConvertTo-MusicServerSqlLiteral $httpStatus; message = ConvertTo-MusicServerSqlLiteral $message; created = ConvertTo-MusicServerSqlLiteral $createdAt
    }
    [void]$Statements.Add("INSERT INTO events (event_type,track_id,provider,from_state,to_state,attempt,duration_ms,result,error_type,http_status,message,created_at) VALUES ($($p.type),$($p.tid),$($p.provider),$($p.from),$($p.to),$($p.attempt),$($p.duration),$($p.result),$($p.error),$($p.http),$($p.message),$($p.created))")
    if ($eventType -eq 'TRACK_LIKED' -and $trackId) {
        Add-MigrationFeedbackStatement -Statements $Statements -TrackId $trackId -FeedbackType 'LIKE' -Source 'legacy_event' -Value 'true' -CreatedAt $createdAt
        if ($Report.Contains('imported') -and $Report.imported -and $Report.imported.Contains('explicit_likes')) { $Report.imported.explicit_likes++ }
    } elseif ($eventType -eq 'TRACK_UNLIKED' -and $trackId) {
        Add-MigrationFeedbackStatement -Statements $Statements -TrackId $trackId -FeedbackType 'UNLIKE' -Source 'legacy_event' -Value 'false' -CreatedAt $createdAt
    } elseif ($eventType -eq 'RECOMMENDATION_DISPLAY' -and $trackId) {
        $date = ''; $rank = 0; $recId = ''
        if ($message -match 'date=([^;]+);rank=(\d+);rec_id=(.*)$') {
            $date = [string]$Matches[1]; $rank = [int]$Matches[2]; $recId = [string]$Matches[3]
        }
        $displayValue = if ($date -and $rank -gt 0) { "legacy:display:$date`:$rank`:$recId" } else { "legacy:event:$createdAt`:$eventType`:$trackId" }
        Add-MigrationFeedbackStatement -Statements $Statements -TrackId $trackId -FeedbackType 'DISPLAY' -Source 'legacy_event' -Value $displayValue -CreatedAt $createdAt
    }
    return $true
}

function Add-MigrationDisplayStatement {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Statements,
        [string]$TrackId,
        [string]$Date,
        [int]$Rank,
        [string]$RecId,
        [string]$CreatedAt
    )
    if (-not $TrackId -or -not $Date) { return }
    $value = "legacy:display:$Date`:$Rank`:$RecId"
    Add-MigrationFeedbackStatement -Statements $Statements -TrackId $TrackId -FeedbackType 'DISPLAY' -Source 'legacy_recommendation' -Value $value -CreatedAt $CreatedAt
}

function Add-MigrationDailyRecommendationStatement {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Statements,
        [Parameter(Mandatory)][psobject]$Row,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Report,
        [string]$FallbackDate = ''
    )
    $title = [string](Get-OptionalProperty $Row 'title' (Get-OptionalProperty $Row 'Title'))
    $artist = [string](Get-OptionalProperty $Row 'artist' (Get-OptionalProperty $Row 'Artist'))
    $date = [string](Get-OptionalProperty $Row 'date' (Get-OptionalProperty $Row 'Date' $FallbackDate))
    $trackId = Get-LegacyTrackId -Row $Row
    if (-not $title -or -not $date -or -not $trackId) {
        $Report.legacy_ignored += 'malformed recommendation row (title/date/track_id missing)'
        return $false
    }
    $rank = 0
    $rank = Convert-LegacyInt -Value (Get-OptionalProperty $Row 'rank' (Get-OptionalProperty $Row 'Rank' 0)) -Report $Report -Label "recommendation rank for $title"
    if ($rank -le 0) {
        $Report.legacy_ignored += "malformed recommendation row: invalid rank for $title"
        return $false
    }
    $neteaseId = [string](Get-OptionalProperty $Row 'netease_id' (Get-OptionalProperty $Row 'NeteaseId'))
    $album = [string](Get-OptionalProperty $Row 'album' (Get-OptionalProperty $Row 'Album'))
    $duration = Convert-LegacyInt -Value (Get-OptionalProperty $Row 'duration' (Get-OptionalProperty $Row 'Duration' 0)) -Report $Report -Label "recommendation duration for $title"
    $reason = [string](Get-OptionalProperty $Row 'reason' (Get-OptionalProperty $Row 'Reason' (Get-OptionalProperty $Row 'FromSeed')))
    $seedSource = [string](Get-OptionalProperty $Row 'seed_source' (Get-OptionalProperty $Row 'SeedSource'))
    $playback = [string](Get-OptionalProperty $Row 'playback_source' (Get-OptionalProperty $Row 'PlaybackSource'))
    $recId = [string](Get-OptionalProperty $Row 'id' (Get-OptionalProperty $Row 'RecId'))
    if (-not $recId) { $recId = "rec_legacy_${date}_$rank`_$trackId" }
    $createdAt = [string](Get-OptionalProperty $Row 'created_at' (Get-OptionalProperty $Row 'CreatedAt'))
    if (-not $createdAt) { $createdAt = Get-NowIso }
    $updatedAt = [string](Get-OptionalProperty $Row 'updated_at' (Get-OptionalProperty $Row 'UpdatedAt' $createdAt))
    $preview = ConvertTo-Json -InputObject @(Get-OptionalProperty $Row 'preview_sources' (Get-OptionalProperty $Row 'PreviewSources' @())) -Compress -Depth 10
    $liked = if (Test-LegacyPositive (Get-OptionalProperty $Row 'liked' (Get-OptionalProperty $Row 'Liked' $false))) { 1 } else { 0 }
    $identifiers = if ($neteaseId) { ConvertTo-Json -InputObject @([pscustomobject]@{ type = 'netease'; value = $neteaseId }) -Compress -Depth 10 } else { '[]' }
    $params = @{
        d = ConvertTo-MusicServerSqlLiteral $date; r = ConvertTo-MusicServerSqlLiteral $rank; rid = ConvertTo-MusicServerSqlLiteral $recId
        tid = ConvertTo-MusicServerSqlLiteral $trackId; nid = ConvertTo-MusicServerSqlLiteral $neteaseId; title = ConvertTo-MusicServerSqlLiteral $title
        artist = ConvertTo-MusicServerSqlLiteral $artist; album = ConvertTo-MusicServerSqlLiteral $album; dur = ConvertTo-MusicServerSqlLiteral $duration
        reason = ConvertTo-MusicServerSqlLiteral $reason; ss = ConvertTo-MusicServerSqlLiteral $seedSource; ps = ConvertTo-MusicServerSqlLiteral $playback
        preview = ConvertTo-MusicServerSqlLiteral $preview; liked = ConvertTo-MusicServerSqlLiteral $liked; cat = ConvertTo-MusicServerSqlLiteral $createdAt; uat = ConvertTo-MusicServerSqlLiteral $updatedAt
    }
    $canonicalParams = @{
        id = ConvertTo-MusicServerSqlLiteral $trackId; title = ConvertTo-MusicServerSqlLiteral $title; artist = ConvertTo-MusicServerSqlLiteral $artist; album = ConvertTo-MusicServerSqlLiteral $album
        dur = ConvertTo-MusicServerSqlLiteral $duration; ident = ConvertTo-MusicServerSqlLiteral $identifiers; preview = ConvertTo-MusicServerSqlLiteral $preview; now = ConvertTo-MusicServerSqlLiteral $createdAt
    }
    [void]$Statements.Add("INSERT INTO canonical_tracks (id,title,artist,album,duration,cover_url,identifiers_json,preview_sources_json,download_candidates_json,local_song_id,status,created_at,updated_at,revision) VALUES ($($canonicalParams.id),$($canonicalParams.title),$($canonicalParams.artist),$($canonicalParams.album),$($canonicalParams.dur),'',$($canonicalParams.ident),$($canonicalParams.preview),'[]','','REMOTE',$($canonicalParams.now),$($canonicalParams.now),1) ON CONFLICT(id) DO UPDATE SET title=excluded.title, artist=excluded.artist, album=excluded.album, duration=excluded.duration, identifiers_json=excluded.identifiers_json, preview_sources_json=excluded.preview_sources_json, created_at=canonical_tracks.created_at, updated_at=excluded.updated_at, revision=canonical_tracks.revision")
    [void]$Statements.Add("INSERT OR IGNORE INTO daily_recommendations (date,rank,rec_id,track_id,netease_id,title,artist,album,duration,reason,seed_source,playback_source,preview_sources_json,liked,created_at,updated_at) VALUES ($($params.d),$($params.r),$($params.rid),$($params.tid),$($params.nid),$($params.title),$($params.artist),$($params.album),$($params.dur),$($params.reason),$($params.ss),$($params.ps),$($params.preview),$($params.liked),$($params.cat),$($params.uat))")
    Add-MigrationDisplayStatement -Statements $Statements -TrackId $trackId -Date $date -Rank $rank -RecId $recId -CreatedAt $createdAt
    if ($liked -eq 1) {
        $likeValue = New-LegacyMetadataValue -LegacyKey "legacy_like:$date`:$rank`:$trackId" -Title $title -Artist $artist -NeteaseId $neteaseId -Positive $true
        Add-MigrationFeedbackStatement -Statements $Statements -TrackId $trackId -FeedbackType 'LIKE' -Source 'legacy_json' -Value $likeValue -CreatedAt $createdAt
        $Report.imported.explicit_likes++
    }
    return $true
}

function Invoke-MusicServerMigration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Config,
        [switch]$DryRun,
        [int]$FailAfterStep = 0
    )
    $report = [ordered]@{
        status = 'PENDING'; source_counts = @{}; database_counts = @{}; imported = @{}; skipped = 0
        legacy_ignored = @(); conflicts = 0; conflict_details = @(); backup_path = ''; idempotent = $false
    }
    $dbPath = Join-Path $Config.StateDir 'musicserver.db'
    if (-not (Test-Path -LiteralPath $dbPath)) { $report.status = 'NO_DB'; return $report }
    if ($DryRun) { Connect-MusicServerDatabase -DbPath $dbPath -SqliteExe $Config.Sqlite }

    $marker = @()
    try {
        $marker = @(Invoke-MusicServerParamSql -Template 'SELECT source_key FROM migration_markers WHERE source_key = @key LIMIT 1;' -Params @{ key = $script:RecommendationMigrationKey })
    } catch {
        # A production database from before Phase 4 has no marker table yet.
        # Keep migration -DryRun genuinely read-only: treat that as an absent
        # marker and let the legacy readers produce their preview report. A
        # normal migration still fails loudly unless the caller initialized
        # the current schema first (daily_recommend does that).
        $markerError = [string]$_.Exception.Message
        if (-not $DryRun -or $markerError -notmatch 'migration_markers') { throw }
    }
    if ($marker.Count -gt 0) {
        $report.status = 'ALREADY_MIGRATED'
        $report.idempotent = $true
        return $report
    }

    # Databases created by the Phase 3 API/worker already contain canonical
    # tracks but have no legacy recommendation files to import. Preserve the
    # pre-marker idempotent behavior for that case; when any legacy source is
    # present, continue so the one-time import can still reconcile it.
    $legacySources = @(
        (Join-Path $Config.StateDir 'tracks.json'),
        (Join-Path $Config.StateDir 'recommendations.json'),
        (Join-Path $Config.StateDir 'recommendation_history.json'),
        (Join-Path $Config.StateDir 'wanted.json'),
        (Join-Path $Config.StateDir 'providers.json'),
        (Join-Path $Config.StateDir 'events.jsonl'),
        (Join-Path $Config.DataDir 'accepted.csv'),
        (Join-Path $Config.DataDir 'rejected.csv'),
        (Join-Path $Config.Root 'lyrics_report.csv')
    )
    $hasLegacySource = $false
    foreach ($sourcePath in $legacySources) {
        if (Test-Path -LiteralPath $sourcePath) {
            try {
                if ((Get-Item -LiteralPath $sourcePath).Length -gt 0) { $hasLegacySource = $true; break }
            } catch {
                $hasLegacySource = $true
                break
            }
        }
    }
    if (-not $hasLegacySource) {
        $existing = @(Invoke-MusicServerParamSql -Template 'SELECT COUNT(*) AS cnt FROM canonical_tracks;' -Params @{})
        if ($existing.Count -gt 0 -and [int]$existing[0].cnt -gt 0) {
            $report.status = 'ALREADY_MIGRATED'
            $report.idempotent = $true
            return $report
        }
    }

    $jsonTracks = @(Read-LegacyCollectionSafe -Config $Config -Name tracks -Report $report)
    $jsonRecs = @(Read-LegacyCollectionSafe -Config $Config -Name recommendations -Report $report)
    $jsonHistory = @(Read-LegacyCollectionSafe -Config $Config -Name recommendation_history -Report $report)
    $jsonWanted = @(Read-LegacyCollectionSafe -Config $Config -Name wanted -Report $report)
    $jsonProviders = @(Read-LegacyCollectionSafe -Config $Config -Name providers -Report $report)
    $legacyEvents = @(Read-LegacyEventsSafe -Path (Join-Path $Config.StateDir 'events.jsonl') -Report $report)
    $acceptedRows = @(Read-LegacyCsvSafe -Path (Join-Path $Config.DataDir 'accepted.csv') -Label 'accepted.csv' -Report $report)
    $rejectedRows = @(Read-LegacyCsvSafe -Path (Join-Path $Config.DataDir 'rejected.csv') -Label 'rejected.csv' -Report $report)
    $lyricsRows = @(Read-LegacyCsvSafe -Path (Join-Path $Config.Root 'lyrics_report.csv') -Label 'lyrics_report.csv' -Report $report)
    $report.source_counts = @{
        tracks = $jsonTracks.Count; recommendations = $jsonRecs.Count; history = $jsonHistory.Count; wanted = $jsonWanted.Count; providers = $jsonProviders.Count; events = $legacyEvents.Count
        accepted = $acceptedRows.Count; rejected = $rejectedRows.Count; lyrics_fallback = $lyricsRows.Count
    }
    if ($DryRun) {
        $report.status = 'DRY_RUN'
        $report.database_counts = [ordered]@{}
        foreach ($table in @('canonical_tracks','daily_recommendations','recommendation_feedback','wanted_queue','provider_health','events')) {
            try {
                $rows = @(Invoke-MusicServerParamSql -Template ("SELECT COUNT(*) AS cnt FROM $table;") -Params @{})
                $report.database_counts[$table] = if ($rows.Count -gt 0) { [int]$rows[0].cnt } else { 0 }
            } catch { $report.database_counts[$table] = $null }
        }
        $report.imported = @{ tracks = 0; recommendations = 0; history = 0; wanted = 0; providers = 0; events = 0; accepted = 0; rejected = 0; lyrics_fallback = 0; display = 0; explicit_likes = 0 }
        $previewStatements = New-Object System.Collections.Generic.List[string]
        foreach ($rec in $jsonRecs) { if (Add-MigrationDailyRecommendationStatement -Statements $previewStatements -Row $rec -Report $report) { $report.imported.recommendations++; $report.imported.display++ } }
        foreach ($hist in $jsonHistory) { if (Add-MigrationDailyRecommendationStatement -Statements $previewStatements -Row $hist -Report $report) { $report.imported.history++; $report.imported.display++ } }
        foreach ($row in $acceptedRows) {
            $title = [string](Get-OptionalProperty $row 'Title'); $neteaseId = [string](Get-OptionalProperty $row 'NeteaseId')
            if (-not $title -and -not $neteaseId) { $report.legacy_ignored += 'malformed accepted.csv row: title and NeteaseId missing'; continue }
            $report.imported.accepted++
        }
        foreach ($row in $rejectedRows) {
            $title = [string](Get-OptionalProperty $row 'Title'); $neteaseId = [string](Get-OptionalProperty $row 'NeteaseId')
            if (-not $title -and -not $neteaseId) { $report.legacy_ignored += 'malformed rejected.csv row: title and NeteaseId missing'; continue }
            $report.imported.rejected++
        }
        $invalidLyrics = 0
        foreach ($row in $lyricsRows) {
            $matched = [string](Get-OptionalProperty $row 'Matched'); $status = [string](Get-OptionalProperty $row 'Status')
            if ($matched -and $status -in @('OK','NO_LYRIC')) { $report.imported.lyrics_fallback++ } else { $invalidLyrics++ }
        }
        if ($invalidLyrics -gt 0) { $report.legacy_ignored += "ignored lyrics_report rows: $invalidLyrics" }
        foreach ($track in $jsonTracks) {
            if ([string](Get-OptionalProperty $track 'id')) { $report.imported.tracks++ } else { $report.legacy_ignored += 'malformed tracks.json row: id missing' }
        }
        foreach ($wanted in $jsonWanted) {
            if ([string](Get-OptionalProperty $wanted 'track_id')) { $report.imported.wanted++ } else { $report.legacy_ignored += 'malformed wanted.json row: track_id missing' }
        }
        foreach ($prov in $jsonProviders) {
            $providerName = [string](Get-OptionalProperty $prov 'provider')
            if ($providerName -in @('local','bilibili_search','bilibili_download','bilibili')) { $report.imported.providers++ }
            else { $report.legacy_ignored += "unknown provider: $providerName" }
            if ($providerName -eq 'bilibili') { $report.legacy_ignored += 'legacy provider: bilibili' }
        }
        foreach ($event in $legacyEvents) { if (Add-MigrationEventStatement -Statements $previewStatements -Event $event -Report $report) { $report.imported.events++ } }
        $report.imported.explicit_likes = [int]$report.imported.explicit_likes
        $conflictDetails = New-Object System.Collections.Generic.List[string]
        foreach ($track in $jsonTracks) {
            $trackId = [string](Get-OptionalProperty $track 'id')
            if (-not $trackId) { continue }
            try { if (@(Invoke-MusicServerParamSql -Template 'SELECT id FROM canonical_tracks WHERE id = @id LIMIT 1;' -Params @{ id = $trackId }).Count -gt 0) { $report.conflicts++; if ($conflictDetails.Count -lt 25) { [void]$conflictDetails.Add("canonical:$trackId") } } } catch {}
        }
        foreach ($rec in @($jsonRecs) + @($jsonHistory)) {
            $date = [string](Get-OptionalProperty $rec 'date' (Get-OptionalProperty $rec 'Date'))
            $rank = Convert-LegacyInt -Value (Get-OptionalProperty $rec 'rank' (Get-OptionalProperty $rec 'Rank' 0)) -Default 0
            if (-not $date -or $rank -le 0) { continue }
            try { if (@(Invoke-MusicServerParamSql -Template 'SELECT rec_id FROM daily_recommendations WHERE date = @date AND rank = @rank LIMIT 1;' -Params @{ date = $date; rank = $rank }).Count -gt 0) { $report.conflicts++; if ($conflictDetails.Count -lt 25) { [void]$conflictDetails.Add("daily:$date`:$rank") } } } catch {}
        }
        $report.conflict_details = @($conflictDetails)
        return $report
    }

    $backupDir = Join-Path $Config.StateDir "migration_backup_$([DateTime]::UtcNow.ToString('yyyyMMdd_HHmmss'))"
    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
    foreach ($src in @(
        (Join-Path $Config.StateDir 'tracks.json'), (Join-Path $Config.StateDir 'recommendations.json'),
        (Join-Path $Config.StateDir 'recommendation_history.json'), (Join-Path $Config.StateDir 'wanted.json'),
        (Join-Path $Config.StateDir 'providers.json'), (Join-Path $Config.StateDir 'events.jsonl'),
        (Join-Path $Config.DataDir 'accepted.csv'), (Join-Path $Config.DataDir 'rejected.csv'),
        (Join-Path $Config.Root 'lyrics_report.csv')
    )) {
        if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $backupDir ([IO.Path]::GetFileName($src))) -Force }
    }
    $report.backup_path = $backupDir

    $statements = New-Object System.Collections.Generic.List[string]
    $importedTracks = 0; $importedRecs = 0; $importedHistory = 0; $importedWanted = 0; $importedProviders = 0
    $importedAccepted = 0; $importedRejected = 0; $importedLyrics = 0; $importedEvents = 0; $displayCount = 0; $skipped = 0; $conflicts = 0
    $report.imported = @{ tracks = 0; recommendations = 0; history = 0; wanted = 0; providers = 0; events = 0; accepted = 0; rejected = 0; lyrics_fallback = 0; display = 0; explicit_likes = 0 }

    foreach ($track in $jsonTracks) {
        $trackId = [string](Get-OptionalProperty $track 'id')
        if (-not $trackId) { $report.legacy_ignored += 'malformed tracks.json row: id missing'; continue }
        $identifiers = ConvertTo-Json -InputObject @(Get-OptionalProperty $track 'identifiers' @()) -Compress -Depth 10
        $preview = ConvertTo-Json -InputObject @(Get-OptionalProperty $track 'preview_sources' @()) -Compress -Depth 10
        $candidates = ConvertTo-Json -InputObject @(Get-OptionalProperty $track 'download_candidates' @()) -Compress -Depth 10
        $existing = @(Invoke-MusicServerParamSql -Template 'SELECT id FROM canonical_tracks WHERE id = @id LIMIT 1;' -Params @{ id = $trackId })
        if ($existing.Count -gt 0) { $skipped++; $conflicts++; continue }
        $now = Get-NowIso
        $p = @{
            id = ConvertTo-MusicServerSqlLiteral $trackId; title = ConvertTo-MusicServerSqlLiteral ([string](Get-OptionalProperty $track 'title')); artist = ConvertTo-MusicServerSqlLiteral ([string](Get-OptionalProperty $track 'artist')); album = ConvertTo-MusicServerSqlLiteral ([string](Get-OptionalProperty $track 'album')); dur = ConvertTo-MusicServerSqlLiteral (Convert-LegacyInt -Value (Get-OptionalProperty $track 'duration' 0) -Report $report -Label "track duration for $trackId"); cover = ConvertTo-MusicServerSqlLiteral ([string](Get-OptionalProperty $track 'cover_url')); ident = ConvertTo-MusicServerSqlLiteral $identifiers; preview = ConvertTo-MusicServerSqlLiteral $preview; candidates = ConvertTo-MusicServerSqlLiteral $candidates; local = ConvertTo-MusicServerSqlLiteral ([string](Get-OptionalProperty $track 'local_song_id')); status = ConvertTo-MusicServerSqlLiteral ([string](Get-OptionalProperty $track 'status' 'REMOTE')); created = ConvertTo-MusicServerSqlLiteral ([string](Get-OptionalProperty $track 'created_at' $now)); updated = ConvertTo-MusicServerSqlLiteral ([string](Get-OptionalProperty $track 'updated_at' $now))
        }
        [void]$statements.Add("INSERT OR IGNORE INTO canonical_tracks (id,title,artist,album,duration,cover_url,identifiers_json,preview_sources_json,download_candidates_json,local_song_id,status,created_at,updated_at,revision) VALUES ($($p.id),$($p.title),$($p.artist),$($p.album),$($p.dur),$($p.cover),$($p.ident),$($p.preview),$($p.candidates),$($p.local),$($p.status),$($p.created),$($p.updated),1)")
        $importedTracks++
    }

    foreach ($rec in $jsonRecs) { if (Add-MigrationDailyRecommendationStatement -Statements $statements -Row $rec -Report $report) { $importedRecs++; $displayCount++ } }
    foreach ($hist in $jsonHistory) { if (Add-MigrationDailyRecommendationStatement -Statements $statements -Row $hist -Report $report) { $importedHistory++; $displayCount++ } }

    foreach ($row in $acceptedRows) {
        $title = [string](Get-OptionalProperty $row 'Title'); $artist = [string](Get-OptionalProperty $row 'Artist'); $neteaseId = [string](Get-OptionalProperty $row 'NeteaseId'); $file = [string](Get-OptionalProperty $row 'File'); $at = [string](Get-OptionalProperty $row 'AcceptedAt')
        if (-not $title -and -not $neteaseId) { $report.legacy_ignored += 'malformed accepted.csv row: title and NeteaseId missing'; continue }
        $trackId = Get-LegacyTrackId -Row ([pscustomobject]@{ Title = $title; Artist = $artist; NeteaseId = $neteaseId })
        $key = "accepted:$at`:$neteaseId`:$title`:$artist`:$file"
        $value = New-LegacyMetadataValue -LegacyKey $key -Title $title -Artist $artist -NeteaseId $neteaseId -File $file -AcceptedAt $at -Positive $true
        $created = if ($at) { $at } else { Get-NowIso }
        Add-MigrationFeedbackStatement -Statements $statements -TrackId $trackId -FeedbackType 'ACCEPTED' -Source 'legacy_accepted_csv' -Value $value -CreatedAt $created
        $importedAccepted++
    }
    foreach ($row in $rejectedRows) {
        $title = [string](Get-OptionalProperty $row 'Title'); $artist = [string](Get-OptionalProperty $row 'Artist'); $neteaseId = [string](Get-OptionalProperty $row 'NeteaseId'); $at = [string](Get-OptionalProperty $row 'RejectedAt')
        if (-not $title -and -not $neteaseId) { $report.legacy_ignored += 'malformed rejected.csv row: title and NeteaseId missing'; continue }
        $trackId = Get-LegacyTrackId -Row ([pscustomobject]@{ Title = $title; Artist = $artist; NeteaseId = $neteaseId })
        $key = "rejected:$at`:$neteaseId`:$title`:$artist"
        $value = New-LegacyMetadataValue -LegacyKey $key -Title $title -Artist $artist -NeteaseId $neteaseId -AcceptedAt $at -Positive $true
        $created = if ($at) { $at } else { Get-NowIso }
        Add-MigrationFeedbackStatement -Statements $statements -TrackId $trackId -FeedbackType 'REJECTED' -Source 'legacy_rejected_csv' -Value $value -CreatedAt $created
        $importedRejected++
    }
    foreach ($row in $lyricsRows) {
        $matched = [string](Get-OptionalProperty $row 'Matched'); $artist = [string](Get-OptionalProperty $row 'MatchedArtist'); $status = [string](Get-OptionalProperty $row 'Status')
        if (-not $matched -or $status -notin @('OK','NO_LYRIC')) { continue }
        $trackId = Get-CanonicalTrackId -Title $matched -Artist $artist
        $file = [string](Get-OptionalProperty $row 'File')
        $value = New-LegacyMetadataValue -LegacyKey "lyrics:$file`:$matched`:$artist" -Title $matched -Artist $artist -File $file -Positive $true
        Add-MigrationFeedbackStatement -Statements $statements -TrackId $trackId -FeedbackType 'LIBRARY_FALLBACK' -Source 'legacy_lyrics_report' -Value $value -CreatedAt (Get-NowIso)
        $importedLyrics++
    }

    foreach ($w in $jsonWanted) {
        $trackId = [string](Get-OptionalProperty $w 'track_id')
        if (-not $trackId) { $report.legacy_ignored += 'malformed wanted.json row: track_id missing'; continue }
        $existing = @(Invoke-MusicServerParamSql -Template 'SELECT track_id FROM wanted_queue WHERE track_id = @tid LIMIT 1;' -Params @{ tid = $trackId })
        if ($existing.Count -gt 0) { $skipped++; $conflicts++; continue }
        $selected = ''; $selectedValue = Get-OptionalProperty $w 'selected_candidate' $null
        if ($null -ne $selectedValue) { $selected = ConvertTo-Json -InputObject $selectedValue -Compress -Depth 10 }
        $p = @{
            tid = ConvertTo-MusicServerSqlLiteral $trackId; wid = ConvertTo-MusicServerSqlLiteral ([string](Get-OptionalProperty $w 'id')); state = ConvertTo-MusicServerSqlLiteral ([string](Get-OptionalProperty $w 'state' 'WANTED')); attempts = ConvertTo-MusicServerSqlLiteral (Convert-LegacyInt -Value (Get-OptionalProperty $w 'attempts' 0) -Report $report -Label "wanted attempts for $trackId"); max = ConvertTo-MusicServerSqlLiteral (Convert-LegacyInt -Value (Get-OptionalProperty $w 'max_attempts' 5) -Default 5 -Report $report -Label "wanted max_attempts for $trackId"); retry = ConvertTo-MusicServerSqlLiteral ([string](Get-OptionalProperty $w 'next_retry_at')); selected = ConvertTo-MusicServerSqlLiteral $selected; error = ConvertTo-MusicServerSqlLiteral ([string](Get-OptionalProperty $w 'last_error')); created = ConvertTo-MusicServerSqlLiteral ([string](Get-OptionalProperty $w 'created_at' (Get-NowIso))); updated = ConvertTo-MusicServerSqlLiteral ([string](Get-OptionalProperty $w 'updated_at' (Get-NowIso)))
        }
        [void]$statements.Add("INSERT INTO wanted_queue (track_id,wanted_id,state,attempt_count,max_attempts,next_retry_at,selected_candidate_json,last_error,revision,created_at,updated_at) VALUES ($($p.tid),$($p.wid),$($p.state),$($p.attempts),$($p.max),$($p.retry),$($p.selected),$($p.error),1,$($p.created),$($p.updated))")
        $importedWanted++
    }

    $validProviders = @('local','bilibili_search','bilibili_download')
    foreach ($prov in $jsonProviders) {
        $pname = [string]$prov.provider
        if ($pname -eq 'bilibili') { $report.legacy_ignored += 'legacy provider: bilibili (HALF_OPEN); merged into bilibili_search'; $pname = 'bilibili_search' }
        if ($pname -notin $validProviders) { $report.legacy_ignored += "unknown provider: $pname"; continue }
        $probeValue = if (Get-OptionalProperty $prov 'probe_pending' $false) { 1 } else { 0 }
        $p = @{
            provider = ConvertTo-MusicServerSqlLiteral $pname; state = ConvertTo-MusicServerSqlLiteral ([string](Get-OptionalProperty $prov 'state' 'CLOSED')); success = ConvertTo-MusicServerSqlLiteral (Convert-LegacyInt -Value (Get-OptionalProperty $prov 'success_count' 0) -Report $report -Label "provider success_count for $pname"); failure = ConvertTo-MusicServerSqlLiteral (Convert-LegacyInt -Value (Get-OptionalProperty $prov 'failure_count' 0) -Report $report -Label "provider failure_count for $pname"); cf = ConvertTo-MusicServerSqlLiteral (Convert-LegacyInt -Value (Get-OptionalProperty $prov 'consecutive_failures' 0) -Report $report -Label "provider consecutive_failures for $pname"); c412 = ConvertTo-MusicServerSqlLiteral (Convert-LegacyInt -Value (Get-OptionalProperty $prov 'consecutive_412' 0) -Report $report -Label "provider consecutive_412 for $pname"); ls = ConvertTo-MusicServerSqlLiteral ([string](Get-OptionalProperty $prov 'last_success')); lf = ConvertTo-MusicServerSqlLiteral ([string](Get-OptionalProperty $prov 'last_failure')); l412 = ConvertTo-MusicServerSqlLiteral ([string](Get-OptionalProperty $prov 'last_412_at')); blocked = ConvertTo-MusicServerSqlLiteral ([string](Get-OptionalProperty $prov 'blocked_until')); latency = ConvertTo-MusicServerSqlLiteral (Convert-LegacyDouble -Value (Get-OptionalProperty $prov 'average_latency_ms' 0) -Report $report -Label "provider average_latency_ms for $pname"); probe = ConvertTo-MusicServerSqlLiteral $probeValue; now = ConvertTo-MusicServerSqlLiteral (Get-NowIso)
        }
        [void]$statements.Add("INSERT OR REPLACE INTO provider_health (provider,state,success_count,failure_count,consecutive_failures,consecutive_412,last_success,last_failure,last_412_at,blocked_until,average_latency_ms,half_open_probe_claimed,last_error,revision,updated_at) VALUES ($($p.provider),$($p.state),$($p.success),$($p.failure),$($p.cf),$($p.c412),$($p.ls),$($p.lf),$($p.l412),$($p.blocked),$($p.latency),$($p.probe),'',1,$($p.now))")
        $importedProviders++
    }
    foreach ($event in $legacyEvents) {
        if (Add-MigrationEventStatement -Statements $statements -Event $event -Report $report) { $importedEvents++ }
    }

    $markerValue = ConvertTo-MusicServerSqlLiteral '{"phase":"recommendation_state_v2"}'
    $markerTime = ConvertTo-MusicServerSqlLiteral (Get-NowIso)
    $message = "tracks=$importedTracks; recs=$importedRecs; history=$importedHistory; accepted=$importedAccepted; rejected=$importedRejected; lyrics=$importedLyrics; wanted=$importedWanted; providers=$importedProviders; events=$importedEvents"
    [void]$statements.Add("INSERT INTO events (event_type,message,result,created_at) VALUES ('MIGRATION_COMPLETED',$(ConvertTo-MusicServerSqlLiteral $message),'SUCCESS',$markerTime)")
    [void]$statements.Add("INSERT INTO migration_markers (source_key,imported_at,result_json) VALUES ($(ConvertTo-MusicServerSqlLiteral $script:RecommendationMigrationKey),$markerTime,$markerValue)")
    try {
        [void](Invoke-StateAtomicSql -Statements $statements.ToArray() -FailAfterStep $FailAfterStep)
        $report.imported = @{ tracks = $importedTracks; recommendations = $importedRecs; history = $importedHistory; wanted = $importedWanted; providers = $importedProviders; events = $importedEvents; accepted = $importedAccepted; rejected = $importedRejected; lyrics_fallback = $importedLyrics; display = $displayCount; explicit_likes = [int]$report.imported.explicit_likes }
        $report.skipped = $skipped; $report.conflicts = $conflicts; $report.status = 'SUCCESS'
    } catch {
        $report.status = 'FAILED'; $report.error = $_.Exception.Message
    }
    return $report
}

Export-ModuleMember -Function *
