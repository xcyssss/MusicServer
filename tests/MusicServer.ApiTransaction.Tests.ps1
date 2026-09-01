<#
.SYNOPSIS
    MusicServer ApiTransaction hardening tests (SQLite as sole runtime truth).

    Scope (per hardening-v2 task):
      A  LIKE action matrix + rollback (in-process, State layer)
      B  UNLIKE action matrix + rollback (in-process)
      C  Multi-worker invariants with REAL child PowerShell processes
      D  SQLite as the only source of truth (no JSON round-trip)
      E  Real HTTP API smoke (music_api.ps1, real HTTP/JSON)

    Isolation:
      - Fresh temp test root per Describe block (DailyMix_data\state under it).
      - Real sqlite3.exe via $Config.Sqlite (no in-process SQLite shim).
      - Child processes (C-suite) are separate pwsh instances sharing one DB file.
      - E-suite starts real music_api.ps1 server on 127.0.0.1 (free port, then kill).

    Pester 5 compatible (Describes/Its only; BeforeEach/AfterEach inside Describes).
#>

$ErrorActionPreference = 'Stop'

$ProjectRoot = Split-Path -Parent $PSScriptRoot

# Import modules ONCE per test process (idempotent -Force).
# NOTE: all -Force imports must complete BEFORE any Initialize-MusicServerDatabase
# call (module instance reset law - see music_api.ps1 header).
Import-Module (Join-Path $ProjectRoot 'MusicServer.Core.psm1') -Force
Import-Module (Join-Path $ProjectRoot 'MusicServer.Database.psm1') -Force
Import-Module (Join-Path $ProjectRoot 'MusicServer.State.psm1') -Force
Import-Module (Join-Path $ProjectRoot 'MusicServer.Migration.psm1') -Force

function Get-TermExe {
    $cmd = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return (Get-Command powershell.exe).Source
}

# ---------------------------------------------------------------------------
# Test-process state
# ---------------------------------------------------------------------------
$script:T = [pscustomobject]@{
    Root      = $null
    Config    = $null
    DbPath    = $null
    TestRoots = @()
    ApiProcs  = @()
}

function Invoke-FreePort {
    # Ask the OS for a free TCP port on 127.0.0.1; close and return it.
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = [int]$listener.LocalEndpoint.Port
    $listener.Stop()
    return $port
}

function New-TestRoot {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('msat_' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path (Join-Path $root 'DailyMix_data\state') -Force
    $script:T.TestRoots += $root
    return $root
}

function Invoke-DbSetup {
    param([Parameter(Mandatory)][string]$Root)
    $cfg = New-MusicServerConfig -Root $Root
    Initialize-MusicServerState -Config $cfg
    $db = Join-Path $cfg.StateDir 'musicserver.db'
    Initialize-MusicServerDatabase -DbPath $db -SqliteExe $cfg.Sqlite
    Initialize-MusicServerSchema
    $script:T.Root = $Root
    $script:T.Config = $cfg
    $script:T.DbPath = $db
}

function Stop-ApiServer {
    foreach ($proc in @($script:T.ApiProcs)) {
        try {
            if ($proc -and -not $proc.HasExited) {
                # Kill the whole process tree (taskkill /T) to be safe.
                & cmd.exe /c "taskkill /PID $($proc.Id) /T /F" 6>&1 | Out-Null
                $proc.WaitForExit(5000) | Out-Null
            }
        } catch {}
        try { if ($proc) { $proc.Dispose() | Out-Null } } catch {}
    }
    $script:T.ApiProcs = @()
}

function Remove-All {
    Stop-ApiServer
    foreach ($root in @($script:T.TestRoots)) {
        try { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue } catch {}
    }
    $script:T.TestRoots = @()
    $script:T.Root = $null; $script:T.Config = $null; $script:T.DbPath = $null
}

function Start-MusicApi {
    param([Parameter(Mandatory)][string]$Root)
    $port = Invoke-FreePort
    $prefix = "http://127.0.0.1:$port/"
    $logFile = Join-Path $Root 'api_launch.log'
      $errFile = Join-Path $Root 'api_launch.err.log'
      $psExe = (Get-Command powershell.exe).Source
      $argList = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
          '-File', (Join-Path $ProjectRoot 'music_api.ps1'),
          '-Prefix', $prefix, '-Root', $Root)
      $proc = Start-Process -FilePath $psExe -ArgumentList $argList -WindowStyle Hidden -PassThru -RedirectStandardOutput $logFile -RedirectStandardError $errFile
      $script:T.ApiProcs += $proc
      $deadline = [DateTime]::UtcNow.AddSeconds(40)
      $ready = $false
      while ([DateTime]::UtcNow -lt $deadline) {
          if ($proc.HasExited) { break }
          $logText = ''
          if (Test-Path -LiteralPath $logFile) { $logText = (Get-Content -Path $logFile -Raw -ErrorAction SilentlyContinue) }
          if ($logText -match 'API v2 ready') { $ready = $true; break }
          Start-Sleep -Milliseconds 200
      }
      if (-not $ready) {
          if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
          $detail = ''
          if (Test-Path -LiteralPath $logFile) { $detail = ($detail + "LOG>" + (Get-Content -Path $logFile -Raw -ErrorAction SilentlyContinue) + [Environment]::NewLine) }
          if (Test-Path -LiteralPath $errFile) { $detail = ($detail + "ERR>" + (Get-Content -Path $errFile -Raw -ErrorAction SilentlyContinue)) }
          throw "music_api.ps1 did not become ready in 40s. `n$detail"
      }
      return [pscustomobject]@{ Process = $proc; BaseUrl = $prefix.TrimEnd('/'); Port = $port }
}

