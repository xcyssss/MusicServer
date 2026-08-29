# Worker runtime smoke test. Scratch root only; never touches real state.
# Seeds one WANTED track, runs the real wanted_worker.ps1 -Once against the scratch root,
# then inspects scratch DB (want_ed_queue) + legacy JSON.
$ErrorActionPreference = 'Continue'
$root = 'E:\Project\MusicServer'
$testroot = Join-Path $root 'tests\smoke_root'
$log = Join-Path $root 'tests\worker_smoke.txt'
$sqlite = 'C:\Users\dell\anaconda3\Library\bin\sqlite3.exe'
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
Import-Module 'E:\Project\MusicServer\MusicServer.Core.psm1' -Force
$cfg = New-MusicServerConfig -Root 'E:\Project\MusicServer\tests\smoke_root'
$null = Initialize-MusicServerState -Config $cfg
$w = Add-WantedTrack -Config $cfg -TrackId 'smk-1234'
"SEEDED id={0} state={1}" -f $w.id, $w.state
'@
Run-Step 'seed' $seed

# 2) Run the real worker once against the scratch root
$worker = @'
$ErrorActionPreference = 'Continue'
& 'E:\Project\MusicServer\wanted_worker.ps1' -Once -Root 'E:\Project\MusicServer\tests\smoke_root'
"WORKER_EXIT=$LASTEXITCODE"
'@
Run-Step 'worker' $worker

# 3) Inspect scratch DB + legacy JSON
$inspect = @'
Import-Module 'E:\Project\MusicServer\MusicServer.State.psm1' -Force
$null = Initialize-MusicServerDatabase -DbPath 'E:\Project\MusicServer\tests\smoke_root\DailyMix_data\state\musicserver.db' -SqliteExe 'C:\Users\dell\anaconda3\Library\bin\sqlite3.exe'
try { $row = Get-WantedItemDb -TrackId 'smk-1234'; "DB id={0} state={1} claimed_by={2} rev={3} err={4}" -f $row.id, $row.state, $row.claimed_by, $row.revision, $row.last_error } catch { "DB_ERR: $($_.Exception.Message)" }
Import-Module 'E:\Project\MusicServer\MusicServer.Core.psm1' -Force
$cfg = New-MusicServerConfig -Root 'E:\Project\MusicServer\tests\smoke_root'
$leg = @(Get-WantedTracks -Config $cfg -EligibleOnly)
"LEGACY eligible={0}" -f $leg.Count
foreach ($i in $leg) { "LEGACY {0} {1} {2}" -f $i.id, $i.state, $i.track_id }
'@
Run-Step 'inspect' $inspect
