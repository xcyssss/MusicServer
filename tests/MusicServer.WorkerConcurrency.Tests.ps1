$ProjectRoot = Split-Path -Parent $PSScriptRoot
$CorePath  = Join-Path $ProjectRoot 'MusicServer.Core.psm1'
$DbPath    = Join-Path $ProjectRoot 'MusicServer.Database.psm1'
$StatePath = Join-Path $ProjectRoot 'MusicServer.State.psm1'
$WorkerChildScript = Join-Path $PSScriptRoot 'MusicServer.WorkerChild.ps1'

function Build-WorkerChildArgs {
    param(
        [string]$TestRoot,
        [string]$Action,
        [string]$WorkerId,
        [string]$OutFile,
        [string]$TrackId = '',
        [string]$NewState = 'RETRY_WAIT',
        [int]$ExpectedRevision = -1,
        [int]$LeaseMinutes = 30
    )
    @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $WorkerChildScript,
        '-ProjectRoot', $ProjectRoot,
        '-Root', $TestRoot,
        '-Action', $Action,
        '-WorkerId', $WorkerId,
        '-OutFile', $OutFile,
        '-TrackId', $TrackId,
        '-NewState', $NewState,
        '-ExpectedRevision', ([string]$ExpectedRevision),
        '-LeaseMinutes', ([string]$LeaseMinutes)
    )
}

function Invoke-WorkerChild {
    param(
        [string]$TestRoot,
        [string]$Action,
        [string]$WorkerId,
        [string]$OutFile,
        [string]$TrackId = '',
        [string]$NewState = 'RETRY_WAIT',
        [int]$ExpectedRevision = -1,
        [int]$LeaseMinutes = 30
    )
    $argList = Build-WorkerChildArgs -TestRoot $TestRoot -Action $Action -WorkerId $WorkerId `
        -OutFile $OutFile -TrackId $TrackId -NewState $NewState `
        -ExpectedRevision $ExpectedRevision -LeaseMinutes $LeaseMinutes
    $proc = Start-Process -FilePath (Get-Command powershell.exe).Source -ArgumentList $argList -WindowStyle Hidden -PassThru
    if (-not $proc.WaitForExit(120000)) {
        $proc.Kill()
        throw "Worker child '$WorkerId' timed out waiting for an action result."
    }
    $raw = (Get-Content -LiteralPath $OutFile -Raw -ErrorAction SilentlyContinue)
    if (-not $raw) { throw "Worker child '$WorkerId' did not produce a result at $OutFile." }
    return ($raw.Trim() | ConvertFrom-Json)
}

