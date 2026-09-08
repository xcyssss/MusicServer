# Measure EXE launch to current UI/API readiness, not rendered UI acceptance.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Executable,
    [string]$RuntimeSource = '',
    [ValidateRange(1, 30)][int]$Runs = 5,
    [string]$Label = 'startup',
    [ValidateSet('FreshRuntime', 'Restart')][string]$Scenario = 'Restart'
)
$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
if (-not $RuntimeSource) { $RuntimeSource = $project }
. (Join-Path $project 'tests/MusicServer.RuntimeFixture.ps1')
. (Join-Path $project 'tests/MusicServer.DesktopSmoke.ps1')
$exePath = (Resolve-Path -LiteralPath $Executable).Path
$RuntimeSource = (Resolve-Path -LiteralPath $RuntimeSource).Path
$fixture = New-MusicServerRuntimeFixture -ProjectRoot $RuntimeSource -Parent (Join-Path $project 'artifacts')
$oldHome = $env:MUSICSERVER_APP_HOME
$oldWorker = $env:MUSICSERVER_DISABLE_WORKER
$oldTrace = $env:MUSICSERVER_STARTUP_TRACE
$env:MUSICSERVER_DISABLE_WORKER = '1'
$child = $null
$samples = @()
$traces = @()
$serviceTraces = @()

function Wait-MeasurementPortsClosed {
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        $listeners = @(Get-NetTCPConnection -State Listen -LocalPort 8787,8788,8789,8790,8791,8792 -ErrorAction SilentlyContinue)
        if ($listeners.Count -eq 0) { return }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'Owned desktop service ports did not close after measurement.'
}
try {
    $bin = Join-Path $fixture.Root 'desktop-bin'
    $bundle = Join-Path $bin 'resources/runtime'
    New-Item -ItemType Directory -Path $bundle -Force | Out-Null
    & (Join-Path $RuntimeSource 'scripts/prepare_tauri_runtime.ps1') -ProjectRoot $RuntimeSource -Destination $bundle | Out-Null
    $testExe = Join-Path $bin 'musicserver-desktop.exe'
    Copy-Item -LiteralPath $exePath -Destination $testExe
    Import-Module (Join-Path $RuntimeSource 'MusicServer.Identity.psm1') -Force
    $marker = Get-MusicServerBuildIdentity -Root $RuntimeSource
    if (-not $marker) { throw 'Runtime build marker is missing.' }
    # Restart excludes a warm-up launch. FreshRuntime stages into an empty home
    # for every sample; it does not include installer or WebView2 installation.
    $firstRun = if ($Scenario -eq 'Restart') { 0 } else { 1 }
    foreach ($run in $firstRun..$Runs) {
        $homeName = if ($Scenario -eq 'FreshRuntime') { 'home-' + $run } else { 'restart-home' }
        $env:MUSICSERVER_APP_HOME = Join-Path $fixture.Root $homeName
        $tracePath = Join-Path $fixture.Root ('trace-' + $run + '.json')
        $env:MUSICSERVER_STARTUP_TRACE = $tracePath
        if (@(Get-NetTCPConnection -State Listen -LocalPort 8787,8788,8789,8790,8791,8792 -ErrorAction SilentlyContinue).Count) {
            throw 'A desktop service port is already owned. Close the owning APP before this isolated measurement.'
        }
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $child = Start-Process -FilePath $testExe -WindowStyle Hidden -PassThru
        $ready = $false
        while ($watch.Elapsed.TotalSeconds -lt 40 -and -not $child.HasExited) {
            $client = [Net.Sockets.TcpClient]::new()
            try {
                if ($client.ConnectAsync('127.0.0.1', 8790).Wait(50)) {
                    $health = Invoke-RestMethod 'http://127.0.0.1:8787/health' -TimeoutSec 2
                    $web = Invoke-WebRequest 'http://127.0.0.1:8790/app.js' -UseBasicParsing -TimeoutSec 2
                    if (($health | ConvertTo-Json -Compress) -match [regex]::Escape($marker) -and $web.Content.Contains($marker)) { $ready = $true; break }
                }
            } catch {} finally { $client.Dispose() }
            Start-Sleep -Milliseconds 50
        }
        if (-not $ready) { throw 'EXE did not reach current UI/API readiness.' }
        $elapsed = [Math]::Round($watch.Elapsed.TotalMilliseconds, 2)
        # External readiness can beat the shell's next poll. Wait for a complete
        # diagnostic report before stopping the APP, outside the measured timer.
        $trace = $null
        $traceDeadline = [DateTime]::UtcNow.AddSeconds(5)
        do {
            try {
                $trace = Get-Content -LiteralPath $tracePath -Raw -Encoding UTF8 | ConvertFrom-Json
            } catch { $trace = $null }
            if ($trace) { break }
            Start-Sleep -Milliseconds 50
        } while ([DateTime]::UtcNow -lt $traceDeadline -and -not $child.HasExited)
        if (-not $trace -or $trace.schema -ne 1 -or $trace.build_id -ne $marker -or $trace.outcome -ne 'services_ready') {
            throw 'EXE startup trace missing, incompatible, or not ready. Rebuild the current desktop EXE.'
        }
        $roles = [ordered]@{}
        foreach ($role in @('ui', 'api')) {
            $serviceTrace = Get-Content -LiteralPath ($tracePath + '.' + $role + '.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($serviceTrace.schema -ne 1 -or $serviceTrace.role -ne $role) { throw 'Invalid service startup trace.' }
            $roles[$role] = $serviceTrace
        }
        if ($run -gt 0) { $samples += $elapsed; $traces += $trace; $serviceTraces += $roles }
        # This is a forced-tree cleanup, not a graceful-window-close test.
        Stop-MusicServerSmokeDesktop -Process $child
        Wait-MeasurementPortsClosed
        $child.Dispose(); $child = $null
    }
    $sorted = @($samples | Sort-Object)
    $report = [ordered]@{ label = $Label; scenario = $Scenario; executable_sha256 = (Get-FileHash $exePath).Hash; runtime_marker = $marker; runs = $Runs; startup_to_services_ms = $samples; p50_ms = $sorted[[int][Math]::Ceiling($Runs * .5) - 1]; p95_ms = $sorted[[int][Math]::Ceiling($Runs * .95) - 1]; desktop_traces = $traces; scope = 'Real EXE, isolated empty state, downloader omitted; excludes installer, rendered UI, and OS cold-cache guarantees' }
    $output = Join-Path $project ('artifacts/startup-' + [guid]::NewGuid().ToString('N') + '.json')
    $report['service_traces'] = $serviceTraces
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $output -Encoding UTF8
    Write-Output $output
    Write-Output ($report | ConvertTo-Json -Depth 8 -Compress)
} finally {
    $env:MUSICSERVER_APP_HOME = $oldHome
    $env:MUSICSERVER_DISABLE_WORKER = $oldWorker
    $env:MUSICSERVER_STARTUP_TRACE = $oldTrace
    if ($child -and -not $child.HasExited) { Start-Process -FilePath taskkill.exe -ArgumentList @('/PID', [string]$child.Id, '/T', '/F') -WindowStyle Hidden -Wait | Out-Null }
    Remove-MusicServerRuntimeFixture -Fixture $fixture
}
