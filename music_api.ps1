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
#       GET  /api/listening/stats -> { most_played=[...], rediscover=[...], total_local }
#       GET  /api/listening/random -> one playable local track
#       POST /api/library/{id}/play or /api/tracks/{id}/play -> completed local play event
#       GET  /health               -> { status='ok', ... }
# ------------------------------------------------------------------
param(
    [string]$Prefix = 'http://127.0.0.1:8787/',
    [switch]$Once,
    [string]$Root = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'
$startupClock = [Diagnostics.Stopwatch]::StartNew()
$startupPhases = [ordered]@{}
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
Import-Module (Join-Path $PSScriptRoot 'MusicServer.Http.psm1') -Force
$startupPhases['module_imports'] = $startupClock.Elapsed.TotalMilliseconds

$Config = New-MusicServerConfig -Root $Root
Initialize-MusicServerState -Config $Config -SkipLibrary
# The API is spawned with redirected stdio, so Write-Host output is discarded.
# Runtime diagnostics must therefore go to a file under APP_HOME\logs.
$ApiLog = Join-Path $Config.LogDir 'musicserver-api.log'
function Write-ApiLog {
    param([string]$Message)
    Write-MusicServerLog -Path $ApiLog -Message $Message
}
$DbPath = Join-Path $Config.StateDir 'musicserver.db'
$SqliteExe = [string]$Config.Sqlite
if (-not $SqliteExe -or -not (Test-Path -LiteralPath $SqliteExe)) {
    $cmd = Get-Command sqlite3.exe -ErrorAction SilentlyContinue
    if ($cmd) { $SqliteExe = $cmd.Source }
    else {
        $cmd = Get-Command sqlite3 -ErrorAction SilentlyContinue
        if ($cmd) { $SqliteExe = $cmd.Source }
    }
}
if (-not (Test-Path -LiteralPath $SqliteExe) -and -not (Get-Command $SqliteExe -ErrorAction SilentlyContinue)) {
    throw "SQLite3 executable not found: $SqliteExe"
}
$startupPhases['config_state'] = $startupClock.Elapsed.TotalMilliseconds
Initialize-MusicServerDatabase -DbPath $DbPath -SqliteExe $SqliteExe
$startupPhases['database_connect'] = $startupClock.Elapsed.TotalMilliseconds
Initialize-MusicServerSchema
$startupPhases['schema'] = $startupClock.Elapsed.TotalMilliseconds
Apply-ConfiguredMusicDir -Config $Config
Initialize-MusicServerLibrary -Config $Config | Out-Null
$startupPhases['config_library'] = $startupClock.Elapsed.TotalMilliseconds
Write-Host ("API v2 ready | db={0} | music_dir={1} | migration=NOT_REQUESTED" -f $DbPath, $Config.MusicDir) -ForegroundColor Green
Write-ApiLog ("API v2 ready | db={0} | music_dir={1}" -f $DbPath, $Config.MusicDir)

function Send-Json([psobject]$Context) {
    $body = $Context.Body
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Depth 20))
    $Context.Response.ContentType = 'application/json; charset=utf-8'
    $Context.Response.StatusCode = [int]$Context.StatusCode
    $Context.Response.ContentLength64 = $bodyBytes.Length
    if ($env:MUSICSERVER_DIAGNOSTICS -eq '1') {
        $calls = (Get-MusicServerSqliteInvocationCount) - $script:RequestSqliteStart
        $Context.Response.Headers['X-MusicServer-State-Sqlite-Calls'] = [string]$calls
    }
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
            # The provider must come from the source record, not be assumed: a
            # NetEase preview URL reported as bilibili would mislead any caller
            # that branches on the provider.
            $previewProvider = [string](Get-OptionalProperty $previewSource 'provider' '')
            if (-not $previewProvider) { $previewProvider = 'preview' }
            return [pscustomobject]@{
                provider = $previewProvider
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
        # canonical_tracks.local_song_id stores the read-only Navidrome
        # media_file id, not a filesystem path. Resolve that id through the
        # current media_file snapshot so canonical local tracks can be played.
        $navId = if ($value.StartsWith('library-')) { $value.Substring('library-'.Length) } else { $value }
        try {
            $navRow = @(Find-RequestNavidromeItem -Id $navId)
            if ($navRow) {
                $navPath = [string]$navRow[0].path
                if ($navPath -and -not [System.IO.Path]::IsPathRooted($navPath)) {
                    $navPath = Join-Path $Config.MusicDir $navPath
                }
                if ($navPath -and (Test-Path -LiteralPath $navPath -PathType Leaf)) {
                    return ([System.IO.Path]::GetFullPath((Get-Item -LiteralPath $navPath).FullName))
                }
            }
        } catch {}
    }
    return $null
}

function Get-StableLocalIdentity {
    param([Parameter(Mandatory)][string]$File)
    return Get-MusicServerLocalIdentity -File $File
}

