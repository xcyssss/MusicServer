# Set .md file association to VS Code
$codeExe = "C:\Users\dell\AppData\Local\Programs\Microsoft VS Code\Code.exe"

# 1. Register VSCode.md ProgId at both HKLM and HKCU
foreach ($hive in @("HKLM:\Software\Classes", "HKCU:\Software\Classes")) {
    $key = "$hive\VSCode.md"
    New-Item -Path $key -Force | Out-Null
    Set-ItemProperty -Path $key -Name "(Default)" -Value "Markdown (VS Code)"
    New-Item -Path "$key\DefaultIcon" -Force | Out-Null
    Set-ItemProperty -Path "$key\DefaultIcon" -Name "(Default)" -Value "$codeExe,0"
    New-Item -Path "$key\shell\open\command" -Force | Out-Null
    Set-ItemProperty -Path "$key\shell\open\command" -Name "(Default)" -Value "`"$codeExe`" `"%1`""
}

# 2. Set system-level assoc
cmd /c "assoc .md=VSCode.md"
cmd /c "assoc .markdown=VSCode.md"

# 3. Clear old UserChoice and set new one
$userChoice = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.md\UserChoice"
Remove-Item $userChoice -Recurse -Force -ErrorAction SilentlyContinue
New-Item -Path $userChoice -Force | Out-Null
New-ItemProperty -Path $userChoice -Name "ProgId" -Value "VSCode.md" -PropertyType String -Force | Out-Null

# Same for .markdown
$userChoice2 = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.markdown\UserChoice"
Remove-Item $userChoice2 -Recurse -Force -ErrorAction SilentlyContinue
New-Item -Path $userChoice2 -Force | Out-Null
New-ItemProperty -Path $userChoice2 -Name "ProgId" -Value "VSCode.md" -PropertyType String -Force | Out-Null

# 4. Clean up old Obsidian association
Remove-Item "HKLM:\Software\Classes\Obsidian.md" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "HKCU:\Software\Classes\Obsidian.md" -Recurse -Force -ErrorAction SilentlyContinue

# 5. Notify shell
Add-Type -MemberDefinition '[DllImport("shell32.dll")] public static extern void SHChangeNotify(int wEventId, int uFlags, IntPtr dwItem1, IntPtr dwItem2);' -Name "Shell32" -Namespace "Win32" -ErrorAction SilentlyContinue
[Win32.Shell32]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)

Write-Host "DONE"
"DONE" | Out-File "E:\Project\MusicServer\assoc_result.txt"