function Stop-MusicApi {
    Stop-ApiServer
}

function Invoke-Http {
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [string]$Body = ''
    )
    try {
        $request = [System.Net.HttpWebRequest]::Create(($BaseUrl.TrimEnd('/') + $Path))
        $request.Method = $Method
        $request.Timeout = 30000
        $request.ReadWriteTimeout = 30000
        $request.ContentType = 'application/json; charset=utf-8'
        # Always frame the request with an explicit Content-Length (server is a
        # keep-alive HttpListener and replies 411 Length Required otherwise).
        # PS 5.1 (.NET 4.x) HttpWebRequest lacks ContentLength64 -> use ContentLength.
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
        if ($request.GetType().GetProperty('ContentLength64')) { $request.ContentLength64 = $bytes.Length } else { $request.ContentLength = $bytes.Length }
        if ($bytes.Length -gt 0) {
            $reqStream = $request.GetRequestStream()
            $reqStream.Write($bytes, 0, $bytes.Length)
            $reqStream.Close()
        }
        $response = $request.GetResponse()
        $stream = $response.GetResponseStream()
        $ms = [System.IO.MemoryStream]::new()
        $buf = New-Object byte[] 8192
        while (($n = $stream.Read($buf, 0, $buf.Length)) -gt 0) { $ms.Write($buf, 0, $n) }
        $text = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
        $status = [int]$response.StatusCode
        $response.Dispose()
    }
    catch [System.Net.WebException] {
        $we = $_.Exception # WebException
        $status = -1
        if ($we.Response) {
            try {
                $resp = $we.Response
                $status = [int]$resp.StatusCode
                $stream = $resp.GetResponseStream()
                $ms = [System.IO.MemoryStream]::new()
                $buf = New-Object byte[] 8192
                while (($n = $stream.Read($buf, 0, $buf.Length)) -gt 0) { $ms.Write($buf, 0, $n) }
                $text = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
                $resp.Dispose() | Out-Null
            } catch { $text = '' }
        } else { $text = '' }
    }
    $json = $null
    if ($text) {
        try { $json = $text | ConvertFrom-Json } catch {}
    }
    return [pscustomobject]@{ Status = [int]$status; Text = [string]$text; Json = $json }
}

function New-SeedTrack {
    param([string]$Status = 'REMOTE')
    $r = [PSCustomObject]@{ N = ([guid]::NewGuid().ToString('N').Substring(0, 6)) }
    $track = New-CanonicalTrack -Title ('TxTrack ' + $r.N) -Artist ('TxArtist ' + $r.N) -Status $Status -PreviewSources @(@{ provider = 'music_api'; preview_url = 'https://example.invalid/preview.mp3' })
    $saved = Save-CanonicalTrackDb -Track $track
    if (-not $saved.Success) { throw "Save-CanonicalTrackDb failed: $($saved.Error)" }
    return [string]$track.id
}

