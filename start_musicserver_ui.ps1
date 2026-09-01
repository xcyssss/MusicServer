param(
    [string]$ApiPrefix = 'http://127.0.0.1:8787/',
    [string]$UiPrefix = 'http://127.0.0.1:8790/',
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Root = $PSScriptRoot
$WebRoot = Join-Path $Root 'web'
$ApiScript = Join-Path $Root 'music_api.ps1'
$ApiProcess = $null
$StartedApi = $false

function Test-ApiReady {
    try {
        $health = Invoke-RestMethod -Uri ($ApiPrefix.TrimEnd('/') + '/health') -TimeoutSec 2
        return ([string]$health.status -eq 'ok')
    } catch {
        return $false
    }
}

function Start-MusicServerApi {
    if (Test-ApiReady) {
        Write-Host "MusicServer API is already running at $ApiPrefix" -ForegroundColor Green
        return
    }

    if (-not (Test-Path -LiteralPath $ApiScript -PathType Leaf)) {
        throw "music_api.ps1 not found: $ApiScript"
    }

    $escapedScript = $ApiScript.Replace('"', '\"')
    $escapedPrefix = $ApiPrefix.Replace('"', '\"')
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$escapedScript`" -Prefix `"$escapedPrefix`""
    $script:ApiProcess = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WorkingDirectory $Root -PassThru
    $script:StartedApi = $true

    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Milliseconds 500
        if (Test-ApiReady) {
            Write-Host "MusicServer API started at $ApiPrefix" -ForegroundColor Green
            return
        }
        if ($script:ApiProcess.HasExited) {
            throw "music_api.ps1 exited before /health became ready. ExitCode=$($script:ApiProcess.ExitCode)"
        }
    }

    throw "MusicServer API did not become healthy at $ApiPrefix"
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

    $bytes = [IO.File]::ReadAllBytes($file)
    $Context.Response.StatusCode = 200
    $Context.Response.ContentType = $ContentType
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.Headers['Cache-Control'] = 'no-store'
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.OutputStream.Close()
}

function Proxy-ApiRequest {
    param([Parameter(Mandatory)]$Context)

    $request = $Context.Request
    $pathAndQuery = $request.Url.PathAndQuery

    # The current web client still uses the pre-v2 route name. Keep the UI
    # compatible without changing the stable backend API contract.
    if ($pathAndQuery -match '^/api/recommendations/today(?:\?|$)') {
        $pathAndQuery = $pathAndQuery -replace '^/api/recommendations/today', '/api/today'
    }

    $target = $ApiPrefix.TrimEnd('/') + $pathAndQuery
    $proxyRequest = [System.Net.HttpWebRequest]::Create($target)
    $proxyRequest.Method = $request.HttpMethod
    $proxyRequest.AllowAutoRedirect = $false
    $proxyRequest.Timeout = 30000
    $proxyRequest.ReadWriteTimeout = 30000

    if ($request.ContentType) {
        $proxyRequest.ContentType = $request.ContentType
    }
    if ($request.ContentLength64 -gt 0) {
        $proxyRequest.ContentLength = $request.ContentLength64
        $out = $proxyRequest.GetRequestStream()
        try {
            $request.InputStream.CopyTo($out)
        } finally {
            $out.Dispose()
        }
    }

    $proxyResponse = $null
    try {
        $proxyResponse = $proxyRequest.GetResponse()
    } catch [System.Net.WebException] {
        if ($_.Exception.Response) {
            $proxyResponse = $_.Exception.Response
        } else {
            throw
        }
    }

    try {
        $Context.Response.StatusCode = [int]$proxyResponse.StatusCode
        if ($proxyResponse.ContentType) {
            $Context.Response.ContentType = $proxyResponse.ContentType
        }
        if ($proxyResponse.Headers['Location']) {
            $Context.Response.RedirectLocation = $proxyResponse.Headers['Location']
        }

        $input = $proxyResponse.GetResponseStream()
        try {
            if ($input) {
                $input.CopyTo($Context.Response.OutputStream)
            }
        } finally {
            if ($input) { $input.Dispose() }
        }
    } finally {
        $proxyResponse.Dispose()
        $Context.Response.OutputStream.Close()
    }
}

if (-not (Test-Path -LiteralPath (Join-Path $WebRoot 'index.html') -PathType Leaf)) {
    throw "Web UI not found under $WebRoot"
}

Start-MusicServerApi

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add($UiPrefix)
try {
    $listener.Start()
} catch {
    throw "Could not listen on $UiPrefix. Another process may already be using this port. $($_.Exception.Message)"
}

Write-Host ''
Write-Host 'MusicServer is ready.' -ForegroundColor Green
Write-Host "Open: $UiPrefix" -ForegroundColor Cyan
Write-Host "API:  $ApiPrefix" -ForegroundColor DarkGray
Write-Host 'Press Ctrl+C to stop this UI launcher.' -ForegroundColor DarkGray

if (-not $NoBrowser) {
    try { Start-Process $UiPrefix | Out-Null } catch {}
}

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        try {
            $path = $context.Request.Url.AbsolutePath
            switch ($path) {
                '/'          { Send-StaticFile -Context $context -RelativePath 'index.html' -ContentType 'text/html; charset=utf-8'; continue }
                '/index.html' { Send-StaticFile -Context $context -RelativePath 'index.html' -ContentType 'text/html; charset=utf-8'; continue }
                '/app.js'     { Send-StaticFile -Context $context -RelativePath 'app.js' -ContentType 'application/javascript; charset=utf-8'; continue }
                '/styles.css' { Send-StaticFile -Context $context -RelativePath 'styles.css' -ContentType 'text/css; charset=utf-8'; continue }
                '/favicon.ico' { $context.Response.StatusCode = 204; $context.Response.Close(); continue }
            }

            if ($path -eq '/health' -or $path.StartsWith('/api/')) {
                Proxy-ApiRequest -Context $context
                continue
            }

            $context.Response.StatusCode = 404
            $context.Response.Close()
        } catch {
            Write-Host "UI request failed: $($_.Exception.Message)" -ForegroundColor Red
            try {
                if ($context.Response.OutputStream.CanWrite) {
                    $context.Response.StatusCode = 502
                    $context.Response.Close()
                }
            } catch {}
        }
    }
} finally {
    if ($listener.IsListening) { $listener.Stop() }
    $listener.Close()

    if ($StartedApi -and $ApiProcess -and -not $ApiProcess.HasExited) {
        try { Stop-Process -Id $ApiProcess.Id -Force -ErrorAction SilentlyContinue } catch {}
    }
}
