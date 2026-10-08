# Desktop maintenance is asynchronous. SQLite owns job state; snapshots are backups only.
$script:LibraryImportRetries=@{}
function Initialize-ManagementSchema {
    Invoke-MusicServerSqlNonQuery -Query @'
CREATE TABLE IF NOT EXISTS maintenance_jobs (
 id TEXT PRIMARY KEY, operation TEXT NOT NULL, state TEXT NOT NULL,
 progress INTEGER NOT NULL DEFAULT 0, message TEXT NOT NULL DEFAULT '',
 result_path TEXT NOT NULL DEFAULT '', created_at TEXT NOT NULL,
 deadline INTEGER NOT NULL, updated_at TEXT NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS one_active_maintenance ON maintenance_jobs(state) WHERE state='RUNNING';
'@ | Out-Null
}

function Get-ManagedComponentDirectory {
    param($Config)
    Join-Path $Config.AppHome 'components\yt20260819-ffmpeg901\bin'
}

function Get-DownloadComponentCatalog {
    @(
        [pscustomobject]@{ name='yt-dlp'; file='yt-dlp.exe'; version='2026.08.19'; size=17840399; sha256='66674953fe251b89f4d08c5f0e35e0728679bd67ab3d7d05c0562af101dd3e7a'; url='https://github.com/yt-dlp/yt-dlp/releases/download/2026.08.19/yt-dlp.exe' }
        [pscustomobject]@{ name='ffmpeg'; file='ffmpeg.zip'; version='9.0.1'; size=111253802; sha256='fec81ae03971d9dd4be3ebe02e263bd2ec1d789483f931bdba5f5715e65da2e9'; url='https://github.com/GyanD/codexffmpeg/releases/download/9.0.1/ffmpeg-9.0.1-essentials_build.zip' }
    )
}

function Set-ManagementJob {
    param([string]$Id, [string]$State='RUNNING', [int]$Progress=0, [string]$Message='', [string]$ResultPath='')
    Invoke-MusicServerParamNonQuery -Template 'UPDATE maintenance_jobs SET state=@state,progress=@progress,message=@message,result_path=@path,updated_at=@now WHERE id=@id AND state=''RUNNING'';' -Params @{ id=$Id; state=$State; progress=$Progress; message=$Message; path=$ResultPath; now=(Get-NowIso) } | Out-Null
}

function Get-ManagementStatus {
    param($Config)
    Invoke-MusicServerParamNonQuery -Template 'UPDATE maintenance_jobs SET state=''ERROR'',message=''INTERRUPTED_OR_TIMEOUT'' WHERE state=''RUNNING'' AND deadline < @now; DELETE FROM app_settings WHERE key=''library_manifest_pending'' AND NOT EXISTS(SELECT 1 FROM maintenance_jobs WHERE state=''RUNNING'' AND operation=''library-import'' AND id=app_settings.value);' -Params @{now=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()} | Out-Null
    $fresh = New-MusicServerConfig -Root $Config.Root -AppHome $Config.AppHome
    $components = foreach ($pair in @(@('YtDlp','yt-dlp'),@('FFmpeg','ffmpeg'),@('FFprobe','ffprobe'))) {
        $path = [string]$fresh.($pair[0])
        [pscustomobject]@{ name=$pair[1]; present=([IO.File]::Exists($path) -or [bool](Get-Command $path -ErrorAction SilentlyContinue)); managed=$path.StartsWith((Join-Path $Config.AppHome 'components'), [StringComparison]::OrdinalIgnoreCase) }
    }
    $jobs = @(Invoke-MusicServerSqlJson -Query 'SELECT id,operation,state,progress,message,result_path,created_at FROM maintenance_jobs ORDER BY created_at DESC LIMIT 8;')
    $backups = @(Get-MusicServerBackups -Config $Config)
    [pscustomobject]@{ components=@($components); ready=(@($components | Where-Object { -not $_.present }).Count -eq 0); jobs=$jobs; backups=$backups; restore_result=(Get-AppSettingDb -Key 'last_restore_result'); output_dir=$Config.OutputDir }
}

function Start-ManagementJob {
    param($Config, [ValidateSet('components','diagnostics','backup','health','library-export','library-import')][string]$Operation)
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    # The child enforces its deadline as well; a terminated APP leaves a visible interrupted job.
    Invoke-MusicServerParamNonQuery -Template 'UPDATE maintenance_jobs SET state=''ERROR'',message=''INTERRUPTED_OR_TIMEOUT'' WHERE state=''RUNNING'' AND deadline < @now;' -Params @{now=$now} | Out-Null
    $existing = @(Invoke-MusicServerSqlJson -Query "SELECT id FROM maintenance_jobs WHERE state='RUNNING';")
    if ($existing.Count) { return $existing[0].id }
    $id = [Guid]::NewGuid().ToString('N')
    Invoke-MusicServerParamNonQuery -Template 'INSERT INTO maintenance_jobs(id,operation,state,created_at,updated_at,deadline) VALUES(@id,@op,''RUNNING'',@now,@now,@deadline);' -Params @{id=$id;op=$Operation;now=(Get-NowIso);deadline=($now+720)} | Out-Null
    if ($Operation -eq 'library-import') { Set-AppSettingDb -Key 'library_manifest_pending' -Value $id }
    try {
        $scriptPath = Join-Path $Config.Root 'manage_musicserver.ps1'
        $args = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -AppHome "{1}" -JobId {2}' -f $scriptPath,$Config.AppHome,$id
        Start-Process -FilePath 'powershell.exe' -ArgumentList $args -WindowStyle Hidden -WorkingDirectory $Config.Root -ErrorAction Stop | Out-Null
    } catch {
        Set-ManagementJob -Id $id -State ERROR -Message 'WORKER_START_FAILED'
        if ($Operation -eq 'library-import') { Remove-AppSettingDb -Key 'library_manifest_pending' }
        throw
    }
    return $id
}

function Get-MusicServerMaintenanceClockSeconds {
    return [Diagnostics.Stopwatch]::GetTimestamp()/[double][Diagnostics.Stopwatch]::Frequency
}

function Start-MusicServerLibraryImportIfNeeded {
    param($Config, [switch]$RetryPending)
    $root=Get-MusicServerLibraryRootKey -Config $Config
    $cacheKey=(Get-MusicServerDbPath)+'|'+$root
    $cached=$script:LibraryImportRetries[$cacheKey]
    $now=Get-MusicServerMaintenanceClockSeconds
    if ($RetryPending -and (-not $cached -or -not $cached.pending -or $now -lt $cached.next_check)) { return $null }
    if (-not $cached) {
        $cached=@{pending=$false;next_check=0.0;stamp='';hash='';job_id=''}
        $script:LibraryImportRetries[$cacheKey]=$cached
    }
    $cached.next_check=$now+30.0
    $manifest=Join-Path $Config.MusicDir '.musicserver-library.json'
    if (-not [IO.Directory]::Exists($Config.MusicDir) -or -not [IO.File]::Exists($manifest)) { $cached.pending=$false;return $null }
    $file=Get-Item -LiteralPath $manifest
    if ($file.Length -gt 33554432) { $cached.pending=$false;return $null }
    $stamp=[string]$file.Length+'|'+$file.LastWriteTimeUtc.Ticks
    if ($stamp -ne $cached.stamp) { $cached.stamp=$stamp;$cached.hash='';$cached.job_id='' }
    $cached.pending=$true
    Initialize-MusicServerLibrarySchema
    # Do not advertise an import while another maintenance operation owns the
    # single job slot. Retain a throttled candidate for the idle API tick.
    $active=@(Invoke-MusicServerSqlJson -Query "SELECT id,operation FROM maintenance_jobs WHERE state='RUNNING';")
    if ($active.Count) { if ($active[0].operation -eq 'library-import') { $cached.job_id=[string]$active[0].id;return $cached.job_id }; return $null }
    if ($RetryPending -and $cached.job_id) {
        $previous=@(Invoke-MusicServerParamSql -Template 'SELECT state FROM maintenance_jobs WHERE id=@id LIMIT 1;' -Params @{id=$cached.job_id})
        if ($previous.Count -and $previous[0].state -eq 'ERROR') { $cached.pending=$false;return $null }
    }
    if (-not $cached.hash) {
        $stream=[IO.File]::OpenRead($manifest)
        try { $cached.hash=Get-MusicServerLibraryStreamHash -InputStream $stream }
        finally { $stream.Dispose() }
    }
    $known=@(Invoke-MusicServerParamSql -Template 'SELECT 1 AS present FROM library_imports WHERE root_key=@root AND manifest_hash=@hash LIMIT 1;' -Params @{root=$root;hash=$cached.hash})
    if ($known.Count) { $cached.pending=$false;return $null }
    $cached.job_id=Start-ManagementJob -Config $Config -Operation 'library-import'
    return $cached.job_id
}

function Receive-VerifiedComponent {
    param($Component, [string]$Destination, [scriptblock]$Progress)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $request = [Net.HttpWebRequest]::Create($Component.url)
    $request.Timeout=20000; $request.ReadWriteTimeout=15000; $request.MaximumAutomaticRedirections=5
    $request.UserAgent='MusicServer component setup'
    $clock=[Diagnostics.Stopwatch]::StartNew(); $response=$null; $inputStream=$null; $outputStream=$null
    try {
        $response=$request.GetResponse()
        if ($response.ResponseUri.Scheme -ne 'https') { throw 'INSECURE_REDIRECT' }
        if ($response.ContentLength -gt $Component.size) { throw 'COMPONENT_SIZE_MISMATCH' }
        $inputStream=$response.GetResponseStream(); $outputStream=[IO.File]::Create($Destination)
        $buffer=New-Object byte[] 65536; [long]$total=0; [long]$reported=0
        while (($read=$inputStream.Read($buffer,0,$buffer.Length)) -gt 0) {
            $total += $read
            if ($total -gt $Component.size -or $clock.Elapsed.TotalSeconds -gt 540) { throw 'COMPONENT_TRANSFER_LIMIT' }
            $outputStream.Write($buffer,0,$read)
            if ($total-$reported -gt 2097152) { & $Progress ($total/[double]$Component.size); $reported=$total }
        }
        $outputStream.Dispose(); $outputStream=$null
        if ($total -ne $Component.size -or (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash -ne $Component.sha256) { throw 'COMPONENT_CHECKSUM_MISMATCH' }
    } finally {
        if ($outputStream) { $outputStream.Dispose() }; if ($inputStream) { $inputStream.Dispose() }; if ($response) { $response.Dispose() }; $request.Abort()
    }
}

function Test-DownloadComponents {
    param($Config, [string]$Directory='')
    $versions=@{}
    foreach ($pair in @(@('YtDlp','yt-dlp.exe','--version'),@('FFmpeg','ffmpeg.exe','-version'),@('FFprobe','ffprobe.exe','-version'))) {
        $exe=if ($Directory) { Join-Path $Directory $pair[1] } else { $Config.($pair[0]) }
        $result=Invoke-MusicServerBoundedProcess -FilePath $exe -Arguments @($pair[2]) -TimeoutSeconds 15
        if ($result.ExitCode -ne 0) { throw "COMPONENT_UNHEALTHY:$($pair[0])" }
        $versions[$pair[0]]=($result.Output -split '\r?\n')[0]
    }
    $probeFile=Join-Path $Config.OutputDir ('component-probe-'+[Guid]::NewGuid().ToString('N')+'.wav')
    $ffmpeg=if ($Directory) { Join-Path $Directory 'ffmpeg.exe' } else { $Config.FFmpeg }
    $ffprobe=if ($Directory) { Join-Path $Directory 'ffprobe.exe' } else { $Config.FFprobe }
    try {
        $encode=Invoke-MusicServerBoundedProcess -FilePath $ffmpeg -Arguments @('-v','error','-nostdin','-f','lavfi','-i','anullsrc=r=8000:cl=mono','-t','0.2','-y',$probeFile) -TimeoutSeconds 15
        $decode=Invoke-MusicServerBoundedProcess -FilePath $ffprobe -Arguments @('-v','error','-show_entries','format=duration','-of','csv=p=0',$probeFile) -TimeoutSeconds 15
        if ($encode.ExitCode -ne 0 -or $decode.ExitCode -ne 0 -or $decode.Output -notmatch '0\.2') { throw 'COMPONENT_AUDIO_PROBE_FAILED' }
    } finally { if ([IO.File]::Exists($probeFile)) { [IO.File]::Delete($probeFile) } }
    return $versions
}

function Install-DownloadComponents {
    param($Config, [string]$JobId)
    $base=Join-Path $Config.AppHome 'components'; [IO.Directory]::CreateDirectory($base) | Out-Null
    $active=Get-ManagedComponentDirectory -Config $Config
    if ([IO.Directory]::Exists($active)) {
        try {
            Set-ManagementJob -Id $JobId -Progress 85 -Message 'VERIFY_AUDIO'
            $current=Test-DownloadComponents -Config $Config -Directory $active
            if ($current.YtDlp -eq '2026.08.19' -and $current.FFmpeg -match '9\.0\.1' -and $current.FFprobe -match '9\.0\.1') { return (Split-Path $active -Parent) }
        } catch { } # An unhealthy installed directory is repaired from pinned assets.
    }
    $stage=Join-Path $base ('staging-'+$JobId); [IO.Directory]::CreateDirectory((Join-Path $stage 'bin')) | Out-Null
    $catalog=@(Get-DownloadComponentCatalog); $index=0
    foreach ($component in $catalog) {
        $offset=$index*40; Set-ManagementJob -Id $JobId -Progress $offset -Message ('FETCH_'+$component.name)
        for ($attempt=0; $attempt -lt 2; $attempt++) {
            try {
                Receive-VerifiedComponent -Component $component -Destination (Join-Path $stage $component.file) -Progress { param($fraction) Set-ManagementJob -Id $JobId -Progress ($offset+[int]($fraction*40)) -Message ('FETCH_'+$component.name) }
                break
            } catch {
                if ($attempt -ge 1 -or $_.Exception.Message -match 'CHECKSUM|SIZE_MISMATCH|INSECURE') { throw }
                Start-Sleep -Seconds 2
            }
        }
        $index++
    }
    Move-Item -LiteralPath (Join-Path $stage 'yt-dlp.exe') -Destination (Join-Path $stage 'bin\yt-dlp.exe')
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip=[IO.Compression.ZipFile]::OpenRead((Join-Path $stage 'ffmpeg.zip'))
    try {
        foreach ($entry in $zip.Entries) {
            if ($entry.Name -in @('ffmpeg.exe','ffprobe.exe')) { [IO.Compression.ZipFileExtensions]::ExtractToFile($entry,(Join-Path $stage ('bin\'+$entry.Name))) }
            elseif ($entry.Name -match '^(LICENSE|README).*') { [IO.Compression.ZipFileExtensions]::ExtractToFile($entry,(Join-Path $stage $entry.Name)) }
        }
    } finally { $zip.Dispose() }
    Set-ManagementJob -Id $JobId -Progress 85 -Message 'VERIFY_AUDIO'
    $versions=Test-DownloadComponents -Config $Config -Directory (Join-Path $stage 'bin')
    if ($versions.YtDlp -ne '2026.08.19' -or $versions.FFmpeg -notmatch '9\.0\.1' -or $versions.FFprobe -notmatch '9\.0\.1') { throw 'COMPONENT_VERSION_MISMATCH' }
    [IO.File]::Delete((Join-Path $stage 'ffmpeg.zip'))
    [IO.File]::WriteAllText((Join-Path $stage 'SOURCES.txt'),"yt-dlp: https://github.com/yt-dlp/yt-dlp/releases/tag/2026.08.19`r`nFFmpeg (Gyan GPL build): https://github.com/GyanD/codexffmpeg/releases/tag/9.0.1`r`nSource: https://ffmpeg.org/releases/ffmpeg-9.0.1.tar.xz`r`nSeparate optional executables downloaded from their publishers. Licenses are retained alongside this file.")
    $final=Split-Path (Get-ManagedComponentDirectory -Config $Config) -Parent
    $previous=$final+'.previous-'+$JobId
    if ([IO.Directory]::Exists($final)) { [IO.Directory]::Move($final,$previous) }
    try {
        # Windows may retain an executable mapping briefly after the health probe exits.
        # Activation remains atomic; retry only this rename, never bypass verification.
        $deadline=[DateTime]::UtcNow.AddSeconds(15)
        while ($true) {
            try { [IO.Directory]::Move($stage,$final); break } catch {
                if ([DateTime]::UtcNow -ge $deadline) { throw }
                Start-Sleep -Milliseconds 250
            }
        }
    } catch { if ([IO.Directory]::Exists($previous)) { [IO.Directory]::Move($previous,$final) }; throw }
    # Keep the previous verified directory for recovery; never remove a running executable.
    Set-AppSettingDb -Key 'download_components_verified' -Value (Get-NowIso)
    return $final
}

function Reset-InterruptedManagementJobs {
    param($Config)
    $jobs=@(Invoke-MusicServerSqlJson -Query "SELECT id,operation FROM maintenance_jobs WHERE state='RUNNING';")
    if (-not $jobs.Count) { Remove-AppSettingDb -Key 'library_manifest_pending'; return }
    $pattern='(?i)(?:^|\s)-File\s+"?'+[regex]::Escape((Join-Path $Config.Root 'manage_musicserver.ps1'))+'(?:"|\s|$)'
    $processes=@(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match $pattern })
    foreach ($job in $jobs) {
        $idPattern='(?i)(?:^|\s)-JobId\s+"?'+[regex]::Escape($job.id)+'(?:"|\s|$)'
        if (-not @($processes | Where-Object { $_.CommandLine -match $idPattern }).Count) {
            Set-ManagementJob -Id $job.id -State ERROR -Message 'INTERRUPTED_OR_TIMEOUT'
            if ($job.operation -eq 'library-export') {
                try { Remove-ManagementStaging -Config $Config -JobId $job.id -Operation library-export }
                catch { Write-MusicServerLog -Path (Join-Path $Config.LogDir 'management.log') -Message 'operation=library-export stage=cleanup result=DEFERRED' }
            }
        }
    }
    if (-not @(Invoke-MusicServerSqlJson -Query "SELECT id FROM maintenance_jobs WHERE state='RUNNING' AND operation='library-import';").Count) { Remove-AppSettingDb -Key 'library_manifest_pending' }
}

function Remove-ManagementStaging {
    param($Config, [string]$JobId, [ValidateSet('components','diagnostics','backup','health','library-export','library-import')][string]$Operation='components')
    if ($JobId -notmatch '^[a-f0-9]{32}$') { throw 'INVALID_JOB_ID' }
    if ($Operation -eq 'library-export') {
        $scriptPattern='(?i)(?:^|\s)-File\s+"?'+[regex]::Escape((Join-Path $Config.Root 'manage_musicserver.ps1'))+'(?:"|\s|$)'
        $idPattern='(?i)(?:^|\s)-JobId\s+"?'+[regex]::Escape($JobId)+'(?:"|\s|$)'
        $active=@(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction Stop | Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match $scriptPattern -and $_.CommandLine -match $idPattern })
        if ($active.Count) { throw 'EXPORT_STILL_RUNNING' }
        $output=[IO.Path]::GetFullPath($Config.OutputDir).TrimEnd('\','/')
        $part=[IO.Path]::GetFullPath((Join-Path $output ('.musicserver-library-export-'+$JobId+'.part')))
        if (-not $part.StartsWith($output+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'INVALID_STAGING_PATH' }
        if ([IO.File]::Exists($part)) { [IO.File]::Delete($part) }
        return
    }
    if ($Operation -ne 'components') { return }
    $base=[IO.Path]::GetFullPath((Join-Path $Config.AppHome 'components'))
    $stage=[IO.Path]::GetFullPath((Join-Path $base ('staging-'+$JobId)))
    if (-not $stage.StartsWith($base+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'INVALID_STAGING_PATH' }
    if ([IO.Directory]::Exists($stage)) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction Stop }
}

function Get-MusicServerBackups {
    param($Config)
    if (-not [IO.Directory]::Exists($Config.BackupDir)) { return @() }
    foreach ($dir in @(Get-ChildItem -LiteralPath $Config.BackupDir -Directory | Where-Object { $_.Name -match '^snapshot-[0-9]{8}T[0-9]{6}-[a-f0-9]{8}$' } | Sort-Object Name -Descending | Select-Object -First 20)) {
        $manifest=Join-Path $dir.FullName 'snapshot.json'
        if ([IO.File]::Exists($manifest)) {
            try { $data=[IO.File]::ReadAllText($manifest) | ConvertFrom-Json; [pscustomobject]@{ id=$dir.Name; created_at=$data.created_at; reason=$data.reason; size=(Get-Item -LiteralPath (Join-Path $dir.FullName 'musicserver.db')).Length } } catch {}
        }
    }
}

function New-MusicServerBackup {
    param($Config, [string]$Reason='manual')
    $id='snapshot-'+[DateTime]::UtcNow.ToString('yyyyMMddTHHmmss')+'-'+[Guid]::NewGuid().ToString('N').Substring(0,8)
    $dir=Join-Path $Config.BackupDir $id; [IO.Directory]::CreateDirectory($dir) | Out-Null
    $snapshot=Join-Path $dir 'musicserver.db'; $db=Join-Path $Config.StateDir 'musicserver.db'
    $escaped=$snapshot.Replace('\','/').Replace("'","''")
    $result=Invoke-MusicServerBoundedProcess -FilePath $Config.Sqlite -Arguments @('-batch',$db,".timeout 10000",".backup '$escaped'") -TimeoutSeconds 30
    if ($result.ExitCode -ne 0) { throw 'BACKUP_FAILED' }
    $check=Invoke-MusicServerBoundedProcess -FilePath $Config.Sqlite -Arguments @('-readonly','-batch',$snapshot,'PRAGMA quick_check;') -TimeoutSeconds 30
    if ($check.ExitCode -ne 0 -or $check.Output.Trim() -ne 'ok') { throw 'BACKUP_INTEGRITY_FAILED' }
    $metadata=@{schema=1;created_at=(Get-NowIso);reason=$Reason;sha256=(Get-FileHash -LiteralPath $snapshot -Algorithm SHA256).Hash}
    [IO.File]::WriteAllText((Join-Path $dir 'snapshot.json'),($metadata | ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    return $dir
}

function Restore-MusicServerBackup {
    param($Config, [string]$BackupId)
    if ($BackupId -notmatch '^snapshot-[0-9]{8}T[0-9]{6}-[a-f0-9]{8}$') { throw 'INVALID_BACKUP_ID' }
    $dir=Join-Path $Config.BackupDir $BackupId; $source=Join-Path $dir 'musicserver.db'
    $metadata=[IO.File]::ReadAllText((Join-Path $dir 'snapshot.json')) | ConvertFrom-Json
    if ($metadata.schema -ne 1 -or (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ne $metadata.sha256) { throw 'BACKUP_CHECKSUM_MISMATCH' }
    $check=Invoke-MusicServerBoundedProcess -FilePath $Config.Sqlite -Arguments @('-readonly','-batch',$source,'PRAGMA quick_check; SELECT COUNT(*) FROM app_settings; SELECT COUNT(*) FROM canonical_tracks;') -TimeoutSeconds 30
    if ($check.ExitCode -ne 0 -or $check.Output -notmatch '^ok\s') { throw 'BACKUP_INTEGRITY_FAILED' }
    $version=Invoke-MusicServerBoundedProcess -FilePath $Config.Sqlite -Arguments @('-readonly','-batch',$source,'PRAGMA user_version;') -TimeoutSeconds 15
    if ($version.ExitCode -ne 0 -or [int]$version.Output.Trim() -gt (Get-SchemaVersion)) { throw 'BACKUP_VERSION_TOO_NEW' }
    # Called only by the desktop shell after its owned service tree has stopped.
    # Refuse foreign services using this runtime rather than writing under a live worker.
    $servicePattern='(?i)(?:^|\s)-File\s+"?'+[regex]::Escape($Config.Root.TrimEnd('\')+'\')+'(start_musicserver_ui|music_api|wanted_worker|daily_recommend)\.ps1(?:"|\s|$)'
    $active=@(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match $servicePattern })
    if ($active.Count) { throw 'SERVICES_STILL_RUNNING' }
    $rollback=New-MusicServerBackup -Config $Config -Reason 'before-restore'
    $db=Join-Path $Config.StateDir 'musicserver.db'
    $staged=$db+'.restore'; [IO.File]::Copy($source,$staged,$true)
    # .backup does not checkpoint the source. Flush WAL before replacement so a
    # failed rename still leaves every original commit readable in the old DB.
    $checkpoint=Invoke-MusicServerBoundedProcess -FilePath $Config.Sqlite -Arguments @('-batch',$db,'PRAGMA wal_checkpoint(TRUNCATE);') -TimeoutSeconds 20
    if ($checkpoint.ExitCode -ne 0 -or $checkpoint.Output.Trim() -notmatch '^0\|') { throw 'DATABASE_BUSY' }
    foreach ($suffix in @('-wal','-shm')) { if ([IO.File]::Exists($db+$suffix)) { [IO.File]::Delete($db+$suffix) } }
    [IO.File]::Replace($staged,$db,$db+'.before-restore',$true)
    $jobTable=@(Invoke-MusicServerSqlJson -Query "SELECT name FROM sqlite_master WHERE name='maintenance_jobs';")
    if ($jobTable.Count) { Invoke-MusicServerSqlNonQuery -Query "UPDATE maintenance_jobs SET state='ERROR',message='INTERRUPTED_OR_TIMEOUT' WHERE state='RUNNING';" }
    Invoke-MusicServerSqlNonQuery -Query "UPDATE wanted_queue SET state='WANTED',claimed_by='',claimed_at=NULL,lease_expires_at=NULL,lease_expires_epoch=NULL,revision=revision+1 WHERE state IN ('RESOLVING','DOWNLOADING','VALIDATING');"
    return $rollback
}

function ConvertTo-MusicServerDiagnosticRoute {
    param([string]$Route)
    $path=($Route -split '[?#]',2)[0]
    if ($path -notmatch '^/(api|health)(/|$)') { return '' }
    $static=@('api','health','library','listening','stats','play','skip','tracks','lyrics','stream','like','today','recommendations','wanted','settings','onboarding','management','status','jobs','search','runtime','client-log','refresh','desktop','diagnostics','files','bootstrap','library-transfer')
    $parts=foreach ($part in @($path.Trim('/').Split('/') | Select-Object -First 8)) { if ($part -in $static) { $part } else { ':id' } }
    return '/'+($parts -join '/')
}

function Read-MusicServerDiagnosticTail {
    param([string]$Path, [int]$MaxBytes=65536)
    $stream=$null;$reader=$null
    try {
        $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        $truncated=$stream.Length -gt $MaxBytes
        if ($truncated) { [void]$stream.Seek(-$MaxBytes,[IO.SeekOrigin]::End) }
        $reader=New-Object IO.StreamReader($stream,[Text.Encoding]::UTF8,$true)
        if ($truncated) { [void]$reader.ReadLine() }
        return @([regex]::Split($reader.ReadToEnd(),'\r?\n') | Select-Object -Last 320)
    } finally { if ($reader) { $reader.Dispose() } elseif ($stream) { $stream.Dispose() } }
}

function ConvertTo-MusicServerDiagnosticLogEntry {
    param([string]$Line, [string]$Component)
    if ($Line.Length -gt 8192) { return $null }
    $entry=[ordered]@{component=$Component}
    if ($Line -match '^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\]') { $entry.at=$Matches[1] }
    if ($Line -match '\[(client|library|startup|request|quality|selection|generation|metadata)\]') { $entry.event=$Matches[1] }
    $numbers=@('elapsed_ms','duration_ms','count','files','items','selected','candidates','local','target','resolved','notFound','failed','progress','pid','download_calls','sqlite_calls','cacheItems','limit','live','lyric_checks','library_count','seed_count','remote_count','local_count','seed_misses')
    $tokens=@('phase','role','operation','stage','result','code','error_type','reason','source','state','diversity','stop_reason','skipped')
    foreach ($match in [regex]::Matches($Line,'(?:^|\s)([A-Za-z_][A-Za-z0-9_]*)=([^\s;]+)(?=\s|;|$)')) {
        $key=$match.Groups[1].Value;$value=$match.Groups[2].Value
        if ($key -in $numbers -or $key -match '^phase_[a-z_]{1,40}$') {
            $number=0.0
            if ([double]::TryParse($value,[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$number) -and $number -ge 0 -and $number -le 900000000) { $entry[$key]=$number }
        } elseif ($key -in $tokens -and $value -match '^[A-Za-z][A-Za-z0-9_-]{0,63}$') {
            if ($key -eq 'source' -and $value -notin @('local','navidrome','netease','bilibili','onboarding_starter','library','library_import','wanted_worker','sqlite')) { continue }
            $entry[$key]=$value
        } elseif ($key -in @('status','http_status') -and $value -match '^[1-5][0-9]{2}$') { $entry[$key]=[int]$value }
        elseif ($key -eq 'method' -and $value -in @('GET','POST','PUT','DELETE','PATCH','HEAD')) { $entry.method=$value }
        elseif ($key -eq 'route') { $route=ConvertTo-MusicServerDiagnosticRoute -Route $value; if ($route) { $entry.route=$route } }
        elseif ($key -in @('cacheHit','empty_result','preserved_existing_day','starter_fallback','library_available','metadata_failed','library_revision_pending','library_revision_ack','completed') -and $value -match '^(true|false)$') { $entry[$key]=$value -ieq 'true' }
    }
    # Older builds wrote free-form slow/error lines. Keep just route/status/time;
    # an exception body or a media identifier never enters the exported report.
    if ($Line -match '\bSLOW\s+(?:(GET|POST|PUT|DELETE|PATCH)\s+)?(/\S+)\s+took\s+([0-9,]+)\s*ms') {
        $entry.event='request_slow'
        if ($Matches[1]) { $entry.method=$Matches[1] }
        $entry.route=ConvertTo-MusicServerDiagnosticRoute -Route $Matches[2]
        $entry.duration_ms=[double]$Matches[3].Replace(',','')
    } elseif ($Line -match '\bERROR\s+(GET|POST|PUT|DELETE|PATCH)\s+(/\S+)\s+status=([1-5][0-9]{2})') {
        $entry.event='request_error';$entry.method=$Matches[1];$entry.route=ConvertTo-MusicServerDiagnosticRoute -Route $Matches[2];$entry.status=[int]$Matches[3]
    } elseif (-not $entry.Contains('event')) {
        foreach ($pattern in @('Launcher failed','UI request failed','Media handler failed','Media request failed','ARTIST backfill failed','Watchdog start failed','Navidrome sqlite query failed','NetEase lyric request failed')) {
            if ($Line.IndexOf($pattern,[StringComparison]::OrdinalIgnoreCase) -ge 0) { $entry.event='runtime_error';$entry.code=$pattern.ToUpperInvariant().Replace(' ','_');break }
        }
    }
    if (-not $entry.Contains('event') -and -not $entry.Contains('operation')) { return $null }
    return [pscustomobject]$entry
}

function Get-MusicServerDiagnosticLogs {
    param($Config)
    $logs=@(
        @('ui','musicserver-ui.log'),@('api','musicserver-api.log'),@('worker','musicserver-worker.log'),
        @('recommendation','musicserver-recommendation.log'),@('management','management.log'),@('watchdog','musicserver-ui.watchdog.log'),@('startup','musicserver-startup.log')
    )
    $result=New-Object Collections.ArrayList
    foreach ($pair in $logs) {
        $recent=New-Object Collections.ArrayList
        foreach ($suffix in @('.1','')) {
            $path=Join-Path $Config.LogDir ($pair[1]+$suffix)
            if (-not [IO.File]::Exists($path)) { continue }
            try {
                foreach ($line in @(Read-MusicServerDiagnosticTail -Path $path)) {
                    $entry=ConvertTo-MusicServerDiagnosticLogEntry -Line $line -Component $pair[0]
                    if ($entry) { [void]$recent.Add($entry) }
                }
            } catch { }
        }
        foreach ($entry in @($recent | Select-Object -Last 80)) { [void]$result.Add($entry) }
    }
    return @($result)
}

function Get-MusicServerDiagnosticStartup {
    param($Config)
    $path=Join-Path $Config.LogDir 'desktop-startup.json'
    if (-not [IO.File]::Exists($path)) { return $null }
    if ((Get-Item -LiteralPath $path).Length -gt 65536) { throw 'STARTUP_REPORT_TOO_LARGE' }
    $raw=[IO.File]::ReadAllText($path) | ConvertFrom-Json
    $report=[ordered]@{state='unknown';reason='UNKNOWN'}
    if ([string]$raw.state -in @('starting','ready','failed','stopped','cancelled')) { $report.state=[string]$raw.state }
    foreach ($name in @('pid','ui_port','api_port','at','elapsed_ms')) {
        $value=Get-OptionalProperty $raw $name $null
        $number=0.0
        if ($null -ne $value -and [double]::TryParse([string]$value,[ref]$number) -and $number -ge 0 -and $number -le 9999999999999) { $report[$name]=$number }
    }
    $message=[string](Get-OptionalProperty $raw 'message' '')
    foreach ($pair in @(
        @('Runtime deployment failed','RUNTIME_DEPLOYMENT_FAILED'),@('No verified service pair','SERVICE_READINESS_FAILED'),
        @('Waiting for owned UI/API','WAITING_FOR_SERVICES'),@('Checking local services','CHECKING_SERVICES'),
        @('Owned services ready','SERVICES_READY'),@("Reusing this app home's current services",'SERVICES_REUSED'),
        @('stopped','STOPPED'),@('cancelled','CANCELLED')
    )) { if ($message.IndexOf($pair[0],[StringComparison]::OrdinalIgnoreCase) -ge 0) { $report.reason=$pair[1];break } }
    return [pscustomobject]$report
}

function Export-MusicServerDiagnostics {
    param($Config)
    $dir=Join-Path $Config.OutputDir ('diagnostics-'+[Guid]::NewGuid().ToString('N')); [IO.Directory]::CreateDirectory($dir) | Out-Null
    # Extract bounded structured facts, never copy raw log lines or exception
    # bodies. Each independent source is fail-soft, including a damaged DB.
    $report=[ordered]@{schema=2;created_at=(Get-NowIso); os=[Environment]::OSVersion.VersionString; powershell=$PSVersionTable.PSVersion.ToString(); library_available=[IO.Directory]::Exists($Config.MusicDir)}
    $errors=New-Object Collections.ArrayList
    $report.components=@(foreach ($pair in @(@('YtDlp','yt-dlp'),@('FFmpeg','ffmpeg'),@('FFprobe','ffprobe'))) {
        $path=[string]$Config.($pair[0])
        [pscustomobject]@{name=$pair[1];present=([IO.File]::Exists($path) -or [bool](Get-Command $path -ErrorAction SilentlyContinue));managed=$path.StartsWith((Join-Path $Config.AppHome 'components'),[StringComparison]::OrdinalIgnoreCase)}
    })
    $queries=[ordered]@{
        queue='SELECT state,COUNT(*) AS count,MAX(attempt_count) AS max_attempts FROM wanted_queue GROUP BY state;'
        failure_codes="SELECT last_error AS code,COUNT(*) AS count FROM wanted_queue WHERE length(last_error) BETWEEN 1 AND 64 AND last_error NOT GLOB '*[^A-Z0-9_]*' GROUP BY last_error;"
        events='SELECT id,event_type,provider,from_state,to_state,attempt,duration_ms,result,error_type,http_status,created_at FROM events ORDER BY id DESC LIMIT 100;'
        jobs="SELECT id,operation,state,progress,created_at,CASE WHEN length(message) BETWEEN 1 AND 64 AND message NOT GLOB '*[^A-Za-z0-9_]*' THEN message ELSE '' END AS code FROM maintenance_jobs ORDER BY created_at DESC LIMIT 20;"
        integrity='PRAGMA quick_check;'
    }
    foreach ($name in $queries.Keys) {
        try { $report[$name]=@(Invoke-MusicServerSqlJson -Query $queries[$name]) }
        catch { $report[$name]=@();[void]$errors.Add([pscustomobject]@{section=$name;code='COLLECTION_FAILED';error_type=$_.Exception.GetBaseException().GetType().Name}) }
    }
    $report.runtime_log=@(Get-MusicServerDiagnosticLogs -Config $Config)
    try { $report.desktop_startup=Get-MusicServerDiagnosticStartup -Config $Config }
    catch { $report.desktop_startup=$null;[void]$errors.Add([pscustomobject]@{section='desktop_startup';code='COLLECTION_FAILED';error_type=$_.Exception.GetBaseException().GetType().Name}) }
    $report.collection_errors=@($errors)
    [IO.File]::WriteAllText((Join-Path $dir 'diagnostics.json'),($report | ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $dir 'README.txt'),'Contains OS/PowerShell versions, component availability, queue state counts, maintenance operation IDs, SQLite integrity, startup state and bounded sanitized recent runtime timings/failures. Media identifiers in request routes are replaced with :id. No raw logs, song names, user paths, URLs, cookies, credentials, audio or databases. Review before sharing.')
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory($dir,$dir+'.zip')
    return $dir+'.zip'
}

