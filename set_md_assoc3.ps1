# Force delete Nutstore .md and set Obsidian as default
# Must run as admin

# 1. Take ownership and delete Nutstore .md ProgId
$nutstoreKey = "HKLM:\Software\Classes\Nutstore.LightApp.md"
if (Test-Path $nutstoreKey) {
    # Try reg.exe delete (more forceful)
    cmd /c "reg delete HKLM\Software\Classes\Nutstore.LightApp.md /f 2>&1"
    Write-Host "Nutstore key deleted via reg.exe"
}

# 2. Also check HKCU for Nutstore
$nutstoreKeyCU = "HKCU:\Software\Classes\Nutstore.LightApp.md"
if (Test-Path $nutstoreKeyCU) {
    cmd /c "reg delete HKCU\Software\Classes\Nutstore.LightApp.md /f 2>&1"
    Write-Host "Nutstore HKCU key deleted"
}

# 3. Force set .md=Obsidian.md at system level
cmd /c "ftype Obsidian.md=""C:\Users\dell\AppData\Local\Programs\Obsidian\Obsidian.exe"" ""%1"""
cmd /c "assoc .md=Obsidian.md"

# 4. Delete UserChoice and all subkeys, then let system assoc take over
cmd /c "reg delete HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.md\UserChoice /f 2>&1"
cmd /c "reg delete HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.md\OpenWithProgids /f 2>&1"

# 5. Recreate OpenWithProgids with only Obsidian
cmd /c "reg add HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.md\OpenWithProgids /v Obsidian.md /t REG_NONE /f 2>&1"

# 6. Notify shell
Add-Type -MemberDefinition '[DllImport("shell32.dll")] public static extern void SHChangeNotify(int wEventId, int uFlags, IntPtr dwItem1, IntPtr dwItem2);' -Name "Shell32" -Namespace "Win32" -ErrorAction SilentlyContinue
[Win32.Shell32]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)

Write-Host "DONE"
Start-Sleep -Seconds 1

# Write result
"DONE" | Out-File "E:\Project\MusicServer\assoc_result.txt"