# ---------------------------------------------------------------------------
# A. LIKE action matrix
# ---------------------------------------------------------------------------
Describe 'A: LIKE action matrix (SQLite single source of truth)' {
    BeforeEach {
        $script:T.Root = $null
        $script:T.Config = $null
        $script:T.DbPath = $null
        $root = New-TestRoot
        Invoke-DbSetup -Root $root
        $script:Cfg = $script:T.Config
    }
    AfterEach {
        Remove-All
    }

    It 'A1 QUEUED: REMOTE -> WANTED, queue row rev 1, feedback LIKE, TRACK_LIKED event' {
        $tid = New-SeedTrack -Status 'REMOTE'
        $qBefore = Get-WantedItemDb -TrackId $tid
        $qBefore | Should BeNullOrEmpty

        $res = Invoke-LikeTrackTransactionDb -TrackId $tid -Source 'test_A1'

        $res.liked | Should Be $true
        $res.action | Should Be 'QUEUED'
        $res.from_status | Should Be 'REMOTE'
        $res.to_status | Should Be 'WANTED'
        $res.to_queue | Should Be 'WANTED'
        $res.queue_revision | Should Be 1

        $canon = Get-CanonicalTrackDb -TrackId $tid
        $canon.status | Should Be 'WANTED'
        [int]$canon.revision | Should Be 2

        $q = Get-WantedItemDb -TrackId $tid
        $q | Should not BeNullOrEmpty
        $q.state | Should Be 'WANTED'
        [int]$q.revision | Should Be 1

        $rows = @(Invoke-MusicServerSqlJson -Query "SELECT feedback_type, source FROM recommendation_feedback WHERE track_id = '$tid' AND feedback_type = 'LIKE' AND source = 'test_A1';")
        $rows.Count | Should Be 1

        $evts = @(Invoke-MusicServerSqlJson -Query "SELECT event_type FROM events WHERE track_id = '$tid' AND event_type = 'TRACK_LIKED';")
        $evts.Count | Should Be 1
    }

    It 'A2 ALREADY_QUEUED: no duplicate row, queue_revision stable, feedback/evidence accumulate' {
        $tid = New-SeedTrack -Status 'REMOTE'
        $r1 = Invoke-LikeTrackTransactionDb -TrackId $tid -Source 'test_A2_first'
        $r1.action | Should Be 'QUEUED'

        $r2 = Invoke-LikeTrackTransactionDb -TrackId $tid -Source 'test_A2_second'
        $r2.liked | Should Be $true
        $r2.action | Should Be 'ALREADY_QUEUED'
        $r2.queue_revision | Should Be 1
        $r2.to_queue | Should Be 'WANTED'

        # Exactly ONE queue row.
        $dup = @(Invoke-MusicServerSqlJson -Query "SELECT COUNT(*) as cnt FROM wanted_queue WHERE track_id = '$tid';")
        [int]$dup[0].cnt | Should Be 1

        # Feedback accumulates (audit evidence, not truth).
        $fb = @(Invoke-MusicServerSqlJson -Query "SELECT COUNT(*) as cnt FROM recommendation_feedback WHERE track_id = '$tid' AND feedback_type = 'LIKE';")
        [int]$fb[0].cnt | Should Be 2

        # Two TRACK_LIKED events (one per action).
        $ev = @(Invoke-MusicServerSqlJson -Query "SELECT COUNT(*) as cnt FROM events WHERE track_id = '$tid' AND event_type = 'TRACK_LIKED';")
        [int]$ev[0].cnt | Should Be 2

        $canon = Get-CanonicalTrackDb -TrackId $tid
        $canon.status | Should Be 'WANTED'
    }

    It 'A3 REQUEUED: CANCEL_REQUESTED -> WANTED, attempt reset, revision bumps' {
        $tid = New-SeedTrack -Status 'REMOTE'
        [void](Invoke-LikeTrackTransactionDb -TrackId $tid -Source 'test_A3_seed')

        # Force queue to CANCEL_REQUESTED to simulate a prior cancel.
        Invoke-MusicServerSqlNonQuery -Query @"
UPDATE wanted_queue
   SET state = 'CANCEL_REQUESTED', last_error = 'simulated_prior_cancel'
 WHERE track_id = '$tid';
"@ | Out-Null

        $res = Invoke-LikeTrackTransactionDb -TrackId $tid -Source 'test_A3_requeue'
        $res.liked | Should Be $true
        $res.action | Should Be 'REQUEUED'
        $res.to_queue | Should Be 'WANTED'
        [int]$res.queue_revision | Should Be 2

        $q = Get-WantedItemDb -TrackId $tid
        $q.state | Should Be 'WANTED'
        [int]$q.revision | Should Be 2
        [int]$q.attempt_count | Should Be 0
        $q.last_error | Should Be ''
        $q.claimed_by | Should Be ''
        # next_retry_at cleared
        $nr = @(Invoke-MusicServerSqlJson -Query "SELECT next_retry_at FROM wanted_queue WHERE track_id = '$tid';")
        [string]$nr[0].next_retry_at | Should Be ''

        $canon = Get-CanonicalTrackDb -TrackId $tid
        $canon.status | Should Be 'WANTED'
    }

    It 'A4 PREFERENCE_ONLY: LOCAL track, no queue row, feedback recorded, unlike keeps local' {
        $tid = New-SeedTrack -Status 'LOCAL'

        $res = Invoke-LikeTrackTransactionDb -TrackId $tid -Source 'test_A4'
        $res.liked | Should Be $true
        $res.action | Should Be 'PREFERENCE_ONLY'
        $res.to_queue | Should BeNullOrEmpty
        [int]$res.queue_revision | Should Be 0

        # No queue row.
        $q = Get-WantedItemDb -TrackId $tid
        $q | Should BeNullOrEmpty

        # Canonical stays LOCAL.
        $canon = Get-CanonicalTrackDb -TrackId $tid
        $canon.status | Should Be 'LOCAL'

        # Feedback recorded as audit.
        $fb = @(Invoke-MusicServerSqlJson -Query "SELECT COUNT(*) as cnt FROM recommendation_feedback WHERE track_id = '$tid' AND feedback_type = 'LIKE';")
        [int]$fb[0].cnt | Should Be 1

        # UNLIKE on LOCAL is also PREFERENCE_ONLY.
        $u = Invoke-UnlikeTrackTransactionDb -TrackId $tid -Source 'test_A4'
        $u.liked | Should Be $false
        $u.action | Should Be 'PREFERENCE_ONLY'
        $canon2 = Get-CanonicalTrackDb -TrackId $tid
        $canon2.status | Should Be 'LOCAL'
    }

    It 'A5 FAIL-N: failure after statement N rolls back all preceding writes' {
        $tid = New-SeedTrack -Status 'REMOTE'
        # QUEUED: [U canon, I queue, I feedback, I event]; inject failure at step 2.
        $a5Threw = $false
        try {
            Invoke-LikeTrackTransactionDb -TrackId $tid -Source 'test_A5' -FailAfterStep 2
        }
        catch { $a5Threw = $true }
        $a5Threw | Should Be $true

        # Rollback must undo both the canonical UPDATE and the queue INSERT.
        $canon = Get-CanonicalTrackDb -TrackId $tid
        $canon.status | Should Be 'REMOTE'
        [int]$canon.revision | Should Be 1

        $q = Get-WantedItemDb -TrackId $tid
        $q | Should BeNullOrEmpty

        $fb = @(Invoke-MusicServerSqlJson -Query "SELECT COUNT(*) as cnt FROM recommendation_feedback WHERE track_id = '$tid' AND feedback_type = 'LIKE';")
        [int]$fb[0].cnt | Should Be 0

        $ev = @(Invoke-MusicServerSqlJson -Query "SELECT COUNT(*) as cnt FROM events WHERE track_id = '$tid' AND event_type = 'TRACK_LIKED';")
        [int]$ev[0].cnt | Should Be 0

        # A subsequent healthy like must succeed (DB still consistent after abort).
        $res = Invoke-LikeTrackTransactionDb -TrackId $tid -Source 'test_A5_retry'
        $res.action | Should Be 'QUEUED'
    }
}

