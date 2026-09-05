<#
.SYNOPSIS
    Measure isolated PS5.1 UI/API services before backend optimization.
.DESCRIPTION
    Uses synthetic 0/1000/10000-track metadata and one shared silent WAV. No
    downloader or live Navidrome process is started. The fixture is intentionally
    a metadata benchmark, not a measurement of scanning 10000 distinct files.
    Measures service readiness, HTTP latency, state sqlite3 process counts and
    server process-tree resources. Tauri rendering/search need separate APP
    measurements and are explicitly unmeasured in the report.
#>
[CmdletBinding()]
param(
    [ValidateRange(0, 100000)][int[]]$TrackCounts = @(0, 1000, 10000),
    [ValidateRange(1, 1000)][int]$Samples = 30,
    [ValidateRange(1, 100)][int]$StartupRuns = 5,
    [string]$OutputDirectory = '',
    [switch]$KeepFixtures
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $projectRoot 'tests\MusicServer.RuntimeFixture.ps1')
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $projectRoot 'artifacts\performance' }
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
$artifactRoot = [IO.Path]::GetFullPath((Join-Path $projectRoot 'artifacts'))
if ($outputRoot -ne $artifactRoot -and -not $outputRoot.StartsWith($artifactRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Performance output must remain under this checkout artifacts directory.'
}
$runRoot = Join-Path $outputRoot ('backend_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $runRoot -Force | Out-Null

function Get-MeasurementSummary {
    param([double[]]$Values)
    $sorted = @($Values | Sort-Object)
    if (-not $sorted.Count) { return $null }
    return [ordered]@{
        count = $sorted.Count
        min = [Math]::Round($sorted[0], 2)
        p50 = [Math]::Round($sorted[[Math]::Max(0, [Math]::Ceiling($sorted.Count * 0.50) - 1)], 2)
        p95 = [Math]::Round($sorted[[Math]::Max(0, [Math]::Ceiling($sorted.Count * 0.95) - 1)], 2)
        max = [Math]::Round($sorted[-1], 2)
    }
}

function Initialize-MeasurementLibrary {
    param($Fixture, [int]$TrackCount)
    if ($TrackCount -eq 0) { return }
    # 1 second, mono PCM, 8 kHz / 16 bit. Many metadata rows intentionally share
    # this one file so this experiment isolates metadata/response assembly cost.
    $wavePath = Join-Path $Fixture.Config.MusicDir 'fixture.wav'
    $file = [IO.File]::Create($wavePath)
    $writer = New-Object IO.BinaryWriter($file)
    try {
        $writer.Write([Text.Encoding]::ASCII.GetBytes('RIFF')); $writer.Write([int]16036)
        $writer.Write([Text.Encoding]::ASCII.GetBytes('WAVEfmt ')); $writer.Write([int]16)
        $writer.Write([int16]1); $writer.Write([int16]1); $writer.Write([int]8000); $writer.Write([int]16000)
        $writer.Write([int16]2); $writer.Write([int16]16)
        $writer.Write([Text.Encoding]::ASCII.GetBytes('data')); $writer.Write([int]16000)
        $writer.Write((New-Object byte[] 16000))
    } finally { $writer.Dispose() }
    $recCount = [Math]::Min(25, $TrackCount)
    $date = ConvertTo-MusicServerSqlLiteral (Get-TodayDate)
    Invoke-MusicServerSqlNonQuery -Query @"
BEGIN;
WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x < $TrackCount)
INSERT INTO canonical_tracks(id,title,artist,album,status) SELECT 'fixture_'||x, 'Fixture Track '||x, 'Fixture Artist', 'Fixture Album', 'REMOTE' FROM n;
INSERT INTO daily_recommendations(date,rank,rec_id,track_id,title,artist,created_at)
SELECT $date, rowid, 'rec_'||id, id, title, artist, $date FROM canonical_tracks ORDER BY rowid LIMIT $recCount;
COMMIT;
"@
    New-Item -ItemType Directory -Path (Split-Path -Parent $Fixture.Config.NdDb) -Force | Out-Null
    $waveLiteral = ConvertTo-MusicServerSqlLiteral $wavePath
    $navSql = @"
CREATE TABLE media_file(id TEXT PRIMARY KEY,title TEXT,artist TEXT,album TEXT,path TEXT,duration REAL,track_number INTEGER,created_at TEXT,updated_at TEXT,missing INTEGER);
WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x < $TrackCount)
INSERT INTO media_file SELECT 'fixture-'||x, 'Fixture Track '||x, 'Fixture Artist', 'Fixture Album', $waveLiteral, 1, x, $date, $date, 0 FROM n;
"@
    $sqlPath = Join-Path $Fixture.Root 'seed.sql'
    [IO.File]::WriteAllText($sqlPath, $navSql, (New-Object Text.UTF8Encoding($false)))
    & $Fixture.Config.Sqlite -bail $Fixture.Config.NdDb ('.read "' + $sqlPath.Replace('\','/') + '"')
    if ($LASTEXITCODE -ne 0) { throw 'Synthetic Navidrome metadata initialization failed.' }
}

function Get-ServerResourceSnapshot {
    param($Fixture)
    $ids = @($Fixture.Processes | ForEach-Object { $_.Id })
    $all = @(Get-CimInstance Win32_Process)
    do {
        $oldCount = $ids.Count
        $ids = @($ids + @($all | Where-Object { $ids -contains [int]$_.ParentProcessId } | ForEach-Object { [int]$_.ProcessId }) | Select-Object -Unique)
    } while ($ids.Count -gt $oldCount)
    $processes = @(Get-Process -Id $ids -ErrorAction SilentlyContinue)
    return [ordered]@{
        process_count = $processes.Count
        working_set_bytes = ($processes | Measure-Object -Property WorkingSet64 -Sum).Sum
        cpu_seconds_since_process_start = ($processes | Measure-Object -Property CPU -Sum).Sum
    }
}

$results = New-Object Collections.ArrayList
$samplesRaw = New-Object Collections.ArrayList
$diagnosticsBefore = $env:MUSICSERVER_DIAGNOSTICS
try {
    $env:MUSICSERVER_DIAGNOSTICS = '1'
    foreach ($trackCount in $TrackCounts) {
        $fixture = $null
        try {
            $fixture = New-MusicServerRuntimeFixture -ProjectRoot $projectRoot -Parent $runRoot
            Initialize-MeasurementLibrary -Fixture $fixture -TrackCount $trackCount
            $startup = @()
            $measurements = New-Object Collections.ArrayList
            $resources = @()
            for ($run = 1; $run -le $StartupRuns; $run++) {
                Start-MusicServerFixtureServices -Fixture $fixture -WithUi
                $startup += $fixture.StartupMs
                $base = "http://127.0.0.1:$($fixture.UiPort)"
                foreach ($path in @('/api/recommendations/today', '/api/library', '/api/listening/stats', '/health')) {
                    # One first request per fresh service process; warm samples
                    # only in run 1. Raw rows retain run and cache phase labels.
                    $iterations = if ($run -eq 1) { $Samples + 1 } else { 1 }
                    for ($sample = 0; $sample -lt $iterations; $sample++) {
                        Invoke-WebRequest -UseBasicParsing -Uri ($base + '/ui/heartbeat?id=performance') -Method POST -Body '' -TimeoutSec 5 | Out-Null
                        $timer = [Diagnostics.Stopwatch]::StartNew()
                        $response = Invoke-WebRequest -UseBasicParsing -Uri ($base + $path) -TimeoutSec 120
                        $elapsed = $timer.Elapsed.TotalMilliseconds
                        $calls = $response.Headers['X-MusicServer-State-Sqlite-Calls']
                        $row = [pscustomobject]@{
                            tracks = $trackCount; run = $run; path = $path
                            phase = if ($sample -eq 0) { 'first_request' } else { 'warm' }
                            elapsed_ms = [Math]::Round($elapsed, 2)
                            state_sqlite_calls = if ($null -ne $calls) { [int]$calls } else { $null }
                            response_bytes = $response.RawContentLength
                        }
                        [void]$measurements.Add($row)
                        [void]$samplesRaw.Add($row)
                    }
                }
                $resources += Get-ServerResourceSnapshot -Fixture $fixture
                Stop-MusicServerFixtureServices -Fixture $fixture
                Write-Host "Measured metadata=$trackCount startup=$run/$StartupRuns"
            }
            $endpoints = @($measurements | Group-Object path,phase | ForEach-Object {
                $group = @($_.Group)
                [ordered]@{
                    path = $group[0].path; phase = $group[0].phase
                    latency_ms = Get-MeasurementSummary -Values @($group | ForEach-Object { $_.elapsed_ms })
                    state_sqlite_calls = if (@($group | Where-Object { $null -ne $_.state_sqlite_calls }).Count) { Get-MeasurementSummary -Values @($group | Where-Object { $null -ne $_.state_sqlite_calls } | ForEach-Object { $_.state_sqlite_calls }) } else { $null }
                }
            })
            [void]$results.Add([ordered]@{ tracks = $trackCount; service_startup_ms = Get-MeasurementSummary $startup; endpoints = $endpoints; resources = $resources })
        } finally {
            if ($fixture) {
                if ($KeepFixtures) { Stop-MusicServerFixtureServices -Fixture $fixture }
                else { Remove-MusicServerRuntimeFixture -Fixture $fixture }
            }
        }
    }
} finally {
    $env:MUSICSERVER_DIAGNOSTICS = $diagnosticsBefore
    $samplesRaw | Export-Csv -LiteralPath (Join-Path $runRoot 'samples.csv') -NoTypeInformation -Encoding UTF8
}
$report = [ordered]@{
    measured_utc = [DateTime]::UtcNow.ToString('o')
    source_commit = [string](& git -C $projectRoot rev-parse HEAD)
    working_tree_dirty = [bool](@(& git -C $projectRoot status --porcelain).Count)
    powershell = $PSVersionTable.PSVersion.ToString()
    os = [Environment]::OSVersion.VersionString
    logical_processors = [Environment]::ProcessorCount
    samples = $Samples; startup_runs = $StartupRuns
    scope = 'PS5.1 service readiness + HTTP via UI proxy; synthetic metadata shares one silent WAV; downloader omitted'
    unmeasured = @('Tauri window readiness', 'WebView2 rendering/search latency', 'distinct-file directory scan cost')
    scenarios = @($results)
}
$reportPath = Join-Path $runRoot 'report.json'
[IO.File]::WriteAllText($reportPath, ($report | ConvertTo-Json -Depth 12), (New-Object Text.UTF8Encoding($false)))
Write-Output $reportPath
