# Elevated: Update Obsidian.md to use explorer.exe wrapper for opening files
# This solves the Electron single-instance problem where Obsidian.exe exits immediately
# when another instance is already running, without forwarding the file.

$obsidianExe = "C:\Users\dell\AppData\Local\Programs\Obsidian\Obsidian.exe"

# Update the open command to use explorer.exe (which properly delegates to running instance)
foreach ($hive in @("HKLM:\Software\Classes", "HKCU:\Software\Classes")) {
    $cmdKey = "$hive\Obsidian.md\shell\open\command"
    if (Test-Path $cmdKey) {
        Set-ItemProperty -Path $cmdKey -Name "(Default)" -Value "explorer.exe `"%1`""
    }
}

# Also update UserChoice if it exists
$userChoice = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.md\UserChoice"
if (Test-Path $userChoice) {
    Set-ItemProperty -Path $userChoice -Name "ProgId" -Value "Obsidian.md" -Force
}

# Notify shell
Add-Type -MemberDefinition '[DllImport("shell32.dll")] public static extern void SHChangeNotify(int wEventId, int uFlags, IntPtr dwItem1, IntPtr dwItem2);' -Name "Shell32" -Namespace "Win32" -ErrorAction SilentlyContinue
[Win32.Shell32]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)

Write-Host "DONE"
"DONE" | Out-File "E:\Project\MusicServer\assoc_result.txt"
