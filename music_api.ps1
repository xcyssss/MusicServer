# music_api.ps1 - 音乐服务器的前端无关 HTTP API（v2 / Phase 3）。
# ------------------------------------------------------------------
# Phase 3 契约：
#   - SQLite 是唯一的运行时状态真源。JSON 仅用于迁移输入 / 备份 / 兼容镜像，
#     运行时请求路径绝不读取旧 JSON 状态（tracks.json / wanted.json / ...）。
#   - 所有状态写入经由 MusicServer.State 层的事务函数
#     （Invoke-LikeTrackTransactionDb / Invoke-UnlikeTrackTransactionDb），
#     API 内不散落 SQL。
#   - Web UI 路由与响应主键保持不变：
#       GET  /api/today            -> { items=[...] }
#       GET  /api/library          -> { items=[...] }
#       GET  /api/library/{id}/stream | /api/library/{id}/lyrics
#       GET  /api/tracks/{id}      -> { track, recommendation, wanted, liked, playback_source, local_status }
#       GET  /api/tracks/{id}/lyrics
#       POST/DELETE /api/tracks/{id}/like -> { accepted, liked, track_id, action, wanted }
#       GET  /api/wanted           -> { items=[...] , total }
#       POST /api/wanted           -> 202 { accepted, queued, wanted }
#       POST /api/wanted/{id}      -> 202 { accepted, queued, wanted }
#       POST /api/wanted/{id}/retry -> 202 { accepted, queued, wanted }
#       POST /api/wanted/{id}/cancel -> { accepted, action, wanted }
#       GET  /api/providers/status -> { items=[local, bilibili_search, bilibili_download] }
#       GET  /health               -> { status='ok', ... }
# ------------------------------------------------------------------
param(
    [string]$Prefix = 'http://127.0.0.1:8787/',
    [switch]$Once,
    [string]$Root = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue } catch {}

# 固定启动顺序：Core -> Providers -> Database -> State。
# 所有 -Force 导入必须在 Initialize-MusicServerDatabase 之前完成（模块实例重置律）。
# Legacy migration is an explicit maintenance action owned by daily_recommend.ps1;
# API startup must never import or rewrite legacy recommendation state.
Import-Module (Join-Path $PSScriptRoot 'MusicServer.Core.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'MusicServer.Providers.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'MusicServer.Database.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'MusicServer.State.psm1') -Force

$Config = New-MusicServerConfig -Root $Root
Initialize-MusicServerState -Config $Config
$DbPath = Join-Path $Config.StateDir 'musicserver.db'
$SqliteExe = [string]$Config.Sqlite
if (-not $SqliteExe -or -not (Test-Path -LiteralPath $SqliteExe)) {
    $cmd = Get-Command sqlite3.exe -ErrorAction SilentlyContinue
    if ($cmd) { $SqliteExe = $cmd.Source }
    else {
        $cmd = Get-Command sqlite3 -ErrorAction SilentlyContinue
        if ($cmd) { $SqliteExe = $cmd.Source }
        elseif (Test-Path -LiteralPath 'C:\Users\dell\anaconda3\Library\bin\sqlite3.exe') {
            $SqliteExe = 'C:\Users\dell\anaconda3\Library\bin\sqlite3.exe'
        }
    }
}
if (-not (Test-Path -LiteralPath $SqliteExe) -and -not (Get-Command $SqliteExe -ErrorAction SilentlyContinue)) {
    throw "SQLite3 executable not found: $SqliteExe"
}
Initialize-MusicServerDatabase -DbPath $DbPath -SqliteExe $SqliteExe
Initialize-MusicServerSchema
Write-Host ("API v2 ready | db={0} | migration=NOT_REQUESTED" -f $DbPath) -ForegroundColor Green

function Send-Json([psobject]$Context) {
    $body = $Context.Body
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Depth 20))
    $Context.Response.ContentType = 'application/json; charset=utf-8'
    $Context.Response.StatusCode = [int]$Context.StatusCode
    $Context.Response.ContentLength64 = $bodyBytes.Length
    $Context.Response.OutputStream.Write($bodyBytes, 0, $bodyBytes.Length)
    $Context.Response.OutputStream.Close()
}

