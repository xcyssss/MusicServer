@echo off
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0start_musicserver_ui.ps1"
if errorlevel 1 (
  echo.
  echo MusicServer failed to start. Review the error above.
  pause
)
