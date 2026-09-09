<#
.SYNOPSIS
    Safely migrates legacy repository data into an external MusicServer APP_HOME.

.DESCRIPTION
    This script is intentionally fail-closed. It refuses to run while any
    Navidrome process exists, refuses non-empty destination conflicts, copies
    each source item, verifies file counts/sizes/hashes, and only then removes
    the verified legacy source item. The repository Music directory is not
    migrated: MusicDir is an independent user path and must be configured
    separately.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$AppHome = ''
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$resolvedRepository = [IO.Path]::GetFullPath($RepositoryRoot)
if (-not (Test-Path -LiteralPath $resolvedRepository -PathType Container)) {
    throw "Repository root does not exist: $resolvedRepository"
}

Import-Module (Join-Path $resolvedRepository 'MusicServer.Core.psm1') -Force
$config = New-MusicServerConfig -Root $resolvedRepository -AppHome $AppHome
$resolvedAppHome = [IO.Path]::GetFullPath($config.AppHome)

function Test-PathWithin {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Parent)
    $normalizedPath = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $normalizedParent = [IO.Path]::GetFullPath($Parent).TrimEnd('\')
    return $normalizedPath.Equals($normalizedParent, [StringComparison]::OrdinalIgnoreCase) -or
        $normalizedPath.StartsWith($normalizedParent + '\', [StringComparison]::OrdinalIgnoreCase)
}

if ((Test-PathWithin -Path $resolvedAppHome -Parent $resolvedRepository) -or
    (Test-PathWithin -Path $resolvedRepository -Parent $resolvedAppHome)) {
    throw "APP_HOME must be outside the repository: $resolvedAppHome"
}

$navidromeProcesses = @(Get-Process -Name 'navidrome','navidrome.exe' -ErrorAction SilentlyContinue)
if ($navidromeProcesses.Count -gt 0) {
    $ids = ($navidromeProcesses | ForEach-Object { $_.Id }) -join ', '
    throw "Stop Navidrome before migration. Running process IDs: $ids"
}

$items = @(
    [pscustomobject]@{ Source = Join-Path $resolvedRepository 'DailyMix_data'; Target = Join-Path $resolvedAppHome 'DailyMix_data' }
    [pscustomobject]@{ Source = Join-Path $resolvedRepository 'Navidrome\Data'; Target = Join-Path $resolvedAppHome 'Navidrome\Data' }
    [pscustomobject]@{ Source = Join-Path $resolvedRepository 'backups'; Target = Join-Path $resolvedAppHome 'backups' }
    [pscustomobject]@{ Source = Join-Path $resolvedRepository 'logs'; Target = Join-Path $resolvedAppHome 'logs' }
    [pscustomobject]@{ Source = Join-Path $resolvedRepository 'cookies.txt'; Target = Join-Path $resolvedAppHome 'secrets\cookies.txt' }
    [pscustomobject]@{ Source = Join-Path $resolvedRepository 'lyrics_report.csv'; Target = Join-Path $resolvedAppHome 'output\lyrics_report.csv' }
)

function Get-MigrationFiles {
    param([Parameter(Mandatory)][string]$Path)
    $item = Get-Item -LiteralPath $Path -Force
    if (-not $item.PSIsContainer) {
        return @([pscustomobject]@{ Relative = $item.Name; Length = $item.Length; Hash = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash })
    }
    $base = $item.FullName.TrimEnd('\') + '\'
    $files = @(Get-ChildItem -LiteralPath $item.FullName -Recurse -File -Force)
    foreach ($file in $files) {
        if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Reparse-point files are not supported by this migration: $($file.FullName)"
        }
        [pscustomobject]@{
            Relative = $file.FullName.Substring($base.Length)
            Length   = $file.Length
            Hash     = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        }
    }
}

foreach ($item in $items) {
    if (-not (Test-Path -LiteralPath $item.Source)) { continue }
    if (Test-Path -LiteralPath $item.Target) {
        throw "Destination already exists; refusing to merge or overwrite: $($item.Target)"
    }
}

# Create only the APP_HOME-owned scaffolding and a generated Navidrome config.
# The old repository config is deliberately not copied because it may contain
# checkout-specific absolute paths.
Initialize-MusicServerState -Config $config -SkipLibrary
$navidromeConfig = Get-Content -LiteralPath $config.NdConfig -Raw -Encoding UTF8
if ($navidromeConfig -match [regex]::Escape($resolvedRepository)) {
    throw "Generated Navidrome config still contains the repository path: $($config.NdConfig)"
}

foreach ($item in $items) {
    if (-not (Test-Path -LiteralPath $item.Source)) { continue }
    $sourceItem = Get-Item -LiteralPath $item.Source -Force
    $targetParent = Split-Path -Parent $item.Target
    New-Item -ItemType Directory -Force -Path $targetParent | Out-Null
    if ($sourceItem.PSIsContainer) {
        # Initialize-MusicServerState above creates empty scaffolding targets,
        # so Copy-Item would nest the source as "target\DailyMix_data\..." and
        # fail verification. Remove the scaffolded empty directory first to
        # keep the copied tree at the item root.
        if (Test-Path -LiteralPath $item.Target) {
            Remove-Item -LiteralPath $item.Target -Recurse -Force
        }
        Copy-Item -LiteralPath $item.Source -Destination $item.Target -Recurse -Force
    } else {
        Copy-Item -LiteralPath $item.Source -Destination $item.Target -Force
    }

    $sourceFiles = @(Get-MigrationFiles -Path $item.Source)
    $targetFiles = @(Get-MigrationFiles -Path $item.Target)
    if ($sourceFiles.Count -ne $targetFiles.Count) {
        throw "Verification failed for $($item.Source): file count differs after copy."
    }
    foreach ($sourceFile in $sourceFiles) {
        $targetFile = $targetFiles | Where-Object { $_.Relative -eq $sourceFile.Relative } | Select-Object -First 1
        if ($null -eq $targetFile -or $targetFile.Length -ne $sourceFile.Length -or
            $targetFile.Hash -ne $sourceFile.Hash) {
            throw "Verification failed for $($item.Source): $($sourceFile.Relative) differs after copy."
        }
    }
}

foreach ($item in $items) {
    if (-not (Test-Path -LiteralPath $item.Source)) { continue }
    if (-not $PSCmdlet.ShouldProcess($item.Source, 'Remove verified legacy data')) { continue }
    Remove-Item -LiteralPath $item.Source -Recurse -Force
}

Write-Output "Migrated verified legacy data into APP_HOME: $resolvedAppHome"
Write-Output "MusicDir was not moved; configure MUSICSERVER_MUSIC_DIR or use the existing external library path."
