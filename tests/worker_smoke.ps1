# Worker runtime smoke test. Scratch root only; never touches real state.
# Seeds one WANTED track, runs the real wanted_worker.ps1 -Once against the scratch root,
# then inspects scratch DB (want_ed_queue) + legacy JSON.
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$testroot = Join-Path ([IO.Path]::GetTempPath()) ('musicserver_smoke_' + [guid]::NewGuid().ToString('N'))
$log = Join-Path $testroot 'worker_smoke.txt'
$sqlite = (Get-Command sqlite3.exe -ErrorAction Stop).Source
$lines = @()

function Run-Step([string]$name, [string]$script) {
    $scriptFile = Join-Path $testroot ($name + '.ps1')
    $outFile = Join-Path $testroot ($name + '_out.txt')
    $errFile = Join-Path $testroot ($name + '_err.txt')
    Set-Content -LiteralPath $scriptFile -Value $script -Encoding UTF8
    $arglist = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $scriptFile)
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $arglist -Wait -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    $outText = (Get-Content $outFile -Raw -ErrorAction SilentlyContinue)
    $errText = (Get-Content $errFile -Raw -ErrorAction SilentlyContinue)
    Write-Host ("[{0}] exit={1}" -f $name, $p.ExitCode)
    Write-Host ($outText)
    if ($errText) { Write-Host ("STDERR: " + $errText) }
}

# fresh scratch root
if (Test-Path $testroot) { Remove-Item -Recurse -Force $testroot -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Path $testroot -Force | Out-Null

# 1) Seed one WANTED track in the scratch root legacy queue
$seed = @'
$ErrorActionPreference = 'Stop'
Import-Module '__ROOT__\MusicServer.Core.psm1' -Force
$cfg = New-MusicServerConfig -Root '__ROOT__' -AppHome '__TESTROOT__'
$null = Initialize-MusicServerState -Config $cfg
$w = Add-WantedTrack -Config $cfg -TrackId 'smk-1234'
"SEEDED id={0} state={1}" -f $w.id, $w.state
'@.Replace('__ROOT__', $root).Replace('__TESTROOT__', $testroot)
Run-Step 'seed' $seed

# 2) Run the real worker once against the scratch root
$worker = @'
$ErrorActionPreference = 'Continue'
$env:MUSICSERVER_APP_HOME = '__TESTROOT__'
& '__ROOT__\wanted_worker.ps1' -Once -Root '__ROOT__'
"WORKER_EXIT=$LASTEXITCODE"
'@.Replace('__ROOT__', $root).Replace('__TESTROOT__', $testroot)
Run-Step 'worker' $worker

# 3) Inspect scratch DB + legacy JSON
$inspect = @'
Import-Module '__ROOT__\MusicServer.State.psm1' -Force
$null = Initialize-MusicServerDatabase -DbPath '__DBPATH__' -SqliteExe '__SQLITE__'
try { $row = Get-WantedItemDb -TrackId 'smk-1234'; "DB id={0} state={1} claimed_by={2} rev={3} err={4}" -f $row.id, $row.state, $row.claimed_by, $row.revision, $row.last_error } catch { "DB_ERR: $($_.Exception.Message)" }
Import-Module '__ROOT__\MusicServer.Core.psm1' -Force
$cfg = New-MusicServerConfig -Root '__ROOT__' -AppHome '__TESTROOT__'
$leg = @(Get-WantedTracks -Config $cfg -EligibleOnly)
"LEGACY eligible={0}" -f $leg.Count
foreach ($i in $leg) { "LEGACY {0} {1} {2}" -f $i.id, $i.state, $i.track_id }
'@.Replace('__ROOT__', $root).Replace('__TESTROOT__', $testroot).Replace('__DBPATH__', (Join-Path $testroot 'DailyMix_data\state\musicserver.db')).Replace('__SQLITE__', $sqlite)
Run-Step 'inspect' $inspect
