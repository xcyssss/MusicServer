# Measure EXE launch to current UI/API readiness, not rendered UI acceptance.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Executable,
    [string]$RuntimeSource = '',
    [ValidateRange(1, 30)][int]$Runs = 5,
    [string]$Label = 'startup'
)
$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
if (-not $RuntimeSource) { $RuntimeSource = $project }
. (Join-Path $project 'tests/MusicServer.RuntimeFixture.ps1')
$exePath = (Resolve-Path -LiteralPath $Executable).Path
$RuntimeSource = (Resolve-Path -LiteralPath $RuntimeSource).Path
$fixture = New-MusicServerRuntimeFixture -ProjectRoot $RuntimeSource -Parent (Join-Path $project 'artifacts')
$oldHome = $env:MUSICSERVER_APP_HOME
$child = $null
$samples = @()
try {
    $bin = Join-Path $fixture.Root 'desktop-bin'
    $bundle = Join-Path $bin 'resources/runtime'
    New-Item -ItemType Directory -Path $bundle -Force | Out-Null
    foreach ($name in @('start_musicserver_ui.ps1','music_api.ps1','watchdog_ui.ps1','MusicServer.Core.psm1','MusicServer.Database.psm1','MusicServer.State.psm1','MusicServer.Http.psm1','MusicServer.Providers.psm1','web')) {
        Copy-Item -LiteralPath (Join-Path $RuntimeSource $name) -Destination $bundle -Recurse
    }
    New-Item -ItemType Directory -Path (Join-Path $bundle 'tools') -Force | Out-Null
    Copy-Item -LiteralPath $fixture.Config.Sqlite -Destination (Join-Path $bundle 'tools/sqlite3.exe')
    $testExe = Join-Path $bin 'musicserver-desktop.exe'
    Copy-Item -LiteralPath $exePath -Destination $testExe
    $marker = [regex]::Match([IO.File]::ReadAllText((Join-Path $RuntimeSource 'web/app.js')), 'musicserver-[a-z0-9-]+').Value
    if (-not $marker) { throw 'Runtime build marker is missing.' }
    $env:MUSICSERVER_APP_HOME = $fixture.Root
    foreach ($run in 1..$Runs) {
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
        $samples += [Math]::Round($watch.Elapsed.TotalMilliseconds, 2)
        # Measurement owns this entire tree. Functional graceful-exit checks are
        # performed by the installed-APP CI gate, independently of this timer.
        Start-Process -FilePath taskkill.exe -ArgumentList @('/PID', [string]$child.Id, '/T', '/F') -WindowStyle Hidden -Wait | Out-Null
        [void]$child.WaitForExit(5000)
        $child.Dispose(); $child = $null
    }
    $sorted = @($samples | Sort-Object)
    $report = [ordered]@{ label = $Label; executable_sha256 = (Get-FileHash $exePath).Hash; runtime_marker = $marker; runs = $Runs; startup_to_services_ms = $samples; p50_ms = $sorted[[int][Math]::Ceiling($Runs * .5) - 1]; p95_ms = $sorted[[int][Math]::Ceiling($Runs * .95) - 1]; scope = 'Real EXE, isolated empty state, downloader omitted, service readiness; no rendered UI timing' }
    $output = Join-Path $project ('artifacts/startup-' + [guid]::NewGuid().ToString('N') + '.json')
    $report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $output -Encoding UTF8
    Write-Output $output
    Write-Output ($report | ConvertTo-Json -Compress)
} finally {
    $env:MUSICSERVER_APP_HOME = $oldHome
    if ($child -and -not $child.HasExited) { Start-Process -FilePath taskkill.exe -ArgumentList @('/PID', [string]$child.Id, '/T', '/F') -WindowStyle Hidden -Wait | Out-Null }
    Remove-MusicServerRuntimeFixture -Fixture $fixture
}
