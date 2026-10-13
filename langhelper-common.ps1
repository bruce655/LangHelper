#requires -Version 5.1

function Get-LangHelperDefaults {
    return [ordered]@{
        Provider = 'vscode'
        Model = 'claude-sonnet-5.5'
        Features = 'POLISH,BILINGUAL_EN_ZHTW'
        PromptFile = ''
        DoubleCopyMs = '700'
        MinChars = '1'
        MaxChars = '8000'
        TimeoutSec = '120'
        AutoCopyResult = '1'
        AlwaysOnTop = '1'
        SingleWindow = '0'
    }
}

function Read-LangHelperConfig {
    param([string]$Path)
    $cfg = Get-LangHelperDefaults
    if (Test-Path -LiteralPath $Path) {
        foreach ($line in ([IO.File]::ReadAllText($Path) -split '\r?\n')) {
            if ($line -match '^\s*([^;#\[\s=]+)\s*=(.*)$') {
                $key = $Matches[1]
                if ($cfg.Contains($key)) { $cfg[$key] = $Matches[2].Trim() }
            }
        }
    }
    $cfg.Provider = $cfg.Provider.ToLowerInvariant()
    if ($cfg.Provider -notin @('vscode', 'auto', 'copilot-cli')) { throw 'Provider must be vscode, auto or copilot-cli.' }
    if ($cfg.Model.Contains(',')) { throw 'Model must contain one model ID or family, not a comma-separated list.' }
    foreach ($key in @('DoubleCopyMs', 'MinChars', 'MaxChars', 'TimeoutSec')) {
        $value = 0
        if (-not [int]::TryParse($cfg[$key], [ref]$value) -or $value -lt 1) { throw "$key must be a positive integer." }
    }
    if ([int]$cfg.MinChars -gt [int]$cfg.MaxChars) { throw 'MinChars cannot exceed MaxChars.' }
    if ([int]$cfg.TimeoutSec -gt 3600) { throw 'TimeoutSec cannot exceed 3600 seconds.' }
    foreach ($key in @('AutoCopyResult', 'AlwaysOnTop', 'SingleWindow')) {
        if ($cfg[$key] -notin @('0', '1')) { throw "$key must be 0 or 1." }
    }
    return $cfg
}

function Save-LangHelperConfig {
    param($Config, [string]$Path, [string]$Template)
    $lines = foreach ($line in ([IO.File]::ReadAllText($Template) -split '\r?\n')) {
        if ($line -match '^([^;#\[\s=]+)=') {
            $key = $Matches[1]
            if ($Config.Contains($key)) { "$key=$($Config[$key])" } else { $line }
        } else { $line }
    }
    [IO.File]::WriteAllText($Path, ($lines -join "`r`n"), (New-Object Text.UTF8Encoding $false))
}

function Get-LangHelperPromptInfo {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Prompt file not found: $Path" }
    $md = [IO.File]::ReadAllText($Path) -replace "`r`n", "`n"
    $core = [regex]::Match($md, '(?ms)##\s+Core[^\n]*\n+```[a-z]*\n(.*?)\n```')
    $modular = $core.Success -and $core.Groups[1].Value.Contains("<clipboard>`n{{PASTE_CLIPBOARD_HERE}}`n</clipboard>")
    $features = @()
    if ($modular) {
        $features = @([regex]::Matches($md, '(?ms)```[a-z]*\n\[FEATURE:\s*([A-Z0-9_]+)\][^\n]*\n.*?\n```') |
            ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
    }
    return [pscustomobject]@{ Modular = $modular; Features = $features }
}

function Split-LangHelperResult {
    param([string]$Text)
    $match = [regex]::Match($Text, '(?s)```[^\r\n]*\r?\n(.*?)\r?\n```')
    if ($match.Success -and $match.Groups[1].Value.Trim()) {
        return [pscustomobject]@{
            Main = $match.Groups[1].Value.Trim()
            Notes = $Text.Remove($match.Index, $match.Length).Trim()
        }
    }
    $sections = [regex]::Matches($Text, '(?ms)^##[ \t]+[^\r\n]+\r?\n(.*?)(?=^##[ \t]+|\z)')
    if ($sections.Count -and $sections[0].Groups[1].Value.Trim()) {
        $main = $sections[0].Groups[1].Value.Trim()
        $notes = $Text.Substring(0, $sections[0].Index).Trim()
        if ($sections.Count -gt 1) { $notes = ($notes + "`n`n" + $Text.Substring($sections[1].Index)).Trim() }
        return [pscustomobject]@{ Main = $main; Notes = $notes }
    }
    return [pscustomobject]@{ Main = $Text.Trim(); Notes = '' }
}

function Get-LangHelperBridgeRoot {
    $base = $env:LOCALAPPDATA
    if (-not $base) { $base = Join-Path $env:USERPROFILE 'AppData\Local' }
    return Join-Path $base 'LangHelper\bridge'
}

function ConvertTo-LangHelperNativeArgument {
    param([string]$Value)
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function Invoke-LangHelperBridge {
    param($Payload, [int]$TimeoutSec = 120)
    $root = Get-LangHelperBridgeRoot
    $hb = Join-Path $root 'heartbeat.json'
    if (-not (Test-Path -LiteralPath $hb)) { throw 'LangHelper Bridge is offline. Start VS Code and test the Copilot connection.' }
    $heartbeat = [IO.File]::ReadAllText($hb) | ConvertFrom-Json
    if (([datetime]$heartbeat.updated).ToUniversalTime() -lt (Get-Date).ToUniversalTime().AddSeconds(-90)) { throw 'LangHelper Bridge heartbeat is stale. Reload VS Code.' }
    if ($heartbeat.protocolVersion -ne 2) { throw 'Bridge update required. Run install.ps1 -NoStartup, then Developer: Reload Window in VS Code.' }
    $id = [guid]::NewGuid().ToString('n')
    $Payload.id = $id
    $req = Join-Path $root "requests\$id.json"
    $res = Join-Path $root "responses\$id.json"
    $tmp = "$req.tmp"
    $done = $false
    try {
        [IO.File]::WriteAllText($tmp, ($Payload | ConvertTo-Json -Depth 8 -Compress), (New-Object Text.UTF8Encoding $false))
        [IO.File]::Move($tmp, $req)
        $watch = [Diagnostics.Stopwatch]::StartNew()
        while ($watch.Elapsed.TotalSeconds -lt $TimeoutSec) {
            if (Test-Path -LiteralPath $res) {
                $obj = [IO.File]::ReadAllText($res) | ConvertFrom-Json
                $done = $true
                if (-not $obj.ok) { throw "LangHelper Bridge: $($obj.error)" }
                return $obj
            }
            Start-Sleep -Milliseconds 100
        }
        throw "LangHelper Bridge did not answer within $TimeoutSec seconds."
    } finally {
        if (-not $done -and (Test-Path -LiteralPath (Join-Path $root 'requests'))) {
            $cancel = Join-Path $root "requests\$id-cancel.json"
            $data = @{ id = "$id-cancel"; action = 'cancel'; targetId = $id } | ConvertTo-Json -Compress
            [IO.File]::WriteAllText("$cancel.tmp", $data, (New-Object Text.UTF8Encoding $false))
            [IO.File]::Move("$cancel.tmp", $cancel)
        }
        foreach ($file in @($tmp, $req, $res)) {
            if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
        }
    }
}
