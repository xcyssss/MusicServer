<#
.SYNOPSIS
    MusicServer 的前端无关 HTTP API。
.DESCRIPTION
    like/unlike 只改变 CanonicalTrack 和 Wanted Queue 状态，立即返回；下载由 wanted_worker.ps1 异步处理。
.PARAMETER Prefix
    监听前缀，默认 http://127.0.0.1:8787/。
.PARAMETER Once
    处理一个请求后退出，便于冒烟测试。
.PARAMETER Root
    项目根目录；默认当前脚本所在目录，主要用于测试和迁移。
#>
param(
    [string]$Prefix = 'http://127.0.0.1:8787/',
    [switch]$Once,
    [string]$Root = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Import-Module (Join-Path $PSScriptRoot 'MusicServer.Core.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'MusicServer.Providers.psm1') -Force
$Config = New-MusicServerConfig -Root $Root
Initialize-MusicServerState -Config $Config
Import-LegacyRecommendationState -Config $Config | Out-Null

function Send-Json {
    param([Parameter(Mandatory)]$Context, [int]$StatusCode, [object]$Body)
    $json = ConvertTo-Json -InputObject $Body -Depth 20
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $Context.Response.StatusCode = $StatusCode
    $Context.Response.ContentType = 'application/json; charset=utf-8'
    $Context.Response.ContentEncoding = [Text.Encoding]::UTF8
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.Close()
}

function Get-TrackPlaybackSource {
    param([Parameter(Mandatory)][psobject]$Track, [Parameter(Mandatory)][string]$TrackId, [psobject]$Recommendation = $null)
    $local = Get-TrackLocalFile -Track $Track
    if ($local) {
        $localId = [string](Get-OptionalProperty $Track 'local_song_id')
        if (-not $localId) { $localId = Get-NavidromeSongIdForPath -Config $Config -Path $local.FullName }
        $streamUrl = if ($localId) { "/api/library/$localId/stream" } else { "/api/tracks/$TrackId/stream" }
        return [pscustomobject]@{
            provider = 'navidrome'; mode = 'local-bridge'; id = $localId
            url = $streamUrl; title = $Track.title; artist = $Track.artist
        }
    }
    $preview = @((Get-OptionalProperty $Track 'preview_sources')) | Select-Object -First 1
    if (-not $preview -and $Recommendation) { $preview = @((Get-OptionalProperty $Recommendation 'preview_sources')) | Select-Object -First 1 }
    if ($preview) {
        $url = if ((Get-OptionalProperty $preview 'media_url')) { [string]$preview.media_url } else { [string]$preview.url }
        return [pscustomobject]@{ provider = (Get-OptionalProperty $preview 'provider' 'remote'); mode = 'preview'; id = (Get-OptionalProperty $preview 'id'); url = $url; title = $Track.title; artist = $Track.artist }
    }
    return $null
}

function Get-TrackLocalFile {
    param([Parameter(Mandatory)][psobject]$Track)

    $localId = [string](Get-OptionalProperty $Track 'local_song_id')
    if ($localId) {
        $resolved = Get-NavidromeLibraryItem -Id $localId
        if ($resolved) { return [IO.FileInfo]$resolved.file }
    }

    $match = Find-LocalTrack -Config $Config -Title ([string]$Track.title) -Artist ([string]$Track.artist)
    if ($match) { return [IO.FileInfo]$match.File }
    return $null
}

function Get-TodayRecommendationResponse {
    $items = foreach ($recommendation in @(Get-TodayRecommendations -Config $Config)) {
        $track = Get-CanonicalTrack -Config $Config -TrackId ([string]$recommendation.track_id)
        if (-not $track) { continue }
        $wanted = @(Get-WantedTracks -Config $Config | Where-Object { [string]$_.track_id -eq [string]$recommendation.track_id } | Select-Object -First 1)
        $playback = Get-TrackPlaybackSource -Track $track -TrackId ([string]$recommendation.track_id) -Recommendation $recommendation
        [pscustomobject]@{
            id = $recommendation.id; date = $recommendation.date; track_id = $recommendation.track_id
            rank = $recommendation.rank; reason = $recommendation.reason; title = $track.title; artist = $track.artist
            album = $track.album; duration = $track.duration; cover_url = $track.cover_url
            track = $track; preview_source = @((Get-OptionalProperty $track 'preview_sources')) | Select-Object -First 1
            playback_source = $playback; liked = [bool](Get-OptionalProperty $recommendation 'liked' $false)
            stream_url = if ($playback -and $playback.provider -eq 'navidrome') { $playback.url } else { '' }
            lyrics_url = if ($playback -and $playback.provider -eq 'navidrome' -and $playback.id) { "/api/library/$($playback.id)/lyrics" } else { "/api/tracks/$($recommendation.track_id)/lyrics" }
            local_status = if ($playback -and $playback.provider -eq 'navidrome') { 'LOCAL' } else { (Get-OptionalProperty $track 'status' 'REMOTE') }; wanted = $wanted
        }
    }
    return @($items)
}

function Invoke-SqliteJson {
    param([Parameter(Mandatory)][string]$Query)

    if (-not (Test-Path -LiteralPath $Config.NdDb)) { return @() }
    $sqlite = [string]$Config.Sqlite
    if (-not (Get-Command $sqlite -ErrorAction SilentlyContinue)) {
        $fallback = 'C:\Users\dell\anaconda3\Library\bin\sqlite3.exe'
        if (Test-Path -LiteralPath $fallback) { $sqlite = $fallback } else { return @() }
    }

    $tmp = Join-Path ([IO.Path]::GetTempPath()) "musicserver_api_$([guid]::NewGuid().ToString('N')).db"
    try {
        Copy-Item -LiteralPath $Config.NdDb -Destination $tmp -Force
        foreach ($ext in @('-wal', '-shm')) {
            $sidecar = "$($Config.NdDb)$ext"
            if (Test-Path -LiteralPath $sidecar) {
                Copy-Item -LiteralPath $sidecar -Destination "$tmp$ext" -Force -ErrorAction SilentlyContinue
            }
        }
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $sqlite
        $escapedQuery = $Query.Replace('"', '\"')
        $startInfo.Arguments = "-json `"$tmp`" `"$escapedQuery`""
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        try { $startInfo.StandardOutputEncoding = [Text.UTF8Encoding]::new($false) } catch {}
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        $process.Start() | Out-Null
        $json = $process.StandardOutput.ReadToEnd()
        $process.StandardError.ReadToEnd() | Out-Null
        $process.WaitForExit()
        $exitCode = $process.ExitCode
        $process.Dispose()
        if ($exitCode -ne 0 -or [string]::IsNullOrWhiteSpace($json)) { return @() }
        if ([string]::IsNullOrWhiteSpace($json) -or $json -eq '[]') { return @() }
        $parsed = ConvertFrom-Json $json
        if ($parsed -is [Array]) {
            foreach ($item in $parsed) { Write-Output $item }
        } else {
            Write-Output $parsed
        }
    } catch {
        return @()
    } finally {
        Remove-Item -LiteralPath "$tmp*" -Force -ErrorAction SilentlyContinue
    }
}

function Resolve-LibraryFile {
    param([Parameter(Mandatory)][string]$RelativePath)

    $path = $RelativePath.Replace('/', '\')
    $fullPath = if ([IO.Path]::IsPathRooted($path)) { $path } else { Join-Path $Config.MusicDir $path }
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { return $null }
    return [IO.FileInfo](Get-Item -LiteralPath $fullPath -Force)
}

function Get-NavidromeLibrary {
    $query = @"
select m.id, m.path, m.title, m.album, m.artist, m.duration, m.genre,
       case when exists (
           select 1 from annotation a
           where a.item_id = m.id and a.item_type = 'media_file' and a.starred = 1
       ) then 1 else 0 end as starred
from media_file m
where m.missing = 0
order by lower(coalesce(m.artist, '')), lower(coalesce(m.title, '')), m.path;
"@
    $rows = @(Invoke-SqliteJson -Query $query)
    $items = foreach ($row in $rows) {
        $file = Resolve-LibraryFile -RelativePath ([string]$row.path)
        if (-not $file) { continue }
        $id = [string]$row.id
        [pscustomobject]@{
            id = $id; title = [string]$row.title; artist = [string]$row.artist
            album = [string]$row.album; genre = [string]$row.genre; duration = [double]$row.duration
            starred = [bool]([int]$row.starred); source = if ([string]$row.path -like 'DailyMix*') { 'DailyMix' } else { 'library' }
            stream_url = "/api/library/$id/stream"; lyrics_url = "/api/library/$id/lyrics"
        }
    }
    return @($items)
}

function Get-NavidromeLibraryItem {
    param([Parameter(Mandatory)][string]$Id)
    if ($Id -notmatch '^[A-Za-z0-9_-]+$') { return $null }
    $query = "select id, path, title, artist, album, duration from media_file where id = '$Id' and missing = 0 limit 1;"
    $row = @(Invoke-SqliteJson -Query $query) | Select-Object -First 1
    if (-not $row) { return $null }
    $file = Resolve-LibraryFile -RelativePath ([string]$row.path)
    if (-not $file) { return $null }
    return [pscustomobject]@{ row = $row; file = $file }
}

function Get-LyricsReportEntry {
    param([Parameter(Mandatory)][IO.FileInfo]$File)

    if ($null -eq $script:LyricsReportEntries) {
        $script:LyricsReportEntries = @{}
        $reportPath = Join-Path $Config.Root 'lyrics_report.csv'
        if (Test-Path -LiteralPath $reportPath -PathType Leaf) {
            foreach ($row in @(Import-Csv -LiteralPath $reportPath -ErrorAction SilentlyContinue)) {
                if ($row.File) { $script:LyricsReportEntries[[string]$row.File] = $row }
            }
        }
    }
    if ($script:LyricsReportEntries.ContainsKey($File.Name)) { return $script:LyricsReportEntries[$File.Name] }
    return $null
}

function Get-LyricsForFile {
    param([Parameter(Mandatory)][IO.FileInfo]$File)

    $report = Get-LyricsReportEntry -File $File
    $quality = if ($report -and $report.Status) { [string]$report.Status } else { 'UNREPORTED' }
    if ($quality -in @('SUSPECT', 'NO_MATCH', 'NO_LYRIC')) {
        return [pscustomobject]@{
            available = $false; format = ''; text = ''; quality = $quality
            message = '这首歌的歌词匹配度不足，已暂不显示，避免放错歌词。'
        }
    }

    $stem = Join-Path $File.DirectoryName $File.BaseName
    foreach ($extension in @('.lrc', '.txt')) {
        $lyricsPath = "$stem$extension"
        if (Test-Path -LiteralPath $lyricsPath -PathType Leaf) {
            try {
                $bytes = [IO.File]::ReadAllBytes($lyricsPath)
                try { $text = (New-Object Text.UTF8Encoding($false, $true)).GetString($bytes) }
                catch { $text = [Text.Encoding]::GetEncoding(936).GetString($bytes) }
                $text = $text.TrimStart([char]0xFEFF)
                return [pscustomobject]@{ available = $true; format = $extension.TrimStart('.'); text = $text; quality = $quality; message = '' }
            } catch { return [pscustomobject]@{ available = $false; format = ''; text = ''; quality = 'READ_ERROR'; message = '歌词文件无法读取。' } }
        }
    }
    return [pscustomobject]@{ available = $false; format = ''; text = ''; quality = 'MISSING'; message = '这首歌暂时没有找到本地歌词。' }
}

function Send-StaticFile {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][AllowEmptyString()][string]$RelativePath)
    $allowed = @{
        '' = 'index.html'; 'index.html' = 'index.html'; 'app.js' = 'app.js'; 'styles.css' = 'styles.css'
    }
    $key = $RelativePath.Trim('/')
    if (-not $allowed.ContainsKey($key)) { Send-Json -Context $Context -StatusCode 404 -Body @{ error = 'NOT_FOUND' }; return }
    $path = Join-Path (Join-Path $PSScriptRoot 'web') $allowed[$key]
    if (-not (Test-Path -LiteralPath $path)) { Send-Json -Context $Context -StatusCode 404 -Body @{ error = 'ASSET_NOT_FOUND' }; return }
    $bytes = [IO.File]::ReadAllBytes($path)
    $type = switch ([IO.Path]::GetExtension($path)) { '.html' { 'text/html; charset=utf-8' } '.js' { 'text/javascript; charset=utf-8' } '.css' { 'text/css; charset=utf-8' } default { 'application/octet-stream' } }
    $Context.Response.StatusCode = 200
    $Context.Response.ContentType = $type
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.Close()
}

function Send-AudioFile {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][IO.FileInfo]$File)

    $start = [int64]0; $end = $file.Length - 1; $status = 200
    $range = [string]$Context.Request.Headers['Range']
    if ($range -match '^bytes=(\d*)-(\d*)$') {
        if ($Matches[1]) { $start = [int64]$Matches[1] }
        if ($Matches[2]) { $end = [int64]$Matches[2] } else { $end = [Math]::Min($file.Length - 1, $start + 1024 * 1024 - 1) }
        if ($start -ge $file.Length -or $start -gt $end) { $Context.Response.StatusCode = 416; $Context.Response.Close(); return }
        $end = [Math]::Min($end, $file.Length - 1); $status = 206
    }
    $length = $end - $start + 1
    $Context.Response.StatusCode = $status
    $Context.Response.ContentType = switch ($File.Extension.ToLowerInvariant()) {
        '.m4a' { 'audio/mp4' }
        '.flac' { 'audio/flac' }
        '.ogg' { 'audio/ogg' }
        '.wav' { 'audio/wav' }
        default { 'audio/mpeg' }
    }
    $Context.Response.ContentLength64 = $length
    $Context.Response.Headers['Accept-Ranges'] = 'bytes'
    if ($status -eq 206) { $Context.Response.Headers['Content-Range'] = "bytes $start-$end/$($File.Length)" }
    $stream = [IO.File]::OpenRead($File.FullName)
    try {
        $stream.Position = $start
        $buffer = New-Object byte[] 65536
        $remaining = $length
        while ($remaining -gt 0) {
            $read = $stream.Read($buffer, 0, [int][Math]::Min($buffer.Length, $remaining))
            if ($read -le 0) { break }
            $Context.Response.OutputStream.Write($buffer, 0, $read)
            $remaining -= $read
        }
    } finally { $stream.Dispose(); $Context.Response.Close() }
}