Describe 'MusicServer Hardening v2 Phase 2 - Worker Concurrency' {
    BeforeEach {
        $TestRoot = Join-Path ([IO.Path]::GetTempPath()) "msvc_$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $TestRoot -Force | Out-Null
        $StateDir = Join-Path $TestRoot 'DailyMix_data\state'
        New-Item -ItemType Directory -Path $StateDir -Force | Out-Null

        Import-Module $CorePath -Force
        Import-Module $DbPath -Force
        Import-Module $StatePath -Force

        $Config = New-MusicServerConfig -Root $TestRoot
        Initialize-MusicServerState -Config $Config
        $script:DbbPath = Join-Path $Config.StateDir 'musicserver.db'
        Initialize-MusicServerDatabase -DbPath $script:DbbPath -SqliteExe $Config.Sqlite
        Initialize-MusicServerSchema
    }

    AfterEach {
        Remove-Item -LiteralPath $TestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    # 1 ─ Two real PowerShell workers race the same track: exactly one claim succeeds.
    It 'exactly one of two concurrent workers claims the item' {
        $track = New-CanonicalTrack -Title 'Race' -Artist 'Concurrent'
        Save-CanonicalTrackDb -Track $track | Out-Null
        Add-WantedItemDb -TrackId $track.id | Out-Null

        # Launch two concurrent PowerShell worker processes (true race).
        $psExe = (Get-Command powershell.exe).Source
        $resAFile = Join-Path $TestRoot 'race_A.json'
        $resBFile = Join-Path $TestRoot 'race_B.json'
        $argsA = Build-WorkerChildArgs -TestRoot $TestRoot -Action 'claim' -WorkerId 'worker_race_A' -OutFile $resAFile -TrackId $track.id
        $argsB = Build-WorkerChildArgs -TestRoot $TestRoot -Action 'claim' -WorkerId 'worker_race_B' -OutFile $resBFile -TrackId $track.id
        $procA = Start-Process -FilePath $psExe -ArgumentList $argsA -WindowStyle Hidden -PassThru
        $procB = Start-Process -FilePath $psExe -ArgumentList $argsB -WindowStyle Hidden -PassThru
        $okA = $procA.WaitForExit(120000)
        $okB = $procB.WaitForExit(120000)
        if (-not $okA) { $procA.Kill() }
        if (-not $okB) { $procB.Kill() }
        $okA | Should Be $true
        $okB | Should Be $true

        $rawA = Get-Content -LiteralPath $resAFile -Raw -ErrorAction SilentlyContinue
        $rawB = Get-Content -LiteralPath $resBFile -Raw -ErrorAction SilentlyContinue
        $rawA | Should Not BeNullOrEmpty
        $rawB | Should Not BeNullOrEmpty
        $resA = $rawA.Trim() | ConvertFrom-Json
        $resB = $rawB.Trim() | ConvertFrom-Json

        # Exactly one of the two real workers must win the claim.
        $trueCount = @(@($resA, $resB) | Where-Object { $_.Success -eq $true }).Count
        $trueCount | Should Be 1

        # The loser must report the conflict (not an exception).
        $losers = @(@($resA, $resB) | Where-Object { $_.Success -eq $false })
        $losers[0].Reason | Should Be 'CLAIM_CONFLICT'

        # A single winner must be recorded as the claim holder.
        $item = Get-WantedItemDb -TrackId $track.id
        $item.state | Should Be 'RESOLVING'
        if (@('worker_race_A', 'worker_race_B') -notcontains [string]$item.claimed_by) {
            throw "claimed_by [$($item.claimed_by)] is neither worker_race_A nor worker_race_B"
        }
        $item.lease_expires_epoch | Should Not Be $null
        ($item.lease_expires_epoch -gt [long][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) | Should Be $true
    }

    # 2 ─ A stale worker cannot overwrite CANCEL_REQUESTED.
    It 'stale worker CAS cannot overwrite CANCEL_REQUESTED' {
        $track = New-CanonicalTrack -Title 'Cancel' -Artist 'Stale'
        Save-CanonicalTrackDb -Track $track | Out-Null
        Add-WantedItemDb -TrackId $track.id | Out-Null

        $claim = Claim-WantedItemDb -TrackId $track.id -WorkerId 'worker_stale'
        $claim.Success | Should Be $true

        # Snapshot the revision the stale worker last saw
        $snapshot = Get-WantedItemDb -TrackId $track.id
        $staleRev = $snapshot.revision

        # User (or API) requests cancellation
        $cancel = Request-WantedCancellationDb -TrackId $track.id
        $cancel.Success | Should Be $true
        $cancel.Reason | Should Be 'CANCEL_REQUESTED'

        # Stale worker (real process) attempts a state transition with its outdated revision
        $out2 = Join-Path $TestRoot 'stale_cas.json'
        $staleResult = Invoke-WorkerChild -TestRoot $TestRoot -Action 'cas' -WorkerId 'worker_stale' `
            -OutFile $out2 -TrackId $track.id -NewState 'RETRY_WAIT' -ExpectedRevision $staleRev
        $staleResult.Success | Should Be $false

        # State must remain CANCEL_REQUESTED
        $item = Get-WantedItemDb -TrackId $track.id
        $item.state | Should Be 'CANCEL_REQUESTED'
    }

    # 3 ─ An expired lease is recoverable by another worker.
    It 'expired lease allows crash recovery then re-claim by another worker' {
        $track = New-CanonicalTrack -Title 'Lease' -Artist 'Expired'
        Save-CanonicalTrackDb -Track $track | Out-Null
        Add-WantedItemDb -TrackId $track.id | Out-Null

        # Worker-1 claims successfully
        $c1 = Claim-WantedItemDb -TrackId $track.id -WorkerId 'worker_lease_1'
        $c1.Success | Should Be $true
        $item = Get-WantedItemDb -TrackId $track.id
        $item.state | Should Be 'RESOLVING'
        $item.lease_expires_epoch | Should Not Be $null

        # Simulate lease expiry (push epoch 2 min into the past)
        $expiredEpoch = [long][DateTimeOffset]::UtcNow.AddSeconds(-120).ToUnixTimeSeconds()
        Invoke-MusicServerParamNonQuery -Template "UPDATE wanted_queue SET lease_expires_epoch = @exp WHERE track_id = @tid;" -Params @{ exp = $expiredEpoch; tid = $track.id }

        # Crash recovery should detect and clear the stale lease
        $recovered = Invoke-CrashRecoveryDb
        $recovered | Should Be 1

        $item = Get-WantedItemDb -TrackId $track.id
        $item.state | Should Be 'RETRY_WAIT'
        $item.claimed_by | Should Be ''

        # Worker-2 (real process) can now claim the recovered item
        $out3 = Join-Path $TestRoot 'reclaim.json'
        $resC2 = Invoke-WorkerChild -TestRoot $TestRoot -Action 'claim' -WorkerId 'worker_lease_2' -OutFile $out3 -TrackId $track.id
        $resC2.Success | Should Be $true

        $item = Get-WantedItemDb -TrackId $track.id
        $item.claimed_by | Should Be 'worker_lease_2'
        $item.state | Should Be 'RESOLVING'
        $item.lease_expires_epoch | Should Not Be $null
        ($item.lease_expires_epoch -gt [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) | Should Be $true
    }

    # 4 ─ An active lease cannot be recovered or claimed.
    It 'active lease is not recovered and cannot be claimed by another worker' {
        $track = New-CanonicalTrack -Title 'Active' -Artist 'Locked'
        Save-CanonicalTrackDb -Track $track | Out-Null
        Add-WantedItemDb -TrackId $track.id | Out-Null

        # Worker-1 claims with the default 30-minute lease
        $c1 = Claim-WantedItemDb -TrackId $track.id -WorkerId 'worker_active'
        $c1.Success | Should Be $true

        $item = Get-WantedItemDb -TrackId $track.id
        $item.state | Should Be 'RESOLVING'
        $nowEpoch = [long][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $item.lease_expires_epoch | Should BeGreaterThan $nowEpoch

        # Crash recovery must NOT touch an active lease
        $recovered = Invoke-CrashRecoveryDb
        $recovered | Should Be 0

        # Another worker (real process) must NOT be able to claim
        $out4 = Join-Path $TestRoot 'intruder.json'
        $resC2 = Invoke-WorkerChild -TestRoot $TestRoot -Action 'claim' -WorkerId 'worker_intruder' -OutFile $out4 -TrackId $track.id
        $resC2.Success | Should Be $false
        $resC2.Reason | Should Be 'CLAIM_CONFLICT'

        # State remains intact
        $item = Get-WantedItemDb -TrackId $track.id
        $item.state | Should Be 'RESOLVING'
        $item.claimed_by | Should Be 'worker_active'
    }
}