function Resolve-LibraryNaPath {
    param([Parameter(Mandatory)][string]$NaId)
    $dirs = @($Config.MusicDir)
    $found = $null
    foreach ($dir in $dirs) {
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        $files = Get-ChildItem -LiteralPath $dir -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.mp3','.flac','.wav','.aac','.m4a' }
        foreach ($file in $files) {
            $na = Get-StableLocalIdentity -File $file.FullName
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
    if (-not (Test-Path -LiteralPath $DbPath -PathType Leaf)) { return @() }
    $errorFile = Join-Path ([System.IO.Path]::GetTempPath()) ("navidrome_err_{0}.log" -f [guid]::NewGuid().ToString('N'))
    try {
        # Pass SQL as one argument. Start-Process -ArgumentList can flatten a
        # query containing spaces and make sqlite receive an incomplete query.
        $output = @(& $sqlite '-readonly' '-json' $DbPath $Sql 2> $errorFile)
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) { return @() }
        $text = ($output -join [Environment]::NewLine)
    } finally {
        Remove-Item -LiteralPath $errorFile -Force -ErrorAction SilentlyContinue
    }
    if ([string]::IsNullOrWhiteSpace($text)) { return @() }
    return @(ConvertFrom-MusicServerJsonArray -Json $text)
}

function Read-NavidromeLibrary {
    param([AllowEmptyString()][string]$WhereSql = '', [AllowEmptyString()][string[]]$Params = @())
    # `missing` is Navidrome's own bookkeeping and only a scan refreshes it. The
    # packaged runtime does not ship Navidrome, so on a machine without it every
    # row stays flagged missing for ever and filtering on the flag hid the whole
    # library. Callers verify the file on disk instead, which is the fact that
    # actually matters.
    if ($WhereSql) {
        $sql = "SELECT id, title AS name, artist, album, path, duration, track_number AS track, created_at AS addedto, updated_at AS collectionat FROM media_file WHERE $WhereSql;"
    } else {
        $sql = 'SELECT id, title AS name, artist, album, path, duration, track_number AS track, created_at AS addedto, updated_at AS collectionat FROM media_file;'
    }
    return @(Invoke-SqliteJson -DbPath $Config.NdDb -Sql $sql -Params $Params)
}

function Get-RequestNavidromeLibrary {
    if ($null -eq $script:RequestNavidromeLibrary) {
        $script:RequestNavidromeLibrary = @(Read-NavidromeLibrary)
    }
    return $script:RequestNavidromeLibrary
}

function Find-RequestNavidromeItem {
    param([string]$Id = '', [string]$File = '')
    if ($null -eq $script:RequestNavidromeById) {
        $script:RequestNavidromeById = @{}
        $script:RequestNavidromeByFile = @{}
        foreach ($row in @(Get-RequestNavidromeLibrary)) {
            $script:RequestNavidromeById[[string]$row.id] = $row
            $path = [string]$row.path
            if (-not $path) { continue }
            try {
                if (-not [IO.Path]::IsPathRooted($path)) { $path = Join-Path $Config.MusicDir $path }
                $path = [IO.Path]::GetFullPath($path)
                if (-not $script:RequestNavidromeByFile.ContainsKey($path)) { $script:RequestNavidromeByFile[$path] = $row }
            } catch {}
        }
    }
    if ($Id) { return $script:RequestNavidromeById[$Id] }
    if ($File) { return $script:RequestNavidromeByFile[[IO.Path]::GetFullPath($File)] }
}

function Get-NavidromeLibrary {
    return @(Get-RequestNavidromeLibrary)
}

function Get-NavidromeLibraryId {
    param([Parameter(Mandatory)][string]$File)
    $fullFile = [System.IO.Path]::GetFullPath($File)
    $row = Find-RequestNavidromeItem -File $fullFile
    if ($row) { return 'library-' + [string]$row.id }
    return Get-StableLocalIdentity -File $File
}

function Get-NavidromeLibraryItem {
    param([Parameter(Mandatory)][psobject]$Track)
    $file = Get-TrackLocalFile -Track $Track
    if (-not $file) { return $null }
    $fullFile = [System.IO.Path]::GetFullPath($file)
    return @(Find-RequestNavidromeItem -File $fullFile)
}

function Get-LocalCanonicalTrackMap {
    try { return Get-CanonicalLocalTrackMapDb } catch { return @{} }
}

function New-ListeningLibraryItem {
    param(
        [Parameter(Mandatory)][psobject]$Row,
        [Parameter(Mandatory)][string]$File,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$LocalId,
        [Parameter(Mandatory)][hashtable]$CanonicalByLocalId
    )

    $canonical = $null
    $rowId = [string](Get-OptionalProperty $Row 'id')
    if ($rowId -and $CanonicalByLocalId.ContainsKey($rowId)) { $canonical = $CanonicalByLocalId[$rowId] }
    $identity = if ($canonical) { [string]$canonical.id } else { Get-StableLocalIdentity -File $File }
    $title = [string](Get-OptionalProperty $Row 'name' (Get-OptionalProperty $Row 'title'))
    $artist = [string](Get-OptionalProperty $Row 'artist')
    $album = [string](Get-OptionalProperty $Row 'album')
    $lrcPath = Get-LrcPath -Path $File
    $trackId = if ($canonical) { [string]$canonical.id } else { $identity }
    [pscustomobject]@{
        id = $LocalId; library_id = $LocalId; source = $Source; provider = 'navidrome'
        name = $title; title = $title; artist = $artist; album = $album
        duration = [int](Get-OptionalProperty $Row 'duration' 0); track = [int](Get-OptionalProperty $Row 'track' 0)
        addedto = [string](Get-OptionalProperty $Row 'addedto')
        collectionat = [string](Get-OptionalProperty $Row 'collectionat')
        path = $File; file = $File
        track_id = $trackId; canonical_track_id = if ($canonical) { [string]$canonical.id } else { '' }
        listening_identity = $identity; local_status = 'LOCAL'
        stream_url = "/api/library/$LocalId/stream"
        lyrics_url = if ($lrcPath) { "/api/library/$LocalId/lyrics" } else { '' }
        cover_url = ''
    }
}

# A flat library keeps every file directly in MusicDir. The library root's own
# name is not an artist, and reporting it as one is why every row used to show
# the same placeholder ("Music") instead of a name.
function Get-LibraryFolderArtist {
    param([Parameter(Mandatory)][string]$File)
    $parent = Split-Path -Parent $File
    if (-not $parent) { return '' }
    $root = [string]$Config.MusicDir
    if (-not [string]::IsNullOrWhiteSpace($root)) {
        try {
            if ([IO.Path]::GetFullPath($parent).TrimEnd('\') -ieq [IO.Path]::GetFullPath($root).TrimEnd('\')) { return '' }
        } catch { }
    }
    return [string](Split-Path -Leaf $parent)
}

# The indexed artist of a Bilibili download is the uploader, not the singer. The
# launcher resolves the real singer in the background and records it in state, so
# every library surface reads that cache here. Fail-soft: a resolution that has
# not run yet leaves the index value in place rather than blanking it.
function Add-ResolvedArtist {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Items)
    if (@($Items).Count -eq 0) { return @() }
    $resolved = @{}
    try { $resolved = Get-LocalTrackArtistMapDb } catch { $resolved = @{} }
    # Channel branding is a prefix shared by many titles, so it is only
    # recognisable from the whole set; a single-item lookup gets no prefixes.
    $prefixes = @()
    try { $prefixes = @(Get-SharedTitlePrefixes -Titles @($Items | ForEach-Object { [string](Get-OptionalProperty $_ 'title' '') })) } catch { $prefixes = @() }
    # The year is a property of the track, not of the artist decision, so every row
    # carries one even when there is no decision at all. 0 means unknown and the UI
    # renders nothing; it is never back-filled from the file's own `year` tag.
    foreach ($item in @($Items)) { $item | Add-Member -NotePropertyName 'year' -NotePropertyValue 0 -Force }
    foreach ($item in @($Items)) {
        $key = Get-MusicServerPathKey -Path ([string](Get-OptionalProperty $item 'file' ''))
        $row = if ($key -and $resolved.ContainsKey($key)) { $resolved[$key] } else { $null }
        $decision = Resolve-DisplayArtist -Title ([string](Get-OptionalProperty $item 'title' '')) -Indexed ([string](Get-OptionalProperty $item 'artist' '')) -CachedRow $row -KnownPrefixes $prefixes
        if (-not $decision) { continue }
        if ($decision.artist) { $item.artist = $decision.artist }
        if ($decision.album) { $item.album = $decision.album }
        $item.year = [int]$decision.year
    }
    return @($Items)
}

function Get-LocalListeningItems {
    $canonicalByLocalId = Get-LocalCanonicalTrackMap
    $items = New-Object System.Collections.ArrayList
    $seenFiles = @{}

    foreach ($row in @(Get-NavidromeLibrary)) {
        $file = [string](Get-OptionalProperty $row 'path')
        if ([string]::IsNullOrWhiteSpace($file)) { continue }
        try {
            if (-not [System.IO.Path]::IsPathRooted($file)) { $file = Join-Path $Config.MusicDir $file }
            $file = [System.IO.Path]::GetFullPath($file)
        } catch { continue }
        $fileKey = $file.ToLowerInvariant()
        if ($seenFiles.ContainsKey($fileKey)) { continue }
        if (-not [IO.File]::Exists($file)) { continue }
        $seenFiles[$fileKey] = $true
        $localId = 'library-' + [string]$row.id
        [void]$items.Add((New-ListeningLibraryItem -Row $row -File $file -Source 'navidrome' -LocalId $localId -CanonicalByLocalId $canonicalByLocalId))
    }

    foreach ($dir in @($Config.MusicDir)) {
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
        foreach ($fileInfo in @(Get-ChildItem -LiteralPath $dir -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.mp3','.flac','.wav','.aac','.m4a' })) {
            $file = [System.IO.Path]::GetFullPath($fileInfo.FullName)
            $fileKey = $file.ToLowerInvariant()
            if ($seenFiles.ContainsKey($fileKey)) { continue }
            $seenFiles[$fileKey] = $true
            $title = [System.IO.Path]::GetFileNameWithoutExtension($file)
            $artist = Get-LibraryFolderArtist -File $file
            $addedAt = ''
            try { $addedAt = (Get-Item -LiteralPath $file).LastWriteTime.ToString('o') } catch {}
            $row = [pscustomobject]@{ id = ''; name = $title; artist = $artist; album = $artist; duration = 0; track = 0; addedto = $addedAt; collectionat = $addedAt }
            $localId = Get-StableLocalIdentity -File $file
            [void]$items.Add((New-ListeningLibraryItem -Row $row -File $file -Source 'local' -LocalId $localId -CanonicalByLocalId $canonicalByLocalId))
        }
    }
    return @(Add-ResolvedArtist -Items @($items))
}

function Get-LocalListeningItem {
    param([Parameter(Mandatory)][string]$LocalId)
    return @(Get-LocalListeningItems | Where-Object {
        [string]$_.id -eq $LocalId -or [string]$_.track_id -eq $LocalId -or [string]$_.listening_identity -eq $LocalId
    } | Select-Object -First 1)
}

function Get-RandomLocalListeningItem {
    param([string]$ExcludeId = '')
    $items = @(Get-LocalListeningItems)
    if ($items.Count -eq 0) { return $null }
    $candidates = @($items | Where-Object {
        -not $ExcludeId -or (
            [string]$_.id -ne $ExcludeId -and
            [string]$_.track_id -ne $ExcludeId -and
            [string]$_.listening_identity -ne $ExcludeId
        )
    })
    if ($candidates.Count -eq 0) { $candidates = $items }
    return $candidates[(Get-Random -Minimum 0 -Maximum $candidates.Count)]
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
    $candidate = if ([System.IO.Path]::GetExtension($Path) -ieq '.lrc') {
        $Path
    } else {
        [System.IO.Path]::ChangeExtension($Path, '.lrc')
    }
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    return $null
}

function Get-LibraryItemResponse {
    param([Parameter(Mandatory)][string]$LocalId)
    if ($LocalId.StartsWith('library-')) {
        $idPart = $LocalId.Substring('library-'.Length)
        $row = @(Read-NavidromeLibrary -WhereSql ("id = " + (ConvertTo-MusicServerSqlLiteral $idPart)))
        if ($row) {
            $file = [string]$row[0].path
            if (-not [System.IO.Path]::IsPathRooted($file)) { $file = Join-Path $Config.MusicDir $file }
            $file = [System.IO.Path]::GetFullPath($file)
            # An index row can outlive its file, so only serve it while that file
            # is still there.
            if ([IO.File]::Exists($file)) {
                $item = [pscustomobject]@{
                    id = $LocalId; source = 'navidrome'; provider = 'navidrome'
                    name = [string]$row.name; artist = [string]$row.artist; album = [string]$row.album
                    duration = [int]$row.duration; track = [int]$row.track
                    addedto = [string]$row.addedto; collectionat = [string]$row.collectionat
                    path = [string]$row.path; file = $file; year = 0
                    stream_url = "/api/library/$LocalId/stream"
                    lyrics_url = "/api/library/$LocalId/lyrics"
                }
                return @(Add-ResolvedArtist -Items @($item))[0]
            }
        }
    }
    if ($LocalId.StartsWith('na-')) {
        $found = Resolve-LibraryNaPath -NaId $LocalId
        if ($found) {
            $lrcPath = Get-LrcPath -Path $found
            $name = [System.IO.Path]::GetFileNameWithoutExtension($found)
            $artist = Get-LibraryFolderArtist -File $found
            $item = [pscustomobject]@{
                id = $LocalId; source = 'local'; provider = 'navidrome'
                name = $name; artist = $artist; album = $artist; duration = 0; track = 0
                addedto = ''; collectionat = ''; path = $found; file = $found; year = 0
                stream_url = "/api/library/$LocalId/stream"
                lyrics_url = if ($lrcPath) { "/api/library/$LocalId/lyrics" } else { '' }
            }
            return @(Add-ResolvedArtist -Items @($item))[0]
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

function Remove-LibraryTrack {
    param([Parameter(Mandatory)][string]$LocalId)
    # Resolve the file for the id. na- ids resolve by scanning the library dirs.
    $file = $null
    try {
        $item = Get-LibraryItemResponse -LocalId $LocalId
        $file = [string]$item.file
    } catch { $file = $null }
    if (-not $file -or -not (Test-Path -LiteralPath $file -PathType Leaf)) {
        return @{ Error = 'FILE_NOT_FOUND'; Message = '找不到要删除的本地文件。'; File = $file; Deleted = $false; TrackId = '' }
    }
    $fullFile = [System.IO.Path]::GetFullPath($file)

    # Before deleting, find any canonical track that is LOCAL and bound to this
    # file (via Navidrome media_file path) so its state can be reset.
    $trackId = ''
    try {
        $escapedPath = ([string]$fullFile).Replace("'", "''")
        $navRows = @(Invoke-SqliteJson -DbPath $Config.NdDb -Sql "SELECT id FROM media_file WHERE path = '$escapedPath' LIMIT 1;")
        if ($navRows.Count -gt 0) {
            $songId = [string]$navRows[0].id
            # Find canonical tracks bound to this Navidrome song id.
            $candRows = @(Invoke-MusicServerParamSql -Template "SELECT id FROM canonical_tracks WHERE local_song_id = @sid AND status = 'LOCAL' LIMIT 5;" -Params @{ sid = $songId })
            if ($candRows.Count -gt 0) { $trackId = [string]$candRows[0].id }
        }
    } catch {}

    # Delete the audio file and its sidecar .lrc.
    try { Remove-Item -LiteralPath $fullFile -Force -ErrorAction Stop } catch { }
    $lrcFile = [System.IO.Path]::ChangeExtension($fullFile, '.lrc')
    if (Test-Path -LiteralPath $lrcFile) { Remove-Item -LiteralPath $lrcFile -Force -ErrorAction SilentlyContinue }

    # Reset canonical track to REMOTE (and drop the local binding) if one was bound.
    if ($trackId) {
        try {
            $track = Get-CanonicalTrackDb -TrackId $trackId
            if ($track) {
                $track.status = 'REMOTE'
                $track.local_song_id = ''
                Save-CanonicalTrackDb -Track $track | Out-Null
            }
        } catch {}
    }

    # Ask Navidrome to rescan so the deleted file leaves its library.
    try {
        if ((Test-Path -LiteralPath $Config.NdExe) -and (Test-Path -LiteralPath $Config.NdConfig)) {
            & $Config.NdExe -c $Config.NdConfig scan --nobanner 2>$null | Out-Null
        }
    } catch {}

    return @{ Error = ''; Message = 'ok'; File = $fullFile; Deleted = $true; TrackId = $trackId }
}

function Get-TodayRecommendationResponse {
    $batch = @(Get-TodayRecommendationBatchDb)
    # One fold for the whole day rather than a query per row.
    $preference = @{}
    try { $preference = Get-TrackPreferenceMapDb } catch { $preference = @{} }
    return @(foreach ($entry in $batch) {
        $rec = $entry.Recommendation
        $trackId = [string]$rec.track_id
        $track = $entry.Track
        $wanted = $entry.Wanted
        $liked = [bool]$rec.liked
        $feedback = $entry.Feedback
        if ($feedback) { $liked = ($feedback -eq 'LIKE') }
        $disliked = ($preference.ContainsKey($trackId) -and [string]$preference[$trackId] -eq 'DISLIKE')
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
            year     = [int](Get-OptionalProperty $track 'release_year' 0)
            cover_url = [string]$track.cover_url
            track    = $track
            preview_source = @($track.preview_sources) | Where-Object { [string](Get-OptionalProperty $_ 'media_url') } | Select-Object -First 1
            playback_source = $playback
            liked    = $liked
            disliked = $disliked
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
    # Disliking records an UNLIKE, so a disliked track is never reported as liked;
    # `disliked` is the separate state the UI renders.
    $disliked = $false
    try { $disliked = ((Get-LatestTrackPreferenceDb -TrackId $TrackId) -eq 'DISLIKE') } catch { $disliked = $false }
    return [pscustomobject]@{
        track_id        = $TrackId
        track           = $track
        recommendation  = $rec
        wanted          = $wanted
        liked           = $liked
        disliked        = $disliked
        playback_source = $playback
        local_status    = if ($isLocal) { 'LOCAL' } else { [string]$track.status }
    }
}

function Get-ListeningStatsResponse {
    $library = @(Get-LocalListeningItems)
    $overview = Get-ListeningOverviewDb -LibraryItems $library -MostPlayedLimit 5 -RediscoverLimit 5 -RecentCooldownMinutes 120
    return [pscustomobject]@{
        most_played = @($overview.most_played)
        rediscover = @($overview.rediscover)
        total_local = $library.Count
    }
}

function Get-ListeningPlayResponse {
    param(
        [Parameter(Mandatory)][string]$LocalId,
        [string]$SessionId = ''
    )
    $item = @(Get-LocalListeningItem -LocalId $LocalId) | Select-Object -First 1
    if ($null -eq $item) { throw 'LIBRARY_NOT_FOUND: ' + $LocalId }
    $stat = Record-ListeningPlayDb -Identity ([string]$item.listening_identity) -TrackId ([string]$item.track_id) -LibraryId ([string]$item.id) -SessionId $SessionId
    return [pscustomobject]@{
        accepted = $true
        counted = [bool]$stat.counted
        id = [string]$item.id
        library_id = [string]$item.id
        identity = [string]$stat.identity
        track_id = [string]$item.track_id
        title = [string]$item.title
        artist = [string]$item.artist
        play_count = [int]$stat.play_count
        last_played_at = $stat.last_played_at
        first_played_at = $stat.first_played_at
        updated_at = [string]$stat.updated_at
        session_id = [string]$stat.session_id
    }
}

function Get-ListeningSessionIdFromBody {
    param([AllowEmptyString()][string]$Body = '')
    if ([string]::IsNullOrWhiteSpace($Body)) { return '' }
    try {
        $payload = ConvertFrom-Json -InputObject $Body
        return [string](Get-OptionalProperty $payload 'session_id')
    } catch {
        return ''
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

$script:requestCount = 0
Import-Module (Join-Path $PSScriptRoot 'MusicServer.Identity.psm1') -Force
$script:BuildMarker = Get-MusicServerBuildIdentity -Root $PSScriptRoot
$startupPhases['build_identity'] = $startupClock.Elapsed.TotalMilliseconds

$listener = [System.Net.HttpListener]::new()
$prefix = $Prefix
if (-not $prefix.EndsWith('/')) { $prefix += '/' }
$listener.Prefixes.Add($prefix)
$listener.Start()
$startupPhases['listener_start'] = $startupClock.Elapsed.TotalMilliseconds
Write-Host "API listening on $prefix" -ForegroundColor Cyan
Write-ApiLog ("API listening on {0} | marker={1}" -f $prefix, $script:BuildMarker)

# /api/today is recomputed per request and costs ~5s (each DB read spawns a
# sqlite3 subprocess; 20 tracks x several reads). The UI polls it every 15s,
# and because the UI proxies on a single thread, a slow /api/today blocks
# playback/health for everyone. Daily recommendations only change once a day
# (23:00), so a short cache makes the endpoint near-instant without staleness.
$script:TodayCacheItems = $null
$script:TodayCacheAt = [DateTime]::MinValue
$script:TodayCacheSeconds = 60
Write-MusicServerStartupTrace -Role api -Checkpoints $startupPhases
while ($true) {
    $script:Context = $listener.GetContext()
    $script:RequestNavidromeLibrary = $null
    $script:RequestNavidromeById = $null
    $script:RequestNavidromeByFile = $null
    $Context = $script:Context
    $request = $Context.Request
    $path = [System.Web.HttpUtility]::UrlDecode($request.Url.AbsolutePath, [System.Text.Encoding]::UTF8)
    $method = $request.HttpMethod
    $script:requestCount++
    $script:RequestSqliteStart = Get-MusicServerSqliteInvocationCount
    Write-Host ("[{0}] {1} {2}  (req #{3})" -f [DateTime]::Now.ToString('HH:mm:ss'), $method, $path, $script:requestCount) -ForegroundColor Gray
    Write-ApiLog ("{0} {1} (req #{2})" -f $method, $path, $script:requestCount)
    $startTime = [DateTime]::UtcNow
    try {
        $bodyText = (Read-MusicServerJsonRequest -Request $request).Text
        if ($method -eq 'GET' -and $path -eq '/api/today') {
            $now = [DateTime]::UtcNow
            $cacheAge = ($now - $script:TodayCacheAt).TotalSeconds
            if ($null -eq $script:TodayCacheItems -or $cacheAge -ge $script:TodayCacheSeconds) {
                $script:TodayCacheItems = @(Get-TodayRecommendationResponse)
                $script:TodayCacheAt = $now
            }
            $body = @{ items = $script:TodayCacheItems; total = @($script:TodayCacheItems).Count }
            Send-Json -Context ([pscustomobject]@{ Response = $Context.Response; Body = $body; StatusCode = 200 })
        }
        elseif ($method -eq 'GET' -and $path -eq '/api/listening/stats') {
            $body = Get-ListeningStatsResponse
            Send-Json -Context ([pscustomobject]@{ Response = $Context.Response; Body = $body; StatusCode = 200 })
        }
        elseif ($method -eq 'GET' -and $path -eq '/api/listening/random') {
            $query = [System.Web.HttpUtility]::ParseQueryString($request.Url.Query)
            $excludeId = [string]$query['exclude']
            $randomItem = Get-RandomLocalListeningItem -ExcludeId $excludeId
            if ($null -eq $randomItem) {
                $body = @{ error = 'LIBRARY_EMPTY'; message = '本地曲库还没有可播放的歌曲。' }
                Send-Json -Context ([pscustomobject]@{ Response = $Context.Response; Body = $body; StatusCode = 404 })
            } else {
                $body = ConvertTo-ListeningItemResponse -Item $randomItem
                Send-Json -Context ([pscustomobject]@{ Response = $Context.Response; Body = $body; StatusCode = 200 })
            }
        }
        elseif ($method -eq 'POST' -and $path -match '^/api/library/([^/]+)/play$') {
            $localId = [System.Web.HttpUtility]::UrlDecode($Matches[1], [System.Text.Encoding]::UTF8)
            $sessionId = Get-ListeningSessionIdFromBody -Body $bodyText
            $body = Get-ListeningPlayResponse -LocalId $localId -SessionId $sessionId
            Send-Json -Context ([pscustomobject]@{ Response = $Context.Response; Body = $body; StatusCode = 200 })
        }
        elseif ($method -eq 'POST' -and $path -match '^/api/tracks/([^/]+)/play$') {
            $trackId = [System.Web.HttpUtility]::UrlDecode($Matches[1], [System.Text.Encoding]::UTF8)
            $sessionId = Get-ListeningSessionIdFromBody -Body $bodyText
            $body = Get-ListeningPlayResponse -LocalId $trackId -SessionId $sessionId
            Send-Json -Context ([pscustomobject]@{ Response = $Context.Response; Body = $body; StatusCode = 200 })
        }
        elseif ($method -eq 'GET' -and $path -eq '/api/library') {
            $allItems = @(Get-LocalListeningItems)
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
                # Serve the audio with HTTP Range support so <audio> can seek.
                $length = (Get-Item -LiteralPath $file).Length
                $rangeHeader = $Context.Request.Headers['Range']
                $start = 0; $end = $length - 1; $isPartial = $false
                if ($rangeHeader -match 'bytes=(\d*)-(\d*)') {
                    $rS = $Matches[1]; $rE = $Matches[2]
                    if ($rS -ne '') { $start = [long]$rS }
                    if ($rE -ne '') { $end = [Math]::Min([long]$rE, $length - 1) }
                    if ($rS -eq '' -and $rE -ne '') {
                        $n = [Math]::Min([long]$rE, $length); $start = $length - $n; $end = $length - 1
                    }
                    if ($start -ge $length) {
                        try {
                            $Context.Response.StatusCode = 416
                            $Context.Response.Headers['Content-Range'] = "bytes */$length"
                            $Context.Response.Close()
                        } catch {}
                        return
                    }
                    $isPartial = $true
                }
                $chunkLength = $end - $start + 1
                $Context.Response.StatusCode = if ($isPartial) { 206 } else { 200 }
                $Context.Response.ContentType = 'audio/mpeg'
                $Context.Response.Headers['Accept-Ranges'] = 'bytes'
                $Context.Response.ContentLength64 = $chunkLength
                if ($isPartial) { $Context.Response.Headers['Content-Range'] = "bytes $start-$end/$length" }
                $stream = [System.IO.File]::Open($file, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                try {
                    if ($start -gt 0) { [void]$stream.Seek($start, [System.IO.SeekOrigin]::Begin) }
                    $buffer = New-Object byte[] 65536
                    $remaining = $chunkLength
                    while ($remaining -gt 0) {
                        $toRead = [int][Math]::Min($buffer.Length, $remaining)
                        $read = $stream.Read($buffer, 0, $toRead)
                        if ($read -le 0) { break }
                        $remaining -= $read
                        $Context.Response.OutputStream.Write($buffer, 0, $read)
                    }
                } finally {
                    $stream.Dispose()
                    try { $Context.Response.OutputStream.Close() } catch {}
                }
            }
        }
        elseif ($method -eq 'GET' -and $path -match '^/api/library/([^/]+)/lyrics$') {
            $localId = [System.Web.HttpUtility]::UrlDecode($Matches[1], [System.Text.Encoding]::UTF8)
            $item = Get-LibraryItemResponse -LocalId $localId
            $lrcPath = Get-LrcPath -Path ([string]$item.file)
            if ($lrcPath) {
                $lyrics = Read-NeteaseLyrics -Path $lrcPath
                $body = @{ id = $localId; available = $true; format = 'lrc'; text = $lyrics; lyrics = $lyrics; path = $lrcPath }
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
                        $body = @{ track_id = $trackId; available = $true; format = 'lrc'; text = $lyrics; lyrics = $lyrics; path = $lrcPath }
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
            # Like state is part of /api/today items: invalidate the cache so the
            # UI shows the heart/queue status immediately after the action.
            $script:TodayCacheItems = $null
            $script:TodayCacheAt = [DateTime]::MinValue
            $body = [pscustomobject]@{
                accepted = $true
                liked    = [bool]$tx.Result.liked
                track_id = [string]$tx.Result.track_id
                action   = [string]$tx.Result.action
                wanted   = $tx.Wanted
            }
            Send-Json -Context ([pscustomobject]@{ Response = $Context.Response; Body = $body; StatusCode = 200 })
        }
        elseif (($method -eq 'POST' -or $method -eq 'DELETE') -and $path -match '^/api/tracks/([^/]+)/dislike$') {
            $trackId = [System.Web.HttpUtility]::UrlDecode($Matches[1], [System.Text.Encoding]::UTF8)
            $track = Get-CanonicalTrackDb -TrackId $trackId
            if (-not $track) {
                $body = @{ error = 'TRACK_NOT_FOUND'; track_id = $trackId }
                Send-Json -Context ([pscustomobject]@{ Response = $Context.Response; Body = $body; StatusCode = 404 })
            } else {
                # Preference-only: no queue change, no download cancellation, no
                # file deletion. Disliking says what to recommend, not what to keep.
                # The album and NetEase id are recorded with it because everything
                # RELATED to the song is down-weighted too, not just this recording.
                if ($method -eq 'POST') {
                    $tx = Write-TrackDislikeDb -TrackId $trackId -Title ([string]$track.title) `
                        -Artist ([string]$track.artist) -Album ([string]$track.album) `
                        -NeteaseId (Get-NeteaseIdFromTrack -Track $track) -Source 'music_api'
                } else {
                    $tx = Write-TrackUndislikeDb -TrackId $trackId -Source 'music_api'
                }
                # disliked/liked are part of /api/today items, so drop the cache.
                $script:TodayCacheItems = $null
                $script:TodayCacheAt = [DateTime]::MinValue
                $body = [pscustomobject]@{
                    accepted = $true
                    disliked = [bool]$tx.disliked
                    track_id = $trackId
                }
                Send-Json -Context ([pscustomobject]@{ Response = $Context.Response; Body = $body; StatusCode = 200 })
            }
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
                $script:TodayCacheItems = $null
                $script:TodayCacheAt = [DateTime]::MinValue
                $bodyOut = [pscustomobject]@{ accepted = $true; queued = $queued; wanted = $tx.Wanted }
                Send-Json -Context ([pscustomobject]@{ Response = $Context.Response; Body = $bodyOut; StatusCode = 202 })
            }
        }
        elseif ($method -eq 'POST' -and $path -match '^/api/wanted/([^/]+)$') {
            $trackId = [System.Web.HttpUtility]::UrlDecode($Matches[1], [System.Text.Encoding]::UTF8)
            $tx = Resolve-RouteLikeTransaction -TrackId $trackId
            $queued = ($tx.Result.action -in @('QUEUED','REQUEUED'))
            $script:TodayCacheItems = $null
            $script:TodayCacheAt = [DateTime]::MinValue
            $body = [pscustomobject]@{ accepted = $true; queued = $queued; wanted = $tx.Wanted }
            Send-Json -Context ([pscustomobject]@{ Response = $Context.Response; Body = $body; StatusCode = 202 })
        }
        elseif ($method -eq 'POST' -and $path -match '^/api/wanted/([^/]+)/retry$') {
            $trackId = [System.Web.HttpUtility]::UrlDecode($Matches[1], [System.Text.Encoding]::UTF8)
            $tx = Resolve-RouteLikeTransaction -TrackId $trackId
            $queued = ($tx.Result.action -in @('QUEUED','REQUEUED'))
            $script:TodayCacheItems = $null
            $script:TodayCacheAt = [DateTime]::MinValue
            $body = [pscustomobject]@{ accepted = $true; queued = $queued; wanted = $tx.Wanted }
            Send-Json -Context ([pscustomobject]@{ Response = $Context.Response; Body = $body; StatusCode = 202 })
        }
        elseif ($method -eq 'POST' -and $path -match '^/api/wanted/([^/]+)/cancel$') {
            $trackId = [System.Web.HttpUtility]::UrlDecode($Matches[1], [System.Text.Encoding]::UTF8)
            $tx = Resolve-RouteLikeTransaction -TrackId $trackId -Unlike
            $script:TodayCacheItems = $null
            $script:TodayCacheAt = [DateTime]::MinValue
            $body = [pscustomobject]@{ accepted = $true; action = [string]$tx.Result.action; wanted = $tx.Wanted }
            Send-Json -Context ([pscustomobject]@{ Response = $Context.Response; Body = $body; StatusCode = 200 })
        }
        elseif ($method -eq 'DELETE' -and $path -match '^/api/library/([^/]+)$') {
            $localId = [System.Web.HttpUtility]::UrlDecode($Matches[1], [System.Text.Encoding]::UTF8)
            $result = Remove-LibraryTrack -LocalId $localId
            if ($result.Error) {
                $body = @{ error = $result.Error; id = $localId; message = $result.Message }
                Send-Json -Context ([pscustomobject]@{ Response = $Context.Response; Body = $body; StatusCode = 404 })
            } else {
                $body = [pscustomobject]@{
                    accepted = $true; id = $localId; deleted = $result.Deleted
                    file = $result.File; track_id = $result.TrackId
                    message = "已删除：$([IO.Path]::GetFileName($result.File))"
                }
                Send-Json -Context ([pscustomobject]@{ Response = $Context.Response; Body = $body; StatusCode = 200 })
            }
        }
        elseif ($method -eq 'GET' -and $path -eq '/api/providers/status') {
            $providers = @(Get-ProviderStatusesDb)
            $body = @{ items = $providers; total = $providers.Count }
            Send-Json -Context ([pscustomobject]@{ Response = $Context.Response; Body = $body; StatusCode = 200 })
        }
        elseif ($method -eq 'GET' -and $path -eq '/api/settings/music-library') {
            $currentPath = $Config.MusicDir
            $defaultPath = Get-DefaultMusicDir -AppHome $Config.AppHome
            $isDefault = ($currentPath -eq $defaultPath)
            $available = (Test-Path -LiteralPath $currentPath -PathType Container)
            $source = if ($env:MUSICSERVER_MUSIC_DIR) { 'environment' } elseif (-not $isDefault) { 'database' } else { 'default' }
            $body = [pscustomobject]@{
                path = $currentPath
                default_path = $defaultPath
                source = $source
                available = $available
                daily_dir = $Config.DailyDir
            }
            Send-Json -Context ([pscustomobject]@{ Response = $Context.Response; Body = $body; StatusCode = 200 })
        }
        elseif ($method -eq 'PUT' -and $path -eq '/api/settings/music-library') {
            $bodyObj = $null
            try { if ($bodyText) { $bodyObj = ConvertFrom-Json -InputObject $bodyText } } catch {}
            if (-not $bodyObj -or -not $bodyObj.path) {
                $body = @{ error = 'INVALID_REQUEST'; message = 'Request body must contain "path".' }
                Send-Json -Context ([pscustomobject]@{ Response = $Context.Response; Body = $body; StatusCode = 400 })
            } else {
                $candidate = [string]$bodyObj.path
                $validation = Test-MusicLibraryPath -Path $candidate
                if (-not $validation.Valid) {
                    $body = @{ error = 'INVALID_PATH'; message = "Path is not valid: $($validation.Reason)"; reason = $validation.Reason }
                    Send-Json -Context ([pscustomobject]@{ Response = $Context.Response; Body = $body; StatusCode = 400 })
                } else {
                    $newPath = $validation.FullPath
                    # Create directory if it doesn't exist (user is choosing a new location)
                    if (-not (Test-Path -LiteralPath $newPath -PathType Container)) {
                        try { New-Item -ItemType Directory -Force -Path $newPath | Out-Null } catch {
                            $body = @{ error = 'CREATE_FAILED'; message = "Cannot create directory: $_" }
                            Send-Json -Context ([pscustomobject]@{ Response = $Context.Response; Body = $body; StatusCode = 400 })
                            return
                        }
                    }
                    $previousPath = $Config.MusicDir
                    Set-AppSettingDb -Key 'music_library_path' -Value $newPath
                    Apply-ConfiguredMusicDir -Config $Config
                    # Sync Navidrome MusicFolder
                    try { Sync-NavidromeMusicFolder -NdConfigPath $Config.NdConfig -NewMusicFolder $Config.MusicDir | Out-Null } catch {}
                    $body = [pscustomobject]@{
                        accepted = $true
                        path = $Config.MusicDir
                        previous_path = $previousPath
                        daily_dir = $Config.DailyDir
                        message = 'Music library path updated. Restart MusicServer for all services to pick up the change.'
                        requires_restart = $true
                    }
                    Send-Json -Context ([pscustomobject]@{ Response = $Context.Response; Body = $body; StatusCode = 200 })
                }
            }
        }
        elseif ($method -eq 'DELETE' -and $path -eq '/api/settings/music-library') {
            $previousPath = $Config.MusicDir
            $defaultPath = Get-DefaultMusicDir -AppHome $Config.AppHome
            Remove-AppSettingDb -Key 'music_library_path'
            Apply-ConfiguredMusicDir -Config $Config
            try { Sync-NavidromeMusicFolder -NdConfigPath $Config.NdConfig -NewMusicFolder $Config.MusicDir | Out-Null } catch {}
            $body = [pscustomobject]@{
                accepted = $true
                path = $Config.MusicDir
                previous_path = $previousPath
                daily_dir = $Config.DailyDir
                message = 'Music library path reset to default. Restart MusicServer for all services to pick up the change.'
                requires_restart = $true
            }
            Send-Json -Context ([pscustomobject]@{ Response = $Context.Response; Body = $body; StatusCode = 200 })
        }
        elseif ($method -eq 'GET' -and $path -eq '/health') {
            $dbOk = $false
            try { [void](Get-DbStats); $dbOk = $true } catch {}
            $body = @{ status = if ($dbOk) { 'ok' } else { 'degraded' }; db = $dbOk; build = $script:BuildMarker; uptime_requests = $script:requestCount }
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
        $inputError = $_.Exception.Data.Contains('HttpStatusCode')
        if ($inputError) { $statusCode = [int]$_.Exception.Data['HttpStatusCode'] }
        elseif ($errMsg -match 'TRACK_NOT_FOUND') { $statusCode = 404 }
        elseif ($errMsg -match 'LIBRARY_NOT_FOUND') { $statusCode = 404 }
        elseif ($errMsg -match 'Sqlite|sqlite|NOT\s+NULL|constraint|no such table|database is locked') { $statusCode = 500 }
        Write-Host "  ERROR: $errMsg" -ForegroundColor Red
        Write-ApiLog ("ERROR {0} {1} status={2} {3}" -f $method, $path, $statusCode, $errMsg)
        $errorCode = if ($inputError) { [string]$_.Exception.Data['ErrorCode'] } elseif ($statusCode -eq 404) { 'NOT_FOUND' } else { 'INTERNAL_ERROR' }
        try {
            if ($inputError) { $Context.Response.KeepAlive = $false }
            $body = @{ error = $errorCode; message = $errMsg }
            Send-Json -Context ([pscustomobject]@{ Response = $Context.Response; Body = $body; StatusCode = $statusCode })
        } catch { try { $Context.Response.Abort() } catch {} }
    } finally {
        $elapsed = ([DateTime]::UtcNow - $startTime).TotalMilliseconds
        Write-Host ("  done in {0:N0} ms" -f $elapsed) -ForegroundColor DarkGray
        if ($elapsed -ge 3000) { Write-ApiLog ("SLOW {0} {1} took {2:N0} ms" -f $method, $path, $elapsed) }
    }
    if ($Once) { break }
}
$listener.Stop()
