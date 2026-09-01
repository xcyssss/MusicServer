<#
.SYNOPSIS
    Real-HTTP racing client used by MusicServer.ApiRuntime.Tests.ps1 (R1).

    Waits until the barrier file is DELETED by the parent (simultaneity gate),
    then fires POST {BaseUrl}/api/tracks/{TrackId}/like and records
    status / accepted / liked / action / reason / elapsed_ms into -OutFile.

    Run as a standalone Windows PowerShell / pwsh process - no Pester, no
    server modules. Raw .NET HTTP for minimal dispatch latency.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BaseUrl,
    [Parameter(Mandatory)][string]$TrackId,
    [Parameter(Mandatory)][string]$BarrierFile,
    [Parameter(Mandatory)][string]$OutFile,
    [Parameter(Mandatory)][string]$ReadyFile,
    [ValidateRange(1000, 120000)][int]$BarrierTimeoutMs = 20000
)

$ErrorActionPreference = 'Stop'

$sw = [System.Diagnostics.Stopwatch]::StartNew()

# ---- arm: tell parent we are waiting on the barrier -----------------------
Set-Content -LiteralPath $ReadyFile -Value ([DateTime]::UtcNow.ToString('o'))

# ---- wait for the barrier to be released -----------------------------------
$deadline = [DateTime]::UtcNow.AddMilliseconds([double]$BarrierTimeoutMs)
while (Test-Path -LiteralPath $BarrierFile) {
    if ([DateTime]::UtcNow -gt $deadline) {
        # Parent failed to release; write a failure record and exit.
        [ordered]@{ status = -1; accepted = $false; liked = $false; action = 'BARRIER_TIMEOUT'; reason = 'barrier not released' } |
            ConvertTo-Json | Set-Content -LiteralPath $OutFile -Encoding UTF8
        exit 1
    }
    Start-Sleep -Milliseconds 5
}
$sw.Restart()

# ---- fire the like request -------------------------------------------------
$body = ''
try {
    $request = [System.Net.HttpWebRequest]::Create($BaseUrl.TrimEnd('/') + "/api/tracks/$TrackId/like")
    $request.Method = 'POST'
    $request.Timeout = 15000
    $request.ReadWriteTimeout = 15000
    $request.ContentType = 'application/json; charset=utf-8'
    # Keep-alive bodyless POST requires an explicit Content-Length or the
    # HttpListener answers 411 Length Required (proven under PS 5.1).
    if ($request.GetType().GetProperty('ContentLength64')) { $request.ContentLength64 = 0 } else { $request.ContentLength = 0 }
    $response = $request.GetResponse()
    $stream = $response.GetResponseStream()
    $ms = [System.IO.MemoryStream]::new()
    $buf = New-Object byte[] 8192
    while (($n = $stream.Read($buf, 0, $buf.Length)) -gt 0) { $ms.Write($buf, 0, $n) }
    $body = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
    $status = [int]$response.StatusCode
    $response.Dispose()
}
catch [System.Net.WebException] {
    $we = $_.Exception
    $status = -1
    $body = ''
    if ($we.Response) {
        try {
            $resp = $we.Response
            $status = [int]$resp.StatusCode
            $stream = $resp.GetResponseStream()
            $ms = [System.IO.MemoryStream]::new()
            $buf = New-Object byte[] 8192
            while (($n = $stream.Read($buf, 0, $buf.Length)) -gt 0) { $ms.Write($buf, 0, $n) }
            $body = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
            $resp.Dispose() | Out-Null
        } catch { $body = '' }
    }
}
$sw.Stop()

$result = [ordered]@{
    status      = [int]$status
    accepted    = $false
    liked       = $false
    action      = ''
    reason      = ''
    elapsed_ms  = [long]$sw.ElapsedMilliseconds
}
if ($body) {
    try {
        $json = $body | ConvertFrom-Json
        if ($json.PSObject.Properties['accepted'])  { $result.accepted = [bool]$json.accepted }
        if ($json.PSObject.Properties['liked'])     { $result.liked = [bool]$json.liked }
        if ($json.PSObject.Properties['action'])    { $result.action = [string]$json.action }
        if ($json.PSObject.Properties['reason'])    { $result.reason = [string]$json.reason }
    } catch {}
}
$result | ConvertTo-Json | Set-Content -LiteralPath $OutFile -Encoding UTF8
exit 0