function Send-LocalAudio {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$TrackId)
    $track = Get-CanonicalTrack -Config $Config -TrackId $TrackId
    if (-not $track) { Send-Json -Context $Context -StatusCode 404 -Body @{ error = 'TRACK_NOT_FOUND' }; return }
    $local = Find-LocalTrack -Config $Config -Title $track.title -Artist $track.artist
    if (-not $local) { Send-Json -Context $Context -StatusCode 404 -Body @{ error = 'LOCAL_AUDIO_NOT_FOUND' }; return }
    Send-AudioFile -Context $Context -File ([IO.FileInfo]$local.File)
}

function Send-LibraryAudio {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$LibraryId)
    $resolved = Get-NavidromeLibraryItem -Id $LibraryId
    if (-not $resolved) { Send-Json -Context $Context -StatusCode 404 -Body @{ error = 'LIBRARY_TRACK_NOT_FOUND' }; return }
    Send-AudioFile -Context $Context -File $resolved.file
}

function Get-TrackResponse {
    param([string]$TrackId)
    $track = Get-CanonicalTrack -Config $Config -TrackId $TrackId
    if (-not $track) { return $null }
    $recommendation = @(Read-StateCollection -Config $Config -Name recommendation_history |
        Where-Object { [string]$_.track_id -eq $TrackId } | Sort-Object date -Descending | Select-Object -First 1)
    $wanted = @(Get-WantedTracks -Config $Config | Where-Object { [string]$_.track_id -eq $TrackId } | Select-Object -First 1)
    $playback = Get-TrackPlaybackSource -Track $track -TrackId $TrackId -Recommendation ($recommendation | Select-Object -First 1)
    return [pscustomobject]@{ track = $track; recommendation = $recommendation; wanted = $wanted; playback_source = $playback; local_status = if ($playback -and $playback.provider -eq 'navidrome') { 'LOCAL' } else { (Get-OptionalProperty $track 'status' 'REMOTE') } }
}

