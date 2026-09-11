# Runs the CI test groups the way CI runs them: the `state` and `api` groups in
# PARALLEL, each suite bounded on its own.
#
# Why this file exists
# --------------------
# AGENTS.md forbids a serial full-suite pass, but for a long time the only
# convenient thing to reach for was a hand-written loop over every suite. That
# loop is exactly the hour-class job the rule warns about, so agents kept
# rebuilding it. This is the supported alternative: two groups side by side, every
# suite inside a group bounded by tests/run_suite.ps1, and the whole run bounded
# again here.
#
# Each group is one job; inside a group the suites run one at a time, because the
# api suites bind real HTTP ports and starting them concurrently would make the
# run flaky rather than fast. Two groups in parallel is what CI does.
#
# Progress is printed as it happens (a polling tail over each group's progress
# file), so a stuck suite is visible instead of being hidden until the pipeline
# ends.
param(
    [string[]]$StateSuites = @('Core', 'Database', 'V2', 'WorkerConcurrency', 'Recommendation', 'LegacyRetirement', 'Listening', 'Web', 'Tauri', 'ConfigurableLibrary', 'TestRunner', 'Identity'),
    [string[]]$ApiSuites = @('Http', 'UiProxyRuntime', 'MediaRuntime', 'ApiTransaction', 'ApiRuntime'),
    [int]$SuiteTimeoutSeconds = 300,
    [int]$GroupTimeoutSeconds = 900,
    [string]$LogDir = '',
    [string[]]$ExcludeTag = @('RequiresLocalRuntime')
)
$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$runner = Join-Path $PSScriptRoot 'run_suite.ps1'
if (-not $LogDir) { $LogDir = Join-Path $ProjectRoot 'artifacts\groups' }
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
# Absolute from here on. A background job runs in its own working directory, so a
# relative path the parent creates and then polls is not the path the job writes.
$LogDir = [IO.Path]::GetFullPath($LogDir)

