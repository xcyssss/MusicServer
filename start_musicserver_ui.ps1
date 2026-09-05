param(
    [string]$ApiPrefix = 'http://127.0.0.1:8787/',
    [string]$UiPrefix = 'http://127.0.0.1:8790/',
    [switch]$NoBrowser,
    [int]$ClientTimeoutSeconds = 90,
    [int]$LastClientGraceSeconds = 8
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue } catch {}
try {
    # The UI proxies every /api/* request to the backend over HttpWebRequest while
    # serving all clients from a single-threaded HttpListener loop. With the .NET
    # default connection limit (2) the proxy can deadlock: a second concurrent
    # browser request blocks waiting for a pooled connection that only the blocked
    # handler thread could release. Raise the limit so concurrent proxy requests
    # never queue behind each other.
    [System.Net.ServicePointManager]::DefaultConnectionLimit = 50
    [System.Net.ServicePointManager]::MaxServicePointIdleTime = 10000
} catch {}

$Root = $PSScriptRoot
$WebRoot = Join-Path $Root 'web'
$ApiScript = Join-Path $Root 'music_api.ps1'
$WorkerScript = Join-Path $Root 'wanted_worker.ps1'
$LogRoot = Join-Path $Root 'logs'
$LyricsReportPath = Join-Path $Root 'lyrics_report.csv'
$UiLog = Join-Path $LogRoot 'musicserver-ui.log'
$ApiOutLog = Join-Path $LogRoot 'musicserver-api.stdout.log'
$ApiErrLog = Join-Path $LogRoot 'musicserver-api.stderr.log'
$WorkerOutLog = Join-Path $LogRoot 'musicserver-worker.stdout.log'
$WorkerErrLog = Join-Path $LogRoot 'musicserver-worker.stderr.log'
$UiHeartbeatFile = Join-Path $LogRoot 'musicserver-ui.heartbeat'
$WatchdogLog = Join-Path $LogRoot 'musicserver-ui.watchdog.log'
$ApiProcess = $null
$StartedApi = $false
$WorkerProcess = $null
$StartedWorker = $false
$Listener = $null
$Clients = @{}
$HasSeenClient = $false
$NoClientSince = $null
$StartupDeadline = [DateTime]::UtcNow.AddSeconds(60)
$LibraryFiles = @{}
# Watchdog state: the UI serves every request on one thread, so a handler that
# wedges (slow external call, proxy hang) freezes the whole UI. A background
# watchdog thread watches $script:LastActivityAt and force-restarts this process
# when the main loop has made no progress for too long.
$script:LastActivityAt = [DateTime]::UtcNow
$script:CurrentRequest = ''
$script:UiLibraryCache = $null
$script:UiLibraryCacheAt = [DateTime]::MinValue

if (-not (Test-Path -LiteralPath $LogRoot)) {
    New-Item -ItemType Directory -Force -Path $LogRoot | Out-Null
}

function Write-UiLog {
    param([string]$Message)
    try {
        $line = '[{0}] {1}' -f ([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss')), $Message
        Add-Content -LiteralPath $UiLog -Value $line -Encoding UTF8
    } catch {}
}

function Test-ApiReady {
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        try {
            $ok = $client.ConnectAsync('127.0.0.1', ([Uri]$ApiPrefix).Port).Wait(1500)
            return $ok
        } finally {
            $client.Dispose()
        }
    } catch {
        return $false
    }
}

function Test-UiReady {
    # Port probe beats an HTTP health probe here: the UI serves every request on
    # a single thread, so a /health call can time out while the listener is
    # merely busy (e.g. mid-way through a slow proxied request). A listening port
    # means a UI process already owns the prefix; the double-click launcher must
    # then open the existing instance instead of failing with a prefix conflict.
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        try {
            $ok = $client.ConnectAsync('127.0.0.1', ([Uri]$UiPrefix).Port).Wait(1500)
            return $ok
        } finally {
            $client.Dispose()
        }
    } catch {
        return $false
    }
}

function Start-MusicServerApi {
    if (Test-ApiReady) {
        Write-UiLog "API already running at $ApiPrefix"
        return
    }

    if (-not (Test-Path -LiteralPath $ApiScript -PathType Leaf)) {
        throw "music_api.ps1 not found: $ApiScript"
    }

    $escapedScript = $ApiScript.Replace('"', '\"')
    $escapedPrefix = $ApiPrefix.Replace('"', '\"')
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$escapedScript`" -Prefix `"$escapedPrefix`""
    $script:ApiProcess = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WorkingDirectory $Root -WindowStyle Hidden -PassThru -RedirectStandardOutput $ApiOutLog -RedirectStandardError $ApiErrLog
    $script:StartedApi = $true

    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Milliseconds 500
        if (Test-ApiReady) {
            Write-UiLog "API started at $ApiPrefix pid=$($script:ApiProcess.Id)"
            return
        }
        if ($script:ApiProcess.HasExited) {
            throw "music_api.ps1 exited before /health became ready. ExitCode=$($script:ApiProcess.ExitCode). See $ApiErrLog"
        }
    }

    throw "MusicServer API did not become healthy at $ApiPrefix. See $ApiErrLog"
}

