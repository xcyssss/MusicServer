$ProjectRoot = Split-Path -Parent $PSScriptRoot

Describe 'MusicServer Hardening v2 - SQLite State Layer' {
    BeforeEach {
        $TestRoot = Join-Path ([IO.Path]::GetTempPath()) "musicserver_v2_$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $TestRoot -Force | Out-Null
        $StateDir = Join-Path $TestRoot 'DailyMix_data\state'
        New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
        Import-Module (Join-Path $ProjectRoot 'MusicServer.Core.psm1') -Force
        Import-Module (Join-Path $ProjectRoot 'MusicServer.Database.psm1') -Force
        Import-Module (Join-Path $ProjectRoot 'MusicServer.State.psm1') -Force
        Import-Module (Join-Path $ProjectRoot 'MusicServer.Migration.psm1') -Force
        $Config = New-MusicServerConfig -Root $TestRoot
        Initialize-MusicServerState -Config $Config
        $dbPath = Join-Path $Config.StateDir 'musicserver.db'
        $sqlite = & $Config.Sqlite --version 2>$null
        Initialize-MusicServerDatabase -DbPath $dbPath -SqliteExe $Config.Sqlite
        Initialize-MusicServerSchema
    }

    AfterEach {
        Remove-Item -LiteralPath $TestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    # === Migration Tests ===

    It 'migrates empty state to DB without errors' {
        $report = Invoke-MusicServerMigration -Config $Config
        $report.status | Should Be 'SUCCESS'
        $report.imported.tracks | Should Be 0
    }

    It 'migrates existing JSON state to DB' {
        $track = New-CanonicalTrack -Title 'Migration Test' -Artist 'Artist' -Status 'REMOTE'
        Save-CanonicalTrack -Config $Config -Track $track | Out-Null
        $wanted = [pscustomobject]@{
            id = 'wanted_test'; track_id = $track.id; state = 'WANTED'; attempts = 0; max_attempts = 5
            next_retry_at = $null; selected_candidate = $null; last_error = ''
            created_at = (Get-NowIso); updated_at = (Get-NowIso)
        }
        Write-StateCollection -Config $Config -Name wanted -Items @($wanted)
        $prov = [pscustomobject]@{
            provider = 'bilibili_search'; state = 'OPEN'; success_count = 0; failure_count = 2
            consecutive_failures = 2; consecutive_412 = 2; last_success = $null
            last_failure = (Get-NowIso); last_412_at = (Get-NowIso)
            blocked_until = (Get-NowIso); average_latency_ms = 0; probe_pending = $false
            updated_at = (Get-NowIso)
        }
        Write-StateCollection -Config $Config -Name providers -Items @($prov)
        $report = Invoke-MusicServerMigration -Config $Config
        $report.status | Should Be 'SUCCESS'
        $report.imported.tracks | Should Be 1
        $report.imported.wanted | Should Be 1
        $dbTrack = Get-CanonicalTrackDb -TrackId $track.id
        $dbTrack | Should Not Be $null
        $dbTrack.title | Should Be 'Migration Test'
    }

    It 'is idempotent on repeated migration' {
        $track = New-CanonicalTrack -Title 'Idempotent' -Artist 'A'
        Save-CanonicalTrack -Config $Config -Track $track | Out-Null
        $report1 = Invoke-MusicServerMigration -Config $Config
        $report1.status | Should Be 'SUCCESS'
        $report2 = Invoke-MusicServerMigration -Config $Config
        $report2.status | Should Be 'ALREADY_MIGRATED'
        $report2.idempotent | Should Be $true
    }

    It 'ignores legacy bilibili provider during migration' {
        $legacy = [pscustomobject]@{
            provider = 'bilibili'; state = 'HALF_OPEN'; success_count = 0; failure_count = 3
            consecutive_failures = 3; consecutive_412 = 1; last_success = $null
            last_failure = (Get-NowIso); last_412_at = (Get-NowIso)
            blocked_until = (Get-NowIso); average_latency_ms = 0; probe_pending = $false
            updated_at = (Get-NowIso)
        }
        Write-StateCollection -Config $Config -Name providers -Items @($legacy)
        $report = Invoke-MusicServerMigration -Config $Config
        $report.status | Should Be 'SUCCESS'
        $report.legacy_ignored.Count | Should BeGreaterThan 0
    }

    It 'creates backup during migration' {
        $track = New-CanonicalTrack -Title 'Backup Test' -Artist 'A'
        Save-CanonicalTrack -Config $Config -Track $track | Out-Null
        $report = Invoke-MusicServerMigration -Config $Config
        $report.backup_path | Should Not Be ''
        Test-Path -LiteralPath $report.backup_path | Should Be $true
        Test-Path -LiteralPath (Join-Path $report.backup_path 'tracks.json') | Should Be $true
    }

    It 'dry run does not modify DB' {
        $track = New-CanonicalTrack -Title 'DryRun' -Artist 'A'
        Save-CanonicalTrack -Config $Config -Track $track | Out-Null
        $report = Invoke-MusicServerMigration -Config $Config -DryRun
        $report.status | Should Be 'DRY_RUN'
        $dbTrack = Get-CanonicalTrackDb -TrackId $track.id
        $dbTrack | Should Be $null
    }

    # === Wanted Queue Transaction Tests ===

    It 'creates exactly one wanted item on like' {
        $track = New-CanonicalTrack -Title 'W1' -Artist 'A'
        $result = Save-CanonicalTrackDb -Track $track
        $wanted = Add-WantedItemDb -TrackId $track.id
        $wanted | Should Not Be $null
        $wanted.state | Should Be 'WANTED'
        $all = @(Get-WantedTracksDb)
        @($all | Where-Object { $_.track_id -eq $track.id }).Count | Should Be 1
    }

    It 'keeps repeated like idempotent' {
        $track = New-CanonicalTrack -Title 'W2' -Artist 'A'
        Save-CanonicalTrackDb -Track $track | Out-Null
        Add-WantedItemDb -TrackId $track.id | Out-Null
        Add-WantedItemDb -TrackId $track.id | Out-Null
        $all = @(Get-WantedTracksDb)
        @($all | Where-Object { $_.track_id -eq $track.id }).Count | Should Be 1
    }

    It 'removes idle wanted on unlike atomically' {
        $track = New-CanonicalTrack -Title 'W3' -Artist 'A'
        Save-CanonicalTrackDb -Track $track | Out-Null
        Add-WantedItemDb -TrackId $track.id | Out-Null
        $result = Request-WantedCancellationDb -TrackId $track.id
        $result.Success | Should Be $true
        $result.Reason | Should Be 'IDLE_REMOVED'
        $item = Get-WantedItemDb -TrackId $track.id
        $item | Should Be $null
    }

    It 'sets CANCEL_REQUESTED on active unlike' {
        $track = New-CanonicalTrack -Title 'W4' -Artist 'A'
        Save-CanonicalTrackDb -Track $track | Out-Null
        $wanted = Add-WantedItemDb -TrackId $track.id
        $claim = Claim-WantedItemDb -TrackId $track.id -WorkerId 'worker_test'
        $claim.Success | Should Be $true
        $result = Request-WantedCancellationDb -TrackId $track.id
        $result.Success | Should Be $true
        $result.Reason | Should Be 'CANCEL_REQUESTED'
        $item = Get-WantedItemDb -TrackId $track.id
        $item.state | Should Be 'CANCEL_REQUESTED'
    }

    It 'prevents duplicate active wanted' {
        $track = New-CanonicalTrack -Title 'W5' -Artist 'A'
        Save-CanonicalTrackDb -Track $track | Out-Null
        Add-WantedItemDb -TrackId $track.id | Out-Null
        $claim = Claim-WantedItemDb -TrackId $track.id -WorkerId 'w1'
        $claim.Success | Should Be $true
        $claim2 = Claim-WantedItemDb -TrackId $track.id -WorkerId 'w2'
        $claim2.Success | Should Be $false
    }

    # === CAS Tests ===

    It 'CAS succeeds with correct revision' {
        $track = New-CanonicalTrack -Title 'CAS1' -Artist 'A'
        $r1 = Save-CanonicalTrackDb -Track $track
        $r1.Success | Should Be $true
        $r1.Revision | Should Be 1
        $r2 = Save-CanonicalTrackDb -Track $track -CAS -ExpectedRevision 1
        $r2.Success | Should Be $true
        $r2.Revision | Should Be 2
    }

    It 'CAS fails with wrong revision' {
        $track = New-CanonicalTrack -Title 'CAS2' -Artist 'A'
        Save-CanonicalTrackDb -Track $track | Out-Null
        $result = Save-CanonicalTrackDb -Track $track -CAS -ExpectedRevision 999
        $result.Success | Should Be $false
        $result.Reason | Should Be 'CAS_MISMATCH'
    }

    It 'stale revision cannot overwrite CANCEL_REQUESTED' {
        $track = New-CanonicalTrack -Title 'CAS3' -Artist 'A'
        Save-CanonicalTrackDb -Track $track | Out-Null
        $wanted = Add-WantedItemDb -TrackId $track.id
        $claim = Claim-WantedItemDb -TrackId $track.id -WorkerId 'worker_a'
        $claim.Success | Should Be $true
        $wantedRev = $wanted.revision
        Request-WantedCancellationDb -TrackId $track.id | Out-Null
        $casResult = Update-WantedStateCasDb -TrackId $track.id -NewState 'RETRY_WAIT' -ExpectedRevision $wantedRev -WorkerId 'worker_a'
        $casResult.Success | Should Be $false
        $item = Get-WantedItemDb -TrackId $track.id
        $item.state | Should Be 'CANCEL_REQUESTED'
    }

    # === Worker Claim / Lease Tests ===

    It 'one worker claims item successfully' {
        $track = New-CanonicalTrack -Title 'L1' -Artist 'A'
        Save-CanonicalTrackDb -Track $track | Out-Null
        Add-WantedItemDb -TrackId $track.id | Out-Null
        $claim = Claim-WantedItemDb -TrackId $track.id -WorkerId 'worker_1'
        $claim.Success | Should Be $true
        $item = Get-WantedItemDb -TrackId $track.id
        $item.claimed_by | Should Be 'worker_1'
        $item.state | Should Be 'RESOLVING'
    }

    It 'second worker cannot claim same item' {
        $track = New-CanonicalTrack -Title 'L2' -Artist 'A'
        Save-CanonicalTrackDb -Track $track | Out-Null
        Add-WantedItemDb -TrackId $track.id | Out-Null
        $c1 = Claim-WantedItemDb -TrackId $track.id -WorkerId 'w1'
        $c1.Success | Should Be $true
        $c2 = Claim-WantedItemDb -TrackId $track.id -WorkerId 'w2'
        $c2.Success | Should Be $false
    }

    It 'expired lease is recoverable' {
        $track = New-CanonicalTrack -Title 'L3' -Artist 'A'
        Save-CanonicalTrackDb -Track $track | Out-Null
        Add-WantedItemDb -TrackId $track.id | Out-Null
        $claim = Claim-WantedItemDb -TrackId $track.id -WorkerId 'w1'
        $claim.Success | Should Be $true
        $now = Get-NowIso
        Invoke-MusicServerParamNonQuery -Template @"
UPDATE wanted_queue SET lease_expires_at = @exp WHERE track_id = @tid;
"@ -Params @{ exp = ([DateTime]::UtcNow.AddMinutes(-5)).ToString('o'); tid = $track.id }
        $recovered = Invoke-CrashRecoveryDb
        $recovered | Should Be 1
        $item = Get-WantedItemDb -TrackId $track.id
        $item.state | Should Be 'RETRY_WAIT'
        $item.last_error | Should Be 'STALE_LEASE_RECOVERY'
    }

    It 'active lease is not recovered' {
        $track = New-CanonicalTrack -Title 'L4' -Artist 'A'
        Save-CanonicalTrackDb -Track $track | Out-Null
        Add-WantedItemDb -TrackId $track.id | Out-Null
        $claim = Claim-WantedItemDb -TrackId $track.id -WorkerId 'w1'
        $claim.Success | Should Be $true
        $recovered = Invoke-CrashRecoveryDb
        $recovered | Should Be 0
        $item = Get-WantedItemDb -TrackId $track.id
        $item.state | Should Be 'RESOLVING'
    }

    It 'cancellation outranks stale lease recovery' {
        $track = New-CanonicalTrack -Title 'L5' -Artist 'A'
        Save-CanonicalTrackDb -Track $track | Out-Null
        Add-WantedItemDb -TrackId $track.id | Out-Null
        $claim = Claim-WantedItemDb -TrackId $track.id -WorkerId 'w1'
        $claim.Success | Should Be $true
        Request-WantedCancellationDb -TrackId $track.id | Out-Null
        $now = Get-NowIso
        Invoke-MusicServerParamNonQuery -Template @"
UPDATE wanted_queue SET lease_expires_at = @exp WHERE track_id = @tid;
"@ -Params @{ exp = ([DateTime]::UtcNow.AddMinutes(-5)).ToString('o'); tid = $track.id }
        $recovered = Invoke-CrashRecoveryDb
        $recovered | Should Be 1
        $item = Get-WantedItemDb -TrackId $track.id
        $item | Should Be $null
    }

    # === Provider Health Tests ===

    It 'search and download circuits are independent' {
        $h1 = Get-ProviderHealthDb -Provider 'bilibili_search'
        $h2 = Get-ProviderHealthDb -Provider 'bilibili_download'
        $h1.state | Should Be 'CLOSED'
        $h2.state | Should Be 'CLOSED'
        $h1.provider | Should Not Be $h2.provider
    }

    It 'exactly one HALF_OPEN probe allowed' {
        $health = Get-ProviderHealthDb -Provider 'bilibili_search'
        $health.state = 'OPEN'
        $health.blocked_until = ([DateTime]::UtcNow.AddMinutes(-1)).ToString('o')
        Save-ProviderHealthDb -Health $health | Out-Null
        $p1 = Claim-HalfOpenProbeDb -Provider 'bilibili_search'
        $p1 | Should Be $true
        $p2 = Claim-HalfOpenProbeDb -Provider 'bilibili_search'
        $p2 | Should Be $false
    }

    It '412 backoff sets correct state' {
        $health = Get-ProviderHealthDb -Provider 'bilibili_search'
        $health.state = 'OPEN'
        $health.consecutive_412 = 1
        $health.blocked_until = ([DateTime]::UtcNow.AddMinutes(15)).ToString('o')
        Save-ProviderHealthDb -Health $health | Out-Null
        $loaded = Get-ProviderHealthDb -Provider 'bilibili_search'
        $loaded.state | Should Be 'OPEN'
        $loaded.consecutive_412 | Should Be 1
    }

    # === Crash Recovery Tests ===

    It 'recovers stale DOWNLOADING to RETRY_WAIT' {
        $track = New-CanonicalTrack -Title 'CR1' -Artist 'A'
        Save-CanonicalTrackDb -Track $track | Out-Null
        Add-WantedItemDb -TrackId $track.id | Out-Null
        Claim-WantedItemDb -TrackId $track.id -WorkerId 'w1' | Out-Null
        Update-WantedStateCasDb -TrackId $track.id -NewState 'DOWNLOADING' -ExpectedRevision 2 -WorkerId 'w1' | Out-Null
        Invoke-MusicServerParamNonQuery -Template @"
UPDATE wanted_queue SET lease_expires_at = @exp WHERE track_id = @tid;
"@ -Params @{ exp = ([DateTime]::UtcNow.AddMinutes(-5)).ToString('o'); tid = $track.id }
        $recovered = Invoke-CrashRecoveryDb
        $recovered | Should Be 1
        $item = Get-WantedItemDb -TrackId $track.id
        $item.state | Should Be 'RETRY_WAIT'
    }

    It 'recovers stale VALIDATING to RETRY_WAIT' {
        $track = New-CanonicalTrack -Title 'CR2' -Artist 'A'
        Save-CanonicalTrackDb -Track $track | Out-Null
        Add-WantedItemDb -TrackId $track.id | Out-Null
        Claim-WantedItemDb -TrackId $track.id -WorkerId 'w1' | Out-Null
        Update-WantedStateCasDb -TrackId $track.id -NewState 'DOWNLOADING' -ExpectedRevision 2 -WorkerId 'w1' | Out-Null
        Update-WantedStateCasDb -TrackId $track.id -NewState 'VALIDATING' -ExpectedRevision 3 -WorkerId 'w1' | Out-Null
        Invoke-MusicServerParamNonQuery -Template @"
UPDATE wanted_queue SET lease_expires_at = @exp WHERE track_id = @tid;
"@ -Params @{ exp = ([DateTime]::UtcNow.AddMinutes(-5)).ToString('o'); tid = $track.id }
        $recovered = Invoke-CrashRecoveryDb
        $recovered | Should Be 1
        $item = Get-WantedItemDb -TrackId $track.id
        $item.state | Should Be 'RETRY_WAIT'
    }

    # === Encoding / SQL Safety Tests ===

    It 'handles Chinese title round-trip' {
        $track = New-CanonicalTrack -Title '吹灭小山河' -Artist '国风堂,司南'
        Save-CanonicalTrackDb -Track $track | Out-Null
        $loaded = Get-CanonicalTrackDb -TrackId $track.id
        $loaded.title | Should Be '吹灭小山河'
        $loaded.artist | Should Be '国风堂,司南'
    }

    It 'handles Japanese title round-trip' {
        $track = New-CanonicalTrack -Title '妄想感傷代償連盟' -Artist 'DECO*27,初音ミク'
        Save-CanonicalTrackDb -Track $track | Out-Null
        $loaded = Get-CanonicalTrackDb -TrackId $track.id
        $loaded.title | Should Be '妄想感傷代償連盟'
    }

    It 'handles apostrophe in title' {
        $track = New-CanonicalTrack -Title "Don't Stop Me Now" -Artist "Queen"
        Save-CanonicalTrackDb -Track $track | Out-Null
        $loaded = Get-CanonicalTrackDb -TrackId $track.id
        $loaded.title | Should Be "Don't Stop Me Now"
    }

    It 'handles double-quote in artist' {
        $track = New-CanonicalTrack -Title 'Test' -Artist 'Artist "Special" Name'
        Save-CanonicalTrackDb -Track $track | Out-Null
        $loaded = Get-CanonicalTrackDb -TrackId $track.id
        $loaded.artist | Should Be 'Artist "Special" Name'
    }

    # === Events Test ===

    It 'writes and reads events' {
        Write-MusicServerEventDb -EventType 'TEST_EVENT' -TrackId 'track_test' -Message 'test message'
        $events = @(Get-EventsDb -TrackId 'track_test')
        $events.Count | Should Be 1
        $events[0].event_type | Should Be 'TEST_EVENT'
    }

    # === Schema Version Test ===

    It 'sets and reads schema version' {
        Set-SchemaVersion -Version 1
        $v = Get-SchemaVersion
        $v | Should Be 1
    }

    # === DB Stats Test ===

    It 'reports correct DB stats' {
        $track = New-CanonicalTrack -Title 'Stats' -Artist 'A'
        Save-CanonicalTrackDb -Track $track | Out-Null
        $stats = Get-DbStats
        $stats.canonical_tracks | Should Be 1
    }
}
