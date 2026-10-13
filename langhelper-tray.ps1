#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ConfigFile = '',
    [switch]$Translate,
    [switch]$TestMode
)

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSEdition -eq 'Core' -or [Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $arguments = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath))
    if ($ConfigFile) { $arguments += @('-ConfigFile', ('"{0}"' -f $ConfigFile)) }
    if ($Translate) { $arguments += '-Translate' }
    if ($TestMode) { throw 'UI tests must run in Windows PowerShell 5.1 with -STA.' }
    Start-Process "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $arguments
    return
}

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$script:Root = $PSScriptRoot
$script:Backend = Join-Path $script:Root 'langhelper.ps1'
. (Join-Path $script:Root 'langhelper-common.ps1')
$script:IniPath = if ($ConfigFile) { $ConfigFile } else { Join-Path $script:Root 'langhelper.ini' }
try { $script:Config = Read-LangHelperConfig $script:IniPath }
catch {
    [Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Invalid LangHelper settings') | Out-Null
    throw
}
$script:DataDir = Split-Path -Parent (Get-LangHelperBridgeRoot)
$script:LogDir = Join-Path $script:Root 'logs'
$script:Utf8 = New-Object Text.UTF8Encoding $false
$script:Windows = New-Object System.Collections.Generic.List[object]
$script:LastClipboardTick = [datetime]::MinValue
$script:IgnoreClipboardUntil = [datetime]::MinValue
foreach ($directory in @($script:DataDir, $script:LogDir)) {
    [void][IO.Directory]::CreateDirectory($directory)
}

function Write-Log {
    param([string]$Message)
    $path = Join-Path $script:LogDir ("langhelper_{0}.log" -f (Get-Date -Format 'yyyyMM'))
    $safe = $Message -replace [regex]::Escape($env:USERPROFILE), '%USERPROFILE%'
    Add-Content -LiteralPath $path -Encoding UTF8 -Value ("{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $safe)
}

function Save-Config {
    Save-LangHelperConfig $script:Config $script:IniPath (Join-Path $script:Root 'langhelper.ini.example')
}

function Set-BoxText {
    param($Box, [string]$Text)
    $Box.Text = $Text -replace "\r?\n", "`r`n"
    $Box.Select(0, 0)
    $Box.ScrollToCaret()
}

function Set-Status {
    param($Window, [string]$Text, [switch]$ErrorStatus)
    $Window.Status.Text = $Text
    $Window.Status.ForeColor = if ($ErrorStatus) { [Drawing.Color]::Firebrick } else { [Drawing.Color]::DarkSlateGray }
}

function Set-ClipboardQuietly {
    param([string]$Text)
    $script:IgnoreClipboardUntil = (Get-Date).AddMilliseconds(1500)
    [Windows.Forms.Clipboard]::SetText($Text)
}

function Get-ClipboardTextSafely {
    for ($i = 0; $i -lt 8; $i++) {
        try {
            if ([Windows.Forms.Clipboard]::ContainsText()) { return [Windows.Forms.Clipboard]::GetText() }
            return ''
        } catch [Runtime.InteropServices.ExternalException] {
            Start-Sleep -Milliseconds 40
        }
    }
    throw 'Clipboard is busy. Try copying again.'
}

function Stop-WindowJob {
    param($Window, [string]$Property = 'Job')
    $job = $Window.$Property
    if (-not $job) { return }
    $Window.$Property = $null
    try {
        $job.Shell.Stop()
    } finally {
        $job.Shell.Dispose()
        foreach ($file in @($job.InputFile, $job.OutputFile)) {
            if ($file -and (Test-Path -LiteralPath $file)) { Remove-Item -LiteralPath $file -Force }
        }
    }
}

function Start-ModelRefresh {
    param($Window)
    Stop-WindowJob $Window 'CatalogJob'
    $provider = [string]$Window.Provider.SelectedItem
    $Window.Model.Items.Clear()
    $Window.Models = @()
    $Window.CatalogAvailable = $false
    if ($provider -eq 'copilot-cli') {
        $Window.Model.DropDownStyle = 'DropDown'
        $Window.Model.Text = $Window.CliModel
        $Window.ModelHint.Text = 'CLI: enter a model ID; no verified CLI catalog is available.'
        return
    }
    $Window.Model.DropDownStyle = 'DropDownList'
    $Window.ModelHint.Text = 'Loading VS Code models...'
    $shell = [powershell]::Create()
    [void]$shell.AddScript({
        param($common)
        . $common
        Invoke-LangHelperBridge -Payload @{ action = 'models' } -TimeoutSec 15
    }).AddArgument((Join-Path $script:Root 'langhelper-common.ps1'))
    $Window.CatalogJob = [pscustomobject]@{
        Shell = $shell; Handle = $shell.BeginInvoke(); InputFile = ''; OutputFile = ''
    }
}

function Complete-ModelRefresh {
    param($Window)
    $job = $Window.CatalogJob
    if (-not $job -or -not $job.Handle.IsCompleted) { return }
    $Window.CatalogJob = $null
    try {
        $data = @($job.Shell.EndInvoke($job.Handle))
        if ($job.Shell.Streams.Error.Count) { throw ($job.Shell.Streams.Error | Out-String) }
        if (-not $data.Count) { throw 'Bridge returned no model catalog. Reinstall the bridge and reload VS Code.' }
        $Window.Models = @($data[-1].models)
        if (-not $Window.Models.Count) { throw 'No Copilot models are available to this VS Code account.' }
        $Window.CatalogAvailable = $true
        [void]$Window.Model.Items.Add('(Provider default)')
        $selected = -1
        for ($i = 0; $i -lt $Window.Models.Count; $i++) {
            $model = $Window.Models[$i]
            [void]$Window.Model.Items.Add("$($model.name) [$($model.id)]")
            if ($model.id -eq $Window.VSCodeModel -or $model.family -eq $Window.VSCodeModel) { $selected = $i + 1 }
        }
        if (-not $Window.VSCodeModel) { $selected = 0 }
        $Window.Model.SelectedIndex = $selected
        if ($selected -lt 0) {
            $Window.ModelHint.Text = "Requested model unavailable: $($Window.VSCodeModel). Select a model."
        } else {
            $Window.ModelHint.Text = 'VS Code catalog (auto uses this list; CLI fallback is reported).'
        }
    } catch {
        $Window.ModelHint.Text = $_.Exception.Message
        if ($Window.Provider.SelectedItem -eq 'auto' -and $Window.VSCodeModel) {
            [void]$Window.Model.Items.Add("Saved model [$($Window.VSCodeModel)] (unverified)")
            $Window.Model.SelectedIndex = 0
            $Window.ModelHint.Text += " Auto will try saved model $($Window.VSCodeModel); CLI compatibility is not verified."
        }
        Set-Status $Window $Window.ModelHint.Text -ErrorStatus
        Write-Log "model lookup failed: $($_.Exception.Message)"
    } finally {
        $job.Shell.Dispose()
    }
}

function Get-WindowModel {
    param($Window)
    if ($Window.Provider.SelectedItem -eq 'copilot-cli') {
        $value = $Window.Model.Text.Trim()
        if (-not $value) { throw 'Enter an explicit CLI model ID before translating.' }
        $Window.CliModel = $value
        return $value
    }
    if ($Window.Provider.SelectedItem -eq 'auto' -and -not $Window.CatalogAvailable) {
        if (-not $Window.VSCodeModel) { throw 'Auto without a VS Code catalog requires a saved explicit model ID. Configure the CLI provider and save its model as defaults.' }
        return [string]$Window.VSCodeModel
    }
    if ($Window.Model.SelectedIndex -lt 0) { throw 'Select an available VS Code model, or refresh the model list.' }
    if ($Window.Model.SelectedIndex -eq 0) { $Window.VSCodeModel = ''; return '' }
    $model = $Window.Models[$Window.Model.SelectedIndex - 1]
    $Window.VSCodeModel = $model.id
    return [string]$model.id
}

function Start-Translation {
    param($Window)
    try {
        $text = $Window.Source.Text.Trim()
        if (-not $text) { throw 'Source is empty.' }
        $model = Get-WindowModel $Window
        Stop-WindowJob $Window
        $id = [guid]::NewGuid().ToString('n')
        $inputFile = Join-Path $script:DataDir "req-$id.txt"
        $outputFile = Join-Path $script:DataDir "res-$id.txt"
        [IO.File]::WriteAllText($inputFile, $text, $script:Utf8)
        $parameters = @{
            Provider = [string]$Window.Provider.SelectedItem
            Model = $model
            Features = if ($Window.PromptInfo.Modular) { $Window.Features } else { '' }
            PromptFile = $Window.PromptFile
            InputFile = $inputFile; OutputFile = $outputFile
            TimeoutSec = [int]$Window.TimeoutSec; PassThru = $true
        }
        $shell = [powershell]::Create()
        [void]$shell.AddCommand($script:Backend).AddParameters($parameters)
        $Window.Job = [pscustomobject]@{
            Shell = $shell; Handle = $shell.BeginInvoke()
            InputFile = $inputFile; OutputFile = $outputFile
            Watch = [Diagnostics.Stopwatch]::StartNew()
            Source = $text; Features = $parameters.Features
            RequestedModel = $model; RequestedProvider = $parameters.Provider
        }
        Set-BoxText $Window.Result ''
        Set-BoxText $Window.Notes ''
        Set-Status $Window "Translating via $($parameters.Provider)..."
        Write-Log "translate: $($text.Length) chars, provider=$($parameters.Provider), model=$model"
    } catch {
        Set-Status $Window $_.Exception.Message -ErrorStatus
        Write-Log "translation start failed: $($_.Exception.Message)"
    }
}

function Complete-Translation {
    param($Window)
    $job = $Window.Job
    if (-not $job) { return }
    if (-not $job.Handle.IsCompleted) {
        Set-Status $Window ("Translating via {0} - {1:n1} s" -f $job.RequestedProvider, $job.Watch.Elapsed.TotalSeconds)
        return
    }
    $Window.Job = $null
    try {
        $responses = @($job.Shell.EndInvoke($job.Handle))
        if ($job.Shell.Streams.Error.Count) { throw ($job.Shell.Streams.Error | Out-String) }
        if (-not $responses.Count -or -not $responses[-1].Content) { throw 'Backend returned no translation metadata.' }
        $response = $responses[-1]
        $split = Split-LangHelperResult $response.Content
        Set-BoxText $Window.Result $split.Main
        Set-BoxText $Window.Notes $split.Notes
        $modelLabel = $response.ModelId
        if (-not $response.ModelVerified) { $modelLabel = "$modelLabel (requested; CLI model not verified)" }
        $status = "Done in {0:n3} s | {1} | {2}" -f $job.Watch.Elapsed.TotalSeconds, $response.Provider, $modelLabel
        if ($response.Fallback) { $status += ' | FALLBACK'; Write-Log ("fallback: " + ($response.Failures -join '; ')) }
        Set-Status $Window $status
        Write-Log $status
        $row = @{
            at = (Get-Date).ToString('o'); source = $job.Source; result = $response.Content
            features = $job.Features; provider = $response.Provider; model = $response.ModelId
            modelVerified = $response.ModelVerified; elapsedMs = $job.Watch.ElapsedMilliseconds
        } | ConvertTo-Json -Depth 4 -Compress
        # The translation already succeeded; report each persistence failure on its own
        # so a locked history file cannot leave an older last-result.txt behind.
        try { Add-Content -LiteralPath (Join-Path $script:DataDir 'history.jsonl') -Value $row -Encoding UTF8 }
        catch { Write-Log "could not write history: $($_.Exception.Message)" }
        try { [IO.File]::WriteAllText((Join-Path $script:DataDir 'last-result.txt'), $response.Content, $script:Utf8) }
        catch { Write-Log "could not write last result: $($_.Exception.Message)" }
        if ($Window.AutoCopy -and $split.Main) { Set-ClipboardQuietly $split.Main }
    } catch {
        Set-Status $Window $_.Exception.Message -ErrorStatus
        Write-Log "translation failed: $($_.Exception.Message)"
    } finally {
        $job.Shell.Dispose()
        foreach ($file in @($job.InputFile, $job.OutputFile)) {
            if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
        }
    }
}

function Show-FeatureSettings {
    param($Window)
    if (-not $Window.PromptInfo.Modular) { return }
    $dialog = New-Object Windows.Forms.Form
    $dialog.Text = 'Configure features'
    $dialog.Size = New-Object Drawing.Size(450, 440)
    $dialog.StartPosition = 'CenterParent'
    $list = New-Object Windows.Forms.CheckedListBox
    $list.Dock = 'Fill'
    $list.CheckOnClick = $true
    foreach ($name in $Window.PromptInfo.Features) { [void]$list.Items.Add($name, ($Window.Features.Split(',') -contains $name)) }
    $save = New-Object Windows.Forms.Button
    $save.Text = 'Apply'
    $save.Dock = 'Bottom'
    $save.DialogResult = 'OK'
    $dialog.Controls.Add($list)
    $dialog.Controls.Add($save)
    $dialog.AcceptButton = $save
    try {
        if ($dialog.ShowDialog($Window.Form) -eq 'OK') {
            $Window.Features = @($list.CheckedItems) -join ','
            $Window.FeatureLabel.Text = "Features: $($Window.Features)"
        }
    } finally { $dialog.Dispose() }
}

function New-TextArea {
    param([bool]$ReadOnly)
    $box = New-Object Windows.Forms.TextBox
    $box.Multiline = $true
    $box.AcceptsReturn = -not $ReadOnly
    $box.ReadOnly = $ReadOnly
    $box.ScrollBars = 'Vertical'
    $box.Dock = 'Fill'
    $box.BackColor = if ($ReadOnly) { [Drawing.Color]::WhiteSmoke } else { [Drawing.Color]::White }
    return $box
}

function New-TranslatorWindow {
    $prompt = $script:Config.PromptFile
    if (-not $prompt) { $prompt = Join-Path $script:Root 'prompt.md' }
    $info = Get-LangHelperPromptInfo $prompt
    $form = New-Object Windows.Forms.Form
    $form.Text = 'LangHelper'
    $form.Size = New-Object Drawing.Size(960, 850)
    $form.MinimumSize = New-Object Drawing.Size(820, 650)
    $form.StartPosition = 'CenterScreen'
    $form.TopMost = ($script:Config.AlwaysOnTop -eq '1')
    $form.Font = New-Object Drawing.Font('Segoe UI', 10)
    $form.KeyPreview = $true
    $window = [pscustomobject]@{
        Form = $form; Source = (New-TextArea $false); Snapshot = (New-TextArea $true)
        Result = (New-TextArea $true); Notes = (New-TextArea $true)
        Status = (New-Object Windows.Forms.Label)
        Provider = (New-Object Windows.Forms.ComboBox); Model = (New-Object Windows.Forms.ComboBox)
        ModelHint = (New-Object Windows.Forms.Label); FeatureLabel = (New-Object Windows.Forms.Label)
        Models = @(); CatalogAvailable = $false; VSCodeModel = $script:Config.Model; CliModel = ''
        Job = $null; CatalogJob = $null; PendingTranslate = $false
        Features = $script:Config.Features; PromptFile = $prompt; PromptInfo = $info
        TimeoutSec = $script:Config.TimeoutSec; AutoCopy = ($script:Config.AutoCopyResult -eq '1')
    }
    if ($script:Config.Provider -eq 'copilot-cli') { $window.CliModel = $script:Config.Model }
    $form.Tag = $window
    $table = New-Object Windows.Forms.TableLayoutPanel
    $table.Dock = 'Fill'
    $table.Padding = New-Object Windows.Forms.Padding(12)
    $table.ColumnCount = 1
    $table.RowCount = 13
    foreach ($height in @(38, 34, 26, -26, 26, -12, 36, 40, 26, -30, 26, -32, 40)) {
        $type = if ($height -lt 0) { [Windows.Forms.SizeType]::Percent } else { [Windows.Forms.SizeType]::Absolute }
        [void]$table.RowStyles.Add((New-Object Windows.Forms.RowStyle($type, [math]::Abs($height))))
    }
    $controls = New-Object Windows.Forms.FlowLayoutPanel
    $controls.Dock = 'Fill'
    $window.Provider.DropDownStyle = 'DropDownList'
    $window.Provider.Width = 130
    $window.Provider.Items.AddRange(@('vscode', 'copilot-cli', 'auto'))
    $window.Provider.SelectedItem = $script:Config.Provider
    $window.Model.Width = 430
    $refresh = New-Object Windows.Forms.Button
    $refresh.Text = 'Refresh models'
    $refresh.AutoSize = $true
    foreach ($control in @($window.Provider, $window.Model, $refresh)) { [void]$controls.Controls.Add($control) }
    $table.Controls.Add($controls, 0, 0)
    $window.ModelHint.Dock = 'Fill'
    $table.Controls.Add($window.ModelHint, 0, 1)
    foreach ($entry in @(@(2, 'Source (editable)'), @(4, 'Original clipboard snapshot'), @(8, 'Translation (Copy result copies this)'), @(10, 'Notes / back-translation'))) {
        $label = New-Object Windows.Forms.Label
        $label.Text = $entry[1]; $label.Dock = 'Fill'
        $table.Controls.Add($label, 0, $entry[0])
    }
    $table.Controls.Add($window.Source, 0, 3)
    $table.Controls.Add($window.Snapshot, 0, 5)
    $table.Controls.Add($window.Result, 0, 9)
    $table.Controls.Add($window.Notes, 0, 11)
    $featureRow = New-Object Windows.Forms.FlowLayoutPanel
    $featureRow.Dock = 'Fill'
    $configure = New-Object Windows.Forms.Button
    $configure.Text = 'Configure features'
    $configure.AutoSize = $true
    $configure.Enabled = $info.Modular
    $window.FeatureLabel.AutoSize = $true
    $window.FeatureLabel.Text = if ($info.Modular) { "Features: $($window.Features)" } else {
        [regex]::Unescape('\u4f7f\u7528\u5916\u90e8 prompt\uff0cFeatures \u4e0d\u9069\u7528')
    }
    [void]$featureRow.Controls.Add($configure)
    [void]$featureRow.Controls.Add($window.FeatureLabel)
    $table.Controls.Add($featureRow, 0, 6)
    $window.Status.Dock = 'Fill'
    $table.Controls.Add($window.Status, 0, 7)
    $buttons = New-Object Windows.Forms.FlowLayoutPanel
    $buttons.Dock = 'Fill'
    $translateButton = New-Object Windows.Forms.Button
    $translateButton.Text = '&Re-translate'; $translateButton.AutoSize = $true
    $copy = New-Object Windows.Forms.Button
    $copy.Text = '&Copy result'; $copy.AutoSize = $true
    $defaults = New-Object Windows.Forms.Button
    $defaults.Text = 'Save as defaults'; $defaults.AutoSize = $true
    $close = New-Object Windows.Forms.Button
    $close.Text = 'Close'; $close.AutoSize = $true
    foreach ($button in @($translateButton, $copy, $defaults)) { [void]$buttons.Controls.Add($button) }
    $buttonRow = New-Object Windows.Forms.Panel
    $buttonRow.Dock = 'Fill'
    $buttons.WrapContents = $false
    $buttons.AutoSize = $true
    $buttons.Dock = 'Left'
    $buttonRow.Controls.Add($buttons)
    $close.Name = 'CloseButton'
    $close.Anchor = 'Top, Right'
    $buttonRow.Controls.Add($close)
    $buttonRow.Add_Resize({
        param($s, $e)
        $closeButton = $s.Controls['CloseButton']
        $margin = $closeButton.Margin
        $closeButton.Location = New-Object Drawing.Point([math]::Max(0, $s.ClientSize.Width - $closeButton.Width - $margin.Right), $margin.Top)
    })
    $window | Add-Member -NotePropertyName CloseButton -NotePropertyValue $close
    $table.Controls.Add($buttonRow, 0, 12)
    $form.Controls.Add($table)
    $form.AcceptButton = $translateButton
    $refresh.Add_Click({ param($s, $e) Start-ModelRefresh $s.FindForm().Tag })
    $window.Provider.Add_SelectedIndexChanged({
        param($s, $e)
        $w = $s.FindForm().Tag
        if ($w.Job) { Stop-WindowJob $w; Set-Status $w 'Provider changed; previous translation cancelled.' }
        $w.PendingTranslate = $false
        Start-ModelRefresh $w
    })
    $window.Model.Add_SelectedIndexChanged({
        param($s, $e)
        $w = $s.FindForm().Tag
        if ($w.CatalogAvailable -and $w.Provider.SelectedItem -ne 'copilot-cli' -and $s.SelectedIndex -ge 0) {
            $w.VSCodeModel = if ($s.SelectedIndex -eq 0) { '' } else { $w.Models[$s.SelectedIndex - 1].id }
        }
    })
    $translateButton.Add_Click({ param($s, $e) Start-Translation $s.FindForm().Tag })
    $configure.Add_Click({ param($s, $e) Show-FeatureSettings $s.FindForm().Tag })
    $copy.Add_Click({
        param($s, $e)
        $w = $s.FindForm().Tag
        try {
            if (-not $w.Result.Text) { throw 'No translation to copy.' }
            Set-ClipboardQuietly $w.Result.Text
            Set-Status $w 'Main translation copied.'
        } catch { Set-Status $w $_.Exception.Message -ErrorStatus }
    })
    $defaults.Add_Click({
        param($s, $e)
        $w = $s.FindForm().Tag
        try {
            $script:Config.Model = Get-WindowModel $w
            $script:Config.Provider = [string]$w.Provider.SelectedItem
            $script:Config.Features = $w.Features
            Save-Config
            Set-Status $w 'Defaults saved for new windows.'
        } catch { Set-Status $w $_.Exception.Message -ErrorStatus }
    })
    $close.Add_Click({ param($s, $e) $s.FindForm().Close() })
    $form.Add_KeyDown({ param($s, $e) if ($e.KeyCode -eq 'Escape') { $s.Close() } })
    $form.Add_FormClosed({
        param($s, $e)
        Stop-WindowJob $s.Tag
        Stop-WindowJob $s.Tag 'CatalogJob'
        [void]$script:Windows.Remove($s.Tag)
    })
    [void]$script:Windows.Add($window)
    if (-not $TestMode) { Start-ModelRefresh $window }
    return $window
}

function Show-Translation {
    param([string]$Text, [switch]$NoTranslate)
    $window = $null
    if ($script:Config.SingleWindow -eq '1' -and $script:Windows.Count) { $window = $script:Windows[$script:Windows.Count - 1] }
    if (-not $window) { $window = New-TranslatorWindow }
    Stop-WindowJob $window
    Set-BoxText $window.Source $Text
    Set-BoxText $window.Snapshot $Text
    Set-BoxText $window.Result ''
    Set-BoxText $window.Notes ''
    $window.Form.Show()
    $window.Form.WindowState = 'Normal'
    [void]$window.Form.Activate()
    Set-Status $window 'Ready'
    $window.PendingTranslate = -not $NoTranslate
    if ($window.PendingTranslate -and -not $window.CatalogJob) {
        $window.PendingTranslate = $false
        Start-Translation $window
    }
    return $window
}

function Invoke-ClipboardTrigger {
    try {
        $now = Get-Date
        if ($now -lt $script:IgnoreClipboardUntil) { return }
        $double = ($now - $script:LastClipboardTick).TotalMilliseconds -le [int]$script:Config.DoubleCopyMs
        $script:LastClipboardTick = $now
        if (-not $double -or -not [LangHelper.ClipboardWatcher]::IsCtrlDown()) { return }
        $script:LastClipboardTick = [datetime]::MinValue
        $text = (Get-ClipboardTextSafely).Trim()
        if ($text.Length -lt [int]$script:Config.MinChars) { return }
        $truncated = $text.Length -gt [int]$script:Config.MaxChars
        if ($truncated) { $text = $text.Substring(0, [int]$script:Config.MaxChars) }
        $w = Show-Translation $text
        if ($truncated) { $w.ModelHint.Text += " | Input truncated to $($script:Config.MaxChars) chars."; Write-Log 'Clipboard input truncated.' }
    } catch {
        Write-Log "clipboard trigger failed: $($_.Exception.Message)"
        [Windows.Forms.MessageBox]::Show($_.Exception.Message, 'LangHelper') | Out-Null
    }
}

if ($TestMode) { return }

function New-TrayIcon {
    $bitmap = New-Object Drawing.Bitmap 32, 32
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    $brush = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(30, 145, 90))
    $font = New-Object Drawing.Font('Segoe UI', 16, [Drawing.FontStyle]::Bold)
    $format = New-Object Drawing.StringFormat
    $format.Alignment = 'Center'
    $format.LineAlignment = 'Center'
    try {
        $graphics.Clear([Drawing.Color]::Transparent)
        $graphics.FillEllipse($brush, 0, 0, 31, 31)
        $graphics.DrawString('H', $font, [Drawing.Brushes]::White, (New-Object Drawing.RectangleF(0, 0, 32, 32)), $format)
        $handle = $bitmap.GetHicon()
        $icon = [Drawing.Icon]::FromHandle($handle)
        try { return $icon.Clone() } finally { $icon.Dispose(); [void][LangHelper.ClipboardWatcher]::DestroyIcon($handle) }
    } finally { $format.Dispose(); $font.Dispose(); $brush.Dispose(); $graphics.Dispose(); $bitmap.Dispose() }
}

$mutex = New-Object Threading.Mutex($false, 'Local\LangHelper.Tray')
$owned = $false
$tray = $null
$watcher = $null
$pump = $null
$context = $null
try {
    try { $owned = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned = $true }
    if (-not $owned) {
        [Windows.Forms.MessageBox]::Show('LangHelper is already running. Exit the existing green H tray icon first.', 'LangHelper') | Out-Null
        return
    }
    Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Windows.Forms;
namespace LangHelper {
    public class ClipboardWatcher : NativeWindow, IDisposable {
        public event EventHandler ClipboardUpdate;
        [DllImport("user32.dll", SetLastError=true)] static extern bool AddClipboardFormatListener(IntPtr hwnd);
        [DllImport("user32.dll")] static extern bool RemoveClipboardFormatListener(IntPtr hwnd);
        [DllImport("user32.dll")] static extern short GetAsyncKeyState(int key);
        [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr icon);
        public ClipboardWatcher() {
            CreateHandle(new CreateParams());
            if (!AddClipboardFormatListener(Handle)) {
                int error = Marshal.GetLastWin32Error();
                DestroyHandle();
                throw new Win32Exception(error);
            }
        }
        public static bool IsCtrlDown() { return (GetAsyncKeyState(0x11) & 0x8000) != 0; }
        protected override void WndProc(ref Message m) {
            if (m.Msg == 0x031D && ClipboardUpdate != null) ClipboardUpdate(this, EventArgs.Empty);
            base.WndProc(ref m);
        }
        public void Dispose() { RemoveClipboardFormatListener(Handle); DestroyHandle(); }
    }
}
'@
    $menu = New-Object Windows.Forms.ContextMenuStrip
    $open = $menu.Items.Add('Open translator window')
    $open.Add_Click({ [void](Show-Translation '' -NoTranslate) })
    $now = $menu.Items.Add('Translate clipboard now')
    $now.Add_Click({
        try { $text = Get-ClipboardTextSafely; if ($text.Trim()) { [void](Show-Translation $text.Trim()) } }
        catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message, 'LangHelper') | Out-Null }
    })
    $providerMenu = New-Object Windows.Forms.ToolStripMenuItem 'Provider (new windows)'
    $script:ProviderMenu = $providerMenu
    foreach ($provider in @('vscode', 'copilot-cli', 'auto')) {
        $item = New-Object Windows.Forms.ToolStripMenuItem $provider
        $item.Tag = $provider
        $item.Checked = ($provider -eq $script:Config.Provider)
        $item.Add_Click({
            param($s, $e)
            try {
                $previous = [string]$script:Config.Provider
                $script:Config.Provider = [string]$s.Tag
                # Model IDs are provider-specific; do not carry a VS Code ID into CLI,
                # but keep a custom VS Code model when moving between vscode and auto.
                if ($s.Tag -eq 'copilot-cli') { $script:Config.Model = '' }
                elseif ($previous -eq 'copilot-cli' -or -not [string]$script:Config.Model) { $script:Config.Model = 'claude-sonnet-5.5' }
                Save-Config
                foreach ($sibling in $s.Owner.Items) { $sibling.Checked = ($sibling.Tag -eq $s.Tag) }
            } catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message, 'LangHelper') | Out-Null }
        })
        [void]$providerMenu.DropDownItems.Add($item)
    }
    [void]$menu.Items.Add($providerMenu)
    $last = $menu.Items.Add('Show last result')
    $last.Add_Click({
        $file = Join-Path $script:DataDir 'last-result.txt'
        if (Test-Path -LiteralPath $file) {
            $w = Show-Translation '' -NoTranslate
            $split = Split-LangHelperResult ([IO.File]::ReadAllText($file))
            Set-BoxText $w.Result $split.Main
            Set-BoxText $w.Notes $split.Notes
            Set-Status $w 'Last saved result'
        }
    })
    foreach ($entry in @(@('Open history', (Join-Path $script:DataDir 'history.jsonl')), @('Open log', (Join-Path $script:LogDir ("langhelper_{0}.log" -f (Get-Date -Format 'yyyyMM')))), @('Edit langhelper.ini', $script:IniPath))) {
        $item = $menu.Items.Add($entry[0]); $item.Tag = $entry[1]
        $item.Add_Click({ param($s, $e) if (Test-Path -LiteralPath $s.Tag) { Start-Process notepad.exe -ArgumentList ('"{0}"' -f $s.Tag) } })
    }
    $reload = $menu.Items.Add('Reload config (new windows)')
    $reload.Add_Click({
        try {
            $script:Config = Read-LangHelperConfig $script:IniPath
            foreach ($providerItem in $script:ProviderMenu.DropDownItems) { $providerItem.Checked = ($providerItem.Tag -eq $script:Config.Provider) }
            Write-Log 'Config reloaded for new windows.'
        }
        catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Invalid LangHelper settings') | Out-Null }
    })
    $exit = $menu.Items.Add('Exit')
    $context = New-Object Windows.Forms.ApplicationContext
    $exit.Add_Click({ $context.ExitThread() })
    $tray = New-Object Windows.Forms.NotifyIcon
    $tray.Icon = New-TrayIcon
    $tray.Text = 'LangHelper - Ctrl+C, Ctrl+C'
    $tray.ContextMenuStrip = $menu
    $tray.Visible = $true
    $tray.Add_MouseDoubleClick({ [void](Show-Translation '' -NoTranslate) })
    $watcher = New-Object LangHelper.ClipboardWatcher
    $watcher.add_ClipboardUpdate({ Invoke-ClipboardTrigger })
    $pump = New-Object Windows.Forms.Timer
    $pump.Interval = 100
    $pump.Add_Tick({
        foreach ($w in @($script:Windows.ToArray())) {
            Complete-ModelRefresh $w
            if ($w.PendingTranslate -and -not $w.CatalogJob) { $w.PendingTranslate = $false; Start-Translation $w }
            Complete-Translation $w
        }
    })
    $pump.Start()
    Write-Log "started (provider=$($script:Config.Provider), SingleWindow=$($script:Config.SingleWindow))"
    if ($Translate) { [void](Show-Translation (Get-ClipboardTextSafely)) }
    [Windows.Forms.Application]::Run($context)
} catch {
    Write-Log "startup/runtime failure: $($_.Exception.Message)"
    [Windows.Forms.MessageBox]::Show($_.Exception.Message, 'LangHelper failed') | Out-Null
    throw
} finally {
    if ($pump) { $pump.Stop(); $pump.Dispose() }
    foreach ($w in @($script:Windows.ToArray())) { $w.Form.Close(); $w.Form.Dispose() }
    if ($watcher) { $watcher.Dispose() }
    if ($tray) { $tray.Visible = $false; if ($tray.Icon) { $tray.Icon.Dispose() }; $tray.Dispose() }
    if ($context) { $context.Dispose() }
    if ($owned) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
