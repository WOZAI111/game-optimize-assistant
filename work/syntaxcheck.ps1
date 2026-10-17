param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Paths)
$fail = 0
foreach ($p in $Paths) {
    if (-not (Test-Path -LiteralPath $p)) { Write-Host "MISSING $p"; $fail++; continue }
    $t = Get-Content -Raw -LiteralPath $p
    try {
        $null = [scriptblock]::Create($t)
        Write-Host "OK    $p"
    } catch {
        Write-Host "FAIL  $p"
        Write-Host ("      " + $_.Exception.Message)
        $fail++
    }
}
exit $fail
