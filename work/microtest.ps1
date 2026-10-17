# Isolate the failing expressions. ASCII only.
function T {
    param([string]$Name, [scriptblock]$Body)
    try {
        $r = & $Body
        Write-Host ("OK    {0}  => {1}" -f $Name, $r)
    } catch {
        Write-Host ("THROW {0}  => {1}" -f $Name, $_.Exception.Message)
    }
}

$list = New-Object 'System.Collections.Generic.List[object]'
$objA = [ordered]@{ id = 'A'; priority = 3; title = 'aa' }
$objB = [ordered]@{ id = 'B'; priority = 1; title = 'bb' }
$null = $list.Add($objA)
$null = $list.Add($objB)

T 'A_atsign_list_count' { @($list).Count }
T 'B_liststring_add' { $b = New-Object 'System.Collections.Generic.List[string]'; $null = $b.Add(('x {0}' -f 1)); $b -join '|' }
T 'C_f_with_atcount' { $b = New-Object 'System.Collections.Generic.List[string]'; $null = $b.Add(('x {0}' -f @($list).Count)); $b -join '|' }
T 'D_f_with_prop' { $b = New-Object 'System.Collections.Generic.List[string]'; $h = [ordered]@{ title = 'tt' }; $null = $b.Add(('y {0}' -f $h.title)); $b -join '|' }
T 'E_sort_ordered' { $s = @($list | Sort-Object { $_['priority'] }); ($s | ForEach-Object { $_.id }) -join ',' }
T 'F_catalog_lookup' { $cat = [ordered]@{ A = [ordered]@{ Title = 't1' } }; $c = $cat['A']; $c.Title }
T 'G_ordered_value_atlist' { $d = [ordered]@{ tweaks = @($list) }; $d.tweaks.Count }
T 'H_foreach_atlist' { $n = 0; foreach ($t in @($list)) { $n += $t.priority }; $n }
T 'J_format_braces' { ('    {0} = @{{ Title = ''{1}'' }}' -f 'ID', 'TITLE') }
T 'K_atnull_count' { @($null).Count }
T 'L_f_with_list_count_prop' { $b = New-Object 'System.Collections.Generic.List[string]'; $null = $b.Add(('x {0}' -f $list.Count)); $b -join '|' }
T 'M_first_entry_title' { $s = @($list | Sort-Object { $_['priority'] }); $s[0].title }
T 'N_script_ordered' { $script:Cat2 = [ordered]@{ X = [ordered]@{ Title = 'tx'; Admin = $true } }; $c2 = $script:Cat2['X']; "$($c2.Title)/$($c2.Admin)" }
