# Online discovery owns its bounded SQLite cache; it never edits the daily mix.
function Initialize-OnlineSearchSchema {
    Invoke-MusicServerSqlNonQuery -Query @'
CREATE TABLE IF NOT EXISTS online_searches (
 id TEXT PRIMARY KEY, query TEXT NOT NULL, state TEXT NOT NULL,
 error_code TEXT NOT NULL DEFAULT '', created_at TEXT NOT NULL, expires_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS online_search_results (
 search_id TEXT NOT NULL REFERENCES online_searches(id) ON DELETE CASCADE,
 rank INTEGER NOT NULL, track_id TEXT NOT NULL REFERENCES canonical_tracks(id),
 PRIMARY KEY(search_id, track_id)
);
'@
    $columns=@(Invoke-MusicServerSqlJson -Query 'PRAGMA table_info(online_searches);')
    if (-not ($columns | Where-Object { $_.name -eq 'source' })) {
        Invoke-MusicServerSqlNonQuery -Query "ALTER TABLE online_searches ADD COLUMN source TEXT NOT NULL DEFAULT 'netease';" | Out-Null
    }
}

function ConvertTo-OnlineSearchQuery {
    param([AllowNull()][object]$Query)
    if ($Query -isnot [string] -or $Query.Length -gt 80 -or $Query -match '[\x00-\x1f\x7f]') { return '' }
    return ($Query.Trim() -replace '\s+', ' ')
}

function ConvertFrom-OnlineSearchSongs {
    param([AllowEmptyCollection()][object[]]$Songs)
    $seen = @{}
    foreach ($song in @($Songs | Select-Object -First 20)) {
        if (-not $song) { continue }
        $id = [string](Get-OptionalProperty $song 'id')
        $title = [string](Get-OptionalProperty $song 'name')
        $credits = @(Get-OptionalProperty $song 'artists' (Get-OptionalProperty $song 'ar' @()))
        $artist = (@($credits | ForEach-Object { [string](Get-OptionalProperty $_ 'name') } | Where-Object { $_ }) -join ',')
        $album = Get-OptionalProperty $song 'album' (Get-OptionalProperty $song 'al' $null)
        $durationMs = 0.0
        if (-not [double]::TryParse([string](Get-OptionalProperty $song 'duration' (Get-OptionalProperty $song 'dt' 0)), [ref]$durationMs)) { continue }
        if ($id -notmatch '^[1-9][0-9]{0,18}$' -or $seen.ContainsKey($id) -or -not $title.Trim() -or -not $artist -or $title.Length -gt 250 -or $artist.Length -gt 300 -or $durationMs -lt 1000 -or $durationMs -gt 86400000) { continue }
        $seen[$id] = $true
        $preview = @([pscustomobject]@{ provider='netease'; id=$id; media_url="https://music.163.com/song/media/outer/url?id=$id.mp3" })
        New-CanonicalTrack -Title $title -Artist $artist -Album ([string](Get-OptionalProperty $album 'name')) -Duration ([int][math]::Round($durationMs / 1000)) `
            -Identifiers @([pscustomobject]@{type='netease';value=$id}) -PreviewSources $preview
    }
}

function Save-OnlineSearchResultsDb {
    param([string]$SearchId, [AllowEmptyCollection()][object[]]$Tracks)
    # INSERT only: a second search cannot reset a local binding, an active
    # download or preference. Exact provider identity also joins existing picks.
    $sql = New-Object Text.StringBuilder
    [void]$sql.AppendLine('BEGIN IMMEDIATE;')
    $sid = ConvertTo-MusicServerSqlLiteral $SearchId
    $rank = 0
    foreach ($track in $Tracks) {
        $rank++
        $identity=$track.identifiers[0]
        $kind = ConvertTo-MusicServerSqlLiteral ([string]$identity.type)
        $nid = ConvertTo-MusicServerSqlLiteral ([string]$identity.value)
        $base = ConvertTo-MusicServerSqlLiteral ([string]$track.id)
        $alternative = ConvertTo-MusicServerSqlLiteral ('track_' + [string]$identity.type + '_' + [string]$identity.value)
        $existing = "SELECT t.id FROM canonical_tracks t, json_each(t.identifiers_json) j WHERE json_extract(j.value,'$.type')=$kind AND CAST(json_extract(j.value,'$.value') AS TEXT)=$nid ORDER BY t.id LIMIT 1"
        $newId = "CASE WHEN EXISTS(SELECT 1 FROM canonical_tracks WHERE id=$base) THEN $alternative ELSE $base END"
        $values = @($track.title,$track.artist,$track.album,$track.duration,'',(ConvertTo-MusicServerJsonArrayText $track.identifiers),(ConvertTo-MusicServerJsonArrayText $track.preview_sources),(ConvertTo-MusicServerJsonArrayText $track.download_candidates),'','REMOTE',0,$track.created_at,$track.updated_at,1) | ForEach-Object { ConvertTo-MusicServerSqlLiteral $_ }
        [void]$sql.AppendLine("INSERT OR IGNORE INTO canonical_tracks (id,title,artist,album,duration,cover_url,identifiers_json,preview_sources_json,download_candidates_json,local_song_id,status,release_year,created_at,updated_at,revision) SELECT $newId,$($values -join ',') WHERE NOT EXISTS($existing) AND EXISTS(SELECT 1 FROM online_searches WHERE id=$sid AND state='RUNNING');")
        [void]$sql.AppendLine("INSERT OR IGNORE INTO online_search_results(search_id,rank,track_id) SELECT $sid,$rank,($existing) WHERE EXISTS(SELECT 1 FROM online_searches WHERE id=$sid AND state='RUNNING');")
    }
    [void]$sql.AppendLine("UPDATE online_searches SET state='DONE' WHERE id=$sid AND state='RUNNING';")
    [void]$sql.AppendLine('COMMIT;')
    Invoke-MusicServerSqlNonQuery -Query $sql.ToString() | Out-Null
}

function Invoke-OnlineMusicSearch {
    param([psobject]$Config, [string]$SearchId, [string]$Query, [string]$Source = 'netease')
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $code = ''; $count = 0
    try {
        if ($Source -eq 'bilibili') {
            $result=Search-BilibiliCandidates -Config $Config -Track ([pscustomobject]@{title=$Query;artist=''}) -Query $Query -Limit 20 -TimeoutSeconds 17
            if ($result.Error) { $code=[string]$result.Error; throw $code }
            $tracks=@(ConvertFrom-BilibiliSearchCandidates -Candidates @($result.Candidates))
        } else {
            if (-not (Claim-ProviderRequest -Config $Config -Provider 'netease')) { $code='PROVIDER_UNAVAILABLE'; throw $code }
            try {
                $response = Invoke-RestMethod -Uri "https://music.163.com/api/search/get?s=$([uri]::EscapeDataString($Query))&type=1&limit=20" `
                    -Headers @{'Referer'='https://music.163.com/';'User-Agent'='Mozilla/5.0'} -TimeoutSec 7
                if ([int](Get-OptionalProperty $response 'code' 0) -ne 200 -or -not $response.result) { throw 'INVALID_SEARCH_RESPONSE' }
                $tracks = @(ConvertFrom-OnlineSearchSongs -Songs @(Get-OptionalProperty $response.result 'songs' @()))
                Record-ProviderSuccess -Config $Config -Provider 'netease' -LatencyMs $clock.Elapsed.TotalMilliseconds | Out-Null
            } catch {
                $code='SEARCH_UNAVAILABLE'
                Record-ProviderFailure -Config $Config -Provider 'netease' -ErrorType $code -Message 'online discovery request failed' | Out-Null
                throw
            }
        }
        Save-OnlineSearchResultsDb -SearchId $SearchId -Tracks $tracks
        $count=$tracks.Count
    } catch {
        if (-not $code) { $code='SEARCH_FAILED' }
        Invoke-MusicServerParamNonQuery -Template "UPDATE online_searches SET state='ERROR',error_code=@code WHERE id=@id AND state='RUNNING';" -Params @{id=$SearchId;code=$code} | Out-Null
    } finally {
        Write-MusicServerLog -Path (Join-Path $Config.LogDir 'musicserver-api.log') -Message ("[search] id={0} source={1} count={2} error={3} elapsed_ms={4}" -f $SearchId,$Source,$count,$code,[int]$clock.Elapsed.TotalMilliseconds)
    }
}

