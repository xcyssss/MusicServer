param(
    [string]$ApiPrefix = 'http://127.0.0.1:8787/',
    [string]$UiPrefix = 'http://127.0.0.1:8790/',
    [switch]$NoBrowser,
    [int]$ClientTimeoutSeconds = 90,
    [int]$LastClientGraceSeconds = 8
)

$ErrorActionPreference = 'Stop'
$startupClock = [Diagnostics.Stopwatch]::StartNew()
$startupPhases = [ordered]@{}
$ProgressPreference = 'SilentlyContinue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue } catch {}
try {
    # Media runspaces and the control proxy share .NET's connection pool. Keep
    # local API connections available while concurrent lyrics requests run.
    [System.Net.ServicePointManager]::DefaultConnectionLimit = 50
    [System.Net.ServicePointManager]::MaxServicePointIdleTime = 10000
} catch {}

$Root = $PSScriptRoot
$WebRoot = Join-Path $Root 'web'
$ApiScript = Join-Path $Root 'music_api.ps1'
$WorkerScript = Join-Path $Root 'wanted_worker.ps1'
$LogRoot = $null
$LyricsReportPath = $null
$UiLog = $null
$ApiOutLog = $null
$ApiErrLog = $null
$WorkerOutLog = $null
$WorkerErrLog = $null
$UiHeartbeatFile = $null
$WatchdogLog = $null
$ApiProcess = $null
$StartedApi = $false
$WorkerProcess = $null
$StartedWorker = $false
$Listener = $null
$Clients = @{}
$HasSeenClient = $false
$NoClientSince = $null
$StartupDeadline = [DateTime]::UtcNow.AddSeconds(60)
$LibraryFiles = @{}
# Watchdog state: the UI serves every request on one thread, so a handler that
# wedges (slow external call, proxy hang) freezes the whole UI. A background
# watchdog thread watches $script:LastActivityAt and force-restarts this process
# when the main loop has made no progress for too long.
$script:LastActivityAt = [DateTime]::UtcNow
$script:CurrentRequest = ''
$script:UiLibraryCache = $null
$script:UiLibraryCacheAt = [DateTime]::MinValue
$script:NextHeartbeatAt = [DateTime]::MinValue

function Write-UiLog {
    param([string]$Message)
    Write-MusicServerLog -Path $UiLog -Message $Message
}

function Test-ApiReady {
    param([ValidateRange(1, 400)][int]$TimeoutMilliseconds = 400)
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        try {
            $ok = $client.ConnectAsync('127.0.0.1', ([Uri]$ApiPrefix).Port).Wait($TimeoutMilliseconds)
            return $ok
        } finally {
            $client.Dispose()
        }
    } catch {
        return $false
    }
}

function Test-UiReady {
    # Port probe beats an HTTP health probe here: the UI serves every request on
    # a single thread, so a /health call can time out while the listener is
    # merely busy (e.g. mid-way through a slow proxied request). A listening port
    # means a UI process already owns the prefix; the double-click launcher must
    # then open the existing instance instead of failing with a prefix conflict.
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        try {
            $ok = $client.ConnectAsync('127.0.0.1', ([Uri]$UiPrefix).Port).Wait(400)
            return $ok
        } finally {
            $client.Dispose()
        }
    } catch {
        return $false
    }
}

function Start-MusicServerApi {
    param([ValidateRange(1, 27)][int]$StartupTimeoutSeconds = 27)
    if (Test-ApiReady) {
        Write-UiLog "API already running at $ApiPrefix"
        return
    }

    if (-not (Test-Path -LiteralPath $ApiScript -PathType Leaf)) {
        throw "music_api.ps1 not found: $ApiScript"
    }

    $escapedScript = $ApiScript.Replace('"', '\"')
    $escapedPrefix = $ApiPrefix.Replace('"', '\"')
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$escapedScript`" -Prefix `"$escapedPrefix`""
    $script:ApiProcess = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WorkingDirectory $Root -WindowStyle Hidden -PassThru -RedirectStandardOutput $ApiOutLog -RedirectStandardError $ApiErrLog
    $script:StartedApi = $true

    # The preflight above retains its conservative ownership probe. Once this
    # launcher owns the child, poll promptly under a total monotonic deadline.
    # Previously 30 * (500 ms sleep + 400 ms connect) could consume 27 seconds.
    $readyClock = [Diagnostics.Stopwatch]::StartNew()
    $budgetMs = $StartupTimeoutSeconds * 1000
    while ($readyClock.Elapsed.TotalMilliseconds -lt $budgetMs) {
        if ($script:ApiProcess.HasExited) {
            throw "music_api.ps1 exited before /health became ready. ExitCode=$($script:ApiProcess.ExitCode). See $ApiErrLog"
        }
        $remaining = [Math]::Max(1, [int]($budgetMs - $readyClock.Elapsed.TotalMilliseconds))
        if (Test-ApiReady -TimeoutMilliseconds ([Math]::Min(100, $remaining))) {
            Write-UiLog "API started at $ApiPrefix pid=$($script:ApiProcess.Id)"
            return
        }
        $remaining = [int]($budgetMs - $readyClock.Elapsed.TotalMilliseconds)
        if ($remaining -gt 0) {
            Start-Sleep -Milliseconds ([Math]::Min(100, $remaining))
        }
    }

    throw "MusicServer API did not become healthy at $ApiPrefix. See $ApiErrLog"
}

# Wanted worker: the background process that actually downloads liked tracks from
# the queue. The old launcher generation (start_musicserver.cmd/.vbs/.ps1) started
# it explicitly; the single-process UI launcher (start_musicserver_ui.ps1) never
# did, so likes stayed queued forever. This launcher now owns it the same way it
# owns the API: start it on launch, stop it when the last browser client closes.
function Test-WorkerReady {
    try {
        $stateDb = Join-Path $Config.StateDir 'musicserver.db'
        if (-not (Test-Path -LiteralPath $stateDb -PathType Leaf)) { return $false }
        # The queue mutex is per-named-mutex, not per-process: an existing healthy
        # worker holds 'MusicServer_WantedWorker', so we probe that instead of a port.
        $workerMutexName = [Environment]::GetEnvironmentVariable('MUSICSERVER_WORKER_MUTEX_NAME', 'Process')
        if ([string]::IsNullOrWhiteSpace($workerMutexName)) { $workerMutexName = 'MusicServer_WantedWorker' }
        $mutex = [Threading.Mutex]::new($false, $workerMutexName)
        try {
            $owned = $mutex.WaitOne(0)
            if ($owned) { $mutex.ReleaseMutex() }
            return (-not $owned)   # someone else holds it -> a worker is running
        } finally {
            $mutex.Dispose()
        }
    } catch {
        return $false
    }
}

