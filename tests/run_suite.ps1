# One-shot test runner: writes a summary + failures to -LogFile.
param(
    [Parameter(Mandatory)][string]$SuiteFile,
    [Parameter(Mandatory)][string]$LogFile
)
$suite = Join-Path (Split-Path $SuiteFile -Parent) (Split-Path $SuiteFile -Leaf)
$lines = @()
try {
    Import-Module Pester -ErrorAction Stop
    $r = Invoke-Pester -Path $suite -PassThru -Quiet
    $lines += "SUITE: $suite"
    $lines += "Passed: $($r.PassedCount)  Failed: $($r.FailedCount)  Total: $($r.TotalCount)"
    if ($r.Failed) {
        foreach ($f in @($r.Failed)) {
            $lines += "FAILED: $($f.ExpandedPath)"
            if ($f.ErrorRecord) { $lines += "  :: $($f.ErrorRecord.Exception.Message)" }
            if ($f.Block) { $lines += "  :: " + (($f.Block.ScriptBlock.ToString().Split("`n") | Where-Object { $_ -match 'FAIL|throw|Should' } | Select-Object -First 5) -join " | ") }
        }
    }
    $lines | Set-Content -LiteralPath $LogFile -Encoding UTF8
    exit ($(if ($r.FailedCount -gt 0) { 1 } else { 0 }))
} catch {
    "RUNNER EXCEPTION: $($_.Exception.Message)" | Set-Content -LiteralPath $LogFile -Encoding UTF8
    exit 2
}
