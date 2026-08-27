@echo off
setlocal
cd /d "%~dp0"

rem Start the existing components in separate, minimized windows.
start "MusicServer Navidrome" /min powershell.exe -NoProfile -File "%~dp0start_navidrome.ps1" -NoBrowser
start "MusicServer API" /min powershell.exe -NoProfile -File "%~dp0music_api.ps1"
start "MusicServer Wanted Worker" /min powershell.exe -NoProfile -File "%~dp0wanted_worker.ps1" -PollSeconds 30

rem Give the local API a few seconds to bind before opening the UI.
ping.exe -n 6 127.0.0.1 >nul
start "" "http://127.0.0.1:8787/"
endlocal