function Start-MusicServerWorker {
    if ($env:MUSICSERVER_DISABLE_WORKER -eq '1') { return }
    if (Test-WorkerReady) {
        Write-UiLog 'Wanted worker already running (queue mutex held).'
        return
    }
    if (-not (Test-Path -LiteralPath $WorkerScript -PathType Leaf)) {
        Write-UiLog "wanted_worker.ps1 not found: $WorkerScript"
        return
    }
    $escapedScript = $WorkerScript.Replace('"', '\"')
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$escapedScript`" -PollSeconds 30"
    $script:WorkerProcess = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WorkingDirectory $Root -WindowStyle Hidden -PassThru -RedirectStandardOutput $WorkerOutLog -RedirectStandardError $WorkerErrLog
    $script:StartedWorker = $true
    Write-UiLog "Wanted worker started pid=$($script:WorkerProcess.Id)"
}

# Daily recommendations are generated by a Windows Scheduled Task because the
# desktop APP is not guaranteed to be running when the day rolls over. Register
# the task for a packaged APP_HOME and backfill the current day while it has no
# recommendations yet. Failures here must never block the UI/API startup.
function Test-DailyRecommendTaskCurrent {
    param([psobject]$Task, [string]$Generator)
    if (-not $Task) { return $false }
    $action = @($Task.Actions) | Select-Object -First 1
    if (-not $action) { return $false }
    if (([string]$action.Arguments).IndexOf($Generator, [StringComparison]::OrdinalIgnoreCase) -lt 0) { return $false }
    $settings = $Task.Settings
    if (-not $settings) { return $false }
    # A task registered before these were set is unusable on a laptop or when the
    # PC was off at the trigger time, so it must be re-registered, not reused.
    if (-not $settings.StartWhenAvailable) { return $false }
    if ($settings.DisallowStartIfOnBatteries) { return $false }
    if ($settings.StopIfGoingOnBatteries) { return $false }
    return $true
}

# The task follows the user. A repair triggered by a moved install directory, a
# reinstall, or settings written by an older build must keep the schedule the
# user chose instead of silently resetting it to 07:00 / 20. Both values are
# read back from the task that is about to be replaced.
function Get-DailyRecommendTaskPreferences {
    param([psobject]$Task)
    $preferences = @{ Time = ''; Count = 0 }
    if (-not $Task) { return $preferences }
    $trigger = @($Task.Triggers) | Select-Object -First 1
    if ($trigger -and $trigger.StartBoundary) {
        # A daily trigger stores the wall-clock time the user picked. Read the
        # time as written: converting the offset to local time would shift the
        # schedule whenever the reading machine sits in another time zone.
        $match = [regex]::Match([string]$trigger.StartBoundary, '[T ](\d{2}):(\d{2})')
        if ($match.Success) {
            $preferences.Time = '{0}:{1}' -f $match.Groups[1].Value, $match.Groups[2].Value
        } else {
            try {
                $preferences.Time = ([datetime]$trigger.StartBoundary).ToString('HH:mm')
            } catch { }
        }
    }
    $action = @($Task.Actions) | Select-Object -First 1
    if ($action) {
        $match = [regex]::Match([string]$action.Arguments, '-Count\s+(\d{1,3})')
        if ($match.Success) {
            $count = [int]$match.Groups[1].Value
            if ($count -ge 1 -and $count -le 100) { $preferences.Count = $count }
        }
    }
    return $preferences
}

function Test-DailyRecommendGeneratedToday {
    try {
        # The task is registered with `-AppHome $Root`, so the health check must
        # read that same home. `$Config` resolves APP_HOME from the environment,
        # which can differ from the directory this launcher was installed into.
        $taskConfig = New-MusicServerConfig -Root $Root -AppHome $Root
        $dbPath = Join-Path $taskConfig.StateDir 'musicserver.db'
        if (-not (Test-Path -LiteralPath $dbPath -PathType Leaf)) { return $false }
        # Connecting rebinds the shared Database module, so put the launcher's own
        # binding back afterwards instead of leaking this probe into later reads.
        $previousDb = Get-MusicServerDbPath
        $previousExe = Get-MusicServerSqliteExe
        try {
            Connect-MusicServerDatabase -DbPath $dbPath -SqliteExe $taskConfig.Sqlite
            $rows = @(Invoke-MusicServerParamSql -Template 'SELECT COUNT(*) AS cnt FROM daily_recommendations WHERE date = @d;' -Params @{ d = (Get-TodayDate) })
            return ((@($rows).Count -gt 0) -and ([int]$rows[0].cnt -gt 0))
        } finally {
            if ($previousDb) { Connect-MusicServerDatabase -DbPath $previousDb -SqliteExe $previousExe }
        }
    } catch {
        return $false
    }
}

function Initialize-MusicServerScheduledTasks {
    if ($env:MUSICSERVER_DISABLE_SCHEDULED_TASKS -eq '1') { return }
    # A source checkout (or a test fixture) must not register machine state.
    if (Test-Path -LiteralPath (Join-Path $Root '.git')) { return }
    $generator = Join-Path $Root 'daily_recommend.ps1'
    $registrar = Join-Path $Root 'register_daily_recommend.ps1'
    if (-not (Test-Path -LiteralPath $generator -PathType Leaf)) {
        Write-UiLog "Scheduled task setup skipped: $generator is missing"
        return
    }
    if (-not (Test-Path -LiteralPath $registrar -PathType Leaf)) {
        Write-UiLog "Scheduled task setup skipped: $registrar is missing"
        return
    }

    $taskName = 'MusicServer_DailyRecommend'
    try {
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if (-not (Test-DailyRecommendTaskCurrent -Task $task -Generator $generator)) {
            # Carry the user's own schedule across the repair (moved install
            # directory, reinstall, or defaults written by an older build).
            $preferences = Get-DailyRecommendTaskPreferences -Task $task
            $registerArgs = @{ AppHome = $Root }
            $effectiveTime = '07:00'
            $effectiveCount = 20
            if ($preferences.Time) { $registerArgs['Time'] = $preferences.Time; $effectiveTime = $preferences.Time }
            if ($preferences.Count) { $registerArgs['Count'] = $preferences.Count; $effectiveCount = $preferences.Count }
            & $registrar @registerArgs | Out-Null
            Write-UiLog "Registered scheduled task $taskName (time=$effectiveTime; count=$effectiveCount)"
            $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        }

        # Backfill while the day still has nothing. Keying off the stored rows
        # instead of the last run time means a run that failed mid-way (network,
        # or a library that was still empty) cannot leave the day permanently
        # without recommendations.
        $generatedToday = Test-DailyRecommendGeneratedToday
        $recentRun = $false
        $info = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
        if ($info -and $info.LastRunTime) {
            $lastRun = [datetime]$info.LastRunTime
            if ($lastRun.Year -gt 1900) { $recentRun = (((Get-Date) - $lastRun).TotalMinutes -lt 15) }
        }
        $running = $false
        if ($task) { $running = ([string]$task.State -eq 'Running') }
        if ((-not $running) -and (-not $generatedToday) -and (-not $recentRun)) {
            Start-ScheduledTask -TaskName $taskName
            Write-UiLog "Started scheduled task $taskName to backfill today's recommendations"
        }
    } catch {
        Write-UiLog "Scheduled task setup skipped: $($_.Exception.Message)"
    }
}

Import-Module (Join-Path $Root 'MusicServer.Core.psm1') -Force
Import-Module (Join-Path $Root 'MusicServer.Database.psm1') -Force
Import-Module (Join-Path $Root 'MusicServer.State.psm1') -Force
Import-Module (Join-Path $Root 'MusicServer.Http.psm1') -Force
Import-Module (Join-Path $Root 'MusicServer.Providers.psm1') -Force
Import-Module (Join-Path $Root 'MusicServer.Identity.psm1') -Force
$startupPhases['module_imports'] = $startupClock.Elapsed.TotalMilliseconds
$script:BuildMarker = Get-MusicServerBuildIdentity -Root $Root
$startupPhases['build_identity'] = $startupClock.Elapsed.TotalMilliseconds
$Config = New-MusicServerConfig -Root $Root
$LogRoot = $Config.LogDir
$LyricsReportPath = $Config.LyricsReport
$UiLog = Join-Path $LogRoot 'musicserver-ui.log'
$ApiOutLog = Join-Path $LogRoot 'musicserver-api.stdout.log'
$ApiErrLog = Join-Path $LogRoot 'musicserver-api.stderr.log'
$WorkerOutLog = Join-Path $LogRoot 'musicserver-worker.stdout.log'
$WorkerErrLog = Join-Path $LogRoot 'musicserver-worker.stderr.log'
$UiHeartbeatFile = Join-Path $LogRoot 'musicserver-ui.heartbeat'
$WatchdogLog = Join-Path $LogRoot 'musicserver-ui.watchdog.log'
Initialize-MusicServerState -Config $Config -SkipLibrary
if (-not (Test-Path -LiteralPath $LogRoot -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $LogRoot | Out-Null
}
# Resolve configured music dir from SQLite if available (DB may already exist from a prior run)
try {
    $uiDbPath = Join-Path $Config.StateDir 'musicserver.db'
    if (Test-Path -LiteralPath $uiDbPath -PathType Leaf) {
        Connect-MusicServerDatabase -DbPath $uiDbPath -SqliteExe $Config.Sqlite
        Apply-ConfiguredMusicDir -Config $Config
        # The artist cache is read while assembling every library response, so
        # create it here rather than waiting for the API process or the backfill.
        Initialize-LocalTrackArtistSchema
    }
} catch {}
try { Initialize-MusicServerLibrary -Config $Config | Out-Null } catch {}
$startupPhases['config_library'] = $startupClock.Elapsed.TotalMilliseconds

function Invoke-NavidromeSqliteJson {
    param([Parameter(Mandatory)][string]$Sql)

    if (-not (Test-Path -LiteralPath $Config.NdDb -PathType Leaf)) { return @() }
    $sqlite = [string]$Config.Sqlite
    if (-not $sqlite) { return @() }

    $errorFile = Join-Path ([System.IO.Path]::GetTempPath()) ("musicserver_nav_{0}.err" -f [guid]::NewGuid().ToString('N'))
    try {
        # Invoke sqlite directly so the complete SQL statement is passed as one
        # argument. Start-Process -ArgumentList flattens the SQL string and can
        # make sqlite receive only an incomplete statement such as "SELECT".
        $output = & $sqlite '-readonly' '-json' $Config.NdDb $Sql 2> $errorFile
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            $detail = if (Test-Path -LiteralPath $errorFile) { Get-Content -LiteralPath $errorFile -Raw -ErrorAction SilentlyContinue } else { '' }
            Write-UiLog "Navidrome sqlite query failed exit=$exitCode $detail"
            return @()
        }
        $text = (@($output) -join [Environment]::NewLine)
        if ([string]::IsNullOrWhiteSpace($text)) { return @() }
        $parsed = ConvertFrom-Json -InputObject $text
        if ($null -eq $parsed) { return @() }
        return @($parsed)
    } catch {
        Write-UiLog "Navidrome sqlite query exception: $($_.Exception.Message)"
        return @()
    } finally {
        Remove-Item -LiteralPath $errorFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-LocalLibraryId {
    param([Parameter(Mandatory)][string]$File)
    return Get-MusicServerLocalIdentity -File $File
}

function Get-LrcPath {
    param([string]$File)
    if (-not $File) { return $null }
    $candidate = [System.IO.Path]::ChangeExtension($File, '.lrc')
    if ([IO.File]::Exists($candidate)) { return $candidate }
    return $null
}

function Get-LyricQuality {
    param([Parameter(Mandatory)][string]$File)

    if (-not (Test-Path -LiteralPath $LyricsReportPath -PathType Leaf)) { return 'UNVERIFIED' }
    try {
        $fileName = [System.IO.Path]::GetFileName($File)
        $row = Import-Csv -LiteralPath $LyricsReportPath |
            Where-Object { [string]$_.File -eq $fileName } |
            Select-Object -First 1
        if ($row -and $row.Status) { return ([string]$row.Status).ToUpperInvariant() }
    } catch {
        Write-UiLog "Could not read lyric quality for $File : $($_.Exception.Message)"
    }
    return 'UNVERIFIED'
}

function Get-NeteaseIdForTrack {
    param([Parameter(Mandatory)]$TrackResponse)

    $recommendation = $TrackResponse.recommendation
    if ($recommendation) {
        $explicitId = [string]$recommendation.netease_id
        if (-not [string]::IsNullOrWhiteSpace($explicitId)) { return $explicitId.Trim() }
        $playbackValue = [string]$recommendation.playback_source
        if ($playbackValue -match '^netease:(.+)$') { return ([string]$Matches[1]).Trim() }
    }

    foreach ($identifier in @($TrackResponse.track.identifiers)) {
        $identifierType = [string]$identifier.type
        $identifierValue = [string]$identifier.value
        if ($identifierType.ToLowerInvariant() -eq 'netease' -and -not [string]::IsNullOrWhiteSpace($identifierValue)) {
            return $identifierValue.Trim()
        }
    }
    return ''
}

function Get-NetEaseLyricsById {
    param([Parameter(Mandatory)][string]$SongId)

    $headers = @{
        'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/124 Safari/537.36'
        'Referer' = 'https://music.163.com/'
        'Accept' = 'application/json,text/plain,*/*'
    }
    try {
        $encoded = [System.Uri]::EscapeDataString($SongId)
        $response = Invoke-RestMethod -Uri "https://music.163.com/api/song/lyric?id=$encoded&lv=1&kv=1&tv=-1" -Headers $headers -TimeoutSec 15
        if ($response -and $response.lrc -and $response.lrc.lyric) {
            return [string]$response.lrc.lyric
        }
    } catch {
        Write-UiLog "NetEase lyric request failed song=$SongId : $($_.Exception.Message)"
    }
    return ''
}

# A flat library keeps every file directly in MusicDir. The library root's own
# name is not an artist, and reporting it as one is why every row used to show
# the same placeholder ("Music") instead of a name.
function Get-LibraryFolderArtist {
    param([Parameter(Mandatory)][string]$File)
    $parent = Split-Path -Parent $File
    if (-not $parent) { return '' }
    $root = [string]$Config.MusicDir
    if (-not [string]::IsNullOrWhiteSpace($root)) {
        try {
            if ([IO.Path]::GetFullPath($parent).TrimEnd('\') -ieq [IO.Path]::GetFullPath($root).TrimEnd('\')) { return '' }
        } catch { }
    }
    return [string](Split-Path -Leaf $parent)
}

function Get-UiLibrary {
    # The single-threaded UI is hammered by browser polls (every open tab polls
    # /api/library every 15s). Each call used to re-scan the whole Music folder
    # and recompute a SHA per file (~0.5-1s), so a few tabs froze the listener.
    # Cache the assembled list: the library only changes when files move in/out,
    # which the refresh button and a short TTL handle.
    $cacheAge = ([DateTime]::UtcNow - $script:UiLibraryCacheAt).TotalSeconds
    if ($null -ne $script:UiLibraryCache -and $cacheAge -lt 30) {
        return @($script:UiLibraryCache)
    }
    $items = New-Object System.Collections.ArrayList
    $seenFiles = @{}
    $script:LibraryFiles = @{}

    # Navidrome 0.63.x stores songs in media_file. Keep the UI response aliases
    # stable so the frontend does not depend on Navidrome's internal column names.
    # `missing` is Navidrome's own bookkeeping and only a scan refreshes it; the
    # packaged runtime does not ship Navidrome, so on a machine without it every
    # row stays flagged missing and filtering on the flag hid the whole library,
    # leaving the folder-name fallback below to invent an artist for every row.
    # The file-existence check further down is the fact that matters.
    $sql = 'SELECT id, title AS name, artist, album, path, duration, track_number AS track, created_at AS addedto, updated_at AS collectionat FROM media_file;'
    foreach ($row in @(Invoke-NavidromeSqliteJson -Sql $sql)) {
        $file = [string]$row.path
        if ([string]::IsNullOrWhiteSpace($file)) { continue }
        try {
            if (-not [System.IO.Path]::IsPathRooted($file)) {
                $musicRoot = @($Config.MusicDir | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) } | Select-Object -First 1)
                if ($musicRoot.Count -gt 0) { $file = Join-Path ([string]$musicRoot[0]) $file }
                else { continue }
            }
            $file = [System.IO.Path]::GetFullPath($file)
        } catch { continue }
        if (-not [IO.File]::Exists($file)) { continue }

        $seenFiles[$file.ToLowerInvariant()] = $true
        $id = 'library-' + [string]$row.id
        $script:LibraryFiles[$id] = $file
        $lrcPath = Get-LrcPath -File $file
        [void]$items.Add([pscustomobject]@{
            id = $id; source = 'navidrome'; provider = 'navidrome'
            name = [string]$row.name; title = [string]$row.name
            artist = [string]$row.artist; album = [string]$row.album
            duration = [int]$row.duration; track = [int]$row.track
            addedto = [string]$row.addedto; collectionat = [string]$row.collectionat
            path = $file; file = $file
            stream_url = "/api/library/$id/stream"
            lyrics_url = if ($lrcPath) { "/api/library/$id/lyrics" } else { '' }
        })
    }

    foreach ($dir in @($Config.MusicDir)) {
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
        foreach ($entry in @(Get-ChildItem -LiteralPath $dir -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.mp3','.flac','.wav','.aac','.m4a' })) {
            $file = [System.IO.Path]::GetFullPath($entry.FullName)
            $fileKey = $file.ToLowerInvariant()
            if ($seenFiles.ContainsKey($fileKey)) { continue }
            $seenFiles[$fileKey] = $true
            $id = Get-LocalLibraryId -File $file
            $script:LibraryFiles[$id] = $file
            $title = [System.IO.Path]::GetFileNameWithoutExtension($file)
            $artist = Get-LibraryFolderArtist -File $file
            $lrcPath = Get-LrcPath -File $file
            $addedAt = ''
            try { $addedAt = (Get-Item -LiteralPath $file).LastWriteTime.ToString('o') } catch {}
            [void]$items.Add([pscustomobject]@{
                id = $id; source = 'local'; provider = 'navidrome'
                name = $title; title = $title; artist = $artist; album = $artist
                duration = 0; track = 0; addedto = $addedAt; collectionat = $addedAt
                path = $file; file = $file
                stream_url = "/api/library/$id/stream"
                lyrics_url = if ($lrcPath) { "/api/library/$id/lyrics" } else { '' }
            })
        }
    }

    # Bilibili downloads tag the uploader rather than the singer and sit directly
    # in the library root, so neither the index nor the folder names the artist.
    # Apply the resolution: the cached online match when there is one, otherwise
    # the uploader's own "<artist>《<song>》" label, otherwise the index value.
    # Fail-soft: this also runs inside media runspaces that hold no state DB.
    $resolved = @{}
    try { $resolved = Get-LocalTrackArtistMapDb } catch { $resolved = @{} }
    $prefixes = @()
    try { $prefixes = @(Get-SharedTitlePrefixes -Titles @($items | ForEach-Object { [string]$_.title })) } catch { $prefixes = @() }
    foreach ($item in $items) {
        $key = Get-MusicServerPathKey -Path ([string]$item.file)
        $row = if ($key -and $resolved.ContainsKey($key)) { $resolved[$key] } else { $null }
        $decision = Resolve-DisplayArtist -Title ([string]$item.title) -Indexed ([string]$item.artist) -CachedRow $row -KnownPrefixes $prefixes
        if (-not $decision) { continue }
        if ($decision.artist) { $item.artist = $decision.artist }
        if ($decision.album) { $item.album = $decision.album }
        if ($decision.source) {
            $item | Add-Member -NotePropertyName 'artist_source' -NotePropertyValue ([string]$decision.source) -Force
        }
    }

    $script:UiLibraryCache = @($items)
    $script:UiLibraryJsonCache = $null
    $script:UiLibraryCacheAt = [DateTime]::UtcNow
    return @($items)
}

function Resolve-UiLibraryFile {
    param([Parameter(Mandatory)][string]$Id)
    Write-UiLog "RESOLVE $Id cacheHit=$($script:LibraryFiles.ContainsKey($Id)) cacheItems=$($script:LibraryFiles.Count)"
    if ($script:LibraryFiles.ContainsKey($Id)) {
        $candidate = [string]$script:LibraryFiles[$Id]
        if ([IO.File]::Exists($candidate)) { return $candidate }
    }
    if ($Id.StartsWith('library-')) {
        $navId = $Id.Substring(8).Replace("'", "''")
        $rows = @(Invoke-NavidromeSqliteJson -Sql "SELECT path FROM media_file WHERE id = '$navId' LIMIT 1;")
        if ($rows.Count -gt 0) {
            $file = [string]$rows[0].path
            if ($file) {
                if (-not [IO.Path]::IsPathRooted($file)) { $file = Join-Path $Config.MusicDir $file }
                if ([IO.File]::Exists($file)) { return [IO.Path]::GetFullPath($file) }
            }
        }
        return $null
    }
    [void](Get-UiLibrary)
    if ($script:LibraryFiles.ContainsKey($Id)) {
        $candidate = [string]$script:LibraryFiles[$Id]
        if ([IO.File]::Exists($candidate)) { return $candidate }
    }
    return $null
}

# Writes response bytes with a hard timeout. HttpListener's OutputStream blocks
# forever (no exception, no timeout) once the client has disconnected mid-write,
# and this UI serves every request on one thread, so one wedged write froze the
# whole player. Async write + wait bounds the block; on timeout we give up and
# close, letting the main loop move on.
function Send-ResponseBytes {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][byte[]]$Bytes,
        [int]$TimeoutMs = 5000
    )
    try {
        $stream = $Context.Response.OutputStream
        $async = $stream.BeginWrite($Bytes, 0, $Bytes.Length, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs)) {
            try { $Context.Response.Abort() } catch {}
            return $false
        }
        $stream.EndWrite($async)
        try { $Context.Response.OutputStream.Close() } catch {}
        return $true
    } catch {
        try { $Context.Response.Abort() } catch {}
        return $false
    }
}

function Send-Json {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Body, [int]$StatusCode = 200)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Body -Depth 8 -Compress))
    try {
        $Context.Response.StatusCode = $StatusCode
        $Context.Response.ContentType = 'application/json; charset=utf-8'
        $Context.Response.ContentLength64 = $bytes.Length
        $Context.Response.Headers['Cache-Control'] = 'no-store'
    } catch {
        try { $Context.Response.Abort() } catch {}
        return
    }
    [void](Send-ResponseBytes -Context $Context -Bytes $bytes)
}

# Lyrics responses bypass ConvertTo-Json entirely: it has been observed spinning
# at 100% CPU on this long-running process for small lyric payloads (Japanese
# text with full-width brackets). Manual JSON with proper escaping is always safe.
function ConvertTo-JsonStringValue {
    param([AllowNull()][object]$Value)
    try { Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue } catch {}
    if ($null -eq $Value) { return '""' }
    return '"' + [System.Web.HttpUtility]::JavaScriptStringEncode([string]$Value) + '"'
}

function Send-LyricsJson {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$Id,
        [bool]$Available,
        [string]$Text,
        [string]$Quality,
        [string]$Source,
        [string]$Path,
        [string]$Message
    )
    $avail = if ($Available) { 'true' } else { 'false' }
    $json = '{"id":' + (ConvertTo-JsonStringValue $Id) + ',"available":' + $avail + ',"format":"lrc","text":' + (ConvertTo-JsonStringValue $Text) +
        ',"quality":' + (ConvertTo-JsonStringValue $Quality) + ',"source":' + (ConvertTo-JsonStringValue $Source) +
        ',"path":' + (ConvertTo-JsonStringValue $Path) + ',"message":' + (ConvertTo-JsonStringValue $Message) + '}'
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    try {
        $Context.Response.StatusCode = 200
        $Context.Response.ContentType = 'application/json; charset=utf-8'
        $Context.Response.ContentLength64 = $bytes.Length
        $Context.Response.Headers['Cache-Control'] = 'no-store'
    } catch {
        try { $Context.Response.Abort() } catch {}
        return
    }
    [void](Send-ResponseBytes -Context $Context -Bytes $bytes)
}

function Send-StaticFile {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][string]$ContentType
    )

    $file = Join-Path $WebRoot $RelativePath
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        $Context.Response.StatusCode = 404
        $Context.Response.Close()
        return
    }

    $bytes = [System.IO.File]::ReadAllBytes($file)
    if ($RelativePath -eq 'app.js') {
        $bytes = [Text.Encoding]::UTF8.GetBytes([Text.Encoding]::UTF8.GetString($bytes).Replace('musicserver-development', $script:BuildMarker))
    }
    $Context.Response.StatusCode = 200
    $Context.Response.ContentType = $ContentType
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.Headers['Cache-Control'] = 'no-store'
    [void](Send-ResponseBytes -Context $Context -Bytes $bytes)
}

function Send-IndexHtml {
    param([Parameter(Mandatory)]$Context)
    $file = Join-Path $WebRoot 'index.html'
    $html = Get-Content -LiteralPath $file -Raw -Encoding UTF8
    $lifecycleScript = @'
<script>
(() => {
  const clientId = (globalThis.crypto && crypto.randomUUID)
    ? crypto.randomUUID()
    : String(Date.now()) + '-' + Math.random().toString(16).slice(2);
  const heartbeatUrl = '/ui/heartbeat?id=' + encodeURIComponent(clientId);
  const heartbeat = () => fetch(heartbeatUrl, {
    method: 'POST', cache: 'no-store', keepalive: true
  }).catch(() => {});
  heartbeat();
  setInterval(heartbeat, 5000);
  document.addEventListener('visibilitychange', () => { if (!document.hidden) heartbeat(); });
  window.addEventListener('pageshow', heartbeat);
  window.addEventListener('pagehide', () => {
    try { navigator.sendBeacon('/ui/goodbye?id=' + encodeURIComponent(clientId), ''); } catch {}
  });
})();
</script>
'@
    if ($html.Contains('</body>')) {
        $html = $html.Replace('</body>', $lifecycleScript + [Environment]::NewLine + '</body>')
    } else {
        $html += $lifecycleScript
    }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($html)
    $Context.Response.StatusCode = 200
    $Context.Response.ContentType = 'text/html; charset=utf-8'
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.Headers['Cache-Control'] = 'no-store'
    [void](Send-ResponseBytes -Context $Context -Bytes $bytes)
}

function Send-LibraryStream {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Id)
    $file = Resolve-UiLibraryFile -Id $Id
    if (-not $file) {
        Send-Json -Context $Context -Body @{ error = 'FILE_NOT_FOUND'; id = $Id } -StatusCode 404
        return
    }

    $contentTypes = @{
        '.mp3' = 'audio/mpeg'; '.flac' = 'audio/flac'; '.wav' = 'audio/wav'
        '.aac' = 'audio/aac'; '.m4a' = 'audio/mp4'
    }
    $ext = [System.IO.Path]::GetExtension($file).ToLowerInvariant()
    $contentType = if ($contentTypes.ContainsKey($ext)) { $contentTypes[$ext] } else { 'application/octet-stream' }

    $length = (Get-Item -LiteralPath $file).Length

    # HTTP Range support is required for the browser <audio> element to seek
    # (drag the progress bar / jump forward). Parse "Range: bytes=start-end".
    $rangeHeader = $Context.Request.Headers['Range']
    $start = 0
    $end = $length - 1
    $isPartial = $false
    if ($rangeHeader -match 'bytes=(\d*)-(\d*)') {
        $rStart = $Matches[1]; $rEnd = $Matches[2]
        if ($rStart -ne '') { $start = [long]$rStart }
        if ($rEnd -ne '') { $end = [Math]::Min([long]$rEnd, $length - 1) }
        # Suffix range: bytes=-N means last N bytes.
        if ($rStart -eq '' -and $rEnd -ne '') {
            $n = [Math]::Min([long]$rEnd, $length)
            $start = $length - $n; $end = $length - 1
        }
        if ($start -ge $length -or $start -gt $end) {
            # Requested range beyond EOF: 416.
            try {
                $Context.Response.StatusCode = 416
                $Context.Response.Headers['Content-Range'] = "bytes */$length"
                $Context.Response.Close()
            } catch {}
            return
        }
        $isPartial = $true
    }

    $chunkLength = $end - $start + 1
    $stream = [System.IO.File]::Open($file, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $Context.Response.StatusCode = if ($isPartial) { 206 } else { 200 }
        $Context.Response.ContentType = $contentType
        $Context.Response.Headers['Accept-Ranges'] = 'bytes'
        $Context.Response.ContentLength64 = $chunkLength
        if ($isPartial) {
            $Context.Response.Headers['Content-Range'] = "bytes $start-$end/$length"
        }
        if ($start -gt 0) { [void]$stream.Seek($start, [System.IO.SeekOrigin]::Begin) }
        $buffer = New-Object byte[] 65536
        $outStream = $Context.Response.OutputStream
        $remaining = $chunkLength
        while ($remaining -gt 0) {
            $toRead = [int][Math]::Min($buffer.Length, $remaining)
            $read = $stream.Read($buffer, 0, $toRead)
            if ($read -le 0) { break }
            $remaining -= $read
            # Async write + timeout: if the client (audio element) went away,
            # abort instead of blocking the single UI thread forever.
            try {
                $chunk = New-Object byte[] $read
                [Array]::Copy($buffer, $chunk, $read)
                $async = $outStream.BeginWrite($chunk, 0, $read, $null, $null)
                if (-not $async.AsyncWaitHandle.WaitOne(5000)) {
                    try { $Context.Response.Abort() } catch {}
                    break
                }
                $outStream.EndWrite($async)
            } catch {
                try { $Context.Response.Abort() } catch {}
                break
            }
        }
    } finally {
        $stream.Dispose()
        try { $Context.Response.OutputStream.Close() } catch {}
    }
}

function Send-LibraryLyrics {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Id)
    $file = Resolve-UiLibraryFile -Id $Id
    $lrcPath = if ($file) { Get-LrcPath -File $file } else { $null }
    if (-not $lrcPath) {
        Send-LyricsJson -Context $Context -Id $Id -Available $false -Text '' -Quality 'MISSING' -Source 'local' -Path '' -Message '这首歌暂时没有找到本地歌词。'
        return
    }

    $quality = Get-LyricQuality -File $file
    if ($quality -in @('SUSPECT','NO_MATCH','NO_LYRIC','ERROR')) {
        Send-LyricsJson -Context $Context -Id $Id -Available $false -Text '' -Quality $quality -Source 'local' -Path '' -Message '歌词匹配置信度不足，已隐藏，避免显示错误歌词。'
        return
    }

    $lyrics = Get-Content -LiteralPath $lrcPath -Raw -Encoding UTF8
    if ($lyrics -match '^\s*lrc\s*=\s*(.+)$') {
        try {
            $payload = ConvertFrom-Json -InputObject $Matches[1].Trim()
            if ($payload.lrc) { $lyrics = [string]$payload.lrc }
        } catch {}
    }
    Send-LyricsJson -Context $Context -Id $Id -Available $true -Text $lyrics -Quality $quality -Source 'local' -Path $lrcPath -Message ''
}

function Send-TrackLyrics {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$TrackId)

    $trackUrl = $ApiPrefix.TrimEnd('/') + '/api/tracks/' + [System.Uri]::EscapeDataString($TrackId)
    $details = $null
    try {
        $details = Invoke-RestMethod -Uri $trackUrl -TimeoutSec 10
    } catch {
        $body = '{"track_id":' + (ConvertTo-JsonStringValue $TrackId) + ',"available":false,"format":"lrc","text":"","quality":"MISSING","source":"none","message":"无法读取歌曲信息，暂时无法获取歌词。"}'
        Send-JsonRaw -Context $Context -Json $body
        return
    }

    $neteaseId = Get-NeteaseIdForTrack -TrackResponse $details
    if ($neteaseId) {
        $lyrics = Get-NetEaseLyricsById -SongId $neteaseId
        if (-not [string]::IsNullOrWhiteSpace($lyrics)) {
            $body = '{"track_id":' + (ConvertTo-JsonStringValue $TrackId) + ',"available":true,"format":"lrc","text":' + (ConvertTo-JsonStringValue $lyrics) + ',"quality":"EXACT","source":"netease","song_id":' + (ConvertTo-JsonStringValue $neteaseId) + ',"message":""}'
            Send-JsonRaw -Context $Context -Json $body
            return
        }
    }

    $playback = $details.playback_source
    if ($playback -and ([string]$playback.provider).ToLowerInvariant() -eq 'navidrome' -and $playback.id) {
        Send-LibraryLyrics -Context $Context -Id ([string]$playback.id)
        return
    }

    $missingSource = 'none'
    $missingMessage = '这首歌暂时没有可验证的歌词来源。'
    if ($neteaseId) {
        $missingSource = 'netease'
        $missingMessage = '网易云暂未返回这首歌的歌词。'
    }
    $body = '{"track_id":' + (ConvertTo-JsonStringValue $TrackId) + ',"available":false,"format":"lrc","text":"","quality":"MISSING","source":' + (ConvertTo-JsonStringValue $missingSource) + ',"message":' + (ConvertTo-JsonStringValue $missingMessage) + '}'
    Send-JsonRaw -Context $Context -Json $body
}

# Sends a pre-serialized JSON string with the standard headers.
function Send-JsonRaw {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Json, [int]$StatusCode = 200)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Json)
    try {
        $Context.Response.StatusCode = $StatusCode
        $Context.Response.ContentType = 'application/json; charset=utf-8'
        $Context.Response.ContentLength64 = $bytes.Length
        $Context.Response.Headers['Cache-Control'] = 'no-store'
    } catch {
        try { $Context.Response.Abort() } catch {}
        return
    }
    [void](Send-ResponseBytes -Context $Context -Bytes $bytes)
}

function Proxy-ApiRequest {
    param([Parameter(Mandatory)]$Context)

    $request = $Context.Request
    try {
        $requestBody = Read-MusicServerJsonRequest -Request $request
    } catch {
        if (-not $_.Exception.Data.Contains('HttpStatusCode')) { throw }
        $Context.Response.KeepAlive = $false
        Send-Json -Context $Context -StatusCode ([int]$_.Exception.Data['HttpStatusCode']) -Body @{
            error = [string]$_.Exception.Data['ErrorCode']; message = $_.Exception.Message
        }
        return
    }
    $pathAndQuery = $request.Url.PathAndQuery
    if ($pathAndQuery -match '^/api/recommendations/today(?:\?|$)') {
        $pathAndQuery = $pathAndQuery -replace '^/api/recommendations/today', '/api/today'
    }

    $target = $ApiPrefix.TrimEnd('/') + $pathAndQuery
    $proxyRequest = [System.Net.HttpWebRequest]::Create($target)
    $proxyRequest.Method = $request.HttpMethod
    $proxyRequest.AllowAutoRedirect = $false
    $proxyRequest.Timeout = 20000
    $proxyRequest.ReadWriteTimeout = 20000
    if ($request.ContentType) { $proxyRequest.ContentType = $request.ContentType }
    if ($requestBody.Bytes.Length -gt 0) {
        $proxyRequest.ContentLength = $requestBody.Bytes.Length
        $out = $proxyRequest.GetRequestStream()
        try { $out.Write($requestBody.Bytes, 0, $requestBody.Bytes.Length) } finally { $out.Dispose() }
    } elseif ($request.HttpMethod -in @('POST','PUT','PATCH','DELETE')) {
        # A bodyless POST/DELETE must still declare Content-Length: 0. HttpWebRequest
        # otherwise leaves the length unspecified and the HttpListener on the API
        # side answers 411 Length Required, which the browser surfaces as a failed
        # like/queue/delete action even though the backend is healthy.
        $proxyRequest.ContentLength = 0
    }

    $proxyResponse = $null
    try {
        $proxyResponse = $proxyRequest.GetResponse()
    } catch [System.Net.WebException] {
        if ($_.Exception.Response) { $proxyResponse = $_.Exception.Response } else { throw }
    }

    try {
        $Context.Response.StatusCode = [int]$proxyResponse.StatusCode
        if ($proxyResponse.ContentType) { $Context.Response.ContentType = $proxyResponse.ContentType }
        if ($proxyResponse.Headers['X-MusicServer-State-Sqlite-Calls']) {
            $Context.Response.Headers['X-MusicServer-State-Sqlite-Calls'] = $proxyResponse.Headers['X-MusicServer-State-Sqlite-Calls']
        }
        if ($proxyResponse.Headers['Location']) { $Context.Response.RedirectLocation = $proxyResponse.Headers['Location'] }
        if ($proxyResponse.ContentLength -ge 0) { $Context.Response.ContentLength64 = [long]$proxyResponse.ContentLength }
        else { $Context.Response.SendChunked = $true }
        $input = $proxyResponse.GetResponseStream()
        try {
            $buffer = New-Object byte[] 65536
            $outStream = $Context.Response.OutputStream
            while (($read = $input.Read($buffer, 0, $buffer.Length)) -gt 0) {
                # Client (browser) may have gone away mid-response. Async write with
                # a timeout so a dead socket never wedges the single UI thread.
                try {
                    $chunk = New-Object byte[] $read
                    [Array]::Copy($buffer, $chunk, $read)
                    $async = $outStream.BeginWrite($chunk, 0, $read, $null, $null)
                    if (-not $async.AsyncWaitHandle.WaitOne(5000)) {
                        try { $Context.Response.Abort() } catch {}
                        break
                    }
                    $outStream.EndWrite($async)
                } catch {
                    try { $Context.Response.Abort() } catch {}
                    break
                }
            }
        } finally { if ($input) { $input.Dispose() } }
    } finally {
        $proxyResponse.Dispose()
        try { $Context.Response.OutputStream.Close() } catch {}
    }
}

function Get-ClientId {
    param([Parameter(Mandatory)]$Request)
    try {
        $query = [System.Web.HttpUtility]::ParseQueryString($Request.Url.Query)
        return [string]$query['id']
    } catch { return '' }
}

function Register-ClientHeartbeat {
    param([string]$Id)
    if ([string]::IsNullOrWhiteSpace($Id)) { return }
    $script:Clients[$Id] = [DateTime]::UtcNow
    $script:HasSeenClient = $true
    $script:NoClientSince = $null
}

function Remove-Client {
    param([string]$Id)
    if (-not [string]::IsNullOrWhiteSpace($Id)) { [void]$script:Clients.Remove($Id) }
    if ($script:HasSeenClient -and $script:Clients.Count -eq 0 -and -not $script:NoClientSince) {
        $script:NoClientSince = [DateTime]::UtcNow
    }
}

function Remove-StaleClients {
    $now = [DateTime]::UtcNow
    foreach ($id in @($script:Clients.Keys)) {
        $lastSeen = [DateTime]$script:Clients[$id]
        if (($now - $lastSeen).TotalSeconds -ge $ClientTimeoutSeconds) {
            [void]$script:Clients.Remove($id)
        }
    }
    if ($script:HasSeenClient -and $script:Clients.Count -eq 0 -and -not $script:NoClientSince) {
        $script:NoClientSince = $now
    }
}

function Should-AutoStop {
    if ($NoBrowser) { return $false }
    $now = [DateTime]::UtcNow
    if (-not $script:HasSeenClient) { return ($now -ge $script:StartupDeadline) }
    if ($script:Clients.Count -gt 0) { return $false }
    if (-not $script:NoClientSince) { $script:NoClientSince = $now; return $false }
    return (($now - $script:NoClientSince).TotalSeconds -ge $LastClientGraceSeconds)
}

function Handle-Request {
    param([Parameter(Mandatory)]$Context)
    $path = $Context.Request.Url.AbsolutePath
    $script:CurrentRequest = "$($Context.Request.HttpMethod) $path"
    $script:LastActivityAt = [DateTime]::UtcNow

    if ($path -eq '/ui/heartbeat' -and $Context.Request.HttpMethod -eq 'POST') {
        Register-ClientHeartbeat -Id (Get-ClientId -Request $Context.Request)
        $Context.Response.StatusCode = 204
        $Context.Response.Close()
        return
    }
    if ($path -eq '/ui/goodbye' -and $Context.Request.HttpMethod -eq 'POST') {
        Remove-Client -Id (Get-ClientId -Request $Context.Request)
        $Context.Response.StatusCode = 204
        $Context.Response.Close()
        return
    }

    switch ($path) {
        '/'            { Send-IndexHtml -Context $Context; return }
        '/index.html'  { Send-IndexHtml -Context $Context; return }
        '/app.js'      { Send-StaticFile -Context $Context -RelativePath 'app.js' -ContentType 'application/javascript; charset=utf-8'; return }
        '/styles.css'  { Send-StaticFile -Context $Context -RelativePath 'styles.css' -ContentType 'text/css; charset=utf-8'; return }
        '/favicon.ico' { $Context.Response.StatusCode = 204; $Context.Response.Close(); return }
        '/api/library' {
            if ($Context.Request.HttpMethod -eq 'GET') {
                if ($Context.Request.QueryString['refresh'] -eq '1') { $script:UiLibraryCache = $null }
                $items = @(Get-UiLibrary)
                if ($null -eq $script:UiLibraryJsonCache) {
                    $script:UiLibraryJsonCache = ConvertTo-Json -InputObject @{ items = $items; total = $items.Count } -Depth 20 -Compress
                }
                Send-JsonRaw -Context $Context -Json $script:UiLibraryJsonCache
                return
            }
        }
    }

    if ($Context.Request.HttpMethod -eq 'DELETE' -and $path -match '^/api/library/([^/]+)$') {
        # Deleting a library track: proxy to the API, then invalidate the local
        # library caches so the next /api/library request reflects the deletion.
        Proxy-ApiRequest -Context $Context
        $script:UiLibraryCache = $null
        $script:UiLibraryCacheAt = [DateTime]::MinValue
        $script:LibraryFiles = @{}
        return
    }
    if ($Context.Request.HttpMethod -eq 'GET' -and $path -match '^/api/library/([^/]+)/stream$') {
        $id = [System.Web.HttpUtility]::UrlDecode($Matches[1], [System.Text.Encoding]::UTF8)
        Send-LibraryStream -Context $Context -Id $id
        return
    }
    if ($Context.Request.HttpMethod -eq 'GET' -and $path -match '^/api/library/([^/]+)/lyrics$') {
        $id = [System.Web.HttpUtility]::UrlDecode($Matches[1], [System.Text.Encoding]::UTF8)
        Send-LibraryLyrics -Context $Context -Id $id
        return
    }
    if ($Context.Request.HttpMethod -eq 'GET' -and $path -match '^/api/tracks/([^/]+)/lyrics$') {
        $trackId = [System.Web.HttpUtility]::UrlDecode($Matches[1], [System.Text.Encoding]::UTF8)
        Send-TrackLyrics -Context $Context -TrackId $trackId
        return
    }
    if ($path -eq '/health' -or $path.StartsWith('/api/')) {
        Proxy-ApiRequest -Context $Context
        return
    }

    $Context.Response.StatusCode = 404
    $Context.Response.Close()
}

# Slow read-only media requests get four isolated runspaces, with no waiting
# queue. Lifecycle/control requests remain on the owner loop. Each runspace has
# its own derived library cache; only the individual HttpListenerContext crosses
# the boundary, never the main loop's mutable script context or client registry.
function Initialize-MediaPool {
    $initial = [Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $initial.ImportPSModule(@((Join-Path $Root 'MusicServer.Core.psm1')))
    # Get-UiLibrary is only used here to fill this runspace's file map, so the
    # artist overlay it applies needs neither the state DB nor the providers; its
    # lookups fail soft in this runspace and the map is unaffected.
    foreach ($name in @('Write-UiLog','Invoke-NavidromeSqliteJson','Get-LocalLibraryId','Get-LrcPath','Get-LyricQuality','Get-NeteaseIdForTrack','Get-NetEaseLyricsById','Get-UiLibrary','Resolve-UiLibraryFile','Send-ResponseBytes','Send-Json','ConvertTo-JsonStringValue','Send-LyricsJson','Send-JsonRaw','Send-LibraryStream','Send-LibraryLyrics','Send-TrackLyrics')) {
        $definition = (Get-Command $name -CommandType Function).Definition
        $initial.Commands.Add([Management.Automation.Runspaces.SessionStateFunctionEntry]::new($name, $definition))
    }
    foreach ($name in @('Root','Config','ApiPrefix','UiLog','LyricsReportPath')) {
        $initial.Variables.Add([Management.Automation.Runspaces.SessionStateVariableEntry]::new($name, (Get-Variable $name -ValueOnly), 'Read-only request configuration'))
    }
    $script:MediaJobs = [Collections.ArrayList]::new()
    $script:MediaPool = [RunspaceFactory]::CreateRunspacePool(1, 4, $initial, $Host)
    $script:MediaPool.Open()
}

function Complete-MediaJobs {
    foreach ($job in @($script:MediaJobs.ToArray())) {
        if ($job.Async.IsCompleted) {
            try { $job.PowerShell.EndInvoke($job.Async) | Out-Null } catch {}
            foreach ($errorRecord in $job.PowerShell.Streams.Error) { Write-UiLog "Media request failed: $errorRecord" }
            try { $job.Context.Response.Close() } catch {}
            $job.PowerShell.Dispose()
            [void]$script:MediaJobs.Remove($job)
        } elseif ($job.TimeoutSeconds -gt 0 -and -not $job.Stopping -and ([DateTime]::UtcNow - $job.Started).TotalSeconds -gt $job.TimeoutSeconds) {
            try { $job.Context.Response.Abort() } catch {}
            $job.Stopping = $true
            [void]$job.PowerShell.BeginStop($null, $null)
        }
    }
}

# A real singer means up to three online lookups per file, so resolution runs in
# its own single runspace and never on the request path. Every outcome is cached
# in state: a fresh install fills its whole library on the first start, and later
# starts only look at files that are not resolved yet.
function Initialize-ArtistBackfillPool {
    $initial = [Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $initial.ImportPSModule(@(
        (Join-Path $Root 'MusicServer.Core.psm1'),
        (Join-Path $Root 'MusicServer.Database.psm1'),
        (Join-Path $Root 'MusicServer.State.psm1'),
        (Join-Path $Root 'MusicServer.Providers.psm1')
    ))
    foreach ($name in @('Write-UiLog','Get-UiLibrary','Get-LibraryFolderArtist','Invoke-NavidromeSqliteJson','Get-LocalLibraryId','Get-LrcPath')) {
        $definition = (Get-Command $name -CommandType Function).Definition
        $initial.Commands.Add([Management.Automation.Runspaces.SessionStateFunctionEntry]::new($name, $definition))
    }
    foreach ($name in @('Root','Config','UiLog')) {
        $initial.Variables.Add([Management.Automation.Runspaces.SessionStateVariableEntry]::new($name, (Get-Variable $name -ValueOnly), 'Artist backfill configuration'))
    }
    $script:ArtistPool = [RunspaceFactory]::CreateRunspacePool(1, 1, $initial, $Host)
    $script:ArtistPool.Open()
}

function Start-ArtistBackfill {
    if ($env:MUSICSERVER_DISABLE_ARTIST_BACKFILL -eq '1') { return }
    # Bounded so a huge library cannot sit on the network for hours; the rest is
    # picked up on the next start, since every outcome is persisted.
    $limit = 400
    if ($env:MUSICSERVER_ARTIST_BACKFILL_LIMIT) {
        $parsed = 0
        if ([int]::TryParse([string]$env:MUSICSERVER_ARTIST_BACKFILL_LIMIT, [ref]$parsed)) { $limit = $parsed }
    }
    if ($limit -le 0) { return }
    $dbPath = Join-Path $Config.StateDir 'musicserver.db'
    if (-not (Test-Path -LiteralPath $dbPath -PathType Leaf)) { return }
    # A slow or hostile network must not keep a pass alive indefinitely; whatever
    # is left is retried on the next start because every outcome is persisted.
    $budgetMinutes = 20
    if ($env:MUSICSERVER_ARTIST_BACKFILL_MINUTES) {
        $parsedBudget = 0
        if ([int]::TryParse([string]$env:MUSICSERVER_ARTIST_BACKFILL_MINUTES, [ref]$parsedBudget)) { $budgetMinutes = $parsedBudget }
    }
    $ps = [PowerShell]::Create()
    $ps.RunspacePool = $script:ArtistPool
    [void]$ps.AddScript({
        param($limit, $dbPath, $sqliteExe, $budgetMinutes)
        $ErrorActionPreference = 'Continue'
        $ProgressPreference = 'SilentlyContinue'
        $resolved = 0; $missed = 0; $failed = 0
        $deadline = [DateTime]::UtcNow.AddMinutes($budgetMinutes)
        try {
            Connect-MusicServerDatabase -DbPath $dbPath -SqliteExe $sqliteExe
            Initialize-LocalTrackArtistSchema
            $script:UiLibraryCache = $null
            $script:UiLibraryCacheAt = [DateTime]::MinValue
            $script:LibraryFiles = @{}
            $cached = Get-LocalTrackArtistMapDb
            $pending = New-Object System.Collections.ArrayList
            $cutoff = [DateTime]::UtcNow.AddDays(-30)
            foreach ($item in @(Get-UiLibrary)) {
                $file = [string]$item.file
                if (-not $file) { continue }
                $key = Get-MusicServerPathKey -Path $file
                if (-not $key) { continue }
                if ($cached.ContainsKey($key)) {
                    $row = $cached[$key]
                    # A resolved row stays; a miss is retried only after a while,
                    # so new releases get a chance without re-querying every start.
                    if ([string]$row.status -eq 'RESOLVED' -and [string]$row.artist) { continue }
                    $checked = Convert-ToUtcDateTime ([string]$row.updated_at)
                    if ($checked -and $checked -gt $cutoff) { continue }
                }
                [void]$pending.Add($item)
                if ($pending.Count -ge $limit) { break }
            }
            if ($pending.Count -eq 0) { return }
            Write-UiLog "ARTIST backfill started: $($pending.Count) file(s) pending"
            # Channel branding is a prefix shared by many titles, so it can only be
            # recognised from the whole set rather than one title at a time.
            $prefixes = @()
            try { $prefixes = @(Get-SharedTitlePrefixes -Titles @($pending | ForEach-Object { [string]$_.title })) } catch { $prefixes = @() }
            foreach ($item in $pending) {
                if ([DateTime]::UtcNow -gt $deadline) {
                    Write-UiLog "ARTIST backfill stopped at its time budget with $($pending.Count) file(s) left"
                    break
                }
                $key = Get-MusicServerPathKey -Path ([string]$item.file)
                try {
                    $match = Resolve-NeteaseTrackArtist -Config $Config -Title ([string]$item.title) -DurationSeconds ([int]$item.duration)
                    if ($match -and $match.artist) {
                        Save-LocalTrackArtistDb -PathKey $key -Artist ([string]$match.artist) -Album ([string]$match.album) -Status 'RESOLVED' -Source 'netease' | Out-Null
                        $resolved += 1
                    } else {
                        # No online match: keep the uploader's own labelling when the
                        # file name declares one, and remember the miss either way.
                        $declared = Get-TitleDeclaredArtist -Title ([string]$item.title) -KnownPrefixes $prefixes
                        if ($declared) {
                            Save-LocalTrackArtistDb -PathKey $key -Artist $declared -Status 'RESOLVED' -Source 'title' | Out-Null
                            $resolved += 1
                        } else {
                            Save-LocalTrackArtistDb -PathKey $key -Status 'NOT_FOUND' -Source 'none' | Out-Null
                            $missed += 1
                        }
                    }
                } catch {
                    $failed += 1
                }
                Start-Sleep -Milliseconds 350
            }
            Write-UiLog "ARTIST backfill finished: resolved=$resolved notFound=$missed failed=$failed"
        } catch {
            Write-UiLog "ARTIST backfill failed: $($_.Exception.Message)"
        } finally {
            if ($script:UiLibraryCache) { $script:UiLibraryCache = $null }
        }
    }).AddArgument($limit).AddArgument($dbPath).AddArgument([string]$Config.Sqlite).AddArgument($budgetMinutes)
    $async = $ps.BeginInvoke()
    $script:ArtistJob = [pscustomobject]@{ PowerShell = $ps; Async = $async; Started = [DateTime]::UtcNow }
    Write-UiLog "ARTIST backfill queued (limit=$limit)"
}

function Complete-ArtistBackfill {
    if (-not $script:ArtistJob) { return }
    if (-not $script:ArtistJob.Async.IsCompleted) { return }
    try { $script:ArtistJob.PowerShell.EndInvoke($script:ArtistJob.Async) | Out-Null } catch {}
    foreach ($errorRecord in $script:ArtistJob.PowerShell.Streams.Error) { Write-UiLog "ARTIST backfill error: $errorRecord" }
    $script:ArtistJob.PowerShell.Dispose()
    $script:ArtistJob = $null
    # The list was assembled before the new artists landed.
    $script:UiLibraryCache = $null
    $script:UiLibraryCacheAt = [DateTime]::MinValue
    $script:UiLibraryJsonCache = $null
}

function Start-MediaRequest {
    param($Context)
    if ($Context.Request.HttpMethod -ne 'GET' -or $Context.Request.Url.AbsolutePath -notmatch '^/api/(library|tracks)/([^/]+)/(stream|lyrics)$') { return $false }
    $kind = $Matches[1]; $id = [Uri]::UnescapeDataString($Matches[2]); $action = $Matches[3]
    if ($kind -eq 'tracks' -and $action -eq 'stream') { return $false }
    # Reserve one slot for playback so rapid lyric changes cannot occupy every
    # media channel while their upstream responses finish or time out.
    $lyricsJobs = @($script:MediaJobs | Where-Object { $_.Action -eq 'lyrics' }).Count
    if ($script:MediaJobs.Count -ge 4 -or ($action -eq 'lyrics' -and $lyricsJobs -ge 3)) {
        $Context.Response.StatusCode = 503
        $Context.Response.Headers['Retry-After'] = '1'
        $Context.Response.Close()
        return $true
    }
    $ps = [PowerShell]::Create()
    $ps.RunspacePool = $script:MediaPool
    [void]$ps.AddScript({
        param($requestContext, $kind, $id, $action, $libraryFiles)
        $ErrorActionPreference = 'Stop'
        $ProgressPreference = 'SilentlyContinue'
        # The owner supplies a copy; lookups still check file existence. No
        # pooled runspace retains or mutates the owner's map between requests.
        $script:LibraryFiles = $libraryFiles
        $script:UiLibraryCache = $null
        $script:UiLibraryCacheAt = [DateTime]::MinValue
        try {
            if ($kind -eq 'tracks') { Send-TrackLyrics -Context $requestContext -TrackId $id }
            elseif ($action -eq 'stream') { Send-LibraryStream -Context $requestContext -Id $id }
            else { Send-LibraryLyrics -Context $requestContext -Id $id }
        } catch {
            Write-UiLog "Media handler failed: $($_.Exception.Message)"
            try { $requestContext.Response.StatusCode = 502; $requestContext.Response.Close() } catch {}
        }
    }).AddArgument($Context).AddArgument($kind).AddArgument($id).AddArgument($action).AddArgument($script:LibraryFiles.Clone())
    $async = $ps.BeginInvoke()
    # Audio transfers may legitimately exceed 35 seconds; their individual
    # writes retain the existing five-second stall deadline.
    $deadlineSeconds = if ($action -eq 'lyrics') { 35 } else { 0 }
    [void]$script:MediaJobs.Add([pscustomobject]@{ PowerShell = $ps; Async = $async; Context = $Context; Started = [DateTime]::UtcNow; Stopping = $false; TimeoutSeconds = $deadlineSeconds; Action = $action })
    return $true
}

if (-not (Test-Path -LiteralPath (Join-Path $WebRoot 'index.html') -PathType Leaf)) {
    throw "Web UI not found under $WebRoot"
}

if (Test-UiReady) {
    Write-UiLog "UI already running at $UiPrefix; opening existing instance"
    # Ensure the wanted worker is running even when an older UI instance (started
    # before the worker was added to this launcher) already holds the UI port.
    Start-MusicServerWorker
    Initialize-MusicServerScheduledTasks
    if (-not $NoBrowser) { try { Start-Process $UiPrefix | Out-Null } catch {} }
    return
}

try {
    $startupPhases['ui_port_probe'] = $startupClock.Elapsed.TotalMilliseconds
    Start-MusicServerApi
    $startupPhases['api_start_wait'] = $startupClock.Elapsed.TotalMilliseconds
    Start-MusicServerWorker
    $startupPhases['worker_start'] = $startupClock.Elapsed.TotalMilliseconds
    Initialize-MusicServerScheduledTasks
    $startupPhases['scheduled_tasks'] = $startupClock.Elapsed.TotalMilliseconds

    $script:Listener = [System.Net.HttpListener]::new()
    $script:Listener.Prefixes.Add($UiPrefix)
    try {
        $script:Listener.Start()
    } catch {
        # Race: another launcher grabbed the prefix between the port probe and
        # Start(). Not an error for the user - the other instance serves the UI.
        Write-UiLog "UI prefix already taken by another instance; opening existing UI."
        if (-not $NoBrowser) { try { Start-Process $UiPrefix | Out-Null } catch {} }
        return
    }
    Write-UiLog "UI started at $UiPrefix pid=$PID"
    Initialize-MediaPool
    $startupPhases['listener_media_pool'] = $startupClock.Elapsed.TotalMilliseconds
    Initialize-ArtistBackfillPool
    Start-ArtistBackfill
    $startupPhases['artist_backfill'] = $startupClock.Elapsed.TotalMilliseconds

    # External watchdog: watches the heartbeat file this loop writes and
    # restarts the UI if a wedged handler freezes the single-threaded listener.
    try {
        $watchdog = Join-Path $Root 'watchdog_ui.ps1'
        if (Test-Path -LiteralPath $watchdog -PathType Leaf) {
            $wdArgs = @('-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File', ('"' + $watchdog + '"'), '-HeartbeatFile', ('"' + $UiHeartbeatFile + '"'), '-WatchPid', ([string]$PID), '-RestartScript', ('"' + $PSCommandPath + '"'), '-WorkingDir', ('"' + $Root + '"'), '-LogFile', ('"' + $WatchdogLog + '"'))
            Start-Process -FilePath 'powershell.exe' -ArgumentList $wdArgs -WindowStyle Hidden | Out-Null
            Write-UiLog "Watchdog started (heartbeat=$UiHeartbeatFile pid=$PID)"
        }
    } catch {
        Write-UiLog "Watchdog start failed: $($_.Exception.Message)"
    }

    if (-not $NoBrowser) {
        try { Start-Process $UiPrefix | Out-Null } catch { Write-UiLog "Could not open browser: $($_.Exception.Message)" }
    }

    $startupPhases['watchdog_start'] = $startupClock.Elapsed.TotalMilliseconds
    Write-MusicServerStartupTrace -Role ui -Checkpoints $startupPhases
    $pending = $script:Listener.BeginGetContext($null, $null)
    while ($script:Listener.IsListening) {
        Complete-MediaJobs
        Complete-ArtistBackfill
        if ($pending.AsyncWaitHandle.WaitOne(100)) {
            $context = $script:Listener.EndGetContext($pending)
            if ($script:Listener.IsListening) { $pending = $script:Listener.BeginGetContext($null, $null) }
            try {
                $reqStart = [DateTime]::UtcNow
                if (-not (Start-MediaRequest -Context $context)) { Handle-Request -Context $context }
                $reqMs = [int]([DateTime]::UtcNow - $reqStart).TotalMilliseconds
                if ($reqMs -gt 2000) { Write-UiLog "SLOW $($context.Request.Url.AbsolutePath) took ${reqMs}ms" }
            } catch {
                Write-UiLog "UI request failed: $($_.Exception.Message)"
                try {
                    if ($context.Response.OutputStream.CanWrite) {
                        $context.Response.StatusCode = 502
                        $context.Response.Close()
                    }
                } catch {}
            }
            $script:LastActivityAt = [DateTime]::UtcNow
            $script:CurrentRequest = ''
        }

        Remove-StaleClients
        # Reap I/O promptly without rewriting the watchdog file ten times/sec.
        if ([DateTime]::UtcNow -ge $script:NextHeartbeatAt) {
            try { [System.IO.File]::WriteAllText($UiHeartbeatFile, [DateTime]::UtcNow.ToString('o')) } catch {}
            $script:NextHeartbeatAt = [DateTime]::UtcNow.AddSeconds(1)
        }
        if (Should-AutoStop) {
            Write-UiLog 'No active browser clients remain; stopping UI and owned API process.'
            break
        }
    }
} catch {
    Write-UiLog "Launcher failed: $($_.Exception.Message)"
    throw
} finally {
    foreach ($job in @($script:MediaJobs)) {
        if (-not $job) { continue }
        try { $job.Context.Response.Abort() } catch {}
        try { $job.PowerShell.Stop(); $job.PowerShell.Dispose() } catch {}
    }
    if ($script:MediaPool) { $script:MediaPool.Close(); $script:MediaPool.Dispose() }
    if ($script:Listener) {
        try { if ($script:Listener.IsListening) { $script:Listener.Stop() } } catch {}
        try { $script:Listener.Close() } catch {}
    }
    if ($StartedApi -and $ApiProcess -and -not $ApiProcess.HasExited) {
        try {
            Stop-Process -Id $ApiProcess.Id -Force -ErrorAction SilentlyContinue
            Write-UiLog "Stopped owned API pid=$($ApiProcess.Id)"
        } catch {}
    }
    if ($StartedWorker -and $WorkerProcess -and -not $WorkerProcess.HasExited) {
        try {
            Stop-Process -Id $WorkerProcess.Id -Force -ErrorAction SilentlyContinue
            Write-UiLog "Stopped owned worker pid=$($WorkerProcess.Id)"
        } catch {}
    }
    Write-UiLog 'UI launcher stopped.'
}
