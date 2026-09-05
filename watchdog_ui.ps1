<#
.SYNOPSIS
  External watchdog for the MusicServer UI launcher.

.DESCRIPTION
  start_musicserver_ui.ps1 serves every request on a single thread. If a
  handler wedges (slow external HTTP call, proxy hang, unexpected loop), the
  whole UI freezes: no new requests are accepted, playback and health checks
  time out. This watchdog runs as a separate process, watches the heartbeat
  file the UI main loop writes every iteration, and force-restarts the UI
  (plus the API process it owns) when the heartbeat goes stale.

  Started by start_musicserver_ui.ps1 after the UI listener is up. Exits when
  the UI process it watches is gone for good.

.PARAMETER HeartbeatFile
  Path to the heartbeat file written by the UI main loop.
.PARAMETER WatchPid
  PID of the UI launcher process to watch.
.PARAMETER RestartScript
  Full path of start_musicserver_ui.ps1 to relaunch on stall.
.PARAMETER WorkingDir
  Working directory for the relaunched process.
.PARAMETER LogFile
  Where watchdog events are appended.
.PARAMETER TimeoutSeconds
  Stall threshold; default 60s.
.PARAMETER PollSeconds
  Check interval; default 5s.
#>
param(
    [Parameter(Mandatory)][string]$HeartbeatFile,
    [Parameter(Mandatory)][int]$WatchPid,
    [Parameter(Mandatory)][string]$RestartScript,
    [Parameter(Mandatory)][string]$WorkingDir,
    [string]$LogFile = '',
    [int]$TimeoutSeconds = 60,
    [int]$PollSeconds = 5
)

$ErrorActionPreference = 'SilentlyContinue'

# Single instance: a restarted UI starts a fresh watchdog; the old one must not
# also keep watching (double restarts). Named mutex guards this.
$WatchdogMutex = [Threading.Mutex]::new($false, 'MusicServer_UiWatchdog')
$OwnsWatchdogMutex = $false
try {
    $OwnsWatchdogMutex = $WatchdogMutex.WaitOne(0)
} catch {}
if (-not $OwnsWatchdogMutex) {
    # Another watchdog is active; nothing to do here.
    exit 0
}

function Write-WatchLog {
    param([string]$Message)
    if (-not $LogFile) { return }
    try {
        $line = '[{0}] {1}' -f ([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss')), $Message
        Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    } catch {}
}

# Give the UI a grace period to start writing heartbeats.
Start-Sleep -Seconds 10

$lastRestartAt = [DateTime]::MinValue
while ($true) {
    Start-Sleep -Seconds $PollSeconds
    $uiAlive = $false
    try {
        $proc = Get-Process -Id $WatchPid -ErrorAction SilentlyContinue
        $uiAlive = ($null -ne $proc)
    } catch {}
    if (-not $uiAlive) {
        Write-WatchLog "UI pid=$WatchPid no longer running; watchdog exiting."
        break
    }

    $lastBeat = [DateTime]::MinValue
    if (Test-Path -LiteralPath $HeartbeatFile) {
        try {
            $text = Get-Content -LiteralPath $HeartbeatFile -Raw -ErrorAction Stop
            $lastBeat = [DateTime]::Parse([string]$text).ToUniversalTime()
        } catch {}
    }

    $staleSeconds = [int]([DateTime]::UtcNow - $lastBeat).TotalSeconds
    if ($staleSeconds -gt $TimeoutSeconds) {
        # Heartbeat too old (or never written after grace). Force restart.
        $restartOk = $true
        if (($script:lastRestartAt) -and (([DateTime]::UtcNow - $lastRestartAt).TotalSeconds -lt 120)) {
            Write-WatchLog "UI stall detected but restarted recently ($staleSeconds s stale); waiting longer to avoid a restart loop."
            $restartOk = $false
        }
        if ($restartOk) {
            Write-WatchLog "UI stall detected: heartbeat $staleSeconds s stale. Killing pid=$WatchPid and restarting UI."
            try { Stop-Process -Id $WatchPid -Force -ErrorAction Stop } catch {}
            # The launcher owns the API process; killing the launcher triggers its
            # finally block which stops the API. Give it a moment, then relaunch.
            Start-Sleep -Seconds 3
            try {
                Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File', ('"' + $RestartScript + '"')) -WorkingDirectory $WorkingDir -WindowStyle Hidden | Out-Null
                Write-WatchLog "UI relaunched from watchdog."
                $script:lastRestartAt = [DateTime]::UtcNow
            } catch {
                Write-WatchLog "Relaunch failed: $($_.Exception.Message)"
            }
            # Wait for the new process to bind before resuming checks.
            Start-Sleep -Seconds 15
            continue
        }
    }
}

if ($OwnsWatchdogMutex) {
    try { $WatchdogMutex.ReleaseMutex() } catch {}
}
$WatchdogMutex.Dispose()
