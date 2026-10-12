#requires -Version 5.1
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'langhelper-common.ps1')
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("langhelper-backend-test-" + [guid]::NewGuid().ToString('n'))
$previousLocal = $env:LOCALAPPDATA
$previousPath = $env:PATH
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
    [IO.File]::WriteAllText($inputFile, 'Hello "quoted" input')
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
    Write-Output 'PASS: real backend raw prompt assembly, quoted input, model metadata, output compatibility, measured timeout/cancellation and missing prompt.'
} finally {
    if ($shell) { $shell.Dispose() }
    $env:LOCALAPPDATA = $previousLocal
    $env:PATH = $previousPath
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
