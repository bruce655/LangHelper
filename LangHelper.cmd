@echo off
rem Launch the LangHelper tray app without a console window.
start "" powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0langhelper-tray.ps1" %*
