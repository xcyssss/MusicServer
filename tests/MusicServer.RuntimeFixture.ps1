# Shared isolated runtime for HTTP regressions and backend measurements (PS5.1).
function New-MusicServerRuntimeFixture {
    param([Parameter(Mandatory)][string]$ProjectRoot, [string]$Parent = ([IO.Path]::GetTempPath()))
    $parentRoot = [IO.Path]::GetFullPath($Parent).TrimEnd('\','/')
    $fixtureRoot = Join-Path $parentRoot ('musicserver_fixture_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null
    # Deliberately omit the downloader from test fixtures: HTTP queue tests must
    # never download media or contend for the user's global worker mutex.
    foreach ($file in @('music_api.ps1','start_musicserver_ui.ps1','watchdog_ui.ps1','MusicServer.Core.psm1','MusicServer.Database.psm1','MusicServer.State.psm1','MusicServer.Providers.psm1','MusicServer.Http.psm1')) {
        Copy-Item -LiteralPath (Join-Path $ProjectRoot $file) -Destination (Join-Path $fixtureRoot $file)
    }
    Copy-Item -LiteralPath (Join-Path $ProjectRoot 'web') -Destination (Join-Path $fixtureRoot 'web') -Recurse
    Import-Module (Join-Path $ProjectRoot 'MusicServer.Core.psm1') -Force
    Import-Module (Join-Path $ProjectRoot 'MusicServer.Database.psm1') -Force
    Import-Module (Join-Path $ProjectRoot 'MusicServer.State.psm1') -Force
    $config = New-MusicServerConfig -Root $fixtureRoot
    Initialize-MusicServerState -Config $config
    $database = Join-Path $config.StateDir 'musicserver.db'
    Initialize-MusicServerDatabase -DbPath $database -SqliteExe $config.Sqlite
    Initialize-MusicServerSchema
    return [pscustomobject]@{ Root = $fixtureRoot; Parent = $parentRoot; Database = $database; Config = $config; Processes = @(); ApiPort = 0; UiPort = 0; StartupMs = 0 }
}

function Get-MusicServerFixturePort {
    $socket = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    try { $socket.Start(); return [int]$socket.LocalEndpoint.Port } finally { $socket.Stop() }
}

function Start-MusicServerFixtureServices {
    param([Parameter(Mandatory)]$Fixture, [switch]$WithUi)
    $Fixture.ApiPort = Get-MusicServerFixturePort
    do { $Fixture.UiPort = Get-MusicServerFixturePort } while ($Fixture.UiPort -eq $Fixture.ApiPort)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $roles = @('api')
    if ($WithUi) { $roles += 'ui' }
    foreach ($role in $roles) {
        $apiPrefix = "http://127.0.0.1:$($Fixture.ApiPort)/"
        $uiPrefix = "http://127.0.0.1:$($Fixture.UiPort)/"
        $scriptName = if ($role -eq 'api') { 'music_api.ps1' } else { 'start_musicserver_ui.ps1' }
        $scriptPath = Join-Path $Fixture.Root $scriptName
        $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $scriptPath + '"'
        if ($role -eq 'api') { $arguments += ' -Prefix ' + $apiPrefix }
        else { $arguments += ' -NoBrowser -ApiPrefix ' + $apiPrefix + ' -UiPrefix ' + $uiPrefix + ' -ClientTimeoutSeconds 600' }
        $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WorkingDirectory $Fixture.Root -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $Fixture.Root "$role.out.log") -RedirectStandardError (Join-Path $Fixture.Root "$role.err.log")
        $Fixture.Processes += $process
        $prefix = if ($role -eq 'api') { $apiPrefix } else { $uiPrefix }
        $deadline = [DateTime]::UtcNow.AddSeconds(40)
        $ready = $false
        while ([DateTime]::UtcNow -lt $deadline) {
            if ($process.HasExited) { break }
            try {
                $health = Invoke-RestMethod -Uri ($prefix + 'health') -TimeoutSec 2
                if ($health.status -eq 'ok') { $ready = $true; break }
            } catch {}
            Start-Sleep -Milliseconds 100
        }
        if (-not $ready) {
            $detail = Get-Content -LiteralPath (Join-Path $Fixture.Root "$role.err.log") -Raw -ErrorAction SilentlyContinue
            throw "Fixture $role did not become ready: $detail"
        }
    }
    $Fixture.StartupMs = $timer.Elapsed.TotalMilliseconds
}

function Stop-MusicServerFixtureServices {
    param([Parameter(Mandatory)]$Fixture)
    # Stop the UI tree before the independently owned API.
    for ($i = $Fixture.Processes.Count - 1; $i -ge 0; $i--) {
        $process = $Fixture.Processes[$i]
        try {
            if (-not $process.HasExited) {
                & taskkill.exe /PID $process.Id /T /F 2>&1 | Out-Null
                [void]$process.WaitForExit(5000)
            }
        } finally { $process.Dispose() }
    }
    $Fixture.Processes = @()
}

function Remove-MusicServerRuntimeFixture {
    param([Parameter(Mandatory)]$Fixture)
    Stop-MusicServerFixtureServices -Fixture $Fixture
    $resolved = [IO.Path]::GetFullPath($Fixture.Root)
    if ((Split-Path -Parent $resolved) -ne $Fixture.Parent) { throw "Fixture escaped its parent directory: $resolved" }
    if ((Split-Path -Leaf $resolved) -notmatch '^musicserver_fixture_[0-9a-f]{32}$') { throw "Refusing to remove a non-fixture directory: $resolved" }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}

function Invoke-MusicServerFragmentedRequest {
    param(
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][string]$Path,
        [string]$Method = 'POST',
        [string[]]$Fragments = @('{}'),
        [int]$FragmentDelayMs = 0,
        [int]$LengthOverride = -1,
        [switch]$Chunked,
        [switch]$CloseSend,
        [string]$ContentEncoding = ''
    )
    $client = New-Object Net.Sockets.TcpClient
    try {
        $client.Connect('127.0.0.1', $Port)
        $client.NoDelay = $true
        $stream = $client.GetStream()
        $stream.ReadTimeout = 15000
        $stream.WriteTimeout = 15000
        $length = [Text.Encoding]::UTF8.GetByteCount(($Fragments -join ''))
        if ($LengthOverride -ge 0) { $length = $LengthOverride }
        $headers = "$Method $Path HTTP/1.1`r`nHost: 127.0.0.1:$Port`r`nConnection: close`r`nContent-Type: application/json; charset=utf-8`r`n"
        if ($Chunked) { $headers += "Transfer-Encoding: chunked`r`n" }
        else { $headers += "Content-Length: $length`r`n" }
        if ($ContentEncoding) { $headers += "Content-Encoding: $ContentEncoding`r`n" }
        $headerBytes = [Text.Encoding]::ASCII.GetBytes($headers + "`r`n")
        $stream.Write($headerBytes, 0, $headerBytes.Length)
        foreach ($fragment in $Fragments) {
            if ($FragmentDelayMs) { Start-Sleep -Milliseconds $FragmentDelayMs }
            $bytes = [Text.Encoding]::UTF8.GetBytes($fragment)
            if ($bytes.Length) { $stream.Write($bytes, 0, $bytes.Length) }
        }
        if ($CloseSend) { $client.Client.Shutdown([Net.Sockets.SocketShutdown]::Send) }
        $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8)
        $response = $reader.ReadToEnd()
        $status = -1
        if ($response -match '^HTTP/1\.[01] (\d+)') { $status = [int]$Matches[1] }
        return [pscustomobject]@{ Status = $status; Text = $response }
    } finally { $client.Close() }
}
