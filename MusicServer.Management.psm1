# Desktop maintenance is asynchronous. SQLite owns job state; snapshots are backups only.
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
    param($Config, [ValidateSet('components','diagnostics','backup','health')][string]$Operation)
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    # The child enforces its deadline as well; a terminated APP leaves a visible interrupted job.
    Invoke-MusicServerParamNonQuery -Template 'UPDATE maintenance_jobs SET state=''ERROR'',message=''INTERRUPTED_OR_TIMEOUT'' WHERE state=''RUNNING'' AND deadline < @now;' -Params @{now=$now} | Out-Null
    $existing = @(Invoke-MusicServerSqlJson -Query "SELECT id FROM maintenance_jobs WHERE state='RUNNING';")
    if ($existing.Count) { return $existing[0].id }
    $id = [Guid]::NewGuid().ToString('N')
    Invoke-MusicServerParamNonQuery -Template 'INSERT INTO maintenance_jobs(id,operation,state,created_at,updated_at,deadline) VALUES(@id,@op,''RUNNING'',@now,@now,@deadline);' -Params @{id=$id;op=$Operation;now=(Get-NowIso);deadline=($now+720)} | Out-Null
    try {
        $scriptPath = Join-Path $Config.Root 'manage_musicserver.ps1'
        $args = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -AppHome "{1}" -JobId {2}' -f $scriptPath,$Config.AppHome,$id
        Start-Process -FilePath 'powershell.exe' -ArgumentList $args -WindowStyle Hidden -WorkingDirectory $Config.Root -ErrorAction Stop | Out-Null
    } catch { Set-ManagementJob -Id $id -State ERROR -Message 'WORKER_START_FAILED'; throw }
    return $id
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

function Export-MusicServerDiagnostics {
    param($Config)
    $dir=Join-Path $Config.OutputDir ('diagnostics-'+[Guid]::NewGuid().ToString('N')); [IO.Directory]::CreateDirectory($dir) | Out-Null
    # Allowlisted fields only. Raw logs, DBs, paths, titles, URLs and exception bodies are never exported.
    $report=[ordered]@{created_at=(Get-NowIso); os=[Environment]::OSVersion.VersionString; powershell=$PSVersionTable.PSVersion.ToString(); library_available=[IO.Directory]::Exists($Config.MusicDir)}
    $report.components=@((Get-ManagementStatus -Config $Config).components)
    $report.queue=@(Invoke-MusicServerSqlJson -Query 'SELECT state,COUNT(*) AS count,MAX(attempt_count) AS max_attempts FROM wanted_queue GROUP BY state;')
    $report.failure_codes=@(Invoke-MusicServerSqlJson -Query "SELECT last_error AS code,COUNT(*) AS count FROM wanted_queue WHERE length(last_error) BETWEEN 1 AND 64 AND last_error NOT GLOB '*[^A-Z0-9_]*' GROUP BY last_error;")
    $report.events=@(Invoke-MusicServerSqlJson -Query 'SELECT id,event_type,provider,from_state,to_state,attempt,duration_ms,result,error_type,http_status,created_at FROM events ORDER BY id DESC LIMIT 100;')
    $report.jobs=@(Invoke-MusicServerSqlJson -Query 'SELECT id,operation,state,progress,created_at FROM maintenance_jobs ORDER BY created_at DESC LIMIT 20;')
    $report.integrity=@(Invoke-MusicServerSqlJson -Query 'PRAGMA quick_check;')
    [IO.File]::WriteAllText((Join-Path $dir 'diagnostics.json'),($report | ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $dir 'README.txt'),'Contains OS/PowerShell versions, component availability, queue state counts, maintenance operation IDs and SQLite integrity. No raw logs, song names, paths, cookies, credentials, audio or databases. This folder can be shared after review.')
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory($dir,$dir+'.zip')
    return $dir+'.zip'
}