function Get-TrackPlaybackSource {
    param(
        [Parameter(Mandatory)][psobject]$Track,
        [string]$TrackId = '',
        [AllowNull()][psobject]$Recommendation = $null
    )
    $trackId = if ($TrackId) { $TrackId } else { [string](Get-OptionalProperty $Track 'id') }
    $localFile = Get-TrackLocalFile -Track $Track -TrackId $trackId
    if (-not $localFile) {
        $recommendationPreview = $null
        if ($Recommendation) { $recommendationPreview = @(Get-OptionalProperty $Recommendation 'preview_sources' @()) | Where-Object { [string](Get-OptionalProperty $_ 'media_url') } | Select-Object -First 1 }
        $preview = @(Get-OptionalProperty $Track 'preview_sources' @()) | Where-Object { [string](Get-OptionalProperty $_ 'media_url') } | Select-Object -First 1
        $previewSource = if ($recommendationPreview) { $recommendationPreview } else { $preview }
        if ($previewSource) {
            return [pscustomobject]@{
                provider = 'bilibili'
                url      = [string](Get-OptionalProperty $previewSource 'media_url')
                title    = [string](Get-OptionalProperty $Track 'title')
                artist   = [string](Get-OptionalProperty $Track 'artist')
                type     = 'preview'
                id       = ''
            }
        }
        return $null
    }
    $libraryId = Get-NavidromeLibraryId -File $localFile
    return [pscustomobject]@{
        provider = 'navidrome'
        url      = "/api/library/{0}/stream" -f $libraryId
        file     = $localFile
        title    = [string](Get-OptionalProperty $Track 'title')
        artist   = [string](Get-OptionalProperty $Track 'artist')
        type     = 'local'
        id       = $libraryId
    }
}

function Get-TrackLocalFile {
    param([Parameter(Mandatory)][psobject]$Track, [string]$TrackId = '')
    $trackId = if ($TrackId) { $TrackId } else { [string](Get-OptionalProperty $Track 'id') }
    $candidates = @(
        (Get-OptionalProperty $Track 'local_file')
        (Get-OptionalProperty $Track 'local_song_id')
        (Get-OptionalProperty $Track 'navidrome_song_id')
        (Get-OptionalProperty $Track 'matched_file')
        (Get-OptionalProperty $Track 'matched_song_file')
    )
    foreach ($candidate in $candidates) {
        if (-not $candidate) { continue }
        $value = [string]$candidate
        if ($value -eq 'LOCAL_UNMATCHED') { continue }
        if (Test-Path -LiteralPath $value) { return ([System.IO.Path]::GetFullPath((Get-Item -LiteralPath $value).FullName)) }
        if ($value -match 'na-[0-9a-f]+$') {
            $resolved = Resolve-LibraryNaPath -NaId $value
            if ($resolved) { return $resolved }
            continue
        }
    }
    return $null
}

function Resolve-LibraryNaPath {
    param([Parameter(Mandatory)][string]$NaId)
    $dirs = @($Config.MusicDir)
    $found = $null
    foreach ($dir in $dirs) {
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        $files = Get-ChildItem -LiteralPath $dir -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.mp3','.flac','.wav','.aac' }
        foreach ($file in $files) {
            $na = 'na-' + ([System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes((Get-Item -LiteralPath $file.FullName).FullName))).Replace('-', '').Substring(0,16).ToLowerInvariant())
            if ($na -eq $NaId) { $found = (Get-Item -LiteralPath $file.FullName).FullName; break }
        }
        if ($found) { break }
    }
    return $found
}

