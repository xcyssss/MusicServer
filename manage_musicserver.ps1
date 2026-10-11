param([Parameter(Mandatory)][string]$AppHome, [string]$JobId='', [string]$RestoreBackup='')
$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
Import-Module (Join-Path $PSScriptRoot 'MusicServer.Core.psm1') -DisableNameChecking -Force
Import-Module (Join-Path $PSScriptRoot 'MusicServer.Database.psm1') -DisableNameChecking -Force
Import-Module (Join-Path $PSScriptRoot 'MusicServer.State.psm1') -DisableNameChecking -Force
Import-Module (Join-Path $PSScriptRoot 'MusicServer.Management.psm1') -DisableNameChecking -Force
Import-Module (Join-Path $PSScriptRoot 'MusicServer.Library.psm1') -DisableNameChecking -Force
$config=New-MusicServerConfig -Root $PSScriptRoot -AppHome $AppHome
$db=Join-Path $config.StateDir 'musicserver.db'
Connect-MusicServerDatabase -DbPath $db -SqliteExe $config.Sqlite
Initialize-MusicServerLibrarySchema
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
        if ($result.ExitCode -ne 0) {
            Set-ManagementJob -Id $JobId -State ERROR -Message 'WORKER_FAILED'
            if ($job.operation -eq 'library-import') { Remove-AppSettingDb -Key 'library_manifest_pending' }
        }
    } catch {
        Set-ManagementJob -Id $JobId -State ERROR -Message 'INTERRUPTED_OR_TIMEOUT'
        if ($job.operation -eq 'library-import') { Remove-AppSettingDb -Key 'library_manifest_pending' }
    }
    finally {
        # The bounded child has exited or its process tree has been killed.
        try { Remove-ManagementStaging -Config $config -JobId $JobId -Operation $job.operation } catch {
            Write-MusicServerLog -Path (Join-Path $config.LogDir 'management.log') -Message "job=$JobId stage=cleanup result=DEFERRED"
        }
    }
    exit 0
}
try {
    Apply-ConfiguredMusicDir -Config $config | Out-Null
    $path=''
    $script:lastLibraryProgress=-1
    $libraryProgress={param($percent)
        $progress=[Math]::Min(99,[Math]::Max(0,[int]$percent))
        if ($progress -ne $script:lastLibraryProgress) {
            Set-ManagementJob -Id $JobId -Progress $progress -Message $(if ($job.operation -eq 'library-export') {'EXPORTING_LIBRARY'} else {'IMPORTING_LIBRARY'})
            $script:lastLibraryProgress=$progress
        }
    }
    switch ($job.operation) {
        'components' { $path=Install-DownloadComponents -Config $config -JobId $JobId }
        'health' { Test-DownloadComponents -Config $config | Out-Null }
        'backup' { $path=New-MusicServerBackup -Config $config }
        'diagnostics' { $path=Export-MusicServerDiagnostics -Config $config }
        'library-export' { $path=Export-MusicServerLibrary -Config $config -Progress $libraryProgress -JobId $JobId }
        'library-import' {
            $result=Import-MusicServerLibraryManifest -Config $config -Progress $libraryProgress
            if (-not $result.manifest) { throw 'LIBRARY_MANIFEST_MISSING' }
            Remove-AppSettingDb -Key 'library_manifest_pending'
            if (-not $result.already_imported -and $result.imported -gt 0) {
                # The verified import committed its recommendation revision in
                # the same transaction as metadata and receipt. Preserve it.
                $dailyScript=Join-Path $config.Root 'daily_recommend.ps1'
                if ([IO.File]::Exists($dailyScript) -and -not $env:MUSICSERVER_DISABLE_SCHEDULED_TASKS) {
                    $args='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -AppHome "{1}"' -f $dailyScript,$config.AppHome
                    Start-Process -FilePath 'powershell.exe' -ArgumentList $args -WorkingDirectory $config.Root -WindowStyle Hidden -ErrorAction Stop | Out-Null
                }
            }
        }
        default { throw 'UNKNOWN_OPERATION' }
    }
    Set-ManagementJob -Id $JobId -State DONE -Progress 100 -Message 'COMPLETE' -ResultPath $path
    Write-MusicServerLog -Path (Join-Path $config.LogDir 'management.log') -Message "operation=$($job.operation) job=$JobId result=DONE"
} catch {
    if ($job.operation -eq 'library-import') { Remove-AppSettingDb -Key 'library_manifest_pending' }
    $code=if ($_.Exception.Message -match '^[A-Z][A-Z0-9_:]+$') { $_.Exception.Message } else { $_.Exception.GetBaseException().GetType().Name }
    Set-ManagementJob -Id $JobId -State ERROR -Message $code
    Write-MusicServerLog -Path (Join-Path $config.LogDir 'management.log') -Message "operation=$($job.operation) job=$JobId result=ERROR code=$code"
    exit 1
}