function Complete-OnlineSearchJobs {
    if (-not $script:OnlineJobs) { $script:OnlineJobs = New-Object Collections.ArrayList }
    foreach ($job in @($script:OnlineJobs)) {
        if ($job.Async.IsCompleted) {
            try { $job.PowerShell.EndInvoke($job.Async) | Out-Null } catch {}
            $job.PowerShell.Dispose(); [void]$script:OnlineJobs.Remove($job)
        } elseif (-not $job.Stopping -and ([DateTime]::UtcNow - $job.Started).TotalSeconds -gt 20) {
            [void]$job.PowerShell.BeginStop($null,$null); $job.Stopping=$true
        }
    }
}

function Start-OnlineMusicSearch {
    param([psobject]$Config, [object]$Query, [object]$Source = 'netease')
    $queryText = ConvertTo-OnlineSearchQuery $Query
    if (-not $queryText) { return @{Status=400;Body=@{error='INVALID_QUERY';message='请输入 1–80 个字符的歌名或歌手。'}} }
    if ($Source -isnot [string] -or $Source -notin @('netease','bilibili')) { return @{Status=400;Body=@{error='INVALID_SOURCE';message='请选择网易云或 B 站。'}} }
    Complete-OnlineSearchJobs
    $now=Get-NowIso
    Invoke-MusicServerParamNonQuery -Template "UPDATE online_searches SET state='ERROR',error_code='SEARCH_TIMEOUT' WHERE state='RUNNING' AND expires_at < @now; DELETE FROM online_searches WHERE created_at < @cutoff;" -Params @{now=$now;cutoff=[DateTime]::UtcNow.AddDays(-1).ToString('o')} | Out-Null
    $existing=@(Invoke-MusicServerParamSql -Template "SELECT id FROM online_searches WHERE query=@query AND source=@source AND ((state='RUNNING' AND expires_at>@now) OR (state='DONE' AND created_at>@cache)) ORDER BY created_at DESC LIMIT 1;" -Params @{source=$Source;query=$queryText;now=$now;cache=[DateTime]::UtcNow.AddMinutes(-10).ToString('o')})
    if ($existing.Count) { return @{Status=202;Body=@{id=[string]$existing[0].id}} }
    if ($script:OnlineJobs.Count -ge 2) { return @{Status=429;Body=@{error='SEARCH_BUSY';message='正在完成上一次搜索，请稍后再试。'}} }
    $id=[guid]::NewGuid().ToString('N')
    Invoke-MusicServerParamNonQuery -Template "INSERT INTO online_searches(id,query,source,state,created_at,expires_at) VALUES(@id,@query,@source,'RUNNING',@now,@expires);" -Params @{id=$id;source=$Source;query=$queryText;now=$now;expires=[DateTime]::UtcNow.AddSeconds(20).ToString('o')} | Out-Null
    $ps=[PowerShell]::Create()
    try {
        [void]$ps.AddScript({
            param($root,$config,$id,$queryText,$source)
            try { [Console]::OutputEncoding=[Text.Encoding]::UTF8 } catch {}
            foreach ($name in @('Core','Providers','Database','State','Search')) { Import-Module (Join-Path $root "MusicServer.$name.psm1") -DisableNameChecking }
            Connect-MusicServerDatabase -DbPath (Join-Path $config.StateDir 'musicserver.db') -SqliteExe $config.Sqlite
            Invoke-OnlineMusicSearch -Config $config -SearchId $id -Query $queryText -Source $source
        }).AddArgument($PSScriptRoot).AddArgument($Config).AddArgument($id).AddArgument($queryText).AddArgument($Source)
        $async=$ps.BeginInvoke()
        [void]$script:OnlineJobs.Add([pscustomobject]@{PowerShell=$ps;Async=$async;Started=[DateTime]::UtcNow;Stopping=$false})
    } catch {
        $ps.Dispose()
        Invoke-MusicServerParamNonQuery -Template "UPDATE online_searches SET state='ERROR',error_code='SEARCH_FAILED' WHERE id=@id;" -Params @{id=$id} | Out-Null
    }
    return @{Status=202;Body=@{id=$id}}
}

