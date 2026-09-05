[CmdletBinding()]
param(
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$Destination = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)
if ([string]::IsNullOrWhiteSpace($Destination)) {
    $Destination = Join-Path $ProjectRoot 'src-tauri\resources\runtime'
}
$Destination = [IO.Path]::GetFullPath($Destination)

if (-not (Test-Path -LiteralPath $Destination -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
}

# Keep the tracked placeholder, but remove every generated runtime payload from
# previous builds so stale files cannot silently enter an installer.
Get-ChildItem -LiteralPath $Destination -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ne '.gitkeep' } |
    Remove-Item -Recurse -Force

$runtimeFiles = @(
    'start_musicserver_ui.ps1',
    'music_api.ps1',
    'wanted_worker.ps1',
    'MusicServer.Core.psm1',
    'MusicServer.Database.psm1',
    'MusicServer.State.psm1',
    'MusicServer.Providers.psm1'
)

foreach ($relative in $runtimeFiles) {
    $source = Join-Path $ProjectRoot $relative
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "Required desktop runtime file is missing: $source"
    }
    Copy-Item -LiteralPath $source -Destination (Join-Path $Destination $relative) -Force
}

$webSource = Join-Path $ProjectRoot 'web'
if (-not (Test-Path -LiteralPath $webSource -PathType Container)) {
    throw "Required web runtime directory is missing: $webSource"
}
Copy-Item -LiteralPath $webSource -Destination (Join-Path $Destination 'web') -Recurse -Force

# SQLite is a hard runtime dependency: the API cannot even initialize its state
# database without it. Bundle the real sqlite3.exe, never a Chocolatey shim.
$sqliteCandidates = New-Object System.Collections.Generic.List[string]
if ($env:MUSICSERVER_SQLITE) { [void]$sqliteCandidates.Add($env:MUSICSERVER_SQLITE) }
if ($env:ChocolateyInstall) {
    [void]$sqliteCandidates.Add((Join-Path $env:ChocolateyInstall 'lib\SQLite\tools\sqlite3.exe'))
    [void]$sqliteCandidates.Add((Join-Path $env:ChocolateyInstall 'lib\sqlite\tools\sqlite3.exe'))
}
if ($env:ProgramData) {
    [void]$sqliteCandidates.Add((Join-Path $env:ProgramData 'chocolatey\lib\SQLite\tools\sqlite3.exe'))
    [void]$sqliteCandidates.Add((Join-Path $env:ProgramData 'chocolatey\lib\sqlite\tools\sqlite3.exe'))
}

$resolvedSqlite = $null
foreach ($candidate in $sqliteCandidates) {
    if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        $resolvedSqlite = [IO.Path]::GetFullPath($candidate)
        break
    }
}
if (-not $resolvedSqlite) {
    $cmd = Get-Command sqlite3.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cmd) { $cmd = Get-Command sqlite3 -ErrorAction SilentlyContinue | Select-Object -First 1 }
    if ($cmd -and $cmd.Source -and (Test-Path -LiteralPath $cmd.Source -PathType Leaf)) {
        $resolvedSqlite = [IO.Path]::GetFullPath([string]$cmd.Source)
    }
}
if (-not $resolvedSqlite) {
    throw 'sqlite3.exe is required to build the portable desktop runtime. Install SQLite or set MUSICSERVER_SQLITE to the real executable.'
}

$toolsDir = Join-Path $Destination 'tools'
New-Item -ItemType Directory -Force -Path $toolsDir | Out-Null
$sqliteTarget = Join-Path $toolsDir 'sqlite3.exe'
Copy-Item -LiteralPath $resolvedSqlite -Destination $sqliteTarget -Force

# Fail the build early if a copied Chocolatey shim or broken executable slipped in.
$sqliteVersion = & $sqliteTarget --version 2>&1
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace((@($sqliteVersion) -join ' '))) {
    throw "Bundled sqlite3.exe is not runnable: $sqliteTarget"
}

$manifest = [ordered]@{
    schema = 1
    generated_utc = [DateTime]::UtcNow.ToString('o')
    runtime_files = $runtimeFiles
    web = 'web'
    sqlite = 'tools/sqlite3.exe'
}
$manifestPath = Join-Path $Destination 'runtime-manifest.json'
[IO.File]::WriteAllText(
    $manifestPath,
    ($manifest | ConvertTo-Json -Depth 6),
    (New-Object Text.UTF8Encoding($false))
)

Write-Host "Portable runtime staged: $Destination"
Write-Host "sqlite3: $resolvedSqlite"
