<#
.SYNOPSIS
    注册或移除 Wanted Queue 的 Windows 计划任务。
.PARAMETER Unregister
    移除 MusicServer_WantedWorker。
.PARAMETER IntervalMinutes
    轮询间隔，默认 1 分钟。
#>
param(
    [switch]$Unregister,
    [ValidateRange(1, 60)][int]$IntervalMinutes = 1
)

$taskName = 'MusicServer_WantedWorker'
if ($Unregister) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "已移除计划任务：$taskName" -ForegroundColor Yellow
    exit 0
}

$scriptPath = Join-Path $PSScriptRoot 'wanted_worker.ps1'
$arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -Once -MaxItems 5"
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments -WorkingDirectory $PSScriptRoot
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) `
    -RepetitionDuration (New-TimeSpan -Days 365)
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
    -Description 'Process liked MusicServer tracks asynchronously.' -Force | Out-Null
Write-Host "已注册计划任务：$taskName（每 $IntervalMinutes 分钟）" -ForegroundColor Green
Write-Host "如需移除：.\register_wanted_worker.ps1 -Unregister" -ForegroundColor DarkGray