function Invoke-SqliteJson {
    param(
        [Parameter(Mandatory)][string]$DbPath,
        [Parameter(Mandatory)][string]$Sql,
        [string[]]$Params = @()
    )
    $sqlite = $Config.Sqlite
    if (-not $sqlite) { throw 'SQLite3 executable not found. Set Config.Sqlite or install sqlite3.' }
    $tempOut = Join-Path ([System.IO.Path]::GetTempPath()) ("navidrome_out_{0}.json" -f [guid]::NewGuid().ToString('N'))
    $argList = @('-readonly', '-json', $DbPath, $Sql)
    $proc = Start-Process -FilePath $sqlite -ArgumentList $argList -NoNewWindow -Wait -PassThru -RedirectStandardOutput $tempOut
    $text = $null
    if (Test-Path -LiteralPath $tempOut) { $text = Get-Content -LiteralPath $tempOut -Raw; Remove-Item -LiteralPath $tempOut -Force -ErrorAction SilentlyContinue }
    if ($proc.ExitCode -ne 0) { return @() }
    if (-not $text) { return @() }
    $parsed = ConvertFrom-Json -InputObject ([string]$text)
    if (-not $parsed) { return @() }
    return @($parsed)
}

function Read-NavidromeLibrary {
    param([AllowEmptyString()][string]$WhereSql = '', [AllowEmptyString()][string[]]$Params = @())
    if ($WhereSql) {
        $sql = "SELECT id, name, artist, album, path, duration, track, addedto, collectionat FROM songs WHERE $WhereSql;"
    } else {
        $sql = 'SELECT id, name, artist, album, path, duration, track, addedto, collectionat FROM songs;'
    }
    return @(Invoke-SqliteJson -DbPath $Config.NdDb -Sql $sql -Params $Params)
}

function Get-NavidromeLibrary {
    return @(Read-NavidromeLibrary)
}

function Get-NavidromeLibraryId {
    param([Parameter(Mandatory)][string]$File)
    $row = @(Read-NavidromeLibrary | Where-Object { [string]$_.path -eq $File } | Select-Object -First 1)
    if ($row) { return 'library-' + [string]$row.id }
    return 'na-' + ([System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($File))).Replace('-', '').Substring(0,16).ToLowerInvariant())
}

function Get-NavidromeLibraryItem {
    param([Parameter(Mandatory)][psobject]$Track)
    $file = Get-TrackLocalFile -Track $Track
    if (-not $file) { return $null }
    return @(Read-NavidromeLibrary | Where-Object { [string]$_.path -eq $file } | Select-Object -First 1)
}

function Read-NeteaseLyrics([string]$Path) {
    if (-not $Path) { return '' }
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    $text = $null
    try { $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 } catch { return '' }
    if ($text -match '^\s*lrc\s*=\s*(.+)$') {
        $json = $Matches[1].Trim()
        try {
            $payload = ConvertFrom-Json -InputObject $json
            if ($payload.lrc) { return [string]$payload.lrc }
        } catch {}
    }
    return [string]$text
}

function Get-LrcPath {
    param([string]$Path)
    if (-not $Path) { return $null }
    if (Test-Path -LiteralPath $Path) { return $Path }
    $lrc = [System.IO.Path]::ChangeExtension($Path, '.lrc')
    if (Test-Path -LiteralPath $lrc) { return $lrc }
    return $null
}