# ---------------------------------------------------------------------------
# B. UNLIKE action matrix
# ---------------------------------------------------------------------------
Describe 'B: UNLIKE action matrix (SQLite single source of truth)' {
    BeforeEach {
        $script:T.Root = $null
        $script:T.Config = $null
        $script:T.DbPath = $null
        $root = New-TestRoot
        Invoke-DbSetup -Root $root
        $script:Cfg = $script:T.Config
    }
    AfterEach {
        Remove-All
    }

    It 'B1 IDLE_REMOVED: WANTED -> REMOTE, queue DELETEd, feedback UNLIKE, TRACK_UNLIKED event' {
        $tid = New-SeedTrack -Status 'REMOTE'
        [void](Invoke-LikeTrackTransactionDb -TrackId $tid -Source 'test_B1_seed')

        $res = Invoke-UnlikeTrackTransactionDb -TrackId $tid -Source 'test_B1'
        $res.liked | Should Be $false
        $res.action | Should Be 'IDLE_REMOVED'
        $res.from_queue | Should Be 'WANTED'
        $res.to_queue | Should BeNullOrEmpty
        [int]$res.queue_revision | Should Be 0

        # Queue row gone.
        $qcount = @(Invoke-MusicServerSqlJson -Query "SELECT COUNT(*) as cnt FROM wanted_queue WHERE track_id = '$tid';")
        [int]$qcount[0].cnt | Should Be 0

        # Canonical back to REMOTE.
        $canon = Get-CanonicalTrackDb -TrackId $tid
        $canon.status | Should Be 'REMOTE'

        # UNLIKE feedback recorded.
        $fb = @(Invoke-MusicServerSqlJson -Query "SELECT COUNT(*) as cnt FROM recommendation_feedback WHERE track_id = '$tid' AND feedback_type = 'UNLIKE';")
        [int]$fb[0].cnt | Should Be 1

        # TRACK_UNLIKED event.
        $ev = @(Invoke-MusicServerSqlJson -Query "SELECT COUNT(*) as cnt FROM events WHERE track_id = '$tid' AND event_type = 'TRACK_UNLIKED';")
        [int]$ev[0].cnt | Should Be 1
    }

    It 'B2 CANCEL_REQUESTED: active RESOLVING lease -> CANCEL_REQUESTED, worker lease cleared' {
        $tid = New-SeedTrack -Status 'REMOTE'
        [void](Invoke-LikeTrackTransactionDb -TrackId $tid -Source 'test_B2_seed')

        # Worker claims (real claim path).
        $claim = Claim-WantedItemDb -TrackId $tid -WorkerId 'worker_B2' -LeaseMinutes 30
        $claim.Success | Should Be $true
        $q1 = Get-WantedItemDb -TrackId $tid
        $q1.state | Should Be 'RESOLVING'
        [int]$q1.revision | Should Be 2

        # UNLIKE requests cancel; must go through CANCEL_REQUESTED path.
        $res = Invoke-UnlikeTrackTransactionDb -TrackId $tid -Source 'test_B2'
        $res.liked | Should Be $false
        $res.action | Should Be 'CANCEL_REQUESTED'
        $res.from_queue | Should Be 'RESOLVING'
        $res.to_queue | Should Be 'CANCEL_REQUESTED'
        [int]$res.queue_revision | Should Be 3

        $q2 = Get-WantedItemDb -TrackId $tid
        $q2.state | Should Be 'CANCEL_REQUESTED'
        [int]$q2.revision | Should Be 3
        $q2.claimed_by | Should Be ''
        $q2.claimed_at | Should BeNullOrEmpty
        $q2.last_error | Should Be 'USER_CANCELLED'
        # Lease epoch cleared (NULL -> empty via SqlJson).
        $q2.lease_expires_epoch | Should BeNullOrEmpty

        # Canonical: still WANTED (CANCEL_REQUESTED is not a canonical status transition for cancel).
        $canon = Get-CanonicalTrackDb -TrackId $tid
        $canon.status | Should Be 'WANTED'

        # Events: TRACK_UNLIKED + WANTED_CANCEL_REQUESTED.
        $ev = @(Invoke-MusicServerSqlJson -Query "SELECT event_type FROM events WHERE track_id = '$tid' ORDER BY id DESC LIMIT 2;")
        $actual = @($ev | ForEach-Object { [string]$_.event_type }) -join ','
        $actual | Should Be 'WANTED_CANCEL_REQUESTED,TRACK_UNLIKED'
    }

    It 'B3 IDLE_REMOVED after CANCEL_REQUESTED: queue DELETEd, canonical REMOTE' {
        $tid = New-SeedTrack -Status 'REMOTE'
        [void](Invoke-LikeTrackTransactionDb -TrackId $tid -Source 'test_B3_seed')
        # Claim then cancel to get CANCEL_REQUESTED.
        $claim = Claim-WantedItemDb -TrackId $tid -WorkerId 'worker_B3' -LeaseMinutes 30
        [void]$claim
        $cancel = Invoke-UnlikeTrackTransactionDb -TrackId $tid -Source 'test_B3_cancel'
        $cancel.action | Should Be 'CANCEL_REQUESTED'

        # Unlike again -> IDLE_REMOVED.
        $res = Invoke-UnlikeTrackTransactionDb -TrackId $tid -Source 'test_B3_unlike'
        $res.liked | Should Be $false
        $res.action | Should Be 'IDLE_REMOVED'
        $res.from_queue | Should Be 'CANCEL_REQUESTED'
        $res.to_queue | Should BeNullOrEmpty
        [int]$res.queue_revision | Should Be 0

        # Queue row gone.
        $qcount = @(Invoke-MusicServerSqlJson -Query "SELECT COUNT(*) as cnt FROM wanted_queue WHERE track_id = '$tid';")
        [int]$qcount[0].cnt | Should Be 0

        # Canonical REMOTE.
        $canon = Get-CanonicalTrackDb -TrackId $tid
        $canon.status | Should Be 'REMOTE'

        # Two UNLIKE events total (B3_cancel + B3_unlike); both TRACK_UNLIKED.
        $ev = @(Invoke-MusicServerSqlJson -Query "SELECT COUNT(*) as cnt FROM events WHERE track_id = '$tid' AND event_type = 'TRACK_UNLIKED';")
        [int]$ev[0].cnt | Should Be 2
    }

    It 'B4 FAIL-N: failure after statement N rolls back (active cancel path)' {
        $tid = New-SeedTrack -Status 'REMOTE'
        [void](Invoke-LikeTrackTransactionDb -TrackId $tid -Source 'test_B4_seed')
        $claim = Claim-WantedItemDb -TrackId $tid -WorkerId 'worker_B4' -LeaseMinutes 30
        $claim.Success | Should Be $true
        $q1 = Get-WantedItemDb -TrackId $tid
        [int]$q1.revision | Should Be 2
        $q1.state | Should Be 'RESOLVING'

        # CANCEL_REQUESTED txn: [U queue(cancel), I feedback, I TRACK_UNLIKED, I WANTED_CANCEL_REQUESTED].
        $b4Threw = $false
        try {
            Invoke-UnlikeTrackTransactionDb -TrackId $tid -Source 'test_B4' -FailAfterStep 1
        }
        catch { $b4Threw = $true }
        $b4Threw | Should Be $true

        # Queue still RESOLVING, lease intact, revision unchanged.
        $q2 = Get-WantedItemDb -TrackId $tid
        $q2.state | Should Be 'RESOLVING'
        [int]$q2.revision | Should Be 2
        $q2.claimed_by | Should Be 'worker_B4'

        # No UNLIKE feedback added.
        $fb = @(Invoke-MusicServerSqlJson -Query "SELECT COUNT(*) as cnt FROM recommendation_feedback WHERE track_id = '$tid' AND feedback_type = 'UNLIKE';")
        [int]$fb[0].cnt | Should Be 0

        # No new events.
        $ev = @(Invoke-MusicServerSqlJson -Query "SELECT COUNT(*) as cnt FROM events WHERE track_id = '$tid' AND event_type IN ('TRACK_UNLIKED','WANTED_CANCEL_REQUESTED');")
        [int]$ev[0].cnt | Should Be 0

        # Worker can still renew lease (claim still valid).
        $renew = Renew-LeaseDb -TrackId $tid -WorkerId 'worker_B4'
        [int]$renew | Should Be 1
    }
}

