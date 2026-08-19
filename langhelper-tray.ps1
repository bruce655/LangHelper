#requires -Version 5.1
<#
.SYNOPSIS
    LangHelper 2.0 tray app: a DeepL-style Ctrl+C, Ctrl+C clipboard translator.

.DESCRIPTION
    Replaces the AutoHotkey front end. Everything here is stock Windows
    PowerShell + WinForms, so the only thing you install is nothing.

    Double-copy detection uses the Win32 clipboard listener
    (AddClipboardFormatListener) rather than a keyboard hook: two clipboard
    updates inside DoubleCopyMs, with Ctrl still held, means "translate this".

    The translation itself goes to langhelper.ps1, which prefers the LangHelper
    Bridge extension in VS Code so the work is done by the Copilot models you
    are already signed in to.

.PARAMETER ConfigFile
    Path to langhelper.ini. Defaults to langhelper.ini next to this script.

.PARAMETER Translate
    Translate the current clipboard immediately at startup instead of waiting
    for a double copy.
#>
[CmdletBinding()]
param(
    [string]$ConfigFile = "",
    [switch]$Translate
)

$ErrorActionPreference = 'Stop'

# WinForms and the clipboard both require STA; relaunch rather than fail obscurely.
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $self = $MyInvocation.MyCommand.Path
    $relaunch = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', $self)
    if ($ConfigFile) { $relaunch += @('-ConfigFile', $ConfigFile) }
    if ($Translate)  { $relaunch += '-Translate' }
    Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $relaunch -WindowStyle Hidden
    return
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

$script:Root       = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:Backend    = Join-Path $script:Root 'langhelper.ps1'
$script:PromptPath = Join-Path $script:Root 'prompt.md'
$script:IniPath    = if ($ConfigFile) { $ConfigFile } else { Join-Path $script:Root 'langhelper.ini' }
$localAppData      = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $env:USERPROFILE 'AppData\Local' }
$script:DataDir    = Join-Path $localAppData 'LangHelper'
$script:LogDir     = Join-Path $script:Root 'logs'
$script:Utf8       = New-Object System.Text.UTF8Encoding $false

