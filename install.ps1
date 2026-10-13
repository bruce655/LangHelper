#requires -Version 5.1
<#
.SYNOPSIS
    Sets up LangHelper: installs the VS Code bridge extension, creates
    langhelper.ini, and optionally starts the tray app with Windows.

.DESCRIPTION
    Everything here is per-user and reversible. Run it again after pulling a new
    version to refresh the installed extension.

.PARAMETER Uninstall
    Remove the installed bridge extension and the startup entry. Your
    langhelper.ini, history, and logs are left alone.

.PARAMETER NoStartup
    Skip creating the "start with Windows" entry.
#>
[CmdletBinding()]
param(
    [switch]$Uninstall,
    [switch]$NoStartup
)

$ErrorActionPreference = 'Stop'
$root       = Split-Path -Parent $MyInvocation.MyCommand.Path
$extSource  = Join-Path $root 'vscode-extension'
$manifest   = Get-Content (Join-Path $extSource 'package.json') -Raw | ConvertFrom-Json
$extTarget  = Join-Path $env:USERPROFILE ".vscode\extensions\$($manifest.publisher).$($manifest.name)-$($manifest.version)"
$runKey     = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$runName    = 'LangHelper'

if ($Uninstall) {
    Get-ChildItem (Join-Path $env:USERPROFILE '.vscode\extensions') -Directory -Filter "$($manifest.publisher).$($manifest.name)-*" -ErrorAction SilentlyContinue |
        ForEach-Object { Remove-Item $_.FullName -Recurse -Force; Write-Host "Removed $($_.Name)" }
    Remove-ItemProperty -Path $runKey -Name $runName -ErrorAction SilentlyContinue
    Write-Host 'LangHelper uninstalled. Restart VS Code to unload the extension.'
    return
}

# --- 1. Install the VS Code bridge extension -----------------------------------
# VS Code loads any unpacked folder under ~/.vscode/extensions, so no packaging
# step or marketplace publish is needed.
Get-ChildItem (Join-Path $env:USERPROFILE '.vscode\extensions') -Directory -Filter "$($manifest.publisher).$($manifest.name)-*" -ErrorAction SilentlyContinue |
    ForEach-Object { Remove-Item $_.FullName -Recurse -Force }

New-Item -ItemType Directory -Path $extTarget -Force | Out-Null
Copy-Item (Join-Path $extSource '*') -Destination $extTarget -Recurse -Force
Write-Host "Installed bridge extension to $extTarget"

# --- 2. Create langhelper.ini --------------------------------------------------
$ini = Join-Path $root 'langhelper.ini'
if (-not (Test-Path -LiteralPath $ini)) {
    Copy-Item (Join-Path $root 'langhelper.ini.example') $ini
    Write-Host "Created $ini"
} else {
    Write-Host "Kept existing $ini"
}

# --- 3. Start with Windows -----------------------------------------------------
if (-not $NoStartup) {
    $cmd = '"{0}"' -f (Join-Path $root 'LangHelper.cmd')
    New-ItemProperty -Path $runKey -Name $runName -Value $cmd -PropertyType String -Force | Out-Null
    Write-Host 'LangHelper will start with Windows.'
}

Write-Host ''
Write-Host 'Next steps:' -ForegroundColor Cyan
Write-Host '  1. Restart VS Code (or run the "Developer: Reload Window" command).'
Write-Host '  2. Run the command "LangHelper: Test Copilot Connection" once and approve the prompt.'
Write-Host '  3. Double-click LangHelper.cmd, then press Ctrl+C twice on any text.'
