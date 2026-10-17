
# ---------------------------------------------------------------------------
# 写文件 / 生成个性化优化脚本
# ---------------------------------------------------------------------------
function Save-TextFile {
    param([string]$Path, [string]$Text, [bool]$Bom = $true)
    $dir = [System.IO.Path]::GetDirectoryName($Path)
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $enc = New-Object System.Text.UTF8Encoding($Bom)
    [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

function Escape-Single {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    return $Text.Replace("'", "''")
}

function New-OptimizeScript {
    param($Sys, [hashtable]$A, $Diag, [string]$Stamp, [string]$GameTag, [string]$MachineTag, [string]$ProcName, [string]$TargetExe)

    $ids = @($Diag.tweaks | ForEach-Object { "$([char]39)$($_.id)$([char]39)" })
    $selectedText = ''
    if ($ids.Count -gt 0) { $selectedText = ($ids -join ', ') }

    $infoLines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($t in @($Diag.tweaks)) {
        $cat = $script:TweakCatalog[$t.id]
        $risk = 'low'
        if ("$($cat.Risk)" -eq '中') { $risk = 'medium' }
        if ("$($cat.Risk)" -eq '高') { $risk = 'high' }
        $adminText = '$false'
        if ($cat.Admin) { $adminText = '$true' }
        $rebootText = '$false'
        if ($cat.Reboot) { $rebootText = '$true' }
        $riskyText = '$false'
        if ($cat.Risky) { $riskyText = '$true' }
        $title = Escape-Single "$($cat.Title)"
        $line = '    {0} = @{{ Title = ''{1}''; Risk = ''{2}''; Admin = {3}; Reboot = {4}; Risky = {5} }}'
        $infoLines.Add(($line -f $t.id, $title, $risk, $adminText, $rebootText, $riskyText)) | Out-Null
    }

    $manualLines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($m in @($Diag.manual)) {
        $line = '    @{{ title = ''{0}''; detail = ''{1}''; uri = ''{2}'' }}'
        $manualLines.Add(($line -f (Escape-Single "$($m.title)"), (Escape-Single "$($m.detail)"), (Escape-Single "$($m.uri)"))) | Out-Null
    }

    $gpuText = '未知'
    if (@($Sys.gpus).Count -gt 0) { $gpuText = ((@($Sys.gpus) | ForEach-Object { $_.name }) -join ' + ') }
    $headerLines = New-Object 'System.Collections.Generic.List[string]'
    $headerLines.Add(('    {0} 在本机上的个性化优化脚本' -f (Escape-Single "$($A.gameName)"))) | Out-Null
    $headerLines.Add('') | Out-Null
    $headerLines.Add(('    生成时间：{0}' -f $Sys.generatedAt)) | Out-Null
    $headerLines.Add(('    目标机器：{0} / {1} / {2}' -f (Escape-Single "$MachineTag"), (Escape-Single "$($Sys.cpu.name)"), (Escape-Single "$gpuText"))) | Out-Null
    $headerLines.Add(('    诊断摘要：{0}' -f (Escape-Single "$($Diag.summary)"))) | Out-Null
    $headerLines.Add('') | Out-Null
    $headerLines.Add('    本脚本只会改下面这些项，每一项都会先把原值记进日志，随时可以还原：') | Out-Null
    if (@($Diag.tweaks).Count -eq 0) {
        $headerLines.Add('      （本次没有开关类改动，请看报告里的手动步骤）') | Out-Null
    } else {
        foreach ($t in @($Diag.tweaks)) {
            $cat = $script:TweakCatalog[$t.id]
            $headerLines.Add(('      - {0}：{1}' -f (Escape-Single "$($cat.Title)"), (Escape-Single "$($t.reason)"))) | Out-Null
        }
    }
    $headerLines.Add('') | Out-Null
    $headerLines.Add('    不会做的事：不关 Defender、不关 Windows 更新、不批量禁用系统服务、') | Out-Null
    $headerLines.Add('    不改游戏文件、不碰反作弊进程、不做超频。') | Out-Null

    $template = @'
<#
__HEADER__

    用法（默认是"只看不改"）：
      预演：powershell -ExecutionPolicy Bypass -File .\Optimize-__GAME__-__STAMP__.ps1
      执行：powershell -ExecutionPolicy Bypass -File .\Optimize-__GAME__-__STAMP__.ps1 -Apply
      回滚：powershell -ExecutionPolicy Bypass -File .\Optimize-__GAME__-__STAMP__.ps1 -Revert

    也可以直接双击同目录下的 3-预演不改动.bat / 4-真正应用优化.bat / 5-一键回滚.bat。
#>
[CmdletBinding()]
param(
    [switch]$Apply,
    [switch]$Revert,
    [switch]$AllowRisky,
    [switch]$Elevate,
    [switch]$NoPause,
    [string]$LogDir,
    [string]$GameProcess = '__GAME_PROCESS__'
)

$ErrorActionPreference = 'Continue'
$MachineTag = '__MACHINE_TAG__'
$TargetExe = '__TARGET_EXE__'
$SelectedTweaks = @( __SELECTED_TWEAKS__ )
$TweakInfo = @{
__TWEAK_INFO__
}
$ManualSteps = @(
__MANUAL_STEPS__
)

if (-not $LogDir) {
    if ($PSScriptRoot) { $LogDir = Join-Path $PSScriptRoot 'optimize-logs' } else { $LogDir = Join-Path (Get-Location).Path 'optimize-logs' }
}
$JournalPath = Join-Path $LogDir 'journal.json'

function Test-Admin {
    try {
        return ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Get-RegValueOrNull {
    param([string]$Path, [string]$Name)
    try {
        $key = Get-Item -Path $Path -ErrorAction Stop
        return $key.GetValue($Name, $null, 'DoNotExpandEnvironmentNames')
    } catch { return $null }
}

function StringOf {
    param($Value)
    if ($null -eq $Value) { return '（原本没有）' }
    if ("$Value" -eq '') { return '（空）' }
    return "$Value"
}

function Write-AdminNote {
    if (-not (Test-Admin)) {
        Write-Host '      （这一项需要管理员权限，正式应用时请双击 4-真正应用优化.bat，它会自动请求）' -ForegroundColor Yellow
    }
}

function Show-RegPreview {
    param([string]$Path, [string]$Name, $NewValue)
    $old = Get-RegValueOrNull -Path $Path -Name $Name
    Write-Host ('      将设置 {0} = {1}（原值：{2}）' -f $Name, (StringOf $NewValue), (StringOf $old))
}

function New-JournalEntry {
    param([string]$Tweak, [string]$Kind, [string]$Path, [string]$Name, $OldValue, $NewValue, [string]$OldType)
    return [ordered]@{
        tweak = $Tweak
        kind = $Kind
        path = $Path
        name = $Name
        oldValue = $OldValue
        oldType = $OldType
        newValue = $NewValue
        appliedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }
}

function Save-Journal {
    param($Entry)
    if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
    $entries = @()
    if (Test-Path -LiteralPath $JournalPath) {
        try {
            $raw = [System.IO.File]::ReadAllText($JournalPath, [System.Text.Encoding]::UTF8)
            if ($raw.Trim().Length -gt 0) { $entries = @(($raw | ConvertFrom-Json).entries) }
        } catch { $entries = @() }
    }
    $entries = @($entries) + @($Entry)
    $payload = [ordered]@{ updatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); entries = $entries } | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText($JournalPath, $payload, (New-Object System.Text.UTF8Encoding($false)))
    $logLine = ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '  ' + $Entry.tweak + '  ' + $Entry.name + '  ' + (StringOf $Entry.oldValue) + ' -> ' + (StringOf $Entry.newValue))
    Add-Content -LiteralPath (Join-Path $LogDir 'apply.log') -Value $logLine -Encoding UTF8
}

function Set-RegTweak {
    param([string]$Tweak, [string]$Path, [string]$Name, $NewValue, [string]$Type = 'DWord', [switch]$Preview)
    $old = $null
    $oldType = $null
    try {
        $key = Get-Item -Path $Path -ErrorAction Stop
        $old = $key.GetValue($Name, $null, 'DoNotExpandEnvironmentNames')
        if ($null -ne $old) { $oldType = "$($key.GetValueKind($Name))" }
    } catch { }
    if ($Preview) {
        Write-Host ('      将设置 {0} = {1}（原值：{2}）' -f $Name, (StringOf $NewValue), (StringOf $old))
        return
    }
    try {
        if (-not (Test-Path -Path $Path)) { New-Item -Path $Path -Force | Out-Null }
        Set-ItemProperty -Path $Path -Name $Name -Value $NewValue -Type $Type
    } catch {
        Write-Host ('      写入失败：{0}' -f $_.Exception.Message) -ForegroundColor Red
        return
    }
    Save-Journal (New-JournalEntry -Tweak $Tweak -Kind 'registry' -Path $Path -Name $Name -OldValue $old -NewValue $NewValue -OldType $oldType)
    Write-Host ('      已设置 {0} = {1}（原值：{2}）' -f $Name, (StringOf $NewValue), (StringOf $old))
}

function Show-Plan {
    param([string]$Tweak)
    $info = $TweakInfo[$Tweak]
    if (-not $info) {
        Write-Host ('  - ' + $Tweak)
        return
    }
    $flags = @()
    if ($info.Admin) { $flags += '需要管理员' }
    if ($info.Reboot) { $flags += '需要重启' }
    if ($info.Risky) { $flags += '有安全代价' }
    $flagText = ''
    if ($flags.Count -gt 0) { $flagText = '（' + ($flags -join '，') + '）' }
    Write-Host ('  - ' + $info.Title + '  ' + $flagText)
}

function Restart-Elevated {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'))
    if ($Apply) { $argList += '-Apply' }
    if ($Revert) { $argList += '-Revert' }
    if ($AllowRisky) { $argList += '-AllowRisky' }
    if ($NoPause) { $argList += '-NoPause' }
    Write-Host '正在请求管理员权限，请在弹出的小窗口里点"是"...' -ForegroundColor Yellow
    try {
        Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs -Wait
    } catch {
        Write-Host '你取消了管理员授权，什么都没有修改。' -ForegroundColor Yellow
    }
}

function Invoke-Tweak {
    param([string]$Tweak, [switch]$Preview)
    $admin = Test-Admin

    switch ($Tweak) {
        'GAME_MODE' {
            Write-Host '  [游戏模式] 打开 Windows 游戏模式'
            Set-RegTweak -Tweak 'GAME_MODE' -Path 'HKCU:\Software\Microsoft\GameBar' -Name 'AutoGameModeEnabled' -NewValue 1 -Type DWord -Preview:$Preview
        }
        'GAME_DVR_OFF' {
            Write-Host '  [关闭后台录制] 关闭游戏 DVR / 后台捕获'
            Set-RegTweak -Tweak 'GAME_DVR_OFF' -Path 'HKCU:\System\GameConfigStore' -Name 'GameDVR_Enabled' -NewValue 0 -Type DWord -Preview:$Preview
            Set-RegTweak -Tweak 'GAME_DVR_OFF' -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' -Name 'AppCaptureEnabled' -NewValue 0 -Type DWord -Preview:$Preview
        }
        'POWER_PLAN_HIGH' {
            Write-Host '  [电源计划] 切换到高性能/卓越性能'
            $activeText = ((& powercfg /getactivescheme) -join ' ')
            $oldGuid = ''
            if ($activeText -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') { $oldGuid = $Matches[1] }
            $planList = ((& powercfg /list) -join "`n")
            $target = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
            $targetName = '高性能'
            if ($planList -match 'e9a42b02-d5df-448d-aa00-03f14749eb61') {
                $target = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
                $targetName = '卓越性能'
            }
            if ($Preview) {
                Write-Host ('      将切换到电源计划：{0}（当前 {1}）' -f $targetName, $oldGuid)
                Write-AdminNote
                return
            }
            if (-not $admin) {
                Write-Host '      跳过：需要管理员权限（请用 4-真正应用优化.bat 运行，它会自动请求管理员）' -ForegroundColor Yellow
                return
            }
            & powercfg /setactive $target | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Host '      切换失败，系统里可能没有这个电源计划，已跳过。' -ForegroundColor Red
                return
            }
            Save-Journal (New-JournalEntry -Tweak 'POWER_PLAN_HIGH' -Kind 'powerplan' -Path 'powercfg' -Name 'active' -OldValue $oldGuid -NewValue $target -OldType 'guid')
            Write-Host ('      已切换到{0}（原计划 {1}）' -f $targetName, $oldGuid)
        }
        'FAST_STARTUP_OFF' {
            Write-Host '  [快速启动] 关闭快速启动'
            if ($Preview) {
                Show-RegPreview -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name 'HiberbootEnabled' -NewValue 0
                Write-AdminNote
                return
            }
            if (-not $admin) {
                Write-Host '      跳过：需要管理员权限（请用 4-真正应用优化.bat 运行）' -ForegroundColor Yellow
                return
            }
            Set-RegTweak -Tweak 'FAST_STARTUP_OFF' -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name 'HiberbootEnabled' -NewValue 0 -Type DWord -Preview:$Preview
        }
        'HAGS_ON' {
            Write-Host '  [HAGS] 开启硬件加速 GPU 计划'
            if ($Preview) {
                Show-RegPreview -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name 'HwSchMode' -NewValue 2
                Write-AdminNote
                Write-Host '      （这一项需要重启电脑才会生效）'
                return
            }
            if (-not $admin) {
                Write-Host '      跳过：需要管理员权限（请用 4-真正应用优化.bat 运行）' -ForegroundColor Yellow
                return
            }
            Set-RegTweak -Tweak 'HAGS_ON' -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name 'HwSchMode' -NewValue 2 -Type DWord -Preview:$Preview
            if (-not $Preview) { Write-Host '      这一项需要重启电脑才会生效' -ForegroundColor Yellow }
        }
        'GPU_PREF_HIGH' {
            Write-Host '  [指定独显] 让游戏使用"高性能"GPU'
            if (-not $TargetExe) {
                Write-Host '      跳过：没有拿到游戏的 exe 路径（可以在 设置-系统-屏幕-显示卡 里手动指定）' -ForegroundColor Yellow
                return
            }
            $regPath = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
            $old = Get-RegValueOrNull -Path $regPath -Name $TargetExe
            $new = 'GpuPreference=2;'
            if ($old -and "$old" -match 'GpuPreference\s*=') {
                $new = ("$old") -replace 'GpuPreference\s*=\s*\d+\s*;?', 'GpuPreference=2;'
            }
            if ($Preview) {
                Write-Host ('      将写入 {0} = {1}（原值：{2}）' -f $TargetExe, $new, (StringOf $old))
                return
            }
            try {
                if (-not (Test-Path -Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
                Set-ItemProperty -Path $regPath -Name $TargetExe -Value $new -Type String
            } catch {
                Write-Host ('      写入失败：{0}' -f $_.Exception.Message) -ForegroundColor Red
                return
            }
            Save-Journal (New-JournalEntry -Tweak 'GPU_PREF_HIGH' -Kind 'registry' -Path $regPath -Name $TargetExe -OldValue $old -NewValue $new -OldType 'String')
            Write-Host ('      已设置（原值：{0}）' -f (StringOf $old))
        }
        'GAME_PRIORITY' {
            Write-Host '  [进程优先级] 提高游戏进程优先级'
            if (-not $GameProcess) {
                Write-Host '      跳过：没有拿到游戏进程名' -ForegroundColor Yellow
                return
            }
            $proc = @(Get-Process -Name $GameProcess -ErrorAction SilentlyContinue)
            if ($proc.Count -eq 0) {
                Write-Host ('      游戏（进程名 {0}）现在没有运行；先打开游戏再运行本脚本就能生效' -f $GameProcess) -ForegroundColor Yellow
                return
            }
            $p = $proc[0]
            if ($Preview) {
                Write-Host ('      将把 {0}（PID {1}）的优先级从 {2} 提到 High' -f $GameProcess, $p.Id, $p.PriorityClass)
                return
            }
            $oldPriority = "$($p.PriorityClass)"
            try {
                $p.PriorityClass = 'High'
            } catch {
                Write-Host ('      设置失败：{0}' -f $_.Exception.Message) -ForegroundColor Red
                return
            }
            Save-Journal (New-JournalEntry -Tweak 'GAME_PRIORITY' -Kind 'process' -Path $GameProcess -Name 'priority' -OldValue $oldPriority -NewValue 'High' -OldType 'processpriority')
            Write-Host ('      已提高优先级（原值 {0}）；关掉游戏就自动恢复' -f $oldPriority)
        }
        'VBS_OFF' {
            Write-Host '  [VBS] 关闭基于虚拟化的安全性 / 内存完整性' -ForegroundColor Yellow
            if (-not $AllowRisky) {
                Write-Host '      跳过：这一项有安全代价，必须显式加 -AllowRisky 才会执行' -ForegroundColor Yellow
                if ($Preview) {
                    Show-RegPreview -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' -Name 'EnableVirtualizationBasedSecurity' -NewValue 0
                }
                return
            }
            if ($Preview) {
                Show-RegPreview -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' -Name 'EnableVirtualizationBasedSecurity' -NewValue 0
                Show-RegPreview -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' -Name 'Enabled' -NewValue 0
                Write-AdminNote
                Write-Host '      （这一项需要重启电脑才会生效）'
                Write-Host '      提醒：关掉之后系统对抗恶意软件的能力会下降。' -ForegroundColor Yellow
                return
            }
            if (-not $admin) {
                Write-Host '      跳过：需要管理员权限（请用 4-真正应用优化.bat 运行）' -ForegroundColor Yellow
                return
            }
            Write-Host '      提示：关掉之后系统对抗恶意软件的能力会下降，你随时可以回滚。' -ForegroundColor Yellow
            Set-RegTweak -Tweak 'VBS_OFF' -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' -Name 'EnableVirtualizationBasedSecurity' -NewValue 0 -Type DWord -Preview:$Preview
            Set-RegTweak -Tweak 'VBS_OFF' -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' -Name 'Enabled' -NewValue 0 -Type DWord -Preview:$Preview
            if (-not $Preview) { Write-Host '      这一项需要重启电脑才会生效' -ForegroundColor Yellow }
        }
        default {
            Write-Host ('  未知的改动项：{0}' -f $Tweak) -ForegroundColor Yellow
        }
    }
}

function Invoke-Revert {
    if (-not (Test-Path -LiteralPath $JournalPath)) {
        Write-Host '没有找到日志文件，说明还没有应用过改动，不需要回滚。' -ForegroundColor Green
        return
    }
    $raw = [System.IO.File]::ReadAllText($JournalPath, [System.Text.Encoding]::UTF8)
    if ($raw.Trim().Length -eq 0) {
        Write-Host '日志是空的，不需要回滚。'
        return
    }
    $entries = @(($raw | ConvertFrom-Json).entries)
    if ($entries.Count -eq 0) {
        Write-Host '日志里没有记录，不需要回滚。'
        return
    }
    [array]::Reverse($entries)
    foreach ($e in $entries) {
        switch ("$($e.kind)") {
            'registry' {
                if ($null -eq $e.oldValue) {
                    Remove-ItemProperty -Path "$($e.path)" -Name "$($e.name)" -ErrorAction SilentlyContinue
                    Write-Host ('  已删除 {0} 下的 {1}' -f $e.path, $e.name)
                } else {
                    $t = 'DWord'
                    if ($e.oldType) { $t = "$($e.oldType)" }
                    try {
                        Set-ItemProperty -Path "$($e.path)" -Name "$($e.name)" -Value $e.oldValue -Type $t -ErrorAction Stop
                        Write-Host ('  已还原 {0} = {1}' -f $e.name, $e.oldValue)
                    } catch {
                        Write-Host ('  还原失败（可能需要管理员权限）：{0}' -f $_.Exception.Message) -ForegroundColor Yellow
                    }
                }
            }
            'powerplan' {
                $guid = "$($e.oldValue)"
                if ($guid -match '([0-9a-fA-F-]{36})') {
                    & powercfg /setactive $Matches[1] | Out-Null
                    if ($LASTEXITCODE -eq 0) {
                        Write-Host ('  已还原电源计划 {0}' -f $Matches[1])
                    } else {
                        Write-Host '  电源计划还原失败，请在控制面板-电源选项里手动选一下' -ForegroundColor Yellow
                    }
                }
            }
            'process' {
                Write-Host '  游戏进程优先级：关掉游戏后会自己恢复，不用处理'
            }
            default {
                Write-Host ('  跳过未知记录：{0}' -f $e.kind)
            }
        }
    }
    $archive = Join-Path $LogDir ('journal-reverted-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')
    Move-Item -LiteralPath $JournalPath -Destination $archive -Force
    Write-Host ('回滚完成。原日志已归档为 {0}' -f $archive) -ForegroundColor Green
}

function Show-ManualSteps {
    if (-not $ManualSteps -or $ManualSteps.Count -eq 0) { return }
    Write-Host ''
    Write-Host '===== 下面这些脚本不能替你做，请手动完成 =====' -ForegroundColor Yellow
    $i = 0
    foreach ($m in $ManualSteps) {
        $i++
        Write-Host ('  {0}. {1}' -f $i, $m.title) -ForegroundColor White
        Write-Host ('     {0}' -f $m.detail)
    }
    if ($NoPause) { return }
    $openable = @($ManualSteps | Where-Object { $_.uri })
    if ($openable.Count -eq 0) { return }
    Write-Host ''
    $ans = Read-Host '要现在依次打开上面提到的设置页面吗？（输入 y 打开，直接回车跳过）'
    if ($ans -eq 'y' -or $ans -eq 'Y') {
        foreach ($m in $openable) {
            Write-Host ('  正在打开：{0}' -f $m.title)
            try { Start-Process "$($m.uri)" | Out-Null } catch { Write-Host '    没打开成功，请自己在设置里找一下' -ForegroundColor Yellow }
            Start-Sleep -Milliseconds 700
        }
    }
}

function End-Pause {
    if ($NoPause) { return }
    Write-Host ''
    Read-Host '按回车结束' | Out-Null
}

Write-Host ''
Write-Host ('优化脚本：' + $MachineTag) -ForegroundColor Cyan
Write-Host ('包含改动项：' + @($SelectedTweaks).Count + ' 项')

$admin = Test-Admin

if ($Revert) {
    Write-Host ''
    if (-not $admin -and $Elevate) {
        Restart-Elevated
        exit 0
    }
    Write-Host '开始回滚...' -ForegroundColor Yellow
    Invoke-Revert
    End-Pause
    exit 0
}

if ($Apply -and -not $admin -and $Elevate) {
    Write-Host ''
    Restart-Elevated
    exit 0
}

$preview = -not $Apply
Write-Host ''
if ($preview) {
    Write-Host '【预演模式】不会修改任何设置，只是把计划打印出来。' -ForegroundColor Green
} else {
    Write-Host '【执行模式】会修改设置，并先把原值写进日志，随时可以回滚。' -ForegroundColor Yellow
}
if (-not $admin) {
    Write-Host '（当前不是管理员权限，需要管理员的项目会被自动跳过）' -ForegroundColor Yellow
}
Write-Host ''
Write-Host '计划清单：'
foreach ($t in @($SelectedTweaks)) { Show-Plan -Tweak $t }
Write-Host ''
Write-Host '明细：'
foreach ($t in @($SelectedTweaks)) { Invoke-Tweak -Tweak $t -Preview:$preview }
Write-Host ''

if ($preview) {
    Write-Host '以上只是预演，什么都没有改。' -ForegroundColor Green
    Write-Host '确认没问题后，双击 4-真正应用优化.bat 真正执行。' -ForegroundColor Green
} else {
    Write-Host ('完成。日志：' + $JournalPath) -ForegroundColor Green
    Write-Host '想还原设置：双击 5-一键回滚.bat' -ForegroundColor Green
}

Show-ManualSteps
End-Pause
'@

    $scriptText = $template
    $scriptText = $scriptText.Replace('__HEADER__', ($headerLines -join "`r`n"))
    $scriptText = $scriptText.Replace('__GAME__', $GameTag)
    $scriptText = $scriptText.Replace('__STAMP__', $Stamp)
    $scriptText = $scriptText.Replace('__MACHINE_TAG__', (Escape-Single "$MachineTag"))
    $scriptText = $scriptText.Replace('__TARGET_EXE__', (Escape-Single "$TargetExe"))
    $scriptText = $scriptText.Replace('__GAME_PROCESS__', (Escape-Single "$ProcName"))
    $scriptText = $scriptText.Replace('__SELECTED_TWEAKS__', $selectedText)
    $scriptText = $scriptText.Replace('__TWEAK_INFO__', ($infoLines -join "`r`n"))
    $scriptText = $scriptText.Replace('__MANUAL_STEPS__', ($manualLines -join ",`r`n"))
    # 统一成 CRLF，记事本打开也好看
    $scriptText = $scriptText.Replace("`r`n", "`n").Replace("`n", "`r`n")
    return $scriptText
}

# @@PART6-END@@
