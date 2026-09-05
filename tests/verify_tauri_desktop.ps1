[CmdletBinding()]
param(
    [string]$Root = '',
    [string]$Executable = '',
    [switch]$Launch,
    [switch]$CloseLaunchedApp,
    [switch]$ExercisePlayback
)

$ErrorActionPreference = 'Stop'
$BuildMarker = 'musicserver-listening-stats-v2'
$launchedDesktopPid = $null
if (-not $Root) {
    $Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}
if (-not $Executable) {
    $Executable = Join-Path $Root 'src-tauri\target\release\musicserver-desktop.exe'
}

try {
function Get-DesktopProcess {
    return @(Get-CimInstance Win32_Process | Where-Object {
        $_.ExecutablePath -eq $Executable -or
        $_.CommandLine -match [regex]::Escape($Executable)
    })
}

function Get-HttpResult {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [hashtable]$Headers = @{},
        [int]$Attempts = 3
    )
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        $request = $null
        $response = $null
        try {
            $request = [System.Net.HttpWebRequest]::Create($Uri)
            $request.Method = 'GET'
            $request.KeepAlive = $false
            $request.Timeout = 8000
            $request.ReadWriteTimeout = 8000
            if ($Headers.ContainsKey('Range')) {
                $range = [regex]::Match([string]$Headers['Range'], '^bytes=(\d+)-(\d+)$')
                if ($range.Success) { $request.AddRange([int64]$range.Groups[1].Value, [int64]$range.Groups[2].Value) }
            }
            $response = [System.Net.HttpWebResponse]$request.GetResponse()
            $memory = New-Object System.IO.MemoryStream
            $input = $response.GetResponseStream()
            try { $input.CopyTo($memory) } finally { $input.Dispose() }
            return [pscustomobject]@{
                StatusCode = [int]$response.StatusCode
                Text = [System.Text.Encoding]::UTF8.GetString($memory.ToArray())
            }
        } catch [System.Net.WebException] {
            if ($_.Exception.Response) {
                return [pscustomobject]@{ StatusCode = [int]$_.Exception.Response.StatusCode; Text = '' }
            }
        } catch {
        } finally {
            if ($response) { $response.Dispose() }
        }
        if ($attempt -lt $Attempts) { Start-Sleep -Milliseconds 400 }
    }
    return $null
}

function Send-JsonPost {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Body,
        [int]$Attempts = 3
    )
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        $request = $null
        $response = $null
        try {
            $request = [System.Net.HttpWebRequest]::Create($Uri)
            $request.Method = 'POST'
            $request.KeepAlive = $false
            $request.ContentType = 'application/json; charset=utf-8'
            $request.Timeout = 8000
            $request.ReadWriteTimeout = 8000
            $payload = [System.Text.Encoding]::UTF8.GetBytes($Body)
            $request.ContentLength = $payload.Length
            $output = $request.GetRequestStream()
            try { $output.Write($payload, 0, $payload.Length) } finally { $output.Dispose() }
            $response = [System.Net.HttpWebResponse]$request.GetResponse()
            $memory = New-Object System.IO.MemoryStream
            $input = $response.GetResponseStream()
            try { $input.CopyTo($memory) } finally { $input.Dispose() }
            return [pscustomobject]@{
                StatusCode = [int]$response.StatusCode
                Text = [System.Text.Encoding]::UTF8.GetString($memory.ToArray())
            }
        } catch [System.Net.WebException] {
            if ($_.Exception.Response) {
                $errorResponse = [System.Net.HttpWebResponse]$_.Exception.Response
                try {
                    return [pscustomobject]@{ StatusCode = [int]$errorResponse.StatusCode; Text = '' }
                } finally {
                    $errorResponse.Dispose()
                }
            }
        } catch {
        } finally {
            if ($response) { $response.Dispose() }
        }
        if ($attempt -lt $Attempts) { Start-Sleep -Milliseconds 400 }
    }
    return $null
}