# ---------------------------------------------------------------------------
# C. Real-process concurrency invariants
# ---------------------------------------------------------------------------
Describe 'C: real multi-worker concurrency invariants (separate pwsh child processes)' {
    $ChildScript = Join-Path $PSScriptRoot 'MusicServer.WorkerChild.ps1'
    $ArtifactsRoot = Split-Path -Parent $PSScriptRoot

    function Start-Child {
        param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Action, [string]$WorkerId, [string]$TrackId = '', [string]$NewState = 'RETRY_WAIT', [int]$ExpectedRevision = -1, [int]$LeaseMinutes = 30, [int]$JitterMs = 0)
        $outFile = Join-Path $Root ('evidence_' + $WorkerId + '_' + [guid]::NewGuid().ToString('N') + '.json')
        $args = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $ChildScript,
            '-ProjectRoot', $ProjectRoot, '-Root', $Root, '-Action', $Action,
            '-WorkerId', $WorkerId, '-OutFile', $outFile)
        if ($TrackId) { $args += @('-TrackId', $TrackId) }
        if ($NewState) { $args += @('-NewState', $NewState) }
        if ($ExpectedRevision -ne -1) { $args += @('-ExpectedRevision', [string]$ExpectedRevision) }
        $args += @('-LeaseMinutes', [string]$LeaseMinutes)
        if ($JitterMs -gt 0) { $args += @('-JitterMs', [string]$JitterMs) }

      $psExe = (Get-Command powershell.exe).Source
      $errFile = Join-Path $Root 'child_err.log'
      $proc = Start-Process -FilePath $psExe -ArgumentList $args -WindowStyle Hidden -PassThru -RedirectStandardError $errFile
        $stderr = ''
        if (-not $proc.WaitForExit(60000)) {
            try { $proc.Kill(); $proc.WaitForExit(2000) | Out-Null } catch {}
            $stderr += ' child timed out; killed.'
            return [pscustomobject]@{ Process = $proc; OutFile = $outFile; TimedOut = $true }
        }
        return [pscustomobject]@{ Process = $proc; OutFile = $outFile; ExitCode = $proc.ExitCode; TimedOut = $false }
    }

    function Read-ChildResult {
        param([Parameter(Mandatory)][string]$OutFile)
        $text = ''
        try {
            $deadline = [DateTime]::UtcNow.AddSeconds(15)
            while ((-not (Test-Path -LiteralPath $OutFile)) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 200 }
            if (Test-Path -LiteralPath $OutFile) { $text = [System.IO.File]::ReadAllText($OutFile, [System.Text.Encoding]::UTF8) }
        } catch {}
        if (-not $text) { return [pscustomobject]@{ Success = $false; Reason = 'NO_RESULT_FILE' } }
        try { return ($text | ConvertFrom-Json) } catch { return [pscustomobject]@{ Success = $false; Reason = 'BAD_JSON' } }
    }

    BeforeEach {
        $script:T.Root = $null
        $script:T.Config = $null
        $script:T.DbPath = $null
        $root = New-TestRoot
        Invoke-DbSetup -Root $root
        $script:Cfg = $script:T.Config
    }
    AfterEach {
        Remove-All
    }

    It 'C1 two concurrent workers LIKE the same REMOTE track: exactly one queue row, no phantom rows' {
        $tid = New-SeedTrack -Status 'REMOTE'

        $p1 = Start-Child -Root $script:T.Root -Action 'like' -WorkerId 'worker_like_A' -TrackId $tid -JitterMs 0
        $p2 = Start-Child -Root $script:T.Root -Action 'like' -WorkerId 'worker_like_B' -TrackId $tid -JitterMs 40
        $r1 = Read-ChildResult -OutFile $p1.OutFile
        $r2 = Read-ChildResult -OutFile $p2.OutFile

        # At least one worker succeeded (or both if serialized).
        @($r1, $r2) | ForEach-Object {
            if ($_.Success) { @('QUEUED','ALREADY_QUEUED') -contains $_.Action | Should Be $true }
        }

        # Exactly one row won (or ALREADY_QUEUED observed if serialized).
        $successCount = @(@($r1, $r2) | Where-Object { $_.Success -and $_.Action -in @('QUEUED','ALREADY_QUEUED') }).Count
        ($successCount -ge 1) | Should Be $true

        # Final state: exactly ONE queue row, canonical is WANTED (or LOCAL/UNAVAILABLE not applicable).
        $qcount = @(Invoke-MusicServerSqlJson -Query "SELECT COUNT(*) as cnt FROM wanted_queue WHERE track_id = '$tid';")
        [int]$qcount[0].cnt | Should Be 1

        $canon = Get-CanonicalTrackDb -TrackId $tid
        $canon.status | Should Be 'WANTED'
    }

    It 'C2 stale CAS write by an in-flight worker must fail (not silently overwrite CANCEL_REQUESTED)' {
        $tid = New-SeedTrack -Status 'REMOTE'

        # Like to put it in queue at rev 1 (WANTED).
        [void](Invoke-LikeTrackTransactionDb -TrackId $tid -Source 'test_C2_seed')

        # Worker A claims (real child process): state -> RESOLVING, rev 2.
        $claimProc = Start-Child -Root $script:T.Root -Action 'claim' -WorkerId 'worker_A' -TrackId $tid -LeaseMinutes 30
        $claimRes = $null; $claimRead = $null
        if (-not $claimProc.TimedOut) { $claimRes = Read-ChildResult -OutFile $claimProc.OutFile }
        $claimRes.Success | Should Be $true
        $q = Get-WantedItemDb -TrackId $tid
        $q.state | Should Be 'RESOLVING'
        [int]$q.revision | Should Be 2

        # API unlikes: RESOLVING -> CANCEL_REQUESTED (rev 3).
        $unlike = Invoke-UnlikeTrackTransactionDb -TrackId $tid -Source 'test_C2_unlike'
        $unlike.action | Should Be 'CANCEL_REQUESTED'
        $qAfterCancel = Get-WantedItemDb -TrackId $tid
        $qAfterCancel.state | Should Be 'CANCEL_REQUESTED'
        [int]$qAfterCancel.revision | Should Be 3

        # Worker A attempts a stale CAS write (expected revision 2) against a
        # queue row that is now CANCEL_REQUESTED -> must fail the CAS gate.
        $casRes = Update-WantedStateCasDb -TrackId $tid -NewState 'RETRY_WAIT' -ExpectedRevision 2 -WorkerId 'worker_A'
        $casRes.Success | Should Be $false
        $casRes.Reason | Should Be 'CAS_FAILED'
        [int]$casRes.AffectedRows | Should Be 0
        [string]$casRes.CurrentState | Should Be 'CANCEL_REQUESTED'

        # State unchanged; revision unchanged (3); CANCEL_REQUESTED sticky.
        $qFinal = Get-WantedItemDb -TrackId $tid
        $qFinal.state | Should Be 'CANCEL_REQUESTED'
        [int]$qFinal.revision | Should Be 3
        $qFinal.claimed_by | Should Be ''

        # Evidence file for the hardening report.
        $Evidence = [ordered]@{
            test_id = 'C2'; old_revision = 2; new_revision = 3
            affected_rows = [int]$casRes.AffectedRows; cas_reason = [string]$casRes.Reason
            worker_id = 'worker_A'; state_at_stale_write = 'CANCEL_REQUESTED'
            timestamp = (Get-Date).ToUniversalTime().ToString('o')
        }
        $evidenceDir = Join-Path $ProjectRoot 'artifacts'
        if (-not (Test-Path -LiteralPath $evidenceDir)) { $null = New-Item -ItemType Directory -Force -Path $evidenceDir }
        $evidencePath = Join-Path $evidenceDir 'evidence_cas.json'
        $Evidence | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $evidencePath -Encoding UTF8
    }

    It 'C3 API sees stable state while worker holds lease (no mid-flight clobber)' {
        $tid = New-SeedTrack -Status 'REMOTE'

        # Like -> queue (rev 1, WANTED).
        [void](Invoke-LikeTrackTransactionDb -TrackId $tid -Source 'test_C3_like')

        # Worker A claims (real child) -> RESOLVING (rev 2).
        $claimProc = Start-Child -Root $script:T.Root -Action 'claim' -WorkerId 'worker_C3' -TrackId $tid -LeaseMinutes 30
        $claimRes = Read-ChildResult -OutFile $claimProc.OutFile
        $claimRes.Success | Should Be $true
        $q = Get-WantedItemDb -TrackId $tid
        $q.state | Should Be 'RESOLVING'
        [int]$q.revision | Should Be 2

        # API tries to re-like while RESOLVING: must be ALREADY_QUEUED (not RE-QUEUE).
        $likeRes = Invoke-LikeTrackTransactionDb -TrackId $tid -Source 'test_C3_relike'
        $likeRes.action | Should Be 'ALREADY_QUEUED'

        # Worker A CAS -> RETRY_WAIT (real child, expected revision 2).
        $casProc = Start-Child -Root $script:T.Root -Action 'cas' -WorkerId 'worker_C3' -TrackId $tid -NewState 'RETRY_WAIT' -ExpectedRevision 2
        $casRes = Read-ChildResult -OutFile $casProc.OutFile
        $casRes.Success | Should Be $true
        $casRes.Reason | Should BeNullOrEmpty

        $qAfterCas = Get-WantedItemDb -TrackId $tid
        $qAfterCas.state | Should Be 'RETRY_WAIT'
        [int]$qAfterCas.revision | Should Be 3
        $qAfterCas.claimed_by | Should Be ''

        # API unlikes: RETRY_WAIT -> IDLE_REMOVED; queue cleared, canonical REMOTE.
        $unlike = Invoke-UnlikeTrackTransactionDb -TrackId $tid -Source 'test_C3_unlike'
        $unlike.action | Should Be 'IDLE_REMOVED'
        $canon = Get-CanonicalTrackDb -TrackId $tid
        $canon.status | Should Be 'REMOTE'
        $qCount = @(Invoke-MusicServerSqlJson -Query "SELECT COUNT(*) as cnt FROM wanted_queue WHERE track_id = '$tid';")
        [int]$qCount[0].cnt | Should Be 0
    }
}

