<#
.SYNOPSIS
    MusicServer ApiRuntime hardening tests - real HTTP server (music_api.ps1)
    under real concurrent load, real sockets, real processes.

    Scope (per hardening-v2 task):
      R0  baseline HTTP contract on a live server (health / like / unlike / wanted)
      R1  TWO independent client processes race a single POST /like against the
          same REMOTE track (barrier-synchronized) -> exactly one queue row.
      R2  after all ops: no legacy JSON runtime state files in StateDir.
      R3  server restart resilience: state (DB) survives process death on the
          same root; second server instance serves it.
      R4  unknown track_id over real HTTP -> 404, no writes.

    Isolation:
      - Fresh temp test root per Describe block.
      - Free TCP port per server instance (127.0.0.1).
      - All child/server processes killed in AfterEach (taskkill /T).
#>

$ErrorActionPreference = 'Stop'

$ProjectRoot = Split-Path -Parent $PSScriptRoot

# Module imports (module instance reset law: before any Initialize call).
Import-Module (Join-Path $ProjectRoot 'MusicServer.Core.psm1') -Force
Import-Module (Join-Path $ProjectRoot 'MusicServer.Database.psm1') -Force
Import-Module (Join-Path $ProjectRoot 'MusicServer.State.psm1') -Force

$script:T = [pscustomobject]@{
    Root      = $null
    Config    = $null
    DbPath    = $null
    TestRoots = @()
    ApiProcs  = @()
}

function Invoke-FreePort {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = [int]$listener.LocalEndpoint.Port
    $listener.Stop()
    return $port
}

function New-TestRoot {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('msrt_' + [guid]::NewGuid().ToString('N'))
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

function Stop-AllApiServers {
    foreach ($proc in @($script:T.ApiProcs)) {
        try {
            if ($proc -and -not $proc.HasExited) {
                & cmd.exe /c "taskkill /PID $($proc.Id) /T /F" 6>&1 | Out-Null
                $proc.WaitForExit(5000) | Out-Null
            }
        } catch {}
        try { if ($proc) { $proc.Dispose() | Out-Null } } catch {}
    }
    $script:T.ApiProcs = @()
}

function Remove-AllState {
    Stop-AllApiServers
    foreach ($root in @($script:T.TestRoots)) {
        try { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue } catch {}
    }
    $script:T.TestRoots = @()
}

function Get-TermExe {
    $cmd = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return (Get-Command powershell.exe).Source
}

function Start-MusicApi {
    param([Parameter(Mandatory)][string]$Root)
    $port = Invoke-FreePort
    $prefix = "http://127.0.0.1:$port/"
    $sfx = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $logF = Join-Path $Root ('api_out_' + $sfx + '.log')
    $errF = Join-Path $Root ('api_err_' + $sfx + '.log')
    $argList = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', (Join-Path $ProjectRoot 'music_api.ps1'),
        '-Prefix', $prefix, '-Root', $Root)
    $proc = Start-Process -FilePath (Get-TermExe) -ArgumentList $argList -WindowStyle Hidden -PassThru -RedirectStandardOutput $logF -RedirectStandardError $errF
    $script:T.ApiProcs += $proc

    $stdout = ''
    $deadline = [DateTime]::UtcNow.AddSeconds(40)
    while ([DateTime]::UtcNow -lt $deadline) {
        $stdout = ''
        if (Test-Path -LiteralPath $logF) { try { $stdout = Get-Content -LiteralPath $logF -Raw -EA SilentlyContinue } catch { $stdout = '' } }
        if ($stdout -match 'API v2 ready') {
            return [pscustomobject]@{ Process = $proc; BaseUrl = $prefix.TrimEnd('/'); Port = $port }
        }
        if ($proc.HasExited) { break }
        Start-Sleep -Milliseconds 200
    }
    $stderr = ''
    if (Test-Path -LiteralPath $errF) { try { $stderr = Get-Content -LiteralPath $errF -Raw -EA SilentlyContinue } catch { $stderr = '' } }
    $exitInfo = 'still-running'
    if ($proc.HasExited) { $exitInfo = 'exitcode=' + $proc.ExitCode }
    throw ('music_api.ps1 not ready in 40s. ' + $exitInfo + ' stdout=[' + $stdout + '] stderr=[' + $stderr + ']')
}

