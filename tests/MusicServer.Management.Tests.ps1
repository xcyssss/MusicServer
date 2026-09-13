$ErrorActionPreference='Stop'
$ProjectRoot=Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'MusicServer.RuntimeFixture.ps1')
Describe 'Desktop management data boundaries' {
    BeforeEach {
        $script:fixture=New-MusicServerRuntimeFixture -ProjectRoot $ProjectRoot
        Import-Module (Join-Path $ProjectRoot 'MusicServer.Management.psm1') -Force
        Initialize-ManagementSchema
    }
    AfterEach { Remove-MusicServerRuntimeFixture -Fixture $script:fixture }
    It 'creates a consistent backup and restores settings without touching music or secrets' {
        Set-AppSettingDb -Key 'fixture' -Value 'before'
        $music=Join-Path $fixture.Config.MusicDir 'owned.mp3'; [IO.File]::WriteAllText($music,'not touched')
        $cookie=Join-Path $fixture.Config.SecretsDir 'cookies.txt'; [IO.File]::WriteAllText($cookie,'private')
        $backup=New-MusicServerBackup -Config $fixture.Config
        Set-AppSettingDb -Key 'fixture' -Value 'after'
        $rollback=Restore-MusicServerBackup -Config $fixture.Config -BackupId (Split-Path $backup -Leaf)
        Get-AppSettingDb -Key 'fixture' | Should Be 'before'
        [IO.File]::ReadAllText($music) | Should Be 'not touched'
        [IO.File]::ReadAllText($cookie) | Should Be 'private'
        (Test-Path (Join-Path $rollback 'musicserver.db')) | Should Be $true
        @(Get-MusicServerBackups -Config $fixture.Config).Count | Should Be 2
    }
    It 'refuses altered and traversal backups before replacing current state' {
        Set-AppSettingDb -Key 'fixture' -Value 'kept'
        $backup=New-MusicServerBackup -Config $fixture.Config
        [IO.File]::AppendAllText((Join-Path $backup 'musicserver.db'),'tampered')
        { Restore-MusicServerBackup -Config $fixture.Config -BackupId (Split-Path $backup -Leaf) } | Should Throw 'BACKUP_CHECKSUM_MISMATCH'
        { Restore-MusicServerBackup -Config $fixture.Config -BackupId '..\outside' } | Should Throw 'INVALID_BACKUP_ID'
        Get-AppSettingDb -Key 'fixture' | Should Be 'kept'
    }
    It 'exports only approved diagnostic fields with no credentials or personal paths' {
        Set-AppSettingDb -Key 'cookie' -Value 'secret-test-cookie'
        [IO.File]::WriteAllText((Join-Path $fixture.Config.LogDir 'private.log'),'Cookie: secret-test-cookie https://private/?token=hidden')
        $path=Export-MusicServerDiagnostics -Config $fixture.Config
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip=[IO.Compression.ZipFile]::OpenRead($path)
        try {
            @($zip.Entries).Count | Should Be 2
            $entry=$zip.GetEntry('diagnostics.json'); $reader=New-Object IO.StreamReader($entry.Open())
            try { $text=$reader.ReadToEnd() } finally { $reader.Dispose() }
            $text | Should Not Match 'secret-test-cookie|private.log|token=|musicserver_fixture_|cookies.txt'
            $text | Should Match 'components'
        } finally { $zip.Dispose() }
    }
    It 'pins complete component downloads to publisher hashes and versions' {
        $catalog=@(Get-DownloadComponentCatalog)
        $catalog.Count | Should Be 2
        foreach ($entry in $catalog) { $entry.sha256 | Should Match '^[a-f0-9]{64}$'; $entry.url | Should Match '^https://github.com/'; ($entry.size -gt 1000000) | Should Be $true }
    }
    It 'keeps job state authoritative and records progress only for an active job' {
        $id=[Guid]::NewGuid().ToString('N')
        Invoke-MusicServerParamNonQuery -Template 'INSERT INTO maintenance_jobs(id,operation,state,created_at,updated_at,deadline) VALUES(@id,''components'',''RUNNING'',@now,@now,9999999999);' -Params @{id=$id;now=(Get-NowIso)}
        Set-ManagementJob -Id $id -Progress 45 -Message 'FETCH_ffmpeg'
        $status=Get-ManagementStatus -Config $fixture.Config
        $status.jobs[0].progress | Should Be 45
        Set-ManagementJob -Id $id -State DONE -Progress 100
        Set-ManagementJob -Id $id -State ERROR -Message 'late worker'
        (Get-ManagementStatus -Config $fixture.Config).jobs[0].state | Should Be 'DONE'
    }
    It 'preserves command arguments and kills a stalled child within its deadline' {
        $result=Invoke-MusicServerBoundedProcess -FilePath 'powershell.exe' -Arguments @('-NoProfile','-Command','Write-Output ''literal spaces''') -TimeoutSeconds 10
        $result.ExitCode | Should Be 0
        $result.Output.Trim() | Should Be 'literal spaces'
        $clock=[Diagnostics.Stopwatch]::StartNew()
        { Invoke-MusicServerBoundedProcess -FilePath 'powershell.exe' -Arguments @('-NoProfile','-Command','Start-Sleep -Seconds 30') -TimeoutSeconds 1 } | Should Throw 'PROCESS_TIMEOUT'
        ($clock.Elapsed.TotalSeconds -lt 8) | Should Be $true
    }
}