foreach ($d in @($script:DataDir, $script:LogDir)) {
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

# One tray icon per user, otherwise two listeners fight over every double copy.
$script:Mutex = New-Object System.Threading.Mutex($false, 'Local\LangHelper.Tray')
if (-not $script:Mutex.WaitOne(0)) {
    [Windows.Forms.MessageBox]::Show('LangHelper is already running (look for the green H in the tray).',
        'LangHelper', 'OK', 'Information') | Out-Null
    return
}

# --- Win32 clipboard listener --------------------------------------------------
if (-not ('LangHelper.ClipboardWatcher' -as [type])) {
    Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace LangHelper {
    public class ClipboardWatcher : NativeWindow, IDisposable {
        private const int WM_CLIPBOARDUPDATE = 0x031D;
        public event EventHandler ClipboardUpdate;

        [DllImport("user32.dll", SetLastError = true)] private static extern bool AddClipboardFormatListener(IntPtr hwnd);
        [DllImport("user32.dll", SetLastError = true)] private static extern bool RemoveClipboardFormatListener(IntPtr hwnd);
        [DllImport("user32.dll")] private static extern short GetAsyncKeyState(int vKey);

        public ClipboardWatcher() {
            CreateHandle(new CreateParams());
            AddClipboardFormatListener(Handle);
        }

        public static bool IsCtrlDown() { return (GetAsyncKeyState(0x11) & 0x8000) != 0; }

        protected override void WndProc(ref Message m) {
            if (m.Msg == WM_CLIPBOARDUPDATE) {
                var h = ClipboardUpdate;
                if (h != null) h(this, EventArgs.Empty);
            }
            base.WndProc(ref m);
        }

        public void Dispose() {
            RemoveClipboardFormatListener(Handle);
            DestroyHandle();
        }
    }
}
'@
}

# --- Config --------------------------------------------------------------------
$script:Defaults = [ordered]@{
    Provider       = 'auto'
    Model          = ''
    Features       = 'POLISH,BILINGUAL_EN_ZHTW'
    PromptFile     = ''
    DoubleCopyMs   = '700'
    MinChars       = '1'
    MaxChars       = '8000'
    TimeoutSec     = '120'
    AutoCopyResult = '0'
    AlwaysOnTop    = '1'
}

function Read-Config {
    $cfg = [ordered]@{}
    foreach ($k in $script:Defaults.Keys) { $cfg[$k] = $script:Defaults[$k] }
    if (Test-Path -LiteralPath $script:IniPath) {
        # ReadAllText honours the BOM, so the old UTF-16 ini files still load.
        foreach ($line in ([System.IO.File]::ReadAllText($script:IniPath) -replace "`r`n", "`n").Split("`n")) {
            $t = $line.Trim()
            if (-not $t -or $t.StartsWith(';') -or $t.StartsWith('#') -or $t.StartsWith('[')) { continue }
            $eq = $t.IndexOf('=')
            if ($eq -lt 1) { continue }
            $key = $t.Substring(0, $eq).Trim()
            # Unknown keys are dropped so ini files from older versions clean themselves up on save.
            if ($cfg.Contains($key)) { $cfg[$key] = $t.Substring($eq + 1).Trim() }
        }
    }
    return $cfg
}

function Save-Config {
    param([Parameter(Mandatory)]$Config)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('[LangHelper]')
    foreach ($k in $Config.Keys) { [void]$sb.AppendLine("$k=$($Config[$k])") }
    [System.IO.File]::WriteAllText($script:IniPath, $sb.ToString(), $script:Utf8)
}

$script:Config = Read-Config

function Write-Log {
    param([string]$Message)
    try {
        $file = Join-Path $script:LogDir ("langhelper_{0}.log" -f (Get-Date -Format 'yyyyMM'))
        $safe = $Message -replace [regex]::Escape($env:USERPROFILE), '%USERPROFILE%'
        Add-Content -LiteralPath $file -Value ("{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $safe) -Encoding UTF8
    } catch { }
}

function Add-History {
    param([string]$Source, [string]$Result, [string]$Features)
    try {
        $row = @{
            at       = (Get-Date).ToString('o')
            features = $Features
            provider = $script:Config.Provider
            source   = $Source
            result   = $Result
        } | ConvertTo-Json -Depth 4 -Compress
        Add-Content -LiteralPath (Join-Path $script:DataDir 'history.jsonl') -Value $row -Encoding UTF8
    } catch { }
}

function Get-PromptFeatures {
    $path = if ($script:Config.PromptFile -and (Test-Path -LiteralPath $script:Config.PromptFile)) {
        $script:Config.PromptFile
    } else { $script:PromptPath }
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    $md = [System.IO.File]::ReadAllText($path)
    $names = [regex]::Matches($md, '\[FEATURE:\s*([A-Z0-9_]+)') |
        ForEach-Object { $_.Groups[1].Value } |
        Select-Object -Unique
    return @($names)
}

function Get-SelectedFeatures {
    return @($script:Config.Features.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

# --- Backend call (runs off the UI thread) -------------------------------------
$script:Job = $null

function Stop-Translation {
    if ($script:Job) {
        try { $script:Job.Shell.Stop() } catch { }
        try { $script:Job.Shell.Dispose() } catch { }
        $script:Job = $null
    }
}

function Start-Translation {
    param([Parameter(Mandatory)][string]$Text)

    Stop-Translation
    $id      = [guid]::NewGuid().ToString('n')
    $inFile  = Join-Path $script:DataDir "req-$id.txt"
    $outFile = Join-Path $script:DataDir "res-$id.txt"
    [System.IO.File]::WriteAllText($inFile, $Text, $script:Utf8)

    $promptFile = if ($script:Config.PromptFile) { $script:Config.PromptFile } else { $script:PromptPath }
    $params = @{
        Provider   = $script:Config.Provider
        Features   = ((Get-SelectedFeatures) -join ',')
        InputFile  = $inFile
        OutputFile = $outFile
        TimeoutSec = [int]$script:Config.TimeoutSec
        PromptFile = $promptFile
    }
    if ($script:Config.Model) { $params['Model'] = $script:Config.Model }

    $shell = [powershell]::Create()
    [void]$shell.AddCommand($script:Backend).AddParameters($params)
    $script:Job = [pscustomobject]@{
        Shell    = $shell
        Handle   = $shell.BeginInvoke()
        OutFile  = $outFile
        InFile   = $inFile
        Started  = Get-Date
        Features = $params.Features
        Source   = $Text
    }
    Write-Log ("translate: {0} chars, features=[{1}], provider={2}" -f $Text.Length, $params.Features, $params.Provider)
}

function Complete-Translation {
    if (-not $script:Job -or -not $script:Job.Handle.IsCompleted) { return }

    $job = $script:Job
    $script:Job = $null
    $err = $null
    $text = $null
    try {
        [void]$job.Shell.EndInvoke($job.Handle)
        if ($job.Shell.Streams.Error.Count -gt 0) {
            $err = ($job.Shell.Streams.Error | ForEach-Object { $_.ToString() }) -join "`n"
        } elseif (Test-Path -LiteralPath $job.OutFile) {
            $text = [System.IO.File]::ReadAllText($job.OutFile, $script:Utf8)
        } else {
            $err = 'The backend produced no output file.'
        }
    } catch {
        $err = $_.Exception.Message
    } finally {
        try { $job.Shell.Dispose() } catch { }
        Remove-Item -LiteralPath $job.InFile, $job.OutFile -Force -ErrorAction SilentlyContinue
    }

    $elapsed = [int]((Get-Date) - $job.Started).TotalMilliseconds
    if ($err) {
        Write-Log "failed after ${elapsed}ms: $err"
        Set-Result -Text $err -Status ("Failed after {0:n1} s" -f ($elapsed / 1000)) -IsError
        return
    }

    Write-Log "ok after ${elapsed}ms, $($text.Length) chars"
    Add-History -Source $job.Source -Result $text -Features $job.Features
    try { [System.IO.File]::WriteAllText((Join-Path $script:DataDir 'last-result.txt'), $text, $script:Utf8) } catch { }
    Set-Result -Text $text -Status ("Done in {0:n1} s" -f ($elapsed / 1000))
    if ($script:Config.AutoCopyResult -eq '1') { Set-ClipboardQuietly $text }
}

function Set-ClipboardQuietly {
    param([string]$Text)
    # Our own copy would otherwise look like the first half of a double copy.
    $script:IgnoreClipboardUntil = (Get-Date).AddMilliseconds(1500)
    try { [Windows.Forms.Clipboard]::SetText($Text) } catch { }
}

# --- Translator window ---------------------------------------------------------
$script:Form = $null
$script:ResultBox = $null
$script:SourceBox = $null
$script:StatusLabel = $null
$script:FeaturePanel = $null
$script:CurrentSource = ''

function Set-Result {
    param([string]$Text, [string]$Status = '', [switch]$IsError)
    if (-not $script:Form -or $script:Form.IsDisposed) { return }
    $script:ResultBox.Text = $Text -replace "`r`n", "`n" -replace "`n", "`r`n"
    $script:ResultBox.ForeColor = if ($IsError) { [Drawing.Color]::Firebrick } else { [Drawing.Color]::FromArgb(30, 30, 30) }
    $script:StatusLabel.Text = $Status
}

function New-TranslatorWindow {
    $form = New-Object Windows.Forms.Form
    $form.Text = 'LangHelper'
    $form.Size = New-Object Drawing.Size(820, 620)
    $form.MinimumSize = New-Object Drawing.Size(520, 360)
    $form.StartPosition = 'CenterScreen'
    $form.TopMost = ($script:Config.AlwaysOnTop -eq '1')
    $form.Font = New-Object Drawing.Font('Segoe UI', 9.75)

    $table = New-Object Windows.Forms.TableLayoutPanel
    $table.Dock = 'Fill'
    $table.ColumnCount = 1
    $table.RowCount = 4
    $table.Padding = New-Object Windows.Forms.Padding(10)
    [void]$table.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 78)))
    [void]$table.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 74)))
    [void]$table.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent, 100)))
    [void]$table.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 40)))

    $src = New-Object Windows.Forms.TextBox
    $src.Multiline = $true
    $src.ReadOnly = $true
    $src.ScrollBars = 'Vertical'
    $src.Dock = 'Fill'
    $src.BackColor = [Drawing.Color]::FromArgb(246, 246, 246)
    $table.Controls.Add($src, 0, 0)

    $features = New-Object Windows.Forms.FlowLayoutPanel
    $features.Dock = 'Fill'
    $features.AutoScroll = $true
    $features.WrapContents = $true
    $selected = Get-SelectedFeatures
    foreach ($name in Get-PromptFeatures) {
        $cb = New-Object Windows.Forms.CheckBox
        $cb.Text = $name
        $cb.AutoSize = $true
        $cb.Margin = New-Object Windows.Forms.Padding(4, 4, 12, 4)
        $cb.Checked = ($selected -contains $name)
        $cb.Add_CheckedChanged({ Invoke-FeatureChange })
        [void]$features.Controls.Add($cb)
    }
    $table.Controls.Add($features, 0, 1)

    $result = New-Object Windows.Forms.TextBox
    $result.Multiline = $true
    $result.ReadOnly = $true
    $result.ScrollBars = 'Vertical'
    $result.Dock = 'Fill'
    $result.BackColor = [Drawing.Color]::White
    $result.Font = New-Object Drawing.Font('Segoe UI', 11)
    $table.Controls.Add($result, 0, 2)

    $bottom = New-Object Windows.Forms.FlowLayoutPanel
    $bottom.Dock = 'Fill'
    $bottom.FlowDirection = 'LeftToRight'

    $copy = New-Object Windows.Forms.Button
    $copy.Text = 'Copy result'
    $copy.AutoSize = $true
    $copy.Add_Click({ Set-ClipboardQuietly $script:ResultBox.Text; $script:StatusLabel.Text = 'Copied to clipboard' })
    [void]$bottom.Controls.Add($copy)

    $again = New-Object Windows.Forms.Button
    $again.Text = 'Re-translate'
    $again.AutoSize = $true
    $again.Add_Click({ Invoke-FeatureChange })
    [void]$bottom.Controls.Add($again)

    $status = New-Object Windows.Forms.Label
    $status.AutoSize = $true
    $status.Padding = New-Object Windows.Forms.Padding(12, 8, 0, 0)
    $status.ForeColor = [Drawing.Color]::Gray
    [void]$bottom.Controls.Add($status)

    $table.Controls.Add($bottom, 0, 3)
    $form.Controls.Add($table)

    $form.Add_FormClosing({
        param($s, $e)
        # Keep the window warm; the tray icon is the real lifetime owner.
        if ($e.CloseReason -eq [Windows.Forms.CloseReason]::UserClosing) {
            $e.Cancel = $true
            $s.Hide()
        }
    })
    $form.Add_KeyDown({
        param($s, $e)
        if ($e.KeyCode -eq [Windows.Forms.Keys]::Escape) { $s.Hide() }
    })
    $form.KeyPreview = $true

    $script:Form = $form
    $script:SourceBox = $src
    $script:ResultBox = $result
    $script:StatusLabel = $status
    $script:FeaturePanel = $features
    return $form
}

