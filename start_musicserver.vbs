Option Explicit

' Desktop launcher for MusicServer.
' WScript runs this file without creating a console window. The application
' components are still the existing PowerShell scripts; this wrapper only
' starts them and opens the local web page after the API has had time to bind.

Dim shell, base, navidrome, api, worker
Set shell = CreateObject("WScript.Shell")
base = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\"))
shell.CurrentDirectory = base

navidrome = "powershell.exe -NoLogo -NoProfile -File """ & base & "start_navidrome.ps1"" -NoBrowser"
api = "powershell.exe -NoLogo -NoProfile -File """ & base & "music_api.ps1"""
worker = "powershell.exe -NoLogo -NoProfile -File """ & base & "wanted_worker.ps1"" -PollSeconds 30"

' Window style 0 = hidden; False = do not wait for long-running components.
shell.Run navidrome, 0, False
shell.Run api, 0, False
shell.Run worker, 0, False

' Match the previous launcher behavior: let the API bind before opening the UI.
WScript.Sleep 5000
shell.Run "http://127.0.0.1:8787/", 1, False

Set shell = Nothing