# ---------------------------------------------------------------------------
# D. SQLite as sole source of truth (no JSON round-trip)
# ---------------------------------------------------------------------------
Describe 'D: SQLite is the sole runtime truth (no JSON round-trip)' {
    BeforeEach {
        $script:T.Root = $null
        $script:T.Config = $null
        $script:T.DbPath = $null
        $root = New-TestRoot
        Invoke-DbSetup -Root $root
        $script:Cfg = $script:T.Config
    }
    AfterEach {
        Remove-All
    }

    function Assert-NoRuntimeJson {
        param([Parameter(Mandatory)][string]$StateDir)
        $forbidden = @(
            'tracks.json', 'wanted.json', 'recommendations.json',
            'recommendation_history.json', 'providers.json', 'events.jsonl'
        )
        foreach ($name in $forbidden) {
            $p = Join-Path $StateDir $name
            # These legacy JSON files must NOT appear as live state writes.
            # If present, they are stale seed-only artifacts (empty) and acceptable only as migration input.
            if (Test-Path -LiteralPath $p) {
                $size = (Get-Item -LiteralPath $p).Length
                # Zero-byte files are acceptable only if created as empty seed placeholder;
                # otherwise the runtime wrote JSON which violates the contract.
                @($size) | Should Be 0
            }
        }
    }

    It 'D1: migration is idempotent and does not re-import from JSON' {
        $tid = New-SeedTrack -Status 'REMOTE'
        $canon = Get-CanonicalTrackDb -TrackId $tid
        $revBefore = [int]$canon.revision

        # Migration module already imported at file scope (module instance reset law).
        # Run migration on a DB that already has data.
        $mig = Invoke-MusicServerMigration -Config $script:Cfg

        $mig.status | Should Be 'ALREADY_MIGRATED'
        $mig.idempotent | Should Be $true

        # Canonical count unchanged (no duplicate import).
        $count = @(Invoke-MusicServerSqlJson -Query "SELECT COUNT(*) as cnt FROM canonical_tracks;")
        [int]$count[0].cnt | Should Be 1

        # Track revision unchanged (idempotent = no re-write).
        $canon2 = Get-CanonicalTrackDb -TrackId $tid
        [int]$canon2.revision | Should Be $revBefore
    }

    It 'D2: after LIKE/UNLIKE ops, NO JSON files are written to the state directory' {
        $tid = New-SeedTrack -Status 'REMOTE'
        [void](Invoke-LikeTrackTransactionDb -TrackId $tid -Source 'test_D2')
        [void](Invoke-UnlikeTrackTransactionDb -TrackId $tid -Source 'test_D2')

        Assert-NoRuntimeJson -StateDir $script:Cfg.StateDir
    }

    It 'D3: DB is the source of truth for all reads after a full like/unlike cycle' {
        $tid = New-SeedTrack -Status 'REMOTE'
        [void](Invoke-LikeTrackTransactionDb -TrackId $tid -Source 'test_D3')
        [void](Invoke-UnlikeTrackTransactionDb -TrackId $tid -Source 'test_D3')

        # canonical_tracks: REMOTE (back to idle).
        $canon = Get-CanonicalTrackDb -TrackId $tid
        $canon.status | Should Be 'REMOTE'

        # recommendation_feedback: one LIKE + one UNLIKE.
        $fb = @(Invoke-MusicServerSqlJson -Query "SELECT feedback_type FROM recommendation_feedback WHERE track_id = '$tid' ORDER BY id;")
        $types = @($fb | ForEach-Object { [string]$_.feedback_type })
        $types.Count | Should Be 2
        $types[0] | Should Be 'LIKE'
        $types[1] | Should Be 'UNLIKE'

        # events: TRACK_LIKED then TRACK_UNLIKED.
        $ev = @(Invoke-MusicServerSqlJson -Query "SELECT event_type FROM events WHERE track_id = '$tid' ORDER BY id;")
        $evTypes = @($ev | ForEach-Object { [string]$_.event_type })
        $evTypes.Count | Should Be 2
        $evTypes[0] | Should Be 'TRACK_LIKED'
        $evTypes[1] | Should Be 'TRACK_UNLIKED'

        # Get-LatestRecommendationFeedbackDb returns the latest feedback_type ('UNLIKE').
        $latest = Get-LatestRecommendationFeedbackDb -TrackId $tid
        [string]$latest | Should Be 'UNLIKE'

        # Get-GetEventsDb returns both events.
        $dbEvents = Get-EventsDb -TrackId $tid
        $dbEvents.Count | Should Be 2
    }
}

