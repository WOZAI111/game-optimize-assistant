# End-to-end check of the "apply then revert" safety net.
#
# It copies the generated Optimize-*.ps1 into work\test\, rewrites the GameBar
# registry path to a scratch key, and runs preview / apply / revert while
# checking the real registry state after each step. The user's own settings are
# never touched. ASCII only on purpose.
[CmdletBinding()]
param(
    [string]$Root,
    [string]$OutRoot
)

$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = (Split-Path -Parent $PSScriptRoot) }
$script:Fail = 0

function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    if ($Ok) {
        Write-Host ("PASS  {0} {1}" -f $Name, $Detail) -ForegroundColor Green
    } else {
        Write-Host ("FAIL  {0} {1}" -f $Name, $Detail) -ForegroundColor Red
        $script:Fail++
    }
}

if (-not $OutRoot) { $OutRoot = Join-Path $Root 'work\test-out' }
$WorkDir = Join-Path $Root 'work\test'
if (Test-Path -LiteralPath $WorkDir) { Remove-Item -LiteralPath $WorkDir -Recurse -Force }
New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null

$Generated = @(Get-ChildItem -LiteralPath $OutRoot -Filter 'Optimize-*.ps1' -ErrorAction SilentlyContinue)
Check 'generated-script-exists' ($Generated.Count -ge 1) ("count=" + $Generated.Count)
if ($Generated.Count -eq 0) { exit 1 }
$Src = $Generated | Sort-Object LastWriteTime -Descending | Select-Object -First 1
Write-Host ("using " + $Src.FullName)

$Text = [System.IO.File]::ReadAllText($Src.FullName, [System.Text.Encoding]::UTF8)

$ScratchKey = 'HKCU:\Software\_GameOptScratch'
$Patched = $Text.Replace('HKCU:\Software\Microsoft\GameBar', $ScratchKey)
$Patched = [regex]::Replace($Patched, "\`$SelectedTweaks = @\([^\)]*\)", "`$SelectedTweaks = @('GAME_MODE')")
$TestScript = Join-Path $WorkDir 'Optimize-scratch.ps1'
[System.IO.File]::WriteAllText($TestScript, $Patched, (New-Object System.Text.UTF8Encoding($true)))
Check 'patch-selected-tweaks' ($Patched -match 'GAME_MODE')
$SelLine = @($Patched -split "\r?\n" | Where-Object { $_ -match '^\$SelectedTweaks' })[0]
Check 'patch-drops-other-tweaks' ("$SelLine" -notmatch 'POWER_PLAN_HIGH') ("selLine=" + $SelLine)

if (-not (Test-Path -LiteralPath $ScratchKey)) { New-Item -Path $ScratchKey -Force | Out-Null }
Set-ItemProperty -Path $ScratchKey -Name 'AutoGameModeEnabled' -Value 0 -Type DWord
$Journal = Join-Path $WorkDir 'optimize-logs\journal.json'
if (Test-Path -LiteralPath $Journal) { Remove-Item -LiteralPath $Journal -Force }

function Get-ScratchValue {
    try {
        return (Get-ItemProperty -Path $ScratchKey -Name 'AutoGameModeEnabled' -ErrorAction Stop).AutoGameModeEnabled
    } catch {
        return 'missing'
    }
}

Write-Host ''
Write-Host '--- preview run (must change nothing) ---'
& $TestScript -NoPause | Out-Null
Check 'preview-keeps-value' ("$(Get-ScratchValue)" -eq '0') ("value=" + (Get-ScratchValue))
Check 'preview-writes-no-journal' (-not (Test-Path -LiteralPath $Journal))

Write-Host ''
Write-Host '--- apply run (must write value + journal) ---'
& $TestScript -Apply -NoPause | Out-Null
Check 'apply-writes-value' ("$(Get-ScratchValue)" -eq '1') ("value=" + (Get-ScratchValue))
Check 'apply-writes-journal' (Test-Path -LiteralPath $Journal)
$Entry = $null
if (Test-Path -LiteralPath $Journal) {
    $raw = [System.IO.File]::ReadAllText($Journal, [System.Text.Encoding]::UTF8)
    $Entry = @(($raw | ConvertFrom-Json).entries)[0]
}
if ($null -ne $Entry) {
    Check 'journal-records-old-value' ("$($Entry.oldValue)" -eq '0') ("oldValue=" + $Entry.oldValue)
    Check 'journal-records-old-type' ("$($Entry.oldType)" -eq 'DWord') ("oldType=" + $Entry.oldType)
} else {
    Check 'journal-records-old-value' $false 'no entry'
    Check 'journal-records-old-type' $false 'no entry'
}
Check 'apply-writes-apply-log' (Test-Path -LiteralPath (Join-Path $WorkDir 'optimize-logs\apply.log'))

Write-Host ''
Write-Host '--- revert run (must restore original value) ---'
& $TestScript -Revert -NoPause | Out-Null
Check 'revert-restores-value' ("$(Get-ScratchValue)" -eq '0') ("value=" + (Get-ScratchValue))
Check 'revert-archives-journal' (-not (Test-Path -LiteralPath $Journal))
$Archived = @(Get-ChildItem -LiteralPath (Join-Path $WorkDir 'optimize-logs') -Filter 'journal-reverted-*.json' -ErrorAction SilentlyContinue)
Check 'revert-archive-exists' ($Archived.Count -ge 1)

Remove-Item -LiteralPath $ScratchKey -Recurse -Force -ErrorAction SilentlyContinue
Check 'scratch-key-removed' (-not (Test-Path -LiteralPath $ScratchKey))

Write-Host ''
if ($script:Fail -eq 0) {
    Write-Host 'ALL CHECKS PASSED' -ForegroundColor Green
    exit 0
}
Write-Host ("{0} CHECK(S) FAILED" -f $script:Fail) -ForegroundColor Red
exit 1