function Find-CurrentServicePair {
    foreach ($pair in @(
        [pscustomobject]@{ UiPort = 8790; ApiPort = 8787 },
        [pscustomobject]@{ UiPort = 8791; ApiPort = 8788 },
        [pscustomobject]@{ UiPort = 8792; ApiPort = 8789 }
    )) {
        $app = Get-HttpResult -Uri "http://127.0.0.1:$($pair.UiPort)/app.js"
        $health = Get-HttpResult -Uri "http://127.0.0.1:$($pair.ApiPort)/health"
        if ($app -and $health -and $app.StatusCode -eq 200 -and $health.StatusCode -eq 200 -and
            $app.Text.Contains($BuildMarker) -and $health.Text.Contains($BuildMarker)) {
            $pair
            return
        }
    }
}

if ($CloseLaunchedApp -and -not $Launch) {
    throw '-CloseLaunchedApp requires -Launch so an unrelated desktop process cannot be terminated.'
}

$existing = @(Get-DesktopProcess)
if ($Launch) {
    if ($existing.Count -ne 0) {
        throw "Refusing to launch over an existing MusicServer desktop process ($($existing.Count))."
    }
    if (-not (Test-Path -LiteralPath $Executable -PathType Leaf)) {
        throw "Tauri release executable not found: $Executable"
    }
    $launchedProcess = Start-Process -FilePath $Executable -WorkingDirectory $Root -PassThru
    $launchedDesktopPid = [int]$launchedProcess.Id
}

if (-not $Launch -and $existing.Count -eq 0) {
    throw 'No MusicServer desktop process found. Use -Launch for a clean smoke run.'
}

$desktop = $null
$pair = $null
$deadline = [DateTime]::UtcNow.AddSeconds(70)
do {
    $desktop = @(Get-DesktopProcess)
    $pair = Find-CurrentServicePair
    if ($desktop.Count -eq 1 -and $pair) { break }
    Start-Sleep -Milliseconds 500
} while ([DateTime]::UtcNow -lt $deadline)

if ($desktop.Count -ne 1) { throw "Expected one Tauri desktop process, found $($desktop.Count)." }
if (-not $pair) { throw "Current MusicServer UI/API build marker was not found within 70 seconds." }

$index = Get-HttpResult -Uri "http://127.0.0.1:$($pair.UiPort)/"
if (-not $index -or $index.StatusCode -ne 200 -or -not $index.Text.Contains('id="listening"')) {
    throw 'The Tauri-served UI did not expose the listening section.'
}

$stats = Get-HttpResult -Uri "http://127.0.0.1:$($pair.UiPort)/api/listening/stats"
if (-not $stats -or $stats.StatusCode -ne 200) { throw 'The listening stats endpoint is not reachable through the Tauri UI service.' }
$statsJson = ConvertFrom-Json -InputObject $stats.Text
if ($null -eq $statsJson.most_played -or $null -eq $statsJson.rediscover) { throw 'Listening stats response is missing its JSON contract.' }

$random = Get-HttpResult -Uri "http://127.0.0.1:$($pair.UiPort)/api/listening/random"
if (-not $random -or $random.StatusCode -ne 200) { throw 'The local random listening endpoint is not reachable through the Tauri UI service.' }
$randomJson = ConvertFrom-Json -InputObject $random.Text
if ([string]$randomJson.id -notmatch '^(library-|na-)') { throw "Random endpoint returned a non-local id: $($randomJson.id)" }
if ([string]$randomJson.stream_url -notmatch '^/api/library/.+/stream$') { throw 'Random endpoint did not return a playable local stream URL.' }

$stream = Get-HttpResult -Uri ("http://127.0.0.1:{0}{1}" -f $pair.UiPort, $randomJson.stream_url) -Headers @{ Range = 'bytes=0-0' }
if (-not $stream -or $stream.StatusCode -notin @(200, 206)) { throw 'The random local stream did not respond to a range request.' }

