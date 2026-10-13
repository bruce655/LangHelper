param($Provider, $Model, $Features, $PromptFile, $InputFile, $OutputFile, $TimeoutSec, [switch]$PassThru)
$ErrorActionPreference = 'Stop'
$source = [IO.File]::ReadAllText($InputFile)
if ($source -eq 'slow') { Start-Sleep -Milliseconds 350 } else { Start-Sleep -Milliseconds 100 }
$content = '```text' + "`ntranslated: $source`n" + '```' + "`nNotes: $source"
[IO.File]::WriteAllText($OutputFile, $content)
if ($PassThru) {
    [pscustomobject]@{
        Content = $content; Provider = $Provider; ModelId = $Model
        ModelName = 'Sonnet 5.5'; ModelVerified = $true; Fallback = $false; Failures = @()
    }
}
