<#
.SYNOPSIS
    Write a portable data-directory locator next to an APP or script entry.
.DESCRIPTION
    Stores a relative path when the configuration and data share a volume.
    The data directory must already exist. This command does not move user data.
#>
param(
    [Parameter(Mandatory)][string]$ConfigDirectory,
    [Parameter(Mandatory)][string]$AppHome,
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $projectRoot 'MusicServer.Core.psm1') -Force
$base = [IO.Path]::GetFullPath($ConfigDirectory)
$resolvedHome = Resolve-MusicServerAnchoredPath -Path $AppHome -BasePath $base
if (-not (Test-Path -LiteralPath $base -PathType Container)) { throw "Configuration directory not found: $base" }
if (-not (Test-Path -LiteralPath $resolvedHome -PathType Container)) { throw "Existing data directory not found: $resolvedHome" }
$target = Join-Path $base 'musicserver.paths.json'
if ((Test-Path -LiteralPath $target) -and -not $Force) { throw "Configuration already exists: $target. Review it before using -Force." }
$config = [ordered]@{ schema = 1; app_home = ConvertTo-MusicServerPortablePath -Path $resolvedHome -BasePath $base }
[IO.File]::WriteAllText($target, ($config | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
Write-Output $target