function Invoke-FeatureChange {
    if (-not $script:FeaturePanel) { return }
    $checked = @($script:FeaturePanel.Controls | Where-Object { $_.Checked } | ForEach-Object { $_.Text })
    $script:Config.Features = ($checked -join ',')
    try { Save-Config $script:Config } catch { }
    if ($script:CurrentSource) {
        Set-Result -Text '' -Status 'Translating…'
        Start-Translation -Text $script:CurrentSource
    }
}

function Show-Translation {
    param([Parameter(Mandatory)][string]$Text)

    if (-not $script:Form -or $script:Form.IsDisposed) { [void](New-TranslatorWindow) }
    $script:CurrentSource = $Text
    $script:SourceBox.Text = $Text -replace "`r`n", "`n" -replace "`n", "`r`n"
    Set-Result -Text '' -Status 'Translating…'
    $script:Form.Show()
    $script:Form.WindowState = 'Normal'
    [void]$script:Form.Activate()
    Start-Translation -Text $Text
}

# --- Clipboard trigger ---------------------------------------------------------
$script:LastClipboardTick = [datetime]::MinValue
$script:IgnoreClipboardUntil = [datetime]::MinValue

function Get-ClipboardTextSafely {
    for ($i = 0; $i -lt 8; $i++) {
        try {
            if ([Windows.Forms.Clipboard]::ContainsText()) { return [Windows.Forms.Clipboard]::GetText() }
            return ''
        } catch { Start-Sleep -Milliseconds 40 }
    }
    return ''
}