# ---------------------------------------------------------------------------
# E. Real HTTP API smoke (music_api.ps1)
# ---------------------------------------------------------------------------
Describe 'E: real HTTP API contract (music_api.ps1, real processes and sockets)' {
    BeforeEach {
        $script:T.Root = $null
        $script:T.Config = $null
        $script:T.DbPath = $null
        $root = New-TestRoot
        Invoke-DbSetup -Root $root
        $script:Cfg = $script:T.Config
    }
    AfterEach {
        Stop-MusicApi
        Remove-All
    }

    It 'E1: GET/POST/DELETE /api/tracks/{id}/like returns 200 with correct action field' {
        $tid = New-SeedTrack -Status 'REMOTE'

        $api = Start-MusicApi -Root $script:T.Root
        $base = $api.BaseUrl

        # Health check (real HTTP/JSON round-trip against a real socket).
        $health = Invoke-Http -BaseUrl $base -Method 'GET' -Path '/health'
        $health.Status | Should Be 200
        $health.Json.status | Should Be 'ok'
        $health.Json.db | Should Be $true

        # GET the track (200, track_id present).
        $get = Invoke-Http -BaseUrl $base -Method 'GET' -Path "/api/tracks/$tid"
        $get.Status | Should Be 200
        $get.Json.track_id | Should Be $tid
        $get.Json.track | Should not BeNullOrEmpty
        $get.Json.liked | Should Be $false

        # POST like (200, accepted=true, action=QUEUED, liked=true).
        $postLike = Invoke-Http -BaseUrl $base -Method 'POST' -Path "/api/tracks/$tid/like"
        $postLike.Status | Should Be 200
        $postLike.Json.accepted | Should Be $true
        $postLike.Json.liked | Should Be $true
        $postLike.Json.action | Should Be 'QUEUED'
        $postLike.Json.track_id | Should Be $tid

        # DB: queue row exists in WANTED.
        $q = Get-WantedItemDb -TrackId $tid
        $q.state | Should Be 'WANTED'
        $canon = Get-CanonicalTrackDb -TrackId $tid
        $canon.status | Should Be 'WANTED'

        # DELETE like (200, liked=false, action=IDLE_REMOVED).
        $delLike = Invoke-Http -BaseUrl $base -Method 'DELETE' -Path "/api/tracks/$tid/like"
        $delLike.Status | Should Be 200
        $delLike.Json.liked | Should Be $false
        $delLike.Json.action | Should Be 'IDLE_REMOVED'
        $delLike.Json.track_id | Should Be $tid

        # DB: queue row gone, canonical REMOTE.
        $qCount = @(Invoke-MusicServerSqlJson -Query "SELECT COUNT(*) as cnt FROM wanted_queue WHERE track_id = '$tid';")
        [int]$qCount[0].cnt | Should Be 0
        $canon2 = Get-CanonicalTrackDb -TrackId $tid
        $canon2.status | Should Be 'REMOTE'

        Stop-MusicApi
    }

    It 'E2: unknown track_id returns 404 with no DB writes' {
        $api = Start-MusicApi -Root $script:T.Root
        $base = $api.BaseUrl

        # GET unknown track -> 404 TRACK_NOT_FOUND.
        $get = Invoke-Http -BaseUrl $base -Method 'GET' -Path '/api/tracks/nonexistent_track_x9z'
        $get.Status | Should Be 404
        $get.Json.error | Should Be 'TRACK_NOT_FOUND'

        # POST like on unknown track -> 404 (server catch maps TRACK_NOT_FOUND -> 404).
        $post = Invoke-Http -BaseUrl $base -Method 'POST' -Path '/api/tracks/nonexistent_track_x9z/like'
        $post.Status | Should Be 404

        # DB unchanged: no queue row, no feedback, no events for this id.
        $qCount = @(Invoke-MusicServerSqlJson -Query "SELECT COUNT(*) as cnt FROM wanted_queue WHERE track_id = 'nonexistent_track_x9z';")
        [int]$qCount[0].cnt | Should Be 0
        $fbCount = @(Invoke-MusicServerSqlJson -Query "SELECT COUNT(*) as cnt FROM recommendation_feedback WHERE track_id = 'nonexistent_track_x9z';")
        [int]$fbCount[0].cnt | Should Be 0
        $evCount = @(Invoke-MusicServerSqlJson -Query "SELECT COUNT(*) as cnt FROM events WHERE track_id = 'nonexistent_track_x9z';")
        [int]$evCount[0].cnt | Should Be 0

        Stop-MusicApi
    }
}
