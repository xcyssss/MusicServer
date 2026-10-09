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
    It 'captures slow requests client failures and startup state without exporting private payloads' {
        $lines=@(
            '[2026-10-08 10:00:00] [client] phase=library code=TIMEOUT elapsed_ms=12000 title=PrivateSong token=secret-token',
            '[2026-10-08 10:00:01] [request] method=GET route=/api/tracks/private-song-id/lyrics status=500 elapsed_ms=8000 sqlite_calls=5 Cookie: secret-cookie',
            '[2026-10-08 10:00:02] SLOW /api/library took 4567ms',
            '[2026-10-08 10:00:03] [library] phase=scan result=READY count=1500 elapsed_ms=1800 path=C:\Users\private-owner\Music',
            '[2026-10-08 10:00:04] [startup] role=ui elapsed_ms=9000 phase_schema=1400 phase_listener_media_pool=300'
        )
        [IO.File]::WriteAllLines((Join-Path $fixture.Config.LogDir 'musicserver-ui.log'),$lines)
        [IO.File]::WriteAllLines((Join-Path $fixture.Config.LogDir 'musicserver-recommendation.log'),@(
            '[2026-10-08 10:00:05] [selection] completed=true library_count=1500 seed_count=8 remote_count=18 local_count=2 seed_misses=1 title=PrivateSong',
            '[2026-10-08 10:00:06] [selection] metadata_failed=true stop_reason=provider_busy preserved_existing_day=true',
            '[2026-10-08 10:00:07] [generation] skipped=library_changed_during_discovery preserved_existing_day=true'
        ))
        [IO.File]::WriteAllText((Join-Path $fixture.Config.LogDir 'desktop-startup.json'),'{"state":"failed","message":"Runtime deployment failed: C:\\Users\\private-owner\\bad-file","pid":123,"ui_port":8790,"api_port":8787,"build":"abc123","at":1791417600}')
        $path=Export-MusicServerDiagnostics -Config $fixture.Config
        $zip=[IO.Compression.ZipFile]::OpenRead($path)
        try {
            $reader=New-Object IO.StreamReader($zip.GetEntry('diagnostics.json').Open())
            try { $text=$reader.ReadToEnd();$report=$text | ConvertFrom-Json } finally { $reader.Dispose() }
            $text | Should Not Match 'PrivateSong|private-song-id|private-owner|secret-token|secret-cookie|Cookie:'
            $report.schema | Should Be 2
            @($report.runtime_log).Count | Should Be 8
            @($report.runtime_log | Where-Object {$_.seed_count -eq 8 -and $_.library_count -eq 1500}).Count | Should Be 1
            @($report.runtime_log | Where-Object {$_.stop_reason -eq 'provider_busy'}).Count | Should Be 1
            @($report.runtime_log | Where-Object {$_.skipped -eq 'library_changed_during_discovery'}).Count | Should Be 1
            @($report.runtime_log | Where-Object {$_.code -eq 'TIMEOUT'}).Count | Should Be 1
            @($report.runtime_log | Where-Object {$_.route -eq '/api/tracks/:id/lyrics'}).Count | Should Be 1
            @($report.runtime_log | Where-Object {$_.duration_ms -eq 4567}).Count | Should Be 1
            $report.desktop_startup.state | Should Be 'failed'
            $report.desktop_startup.reason | Should Be 'RUNTIME_DEPLOYMENT_FAILED'
            $report.desktop_startup.pid | Should Be 123
        } finally { $zip.Dispose() }
    }
    It 'bounds recent log extraction and keeps diagnostics usable when a log is malformed' {
        $lines=1..600 | ForEach-Object { '[2026-10-08 10:00:00] [client] phase=library code=NETWORK elapsed_ms='+$_ }
        [IO.File]::WriteAllLines((Join-Path $fixture.Config.LogDir 'musicserver-ui.log'),$lines)
        [IO.File]::WriteAllText((Join-Path $fixture.Config.LogDir 'desktop-startup.json'),'not-json-private-data')
        $path=Export-MusicServerDiagnostics -Config $fixture.Config
        $zip=[IO.Compression.ZipFile]::OpenRead($path)
        try {
            $reader=New-Object IO.StreamReader($zip.GetEntry('diagnostics.json').Open())
            try { $report=$reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
            @($report.runtime_log).Count | Should Be 80
            $report.runtime_log[-1].elapsed_ms | Should Be 600
            @($report.collection_errors | Where-Object {$_.section -eq 'desktop_startup'}).Count | Should Be 1
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
    It 'makes an interrupted maintenance job retryable on restart' {
        $id=[Guid]::NewGuid().ToString('N')
        Invoke-MusicServerParamNonQuery -Template 'INSERT INTO maintenance_jobs(id,operation,state,created_at,updated_at,deadline) VALUES(@id,''components'',''RUNNING'',@now,@now,9999999999);' -Params @{id=$id;now=(Get-NowIso)}
        Reset-InterruptedManagementJobs -Config $fixture.Config
        (Get-ManagementStatus -Config $fixture.Config).jobs[0].state | Should Be 'ERROR'
        $stage=Join-Path $fixture.Config.AppHome ('components\staging-'+$id)
        [IO.Directory]::CreateDirectory($stage) | Out-Null
        [IO.File]::WriteAllText((Join-Path $stage 'partial.zip'),'partial')
        Remove-ManagementStaging -Config $fixture.Config -JobId $id
        [IO.Directory]::Exists($stage) | Should Be $false
        { Remove-ManagementStaging -Config $fixture.Config -JobId '..\outside' } | Should Throw 'INVALID_JOB_ID'
    }
    It 'schedules portable imports only for an unconsumed manifest and an available job slot' {
        Import-Module (Join-Path $ProjectRoot 'MusicServer.Library.psm1') -Force -DisableNameChecking
        Initialize-MusicServerLibrarySchema
        $manifest=Join-Path $fixture.Config.MusicDir '.musicserver-library.json'
        [IO.File]::WriteAllText($manifest,'{"schema":1}')
        Mock Start-ManagementJob { return 'scheduled-import' } -ModuleName MusicServer.Management
        Start-MusicServerLibraryImportIfNeeded -Config $fixture.Config | Should Be 'scheduled-import'
        Assert-MockCalled Start-ManagementJob -ModuleName MusicServer.Management -Times 1 -Exactly -Scope It -ParameterFilter {$Operation -eq 'library-import'}
        $root=Get-MusicServerLibraryRootKey -Config $fixture.Config
        $hash=(Get-FileHash -LiteralPath $manifest -Algorithm SHA256).Hash.ToLowerInvariant()
        Invoke-MusicServerParamNonQuery -Template 'INSERT INTO library_imports(root_key,manifest_hash,imported_at) VALUES(@root,@hash,@now);' -Params @{root=$root;hash=$hash;now=(Get-NowIso)}
        Start-MusicServerLibraryImportIfNeeded -Config $fixture.Config | Should BeNullOrEmpty
        Assert-MockCalled Start-ManagementJob -ModuleName MusicServer.Management -Times 1 -Exactly -Scope It
    }
    It 'does not block recommendations behind a different maintenance job' {
        Import-Module (Join-Path $ProjectRoot 'MusicServer.Library.psm1') -Force -DisableNameChecking
        [IO.File]::WriteAllText((Join-Path $fixture.Config.MusicDir '.musicserver-library.json'),'{"schema":1}')
        $id=[Guid]::NewGuid().ToString('N')
        Invoke-MusicServerParamNonQuery -Template 'INSERT INTO maintenance_jobs(id,operation,state,created_at,updated_at,deadline) VALUES(@id,''diagnostics'',''RUNNING'',@now,@now,9999999999);' -Params @{id=$id;now=(Get-NowIso)}
        Mock Start-ManagementJob { throw 'UNEXPECTED_IMPORT' } -ModuleName MusicServer.Management
        Start-MusicServerLibraryImportIfNeeded -Config $fixture.Config | Should BeNullOrEmpty
        Get-AppSettingDb -Key 'library_manifest_pending' | Should BeNullOrEmpty
        Assert-MockCalled Start-ManagementJob -ModuleName MusicServer.Management -Times 0 -Exactly -Scope It
    }
    It 'clears the import pending flag after a failed worker launch' {
        Mock Start-Process { throw 'fixture start failure' } -ModuleName MusicServer.Management
        { Start-ManagementJob -Config $fixture.Config -Operation library-import } | Should Throw 'fixture start failure'
        Get-AppSettingDb -Key 'library_manifest_pending' | Should BeNullOrEmpty
        (Get-ManagementStatus -Config $fixture.Config).jobs[0].state | Should Be 'ERROR'
    }
    It 'unblocks recommendations when an interrupted portable import expires' {
        $id=[Guid]::NewGuid().ToString('N')
        Invoke-MusicServerParamNonQuery -Template 'INSERT INTO maintenance_jobs(id,operation,state,created_at,updated_at,deadline) VALUES(@id,''library-import'',''RUNNING'',@now,@now,0);' -Params @{id=$id;now=(Get-NowIso)}
        Set-AppSettingDb -Key library_manifest_pending -Value $id
        $status=Get-ManagementStatus -Config $fixture.Config
        $status.jobs[0].state | Should Be 'ERROR'
        Get-AppSettingDb -Key library_manifest_pending | Should BeNullOrEmpty
    }
    It 'cleans only the exited export job partial file and preserves other exports' {
        $id=[Guid]::NewGuid().ToString('N');$other=[Guid]::NewGuid().ToString('N')
        $part=Join-Path $fixture.Config.OutputDir ('.musicserver-library-export-'+$id+'.part')
        $otherPart=Join-Path $fixture.Config.OutputDir ('.musicserver-library-export-'+$other+'.part')
        $finished=Join-Path $fixture.Config.OutputDir 'MusicServer-library-complete.zip'
        foreach ($path in @($part,$otherPart,$finished)) { [IO.File]::WriteAllText($path,'retained unless exact owned partial') }
        Mock Get-CimInstance { @() } -ModuleName MusicServer.Management
        Remove-ManagementStaging -Config $fixture.Config -JobId $id -Operation library-export
        Test-Path -LiteralPath $part | Should Be $false
        Test-Path -LiteralPath $otherPart | Should Be $true
        Test-Path -LiteralPath $finished | Should Be $true
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

Describe 'Deferred portable library import' {
    BeforeEach {
        $script:fixture=New-MusicServerRuntimeFixture -ProjectRoot $ProjectRoot
        Import-Module (Join-Path $ProjectRoot 'MusicServer.Management.psm1') -Force
        Import-Module (Join-Path $ProjectRoot 'MusicServer.Library.psm1') -Force -DisableNameChecking
        Initialize-ManagementSchema
    }
    AfterEach { Remove-MusicServerRuntimeFixture -Fixture $script:fixture }
    It 'retries a busy startup import when the maintenance slot becomes idle without polling hashes' {
        [IO.File]::WriteAllText((Join-Path $fixture.Config.MusicDir '.musicserver-library.json'),'{"schema":1}')
        $id=[Guid]::NewGuid().ToString('N')
        Invoke-MusicServerParamNonQuery -Template 'INSERT INTO maintenance_jobs(id,operation,state,created_at,updated_at,deadline) VALUES(@id,''diagnostics'',''RUNNING'',@now,@now,9999999999);' -Params @{id=$id;now=(Get-NowIso)}
        Mock Get-MusicServerMaintenanceClockSeconds { 100.0 } -ModuleName MusicServer.Management
        Mock Get-MusicServerLibraryStreamHash { 'a'*64 } -ModuleName MusicServer.Management
        Mock Start-Process { $null } -ModuleName MusicServer.Management
        Start-MusicServerLibraryImportIfNeeded -Config $fixture.Config | Should BeNullOrEmpty
        Start-MusicServerLibraryImportIfNeeded -Config $fixture.Config -RetryPending | Should BeNullOrEmpty
        Assert-MockCalled Get-MusicServerLibraryStreamHash -ModuleName MusicServer.Management -Times 0 -Exactly -Scope It
        Invoke-MusicServerParamNonQuery -Template 'UPDATE maintenance_jobs SET state=''DONE'' WHERE id=@id;' -Params @{id=$id}
        Mock Get-MusicServerMaintenanceClockSeconds { 131.0 } -ModuleName MusicServer.Management
        $scheduled=Start-MusicServerLibraryImportIfNeeded -Config $fixture.Config -RetryPending
        $scheduled | Should Match '^[a-f0-9]{32}$'
        Get-AppSettingDb -Key library_manifest_pending | Should Be $scheduled
        Start-MusicServerLibraryImportIfNeeded -Config $fixture.Config -RetryPending | Should BeNullOrEmpty
        Assert-MockCalled Start-Process -ModuleName MusicServer.Management -Times 1 -Exactly -Scope It
        Assert-MockCalled Get-MusicServerLibraryStreamHash -ModuleName MusicServer.Management -Times 1 -Exactly -Scope It
    }
}