$playbackSummary = $null
if ($ExercisePlayback) {
    # This exercises the same UI-proxied event endpoint used by app.js after
    # its 30-second/25%-played client-side threshold. It is opt-in because it
    # intentionally adds two listening events to the real local database.
    $playUri = "http://127.0.0.1:$($pair.UiPort)/api/library/$([System.Uri]::EscapeDataString([string]$randomJson.id))/play"
    $firstSession = 'tauri-smoke-' + [guid]::NewGuid().ToString('N')
    $replaySession = $firstSession + '-replay'
    $body = ConvertTo-Json @{ session_id = $firstSession } -Compress
    $firstPlay = Send-JsonPost -Uri $playUri -Body $body
    $duplicate = Send-JsonPost -Uri $playUri -Body $body
    $replayBody = ConvertTo-Json @{ session_id = $replaySession } -Compress
    $replay = Send-JsonPost -Uri $playUri -Body $replayBody
    if (-not $firstPlay -or $firstPlay.StatusCode -ne 200 -or
        -not $duplicate -or $duplicate.StatusCode -ne 200 -or
        -not $replay -or $replay.StatusCode -ne 200) {
        throw 'The local playback event endpoint did not complete through the Tauri UI service.'
    }
    $firstJson = ConvertFrom-Json -InputObject $firstPlay.Text
    $duplicateJson = ConvertFrom-Json -InputObject $duplicate.Text
    $replayJson = ConvertFrom-Json -InputObject $replay.Text
    if (-not $firstJson.counted -or $duplicateJson.counted -or -not $replayJson.counted -or
        [int]$replayJson.play_count -ne ([int]$firstJson.play_count + 1)) {
        throw 'Playback deduplication/replay contract failed through the Tauri UI service.'
    }
    $afterPlayback = Get-HttpResult -Uri "http://127.0.0.1:$($pair.UiPort)/api/listening/stats"
    if (-not $afterPlayback -or $afterPlayback.StatusCode -ne 200) { throw 'Listening Top 5 did not refresh after the playback event.' }
    $afterPlaybackJson = ConvertFrom-Json -InputObject $afterPlayback.Text
    if ($null -eq $afterPlaybackJson.most_played) { throw 'Refreshed listening stats did not include most_played.' }
    $playbackSummary = "first=true duplicate=false replay=true play_count=$($replayJson.play_count)"
}

$launcher = @(Get-CimInstance Win32_Process | Where-Object {
    $_.ParentProcessId -eq [int]$desktop[0].ProcessId -and
    $_.CommandLine -match 'start_musicserver_ui\.ps1'
})
$summary = [ordered]@{
    DesktopPid = [int]$desktop[0].ProcessId
    UiPort = [int]$pair.UiPort
    ApiPort = [int]$pair.ApiPort
    CurrentWebAssets = $true
    ListeningStats = $true
    LocalRandom = [string]$randomJson.id
    LocalStream = $true
    OwnedLauncher = ($launcher.Count -gt 0)
}
if ($playbackSummary) { $summary.PlaybackContract = $playbackSummary }

if ($CloseLaunchedApp) {
    if ($launcher.Count -eq 0) { throw 'The clean launch did not produce a launcher child owned by Tauri.' }
    $targetPid = [int]$desktop[0].ProcessId
    & taskkill.exe /PID $targetPid /T /F | Out-Null
    $closeDeadline = [DateTime]::UtcNow.AddSeconds(20)
    do {
        $stillDesktop = @(Get-DesktopProcess)
        $stillPair = Find-CurrentServicePair
        if ($stillDesktop.Count -eq 0 -and -not $stillPair) { break }
        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $closeDeadline)
    if ($stillDesktop.Count -ne 0) { throw 'Tauri desktop process did not exit after close.' }
    if ($stillPair) { throw 'Tauri-owned UI/API services survived desktop APP shutdown.' }
    $summary.ServicesStopped = $true
    $launchedDesktopPid = $null
}

[pscustomobject]$summary | Format-List
} catch {
    if ($launchedDesktopPid) {
        try { & taskkill.exe /PID $launchedDesktopPid /T /F | Out-Null } catch {}
    }
    throw
}
