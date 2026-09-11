# Shared by the installed-app CI smoke and its PS5.1 regression tests.
function Stop-MusicServerSmokeDesktop {
    param([Parameter(Mandatory)]$Process)
    $killExitCode = 0
    if (-not $Process.HasExited) {
        $kill = Start-Process -FilePath 'taskkill.exe' -ArgumentList @('/PID', [string]$Process.Id, '/T', '/F') -Wait -PassThru -WindowStyle Hidden
        $killExitCode = $kill.ExitCode
    }
    # taskkill /T can report an error for a descendant that exited during tree
    # traversal, even after terminating the APP. Require the observed outcome.
    if (-not $Process.WaitForExit(5000)) {
        throw "Installed APP did not exit within 5 seconds (taskkill exit code: $killExitCode)."
    }
    if ($killExitCode -ne 0) {
        Write-Warning "taskkill returned $killExitCode, but the installed APP has exited; service shutdown must still be verified."
    }
}
