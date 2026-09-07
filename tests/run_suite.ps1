# One-shot test runner: writes a summary + failures to -LogFile.
param(
    [Parameter(Mandatory)][string]$SuiteFile,
    [Parameter(Mandatory)][string]$LogFile,
    [string[]]$ExcludeTag = @('RequiresLocalRuntime')
)
$ErrorActionPreference = 'Stop'
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
