@echo off
rem Launch the LangHelper tray app without a console window.
start "" "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0langhelper-tray.ps1" -DetachConsole %*
