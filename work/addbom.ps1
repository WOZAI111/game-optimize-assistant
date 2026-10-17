# Add a UTF-8 BOM to text files that contain non-ASCII characters.
#
# Why: Windows PowerShell 5.1 reads a BOM-less .ps1 using the local ANSI codepage,
# so non-ASCII characters get mangled and can even swallow the next character
# (which turns into confusing syntax errors). Keep this file ASCII-only so it can
# always run.
#
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File addbom.ps1 <file> [file...]
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Paths)

$changed = 0
foreach ($p in $Paths) {
    if (-not (Test-Path -LiteralPath $p)) { Write-Host "MISSING  $p"; continue }
    $bytes = Get-Content -LiteralPath $p -Encoding Byte -ReadCount 0
    $hasBom = $false
    if ($bytes.Count -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $hasBom = $true }
    if ($hasBom) { Write-Host "OK       $p"; continue }
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    $text = $text.Replace([string][char]13 + [string][char]10, [string][char]10).Replace([string][char]10, [string][char]13 + [string][char]10)
    $enc = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($p, $text, $enc)
    Write-Host "BOM ADD  $p"
    $changed++
}
Write-Host ("done, {0} file(s) updated" -f $changed)