function Get-LibraryItemResponse {
    param([Parameter(Mandatory)][string]$LocalId)
    if ($LocalId.StartsWith('library-')) {
        $idPart = $LocalId.Substring('library-'.Length)
        $row = @(Read-NavidromeLibrary | Where-Object { [string]$_.id -eq $idPart } | Select-Object -First 1)
        if ($row) {
            $file = [System.IO.Path]::GetFullPath([string]$row.path)
            return [pscustomobject]@{
                id = $LocalId; source = 'navidrome'; provider = 'navidrome'
                name = [string]$row.name; artist = [string]$row.artist; album = [string]$row.album
                duration = [int]$row.duration; track = [int]$row.track
                addedto = [string]$row.addedto; collectionat = [string]$row.collectionat
                path = [string]$row.path; file = $file
                stream_url = "/api/library/$LocalId/stream"
                lyrics_url = "/api/library/$LocalId/lyrics"
            }
        }
    }
    if ($LocalId.StartsWith('na-')) {
        $found = Resolve-LibraryNaPath -NaId $LocalId
        if ($found) {
            $lrcPath = Get-LrcPath -Path $found
            $name = [System.IO.Path]::GetFileNameWithoutExtension($found)
            $artist = [string](Get-Item -LiteralPath (Split-Path -Parent $found)).Name
            return [pscustomobject]@{
                id = $LocalId; source = 'local'; provider = 'navidrome'
                name = $name; artist = $artist; album = $artist; duration = 0; track = 0
                addedto = ''; collectionat = ''; path = $found; file = $found
                stream_url = "/api/library/$LocalId/stream"
                lyrics_url = if ($lrcPath) { "/api/library/$LocalId/lyrics" } else { '' }
            }
        }
    }
    # Fallback: track linked by today's DB recommendations.
    foreach ($rec in @(Get-TodayRecommendationsDb)) {
        $track = Get-CanonicalTrackDb -TrackId ([string]$rec.track_id)
        if (-not $track) { continue }
        $playback = $null
        try { $playback = Get-TrackPlaybackSource -Track $track -TrackId ([string]$rec.track_id) -Recommendation $rec } catch {}
        if ($playback -and $playback.provider -eq 'navidrome' -and [string]$playback.id -eq $LocalId) {
            $lrcPath = if ($playback.file) { Get-LrcPath -Path ([string]$playback.file) } else { $null }
            return [pscustomobject]@{
                id = $LocalId; source = 'local'; provider = 'navidrome'
                name = [string]$playback.title; artist = [string]$playback.artist; album = [string]$playback.artist
                duration = 0; track = 0; addedto = ''; collectionat = ''
                path = [string]$playback.file; file = [string]$playback.file
                stream_url = "/api/library/$LocalId/stream"
                lyrics_url = if ($lrcPath) { "/api/library/$LocalId/lyrics" } else { '' }
            }
        }
    }
    throw 'LIBRARY_NOT_FOUND: ' + $LocalId
}

function Get-TodayRecommendationResponse {
    $recs = @(Get-TodayRecommendationsDb)
    return @(foreach ($rec in $recs) {
        $trackId = [string]$rec.track_id
        $track = Get-CanonicalTrackDb -TrackId $trackId
        if (-not $track) { continue }
        $wanted = $null
        try { $wanted = Get-WantedItemDb -TrackId $trackId } catch {}
        $liked = [bool]$rec.liked
        $feedback = $null
        try { $feedback = Get-LatestRecommendationFeedbackDb -TrackId $trackId } catch {}
        if ($feedback) { $liked = ($feedback -eq 'LIKE') }
        $playback = $null
        try { $playback = Get-TrackPlaybackSource -Track $track -TrackId $trackId -Recommendation $rec } catch {}
        $isLocal = ($playback -and $playback.provider -eq 'navidrome')
        [pscustomobject]@{
            id       = $rec.id
            date     = $rec.date
            track_id = $trackId
            rank     = $rec.rank
            reason   = $rec.reason
            title    = [string]$track.title
            artist   = [string]$track.artist
            album    = [string]$track.album
            duration = [int]$track.duration
            cover_url = [string]$track.cover_url
            track    = $track
            preview_source = @($track.preview_sources) | Where-Object { [string](Get-OptionalProperty $_ 'media_url') } | Select-Object -First 1
            playback_source = $playback
            liked    = $liked
            stream_url = if ($isLocal) { $playback.url } else { '' }
            lyrics_url = if ($isLocal -and $playback.id) { "/api/library/$($playback.id)/lyrics" } else { "/api/tracks/$trackId/lyrics" }
            local_status = if ($isLocal) { 'LOCAL' } else { [string]$track.status }
            wanted   = $wanted
        }
    })
}

