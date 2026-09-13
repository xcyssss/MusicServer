# Shared by the installed-app CI smoke and its PS5.1 regression tests.
function Close-MusicServerSmokeDesktop {
    param([Parameter(Mandatory)]$Process)
    if ($Process.HasExited) { return }
    $deadline = [DateTime]::UtcNow.AddSeconds(35)
    do {
        $Process.Refresh()
        if ($Process.HasExited) { throw 'APP exited before its window could be closed.' }
        if ($Process.MainWindowHandle -ne 0) { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    # Force termination is failure cleanup only, so a broken APP exit handler
    # cannot pass this normal window-close regression.
    if ($Process.MainWindowHandle -eq 0 -or -not $Process.CloseMainWindow() -or -not $Process.WaitForExit(40000)) {
        Stop-MusicServerSmokeDesktop -Process $Process
        throw 'APP did not exit after a normal window-close request.'
    }
}

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