function Get-OnlineMusicSearch {
    param([string]$SearchId)
    Complete-OnlineSearchJobs
    Invoke-MusicServerParamNonQuery -Template "UPDATE online_searches SET state='ERROR',error_code='SEARCH_TIMEOUT' WHERE id=@id AND state='RUNNING' AND expires_at<@now;" -Params @{id=$SearchId;now=(Get-NowIso)} | Out-Null
    $rows=@(Invoke-MusicServerParamSql -Template 'SELECT * FROM online_searches WHERE id=@id;' -Params @{id=$SearchId})
    if (-not $rows.Count) { return $null }
    $search=$rows[0]; $items=@()
    if ($search.state -eq 'DONE') {
        $tracks=@(Invoke-MusicServerParamSql -Template 'SELECT t.* FROM online_search_results r JOIN canonical_tracks t ON t.id=r.track_id WHERE r.search_id=@id ORDER BY r.rank;' -Params @{id=$SearchId})
        $prefs=Get-TrackPreferenceMapDb
        $items=@(foreach ($row in $tracks) {
            $track=Convert-DbTrackRow -Row $row
            [pscustomobject]@{track_id=$track.id;title=$track.title;artist=$track.artist;album=$track.album;duration=$track.duration;track=$track;
                liked=($prefs[$track.id] -eq 'LIKE');local_status=$track.status;preview_source=@($track.preview_sources | Select-Object -First 1)[0]}
        })
    }
    $provider = if ($search.source -eq 'bilibili') { 'bilibili_search' } else { 'netease' }
    $health = Get-ProviderHealthDb -Provider $provider
    return @{id=$SearchId;query=$search.query;state=$search.state;error=$search.error_code;source=$search.source;items=$items;retry_at=$health.blocked_until}
}