function Get-TrackResponse {
    param([Parameter(Mandatory)][string]$TrackId)
    $track = Get-CanonicalTrackDb -TrackId $TrackId
    if (-not $track) { return $null }
    $rec = @(Get-TodayRecommendationsDb | Where-Object { [string]$_.track_id -eq $TrackId }) | Select-Object -First 1
    $wanted = $null
    try { $wanted = Get-WantedItemDb -TrackId $TrackId } catch {}
    $liked = $false
    $feedback = $null
    try { $feedback = Get-LatestRecommendationFeedbackDb -TrackId $TrackId } catch {}
    if ($feedback) { $liked = ($feedback -eq 'LIKE') }
    elseif ($rec) { $liked = [bool]$rec.liked }
    $playback = $null
    try { $playback = Get-TrackPlaybackSource -Track $track -TrackId $TrackId -Recommendation $rec } catch {}
    $isLocal = ($playback -and $playback.provider -eq 'navidrome')
    return [pscustomobject]@{
        track_id        = $TrackId
        track           = $track
        recommendation  = $rec
        wanted          = $wanted
        liked           = $liked
        playback_source = $playback
        local_status    = if ($isLocal) { 'LOCAL' } else { [string]$track.status }
    }
}

function Resolve-RouteLikeTransaction {
    # POST/DELETE /api/tracks/{id}/like and the wanted queue routes all funnel
    # through the State-layer transaction functions (single SQLite txn).
    param([Parameter(Mandatory)][string]$TrackId, [switch]$Unlike)
    if ($Unlike) {
        $result = Invoke-UnlikeTrackTransactionDb -TrackId $TrackId -Source 'music_api'
    } else {
        $result = Invoke-LikeTrackTransactionDb -TrackId $TrackId -Source 'music_api'
    }
    $wanted = $null
    try { $wanted = Get-WantedItemDb -TrackId $TrackId } catch {}
    return @{ Result = $result; Wanted = $wanted }
}

$listener = [System.Net.HttpListener]::new()
$prefix = $Prefix
if (-not $prefix.EndsWith('/')) { $prefix += '/' }
$listener.Prefixes.Add($prefix)
$listener.Start()
Write-Host "API listening on $($listener.Prefixes[0])" -ForegroundColor Cyan

