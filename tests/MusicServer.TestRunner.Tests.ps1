$runner = Join-Path (Split-Path -Parent $PSScriptRoot) 'tests/run_suite.ps1'

Describe 'PowerShell 5.1 test runner contract' {
    function Invoke-RunnerFixture {
        param([string]$Content, [switch]$Missing, [int]$TimeoutSeconds = 0)
        $fixture = Join-Path $TestDrive 'runner fixture.Tests.ps1'
        # A nested log directory is deliberate: the runner resolves the log and its
        # own paths through the session provider, so a caller-supplied directory
        # that does not exist yet is the normal case.
        $log = Join-Path $TestDrive 'nested logs/result.log'
        if ($Missing) {
            $fixture = Join-Path $TestDrive 'missing.Tests.ps1'
        } else {
            Set-Content -LiteralPath $fixture -Value $Content -Encoding UTF8
        }
        $savedPreference = $ErrorActionPreference
        $savedExitCode = $global:LASTEXITCODE
        try {
            # PS5.1 wraps native stderr as ErrorRecord; inspect the process exit code.
            $ErrorActionPreference = 'Continue'
            $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $runner, '-SuiteFile', $fixture, '-LogFile', $log)
            if ($TimeoutSeconds -gt 0) { $arguments += @('-TimeoutSeconds', "$TimeoutSeconds") }
            $output = & powershell.exe @arguments 2>&1
            $code = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $savedPreference
            # Actions checks LASTEXITCODE after Pester returns. Expected child
            # failures must not become the exit status of the parent test job.
            $global:LASTEXITCODE = $savedExitCode
        }
        [pscustomobject]@{ Code = $code; Log = (Get-Content -LiteralPath $log -Raw -Encoding UTF8) }
    }

    It 'reports success and excludes live-runtime tests by default' {
        $r = Invoke-RunnerFixture @'
Describe 'isolated suite' { It 'passes' { 1 | Should Be 1 } }
Describe 'live suite' -Tag RequiresLocalRuntime { It 'must be excluded' { throw 'live test ran' } }
'@
        $r.Code | Should Be 0
        $r.Log | Should Match 'Pester: 3.4.0'
        $r.Log | Should Match 'Passed: 1  Failed: 0  Total: 1'
    }

    It 'reports the failing test, message and location with exit code one' {
        $r = Invoke-RunnerFixture @'
Describe '故意失败夹具' { Context 'failure context' { It '失败详情' { throw '预期失败信息' } } }
'@
        $r.Code | Should Be 1
        $r.Log | Should Match 'Passed: 0  Failed: 1  Total: 1'
        $r.Log | Should Match 'FAILED: 故意失败夹具 / failure context / 失败详情'
        $r.Log | Should Match '预期失败信息'
        $r.Log | Should Match 'runner fixture.Tests.ps1'
    }

    It 'reports a missing suite as a runner error with exit code two' {
        $r = Invoke-RunnerFixture -Missing
        $r.Code | Should Be 2
        $r.Log | Should Match 'RUNNER EXCEPTION:'
        $r.Log | Should Match 'missing.Tests.ps1'
    }

    It 'does not report an empty suite as successful' {
        $r = Invoke-RunnerFixture '# no tests'
        $r.Code | Should Be 2
        $r.Log | Should Match 'No tests discovered'
    }

    It 'kills a suite that overruns its budget and reports exit code three' {
        # A deadlocked suite is the failure mode that used to hold a session for an
        # hour with no verdict. Exit 3 must stay distinct from a test failure (1)
        # and a runner error (2).
        $r = Invoke-RunnerFixture -TimeoutSeconds 5 @'
Describe 'hung suite' { It 'never returns' { Start-Sleep -Seconds 300 } }
'@
        $r.Code | Should Be 3
        $r.Log | Should Match 'TIMEOUT: runner fixture.Tests.ps1 exceeded 5s and was killed'
    }

    It 'never reports a killed run as a pass' {
        # A false green here is the whole reason the runner is bounded: a suite that
        # was stopped must not leave a plausible-looking summary behind.
        $r = Invoke-RunnerFixture -TimeoutSeconds 5 @'
Describe 'hung suite' { It 'pretends to be fine' { Start-Sleep -Seconds 300 } }
'@
        $r.Code | Should Be 3
        $r.Log | Should Not Match 'Passed: 1'
    }

    It 'leaves no child process behind after a timeout' {
        $r = Invoke-RunnerFixture -TimeoutSeconds 5 @'
Describe 'hung suite' { It 'never returns' { Start-Sleep -Seconds 300 } }
'@
        $r.Code | Should Be 3
        # Match only THIS run's processes. Comparing every powershell.exe on the
        # machine would race with unrelated activity; the fixture path is unique to
        # this test and appears in the command line of both the runner and its
        # worker. An orphan would hold the fixed API ports and make the next suite
        # wait, manufacturing a slowdown that looks like a product bug.
        Start-Sleep -Seconds 3
        $leaked = @(
            Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
                Where-Object { $_.CommandLine -and $_.CommandLine.Contains($TestDrive) }
        )
        $leaked.Count | Should Be 0
    }
}
