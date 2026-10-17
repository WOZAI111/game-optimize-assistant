# Which array idioms are safe in Windows PowerShell 5.1? ASCII only.
function T {
    param([string]$Name, [scriptblock]$Body)
    try {
        $r = & $Body
        Write-Host ("OK    {0}  => {1}" -f $Name, $r)
    } catch {
        Write-Host ("THROW {0}  => {1}" -f $Name, $_.Exception.Message)
    }
}

$objA = [ordered]@{ id = 'A'; priority = 3 }
$objB = [ordered]@{ id = 'B'; priority = 1 }

$L1 = New-Object 'System.Collections.Generic.List[object]'
$null = $L1.Add($objA)
$null = $L1.Add($objB)

$L2 = New-Object 'System.Collections.Generic.List[object]'
$null = $L2.Add(1)
$null = $L2.Add(2)

$L3 = New-Object 'System.Collections.Generic.List[string]'
$null = $L3.Add('a')
$null = $L3.Add('b')

$plain = @()
$plain += $objA
$plain += $objB

$arr2 = @($objA, $objB)

Write-Host ("L1 type     : " + $L1.GetType().FullName)
Write-Host ("plain type  : " + $plain.GetType().FullName)
Write-Host ("arr2 type   : " + $arr2.GetType().FullName)
Write-Host ''

T 'P1_list_direct_count' { $L1.Count }
T 'P2_atsign_L1' { @($L1).Count }
T 'P3_atsign_L2_ints' { @($L2).Count }
T 'P4_atsign_L3_strings' { @($L3).Count }
T 'P5_atsign_plain_array' { @($plain).Count }
T 'P6_atsign_arr2' { @($arr2).Count }
T 'P7_L1_ToArray_count' { $L1.ToArray().Count }
T 'P8_atsign_ToArray' { @($L1.ToArray()).Count }
T 'P9_foreach_L1' { $n = 0; foreach ($x in $L1) { $n++ }; $n }
T 'P10_cast_objectarray' { ([object[]]$L1).Count }
T 'P11_pipeline_to_array' { @($L1 | ForEach-Object { $_ }).Count }
T 'P12_atsign_pipeline_L1' { @($L1 | Select-Object -First 8).Count }
T 'P13_plain_plus_list' { $m = @(); $m += $L1; @($m).Count }
T 'P14_compare_object' { $arr2[0].id }
T 'P15_plain_foreach' { $n = 0; foreach ($x in @($plain)) { $n++ }; $n }
T 'P16_L1_index' { $L1[0].id }
T 'P17_atsign_variable_ordered' { $o = [ordered]@{ a = 1 }; @($o).Count }
