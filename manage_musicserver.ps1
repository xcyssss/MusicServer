param([Parameter(Mandatory)][string]$AppHome, [string]$JobId='', [string]$RestoreBackup='')
$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
Import-Module (Join-Path $PSScriptRoot 'MusicServer.Core.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'MusicServer.Database.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'MusicServer.State.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'MusicServer.Management.psm1') -Force
$config=New-MusicServerConfig -Root $PSScriptRoot -AppHome $AppHome
$db=Join-Path $config.StateDir 'musicserver.db'
Connect-MusicServerDatabase -DbPath $db -SqliteExe $config.Sqlite
if ($RestoreBackup) {
    try {
        Restore-MusicServerBackup -Config $config -BackupId $RestoreBackup | Out-Null
        Set-AppSettingDb -Key 'last_restore_result' -Value 'RESTORE_COMPLETE'
        exit 0
    } catch {
        $code=if ($_.Exception.Message -match '^[A-Z_]+$') { $_.Exception.Message } else { 'RESTORE_FAILED' }
        Set-AppSettingDb -Key 'last_restore_result' -Value $code
        Write-MusicServerLog -Path (Join-Path $config.LogDir 'management.log') -Message "operation=restore result=ERROR code=$code"
        exit 1
    }
}
if ($JobId -notmatch '^[a-f0-9]{32}$') { exit 2 }
$jobs=@(Invoke-MusicServerParamSql -Template 'SELECT * FROM maintenance_jobs WHERE id=@id AND state=''RUNNING'';' -Params @{id=$JobId})
if ($jobs.Count -ne 1) { exit 2 }
$job=$jobs[0]
if ($env:MUSICSERVER_MANAGEMENT_CHILD -ne $JobId) {
    try {
        $env:MUSICSERVER_MANAGEMENT_CHILD=$JobId
        $result=Invoke-MusicServerBoundedProcess -FilePath 'powershell.exe' -Arguments @('-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath,'-AppHome',$AppHome,'-JobId',$JobId) -TimeoutSeconds 600
        if ($result.ExitCode -ne 0) { Set-ManagementJob -Id $JobId -State ERROR -Message 'WORKER_FAILED' }
    } catch { Set-ManagementJob -Id $JobId -State ERROR -Message 'INTERRUPTED_OR_TIMEOUT' }
    exit 0
}
try {
    Apply-ConfiguredMusicDir -Config $config | Out-Null
    $path=''
    switch ($job.operation) {
        'components' { $path=Install-DownloadComponents -Config $config -JobId $JobId }
        'health' { Test-DownloadComponents -Config $config | Out-Null }
        'backup' { $path=New-MusicServerBackup -Config $config }
        'diagnostics' { $path=Export-MusicServerDiagnostics -Config $config }
        default { throw 'UNKNOWN_OPERATION' }
    }
    Set-ManagementJob -Id $JobId -State DONE -Progress 100 -Message 'COMPLETE' -ResultPath $path
    Write-MusicServerLog -Path (Join-Path $config.LogDir 'management.log') -Message "operation=$($job.operation) job=$JobId result=DONE"
} catch {
    $code=if ($_.Exception.Message -match '^[A-Z][A-Z0-9_:]+$') { $_.Exception.Message } else { $_.Exception.GetBaseException().GetType().Name }
    Set-ManagementJob -Id $JobId -State ERROR -Message $code
    Write-MusicServerLog -Path (Join-Path $config.LogDir 'management.log') -Message "operation=$($job.operation) job=$JobId result=ERROR code=$code"
    exit 1
}
