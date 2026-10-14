#requires -Version 5.1
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("langhelper-ui-test-" + [guid]::NewGuid().ToString('n'))
[void][IO.Directory]::CreateDirectory($testRoot)
$configPath = Join-Path $testRoot 'langhelper.ini'
$customIni = [IO.File]::ReadAllText((Join-Path $repo 'langhelper.ini.example')).Replace('Model=claude-sonnet-5.5', 'Model=ini-custom-model')
[IO.File]::WriteAllText($configPath, $customIni, (New-Object Text.UTF8Encoding $false))
function Assert($condition, $message) { if (-not $condition) { throw $message } }
try {
    . (Join-Path $repo 'langhelper-tray.ps1') -ConfigFile $configPath -TestMode
    $script:Backend = Join-Path $repo 'tests\fake-backend.ps1'
    $script:DataDir = $testRoot
    $script:LogDir = $testRoot
    $script:Config.AutoCopyResult = '0'
    $script:CopiedText = ''
    function Set-ClipboardQuietly { param([string]$Text) $script:CopiedText = $Text }
    $cfg = Read-LangHelperConfig $configPath
    Assert ($cfg.Provider -eq 'vscode' -and $cfg.Model -eq 'ini-custom-model') 'Wrong defaults.'
    Assert ($cfg.SingleWindow -eq '0' -and $cfg.AutoCopyResult -eq '1') 'Wrong window/copy defaults.'
    Assert (-not $cfg.Contains('SaveHistory')) 'SaveHistory must be removed.'
    $cfg.Model = 'one,two'
    Save-LangHelperConfig $cfg $configPath (Join-Path $repo 'langhelper.ini.example')
    $rejected = $false
    try { [void](Read-LangHelperConfig $configPath) } catch { $rejected = $true }
    Assert $rejected 'Comma-separated models must be rejected.'
    $cfg.Model = 'ini-custom-model'
    Save-LangHelperConfig $cfg $configPath (Join-Path $repo 'langhelper.ini.example')
    Assert ([IO.File]::ReadAllText($configPath).Contains('; Provider for new windows')) 'Config comments were lost.'
    $cfg.Provider = 'VSCODE'
    Save-LangHelperConfig $cfg $configPath (Join-Path $repo 'langhelper.ini.example')
    Assert ((Read-LangHelperConfig $configPath).Provider -eq 'vscode') 'Provider case must be normalized.'
    $cfg.Provider = 'vscode'
    Save-LangHelperConfig $cfg $configPath (Join-Path $repo 'langhelper.ini.example')
    $split = Split-LangHelperResult ('Before' + "`n" + '```text' + "`nhello`n" + '```' + "`nnotes")
    Assert ($split.Main -eq 'hello' -and $split.Notes.Contains('notes')) 'Fenced output split failed.'
    $split = Split-LangHelperResult "## English`nHello`n## Notes`nExplanation"
    Assert ($split.Main -eq 'Hello' -and $split.Notes.Contains('Explanation')) 'Heading split failed.'
    $split = Split-LangHelperResult 'Plain output'
    Assert ($split.Main -eq 'Plain output' -and -not $split.Notes) 'Plain output split failed.'
    $split = Split-LangHelperResult ('```' + "`n`n" + '```' + "`nVisible result")
    Assert ($split.Main.Contains('Visible result')) 'An empty fenced block must not hide the result.'
    $rawPrompt = Join-Path $testRoot 'raw.md'
    [IO.File]::WriteAllText($rawPrompt, 'Translate the input. Return a translation and notes.')
    $script:Config.PromptFile = $rawPrompt
    $a = Show-Translation 'original A' -NoTranslate
    $b = Show-Translation 'original B' -NoTranslate
    Assert ($script:Windows.Count -eq 2 -and $a.Form -ne $b.Form) 'Multi-window mode failed.'
    [Windows.Forms.Application]::DoEvents()
    $a.Form.StartPosition = 'Manual'; $a.Form.Location = New-Object Drawing.Point(50, 50)
    $a.Form.Show()
    $shotDir = $env:LANGHELPER_UI_SCREENSHOT_DIR
    if ($shotDir) { [void][IO.Directory]::CreateDirectory($shotDir) }
    foreach ($size in @(@(960, 850), @(820, 650), @(1400, 900))) {
        $a.Form.Size = New-Object Drawing.Size($size[0], $size[1])
        [Windows.Forms.Application]::DoEvents()
        $row = $a.CloseButton.Parent
        $left = @($row.Controls[0].Controls)
        $label = "$($size[0])x$($size[1])"
        Assert ($left.Count -eq 3 -and $a.CloseButton.Visible) "Bottom buttons are missing at $label."
        foreach ($button in @($left + $a.CloseButton)) {
            Assert ($button.Visible -and $button.Left -ge 0 -and $button.Right -le $row.ClientSize.Width -and $button.Bottom -le $row.ClientSize.Height) "Button '$($button.Text)' is clipped at $label."
        }
        Assert (@($left | Where-Object { $_.Top -ne $left[0].Top }).Count -eq 0 -and $a.CloseButton.Top -eq $left[0].Top) "Bottom buttons are not on one row at $label."
        Assert ($a.CloseButton.Left -gt $left[2].Right -and ($row.ClientSize.Width - $a.CloseButton.Right) -le $a.CloseButton.Margin.Right) "Close is not at the right edge at $label."
        if ($shotDir) {
            $bmp = New-Object Drawing.Bitmap($a.Form.Width, $a.Form.Height)
            $a.Form.DrawToBitmap($bmp, (New-Object Drawing.Rectangle(0, 0, $a.Form.Width, $a.Form.Height)))
            $bmp.Save((Join-Path $shotDir "window-$label.png"), [Drawing.Imaging.ImageFormat]::Png)
            $bmp.Dispose()
        }
    }
    $a.Form.Hide()
    Assert (-not $a.Source.ReadOnly -and $a.Snapshot.ReadOnly -and $a.Notes.ReadOnly) 'Text area permissions incorrect.'
    Assert $a.Source.AcceptsReturn 'Source Enter must insert a newline instead of invoking the default button.'
    Assert ($a.FeatureLabel.Text.Contains('Features') -and -not $a.PromptInfo.Modular) 'Raw prompt notice missing.'
    $a.Source.Text = 'slow'
    $b.Source.Text = 'fast'
    Assert ($a.Snapshot.Text -eq 'original A') 'Editing source changed snapshot.'
    foreach ($w in @($a, $b)) {
        $w.AutoCopy = $true
        $w.Models = @([pscustomobject]@{ id = 'verified-sonnet'; name = 'Sonnet 5.5'; family = 'claude-sonnet-5.5' })
        $w.CatalogAvailable = $true
        [void]$w.Model.Items.Add('(Provider default)')
        [void]$w.Model.Items.Add('Sonnet 5.5')
        $w.Model.SelectedIndex = 1
        Start-Translation $w
    }
    $deadline = (Get-Date).AddSeconds(10)
    while (($a.Job -or $b.Job) -and (Get-Date) -lt $deadline) {
        Complete-Translation $a
        Complete-Translation $b
        [Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 30
    }
    Assert (-not $a.Job -and -not $b.Job) 'Jobs did not complete.'
    Assert ($a.Result.Text -eq 'translated: slow' -and $b.Result.Text -eq 'translated: fast') 'Results crossed windows.'
    Assert ($a.Notes.Text -eq 'Notes: slow' -and $b.Notes.Text -eq 'Notes: fast') 'Notes crossed windows.'
    Assert ($script:CopiedText -eq 'translated: slow') 'Auto-copy must copy only the last completed main translation.'
    Assert ($a.Status.Text.Contains('verified-sonnet')) 'Actual model is not displayed.'
    $history = @(Get-Content -LiteralPath (Join-Path $testRoot 'history.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
    Assert ($history.Count -eq 2 -and $history[0].model -eq 'verified-sonnet') 'History metadata is incorrect.'
    $lockedHistory = [IO.File]::Open((Join-Path $testRoot 'history.jsonl'), 'Open', 'ReadWrite', 'None')
    $script:CopiedText = ''
    $a.Source.Text = 'persist'
    Start-Translation $a
    $deadline = (Get-Date).AddSeconds(10)
    while ($a.Job -and (Get-Date) -lt $deadline) {
        Complete-Translation $a
        [Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 30
    }
    $lockedHistory.Dispose()
    Assert ($a.Status.Text.StartsWith('Done') -and $script:CopiedText -eq 'translated: persist') 'Persistence failure must not fail a successful translation or skip auto-copy.'
    Assert ([IO.File]::ReadAllText((Join-Path $testRoot 'last-result.txt')).Contains('translated: persist')) 'A locked history file must not prevent last-result.txt from updating.'
    function Set-ClipboardQuietly { param([string]$Text) throw 'Clipboard is busy (test).' }
    $a.Source.Text = 'clipboard'
    Start-Translation $a
    $deadline = (Get-Date).AddSeconds(10)
    while ($a.Job -and (Get-Date) -lt $deadline) {
        Complete-Translation $a
        [Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 30
    }
    Assert ($a.Status.Text.StartsWith('Done') -and $a.Status.Text.Contains('Auto-copy failed')) 'Clipboard failure must remain a successful translation with a warning.'
    Assert ($a.Result.Text -eq 'translated: clipboard') 'Clipboard failure lost the translation.'
    Assert ([IO.File]::ReadAllText((Join-Path $testRoot 'last-result.txt')).Contains('translated: clipboard')) 'Clipboard failure lost the persisted result.'
    function Set-ClipboardQuietly { param([string]$Text) $script:CopiedText = $Text }
    $sourceWithWhitespace = "  first  `r`n`tsecond`t `r`n`r`n"
    $a.Source.Text = $sourceWithWhitespace
    Start-Translation $a
    Assert ($a.Job.Source -ceq $sourceWithWhitespace) 'Job must retain exact Source whitespace.'
    Assert ([IO.File]::ReadAllText($a.Job.InputFile) -ceq $sourceWithWhitespace) 'Backend input must retain exact Source whitespace.'
    $deadline = (Get-Date).AddSeconds(10)
    while ($a.Job -and (Get-Date) -lt $deadline) {
        Complete-Translation $a
        [Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 30
    }
    $lastHistory = (Get-Content -LiteralPath (Join-Path $testRoot 'history.jsonl') | Select-Object -Last 1) | ConvertFrom-Json
    Assert ($lastHistory.source -ceq $sourceWithWhitespace) 'History must retain exact Source whitespace.'
    $a.Provider.SelectedItem = 'auto'
    Stop-WindowJob $a 'CatalogJob'
    $a.CatalogAvailable = $true
    $a.Models = @([pscustomobject]@{ id = 'explicit-id'; name = 'Explicit'; family = 'explicit' })
    [void]$a.Model.Items.Add('(Provider default)')
    [void]$a.Model.Items.Add('Explicit')
    $a.Model.SelectedIndex = 0
    $rejected = $false
    try { [void](Get-WindowModel $a) } catch { $rejected = $_.Exception.Message.Contains('Auto requires') }
    Assert $rejected 'Auto must reject Provider default when a catalog is loaded.'
    $a.Model.SelectedIndex = 1
    Assert ((Get-WindowModel $a) -eq 'explicit-id') 'Auto must still accept an explicit model.'
    $a.Provider.SelectedItem = 'copilot-cli'
    Assert ($a.Model.Text -eq 'ini-custom-model' -and $a.CliModel -eq 'ini-custom-model') 'Selecting CLI must prefill the model configured in INI.'
    $a.Model.Text = 'custom-cli-model'
    $a.Provider.SelectedItem = 'vscode'
    Stop-WindowJob $a 'CatalogJob'
    $a.Provider.SelectedItem = 'copilot-cli'
    Assert ($a.Model.Text -eq 'custom-cli-model') 'Switching providers must preserve an entered CLI model.'
    $a.Provider.SelectedItem = 'auto'
    Stop-WindowJob $a 'CatalogJob'
    $script:ProviderMenu = New-Object Windows.Forms.ToolStripMenuItem 'Provider'
    foreach ($provider in @('vscode', 'copilot-cli', 'auto')) {
        $item = New-Object Windows.Forms.ToolStripMenuItem $provider
        $item.Tag = $provider
        [void]$script:ProviderMenu.DropDownItems.Add($item)
    }
    $a.Form.Show()
    [Windows.Forms.Application]::DoEvents()
    $a.CloseButton.Parent.Controls[0].Controls[2].PerformClick()
    Assert ($script:Config.Provider -eq 'auto' -and (Read-LangHelperConfig $configPath).Provider -eq 'auto') 'Save as defaults must persist the selected provider.'
    Assert ($script:ProviderMenu.DropDownItems[2].Checked -and -not $script:ProviderMenu.DropDownItems[0].Checked) 'Save as defaults must synchronize tray provider checks.'
    $script:ProviderMenu.Dispose()
    Remove-Variable ProviderMenu -Scope Script
    $a.Source.Text = " `t`r`n"
    Start-Translation $a
    Assert (-not $a.Job -and $a.Status.Text -eq 'Source is empty.') 'Whitespace-only Source must be rejected.'
    $a.Source.Text = 'close while translating'
    Start-Translation $a
    $a.Form.Close()
    Assert ($script:Windows.Count -eq 1 -and -not $a.Job) 'Closing a window did not cancel its job.'
    $script:Config.SingleWindow = '1'
    $reused = Show-Translation 'new source' -NoTranslate
    Assert ($reused.Form -eq $b.Form -and $script:Windows.Count -eq 1) 'SingleWindow reuse failed.'
    $b.Form.Close()
    $previousLocal = $env:LOCALAPPDATA
    try {
        $env:LOCALAPPDATA = $testRoot
        $script:Config.Provider = 'auto'
        $script:Config.Model = 'saved-cli-model'
        $offline = Show-Translation 'offline auto' -NoTranslate
        Start-ModelRefresh $offline
        $deadline = (Get-Date).AddSeconds(5)
        while ($offline.CatalogJob -and (Get-Date) -lt $deadline) {
            Complete-ModelRefresh $offline
            Start-Sleep -Milliseconds 20
        }
        Assert (-not $offline.CatalogJob -and -not $offline.CatalogAvailable) 'Offline model lookup did not fail as expected.'
        Assert ((Get-WindowModel $offline) -eq 'saved-cli-model') 'Offline auto must preserve the saved model.'
        Assert ($offline.ModelHint.Text.Contains('not verified')) 'Offline auto must report catalog failure and unverified CLI compatibility.'
        Start-Translation $offline
        Assert ($null -ne $offline.Job) 'Offline auto was blocked before backend dispatch.'
        Stop-WindowJob $offline
        $offline.CatalogAvailable = $true
        $offline.Model.SelectedIndex = -1
        $rejected = $false
        try { [void](Get-WindowModel $offline) } catch { $rejected = $true }
        Assert $rejected 'A loaded catalog must still reject unavailable explicit models in auto mode.'
        $offline.CatalogAvailable = $false
        $offline.VSCodeModel = ''
        $rejected = $false
        try { [void](Get-WindowModel $offline) } catch { $rejected = $true }
        Assert $rejected 'Offline auto must not guess a model when no model is saved.'
        $offline.Provider.SelectedItem = 'vscode'
        Stop-WindowJob $offline 'CatalogJob'
        $rejected = $false
        try { [void](Get-WindowModel $offline) } catch { $rejected = $true }
        Assert $rejected 'VS Code mode must still require a valid catalog selection.'
        $offline.Form.Close()
    } finally { $env:LOCALAPPDATA = $previousLocal }
    Add-Type -TypeDefinition @'
namespace LangHelper {
    public static class ClipboardWatcher {
        public static bool IsCtrlDown() { return true; }
    }
}
'@
    $showTranslation = ${function:Show-Translation}
    $getClipboard = ${function:Get-ClipboardTextSafely}
    try {
        function Get-ClipboardTextSafely { return $script:TestClipboard }
        function Show-Translation {
            param([string]$Text)
            $script:TriggeredText = $Text
            return [pscustomobject]@{ ModelHint = [pscustomobject]@{ Text = '' } }
        }
        $script:Config.MinChars = '3'
        $script:Config.MaxChars = '8'
        foreach ($case in @(
            @(' a ', ' a '), @('ab', $null), @(" `t ", $null),
            @('  abcdef', '  abcdef'), @('  abcdefg', '  abcdef')
        )) {
            $script:TestClipboard = $case[0]
            $script:TriggeredText = $null
            $script:IgnoreClipboardUntil = [datetime]::MinValue
            $script:LastClipboardTick = Get-Date
            Invoke-ClipboardTrigger
            Assert ($script:TriggeredText -ceq $case[1]) 'Clipboard whitespace or MinChars/MaxChars behavior changed.'
        }
    } finally {
        Set-Item Function:Show-Translation $showTranslation
        Set-Item Function:Get-ClipboardTextSafely $getClipboard
    }
    Write-Output 'PASS: INI validation, split output, multiline Source, raw prompt notice, independent jobs/history, cancellation, single-window reuse and offline auto selection.'
} finally {
    if (Get-Variable Windows -Scope Script -ErrorAction SilentlyContinue) {
        foreach ($w in @($script:Windows.ToArray())) { $w.Form.Close(); $w.Form.Dispose() }
    }
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
