# One-shot test runner: writes a summary + failures to -LogFile.
#
# Every invocation is bounded by -TimeoutSeconds. The api suites really start
# powershell.exe, music_api.ps1, start_musicserver_ui.ps1, HTTP listeners, SQLite
# fixtures and TCP sockets, each with a 40-second startup allowance, 15-second
# socket timeouts and deliberate slow-I/O sleeps. Pester 3.4 has no bound of its
# own, so one child that exits late or one deadlocked suite can hold a session for
# an hour and never produce a verdict. With a bound the run reports TIMEOUT and
# stops, and the hang becomes the finding instead of the wait.
#
# The suite runs in a child PROCESS rather than in this one: a timeout must be able
# to kill the whole tree, including the services and child processes a suite
# started. Pester inside this process could not be interrupted at all.
param(
    [Parameter(Mandatory)][string]$SuiteFile,
    [Parameter(Mandatory)][string]$LogFile,
    [string[]]$ExcludeTag = @('RequiresLocalRuntime'),
    # Default budget for one targeted suite. AGENTS.md: investigate anything that
    # needs more than this rather than waiting longer.
    [int]$TimeoutSeconds = 300,
    # Internal: the child that actually runs Pester.
    [switch]$Worker
)
$ErrorActionPreference = 'Stop'

function Write-RunnerLog {
    param([string[]]$Content)
    try { $Content | Set-Content -LiteralPath $LogFile -Encoding UTF8 } catch { }
}

function ConvertTo-ProcessArgumentLine {
    # ProcessStartInfo takes one argument string, so anything with a space must be
    # quoted or the child sees it as two parameters.
    param([string[]]$Arguments)
    return (($Arguments | ForEach-Object {
        $a = [string]$_
        if ($a -match '[\s"]') { '"' + ($a -replace '"', '\"') + '"' } else { $a }
    }) -join ' ')
}

if (-not $Worker) {
    # Parent: run the child under a hard wall-clock bound and kill its whole tree on
    # expiry, so a deadlocked suite cannot leave services or listeners behind for
    # the next one to trip over.
    $logPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($LogFile)
    $parent = Split-Path -Parent $logPath
    if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue

    $arguments = @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $PSCommandPath,
        '-SuiteFile', $SuiteFile,
        '-LogFile', $logPath,
        '-Worker',
        '-TimeoutSeconds', '0'
    )
    if ($ExcludeTag -and $ExcludeTag.Count -gt 0) { $arguments += @('-ExcludeTag', ($ExcludeTag -join ',')) }

    # System.Diagnostics.Process rather than Start-Process -PassThru: a process
    # object handed back by Start-Process without -Wait does not keep a handle, so
    # .ExitCode reads as $null -- and `exit $null` is exit code 0, which reported a
    # crashed suite as a pass. That is the exact false green this runner exists to
    # prevent. Only the suite's exit code matters here; stdout is discarded because
    # the worker writes the summary and failure detail into the log file.
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = 'powershell.exe'
    $startInfo.Arguments = ConvertTo-ProcessArgumentLine -Arguments $arguments
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    [void]$process.Start()

    $exited = $process.WaitForExit($TimeoutSeconds * 1000)

    if (-not $exited) {
        # /T kills the suite's own children too (API servers, fixtures, workers).
        & cmd.exe /c "taskkill /PID $($process.Id) /T /F" 2>&1 | Out-Null
        try { $process.WaitForExit(15000) | Out-Null } catch { }
        $name = [IO.Path]::GetFileName($SuiteFile)
        Write-RunnerLog -Content @(
            "SUITE: $SuiteFile",
            'Pester: 3.4.0',
            "TIMEOUT: $name exceeded ${TimeoutSeconds}s and was killed.",
            'Investigate which test, child process, port or request is stuck before re-running.'
        )
        [Console]::Error.WriteLine("TIMEOUT: $SuiteFile")
        exit 3
    }

    # A timed WaitForExit() returns True once the process has exited but does not
    # finish collecting it; the parameterless call does, so .ExitCode is populated.
    $process.WaitForExit()
    $code = $process.ExitCode
    if ($null -eq $code) { $code = 2 }
    try { $process.Dispose() } catch { }

    # A child that died before writing its own log is a runner error, not a pass:
    # "no summary" must never be read as "all green".
    if (-not (Test-Path -LiteralPath $logPath)) {
        Write-RunnerLog -Content @(
            "SUITE: $SuiteFile",
            'Pester: 3.4.0',
            "RUNNER EXCEPTION: the suite process exited with code $code without writing a log."
        )
        [Console]::Error.WriteLine("RUNNER EXCEPTION: no log for $SuiteFile")
        exit 2
    }
    exit $code
}

# Worker: this process runs Pester and writes the log. The parent bounds it.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
$lines = @()
try {
    $logPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($LogFile)
    New-Item -ItemType Directory -Path (Split-Path -Parent $logPath) -Force | Out-Null
    $suite = (Resolve-Path -LiteralPath $SuiteFile -ErrorAction Stop).ProviderPath
    Import-Module Pester -RequiredVersion 3.4.0 -Force -ErrorAction Stop
    $r = Invoke-Pester -Path $suite -ExcludeTag $ExcludeTag -PassThru -Quiet
    $lines += "SUITE: $suite"
    $lines += 'Pester: 3.4.0'
    $lines += "Passed: $($r.PassedCount)  Failed: $($r.FailedCount)  Total: $($r.TotalCount)"
    foreach ($f in @($r.TestResult | Where-Object { $_.Result -eq 'Failed' })) {
        $lines += "FAILED: $($f.Describe) / $($f.Context) / $($f.Name)"
        $lines += "  :: $($f.FailureMessage)"
        if ($f.StackTrace) { $lines += "  :: $($f.StackTrace)" }
    }
    if ($r.TotalCount -eq 0) { throw 'No tests discovered after filtering.' }
    $lines | Set-Content -LiteralPath $logPath -Encoding UTF8
    exit ($(if ($r.FailedCount -gt 0) { 1 } else { 0 }))
} catch {
    $message = "RUNNER EXCEPTION: $($_.Exception.Message)"
    try { @($lines) + $message | Set-Content -LiteralPath $LogFile -Encoding UTF8 } catch { }
    [Console]::Error.WriteLine($message)
    exit 2
}
