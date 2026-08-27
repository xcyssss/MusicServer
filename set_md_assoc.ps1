# Elevated script to set .md file association to Obsidian
$obsidianExe = "C:\Users\dell\AppData\Local\Programs\Obsidian\Obsidian.exe"

# 1. Register ProgId at HKLM (system level) so assoc/ftype can find it
$progIdKey = "HKLM:\Software\Classes\Obsidian.md"
New-Item -Path $progIdKey -Force | Out-Null
Set-ItemProperty -Path $progIdKey -Name "(Default)" -Value "Markdown (Obsidian)"
New-Item -Path "$progIdKey\DefaultIcon" -Force | Out-Null
Set-ItemProperty -Path "$progIdKey\DefaultIcon" -Name "(Default)" -Value "$obsidianExe,0"
New-Item -Path "$progIdKey\shell\open\command" -Force | Out-Null
Set-ItemProperty -Path "$progIdKey\shell\open\command" -Name "(Default)" -Value "`"$obsidianExe`" `"%1`""

# 2. Set system-level assoc
cmd /c "assoc .md=Obsidian.md"
cmd /c "assoc .markdown=Obsidian.md"

# 3. Clear UserChoice (protected key, needs admin + ownership)
$userChoiceMd = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.md\UserChoice"
$userChoiceMd2 = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.markdown\UserChoice"
Remove-Item $userChoiceMd -Force -ErrorAction SilentlyContinue
Remove-Item $userChoiceMd2 -Force -ErrorAction SilentlyContinue

# 4. Also set UserChoice ProgId directly
New-Item -Path $userChoiceMd -Force -ErrorAction SilentlyContinue | Out-Null
New-ItemProperty -Path $userChoiceMd -Name "ProgId" -Value "Obsidian.md" -PropertyType String -Force -ErrorAction SilentlyContinue | Out-Null

Write-Host "SUCCESS" | Out-File "E:\Project\MusicServer\assoc_result.txt"