$script:requestCount = 0
while ($true) {
    $script:Context = $listener.GetContext()
    $Context = $script:Context
    $request = $Context.Request
    $path = [System.Web.HttpUtility]::UrlDecode($request.Url.AbsolutePath, [System.Text.Encoding]::UTF8)
    $method = $request.HttpMethod
    $script:requestCount++
    $bodyText = ''
    try {
        if ($request.ContentLength64 -gt 0) {
            $stream = $request.GetInputStream()
            $bytes = New-Object byte[] $request.ContentLength64
            [void]$stream.Read($bytes, 0, $request.ContentLength64)
            $bodyText = [System.Text.Encoding]::UTF8.GetString($bytes)
        }
    } catch {}
    Write-Host ("[{0}] {1} {2}  (req #{3})" -f [DateTime]::Now.ToString('HH:mm:ss'), $method, $path, $script:requestCount) -ForegroundColor Gray
    $startTime = [DateTime]::UtcNow
    try {
        if ($method -eq 'GET' -and $path -eq '/api/today') {
            $recItems = @(Get-TodayRecommendationResponse)
            $body = @{ items = $recItems; total = $recItems.Count }
            Send-Json -Context ([pscustomobject]@{ Response = $Context.Response; Body = $body; StatusCode = 200 })
        }
        elseif ($method -eq 'GET' -and $path -eq '/api/library') {
            $library = @(Get-NavidromeLibrary)
            $items = foreach ($row in $library) {
                $file = [System.IO.Path]::GetFullPath([string]$row.path)
                $libraryId = 'library-' + [string]$row.id
                $lrcPath = Get-LrcPath -Path $file
                [pscustomobject]@{
                    id = $libraryId; source = 'navidrome'; provider = 'navidrome'
                    name = [string]$row.name; artist = [string]$row.artist; album = [string]$row.album
                    duration = [int]$row.duration; track = [int]$row.track
                    addedto = [string]$row.addedto; collectionat = [string]$row.collectionat
                    path = [string]$row.path; file = $file
                    stream_url = "/api/library/$libraryId/stream"
                    lyrics_url = if ($lrcPath) { "/api/library/$libraryId/lyrics" } else { '' }
                }
            }
            $naItems = foreach ($dir in @($Config.MusicDir)) {
                if (-not (Test-Path -LiteralPath $dir)) { continue }
                foreach ($file in @(Get-ChildItem -LiteralPath $dir -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.mp3','.flac','.wav','.aac' })) {
                    $full = (Get-Item -LiteralPath $file.FullName).FullName
                    $naId = 'na-' + ([System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($full))).Replace('-', '').Substring(0,16).ToLowerInvariant())
                    $lrcPath = Get-LrcPath -Path $full
                    $name = [System.IO.Path]::GetFileNameWithoutExtension($full)
                    $artist = [string](Get-Item -LiteralPath (Split-Path -Parent $full)).Name
                    [pscustomobject]@{
                        id = $naId; source = 'local'; provider = 'navidrome'
                        name = $name; artist = $artist; album = $artist; duration = 0; track = 0
                        addedto = ''; collectionat = ''; path = $full; file = $full
                        stream_url = "/api/library/$naId/stream"
                        lyrics_url = if ($lrcPath) { "/api/library/$naId/lyrics" } else { '' }
                    }
                }
            }
            $allItems = @($items) + @($naItems)
            $body = @{ items = $allItems; total = $allItems.Count }
            Send-Json -Context ([pscustomobject]@{ Response = $Context.Response; Body = $body; StatusCode = 200 })
        }
        elseif ($method -eq 'GET' -and $path -match '^/api/library/([^/]+)/stream$') {
            $localId = [System.Web.HttpUtility]::UrlDecode($Matches[1], [System.Text.Encoding]::UTF8)
            $item = Get-LibraryItemResponse -LocalId $localId
            $file = [string]$item.file
            if (-not (Test-Path -LiteralPath $file)) {
                $body = @{ error = 'FILE_NOT_FOUND'; id = $localId }
                Send-Json -Context ([pscustomobject]@{ Response = $Context.Response; Body = $body; StatusCode = 404 })
            } else {
                $fileBytes = [System.IO.File]::ReadAllBytes($file)
                $Context.Response.ContentType = 'audio/mpeg'
                $Context.Response.ContentLength64 = $fileBytes.Length
                $Context.Response.OutputStream.Write($fileBytes, 0, $fileBytes.Length)
                $Context.Response.OutputStream.Close()
            }
        }
        elseif ($method -eq 'GET' -and $path -match '^/api/library/([^/]+)/lyrics$') {
            $localId = [System.Web.HttpUtility]::UrlDecode($Matches[1], [System.Text.Encoding]::UTF8)
            $item = Get-LibraryItemResponse -LocalId $localId
            $lrcPath = Get-LrcPath -Path ([string]$item.file)
            if ($lrcPath) {
                $lyrics = Read-NeteaseLyrics -Path $lrcPath
                $body = @{ id = $localId; lyrics = $lyrics; path = $lrcPath }
                Send-Json -Context ([pscustomobject]@{ Response = $Context.Response; Body = $body; StatusCode = 200 })
            } else {
                $body = @{ error = 'LYRICS_NOT_FOUND'; id = $localId }
                Send-Json -Context ([pscustomobject]@{ Response = $Context.Response; Body = $body; StatusCode = 404 })
            }
        }
        elseif ($method -eq 'GET' -and $path -match '^/api/tracks/([^/]+)/lyrics$') {
            $trackId = [System.Web.HttpUtility]::UrlDecode($Matches[1], [System.Text.Encoding]::UTF8)
            $track = Get-CanonicalTrackDb -TrackId $trackId
            if (-not $track) {
                $body = @{ error = 'TRACK_NOT_FOUND'; track_id = $trackId }
                Send-Json -Context ([pscustomobject]@{ Response = $Context.Response; Body = $body; StatusCode = 404 })
            } else {
                $localFile = Get-TrackLocalFile -Track $track -TrackId $trackId
                if (-not $localFile) {
                    $body = @{ error = 'LYRICS_NOT_FOUND'; track_id = $trackId; message = 'No local file linked to this track.' }
                    Send-Json -Context ([pscustomobject]@{ Response = $Context.Response; Body = $body; StatusCode = 404 })
                } else {
                    $lrcPath = Get-LrcPath -Path $localFile
                    if (-not $lrcPath) {
                        $body = @{ error = 'LYRICS_NOT_FOUND'; track_id = $trackId; message = "No .lrc next to $([System.IO.Path]::GetFileName($localFile))" }
                        Send-Json -Context ([pscustomobject]@{ Response = $Context.Response; Body = $body; StatusCode = 404 })
                    } else {
                        $lyrics = Read-NeteaseLyrics -Path $lrcPath
                        $body = @{ track_id = $trackId; lyrics = $lyrics; path = $lrcPath }
                        Send-Json -Context ([pscustomobject]@{ Response = $Context.Response; Body = $body; StatusCode = 200 })
                    }
                }
            }
        }
        elseif ($method -eq 'GET' -and $path -match '^/api/tracks/([^/]+)$') {
            $trackId = [System.Web.HttpUtility]::UrlDecode($Matches[1], [System.Text.Encoding]::UTF8)
            $track = Get-CanonicalTrackDb -TrackId $trackId
            if (-not $track) {
                $body = @{ error = 'TRACK_NOT_FOUND'; track_id = $trackId }
                Send-Json -Context ([pscustomobject]@{ Response = $Context.Response; Body = $body; StatusCode = 404 })
            } else {
                $resp = Get-TrackResponse -TrackId $trackId
                Send-Json -Context ([pscustomobject]@{ Response = $Context.Response; Body = $resp; StatusCode = 200 })
            }
        }
        elseif (($method -eq 'POST' -or $method -eq 'DELETE') -and $path -match '^/api/tracks/([^/]+)/like$') {
            $trackId = [System.Web.HttpUtility]::UrlDecode($Matches[1], [System.Text.Encoding]::UTF8)
            $liked = ($method -eq 'POST')
            if ($liked) {
                $tx = Resolve-RouteLikeTransaction -TrackId $trackId
            } else {
                $tx = Resolve-RouteLikeTransaction -TrackId $trackId -Unlike
            }
            $body = [pscustomobject]@{
                accepted = $true
                liked    = [bool]$tx.Result.liked
                track_id = [string]$tx.Result.track_id
                action   = [string]$tx.Result.action
                wanted   = $tx.Wanted
            }
            Send-Json -Context ([pscustomobject]@{ Response = $Context.Response; Body = $body; StatusCode = 200 })
        }
        elseif ($method -eq 'GET' -and $path -eq '/api/wanted') {
            $wantedItems = @(Get-WantedTracksDb)
            $body = @{ items = $wantedItems; total = $wantedItems.Count }
            Send-Json -Context ([pscustomobject]@{ Response = $Context.Response; Body = $body; StatusCode = 200 })
        }
        elseif ($method -eq 'POST' -and $path -eq '/api/wanted') {
            $requestedTrackId = $null
            try {
                if ($bodyText) { $payload = ConvertFrom-Json -InputObject $bodyText; $requestedTrackId = [string]$payload.track_id }
            } catch {}
            if (-not $requestedTrackId) {
                $rec = @(Get-TodayRecommendationsDb) | Select-Object -First 1
                if ($rec) { $requestedTrackId = [string]$rec.track_id }
            }
            if (-not $requestedTrackId) {
                $body = @{ error = 'NO_TRACK_FOUND'; message = 'Provide body {track_id} or have a track in today recommendations.' }
                Send-Json -Context ([pscustomobject]@{ Response = $Context.Response; Body = $body; StatusCode = 400 })
            } else {
                $tx = Resolve-RouteLikeTransaction -TrackId $requestedTrackId
                $queued = $false
                if ($tx.Wanted) { $queued = ($tx.Result.action -in @('QUEUED','REQUEUED')) }
                $bodyOut = [pscustomobject]@{ accepted = $true; queued = $queued; wanted = $tx.Wanted }
                Send-Json -Context ([pscustomobject]@{ Response = $Context.Response; Body = $bodyOut; StatusCode = 202 })
            }
        }
        elseif ($method -eq 'POST' -and $path -match '^/api/wanted/([^/]+)$') {
            $trackId = [System.Web.HttpUtility]::UrlDecode($Matches[1], [System.Text.Encoding]::UTF8)
            $tx = Resolve-RouteLikeTransaction -TrackId $trackId
            $queued = ($tx.Result.action -in @('QUEUED','REQUEUED'))
            $body = [pscustomobject]@{ accepted = $true; queued = $queued; wanted = $tx.Wanted }
            Send-Json -Context ([pscustomobject]@{ Response = $Context.Response; Body = $body; StatusCode = 202 })
        }
        elseif ($method -eq 'POST' -and $path -match '^/api/wanted/([^/]+)/retry$') {
            $trackId = [System.Web.HttpUtility]::UrlDecode($Matches[1], [System.Text.Encoding]::UTF8)
            $tx = Resolve-RouteLikeTransaction -TrackId $trackId
            $queued = ($tx.Result.action -in @('QUEUED','REQUEUED'))
            $body = [pscustomobject]@{ accepted = $true; queued = $queued; wanted = $tx.Wanted }
            Send-Json -Context ([pscustomobject]@{ Response = $Context.Response; Body = $body; StatusCode = 202 })
        }
        elseif ($method -eq 'POST' -and $path -match '^/api/wanted/([^/]+)/cancel$') {
            $trackId = [System.Web.HttpUtility]::UrlDecode($Matches[1], [System.Text.Encoding]::UTF8)
            $tx = Resolve-RouteLikeTransaction -TrackId $trackId -Unlike
            $body = [pscustomobject]@{ accepted = $true; action = [string]$tx.Result.action; wanted = $tx.Wanted }
            Send-Json -Context ([pscustomobject]@{ Response = $Context.Response; Body = $body; StatusCode = 200 })
        }
        elseif ($method -eq 'GET' -and $path -eq '/api/providers/status') {
            $providers = @(Get-ProviderStatusesDb)
            $body = @{ items = $providers; total = $providers.Count }
            Send-Json -Context ([pscustomobject]@{ Response = $Context.Response; Body = $body; StatusCode = 200 })
        }
        elseif ($method -eq 'GET' -and $path -eq '/health') {
            $dbOk = $false
            try { [void](Get-DbStats); $dbOk = $true } catch {}
            $body = @{ status = if ($dbOk) { 'ok' } else { 'degraded' }; db = $dbOk; uptime_requests = $script:requestCount }
            $status = if ($dbOk) { 200 } else { 503 }
            Send-Json -Context ([pscustomobject]@{ Response = $Context.Response; Body = $body; StatusCode = $status })
        }
        elseif ($method -eq 'GET' -and $path -eq '/') {
            $body = @{ service = 'music_server'; version = '2'; phase = 'hardening-v2-phase3' }
            Send-Json -Context ([pscustomobject]@{ Response = $Context.Response; Body = $body; StatusCode = 200 })
        }
        else {
            $body = @{ error = 'NOT_FOUND'; path = $path }
            Send-Json -Context ([pscustomobject]@{ Response = $Context.Response; Body = $body; StatusCode = 404 })
        }
    } catch {
        $errMsg = $_.Exception.Message
        $statusCode = 500
        if ($errMsg -match 'TRACK_NOT_FOUND') { $statusCode = 404 }
        elseif ($errMsg -match 'LIBRARY_NOT_FOUND') { $statusCode = 404 }
        elseif ($errMsg -match 'Sqlite|sqlite|NOT\s+NULL|constraint|no such table|database is locked') { $statusCode = 500 }
        Write-Host "  ERROR: $errMsg" -ForegroundColor Red
        if (-not $Context.Response.HasErrors) {
            try {
                $body = @{ error = if ($statusCode -eq 404) { 'NOT_FOUND' } else { 'INTERNAL_ERROR' }; message = $errMsg }
                Send-Json -Context ([pscustomobject]@{ Response = $Context.Response; Body = $body; StatusCode = $statusCode })
            } catch {}
        }
    } finally {
        $elapsed = ([DateTime]::UtcNow - $startTime).TotalMilliseconds
        Write-Host ("  done in {0:N0} ms" -f $elapsed) -ForegroundColor DarkGray
    }
    if ($Once) { break }
}
$listener.Stop()
