#requires -Version 5.1
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'langhelper-common.ps1')
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("langhelper-backend-test-" + [guid]::NewGuid().ToString('n'))
$previousLocal = $env:LOCALAPPDATA
$previousPath = $env:PATH
$previousTestInput = $env:LANGHELPER_TEST_INPUT
$previousLastLine = $env:LANGHELPER_TEST_LAST_LINE
$env:LOCALAPPDATA = $testRoot
$root = Get-LangHelperBridgeRoot
[void][IO.Directory]::CreateDirectory((Join-Path $root 'requests'))
[void][IO.Directory]::CreateDirectory((Join-Path $root 'responses'))
$shell = $null
function Assert($condition, $message) { if (-not $condition) { throw $message } }
try {
    [IO.File]::WriteAllText((Join-Path $root 'heartbeat.json'), (@{ updated = (Get-Date).ToUniversalTime().ToString('o'); protocolVersion = 2 } | ConvertTo-Json))
    $inputFile = Join-Path $testRoot 'input.txt'
    $outputFile = Join-Path $testRoot 'output.txt'
    $raw = Join-Path $testRoot 'raw.md'
    $source = 'Hello "quoted" input' + "`n" + [regex]::Unescape('\u7e41\u9ad4\u4e2d\u6587') + "`n" + 'C:\path with spaces\ %PATH% !value! & ^ | < >'
    [IO.File]::WriteAllText($inputFile, $source)
    $env:LANGHELPER_TEST_INPUT = $inputFile
    [IO.File]::WriteAllText($raw, 'Translate and return notes.')
    $shell = [powershell]::Create()
    $parameters = @{ Provider = 'vscode'; Model = 'claude-sonnet-5.5'; PromptFile = $raw; Features = 'POLISH'; InputFile = $inputFile; OutputFile = $outputFile; TimeoutSec = 5; PassThru = $true }
    [void]$shell.AddCommand((Join-Path $repo 'langhelper.ps1')).AddParameters($parameters)
    $handle = $shell.BeginInvoke()
    $deadline = (Get-Date).AddSeconds(5)
    $request = $null
    while (-not $request -and (Get-Date) -lt $deadline) {
        $file = Get-ChildItem -LiteralPath (Join-Path $root 'requests') -Filter '*.json' | Select-Object -First 1
        if ($file) { $request = [IO.File]::ReadAllText($file.FullName) | ConvertFrom-Json } else { Start-Sleep -Milliseconds 20 }
    }
    Assert ($null -ne $request) 'Backend did not issue a request.'
    Assert ($request.messages.Count -eq 1 -and $request.messages[0].content.Contains('Hello "quoted" input')) 'Prompt/input was not preserved.'
    Assert (-not $request.messages[0].content.Contains('[FEATURE: POLISH]')) 'Raw prompt must not append feature blocks.'
    $response = @{ id = $request.id; ok = $true; content = 'verified output'; modelId = 'actual-sonnet-id'; modelName = 'Sonnet 5.5'; provider = 'vscode' } | ConvertTo-Json
    $target = Join-Path $root "responses\$($request.id).json"
    [IO.File]::WriteAllText("$target.tmp", $response)
    [IO.File]::Move("$target.tmp", $target)
    $result = @($shell.EndInvoke($handle))
    if ($shell.Streams.Error.Count) { throw ($shell.Streams.Error | Out-String) }
    Assert ($result.Count -eq 1 -and $result[0].ModelId -eq 'actual-sonnet-id' -and $result[0].ModelVerified) 'Backend lost actual model metadata.'
    Assert ([IO.File]::ReadAllText($outputFile) -eq 'verified output') 'Output file compatibility failed.'
    $shell.Dispose(); $shell = $null
    $timedOut = $false
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try { [void](Invoke-LangHelperBridge @{ action = 'models' } -TimeoutSec 1) } catch { $timedOut = $_.Exception.Message.Contains('within 1') }
    Assert ($timedOut -and $watch.Elapsed.TotalSeconds -lt 2.5) 'Bridge timeout threshold failed.'
    $cancels = @(Get-ChildItem -LiteralPath (Join-Path $root 'requests') -Filter '*-cancel.json')
    Assert ($cancels.Count -eq 1) 'Timeout did not send cancellation.'

    # Heartbeat UTC normalization test
    # A fresh UTC timestamp formatted with 'Z' must not be rejected even if local timezone is non-UTC
    [IO.File]::WriteAllText((Join-Path $root 'heartbeat.json'), (@{ updated = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ'); protocolVersion = 2 } | ConvertTo-Json))
    $utcCheckPassed = $false
    try {
        # With a fresh heartbeat, Invoke-LangHelperBridge will proceed past the heartbeat check to request writing
        $watch = [Diagnostics.Stopwatch]::StartNew()
        try { [void](Invoke-LangHelperBridge @{ action = 'models' } -TimeoutSec 1) } catch {
            if ($_.Exception.Message.Contains('within 1')) { $utcCheckPassed = $true }
            else { throw $_ }
        }
    } catch { throw }
    Assert $utcCheckPassed 'Heartbeat with UTC Z format failed fresh check.'

    $parameters.PromptFile = Join-Path $testRoot 'missing.md'
    $shell = [powershell]::Create()
    [void]$shell.AddCommand((Join-Path $repo 'langhelper.ps1')).AddParameters($parameters)
    $missingRejected = $false
    try { [void]$shell.Invoke() } catch { $missingRejected = $true }
    Assert ($missingRejected -or $shell.Streams.Error.Count -gt 0) 'Missing external prompt must be rejected.'
    $shell.Dispose(); $shell = $null
    $cliPath = Join-Path $testRoot 'copilot.exe'
    Add-Type -Path (Join-Path $PSScriptRoot 'fake-cli.cs') -OutputAssembly $cliPath -OutputType ConsoleApplication
    $env:PATH = "$testRoot;$previousPath"
    $parameters.Provider = 'copilot-cli'
    $parameters.PromptFile = $raw
    $shell = [powershell]::Create()
    [void]$shell.AddCommand((Join-Path $repo 'langhelper.ps1')).AddParameters($parameters)
    $cliResult = @($shell.Invoke())
    if ($shell.Streams.Error.Count) { throw ($shell.Streams.Error | Out-String) }
    Assert ($cliResult.Count -eq 1 -and $cliResult[0].Provider -eq 'copilot-cli' -and -not $cliResult[0].ModelVerified) 'CLI metadata must distinguish requested from verified model.'
    $shell.Dispose(); $shell = $null
    foreach ($lastLine in @('Changes: +1 -0', 'Tokens: are words', 'Session: training', 'AI Credits: 1.2', 'Resume: copilot --resume=abc')) {
        $env:LANGHELPER_TEST_LAST_LINE = $lastLine
        $shell = [powershell]::Create()
        [void]$shell.AddCommand((Join-Path $repo 'langhelper.ps1')).AddParameters($parameters)
        $labelResult = @($shell.Invoke())
        if ($shell.Streams.Error.Count) { throw ($shell.Streams.Error | Out-String) }
        Assert ($labelResult.Count -eq 1 -and ($labelResult[0].Content -replace "`r`n", "`n") -ceq "CLI translated`n$lastLine") 'Legitimate CLI translation text was truncated.'
        $shell.Dispose(); $shell = $null
    }
    $env:LANGHELPER_TEST_LAST_LINE = $null
    # A prompt above the 32,767-character command-line limit must still reach a native CLI.
    $largeSource = ('large source ' * 4000) + $source
    [IO.File]::WriteAllText($inputFile, $largeSource)
    $shell = [powershell]::Create()
    [void]$shell.AddCommand((Join-Path $repo 'langhelper.ps1')).AddParameters($parameters)
    $largeResult = @($shell.Invoke())
    if ($shell.Streams.Error.Count) { throw ($shell.Streams.Error | Out-String) }
    Assert ($largeResult.Count -eq 1 -and $largeResult[0].Content -eq 'CLI translated') 'A large prompt must be passed to the native CLI through stdin.'
    $shell.Dispose(); $shell = $null
    [IO.File]::WriteAllText($inputFile, $source)
    $shimDirectory = Join-Path $testRoot 'shim'
    [void][IO.Directory]::CreateDirectory($shimDirectory)
    $env:PATH = "$shimDirectory;$testRoot;$previousPath"
    $shim = @'
$ErrorActionPreference = 'Stop'
if ($args -notcontains '--deny-tool' -or $args -contains '*') { throw 'Missing tool isolation.' }
$input | & (Join-Path (Split-Path -Parent $PSScriptRoot) 'copilot.exe') @args
exit $LASTEXITCODE
'@
    $shimPath = Join-Path $shimDirectory 'copilot.ps1'
    [IO.File]::WriteAllText($shimPath, $shim)
    foreach ($wrapper in @('ps1', 'cmd')) {
        if ($wrapper -eq 'cmd') {
            Remove-Item -LiteralPath $shimPath
            [IO.File]::WriteAllText((Join-Path $shimDirectory 'copilot.cmd'), "@echo off`r`n`"$cliPath`" %*`r`n")
        }
        $shell = [powershell]::Create()
        [void]$shell.AddCommand((Join-Path $repo 'langhelper.ps1')).AddParameters($parameters)
        $wrapped = @($shell.Invoke())
        if ($shell.Streams.Error.Count) { throw ($shell.Streams.Error | Out-String) }
        Assert ($wrapped.Count -eq 1 -and $wrapped[0].Content -eq 'CLI translated') "$wrapper CLI wrapper changed quoted input."
        $shell.Dispose(); $shell = $null
    }
    $sleeperPath = Join-Path $testRoot 'lhsleeper.exe'
    Copy-Item -LiteralPath "$env:SystemRoot\System32\PING.EXE" -Destination $sleeperPath
    [IO.File]::WriteAllText((Join-Path $shimDirectory 'copilot.cmd'), "@echo off`r`n`"$sleeperPath`" -n 60 127.0.0.1 >nul`r`n")
    $timeoutParameters = $parameters.Clone(); $timeoutParameters.TimeoutSec = 2
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $shell = [powershell]::Create()
    [void]$shell.AddCommand((Join-Path $repo 'langhelper.ps1')).AddParameters($timeoutParameters)
    try { [void]$shell.Invoke() } catch { }
    $timedOutCli = ($shell.Streams.Error | Out-String).Contains('within 2') -or $shell.HadErrors
    $shell.Dispose(); $shell = $null
    Start-Sleep -Milliseconds 500
    $leftover = @(Get-Process -Name 'lhsleeper' -ErrorAction SilentlyContinue)
    $leftover | ForEach-Object { Stop-Process -Id $_.Id -Force }
    Assert ($timedOutCli -and $watch.Elapsed.TotalSeconds -lt 10) 'CLI timeout was not enforced promptly.'
    Assert ($leftover.Count -eq 0) 'CLI timeout left a descendant process running.'
    Remove-Item -LiteralPath (Join-Path $shimDirectory 'copilot.cmd')
    Remove-Item -LiteralPath (Join-Path $root 'heartbeat.json')
    $parameters.Provider = 'auto'
    $shell = [powershell]::Create()
    [void]$shell.AddCommand((Join-Path $repo 'langhelper.ps1')).AddParameters($parameters)
    $offline = @($shell.Invoke())
    if ($shell.Streams.Error.Count) { throw ($shell.Streams.Error | Out-String) }
    Assert ($offline.Count -eq 1 -and $offline[0].Provider -eq 'copilot-cli' -and -not $offline[0].Fallback) 'Offline auto must dispatch CLI first.'
    $shell.Dispose(); $shell = $null
    foreach ($wordCount in @(300, 301)) {
        [IO.File]::WriteAllText($inputFile, (('word ' * $wordCount).TrimEnd()))
        & (Join-Path $repo 'langhelper.ps1') -Features SUMMARY -InputFile $inputFile -OutputFile $outputFile -DryRun
        $assembled = [IO.File]::ReadAllText($outputFile)
        $reminder = ($assembled -split 'REMINDER:')[-1]
        Assert ($assembled.Contains('If the source is > 300 words')) 'SUMMARY word threshold was lost.'
        Assert ($reminder.Contains('Enabled features: SUMMARY.') -and $reminder.Contains('only when their stated conditions are satisfied')) 'Reminder must preserve conditional sections.'
        Assert (-not $reminder.Contains('## Key points')) 'Reminder must not make conditional Key points mandatory.'
    }
    & (Join-Path $repo 'langhelper.ps1') -Features 'BILINGUAL_EN_ZHTW,ROMANIZE' -InputFile $inputFile -OutputFile $outputFile -DryRun
    $reminder = ([IO.File]::ReadAllText($outputFile) -split 'REMINDER:')[-1]
    Assert ($reminder.Contains('Enabled features: BILINGUAL_EN_ZHTW, ROMANIZE.') -and -not $reminder.Contains('POLISH')) 'Reminder must not enable cross-referenced features.'
    Write-Output 'PASS: prompt conditions, raw assembly, UTF-8/quotes/metacharacters through exe/ps1/cmd, offline auto dispatch, model metadata, output compatibility, timeout/cancellation and missing prompt.'
} finally {
    if ($shell) { $shell.Dispose() }
    $env:LOCALAPPDATA = $previousLocal
    $env:PATH = $previousPath
    $env:LANGHELPER_TEST_INPUT = $previousTestInput
    $env:LANGHELPER_TEST_LAST_LINE = $previousLastLine
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