function Invoke-Http {
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Path
    )
    $url = $BaseUrl + $Path
    $text = ''
    $status = -1
    try {
        $request = [System.Net.HttpWebRequest]::Create($url)
        $request.Method = $Method
        $request.Timeout = 20000
        $request.ReadWriteTimeout = 20000
        $request.ContentType = 'application/json; charset=utf-8'
        # Keep-alive bodyless requests (incl. POST/DELETE) need an explicit
        # Content-Length or the HttpListener answers 411 Length Required.
        # PS 5.1 (.NET 4.x) HttpWebRequest has no ContentLength64; .NET Core has both.
        if ($request.GetType().GetProperty('ContentLength64')) { $request.ContentLength64 = 0 } else { $request.ContentLength = 0 }
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
        $we = $_.Exception
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
        }
    }
    $json = $null
    if ($text) { try { $json = $text | ConvertFrom-Json } catch {} }
    return [pscustomobject]@{ Status = [int]$status; Text = [string]$text; Json = $json }
}

function New-SeedTrack {
    $sfx = [guid]::NewGuid().ToString('N').Substring(0, 6)
    $track = New-CanonicalTrack -Title ('RtTrack ' + $sfx) -Artist ('RtArtist ' + $sfx) -Status 'REMOTE'
    $saved = Save-CanonicalTrackDb -Track $track
    if (-not $saved.Success) { throw "Save-CanonicalTrackDb failed: $($saved.Error)" }
    return [string]$track.id
}

