$runner = Join-Path (Split-Path -Parent $PSScriptRoot) 'tests/run_suite.ps1'

Describe 'PowerShell 5.1 test runner contract' {
    function Invoke-RunnerFixture {
        param([string]$Content, [switch]$Missing)
        $fixture = Join-Path $TestDrive 'runner fixture.Tests.ps1'
        $log = Join-Path $TestDrive 'nested logs/result.log'
        if ($Missing) {
            $fixture = Join-Path $TestDrive 'missing.Tests.ps1'
        } else {
            Set-Content -LiteralPath $fixture -Value $Content -Encoding UTF8
        }
        $savedPreference = $ErrorActionPreference
        try {
            # PS5.1 wraps native stderr as ErrorRecord; inspect the process exit code.
            $ErrorActionPreference = 'Continue'
            $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner -SuiteFile $fixture -LogFile $log 2>&1
            $code = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $savedPreference
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
}
