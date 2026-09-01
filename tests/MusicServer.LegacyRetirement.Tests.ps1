<#
    Hardening v2 Phase 5 legacy runtime retirement tests.

    These tests use a fresh scratch root and exercise the real worker process
    against SQLite state while deliberately disagreeing legacy JSON state.
#>

$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $ProjectRoot 'MusicServer.Core.psm1') -Force
Import-Module (Join-Path $ProjectRoot 'MusicServer.Database.psm1') -Force
Import-Module (Join-Path $ProjectRoot 'MusicServer.State.psm1') -Force
Import-Module (Join-Path $ProjectRoot 'MusicServer.Migration.psm1') -Force

function New-LegacyRetirementScratch {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('musicserver_legacy_retirement_' + [guid]::NewGuid().ToString('N'))
    $config = New-MusicServerConfig -Root $root
    Initialize-MusicServerState -Config $config
    $db = Join-Path $config.StateDir 'musicserver.db'
    Initialize-MusicServerDatabase -DbPath $db -SqliteExe $config.Sqlite
    Initialize-MusicServerSchema
    return [pscustomobject]@{ Root = $root; Config = $config }
}

function Invoke-LegacyRetirementWorker {
    param([Parameter(Mandatory)][string]$Root, [switch]$DryRun)
    $worker = Join-Path $ProjectRoot 'wanted_worker.ps1'
    $output = Join-Path $Root 'worker.stdout.log'
    $error = Join-Path $Root 'worker.stderr.log'
    $args = @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$worker,'-Once')
    if ($DryRun) { $args += '-DryRun' }
    $args += @('-Root',$Root)
    $shell = if ($PSVersionTable.PSEdition -eq 'Core') { Get-Command pwsh -ErrorAction Stop } else { Get-Command powershell.exe -ErrorAction Stop }
    $process = Start-Process -FilePath $shell.Source `
        -ArgumentList $args -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $output -RedirectStandardError $error
    $stdout = if (Test-Path -LiteralPath $output) { Get-Content -LiteralPath $output -Raw -Encoding UTF8 } else { '' }
    $stderr = if (Test-Path -LiteralPath $error) { Get-Content -LiteralPath $error -Raw -Encoding UTF8 } else { '' }
    return [pscustomobject]@{ ExitCode = $process.ExitCode; Stdout = $stdout; Stderr = $stderr }
}

Describe 'MusicServer Hardening v2 - Legacy Runtime Retirement' {
    It 'worker source contains no legacy runtime state reads' {
        $source = Get-Content -LiteralPath (Join-Path $ProjectRoot 'wanted_worker.ps1') -Raw
        $source | Should Not Match 'Import-LegacyRecommendationState|Get-WantedTracks\s+-Config|Get-CanonicalTrack\s+-Config|Set-TrackStatus\s+-Config|Reset-TrackToRemote\s+-Config|Save-WantedTrack\s+-Config|Remove-WantedTrack\s+-Config|Write-StructuredEvent\s+-Config'
        $source | Should Match 'Get-WantedTracksDb|Get-WantedItemDb|Get-CanonicalTrackDb|Write-MusicServerEventDb'
    }

    It 'provider source contains no JSON health state reads' {
        $source = Get-Content -LiteralPath (Join-Path $ProjectRoot 'MusicServer.Providers.psm1') -Raw
        $source | Should Not Match 'Read-StateCollection|Write-StateCollection'
        $source | Should Match 'Get-ProviderHealthDb|Save-ProviderHealthDb'
    }

    It 'cleanup source contains no legacy CSV state reads' {
        $source = Get-Content -LiteralPath (Join-Path $ProjectRoot 'daily_cleanup.ps1') -Raw
        $source | Should Not Match 'Import-Csv|ConvertFrom-Json|Get-Content\s+[^\r\n]*\.json'
        $source | Should Match 'Get-RecommendationFeedbackDb|Get-RecommendationFileDb'
    }

    It 'worker ignores stale JSON WANTED when SQLite has no wanted row' {
        $scratch = New-LegacyRetirementScratch
        try {
            $track = New-CanonicalTrack -Title 'SQLite Remote Wins' -Artist 'Phase5' -Status 'REMOTE'
            Save-CanonicalTrackDb -Track $track | Out-Null
            Write-StateCollection -Config $scratch.Config -Name tracks -Items @($track)
            Write-StateCollection -Config $scratch.Config -Name wanted -Items @([pscustomobject]@{
                    id = 'legacy_wanted'; track_id = $track.id; state = 'WANTED'; attempts = 0; max_attempts = 5
                    next_retry_at = $null; selected_candidate = $null; last_error = ''; created_at = Get-NowIso; updated_at = Get-NowIso
                })

            $result = Invoke-LegacyRetirementWorker -Root $scratch.Root -DryRun

            $result.ExitCode | Should Be 0
            $result.Stdout | Should Match 'Wanted Queue.*为空'
            (Get-WantedItemDb -TrackId $track.id) | Should Be $null
        } finally {
            if (Test-Path -LiteralPath $scratch.Root) {
                Remove-Item -LiteralPath $scratch.Root -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'worker honors SQLite CANCEL_REQUESTED over JSON RESOLVING' {
        $scratch = New-LegacyRetirementScratch
        try {
            $track = New-CanonicalTrack -Title 'SQLite Cancellation Wins' -Artist 'Phase5' -Status 'REMOTE'
            Save-CanonicalTrackDb -Track $track | Out-Null
            $wanted = Add-WantedItemDb -TrackId $track.id
            Claim-WantedItemDb -TrackId $track.id -WorkerId 'phase5_test_worker' | Out-Null
            Request-WantedCancellationDb -TrackId $track.id | Out-Null
            Write-StateCollection -Config $scratch.Config -Name tracks -Items @($track)
            Write-StateCollection -Config $scratch.Config -Name wanted -Items @([pscustomobject]@{
                    id = $wanted.wanted_id; track_id = $track.id; state = 'RESOLVING'; attempts = 0; max_attempts = 5
                    next_retry_at = $null; selected_candidate = $null; last_error = ''; created_at = Get-NowIso; updated_at = Get-NowIso
                })

            $result = Invoke-LegacyRetirementWorker -Root $scratch.Root -DryRun

            $result.ExitCode | Should Be 0
            (Get-WantedItemDb -TrackId $track.id) | Should Be $null
            (Get-CanonicalTrackDb -TrackId $track.id).status | Should Be 'REMOTE'
        } finally {
            if (Test-Path -LiteralPath $scratch.Root) {
                Remove-Item -LiteralPath $scratch.Root -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'worker honors SQLite WANTED when legacy JSON has no wanted row' {
        $scratch = New-LegacyRetirementScratch
        try {
            $track = New-CanonicalTrack -Title 'SQLite Wanted Wins' -Artist 'Phase5' -Status 'REMOTE'
            Save-CanonicalTrackDb -Track $track | Out-Null
            Add-WantedItemDb -TrackId $track.id | Out-Null
            Write-StateCollection -Config $scratch.Config -Name tracks -Items @($track)
            Write-StateCollection -Config $scratch.Config -Name wanted -Items @()

            $result = Invoke-LegacyRetirementWorker -Root $scratch.Root -DryRun

            $result.ExitCode | Should Be 0
            $result.Stdout | Should Match '处理 Wanted Queue：1 条'
            (Get-WantedItemDb -TrackId $track.id).state | Should Be 'RESOLVING'
        } finally {
            if (Test-Path -LiteralPath $scratch.Root) {
                Remove-Item -LiteralPath $scratch.Root -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'worker does not retry SQLite UNAVAILABLE when JSON says RETRY_WAIT' {
        $scratch = New-LegacyRetirementScratch
        try {
            $track = New-CanonicalTrack -Title 'SQLite Terminal Wins' -Artist 'Phase5' -Status 'UNAVAILABLE'
            Save-CanonicalTrackDb -Track $track | Out-Null
            $wanted = Add-WantedItemDb -TrackId $track.id | Out-Null
            Invoke-MusicServerParamNonQuery -Template "UPDATE wanted_queue SET state = 'UNAVAILABLE', last_error = 'TERMINAL', revision = revision + 1 WHERE track_id = @tid;" -Params @{ tid = $track.id } | Out-Null
            Write-StateCollection -Config $scratch.Config -Name tracks -Items @($track)
            Write-StateCollection -Config $scratch.Config -Name wanted -Items @([pscustomobject]@{
                    id = 'legacy_wanted'; track_id = $track.id; state = 'RETRY_WAIT'; attempts = 3; max_attempts = 5
                    next_retry_at = Get-NowIso; selected_candidate = $null; last_error = ''; created_at = Get-NowIso; updated_at = Get-NowIso
                })

            $result = Invoke-LegacyRetirementWorker -Root $scratch.Root -DryRun

            $result.ExitCode | Should Be 0
            $result.Stdout | Should Match 'Wanted Queue.*为空'
            (Get-WantedItemDb -TrackId $track.id).state | Should Be 'UNAVAILABLE'
            (Get-CanonicalTrackDb -TrackId $track.id).status | Should Be 'UNAVAILABLE'
        } finally {
            if (Test-Path -LiteralPath $scratch.Root) {
                Remove-Item -LiteralPath $scratch.Root -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'persists retry increments in SQLite attempt_count' {
        $scratch = New-LegacyRetirementScratch
        try {
            $track = New-CanonicalTrack -Title 'Retry Counter' -Artist 'Phase5' -Status 'REMOTE' -DownloadCandidates @()
            Save-CanonicalTrackDb -Track $track | Out-Null
            Add-WantedItemDb -TrackId $track.id -MaxAttempts 3 | Out-Null
            $blockedUntil = [DateTime]::UtcNow.AddMinutes(5).ToString('o')
            foreach ($provider in @('bilibili_search', 'bilibili_download')) {
                $health = Get-ProviderHealthDb -Provider $provider
                $health.state = 'OPEN'
                $health.blocked_until = $blockedUntil
                Save-ProviderHealthDb -Health $health | Out-Null
            }

            $result = Invoke-LegacyRetirementWorker -Root $scratch.Root

            $result.ExitCode | Should Be 0
            $wanted = Get-WantedItemDb -TrackId $track.id
            $wanted.state | Should Be 'RETRY_WAIT'
            $wanted.attempt_count | Should Be 1
            $wanted.attempts | Should Be 1
        } finally {
            if (Test-Path -LiteralPath $scratch.Root) {
                Remove-Item -LiteralPath $scratch.Root -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'migration classifies conflicts and remains idempotent on a fresh rehearsal' {
        $scratch = New-LegacyRetirementScratch
        try {
            $track = New-CanonicalTrack -Title 'Migration Rehearsal' -Artist 'Phase5' -Status 'LOCAL'
            $track.local_song_id = 'existing-local'
            Save-CanonicalTrackDb -Track $track | Out-Null
            Write-StateCollection -Config $scratch.Config -Name tracks -Items @(
                [pscustomobject]@{
                    id = $track.id; title = $track.title; artist = $track.artist; album = ''
                    duration = 0; cover_url = ''; identifiers = @(); preview_sources = @()
                    download_candidates = @(); local_song_id = ''; status = 'REMOTE'
                    created_at = Get-NowIso; updated_at = Get-NowIso
                },
                [pscustomobject]@{ title = ''; artist = '' }
            )
            Write-StateCollection -Config $scratch.Config -Name recommendations -Items @([pscustomobject]@{
                    id = 'legacy-rec'; date = '2026-08-30'; rank = 1; track_id = $track.id
                    title = $track.title; artist = $track.artist; netease_id = '12345'; liked = $false
                })
            Write-StateCollection -Config $scratch.Config -Name providers -Items @([pscustomobject]@{
                    provider = 'bilibili'; state = 'HALF_OPEN'; success_count = 0; failure_count = 1
                    consecutive_failures = 1; consecutive_412 = 1; probe_pending = $true
                })

            $first = Invoke-MusicServerMigration -Config $scratch.Config
            $second = Invoke-MusicServerMigration -Config $scratch.Config

            $first.status | Should Be 'SUCCESS'
            $second.status | Should Be 'ALREADY_MIGRATED'
            $second.idempotent | Should Be $true
            @('SAFE_IDEMPOTENT','EXPECTED_LEGACY_OVERLAP','STALE_LEGACY','IDENTITY_AMBIGUITY','SEMANTIC_CONFLICT','MALFORMED') | ForEach-Object {
                $first.conflict_categories.Contains($_) | Should Be $true
            }
            $first.conflict_categories['STALE_LEGACY'] | Should BeGreaterThan 0
            $first.skipped_categories.Contains('MALFORMED') | Should Be $true
            (Get-CanonicalTrackDb -TrackId $track.id).status | Should Be 'LOCAL'
            (Get-CanonicalTrackDb -TrackId $track.id).local_song_id | Should Be 'existing-local'
            @(Get-RecommendationFeedbackDb -TrackId $track.id).Count | Should Be 1
            @(Invoke-MusicServerParamSql -Template 'SELECT provider FROM provider_health WHERE provider = @provider;' -Params @{ provider = 'bilibili' }).Count | Should Be 0
            ($first.legacy_ignored -join "`n") | Should Match 'legacy provider: bilibili.*ignored'
        } finally {
            if (Test-Path -LiteralPath $scratch.Root) {
                Remove-Item -LiteralPath $scratch.Root -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
