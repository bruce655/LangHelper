#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Insert', 'Search', 'Get', 'Delete', 'Clear')]
    [string]$Action = 'Search',

    [string]$DbPath,
    [string]$SourceFile,
    [string]$ResultFile,
    [string]$Model = '',
    [string]$Features = '',
    [string]$Query = '',
    [string]$QueryFile = '',
    [int]$Limit = 80,
    [int]$Id = 0,
    [string]$OutputFile,
    [string]$SourceOut,
    [string]$ResultOut
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $DbPath) { $DbPath = Join-Path $scriptDir 'langhelper_history.sqlite' }
$utf8NoBom = New-Object System.Text.UTF8Encoding $false

if (-not (Get-Command 'sqlite3' -ErrorAction SilentlyContinue)) {
    throw "sqlite3.exe not found. Install it with: winget install SQLite.SQLite"
}

function ConvertTo-SqlLiteral([AllowNull()][string]$Value) {
    if ($null -eq $Value) { return "''" }
    return "'" + $Value.Replace("'", "''") + "'"
}

function Invoke-SqliteScript([string]$Sql, [switch]$Capture) {
    $tmpSql = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllText($tmpSql, $Sql, $utf8NoBom)
        # .read splits its argument on spaces and eats backslashes even when
        # quoted, so hand it a quoted forward-slash path.
        $readCmd = '.read "' + $tmpSql.Replace('\', '/') + '"'
        if ($Capture) {
            $result = & sqlite3 $DbPath $readCmd
        } else {
            & sqlite3 $DbPath $readCmd | Out-Null
            $result = $null
        }
        if ($LASTEXITCODE -ne 0) { throw "sqlite3 failed with exit code $LASTEXITCODE" }
        return $result
    }
    finally {
        if (Test-Path -LiteralPath $tmpSql) {
            Remove-Item -LiteralPath $tmpSql -Force -ErrorAction SilentlyContinue
        }
    }
}

function Initialize-HistoryDb {
    Invoke-SqliteScript @"
CREATE TABLE IF NOT EXISTS history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    created_at TEXT NOT NULL DEFAULT (datetime('now', 'localtime')),
    model TEXT NOT NULL,
    features TEXT NOT NULL,
    source TEXT NOT NULL,
    result TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_history_created_at ON history(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_history_model ON history(model);
"@ | Out-Null
}

function ConvertFrom-HexUtf8([string]$Hex) {
    if ([string]::IsNullOrEmpty($Hex)) { return '' }
    $bytes = New-Object byte[] ($Hex.Length / 2)
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        $bytes[$i] = [Convert]::ToByte($Hex.Substring($i * 2, 2), 16)
    }
    return [System.Text.Encoding]::UTF8.GetString($bytes)
}

Initialize-HistoryDb

switch ($Action) {
    'Insert' {
        if (-not (Test-Path -LiteralPath $SourceFile)) { throw "Source file not found: $SourceFile" }
        if (-not (Test-Path -LiteralPath $ResultFile)) { throw "Result file not found: $ResultFile" }

        $source = [System.IO.File]::ReadAllText($SourceFile, $utf8NoBom)
        $result = [System.IO.File]::ReadAllText($ResultFile, $utf8NoBom)
        $sql = "INSERT INTO history(model, features, source, result) VALUES ({0}, {1}, {2}, {3});" -f `
            (ConvertTo-SqlLiteral $Model), (ConvertTo-SqlLiteral $Features), (ConvertTo-SqlLiteral $source), (ConvertTo-SqlLiteral $result)
        Invoke-SqliteScript $sql | Out-Null
    }

    'Search' {
        if (-not $OutputFile) { throw 'OutputFile is required for Search.' }
        # Search text is untrusted, so the caller passes it by file rather than
        # as a command-line argument.
        if ($QueryFile -and (Test-Path -LiteralPath $QueryFile)) {
            $Query = [System.IO.File]::ReadAllText($QueryFile, $utf8NoBom)
        }
        $safeLimit = [Math]::Max(1, [Math]::Min($Limit, 500))
        $where = ''
        if (-not [string]::IsNullOrWhiteSpace($Query)) {
            # Users type literal text, so % and _ must not act as LIKE wildcards.
            $like = ConvertTo-SqlLiteral ('%' + ($Query -replace '([\\%_])', '\$1') + '%')
            $where = "WHERE source LIKE $like ESCAPE '\' OR result LIKE $like ESCAPE '\'"
        }
        $separator = [char]31
        $sql = @"
.mode list
.separator '$separator'
SELECT
    id,
    created_at,
    hex(source),
    hex(result)
FROM history
$where
ORDER BY id DESC
LIMIT $safeLimit;
"@
        $rows = Invoke-SqliteScript $sql -Capture
        if ($rows -is [System.Array]) { $rows = [string]::Join("`n", $rows) }
        [System.IO.File]::WriteAllText($OutputFile, [string]$rows, $utf8NoBom)
    }

    'Get' {
        if ($Id -le 0) { throw 'A positive Id is required for Get.' }
        if (-not $SourceOut) { throw 'SourceOut is required for Get.' }
        if (-not $ResultOut) { throw 'ResultOut is required for Get.' }

        $sql = @"
.mode list
SELECT hex(source) FROM history WHERE id = $Id;
"@
        $sourceHex = Invoke-SqliteScript $sql -Capture
        if ($sourceHex -is [System.Array]) { $sourceHex = $sourceHex[0] }
        [System.IO.File]::WriteAllText($SourceOut, (ConvertFrom-HexUtf8 ([string]$sourceHex)), $utf8NoBom)

        $sql = @"
.mode list
SELECT hex(result) FROM history WHERE id = $Id;
"@
        $resultHex = Invoke-SqliteScript $sql -Capture
        if ($resultHex -is [System.Array]) { $resultHex = $resultHex[0] }
        [System.IO.File]::WriteAllText($ResultOut, (ConvertFrom-HexUtf8 ([string]$resultHex)), $utf8NoBom)
    }

    'Delete' {
        if ($Id -le 0) { throw 'A positive Id is required for Delete.' }
        Invoke-SqliteScript "DELETE FROM history WHERE id = $Id;" | Out-Null
    }

    'Clear' {
        Invoke-SqliteScript "DELETE FROM history;" | Out-Null
    }
}