function Get-TrackLyricsResponse {
    param([Parameter(Mandatory)][string]$TrackId)
    $track = Get-CanonicalTrack -Config $Config -TrackId $TrackId
    if (-not $track) { return $null }
    $local = Get-TrackLocalFile -Track $track
    if (-not $local) { return [pscustomobject]@{ track_id = $TrackId; available = $false; format = ''; text = ''; quality = 'MISSING'; message = '这首歌暂时没有找到本地歌词。' } }
    $lyrics = Get-LyricsForFile -File $local
    return [pscustomobject]@{ track_id = $TrackId; available = $lyrics.available; format = $lyrics.format; text = $lyrics.text; quality = $lyrics.quality; message = $lyrics.message }
}

function Get-LibraryLyricsResponse {
    param([Parameter(Mandatory)][string]$LibraryId)
    $resolved = Get-NavidromeLibraryItem -Id $LibraryId
    if (-not $resolved) { return $null }
    $lyrics = Get-LyricsForFile -File $resolved.file
    return [pscustomobject]@{ library_id = $LibraryId; available = $lyrics.available; format = $lyrics.format; text = $lyrics.text; quality = $lyrics.quality; message = $lyrics.message }
}

function Read-RequestBody {
    param($Context)
    if ($Context.Request.ContentLength64 -le 0) { return $null }
    $reader = New-Object IO.StreamReader($Context.Request.InputStream, $Context.Request.ContentEncoding)
    try { $raw = $reader.ReadToEnd() } finally { $reader.Dispose() }
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    try { return ConvertFrom-Json $raw } catch { return $null }
}