function ConvertFrom-BilibiliSearchCandidates {
    param([AllowEmptyCollection()][object[]]$Candidates)
    $seen=@{}
    foreach ($entry in @($Candidates | Select-Object -First 20)) {
        $bvid=[string](Get-OptionalProperty $entry 'bvid')
        $title=[string](Get-OptionalProperty $entry 'title')
        if ($bvid -cnotmatch '^BV[0-9A-Za-z]{10}$' -or $seen.ContainsKey($bvid) -or -not $title.Trim() -or $title.Length -gt 250) { continue }
        $seen[$bvid]=$true
        $seconds=[int](Get-OptionalProperty $entry 'duration' 0)
        if ($seconds -lt 1 -or $seconds -gt 86400) { continue }
        $metadata=Get-OptionalProperty $entry 'metadata'
        $uploader=[string](Get-OptionalProperty $metadata 'uploader' (Get-OptionalProperty $metadata 'channel' ''))
        $url="https://www.bilibili.com/video/$bvid"
        # The listener chose this exact video. UP accounts are attribution, not singers.
        New-CanonicalTrack -TrackId "track_bilibili_$bvid" -Title $title -Duration $seconds `
            -Identifiers @([pscustomobject]@{type='bilibili';value=$bvid}) `
            -PreviewSources @([pscustomobject]@{provider='bilibili';bvid=$bvid;webpage_url=$url;uploader=$uploader}) `
            -DownloadCandidates @([pscustomobject]@{provider='bilibili_direct';bvid=$bvid;url=$url;title=$title;artist='';duration=$seconds;priority=80;requires_search=$false})
    }
}

Export-ModuleMember -Function *
