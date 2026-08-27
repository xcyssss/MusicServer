# Elevated: Clean up all competing .md associations and force Obsidian
$obsidianExe = "C:\Users\dell\AppData\Local\Programs\Obsidian\Obsidian.exe"

# 1. Delete Nutstore .md association at system level
Remove-Item "HKLM:\Software\Classes\Nutstore.LightApp.md" -Recurse -Force -ErrorAction SilentlyContinue

# 2. Ensure Obsidian.md ProgId is registered at both HKLM and HKCU
foreach ($hive in @("HKLM:\Software\Classes", "HKCU:\Software\Classes")) {
    $key = "$hive\Obsidian.md"
    New-Item -Path $key -Force | Out-Null
    Set-ItemProperty -Path $key -Name "(Default)" -Value "Markdown (Obsidian)"
    New-Item -Path "$key\DefaultIcon" -Force | Out-Null
    Set-ItemProperty -Path "$key\DefaultIcon" -Name "(Default)" -Value "$obsidianExe,0"
    New-Item -Path "$key\shell\open\command" -Force | Out-Null
    Set-ItemProperty -Path "$key\shell\open\command" -Name "(Default)" -Value "`"$obsidianExe`" `"%1`""
}

# 3. Delete the entire UserChoice key (including hash) and recreate
$userChoiceBase = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.md"
Remove-Item "$userChoiceBase\UserChoice" -Recurse -Force -ErrorAction SilentlyContinue

# 4. Clean OpenWithProgids - remove Nutstore entry, keep Obsidian
$progidsPath = "$userChoiceBase\OpenWithProgids"
if (Test-Path $progidsPath) {
    Remove-ItemProperty -Path $progidsPath -Name "Nutstore.LightApp.md" -Force -ErrorAction SilentlyContinue
}

# 5. Set system-level assoc
cmd /c "assoc .md=Obsidian.md"

# 6. Notify shell to refresh
Add-Type -MemberDefinition '[DllImport("shell32.dll")] public static extern void SHChangeNotify(int wEventId, int uFlags, IntPtr dwItem1, IntPtr dwItem2);' -Name "Shell32" -Namespace "Win32" -ErrorAction SilentlyContinue
[Win32.Shell32]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)

Write-Host "SUCCESS" | Out-File "E:\Project\MusicServer\assoc_result.txt"
