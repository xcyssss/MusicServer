# Process.MainWindowHandle may identify a WebView2/tray helper instead of the APP.
function Get-MusicServerSmokeMainWindow {
    param([Parameter(Mandatory)][int]$ProcessId)
    if (-not ('MusicServerSmokeWindow' -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class MusicServerSmokeWindow {
    private delegate bool EnumProc(IntPtr h, IntPtr p);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc callback, IntPtr p);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern int GetWindowText(IntPtr h, StringBuilder text, int size);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern int GetClassName(IntPtr h, StringBuilder text, int size);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint message, IntPtr w, IntPtr l);
    public static IntPtr Find(int pid) {
        IntPtr found=IntPtr.Zero;
        EnumWindows((h,p)=>{
            uint owner; GetWindowThreadProcessId(h,out owner);
            if(owner != pid) return true;
            var title=new StringBuilder(256); var kind=new StringBuilder(256);
            GetWindowText(h,title,256); GetClassName(h,kind,256);
            if(title.ToString()=="MusicServer" && kind.ToString()=="Tauri Window") { found=h; return false; }
            return true;
        },IntPtr.Zero);
        return found;
    }
}
"@
    }
    return [MusicServerSmokeWindow]::Find($ProcessId)
}

function Send-MusicServerSmokeClose {
    param([Parameter(Mandatory)][IntPtr]$Handle)
    return [MusicServerSmokeWindow]::PostMessage($Handle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
}

# Shared by the installed-app CI smoke and its PS5.1 regression tests.
function Close-MusicServerSmokeDesktop {
    param([Parameter(Mandatory)]$Process)
    if ($Process.HasExited) { return }
    $deadline = [DateTime]::UtcNow.AddSeconds(35)
    do {
        $Process.Refresh()
        if ($Process.HasExited) { throw 'APP exited before its window could be closed.' }
        $handle = Get-MusicServerSmokeMainWindow -ProcessId $Process.Id
        if ($handle -ne [IntPtr]::Zero) { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    # Force termination is failure cleanup only, so a broken APP exit handler
    # cannot pass this normal window-close regression.
    if ($handle -eq [IntPtr]::Zero -or -not (Send-MusicServerSmokeClose -Handle $handle) -or -not $Process.WaitForExit(40000)) {
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

# The APP selects ports, not the smoke runner. Require this process and APP home,
# then validate both live endpoints so a stale report cannot count as readiness.
function Get-MusicServerSmokePair {
    param([Parameter(Mandatory)][string]$AppHome,
          [Parameter(Mandatory)][string]$BuildMarker,
          [Parameter(Mandatory)][int]$DesktopProcessId)
    try {
        $report = Get-Content -LiteralPath (Join-Path $AppHome 'logs\desktop-startup.json') -Raw -ErrorAction Stop | ConvertFrom-Json
        if ($report.state -ne 'ready' -or $report.pid -ne $DesktopProcessId -or $report.build -ne $BuildMarker) { return $null }
        if ($report.ui_port -lt 1 -or $report.ui_port -gt 65535 -or $report.api_port -lt 1 -or $report.api_port -gt 65535) { return $null }
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $normalized = $AppHome.Replace('\','/').TrimEnd('/').ToLowerInvariant()
            $scope = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($normalized))).Replace('-','').ToLowerInvariant()
        } finally { $sha.Dispose() }
        $ui = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$($report.ui_port)/app.js" -TimeoutSec 3
        $health = Invoke-RestMethod -Uri "http://127.0.0.1:$($report.api_port)/health" -TimeoutSec 3
        if ($ui.StatusCode -ne 200 -or -not $ui.Content.Contains($BuildMarker) -or $health.build -ne $BuildMarker -or $health.runtime_scope -ne $scope) { return $null }
        return [pscustomobject]@{ UiPort = [int]$report.ui_port; ApiPort = [int]$report.api_port }
    } catch { return $null }
}