Describe 'R: runtime hardening of the real HTTP API (concurrent processes, real sockets)' {
    $RacerScript = Join-Path $PSScriptRoot 'MusicServer.HttpRacer.ps1'

    BeforeEach {
        $script:T.Root = $null
        $script:T.Config = $null
        $script:T.DbPath = $null
        $root = New-TestRoot
        Invoke-DbSetup -Root $root
        $script:Cfg = $script:T.Config
    }
    AfterEach {
        Remove-AllState
    }

    It 'R0: live server baseline - health 200, POST like 200 QUEUED, DELETE unlike 200 IDLE_REMOVED, GET wanted' {
        $tid = New-SeedTrack
        $api = Start-MusicApi -Root $script:T.Root
        $base = $api.BaseUrl

        $health = Invoke-Http -BaseUrl $base -Method 'GET' -Path '/health'
        $health.Status | Should Be 200
        $health.Json.status | Should Be 'ok'
        $health.Json.db | Should Be $true

        $like = Invoke-Http -BaseUrl $base -Method 'POST' -Path "/api/tracks/$tid/like"
        $like.Status | Should Be 200
        $like.Json.accepted | Should Be $true
        $like.Json.liked | Should Be $true
        $like.Json.action | Should Be 'QUEUED'

        $q = Get-WantedItemDb -TrackId $tid
        $q.state | Should Be 'WANTED'
        [int]$q.revision | Should Be 1

        $unlike = Invoke-Http -BaseUrl $base -Method 'DELETE' -Path "/api/tracks/$tid/like"
        $unlike.Status | Should Be 200
        $unlike.Json.liked | Should Be $false
        $unlike.Json.action | Should Be 'IDLE_REMOVED'

        $canon = Get-CanonicalTrackDb -TrackId $tid
        $canon.status | Should Be 'REMOTE'

        $qcount = @(Invoke-MusicServerSqlJson -Query "SELECT COUNT(*) as cnt FROM wanted_queue WHERE track_id = '$tid';")
        [int]$qcount[0].cnt | Should Be 0

        $wanted = Invoke-Http -BaseUrl $base -Method 'GET' -Path '/api/wanted'
        $wanted.Status | Should Be 200
        $wanted.Json.items | Should BeNullOrEmpty

        Stop-AllApiServers
    }

    It 'R1: two independent client processes race POST /like -> exactly one queue row, one QUEUED' {
        $tid = New-SeedTrack
        $api = Start-MusicApi -Root $script:T.Root
        $base = $api.BaseUrl

        $barrierFile = Join-Path $script:T.Root 'barrier_ready.signal'
        $null = New-Item -ItemType File -Path $barrierFile -Force

        $outDir = Join-Path $script:T.Root 'race'
        $null = New-Item -ItemType Directory -Force -Path $outDir
        $ready1 = Join-Path $outDir 'ready_1.signal'
        $ready2 = Join-Path $outDir 'ready_2.signal'
        $out1 = Join-Path $outDir 'result_1.json'
        $out2 = Join-Path $outDir 'result_2.json'

        # Non-blocking start: the racer arms itself (ReadyFile), then blocks on
        # the barrier file, which the PARENT deletes only AFTER both racers are
        # armed. Waiting for exit here would deadlock the barrier release and
        # kill the racer before it could fire, so just record the handle.
        function Start-Racer {
            param([string]$BaseUrl, [string]$TrackId, [string]$Barrier, [string]$OutFile, [string]$ReadyFile)
            $aa = @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$RacerScript,
                '-BaseUrl',$BaseUrl,'-TrackId',$TrackId,'-BarrierFile',$Barrier,'-OutFile',$OutFile,'-ReadyFile',$ReadyFile)
            $p = Start-Process -FilePath (Get-TermExe) -ArgumentList $aa -WindowStyle Hidden -PassThru
            $script:T.ApiProcs += $p
            return [pscustomobject]@{ Process = $p }
        }

        # Both racers wait on the barrier (true simultaneity at the HTTP boundary).
        $r1 = Start-Racer -BaseUrl $base -TrackId $tid -Barrier $barrierFile -OutFile $out1 -ReadyFile $ready1
        $r2 = Start-Racer -BaseUrl $base -TrackId $tid -Barrier $barrierFile -OutFile $out2 -ReadyFile $ready2

        # Wait until BOTH clients are armed (ready files written by each racer).
        $dead = [DateTime]::UtcNow.AddSeconds(30)
        while ([DateTime]::UtcNow -lt $dead) {
            if ((Test-Path -LiteralPath $ready1) -and (Test-Path -LiteralPath $ready2)) { break }
            Start-Sleep -Milliseconds 100
        }
        (Test-Path -LiteralPath $ready1) | Should Be $true -Because 'racer 1 never armed (timed out)'
        (Test-Path -LiteralPath $ready2) | Should Be $true -Because 'racer 2 never armed (timed out)'

        # Release the barrier: both fire their POST /like within a few ms.
        Remove-Item -LiteralPath $barrierFile -Force

        $dead = [DateTime]::UtcNow.AddSeconds(30)
        while ([DateTime]::UtcNow -lt $dead) {
            if ((Test-Path -LiteralPath $out1) -and (Test-Path -LiteralPath $out2)) { break }
            Start-Sleep -Milliseconds 100
        }
        (Test-Path -LiteralPath $out1) | Should Be $true -Because 'racer 1 produced no result'
        (Test-Path -LiteralPath $out2) | Should Be $true -Because 'racer 2 produced no result'

        $res1 = (Get-Content -LiteralPath $out1 -Raw | ConvertFrom-Json)
        $res2 = (Get-Content -LiteralPath $out2 -Raw | ConvertFrom-Json)

        # Both requests processed with 200 by the single-threaded API.
        [int]$res1.status | Should Be 200
        [int]$res2.status | Should Be 200
        [bool]$res1.accepted | Should Be $true
        [bool]$res2.accepted | Should Be $true

        # Exactly one QUEUED, the other ALREADY_QUEUED (no double queue row).
        # Pester 3 caveat: piping an array asserts each element, so assert per-slot.
        $actions = @($res1.action, $res2.action) | Sort-Object
        $actions.Count | Should Be 2 -Because "race should produce exactly two verdicts, got: $($res1.action) / $($res2.action)"
        $actions[0]     | Should Be 'ALREADY_QUEUED'
        $actions[1]     | Should Be 'QUEUED'

        # Invariant: EXACTLY ONE queue row for the track, at revision 1.
        $q = @(Invoke-MusicServerSqlJson -Query "SELECT state, revision FROM wanted_queue WHERE track_id = '$tid';")
        $q.Count | Should Be 1
        $q[0].state | Should Be 'WANTED'
        [int]$q[0].revision | Should Be 1

        # Canonical is WANTED.
        $canon = Get-CanonicalTrackDb -TrackId $tid
        $canon.status | Should Be 'WANTED'

        # Two LIKE feedback rows (audit trail of both clients' intent).
        $fb = @(Invoke-MusicServerSqlJson -Query "SELECT COUNT(*) as cnt FROM recommendation_feedback WHERE track_id = '$tid' AND feedback_type = 'LIKE';")
        [int]$fb[0].cnt | Should Be 2

        # Evidence artifact for the hardening report.
        $evidenceDir = Join-Path $ProjectRoot 'artifacts'
        if (-not (Test-Path -LiteralPath $evidenceDir)) { $null = New-Item -ItemType Directory -Force -Path $evidenceDir }
        [ordered]@{
            test_id = 'R1'; concurrent_like_clients = 2
            responses = @(@{ status = [int]$res1.status; action = [string]$res1.action },
                          @{ status = [int]$res2.status; action = [string]$res2.action })
            queue_rows = 1; canonical_status = [string]$canon.status
            timestamp = (Get-Date).ToUniversalTime().ToString('o')
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $evidenceDir 'evidence_runtime_r1.json') -Encoding UTF8

        Stop-AllApiServers
    }

    It 'R2: no legacy JSON runtime state files appear after real HTTP like/unlike traffic' {
        $tid = New-SeedTrack
        $api = Start-MusicApi -Root $script:T.Root
        $base = $api.BaseUrl

        [void](Invoke-Http -BaseUrl $base -Method 'POST' -Path "/api/tracks/$tid/like")
        [void](Invoke-Http -BaseUrl $base -Method 'DELETE' -Path "/api/tracks/$tid/like")

        # All legacy JSON state files must either be absent or zero-length
        # (fresh roots never had them; the server must not (re)create them).
        foreach ($name in @('tracks.json','wanted.json','recommendations.json','recommendation_history.json','providers.json','events.jsonl')) {
            $p = Join-Path $script:Cfg.StateDir $name
            if (Test-Path -LiteralPath $p) {
                (Get-Item -LiteralPath $p).Length | Should Be 0 -Because "$name must not be a non-empty runtime write"
            }
        }

        # SQLite is the observable truth: feedback + events present.
        $fb = @(Invoke-MusicServerSqlJson -Query "SELECT COUNT(*) as cnt FROM recommendation_feedback WHERE track_id = '$tid';")
        [int]$fb[0].cnt | Should Be 2
        $ev = @(Invoke-MusicServerSqlJson -Query "SELECT COUNT(*) as cnt FROM events WHERE track_id = '$tid';")
        [int]$ev[0].cnt | Should Be 2

        Stop-AllApiServers
    }

    It 'R3: state survives server death; a second server instance on a new port serves the same DB' {
        $tid = New-SeedTrack
        $api1 = Start-MusicApi -Root $script:T.Root
        $base1 = $api1.BaseUrl

        $like = Invoke-Http -BaseUrl $base1 -Method 'POST' -Path "/api/tracks/$tid/like"
        $like.Json.action | Should Be 'QUEUED'

        # Hard-kill the first server (simulating a crash / restart).
        $target = $api1.Process
        & cmd.exe /c "taskkill /PID $($target.Id) /T /F" 6>&1 | Out-Null
        $target.WaitForExit(5000) | Out-Null
        $script:T.ApiProcs = @($script:T.ApiProcs | Where-Object { $_ -ne $target })

        # Start a SECOND server instance on a NEW port against the SAME root/DB.
        $api2 = Start-MusicApi -Root $script:T.Root
        $base2 = $api2.BaseUrl
        $api2.Port | Should not Be $api1.Port

        $health = Invoke-Http -BaseUrl $base2 -Method 'GET' -Path '/health'
        $health.Status | Should Be 200
        $health.Json.db | Should Be $true

        $get = Invoke-Http -BaseUrl $base2 -Method 'GET' -Path "/api/tracks/$tid"
        $get.Status | Should Be 200
        $get.Json.track_id | Should Be $tid
        $get.Json.liked | Should Be $true

        # Re-like while still queued -> ALREADY_QUEUED (queue survived the crash).
        $rel = Invoke-Http -BaseUrl $base2 -Method 'POST' -Path "/api/tracks/$tid/like"
        $rel.Json.action | Should Be 'ALREADY_QUEUED'
        $q = Get-WantedItemDb -TrackId $tid
        [int]$q.revision | Should Be 1

        Stop-AllApiServers
    }

    It 'R4: unknown track_id over real HTTP -> 404, zero writes in DB' {
        $api = Start-MusicApi -Root $script:T.Root
        $base = $api.BaseUrl

        # Schema setup (BeforeEach) already recorded exactly one
        # MIGRATION_COMPLETED event row. The real contract: the three
        # unknown-id requests below must add NOTHING new to any table, so
        # snapshot the total now and require the delta to be 0.
        $countExpr = "SELECT (SELECT COUNT(*) FROM wanted_queue) + (SELECT COUNT(*) FROM recommendation_feedback) + (SELECT COUNT(*) FROM events) AS total;"
        $before = [int](@(Invoke-MusicServerSqlJson -Query $countExpr))[0].total

        $get = Invoke-Http -BaseUrl $base -Method 'GET' -Path '/api/tracks/zzz_no_such_track_qq'
        $get.Status | Should Be 404

        $like = Invoke-Http -BaseUrl $base -Method 'POST' -Path '/api/tracks/zzz_no_such_track_qq/like'
        $like.Status | Should Be 404

        $unlike = Invoke-Http -BaseUrl $base -Method 'DELETE' -Path '/api/tracks/zzz_no_such_track_qq/like'
        $unlike.Status | Should Be 404

        $after = [int](@(Invoke-MusicServerSqlJson -Query $countExpr))[0].total
        $after | Should Be $before

        Stop-AllApiServers
    }
}