function Handle-Request {
    param($Context)
    $method = $Context.Request.HttpMethod.ToUpperInvariant()
    $segments = @($Context.Request.Url.AbsolutePath.Trim('/') -split '/' | Where-Object { $_ } |
        ForEach-Object { [Uri]::UnescapeDataString($_) })
    try {
        if ($method -eq 'GET' -and $segments.Count -le 1 -and $segments[0] -notin @('api','health')) {
            Send-StaticFile -Context $Context -RelativePath ([string]$Context.Request.Url.AbsolutePath.Trim('/'))
            return
        }
        if ($method -eq 'GET' -and $segments.Count -eq 3 -and $segments[0] -eq 'api' -and $segments[1] -eq 'recommendations' -and $segments[2] -eq 'today') {
            Send-Json -Context $Context -StatusCode 200 -Body ([pscustomobject]@{ date = Get-TodayDate; items = @(Get-TodayRecommendationResponse) })
            return
        }
        if ($method -eq 'GET' -and $segments.Count -eq 2 -and $segments[0] -eq 'api' -and $segments[1] -eq 'library') {
            $items = @(Get-NavidromeLibrary)
            Send-Json -Context $Context -StatusCode 200 -Body ([pscustomobject]@{ count = $items.Count; items = $items })
            return
        }
        if ($method -eq 'GET' -and $segments.Count -eq 4 -and $segments[0] -eq 'api' -and $segments[1] -eq 'library' -and $segments[3] -eq 'stream') {
            Send-LibraryAudio -Context $Context -LibraryId $segments[2]
            return
        }
        if ($method -eq 'GET' -and $segments.Count -eq 4 -and $segments[0] -eq 'api' -and $segments[1] -eq 'library' -and $segments[3] -eq 'lyrics') {
            $lyrics = Get-LibraryLyricsResponse -LibraryId $segments[2]
            if (-not $lyrics) { Send-Json -Context $Context -StatusCode 404 -Body @{ error = 'LIBRARY_TRACK_NOT_FOUND' } }
            else { Send-Json -Context $Context -StatusCode 200 -Body $lyrics }
            return
        }
        if ($method -eq 'GET' -and $segments.Count -eq 4 -and $segments[0] -eq 'api' -and $segments[1] -eq 'tracks' -and $segments[3] -eq 'stream') {
            Send-LocalAudio -Context $Context -TrackId $segments[2]
            return
        }
        if ($method -eq 'GET' -and $segments.Count -eq 3 -and $segments[0] -eq 'api' -and $segments[1] -eq 'tracks') {
            $body = Get-TrackResponse -TrackId $segments[2]
            if (-not $body) { Send-Json -Context $Context -StatusCode 404 -Body @{ error = 'TRACK_NOT_FOUND' } }
            else { Send-Json -Context $Context -StatusCode 200 -Body $body }
            return
        }
        if ($method -eq 'GET' -and $segments.Count -eq 4 -and $segments[0] -eq 'api' -and $segments[1] -eq 'tracks' -and $segments[3] -eq 'lyrics') {
            $lyrics = Get-TrackLyricsResponse -TrackId $segments[2]
            if (-not $lyrics) { Send-Json -Context $Context -StatusCode 404 -Body @{ error = 'TRACK_NOT_FOUND' } }
            else { Send-Json -Context $Context -StatusCode 200 -Body $lyrics }
            return
        }
        if ($segments.Count -eq 4 -and $segments[0] -eq 'api' -and $segments[1] -eq 'tracks' -and $segments[3] -eq 'like' -and $method -in @('POST','DELETE')) {
            if (-not (Get-CanonicalTrack -Config $Config -TrackId $segments[2])) { Send-Json -Context $Context -StatusCode 404 -Body @{ error = 'TRACK_NOT_FOUND' }; return }
            $liked = $method -eq 'POST'
            $result = Set-TrackLike -Config $Config -TrackId $segments[2] -Liked $liked
            Send-Json -Context $Context -StatusCode 200 -Body ([pscustomobject]@{ accepted = $true; liked = $liked; track_id = $segments[2]; wanted = $result.wanted })
            return
        }
        if ($method -eq 'GET' -and $segments.Count -eq 2 -and $segments[0] -eq 'api' -and $segments[1] -eq 'wanted') {
            Send-Json -Context $Context -StatusCode 200 -Body ([pscustomobject]@{ items = @(Get-WantedTracks -Config $Config) })
            return
        }
        if ($method -eq 'POST' -and (($segments.Count -eq 3 -and $segments[0] -eq 'api' -and $segments[1] -eq 'wanted') -or ($segments.Count -eq 4 -and $segments[0] -eq 'api' -and $segments[1] -eq 'wanted' -and $segments[3] -eq 'retry'))) {
            $trackId = $segments[2]
            if (-not (Get-CanonicalTrack -Config $Config -TrackId $trackId)) { Send-Json -Context $Context -StatusCode 404 -Body @{ error = 'TRACK_NOT_FOUND' }; return }
            $wanted = @(Get-WantedTracks -Config $Config | Where-Object { [string]$_.track_id -eq $trackId } | Select-Object -First 1)
            if (-not $wanted) { $wanted = Add-WantedTrack -Config $Config -TrackId $trackId }
            else { $wanted.state = 'WANTED'; $wanted.next_retry_at = $null; $wanted.last_error = ''; Save-WantedTrack -Config $Config -Wanted $wanted | Out-Null }
            Set-TrackStatus -Config $Config -TrackId $trackId -Status 'WANTED' | Out-Null
            Send-Json -Context $Context -StatusCode 202 -Body ([pscustomobject]@{ accepted = $true; queued = $true; wanted = $wanted })
            return
        }
        if ($method -eq 'GET' -and $segments.Count -eq 3 -and $segments[0] -eq 'api' -and $segments[1] -eq 'providers' -and $segments[2] -eq 'status') {
            Send-Json -Context $Context -StatusCode 200 -Body ([pscustomobject]@{ items = @(Get-ProviderStatuses -Config $Config) })
            return
        }
        if ($method -eq 'GET' -and $segments.Count -eq 1 -and $segments[0] -eq 'health') {
            Send-Json -Context $Context -StatusCode 200 -Body @{ status = 'ok' }
            return
        }
        Send-Json -Context $Context -StatusCode 404 -Body @{ error = 'NOT_FOUND' }
    } catch {
        try { Send-Json -Context $Context -StatusCode 500 -Body @{ error = 'INTERNAL_ERROR'; message = $_.Exception.Message } } catch {}
    }
}

$listener = [Net.HttpListener]::new()
$listener.Prefixes.Add($Prefix)
try {
    $listener.Start()
    Write-Host "MusicServer API listening on $Prefix" -ForegroundColor Green
    do {
        $context = $listener.GetContext()
        Handle-Request -Context $context
        if ($Once) { break }
    } while ($true)
} finally {
    if ($listener.IsListening) { $listener.Stop() }
    $listener.Close()
}