# Wanted worker: the background process that actually downloads liked tracks from
# the queue. The old launcher generation (start_musicserver.cmd/.vbs/.ps1) started
# it explicitly; the single-process UI launcher (start_musicserver_ui.ps1) never
# did, so likes stayed queued forever. This launcher now owns it the same way it
# owns the API: start it on launch, stop it when the last browser client closes.
function Test-WorkerReady {
    try {
        $stateDb = Join-Path $Config.StateDir 'musicserver.db'
        if (-not (Test-Path -LiteralPath $stateDb -PathType Leaf)) { return $false }
        # The queue mutex is per-named-mutex, not per-process: an existing healthy
        # worker holds 'MusicServer_WantedWorker', so we probe that instead of a port.
        $mutex = [Threading.Mutex]::new($false, 'MusicServer_WantedWorker')
        try {
            $owned = $mutex.WaitOne(0)
            if ($owned) { $mutex.ReleaseMutex() }
            return (-not $owned)   # someone else holds it -> a worker is running
        } finally {
            $mutex.Dispose()
        }
    } catch {
        return $false
    }
}

function Start-MusicServerWorker {
    if (Test-WorkerReady) {
        Write-UiLog 'Wanted worker already running (queue mutex held).'
        return
    }
    if (-not (Test-Path -LiteralPath $WorkerScript -PathType Leaf)) {
        Write-UiLog "wanted_worker.ps1 not found: $WorkerScript"
        return
    }
    $escapedScript = $WorkerScript.Replace('"', '\"')
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$escapedScript`" -PollSeconds 30"
    $script:WorkerProcess = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WorkingDirectory $Root -WindowStyle Hidden -PassThru -RedirectStandardOutput $WorkerOutLog -RedirectStandardError $WorkerErrLog
    $script:StartedWorker = $true
    Write-UiLog "Wanted worker started pid=$($script:WorkerProcess.Id)"
}

Import-Module (Join-Path $Root 'MusicServer.Core.psm1') -Force
$Config = New-MusicServerConfig -Root $Root

function Invoke-NavidromeSqliteJson {
    param([Parameter(Mandatory)][string]$Sql)

    if (-not (Test-Path -LiteralPath $Config.NdDb -PathType Leaf)) { return @() }
    $sqlite = [string]$Config.Sqlite
    if (-not $sqlite) { return @() }

    $errorFile = Join-Path ([System.IO.Path]::GetTempPath()) ("musicserver_nav_{0}.err" -f [guid]::NewGuid().ToString('N'))
    try {
        # Invoke sqlite directly so the complete SQL statement is passed as one
        # argument. Start-Process -ArgumentList flattens the SQL string and can
        # make sqlite receive only an incomplete statement such as "SELECT".
        $output = & $sqlite '-readonly' '-json' $Config.NdDb $Sql 2> $errorFile
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            $detail = if (Test-Path -LiteralPath $errorFile) { Get-Content -LiteralPath $errorFile -Raw -ErrorAction SilentlyContinue } else { '' }
            Write-UiLog "Navidrome sqlite query failed exit=$exitCode $detail"
            return @()
        }
        $text = (@($output) -join [Environment]::NewLine)
        if ([string]::IsNullOrWhiteSpace($text)) { return @() }
        $parsed = ConvertFrom-Json -InputObject $text
        if ($null -eq $parsed) { return @() }
        return @($parsed)
    } catch {
        Write-UiLog "Navidrome sqlite query exception: $($_.Exception.Message)"
        return @()
    } finally {
        Remove-Item -LiteralPath $errorFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-LocalLibraryId {
    param([Parameter(Mandatory)][string]$File)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes([System.IO.Path]::GetFullPath($File))
        $hex = [System.BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant()
        return 'na-' + $hex.Substring(0, 16)
    } finally {
        $sha.Dispose()
    }
}

function Get-LrcPath {
    param([string]$File)
    if (-not $File) { return $null }
    $candidate = [System.IO.Path]::ChangeExtension($File, '.lrc')
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    return $null
}

function Get-LyricQuality {
    param([Parameter(Mandatory)][string]$File)

    if (-not (Test-Path -LiteralPath $LyricsReportPath -PathType Leaf)) { return 'UNVERIFIED' }
    try {
        $fileName = [System.IO.Path]::GetFileName($File)
        $row = Import-Csv -LiteralPath $LyricsReportPath |
            Where-Object { [string]$_.File -eq $fileName } |
            Select-Object -First 1
        if ($row -and $row.Status) { return ([string]$row.Status).ToUpperInvariant() }
    } catch {
        Write-UiLog "Could not read lyric quality for $File : $($_.Exception.Message)"
    }
    return 'UNVERIFIED'
}

function Get-NeteaseIdForTrack {
    param([Parameter(Mandatory)]$TrackResponse)

    $recommendation = $TrackResponse.recommendation
    if ($recommendation) {
        $explicitId = [string]$recommendation.netease_id
        if (-not [string]::IsNullOrWhiteSpace($explicitId)) { return $explicitId.Trim() }
        $playbackValue = [string]$recommendation.playback_source
        if ($playbackValue -match '^netease:(.+)$') { return ([string]$Matches[1]).Trim() }
    }

    foreach ($identifier in @($TrackResponse.track.identifiers)) {
        $identifierType = [string]$identifier.type
        $identifierValue = [string]$identifier.value
        if ($identifierType.ToLowerInvariant() -eq 'netease' -and -not [string]::IsNullOrWhiteSpace($identifierValue)) {
            return $identifierValue.Trim()
        }
    }
    return ''
}

function Get-NetEaseLyricsById {
    param([Parameter(Mandatory)][string]$SongId)

    $headers = @{
        'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/124 Safari/537.36'
        'Referer' = 'https://music.163.com/'
        'Accept' = 'application/json,text/plain,*/*'
    }
    try {
        $encoded = [System.Uri]::EscapeDataString($SongId)
        $response = Invoke-RestMethod -Uri "https://music.163.com/api/song/lyric?id=$encoded&lv=1&kv=1&tv=-1" -Headers $headers -TimeoutSec 15
        if ($response -and $response.lrc -and $response.lrc.lyric) {
            return [string]$response.lrc.lyric
        }
    } catch {
        Write-UiLog "NetEase lyric request failed song=$SongId : $($_.Exception.Message)"
    }
    return ''
}

function Get-UiLibrary {
    # The single-threaded UI is hammered by browser polls (every open tab polls
    # /api/library every 15s). Each call used to re-scan the whole Music folder
    # and recompute a SHA per file (~0.5-1s), so a few tabs froze the listener.
    # Cache the assembled list: the library only changes when files move in/out,
    # which the refresh button and a short TTL handle.
    $cacheAge = ([DateTime]::UtcNow - $script:UiLibraryCacheAt).TotalSeconds
    if ($null -ne $script:UiLibraryCache -and $cacheAge -lt 30) {
        return @($script:UiLibraryCache)
    }
    $items = New-Object System.Collections.ArrayList
    $seenFiles = @{}
    $script:LibraryFiles = @{}

    # Navidrome 0.63.x stores songs in media_file. Keep the UI response aliases
    # stable so the frontend does not depend on Navidrome's internal column names.
    $sql = 'SELECT id, title AS name, artist, album, path, duration, track_number AS track, created_at AS addedto, updated_at AS collectionat FROM media_file WHERE missing = 0;'
    foreach ($row in @(Invoke-NavidromeSqliteJson -Sql $sql)) {
        $file = [string]$row.path
        if ([string]::IsNullOrWhiteSpace($file)) { continue }
        try {
            if (-not [System.IO.Path]::IsPathRooted($file)) {
                $musicRoot = @($Config.MusicDir | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) } | Select-Object -First 1)
                if ($musicRoot.Count -gt 0) { $file = Join-Path ([string]$musicRoot[0]) $file }
                else { $file = Join-Path $Root $file }
            }
            $file = [System.IO.Path]::GetFullPath($file)
        } catch { continue }
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }

        $seenFiles[$file.ToLowerInvariant()] = $true
        $id = 'library-' + [string]$row.id
        $script:LibraryFiles[$id] = $file
        $lrcPath = Get-LrcPath -File $file
        [void]$items.Add([pscustomobject]@{
            id = $id; source = 'navidrome'; provider = 'navidrome'
            name = [string]$row.name; title = [string]$row.name
            artist = [string]$row.artist; album = [string]$row.album
            duration = [int]$row.duration; track = [int]$row.track
            addedto = [string]$row.addedto; collectionat = [string]$row.collectionat
            path = $file; file = $file
            stream_url = "/api/library/$id/stream"
            lyrics_url = if ($lrcPath) { "/api/library/$id/lyrics" } else { '' }
        })
    }

    foreach ($dir in @($Config.MusicDir)) {
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
        foreach ($entry in @(Get-ChildItem -LiteralPath $dir -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.mp3','.flac','.wav','.aac','.m4a' })) {
            $file = [System.IO.Path]::GetFullPath($entry.FullName)
            $fileKey = $file.ToLowerInvariant()
            if ($seenFiles.ContainsKey($fileKey)) { continue }
            $seenFiles[$fileKey] = $true
            $id = Get-LocalLibraryId -File $file
            $script:LibraryFiles[$id] = $file
            $title = [System.IO.Path]::GetFileNameWithoutExtension($file)
            $artist = [string](Split-Path -Leaf (Split-Path -Parent $file))
            $lrcPath = Get-LrcPath -File $file
            $addedAt = ''
            try { $addedAt = (Get-Item -LiteralPath $file).LastWriteTime.ToString('o') } catch {}
            [void]$items.Add([pscustomobject]@{
                id = $id; source = 'local'; provider = 'navidrome'
                name = $title; title = $title; artist = $artist; album = $artist
                duration = 0; track = 0; addedto = $addedAt; collectionat = $addedAt
                path = $file; file = $file
                stream_url = "/api/library/$id/stream"
                lyrics_url = if ($lrcPath) { "/api/library/$id/lyrics" } else { '' }
            })
        }
    }

    $script:UiLibraryCache = @($items)
    $script:UiLibraryCacheAt = [DateTime]::UtcNow
    return @($items)
}

function Resolve-UiLibraryFile {
    param([Parameter(Mandatory)][string]$Id)
    Write-UiLog "RESOLVE $Id cacheHit=$($script:LibraryFiles.ContainsKey($Id)) cacheItems=$($script:LibraryFiles.Count)"
    if ($script:LibraryFiles.ContainsKey($Id)) {
        $candidate = [string]$script:LibraryFiles[$Id]
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    [void](Get-UiLibrary)
    if ($script:LibraryFiles.ContainsKey($Id)) {
        $candidate = [string]$script:LibraryFiles[$Id]
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return $null
}

# Writes response bytes with a hard timeout. HttpListener's OutputStream blocks
# forever (no exception, no timeout) once the client has disconnected mid-write,
# and this UI serves every request on one thread, so one wedged write froze the
# whole player. Async write + wait bounds the block; on timeout we give up and
# close, letting the main loop move on.
function Send-ResponseBytes {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][byte[]]$Bytes,
        [int]$TimeoutMs = 5000
    )
    try {
        $stream = $Context.Response.OutputStream
        $async = $stream.BeginWrite($Bytes, 0, $Bytes.Length, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs)) {
            try { $Context.Response.Abort() } catch {}
            return $false
        }
        $stream.EndWrite($async)
        try { $Context.Response.OutputStream.Close() } catch {}
        return $true
    } catch {
        try { $Context.Response.Abort() } catch {}
        return $false
    }
}

function Send-Json {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Body, [int]$StatusCode = 200)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Body -Depth 8 -Compress))
    try {
        $Context.Response.StatusCode = $StatusCode
        $Context.Response.ContentType = 'application/json; charset=utf-8'
        $Context.Response.ContentLength64 = $bytes.Length
        $Context.Response.Headers['Cache-Control'] = 'no-store'
    } catch {
        try { $Context.Response.Abort() } catch {}
        return
    }
    [void](Send-ResponseBytes -Context $Context -Bytes $bytes)
}

# Lyrics responses bypass ConvertTo-Json entirely: it has been observed spinning
# at 100% CPU on this long-running process for small lyric payloads (Japanese
# text with full-width brackets). Manual JSON with proper escaping is always safe.
function ConvertTo-JsonStringValue {
    param([AllowNull()][object]$Value)
    try { Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue } catch {}
    if ($null -eq $Value) { return '""' }
    return '"' + [System.Web.HttpUtility]::JavaScriptStringEncode([string]$Value) + '"'
}

function Send-LyricsJson {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$Id,
        [bool]$Available,
        [string]$Text,
        [string]$Quality,
        [string]$Source,
        [string]$Path,
        [string]$Message
    )
    $avail = if ($Available) { 'true' } else { 'false' }
    $json = '{"id":' + (ConvertTo-JsonStringValue $Id) + ',"available":' + $avail + ',"format":"lrc","text":' + (ConvertTo-JsonStringValue $Text) +
        ',"quality":' + (ConvertTo-JsonStringValue $Quality) + ',"source":' + (ConvertTo-JsonStringValue $Source) +
        ',"path":' + (ConvertTo-JsonStringValue $Path) + ',"message":' + (ConvertTo-JsonStringValue $Message) + '}'
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    try {
        $Context.Response.StatusCode = 200
        $Context.Response.ContentType = 'application/json; charset=utf-8'
        $Context.Response.ContentLength64 = $bytes.Length
        $Context.Response.Headers['Cache-Control'] = 'no-store'
    } catch {
        try { $Context.Response.Abort() } catch {}
        return
    }
    [void](Send-ResponseBytes -Context $Context -Bytes $bytes)
}

function Send-StaticFile {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][string]$ContentType
    )

    $file = Join-Path $WebRoot $RelativePath
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        $Context.Response.StatusCode = 404
        $Context.Response.Close()
        return
    }

    $bytes = [System.IO.File]::ReadAllBytes($file)
    $Context.Response.StatusCode = 200
    $Context.Response.ContentType = $ContentType
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.Headers['Cache-Control'] = 'no-store'
    [void](Send-ResponseBytes -Context $Context -Bytes $bytes)
}

function Send-IndexHtml {
    param([Parameter(Mandatory)]$Context)
    $file = Join-Path $WebRoot 'index.html'
    $html = Get-Content -LiteralPath $file -Raw -Encoding UTF8
    $lifecycleScript = @'
<script>
(() => {
  const clientId = (globalThis.crypto && crypto.randomUUID)
    ? crypto.randomUUID()
    : String(Date.now()) + '-' + Math.random().toString(16).slice(2);
  const heartbeatUrl = '/ui/heartbeat?id=' + encodeURIComponent(clientId);
  const heartbeat = () => fetch(heartbeatUrl, {
    method: 'POST', cache: 'no-store', keepalive: true
  }).catch(() => {});
  heartbeat();
  setInterval(heartbeat, 5000);
  document.addEventListener('visibilitychange', () => { if (!document.hidden) heartbeat(); });
  window.addEventListener('pageshow', heartbeat);
  window.addEventListener('pagehide', () => {
    try { navigator.sendBeacon('/ui/goodbye?id=' + encodeURIComponent(clientId), ''); } catch {}
  });
})();
</script>
'@
    if ($html.Contains('</body>')) {
        $html = $html.Replace('</body>', $lifecycleScript + [Environment]::NewLine + '</body>')
    } else {
        $html += $lifecycleScript
    }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($html)
    $Context.Response.StatusCode = 200
    $Context.Response.ContentType = 'text/html; charset=utf-8'
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.Headers['Cache-Control'] = 'no-store'
    [void](Send-ResponseBytes -Context $Context -Bytes $bytes)
}

function Send-LibraryStream {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Id)
    $file = Resolve-UiLibraryFile -Id $Id
    if (-not $file) {
        Send-Json -Context $Context -Body @{ error = 'FILE_NOT_FOUND'; id = $Id } -StatusCode 404
        return
    }

    $contentTypes = @{
        '.mp3' = 'audio/mpeg'; '.flac' = 'audio/flac'; '.wav' = 'audio/wav'
        '.aac' = 'audio/aac'; '.m4a' = 'audio/mp4'
    }
    $ext = [System.IO.Path]::GetExtension($file).ToLowerInvariant()
    $contentType = if ($contentTypes.ContainsKey($ext)) { $contentTypes[$ext] } else { 'application/octet-stream' }

    $length = (Get-Item -LiteralPath $file).Length

    # HTTP Range support is required for the browser <audio> element to seek
    # (drag the progress bar / jump forward). Parse "Range: bytes=start-end".
    $rangeHeader = $Context.Request.Headers['Range']
    $start = 0
    $end = $length - 1
    $isPartial = $false
    if ($rangeHeader -match 'bytes=(\d*)-(\d*)') {
        $rStart = $Matches[1]; $rEnd = $Matches[2]
        if ($rStart -ne '') { $start = [long]$rStart }
        if ($rEnd -ne '') { $end = [Math]::Min([long]$rEnd, $length - 1) }
        # Suffix range: bytes=-N means last N bytes.
        if ($rStart -eq '' -and $rEnd -ne '') {
            $n = [Math]::Min([long]$rEnd, $length)
            $start = $length - $n; $end = $length - 1
        }
        if ($start -ge $length) {
            # Requested range beyond EOF: 416.
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
    $stream = [System.IO.File]::Open($file, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $Context.Response.StatusCode = if ($isPartial) { 206 } else { 200 }
        $Context.Response.ContentType = $contentType
        $Context.Response.Headers['Accept-Ranges'] = 'bytes'
        $Context.Response.ContentLength64 = $chunkLength
        if ($isPartial) {
            $Context.Response.Headers['Content-Range'] = "bytes $start-$end/$length"
        }
        if ($start -gt 0) { [void]$stream.Seek($start, [System.IO.SeekOrigin]::Begin) }
        $buffer = New-Object byte[] 65536
        $outStream = $Context.Response.OutputStream
        $remaining = $chunkLength
        while ($remaining -gt 0) {
            $toRead = [int][Math]::Min($buffer.Length, $remaining)
            $read = $stream.Read($buffer, 0, $toRead)
            if ($read -le 0) { break }
            $remaining -= $read
            # Async write + timeout: if the client (audio element) went away,
            # abort instead of blocking the single UI thread forever.
            try {
                $chunk = New-Object byte[] $read
                [Array]::Copy($buffer, $chunk, $read)
                $async = $outStream.BeginWrite($chunk, 0, $read, $null, $null)
                if (-not $async.AsyncWaitHandle.WaitOne(5000)) {
                    try { $Context.Response.Abort() } catch {}
                    break
                }
                $outStream.EndWrite($async)
            } catch {
                try { $Context.Response.Abort() } catch {}
                break
            }
        }
    } finally {
        $stream.Dispose()
        try { $Context.Response.OutputStream.Close() } catch {}
    }
}

function Send-LibraryLyrics {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Id)
    $file = Resolve-UiLibraryFile -Id $Id
    $lrcPath = if ($file) { Get-LrcPath -File $file } else { $null }
    if (-not $lrcPath) {
        Send-LyricsJson -Context $Context -Id $Id -Available $false -Text '' -Quality 'MISSING' -Source 'local' -Path '' -Message '这首歌暂时没有找到本地歌词。'
        return
    }

    $quality = Get-LyricQuality -File $file
    if ($quality -in @('SUSPECT','NO_MATCH','NO_LYRIC','ERROR')) {
        Send-LyricsJson -Context $Context -Id $Id -Available $false -Text '' -Quality $quality -Source 'local' -Path '' -Message '歌词匹配置信度不足，已隐藏，避免显示错误歌词。'
        return
    }

    $lyrics = Get-Content -LiteralPath $lrcPath -Raw -Encoding UTF8
    if ($lyrics -match '^\s*lrc\s*=\s*(.+)$') {
        try {
            $payload = ConvertFrom-Json -InputObject $Matches[1].Trim()
            if ($payload.lrc) { $lyrics = [string]$payload.lrc }
        } catch {}
    }
    Send-LyricsJson -Context $Context -Id $Id -Available $true -Text $lyrics -Quality $quality -Source 'local' -Path $lrcPath -Message ''
}

function Send-TrackLyrics {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$TrackId)

    $trackUrl = $ApiPrefix.TrimEnd('/') + '/api/tracks/' + [System.Uri]::EscapeDataString($TrackId)
    $details = $null
    try {
        $details = Invoke-RestMethod -Uri $trackUrl -TimeoutSec 10
    } catch {
        $body = '{"track_id":' + (ConvertTo-JsonStringValue $TrackId) + ',"available":false,"format":"lrc","text":"","quality":"MISSING","source":"none","message":"无法读取歌曲信息，暂时无法获取歌词。"}'
        Send-JsonRaw -Context $Context -Json $body
        return
    }

    $neteaseId = Get-NeteaseIdForTrack -TrackResponse $details
    if ($neteaseId) {
        $lyrics = Get-NetEaseLyricsById -SongId $neteaseId
        if (-not [string]::IsNullOrWhiteSpace($lyrics)) {
            $body = '{"track_id":' + (ConvertTo-JsonStringValue $TrackId) + ',"available":true,"format":"lrc","text":' + (ConvertTo-JsonStringValue $lyrics) + ',"quality":"EXACT","source":"netease","song_id":' + (ConvertTo-JsonStringValue $neteaseId) + ',"message":""}'
            Send-JsonRaw -Context $Context -Json $body
            return
        }
    }

    $playback = $details.playback_source
    if ($playback -and ([string]$playback.provider).ToLowerInvariant() -eq 'navidrome' -and $playback.id) {
        Send-LibraryLyrics -Context $Context -Id ([string]$playback.id)
        return
    }

    $missingSource = 'none'
    $missingMessage = '这首歌暂时没有可验证的歌词来源。'
    if ($neteaseId) {
        $missingSource = 'netease'
        $missingMessage = '网易云暂未返回这首歌的歌词。'
    }
    $body = '{"track_id":' + (ConvertTo-JsonStringValue $TrackId) + ',"available":false,"format":"lrc","text":"","quality":"MISSING","source":' + (ConvertTo-JsonStringValue $missingSource) + ',"message":' + (ConvertTo-JsonStringValue $missingMessage) + '}'
    Send-JsonRaw -Context $Context -Json $body
}

# Sends a pre-serialized JSON string with the standard headers.
function Send-JsonRaw {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Json, [int]$StatusCode = 200)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Json)
    try {
        $Context.Response.StatusCode = $StatusCode
        $Context.Response.ContentType = 'application/json; charset=utf-8'
        $Context.Response.ContentLength64 = $bytes.Length
        $Context.Response.Headers['Cache-Control'] = 'no-store'
    } catch {
        try { $Context.Response.Abort() } catch {}
        return
    }
    [void](Send-ResponseBytes -Context $Context -Bytes $bytes)
}

function Proxy-ApiRequest {
    param([Parameter(Mandatory)]$Context)

    $request = $Context.Request
    $pathAndQuery = $request.Url.PathAndQuery
    if ($pathAndQuery -match '^/api/recommendations/today(?:\?|$)') {
        $pathAndQuery = $pathAndQuery -replace '^/api/recommendations/today', '/api/today'
    }

    $target = $ApiPrefix.TrimEnd('/') + $pathAndQuery
    $proxyRequest = [System.Net.HttpWebRequest]::Create($target)
    $proxyRequest.Method = $request.HttpMethod
    $proxyRequest.AllowAutoRedirect = $false
    $proxyRequest.Timeout = 20000
    $proxyRequest.ReadWriteTimeout = 20000
    if ($request.ContentType) { $proxyRequest.ContentType = $request.ContentType }
    if ($request.ContentLength64 -gt 0) {
        $proxyRequest.ContentLength = $request.ContentLength64
        $out = $proxyRequest.GetRequestStream()
        try { $request.InputStream.CopyTo($out) } finally { $out.Dispose() }
    } elseif ($request.HttpMethod -in @('POST','PUT','PATCH','DELETE')) {
        # A bodyless POST/DELETE must still declare Content-Length: 0. HttpWebRequest
        # otherwise leaves the length unspecified and the HttpListener on the API
        # side answers 411 Length Required, which the browser surfaces as a failed
        # like/queue/delete action even though the backend is healthy.
        $proxyRequest.ContentLength = 0
    }

    $proxyResponse = $null
    try {
        $proxyResponse = $proxyRequest.GetResponse()
    } catch [System.Net.WebException] {
        if ($_.Exception.Response) { $proxyResponse = $_.Exception.Response } else { throw }
    }

    try {
        $Context.Response.StatusCode = [int]$proxyResponse.StatusCode
        if ($proxyResponse.ContentType) { $Context.Response.ContentType = $proxyResponse.ContentType }
        if ($proxyResponse.Headers['Location']) { $Context.Response.RedirectLocation = $proxyResponse.Headers['Location'] }
        if ($proxyResponse.ContentLength -ge 0) { $Context.Response.ContentLength64 = [long]$proxyResponse.ContentLength }
        else { $Context.Response.SendChunked = $true }
        $input = $proxyResponse.GetResponseStream()
        try {
            $buffer = New-Object byte[] 65536
            $outStream = $Context.Response.OutputStream
            while (($read = $input.Read($buffer, 0, $buffer.Length)) -gt 0) {
                # Client (browser) may have gone away mid-response. Async write with
                # a timeout so a dead socket never wedges the single UI thread.
                try {
                    $chunk = New-Object byte[] $read
                    [Array]::Copy($buffer, $chunk, $read)
                    $async = $outStream.BeginWrite($chunk, 0, $read, $null, $null)
                    if (-not $async.AsyncWaitHandle.WaitOne(5000)) {
                        try { $Context.Response.Abort() } catch {}
                        break
                    }
                    $outStream.EndWrite($async)
                } catch {
                    try { $Context.Response.Abort() } catch {}
                    break
                }
            }
        } finally { if ($input) { $input.Dispose() } }
    } finally {
        $proxyResponse.Dispose()
        try { $Context.Response.OutputStream.Close() } catch {}
    }
}

function Get-ClientId {
    param([Parameter(Mandatory)]$Request)
    try {
        $query = [System.Web.HttpUtility]::ParseQueryString($Request.Url.Query)
        return [string]$query['id']
    } catch { return '' }
}

function Register-ClientHeartbeat {
    param([string]$Id)
    if ([string]::IsNullOrWhiteSpace($Id)) { return }
    $script:Clients[$Id] = [DateTime]::UtcNow
    $script:HasSeenClient = $true
    $script:NoClientSince = $null
}

function Remove-Client {
    param([string]$Id)
    if (-not [string]::IsNullOrWhiteSpace($Id)) { [void]$script:Clients.Remove($Id) }
    if ($script:HasSeenClient -and $script:Clients.Count -eq 0 -and -not $script:NoClientSince) {
        $script:NoClientSince = [DateTime]::UtcNow
    }
}

function Remove-StaleClients {
    $now = [DateTime]::UtcNow
    foreach ($id in @($script:Clients.Keys)) {
        $lastSeen = [DateTime]$script:Clients[$id]
        if (($now - $lastSeen).TotalSeconds -ge $ClientTimeoutSeconds) {
            [void]$script:Clients.Remove($id)
        }
    }
    if ($script:HasSeenClient -and $script:Clients.Count -eq 0 -and -not $script:NoClientSince) {
        $script:NoClientSince = $now
    }
}

function Should-AutoStop {
    if ($NoBrowser) { return $false }
    $now = [DateTime]::UtcNow
    if (-not $script:HasSeenClient) { return ($now -ge $script:StartupDeadline) }
    if ($script:Clients.Count -gt 0) { return $false }
    if (-not $script:NoClientSince) { $script:NoClientSince = $now; return $false }
    return (($now - $script:NoClientSince).TotalSeconds -ge $LastClientGraceSeconds)
}

function Handle-Request {
    param([Parameter(Mandatory)]$Context)
    $path = $Context.Request.Url.AbsolutePath
    $script:CurrentRequest = "$($Context.Request.HttpMethod) $path"
    $script:LastActivityAt = [DateTime]::UtcNow

    if ($path -eq '/ui/heartbeat' -and $Context.Request.HttpMethod -eq 'POST') {
        Register-ClientHeartbeat -Id (Get-ClientId -Request $Context.Request)
        $Context.Response.StatusCode = 204
        $Context.Response.Close()
        return
    }
    if ($path -eq '/ui/goodbye' -and $Context.Request.HttpMethod -eq 'POST') {
        Remove-Client -Id (Get-ClientId -Request $Context.Request)
        $Context.Response.StatusCode = 204
        $Context.Response.Close()
        return
    }

    switch ($path) {
        '/'            { Send-IndexHtml -Context $Context; return }
        '/index.html'  { Send-IndexHtml -Context $Context; return }
        '/app.js'      { Send-StaticFile -Context $Context -RelativePath 'app.js' -ContentType 'application/javascript; charset=utf-8'; return }
        '/styles.css'  { Send-StaticFile -Context $Context -RelativePath 'styles.css' -ContentType 'text/css; charset=utf-8'; return }
        '/favicon.ico' { $Context.Response.StatusCode = 204; $Context.Response.Close(); return }
        '/api/library' {
            if ($Context.Request.HttpMethod -eq 'GET') {
                $items = @(Get-UiLibrary)
                Send-Json -Context $Context -Body @{ items = $items; total = $items.Count }
                return
            }
        }
    }

    if ($Context.Request.HttpMethod -eq 'DELETE' -and $path -match '^/api/library/([^/]+)$') {
        # Deleting a library track: proxy to the API, then invalidate the local
        # library caches so the next /api/library request reflects the deletion.
        Proxy-ApiRequest -Context $Context
        $script:UiLibraryCache = $null
        $script:UiLibraryCacheAt = [DateTime]::MinValue
        $script:LibraryFiles = @{}
        return
    }
    if ($Context.Request.HttpMethod -eq 'GET' -and $path -match '^/api/library/([^/]+)/stream$') {
        $id = [System.Web.HttpUtility]::UrlDecode($Matches[1], [System.Text.Encoding]::UTF8)
        Send-LibraryStream -Context $Context -Id $id
        return
    }
    if ($Context.Request.HttpMethod -eq 'GET' -and $path -match '^/api/library/([^/]+)/lyrics$') {
        $id = [System.Web.HttpUtility]::UrlDecode($Matches[1], [System.Text.Encoding]::UTF8)
        Send-LibraryLyrics -Context $Context -Id $id
        return
    }
    if ($Context.Request.HttpMethod -eq 'GET' -and $path -match '^/api/tracks/([^/]+)/lyrics$') {
        $trackId = [System.Web.HttpUtility]::UrlDecode($Matches[1], [System.Text.Encoding]::UTF8)
        Send-TrackLyrics -Context $Context -TrackId $trackId
        return
    }
    if ($path -eq '/health' -or $path.StartsWith('/api/')) {
        Proxy-ApiRequest -Context $Context
        return
    }

    $Context.Response.StatusCode = 404
    $Context.Response.Close()
}

if (-not (Test-Path -LiteralPath (Join-Path $WebRoot 'index.html') -PathType Leaf)) {
    throw "Web UI not found under $WebRoot"
}

if (Test-UiReady) {
    Write-UiLog "UI already running at $UiPrefix; opening existing instance"
    # Ensure the wanted worker is running even when an older UI instance (started
    # before the worker was added to this launcher) already holds the UI port.
    Start-MusicServerWorker
    if (-not $NoBrowser) { try { Start-Process $UiPrefix | Out-Null } catch {} }
    return
}

try {
    Start-MusicServerApi
    Start-MusicServerWorker

    $script:Listener = [System.Net.HttpListener]::new()
    $script:Listener.Prefixes.Add($UiPrefix)
    try {
        $script:Listener.Start()
    } catch {
        # Race: another launcher grabbed the prefix between the port probe and
        # Start(). Not an error for the user - the other instance serves the UI.
        Write-UiLog "UI prefix already taken by another instance; opening existing UI."
        if (-not $NoBrowser) { try { Start-Process $UiPrefix | Out-Null } catch {} }
        return
    }
    Write-UiLog "UI started at $UiPrefix pid=$PID"

    # External watchdog: watches the heartbeat file this loop writes and
    # restarts the UI if a wedged handler freezes the single-threaded listener.
    try {
        $watchdog = Join-Path $Root 'watchdog_ui.ps1'
        if (Test-Path -LiteralPath $watchdog -PathType Leaf) {
            $wdArgs = @('-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File', ('"' + $watchdog + '"'), '-HeartbeatFile', ('"' + $UiHeartbeatFile + '"'), '-WatchPid', ([string]$PID), '-RestartScript', ('"' + $PSCommandPath + '"'), '-WorkingDir', ('"' + $Root + '"'), '-LogFile', ('"' + $WatchdogLog + '"'))
            Start-Process -FilePath 'powershell.exe' -ArgumentList $wdArgs -WindowStyle Hidden | Out-Null
            Write-UiLog "Watchdog started (heartbeat=$UiHeartbeatFile pid=$PID)"
        }
    } catch {
        Write-UiLog "Watchdog start failed: $($_.Exception.Message)"
    }

    if (-not $NoBrowser) {
        try { Start-Process $UiPrefix | Out-Null } catch { Write-UiLog "Could not open browser: $($_.Exception.Message)" }
    }

    $pending = $script:Listener.BeginGetContext($null, $null)
    while ($script:Listener.IsListening) {
        if ($pending.AsyncWaitHandle.WaitOne(1000)) {
            $context = $script:Listener.EndGetContext($pending)
            if ($script:Listener.IsListening) { $pending = $script:Listener.BeginGetContext($null, $null) }
            try {
                $reqStart = [DateTime]::UtcNow
                Handle-Request -Context $context
                $reqMs = [int]([DateTime]::UtcNow - $reqStart).TotalMilliseconds
                if ($reqMs -gt 2000) { Write-UiLog "SLOW $($context.Request.Url.AbsolutePath) took ${reqMs}ms" }
            } catch {
                Write-UiLog "UI request failed: $($_.Exception.Message)"
                try {
                    if ($context.Response.OutputStream.CanWrite) {
                        $context.Response.StatusCode = 502
                        $context.Response.Close()
                    }
                } catch {}
            }
            $script:LastActivityAt = [DateTime]::UtcNow
            $script:CurrentRequest = ''
        }

        Remove-StaleClients
        # Heartbeat for the external watchdog: updated every main-loop iteration.
        try { [System.IO.File]::WriteAllText($UiHeartbeatFile, [DateTime]::UtcNow.ToString('o')) } catch {}
        if (Should-AutoStop) {
            Write-UiLog 'No active browser clients remain; stopping UI and owned API process.'
            break
        }
    }
} catch {
    Write-UiLog "Launcher failed: $($_.Exception.Message)"
    throw
} finally {
    if ($script:Listener) {
        try { if ($script:Listener.IsListening) { $script:Listener.Stop() } } catch {}
        try { $script:Listener.Close() } catch {}
    }
    if ($StartedApi -and $ApiProcess -and -not $ApiProcess.HasExited) {
        try {
            Stop-Process -Id $ApiProcess.Id -Force -ErrorAction SilentlyContinue
            Write-UiLog "Stopped owned API pid=$($ApiProcess.Id)"
        } catch {}
    }
    if ($StartedWorker -and $WorkerProcess -and -not $WorkerProcess.HasExited) {
        try {
            Stop-Process -Id $WorkerProcess.Id -Force -ErrorAction SilentlyContinue
            Write-UiLog "Stopped owned worker pid=$($WorkerProcess.Id)"
        } catch {}
    }
    Write-UiLog 'UI launcher stopped.'
}
