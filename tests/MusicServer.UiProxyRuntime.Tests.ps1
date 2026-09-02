$ErrorActionPreference = 'Stop'

$ProjectRoot = Split-Path -Parent $PSScriptRoot

Import-Module (Join-Path $ProjectRoot 'MusicServer.Core.psm1') -Force
Import-Module (Join-Path $ProjectRoot 'MusicServer.Database.psm1') -Force
Import-Module (Join-Path $ProjectRoot 'MusicServer.State.psm1') -Force

$script:ProxyTest = [pscustomobject]@{
    Root = $null
    Processes = @()
}

function Get-TestTermExe {
    $cmd = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return (Get-Command powershell.exe -ErrorAction Stop).Source
}

function Get-TestFreePort {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = [int]$listener.LocalEndpoint.Port
    $listener.Stop()
    return $port
}

function Stop-ProxyTestProcesses {
    foreach ($proc in @($script:ProxyTest.Processes)) {
        try {
            if ($proc -and -not $proc.HasExited) {
                & cmd.exe /c "taskkill /PID $($proc.Id) /T /F" 6>&1 | Out-Null
                $proc.WaitForExit(5000) | Out-Null
            }
        } catch {}
        try { if ($proc) { $proc.Dispose() | Out-Null } } catch {}
    }
    $script:ProxyTest.Processes = @()
}

function Wait-TestHealth {
    param([Parameter(Mandatory)][string]$BaseUrl, [int]$TimeoutSeconds = 40)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $health = Invoke-RestMethod -Uri ($BaseUrl.TrimEnd('/') + '/health') -TimeoutSec 2
            if ([string]$health.status -eq 'ok') { return }
        } catch {}
        Start-Sleep -Milliseconds 200
    }
    throw "Health endpoint did not become ready: $BaseUrl"
}

function Invoke-TestJsonHttp {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Method
    )

    $status = -1
    $text = ''
    try {
        $request = [System.Net.HttpWebRequest]::Create($Url)
        $request.Method = $Method
        $request.Timeout = 20000
        $request.ReadWriteTimeout = 20000
        $request.ContentType = 'application/json; charset=utf-8'
        $body = [System.Text.Encoding]::UTF8.GetBytes('{}')
        $request.ContentLength = $body.Length
        $out = $request.GetRequestStream()
        try { $out.Write($body, 0, $body.Length) } finally { $out.Dispose() }
        $response = $request.GetResponse()
        try {
            $status = [int]$response.StatusCode
            $reader = New-Object System.IO.StreamReader($response.GetResponseStream(), [System.Text.Encoding]::UTF8)
            try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
        } finally { $response.Dispose() }
    } catch [System.Net.WebException] {
        if ($_.Exception.Response) {
            $response = $_.Exception.Response
            try {
                $status = [int]$response.StatusCode
                $reader = New-Object System.IO.StreamReader($response.GetResponseStream(), [System.Text.Encoding]::UTF8)
                try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
            } finally { $response.Dispose() }
        } else {
            throw
        }
    }

    $json = $null
    if ($text) { try { $json = $text | ConvertFrom-Json } catch {} }
    return [pscustomobject]@{ Status = $status; Text = $text; Json = $json }
}

Describe 'MusicServer live UI API proxy' {
    BeforeEach {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('msuiproxy_' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path (Join-Path $root 'DailyMix_data\state') -Force
        $script:ProxyTest.Root = $root

        $cfg = New-MusicServerConfig -Root $root
        Initialize-MusicServerState -Config $cfg
        $db = Join-Path $cfg.StateDir 'musicserver.db'
        Initialize-MusicServerDatabase -DbPath $db -SqliteExe $cfg.Sqlite
        Initialize-MusicServerSchema
    }

    AfterEach {
        Stop-ProxyTestProcesses
        if ($script:ProxyTest.Root) {
            try { Remove-Item -LiteralPath $script:ProxyTest.Root -Recurse -Force -ErrorAction SilentlyContinue } catch {}
        }
        $script:ProxyTest.Root = $null
    }

    It 'forwards browser-style JSON-body POST like requests through the UI gateway' {
        $app = Get-Content -LiteralPath (Join-Path $ProjectRoot 'web\app.js') -Raw
        $app | Should Match "headers:\s*\{\s*'Content-Type':\s*'application/json; charset=utf-8'\s*\}"
        $app | Should Match "body:\s*'\{\}'"

        $suffix = [guid]::NewGuid().ToString('N').Substring(0, 8)
        $track = New-CanonicalTrack -Title ('Proxy Track ' + $suffix) -Artist ('Proxy Artist ' + $suffix) -Status 'REMOTE'
        $saved = Save-CanonicalTrackDb -Track $track
        $saved.Success | Should Be $true
        $trackId = [string]$track.id

        $apiPort = Get-TestFreePort
        $uiPort = Get-TestFreePort
        $apiPrefix = "http://127.0.0.1:$apiPort/"
        $uiPrefix = "http://127.0.0.1:$uiPort/"
        $term = Get-TestTermExe

        $apiOut = Join-Path $script:ProxyTest.Root 'api.out.log'
        $apiErr = Join-Path $script:ProxyTest.Root 'api.err.log'
        $apiArgs = @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $ProjectRoot 'music_api.ps1'),'-Prefix',$apiPrefix,'-Root',$script:ProxyTest.Root)
        $api = Start-Process -FilePath $term -ArgumentList $apiArgs -WindowStyle Hidden -PassThru -RedirectStandardOutput $apiOut -RedirectStandardError $apiErr
        $script:ProxyTest.Processes += $api
        Wait-TestHealth -BaseUrl $apiPrefix

        $uiOut = Join-Path $script:ProxyTest.Root 'ui.out.log'
        $uiErr = Join-Path $script:ProxyTest.Root 'ui.err.log'
        $uiArgs = @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $ProjectRoot 'start_musicserver_ui.ps1'),'-ApiPrefix',$apiPrefix,'-UiPrefix',$uiPrefix,'-NoBrowser')
        $ui = Start-Process -FilePath $term -ArgumentList $uiArgs -WindowStyle Hidden -PassThru -RedirectStandardOutput $uiOut -RedirectStandardError $uiErr
        $script:ProxyTest.Processes += $ui
        Wait-TestHealth -BaseUrl $uiPrefix

        $like = Invoke-TestJsonHttp -Method 'POST' -Url ($uiPrefix.TrimEnd('/') + "/api/tracks/$trackId/like")
        $like.Status | Should Be 200 -Because "the UI proxy must forward the browser-style JSON body; response was [$($like.Text)]"
        $like.Json.accepted | Should Be $true
        $like.Json.liked | Should Be $true
        $like.Json.action | Should Be 'QUEUED'

        $wanted = Get-WantedItemDb -TrackId $trackId
        $wanted.state | Should Be 'WANTED'
    }
}