function Invoke-ClipboardTrigger {
    $now = Get-Date
    if ($now -lt $script:IgnoreClipboardUntil) { return }

    $window = [int]$script:Config.DoubleCopyMs
    $isDouble = ($now - $script:LastClipboardTick).TotalMilliseconds -le $window
    $script:LastClipboardTick = $now
    if (-not $isDouble) { return }

    # A real Ctrl+C, Ctrl+C still has Ctrl down; apps that write the clipboard
    # twice on their own do not, which keeps the trigger from firing by accident.
    if (-not [LangHelper.ClipboardWatcher]::IsCtrlDown()) { return }
    $script:LastClipboardTick = [datetime]::MinValue

    $text = Get-ClipboardTextSafely
    if (-not $text) { return }
    $trimmed = $text.Trim()
    if ($trimmed.Length -lt [int]$script:Config.MinChars) { return }
    if ($trimmed.Length -gt [int]$script:Config.MaxChars) {
        $trimmed = $trimmed.Substring(0, [int]$script:Config.MaxChars)
    }
    Show-Translation -Text $trimmed
}

# --- Tray ----------------------------------------------------------------------
function New-TrayIcon {
    $bmp = New-Object Drawing.Bitmap 32, 32
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([Drawing.Color]::Transparent)
    $g.FillEllipse((New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(255, 30, 145, 90))), 0, 0, 31, 31)
    $fmt = New-Object Drawing.StringFormat
    $fmt.Alignment = 'Center'
    $fmt.LineAlignment = 'Center'
    $g.DrawString('H', (New-Object Drawing.Font('Segoe UI', 16, [Drawing.FontStyle]::Bold)),
        [Drawing.Brushes]::White, (New-Object Drawing.RectangleF(0, 0, 32, 32)), $fmt)
    $g.Dispose()
    $icon = [Drawing.Icon]::FromHandle($bmp.GetHicon())
    $bmp.Dispose()
    return $icon
}

