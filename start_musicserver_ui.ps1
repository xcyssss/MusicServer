param(
    [string]$ApiPrefix = 'http://127.0.0.1:8787/',
    [string]$UiPrefix = 'http://127.0.0.1:8790/',
    [switch]$NoBrowser,
    [int]$ClientTimeoutSeconds = 90,
    [int]$LastClientGraceSeconds = 8
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try { Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue } catch {}

$Root = $PSScriptRoot
$WebRoot = Join-Path $Root 'web'
$ApiScript = Join-Path $Root 'music_api.ps1'
$LogRoot = Join-Path $Root 'logs'
$UiLog = Join-Path $LogRoot 'musicserver-ui.log'
$ApiOutLog = Join-Path $LogRoot 'musicserver-api.stdout.log'
$ApiErrLog = Join-Path $LogRoot 'musicserver-api.stderr.log'
$ApiProcess = $null
$StartedApi = $false
$Listener = $null
$Clients = @{}
$HasSeenClient = $false
$NoClientSince = $null
$StartupDeadline = [DateTime]::UtcNow.AddSeconds(60)
$LibraryFiles = @{}

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
        $health = Invoke-RestMethod -Uri ($ApiPrefix.TrimEnd('/') + '/health') -TimeoutSec 2
        return ([string]$health.status -eq 'ok')
    } catch {
        return $false
    }
}

function Test-UiReady {
    try {
        $health = Invoke-RestMethod -Uri ($UiPrefix.TrimEnd('/') + '/health') -TimeoutSec 2
        return ([string]$health.status -eq 'ok')
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

function Get-UiLibrary {
    $items = New-Object System.Collections.ArrayList
    $seenFiles = @{}
    $script:LibraryFiles = @{}

    $sql = 'SELECT id, name, artist, album, path, duration, track, addedto, collectionat FROM songs;'
    foreach ($row in @(Invoke-NavidromeSqliteJson -Sql $sql)) {
        $file = [string]$row.path
        if ([string]::IsNullOrWhiteSpace($file)) { continue }
        try {
            if (-not [System.IO.Path]::IsPathRooted($file)) { $file = Join-Path $Root $file }
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
            [void]$items.Add([pscustomobject]@{
                id = $id; source = 'local'; provider = 'navidrome'
                name = $title; title = $title; artist = $artist; album = $artist
                duration = 0; track = 0; addedto = ''; collectionat = ''
                path = $file; file = $file
                stream_url = "/api/library/$id/stream"
                lyrics_url = if ($lrcPath) { "/api/library/$id/lyrics" } else { '' }
            })
        }
    }

    return @($items)
}

function Resolve-UiLibraryFile {
    param([Parameter(Mandatory)][string]$Id)
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

function Send-Json {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Body, [int]$StatusCode = 200)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Body -Depth 20))
    $Context.Response.StatusCode = $StatusCode
    $Context.Response.ContentType = 'application/json; charset=utf-8'
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.Headers['Cache-Control'] = 'no-store'
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.OutputStream.Close()
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
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.OutputStream.Close()
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
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.OutputStream.Close()
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
    $stream = [System.IO.File]::Open($file, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $Context.Response.StatusCode = 200
        $Context.Response.ContentType = $contentType
        $Context.Response.ContentLength64 = $stream.Length
        $buffer = New-Object byte[] 65536
        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $Context.Response.OutputStream.Write($buffer, 0, $read)
        }
    } finally {
        $stream.Dispose()
        $Context.Response.OutputStream.Close()
    }
}

function Send-LibraryLyrics {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Id)
    $file = Resolve-UiLibraryFile -Id $Id
    $lrcPath = if ($file) { Get-LrcPath -File $file } else { $null }
    if (-not $lrcPath) {
        Send-Json -Context $Context -Body @{ error = 'LYRICS_NOT_FOUND'; id = $Id } -StatusCode 404
        return
    }

    $lyrics = Get-Content -LiteralPath $lrcPath -Raw -Encoding UTF8
    if ($lyrics -match '^\s*lrc\s*=\s*(.+)$') {
        try {
            $payload = ConvertFrom-Json -InputObject $Matches[1].Trim()
            if ($payload.lrc) { $lyrics = [string]$payload.lrc }
        } catch {}
    }
    Send-Json -Context $Context -Body @{ id = $Id; lyrics = $lyrics; path = $lrcPath }
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
    $proxyRequest.Timeout = 30000
    $proxyRequest.ReadWriteTimeout = 30000
    if ($request.ContentType) { $proxyRequest.ContentType = $request.ContentType }
    if ($request.ContentLength64 -gt 0) {
        $proxyRequest.ContentLength = $request.ContentLength64
        $out = $proxyRequest.GetRequestStream()
        try { $request.InputStream.CopyTo($out) } finally { $out.Dispose() }
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
        try { if ($input) { $input.CopyTo($Context.Response.OutputStream) } }
        finally { if ($input) { $input.Dispose() } }
    } finally {
        $proxyResponse.Dispose()
        $Context.Response.OutputStream.Close()
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
    if (-not $NoBrowser) { try { Start-Process $UiPrefix | Out-Null } catch {} }
    return
}

try {
    Start-MusicServerApi

    $script:Listener = [System.Net.HttpListener]::new()
    $script:Listener.Prefixes.Add($UiPrefix)
    $script:Listener.Start()
    Write-UiLog "UI started at $UiPrefix pid=$PID"

    if (-not $NoBrowser) {
        try { Start-Process $UiPrefix | Out-Null } catch { Write-UiLog "Could not open browser: $($_.Exception.Message)" }
    }

    $pending = $script:Listener.BeginGetContext($null, $null)
    while ($script:Listener.IsListening) {
        if ($pending.AsyncWaitHandle.WaitOne(1000)) {
            $context = $script:Listener.EndGetContext($pending)
            if ($script:Listener.IsListening) { $pending = $script:Listener.BeginGetContext($null, $null) }
            try {
                Handle-Request -Context $context
            } catch {
                Write-UiLog "UI request failed: $($_.Exception.Message)"
                try {
                    if ($context.Response.OutputStream.CanWrite) {
                        $context.Response.StatusCode = 502
                        $context.Response.Close()
                    }
                } catch {}
            }
        }

        Remove-StaleClients
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
    Write-UiLog 'UI launcher stopped.'
}
