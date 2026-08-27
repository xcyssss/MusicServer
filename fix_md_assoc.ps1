# Fix: Revert to Obsidian.exe directly to stop the infinite loop
$obsidianExe = "C:\Users\dell\AppData\Local\Programs\Obsidian\Obsidian.exe"

foreach ($hive in @("HKLM:\Software\Classes", "HKCU:\Software\Classes")) {
    $cmdKey = "$hive\Obsidian.md\shell\open\command"
    if (Test-Path $cmdKey) {
        Set-ItemProperty -Path $cmdKey -Name "(Default)" -Value "`"$obsidianExe`" `"%1`""
    }
}

Add-Type -MemberDefinition '[DllImport("shell32.dll")] public static extern void SHChangeNotify(int wEventId, int uFlags, IntPtr dwItem1, IntPtr dwItem2);' -Name "Shell32" -Namespace "Win32" -ErrorAction SilentlyContinue
[Win32.Shell32]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)

Write-Host "FIXED"
"FIXED" | Out-File "E:\Project\MusicServer\assoc_result.txt"
