
# ---------------------------------------------------------------------------
# 找游戏安装位置 / 启动器 / 主流程
# ---------------------------------------------------------------------------
function Resolve-GameDetails {
    param([string]$Name, [string]$ProcessHint, [string]$PathHint)

    $path = $PathHint
    if (-not $path -and $Name) {
        $path = Find-GameInstall -Name $Name -ProcessName $ProcessHint
    }

    $procName = ''
    if ($path -and "$path".ToLower().EndsWith('.exe')) {
        $procName = [System.IO.Path]::GetFileNameWithoutExtension("$path")
    } elseif ($ProcessHint) {
        $procName = $ProcessHint
    }

    $running = $false
    if ($procName) {
        $p = @(Get-Process -Name $procName -ErrorAction SilentlyContinue)
        if ($p.Count -gt 0) {
            $running = $true
            if (-not $path -and $p[0].Path) {
                $path = "$($p[0].Path)"
                $procName = [System.IO.Path]::GetFileNameWithoutExtension("$path")
            }
        }
    }

    $prefValue = $null
    $prefKind = $null
    if ($path -and "$path".ToLower().EndsWith('.exe')) {
        $pref = Get-UserGpuPreference -ExePath "$path"
        if ($pref) {
            $prefValue = "$($pref.value)"
            $prefKind = "$($pref.kind)"
        }
    }

    return [ordered]@{
        searchName    = $Name
        running       = $running
        installPath   = $path
        gpuPreference = $prefValue
        gpuPrefKind   = $prefKind
        processName   = $procName
        processCount  = 0
    }
}

function Set-GameInfo {
    param($Sys, $Info, [string]$FallbackName)
    if ($Sys -is [System.Collections.IDictionary]) {
        $Sys['game'] = $Info
        return
    }
    try {
        $Sys | Add-Member -NotePropertyName game -NotePropertyValue $Info -Force
    } catch {
        $script:Issues.Add("setgame: $($_.Exception.Message)") | Out-Null
    }
}

function New-LauncherBat {
    param([string]$Path, [string]$SwitchText, [string]$Banner, [string]$Hint)
    # 内容全部使用 ASCII：避免 cmd 按本地编码读取 .bat 造成的乱码与解析问题。
    # 用通配符找最新的 Optimize-*.ps1，这样 bat 里不需要出现中文文件名。
    $lines = @()
    $lines += '@echo off'
    $lines += 'setlocal enableextensions'
    $lines += 'cd /d "%~dp0"'
    $lines += 'echo.'
    $lines += ('echo ' + $Banner)
    $lines += 'echo.'
    $lines += 'set "OPTFILE="'
    $lines += 'for %%f in ("Optimize-*.ps1") do set "OPTFILE=%%~ff"'
    $lines += 'if not defined OPTFILE ('
    $lines += '  echo [ERROR] Optimize-*.ps1 was not found in this folder.'
    $lines += '  echo         Keep this .bat next to the generated Optimize-*.ps1 file.'
    $lines += '  pause'
    $lines += '  exit /b 1'
    $lines += ')'
    $lines += 'echo Using: %OPTFILE%'
    $lines += 'echo.'
    $lines += $SwitchText
    $lines += 'if errorlevel 1 pause'
    $lines += 'endlocal'
    $lines += ('rem ' + $Hint)
    $content = ($lines -join "`r`n") + "`r`n"
    Save-TextFile -Path $Path -Text $content -Bom $false
}