$menu = New-Object Windows.Forms.ContextMenuStrip

$miTranslate = $menu.Items.Add('Translate clipboard now')
$miTranslate.Add_Click({
    $t = Get-ClipboardTextSafely
    if ($t.Trim()) { Show-Translation -Text $t.Trim() }
})

$miProvider = New-Object Windows.Forms.ToolStripMenuItem 'Provider'
foreach ($p in @('auto', 'vscode', 'copilot-cli')) {
    $item = New-Object Windows.Forms.ToolStripMenuItem $p
    $item.Tag = $p
    $item.Checked = ($script:Config.Provider -eq $p)
    $item.Add_Click({
        param($s, $e)
        $script:Config.Provider = [string]$s.Tag
        foreach ($sib in $s.Owner.Items) { $sib.Checked = ($sib.Tag -eq $s.Tag) }
        Save-Config $script:Config
        Write-Log "provider set to $($script:Config.Provider)"
    })
    [void]$miProvider.DropDownItems.Add($item)
}
[void]$menu.Items.Add($miProvider)

$miLast = $menu.Items.Add('Show last result')
$miLast.Add_Click({
    $f = Join-Path $script:DataDir 'last-result.txt'
    if (Test-Path -LiteralPath $f) {
        if (-not $script:Form -or $script:Form.IsDisposed) { [void](New-TranslatorWindow) }
        $script:Form.Show()
        Set-Result -Text ([System.IO.File]::ReadAllText($f, $script:Utf8)) -Status 'Last result'
    }
})