# `powershell.exe -File script.ps1 -StateSuites Database,Identity` hands over ONE
# string, so split on commas rather than looking for a suite literally named
# "Database,Identity" and reporting a bogus all-clear.
$groups = [ordered]@{
    state = @($StateSuites | ForEach-Object { [string]$_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    api   = @($ApiSuites | ForEach-Object { [string]$_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
$ExcludeTag = @($ExcludeTag | ForEach-Object { [string]$_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

Write-Host "Parallel groups: $($groups.Keys -join ' + ')  (per-suite ${SuiteTimeoutSeconds}s, group ${GroupTimeoutSeconds}s)"
foreach ($name in $groups.Keys) { Write-Host ("  {0,-6} {1} suites" -f $name, @($groups[$name]).Count) }

# Each job appends one line per finished suite so the parent can show progress
# without waiting for the group to end. Format: suite|exit|passed|failed|total
#
# The job receives ONE hashtable: -ArgumentList unrolls arrays, so passing the
# suite list and the tag list as separate arguments silently shifted every
# parameter after them and killed both jobs at startup.
$jobs = @{}
$progressFiles = @{}
foreach ($name in $groups.Keys) {
    $progressFiles[$name] = Join-Path $LogDir "$name.progress"
    Remove-Item -LiteralPath $progressFiles[$name] -Force -ErrorAction SilentlyContinue
    $spec = @{
        GroupName    = $name
        Suites       = @($groups[$name])
        Root         = $ProjectRoot
        Runner       = $runner
        ProgressFile = $progressFiles[$name]
        Timeouts     = $SuiteTimeoutSeconds
        Tags         = @($ExcludeTag)
        Dir          = $LogDir
    }
    $jobs[$name] = Start-Job -ScriptBlock {
        param($Spec)
        $GroupName = $Spec.GroupName
        foreach ($suite in @($Spec.Suites)) {
            $suitePath = Join-Path $Spec.Root "tests\MusicServer.$suite.Tests.ps1"
            if (-not (Test-Path -LiteralPath $suitePath)) {
                Add-Content -LiteralPath $Spec.ProgressFile -Value "$suite|2|0|0|0|missing" -Encoding UTF8
                continue
            }
            $log = Join-Path $Spec.Dir "$GroupName-$suite.log"
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Spec.Runner -SuiteFile $suitePath -LogFile $log -TimeoutSeconds $Spec.Timeouts -ExcludeTag $Spec.Tags *> (Join-Path $Spec.Dir "$GroupName-$suite.stdout.log")
            $code = $LASTEXITCODE
            $passed = 0; $failed = 0
            $summary = (Get-Content -LiteralPath $log -Encoding UTF8 -ErrorAction SilentlyContinue | Select-String -Pattern '^Passed:\s*(\d+)\s+Failed:\s*(\d+)\s+Total:\s*(\d+)' | Select-Object -First 1)
            if ($summary) { $passed = [int]$summary.Matches[0].Groups[1].Value; $failed = [int]$summary.Matches[0].Groups[2].Value }
            Add-Content -LiteralPath $Spec.ProgressFile -Value "$suite|$code|$passed|$failed|0|" -Encoding UTF8
        }
    } -ArgumentList $spec
}

$seen = @{}
foreach ($name in $groups.Keys) { $seen[$name] = 0 }
$totals = @{}
foreach ($name in $groups.Keys) { $totals[$name] = [pscustomobject]@{ Passed = 0; Failed = 0; Timeouts = 0; RunnerErrors = 0; Missing = 0; Verdict = 'running' } }
$deadline = [DateTime]::UtcNow.AddSeconds($GroupTimeoutSeconds)
$timedOut = $false

# Pulls any progress lines written since the last read. Called from the polling
# loop and once more after it ends: a line written between the final poll and the
# stop would otherwise be missing from the totals, and a group whose suites did
# finish could be reported with passed=0.
function Update-GroupProgress {
    foreach ($name in $groups.Keys) {
        $file = $progressFiles[$name]
        if (-not (Test-Path -LiteralPath $file)) { continue }
        $all = @(Get-Content -LiteralPath $file -Encoding UTF8 -ErrorAction SilentlyContinue | Where-Object { $_ })
        if ($all.Count -le $seen[$name]) { continue }
        foreach ($line in $all[$seen[$name]..($all.Count - 1)]) {
            $parts = $line -split '\|'
            if ($parts.Count -lt 6) { continue }
            $suite = $parts[0]; $code = [int]$parts[1]; $p = [int]$parts[2]; $f = [int]$parts[3]; $note = $parts[5]
            $totals[$name].Passed += $p
            $totals[$name].Failed += $f
            if ($code -eq 3) { $totals[$name].Timeouts++ }
            elseif ($code -eq 2) { $totals[$name].RunnerErrors++ }
            $flag = 'ok  '
            if ($code -eq 3) { $flag = 'TIME' }
            elseif ($code -eq 2) { $flag = 'ERR ' }
            elseif ($code -ne 0) { $flag = 'FAIL' }
            Write-Host ("  [{0}] {1,-6} {2,-22} passed={3,-4} failed={4,-3}{5}" -f $flag, $name, $suite, $p, $f, $(if ($note) { " ($note)" } else { '' }))
        }
        $seen[$name] = $all.Count
    }
}

while ($true) {
    Update-GroupProgress
    $running = @($groups.Keys | Where-Object { (Get-Job -Id $jobs[$_].Id -ErrorAction SilentlyContinue).State -eq 'Running' })
    if ($running.Count -eq 0) { break }
    if ([DateTime]::UtcNow -gt $deadline) { $timedOut = $true; break }
    Start-Sleep -Seconds 3
}

# Stop anything still running BEFORE judging the groups, then drain what the jobs
# managed to write. A suite that finished between the last poll and the stop has
# its line on disk but not in $totals, so a group that really did pass could be
# reported as passed=0 -- and a group that really did finish looked identical to
# "all green" without the completeness check below.
foreach ($name in $groups.Keys) {
    $job = Get-Job -Id $jobs[$name].Id -ErrorAction SilentlyContinue
    if (-not $job) { continue }
    if ($timedOut -and $job.State -eq 'Running') {
        Write-Host ("  GROUP TIMEOUT: {0} exceeded ${GroupTimeoutSeconds}s and was stopped." -f $name)
        Stop-Job -Job $job -ErrorAction SilentlyContinue
    }
    $jobError = @($job | Receive-Job -ErrorAction SilentlyContinue 2>&1)
    if ($job.State -eq 'Failed') {
        Write-Host ("  GROUP ERROR: {0} job failed: {1}" -f $name, (($jobError | Select-Object -First 2) -join '; '))
        $totals[$name].RunnerErrors++
    }
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
}

Update-GroupProgress

foreach ($name in $groups.Keys) {
    $expected = @($groups[$name]).Count
    $completed = @(Get-Content -LiteralPath $progressFiles[$name] -Encoding UTF8 -ErrorAction SilentlyContinue | Where-Object { $_ }).Count
    if ($completed -lt $expected) {
        Write-Host ("  GROUP INCOMPLETE: {0} finished {1} of {2} suites." -f $name, $completed, $expected)
        $totals[$name].RunnerErrors++
    }
    $t = $totals[$name]
    $t.Verdict = if ($t.RunnerErrors -gt 0) { 'runner-error' } elseif ($t.Timeouts -gt 0) { 'timeout' } elseif ($t.Failed -gt 0) { 'test-failure' } else { 'pass' }
}

Write-Host ''
$grandPassed = 0; $grandFailed = 0; $anyTimeout = $false; $anyRunnerError = $false
foreach ($name in $groups.Keys) {
    $t = $totals[$name]
    $grandPassed += $t.Passed; $grandFailed += $t.Failed
    if ($t.Timeouts -gt 0 -or $t.Verdict -eq 'timeout') { $anyTimeout = $true }
    if ($t.RunnerErrors -gt 0) { $anyRunnerError = $true }
    Write-Host ("{0,-6} {1,-14} passed={2,-5} failed={3,-4} timeouts={4} runner-errors={5}" -f $name, $t.Verdict, $t.Passed, $t.Failed, $t.Timeouts, $t.RunnerErrors)
}
Write-Host ("TOTAL  passed={0} failed={1}" -f $grandPassed, $grandFailed)

if ($timedOut -or $anyTimeout) { exit 3 }
if ($anyRunnerError) { exit 2 }
if ($grandFailed -gt 0) { exit 1 }
exit 0
