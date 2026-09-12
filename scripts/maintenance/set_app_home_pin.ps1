<#
.SYNOPSIS
    Set, show or clear the machine APP_HOME pin used by MusicServer.
.DESCRIPTION
    The APP resolves its writable home in this order:

        MUSICSERVER_APP_HOME  ->  this pin  ->  %LOCALAPPDATA%\com.musicserver.desktop

    The pin is stored in the registry so the APP reads it itself instead of
    inheriting it from whoever started the process. The Tauri installer ends by
    launching the APP through nsis_tauri_utils::RunAsUser, which does not carry the
    invoking session's environment: an environment-only override is therefore lost
    on the first launch after an install or an update, and the APP silently creates
    a second, empty state home next to the real one.

    The key is HKCU\Software\MusicServerRuntime, deliberately outside
    HKCU\Software\<manufacturer>\<product> and %APPDATA%\<bundle id>, both of which
    the NSIS uninstaller deletes.
.PARAMETER AppHome
    Absolute directory that should own DailyMix_data/, Music/, Navidrome/ and logs/.
.PARAMETER Clear
    Remove the pin so the APP falls back to MUSICSERVER_APP_HOME or the platform
    default again.
.EXAMPLE
    .\set_app_home_pin.ps1 -AppHome E:\Project\MusicSever_app
.EXAMPLE
    .\set_app_home_pin.ps1
.EXAMPLE
    .\set_app_home_pin.ps1 -Clear
#>
param(
    [string]$AppHome = '',
    [switch]$Clear
)

$ErrorActionPreference = 'Stop'
$key = 'HKCU:\Software\MusicServerRuntime'
$valueName = 'AppHome'

if ($Clear) {
    if (Test-Path -LiteralPath $key) {
        Remove-ItemProperty -LiteralPath $key -Name $valueName -ErrorAction SilentlyContinue
        Write-Host 'APP_HOME pin cleared.' -ForegroundColor Yellow
    } else {
        Write-Host 'No APP_HOME pin to clear.' -ForegroundColor Yellow
    }
    return
}

if ([string]::IsNullOrWhiteSpace($AppHome)) {
    if (Test-Path -LiteralPath $key) {
        $current = (Get-ItemProperty -LiteralPath $key -Name $valueName -ErrorAction SilentlyContinue).$valueName
        if (-not [string]::IsNullOrWhiteSpace($current)) {
            Write-Host "APP_HOME pin: $current"
            return
        }
    }
    Write-Host 'APP_HOME pin is not set. Pass -AppHome <path> to set it.' -ForegroundColor Yellow
    return
}

$full = [IO.Path]::GetFullPath($AppHome)
if (-not (Test-Path -LiteralPath $full -PathType Container)) {
    # Fail closed on purpose: a pin pointing at a mistyped path would become a new
    # empty home, which is exactly the failure this pin exists to prevent.
    throw "APP_HOME does not exist: $full"
}
if (-not (Test-Path -LiteralPath $key)) { New-Item -Path $key -Force | Out-Null }
Set-ItemProperty -LiteralPath $key -Name $valueName -Value $full -Type String
Write-Host "APP_HOME pin set to $full" -ForegroundColor Green
