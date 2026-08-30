Set-StrictMode -Version 3.0

# MusicServer.Migration.psm1 - JSON to SQLite migration
# Non-destructive, transactional, idempotent.

Import-Module (Join-Path $PSScriptRoot 'MusicServer.Database.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'MusicServer.Core.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'MusicServer.State.psm1') -Force

function Invoke-MusicServerMigration {
    param(
        [Parameter(Mandatory)][psobject]$Config,
        [switch]$DryRun
    )
    $report = [ordered]@{
        status = 'PENDING'; source_counts = @{}; imported = @{}; skipped = @()
        legacy_ignored = @(); conflicts = 0; backup_path = ''; idempotent = $false
    }
    $dbPath = Join-Path $Config.StateDir 'musicserver.db'
    if (-not (Test-Path -LiteralPath $dbPath)) {
        $report.status = 'NO_DB'
        return $report
    }
    $existingTracks = @(Invoke-MusicServerSqlJson -Query 'SELECT COUNT(*) as cnt FROM canonical_tracks;')
    $existingCount = 0
    if ($existingTracks.Count -gt 0 -and $existingTracks[0] -is [pscustomobject]) {
        $p = $existingTracks[0].PSObject.Properties['cnt']
        if ($p) { $existingCount = [int]$p.Value }
    }
    if ($existingCount -gt 0) {
        $report.status = 'ALREADY_MIGRATED'
        $report.idempotent = $true
        return $report
    }
    $jsonTracks = @(Read-StateCollection -Config $Config -Name tracks)
    $jsonRecs = @(Read-StateCollection -Config $Config -Name recommendations)
    $jsonHistory = @(Read-StateCollection -Config $Config -Name recommendation_history)
    $jsonWanted = @(Read-StateCollection -Config $Config -Name wanted)
    $jsonProviders = @(Read-StateCollection -Config $Config -Name providers)
    $report.source_counts = @{
        tracks = $jsonTracks.Count; recommendations = $jsonRecs.Count
        history = $jsonHistory.Count; wanted = $jsonWanted.Count
        providers = $jsonProviders.Count
    }
    if ($DryRun) {
        $report.status = 'DRY_RUN'
        $report.imported = @{
            tracks = $jsonTracks.Count; recommendations = $jsonRecs.Count
            history = $jsonHistory.Count; wanted = $jsonWanted.Count
            providers = $jsonProviders.Count
        }
        foreach ($p in $jsonProviders) {
            $pname = [string]$p.provider
            if ($pname -eq 'bilibili') {
                $report.legacy_ignored += "legacy provider: $pname"
            }
        }
        return $report
    }
    $backupDir = Join-Path $Config.StateDir "migration_backup_$([DateTime]::UtcNow.ToString('yyyyMMdd_HHmmss'))"
    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
    foreach ($name in @('tracks','recommendations','recommendation_history','wanted','providers','events.jsonl')) {
        $src = Join-Path $Config.StateDir "$name.json"
        if ($name -eq 'events.jsonl') { $src = Join-Path $Config.StateDir 'events.jsonl' }
        if (Test-Path -LiteralPath $src) {
            Copy-Item -LiteralPath $src -Destination (Join-Path $backupDir ([IO.Path]::GetFileName($src))) -Force
        }
    }
    $report.backup_path = $backupDir
    $validProviders = @('local','bilibili_search','bilibili_download')
    try {
        $importedTracks = 0; $importedRecs = 0; $importedHistory = 0
        $importedWanted = 0; $importedProviders = 0; $skipped = 0; $conflicts = 0
            foreach ($track in $jsonTracks) {
                $identifiers = ConvertTo-Json -InputObject @(Get-OptionalProperty $track 'identifiers' @()) -Compress -Depth 10
                $preview = ConvertTo-Json -InputObject @(Get-OptionalProperty $track 'preview_sources' @()) -Compress -Depth 10
                $candidates = ConvertTo-Json -InputObject @(Get-OptionalProperty $track 'download_candidates' @()) -Compress -Depth 10
                $existing = @(Invoke-MusicServerParamSql -Template 'SELECT id FROM canonical_tracks WHERE id = @id LIMIT 1;' -Params @{ id = [string]$track.id })
                if ($existing.Count -gt 0) { $skipped++; continue }
                Invoke-MusicServerParamNonQuery -Template @"
INSERT INTO canonical_tracks (id, title, artist, album, duration, cover_url,
    identifiers_json, preview_sources_json, download_candidates_json,
    local_song_id, status, created_at, updated_at, revision)
VALUES (@id, @title, @artist, @album, @dur, @cover,
    @ident, @preview, @candidates,
    @lsid, @status, @cat, @uat, 1);
"@ -Params @{
                    id = [string]$track.id; title = [string]$track.title; artist = [string](Get-OptionalProperty $track 'artist')
                    album = [string](Get-OptionalProperty $track 'album'); dur = [int](Get-OptionalProperty $track 'duration')
                    cover = [string](Get-OptionalProperty $track 'cover_url'); ident = $identifiers
                    preview = $preview; candidates = $candidates
                    lsid = [string](Get-OptionalProperty $track 'local_song_id')
                    status = [string](Get-OptionalProperty $track 'status' 'REMOTE')
                    cat = [string](Get-OptionalProperty $track 'created_at')
                    uat = [string](Get-OptionalProperty $track 'updated_at')
                }
                $importedTracks++
            }
            foreach ($rec in $jsonRecs) {
                $preview = ConvertTo-Json -InputObject @(Get-OptionalProperty $rec 'preview_sources' @()) -Compress -Depth 10
                $liked = if (Get-OptionalProperty $rec 'liked' $false) { 1 } else { 0 }
                Invoke-MusicServerParamNonQuery -Template @"
INSERT OR IGNORE INTO daily_recommendations (date, rank, rec_id, track_id, netease_id,
    title, artist, album, duration, reason, seed_source, playback_source,
    preview_sources_json, liked, created_at, updated_at)
VALUES (@d, @r, @rid, @tid, @nid, @title, @artist, @album, @dur, @reason,
    @ss, @ps, @preview, @liked, @cat, @uat);
"@ -Params @{
                    d = [string](Get-OptionalProperty $rec 'date'); r = [int](Get-OptionalProperty $rec 'rank')
                    rid = [string](Get-OptionalProperty $rec 'id'); tid = [string](Get-OptionalProperty $rec 'track_id')
                    nid = [string](Get-OptionalProperty $rec 'netease_id'); title = [string](Get-OptionalProperty $rec 'title')
                    artist = [string](Get-OptionalProperty $rec 'artist'); album = [string](Get-OptionalProperty $rec 'album')
                    dur = [int](Get-OptionalProperty $rec 'duration'); reason = [string](Get-OptionalProperty $rec 'reason')
                    ss = [string](Get-OptionalProperty $rec 'seed_source'); ps = [string](Get-OptionalProperty $rec 'playback_source')
                    preview = $preview; liked = $liked
                    cat = [string](Get-OptionalProperty $rec 'created_at')
                    uat = [string](Get-OptionalProperty $rec 'updated_at')
                }
                $importedRecs++
            }
            foreach ($hist in $jsonHistory) {
                $preview = ConvertTo-Json -InputObject @(Get-OptionalProperty $hist 'preview_sources' @()) -Compress -Depth 10
                $liked = if (Get-OptionalProperty $hist 'liked' $false) { 1 } else { 0 }
                Invoke-MusicServerParamNonQuery -Template @"
INSERT OR IGNORE INTO daily_recommendations (date, rank, rec_id, track_id, netease_id,
    title, artist, album, duration, reason, seed_source, playback_source,
    preview_sources_json, liked, created_at, updated_at)
VALUES (@d, @r, @rid, @tid, @nid, @title, @artist, @album, @dur, @reason,
    @ss, @ps, @preview, @liked, @cat, @uat);
"@ -Params @{
                    d = [string](Get-OptionalProperty $hist 'date'); r = [int](Get-OptionalProperty $hist 'rank')
                    rid = [string](Get-OptionalProperty $hist 'id'); tid = [string](Get-OptionalProperty $hist 'track_id')
                    nid = [string](Get-OptionalProperty $hist 'netease_id'); title = [string](Get-OptionalProperty $hist 'title')
                    artist = [string](Get-OptionalProperty $hist 'artist'); album = [string](Get-OptionalProperty $hist 'album')
                    dur = [int](Get-OptionalProperty $hist 'duration'); reason = [string](Get-OptionalProperty $hist 'reason')
                    ss = [string](Get-OptionalProperty $hist 'seed_source'); ps = [string](Get-OptionalProperty $hist 'playback_source')
                    preview = $preview; liked = $liked
                    cat = [string](Get-OptionalProperty $hist 'created_at')
                    uat = [string](Get-OptionalProperty $hist 'updated_at')
                }
                $importedHistory++
            }
            foreach ($w in $jsonWanted) {
                $selected = ''
                $wSel = Get-OptionalProperty $w 'selected_candidate' $null
                if ($null -ne $wSel) { $selected = ConvertTo-Json -InputObject $wSel -Compress -Depth 10 }
                $existing = @(Invoke-MusicServerParamSql -Template 'SELECT track_id FROM wanted_queue WHERE track_id = @tid LIMIT 1;' -Params @{ tid = [string]$w.track_id })
                if ($existing.Count -gt 0) { $skipped++; $conflicts++; continue }
                Invoke-MusicServerParamNonQuery -Template @"
INSERT INTO wanted_queue (track_id, wanted_id, state, attempt_count, max_attempts,
    next_retry_at, selected_candidate_json, last_error, revision, created_at, updated_at)
VALUES (@tid, @wid, @state, @ac, @ma, @nrt, @sel, @err, 1, @cat, @uat);
"@ -Params @{
                    tid = [string]$w.track_id; wid = [string]$w.id; state = [string]$w.state
                    ac = [int](Get-OptionalProperty $w 'attempts'); ma = [int](Get-OptionalProperty $w 'max_attempts' 5)
                    nrt = [string](Get-OptionalProperty $w 'next_retry_at')
                    sel = $selected; err = [string](Get-OptionalProperty $w 'last_error')
                    cat = [string](Get-OptionalProperty $w 'created_at')
                    uat = [string](Get-OptionalProperty $w 'updated_at')
                }
                $importedWanted++
            }
            foreach ($prov in $jsonProviders) {
                $pname = [string]$prov.provider
                if ($pname -eq 'bilibili') {
                    $report.legacy_ignored += "legacy provider: $pname (HALF_OPEN); merged into bilibili_search"
                    $searchHealth = Get-ProviderHealthDb -Provider 'bilibili_search'
                    if ($searchHealth.state -eq 'CLOSED' -and $searchHealth.failure_count -eq 0) {
                        $prov.state = 'HALF_OPEN'
                        $prov.probe_pending = $false
                    } else { continue }
                    $pname = 'bilibili_search'
                }
                if ($pname -notin $validProviders) { $report.legacy_ignored += "unknown provider: $pname"; continue }
                Invoke-MusicServerParamNonQuery -Template @"
INSERT OR REPLACE INTO provider_health (provider, state, success_count, failure_count,
    consecutive_failures, consecutive_412, last_success, last_failure, last_412_at,
    blocked_until, average_latency_ms, half_open_probe_claimed, last_error, revision, updated_at)
VALUES (@p, @state, @sc, @fc, @cf, @c412, @ls, @lf, @l412, @bu, @alm, @hpp, '', 1, @now);
"@ -Params @{
                    p = $pname; state = [string]$prov.state
                    sc = [int](Get-OptionalProperty $prov 'success_count')
                    fc = [int](Get-OptionalProperty $prov 'failure_count')
                    cf = [int](Get-OptionalProperty $prov 'consecutive_failures')
                    c412 = [int](Get-OptionalProperty $prov 'consecutive_412')
                    ls = [string](Get-OptionalProperty $prov 'last_success')
                    lf = [string](Get-OptionalProperty $prov 'last_failure')
                    l412 = [string](Get-OptionalProperty $prov 'last_412_at')
                    bu = [string](Get-OptionalProperty $prov 'blocked_until')
                    alm = [double](Get-OptionalProperty $prov 'average_latency_ms')
                    hpp = if (Get-OptionalProperty $prov 'probe_pending' $false) { 1 } else { 0 }
                    now = (Get-NowIso)
                }
                $importedProviders++
            }
            $report.imported = @{
                tracks = $importedTracks; recommendations = $importedRecs
                history = $importedHistory; wanted = $importedWanted
                providers = $importedProviders
            }
            $report.skipped = $skipped
            $report.conflicts = $conflicts
            $report.status = 'SUCCESS'
            Write-MusicServerEventDb -EventType 'MIGRATION_COMPLETED' -Message "tracks=$importedTracks; recs=$importedRecs; history=$importedHistory; wanted=$importedWanted; providers=$importedProviders; skipped=$skipped"
    } catch {
        $report.status = 'FAILED'
        $report.error = $_.Exception.Message
    }
    return $report
}

Export-ModuleMember -Function *