function Invoke-RevertLatest {
    param([string]$Dir)
    if (-not (Test-Path -LiteralPath $Dir)) {
        Write-Host ('没有找到文件夹：' + $Dir) -ForegroundColor Yellow
        return
    }
    $cands = @(Get-ChildItem -LiteralPath $Dir -Filter 'Optimize-*.ps1' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    if ($cands.Count -eq 0) {
        Write-Host '还没有生成过优化脚本，不需要回滚。' -ForegroundColor Green
        return
    }
    foreach ($c in $cands) {
        $logPath = Join-Path (Join-Path $c.DirectoryName 'optimize-logs') 'journal.json'
        if (Test-Path -LiteralPath $logPath) {
            Write-Host ('找到应用记录，正在按日志回滚：' + $c.Name) -ForegroundColor Yellow
            & $c.FullName -Revert -NoPause
            return
        }
    }
    Write-Host '找到了优化脚本，但没有找到应用记录（说明还没有真正应用过），不需要回滚。' -ForegroundColor Green
}

function Restart-SelfElevated {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'))
    if ($RevertLatest) { $argList += '-RevertLatest' }
    if ($OutDir) { $argList += @('-OutDir', ('"' + $OutDir + '"')) }
    if ($NoPause) { $argList += '-NoPause' }
    Write-Host '正在请求管理员权限，请在弹出的小窗口里点"是"...' -ForegroundColor Yellow
    try {
        Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs -Wait
    } catch {
        Write-Host '你取消了管理员授权，什么都没有修改。' -ForegroundColor Yellow
    }
}

function Show-Result {
    param([string]$OutDir, [string]$ReportPath, [string]$JsonPath, [string]$OptName)
    Write-Title '完成'
    Write-Host '生成的文件都在这个文件夹里：'
    Write-Host ('  ' + $OutDir) -ForegroundColor White
    Write-Host ''
    Write-Bullet ('报告（先看这个）：' + [System.IO.Path]::GetFileName($ReportPath))
    Write-Bullet ('原始采集数据：' + [System.IO.Path]::GetFileName($JsonPath))
    Write-Bullet ('优化脚本：' + $OptName)
    Write-Bullet '3-预演不改动.bat（只看不改）'
    Write-Bullet '4-真正应用优化.bat（会请求管理员权限）'
    Write-Bullet '5-一键回滚.bat'
    Write-Host ''
    Write-Host '建议的顺序：' -ForegroundColor Yellow
    Write-Host '  1) 先打开报告，看开头的"一句话结论"和第五节的优化清单'
    Write-Host '  2) 报告 5.3 里的手动步骤（更新驱动、调画质、开刷新率等）先做掉'
    Write-Host '  3) 双击 3-预演不改动.bat 看清计划，再双击 4-真正应用优化.bat 应用'
    Write-Host '  4) 万一有问题：双击 5-一键回滚.bat（主目录里的 3-一键回滚.bat 也一样）'
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
if ($Monitor) {
    # 边玩边记录模式：只读采样，不需要管理员权限，也不会修改任何设置
    $monDir = ''
    if ($PSBoundParameters.ContainsKey('OutDir')) { $monDir = [string]$OutDir }
    $monLaunch = $true
    if ($MonitorNoLaunch) { $monLaunch = $false }
    Invoke-MonitorMode -GameName $MonitorGame -Seconds $MonitorSeconds -Dir $monDir -GameProcess $GameProcess -ExePath $MonitorExe -NoLaunch:$MonitorNoLaunch
    exit 0
}

Write-Title '游戏性能体检与优化方案生成器'
Write-Host '这个程序做两件事：'
Write-Bullet '只读采集这台电脑的现状（不改任何设置）'
Write-Bullet '生成一份诊断报告 + 一份可预演、可一键回滚的优化脚本'
Write-Host ''
Write-Host '它不会动：Windows Defender、Windows 更新、系统服务、游戏文件、反作弊进程。'
Write-Host '所有数据都留在本机，不会上传。'
Write-Host ''
if (-not (Test-IsAdmin)) {
    Write-Note '（当前是普通权限运行，体检本来就不需要管理员；需要管理员的优化项会在应用时单独提示）'
}

if ($Elevate -and -not (Test-IsAdmin)) {
    Write-Host ''
    Restart-SelfElevated
    exit 0
}

if ($RevertLatest) {
    Write-Step '回滚上一次应用过的优化'
    Invoke-RevertLatest -Dir $OutDir
    Wait-Key
    exit 0
}

# ---- 1. 采集 --------------------------------------------------------------
$sys = $null
if ($SystemJson) {
    Write-Step ('从已有文件读取采集数据：' + $SystemJson)
    try {
        $sys = Get-Content -Raw -LiteralPath $SystemJson | ConvertFrom-Json
        $dm = @{}
        if ($sys.driveMedia) {
            foreach ($p in $sys.driveMedia.PSObject.Properties) { $dm[$p.Name] = $p.Value }
        }
        $sys.driveMedia = $dm
        Write-Ok '读取成功'
    } catch {
        Write-Bad ('读取失败：' + $_.Exception.Message)
        Write-Note '改为重新采集。'
        $sys = $null
    }
}
if (-not $sys) {
    Write-Step '第一步：只读采集本机现状（大概需要 10~30 秒，请稍等）'
    $sys = Collect-System -Game $GameProcess
    Write-Ok '采集完成'
    if (@($sys.readIssues).Count -gt 0) {
        Write-Note ('其中有 ' + @($sys.readIssues).Count + ' 项没有读到，报告最后一节会列出来。')
    }
}

# ---- 2. 问诊 --------------------------------------------------------------
Write-Step '第二步：回答几个关于游戏的问题（每一项直接回车就选默认值）'
$answers = Invoke-Interview -Sys $sys
Write-Host ''
Show-Answers -A $answers
Wait-Key '确认无误按回车继续（想改的话就重新运行一次程序）...'

# ---- 3. 用游戏名定位安装位置 ------------------------------------------------
$procHint = $GameProcess
if ($answers.gameName -or $procHint -or $answers.gamePath) {
    Write-Step '第三步：定位游戏安装位置（只读，用来判断硬盘类型和显卡指派）'
    $info = Resolve-GameDetails -Name "$($answers.gameName)" -ProcessHint $procHint -PathHint "$($answers.gamePath)"
    Set-GameInfo -Sys $sys -Info $info -FallbackName "$($answers.gameName)"
    if ($info.installPath) {
        Write-Ok ('找到：' + $info.installPath)
    } else {
        Write-Warn '没有在本机找到这个游戏的安装位置，硬盘相关的判断会跳过。'
    }
    if ($info.running) {
        Write-Note ('游戏正在运行（进程名 ' + $info.processName + '），可以把它的优先级也一起提上去。')
    }
} else {
    Write-Step '第三步：跳过游戏安装位置定位（你没有提供游戏名）'
}

# ---- 4. 诊断 --------------------------------------------------------------
Write-Step '第四步：分析瓶颈'
$diag = Invoke-Diagnosis -Sys $sys -A $answers
Write-Host ''
Write-Host '  结论：' -ForegroundColor Cyan
foreach ($bit in ("$($diag.summary)" -split '；')) {
    if ("$bit".Trim().Length -gt 0) { Write-Host ('    · ' + $bit.Trim()) -ForegroundColor Cyan }
}
Write-Host ''
Write-Host ('  判断出的问题项：' + @($diag.findings).Count + ' 项   手动步骤：' + @($diag.manual).Count + ' 项   脚本可代劳：' + @($diag.tweaks).Count + ' 项')

# ---- 5. 写文件 ------------------------------------------------------------
Write-Step '第五步：生成报告和优化脚本'
$stamp = Get-Date -Format 'yyyyMMdd-HHmm'
$gameTag = Get-SafeFileName -Name "$($answers.gameName)"
$machineTag = "$env:COMPUTERNAME"
$reportPath = Join-Path $OutDir ('报告-' + $gameTag + '-' + $stamp + '.md')
$jsonPath = Join-Path $OutDir ('采集数据-' + $machineTag + '-' + $stamp + '.json')
$optName = 'Optimize-' + $gameTag + '-' + $stamp + '.ps1'
$optPath = Join-Path $OutDir $optName

try {
    if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
} catch {
    Write-Bad ('无法创建输出文件夹：' + $OutDir)
    Write-Bad ('错误：' + $_.Exception.Message)
    Wait-Key
    exit 1
}

$jsonText = $sys | ConvertTo-Json -Depth 8
Save-TextFile -Path $jsonPath -Text $jsonText -Bom $false

$reportText = New-Report -Sys $sys -A $answers -Diag $diag -Stamp $stamp -SystemJsonPath $jsonPath
Save-TextFile -Path $reportPath -Text $reportText -Bom $true

$procName = ''
if ($sys.game -and "$($sys.game.processName)") { $procName = "$($sys.game.processName)" }
$targetExe = ''
if ($sys.game -and "$($sys.game.installPath)" -and "$($sys.game.installPath)".ToLower().EndsWith('.exe')) {
    $targetExe = "$($sys.game.installPath)"
}
$optText = New-OptimizeScript -Sys $sys -A $answers -Diag $diag -Stamp $stamp -GameTag $gameTag -MachineTag $machineTag -ProcName $procName -TargetExe $targetExe
Save-TextFile -Path $optPath -Text $optText -Bom $true

New-LauncherBat -Path (Join-Path $OutDir '3-预演不改动.bat') `
    -SwitchText 'powershell -NoProfile -ExecutionPolicy Bypass -File "%OPTFILE%"' `
    -Banner 'PREVIEW ONLY - nothing will be changed.' `
    -Hint 'preview'
New-LauncherBat -Path (Join-Path $OutDir '4-真正应用优化.bat') `
    -SwitchText 'powershell -NoProfile -ExecutionPolicy Bypass -File "%OPTFILE%" -Apply -Elevate' `
    -Banner 'APPLY - settings will be changed and journaled.' `
    -Hint 'apply'
New-LauncherBat -Path (Join-Path $OutDir '5-一键回滚.bat') `
    -SwitchText 'powershell -NoProfile -ExecutionPolicy Bypass -File "%OPTFILE%" -Revert -Elevate' `
    -Banner 'REVERT - restore everything recorded in the journal.' `
    -Hint 'revert'

Write-Ok '完成'

Show-Result -OutDir $OutDir -ReportPath $reportPath -JsonPath $jsonPath -OptName $optName

if (-not $script:IsNonInteractive -and -not $NoPause) {
    Write-Host ''
    $ans = Read-Host '要现在打开报告文件夹吗？（直接回车打开，输入 n 跳过）'
    if ($ans -ne 'n' -and $ans -ne 'N') {
        try { Start-Process explorer.exe -ArgumentList ('"' + $OutDir + '"') | Out-Null } catch { }
    }
}
if (-not $script:IsNonInteractive -and -not $NoPause) {
    Write-Host ''
    $ans2 = Read-Host '要现在打开报告文件吗？（输入 y 打开，直接回车结束）'
    if ($ans2 -eq 'y' -or $ans2 -eq 'Y') {
        try { Start-Process notepad.exe -ArgumentList ('"' + $reportPath + '"') | Out-Null } catch { }
    }
}

# @@PART9-END@@