$miHistory = $menu.Items.Add('Open history')
$miHistory.Add_Click({
    $f = Join-Path $script:DataDir 'history.jsonl'
    if (Test-Path -LiteralPath $f) { Start-Process notepad.exe $f } else {
        [Windows.Forms.MessageBox]::Show('No history yet.', 'LangHelper', 'OK', 'Information') | Out-Null
    }
})

$miLog = $menu.Items.Add('Open log')
$miLog.Add_Click({
    $f = Join-Path $script:LogDir ("langhelper_{0}.log" -f (Get-Date -Format 'yyyyMM'))
    if (Test-Path -LiteralPath $f) { Start-Process notepad.exe $f }
})

$miConfig = $menu.Items.Add('Edit langhelper.ini')
$miConfig.Add_Click({
    if (-not (Test-Path -LiteralPath $script:IniPath)) { Save-Config $script:Config }
    Start-Process notepad.exe $script:IniPath
})

$miReload = $menu.Items.Add('Reload config')
$miReload.Add_Click({
    $script:Config = Read-Config
    if ($script:Form -and -not $script:Form.IsDisposed) { $script:Form.Dispose(); $script:Form = $null }
    Write-Log 'config reloaded'
})

[void]$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
$miExit = $menu.Items.Add('Exit')

$tray = New-Object Windows.Forms.NotifyIcon
$tray.Icon = New-TrayIcon
$tray.Text = 'LangHelper — Ctrl+C, Ctrl+C to translate'
$tray.Visible = $true
$tray.ContextMenuStrip = $menu
$tray.Add_MouseDoubleClick({
    $t = Get-ClipboardTextSafely
    if ($t.Trim()) { Show-Translation -Text $t.Trim() }
})

# --- Wire up and run -----------------------------------------------------------
$watcher = New-Object LangHelper.ClipboardWatcher
$watcher.add_ClipboardUpdate({ Invoke-ClipboardTrigger })

# The backend runs in its own runspace; this pump moves the result onto the UI thread.
$pump = New-Object Windows.Forms.Timer
$pump.Interval = 120
$pump.Add_Tick({ Complete-Translation })
$pump.Start()

$context = New-Object Windows.Forms.ApplicationContext
$miExit.Add_Click({
    $pump.Stop()
    Stop-Translation
    $tray.Visible = $false
    $tray.Dispose()
    $watcher.Dispose()
    $context.ExitThread()
})

Write-Log "started (provider=$($script:Config.Provider), features=$($script:Config.Features))"
$tray.ShowBalloonTip(3000, 'LangHelper', 'Ready. Press Ctrl+C twice to translate.', 'Info')

if ($Translate) {
    $t = Get-ClipboardTextSafely
    if ($t.Trim()) { Show-Translation -Text $t.Trim() }
}

try {
    [Windows.Forms.Application]::Run($context)
} finally {
    Write-Log 'stopped'
    $script:Mutex.ReleaseMutex()
    $script:Mutex.Dispose()
}
