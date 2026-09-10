<#
.SYNOPSIS
    注册或移除每日推荐（DailyRecommend）的 Windows 计划任务。
.PARAMETER Unregister
    移除 MusicServer_DailyRecommend。
.PARAMETER Time
    每日触发时间（HH:mm），默认 07:00。
.PARAMETER Count
    每次生成的推荐数量，默认 20。
.PARAMETER AppHome
    运行时/数据主目录，默认脚本所在目录。
#>
param(
    [switch]$Unregister,
    [string]$Time = '07:00',
    [ValidateRange(1, 100)][int]$Count = 20,
    [string]$AppHome = $PSScriptRoot
)

$taskName = 'MusicServer_DailyRecommend'
if ($Unregister) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "已移除计划任务：$taskName" -ForegroundColor Yellow
    exit 0
}

$scriptPath = Join-Path $PSScriptRoot 'daily_recommend.ps1'
if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
    throw "daily_recommend.ps1 not found: $scriptPath"
}

$startAt = [datetime]::ParseExact($Time, 'HH:mm', [Globalization.CultureInfo]::InvariantCulture)
$arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -Count $Count -AppHome `"$AppHome`""
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments -WorkingDirectory $PSScriptRoot
$trigger = New-ScheduledTaskTrigger -Daily -At $startAt
# Register-ScheduledTask's defaults would silently disable this task for many
# users: a laptop on battery never starts it, a 07:00 start missed because the
# PC was off is never caught up, and unplugging mid-run kills it. The daily
# recommendation must not depend on the machine being plugged in and awake.
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 1) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings `
    -Description 'Generate the daily MusicServer recommendation metadata.' -Force | Out-Null
Write-Host "已注册计划任务：$taskName（每天 $Time）" -ForegroundColor Green
Write-Host "如需移除：.\register_daily_recommend.ps1 -Unregister" -ForegroundColor DarkGray
