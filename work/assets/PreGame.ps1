<#
    开游戏前整备 —— 进游戏之前跑一下，把抢内存和抢磁盘的后台清掉，游戏结束后自动放回来

    为什么清单里是这几样（来自一份 2026-10-16 的实测记录：一台笔记本跑三角洲）：
      - 网盘同步：OneDrive 系列平均吃掉 32.9MB/s 磁盘、峰值 275.9MB/s，占全部进程磁盘 IO 的 51%，
        比游戏自己（25.1MB/s）还高；游戏加载贴图的时候它在往同一块盘上灌数据。
      - 覆盖层：NVIDIA Overlay 内存峰值 590MB；nvngx_update 峰值 CPU 14.6%，在后台下 DLSS 组件。
      - 聊天软件：微信相关进程内存峰值 774MB。
      - 内存：游戏跑起来之后，可用内存长期不到 1GB（占全程 70%），最低只剩 0.03GB，
        硬缺页峰值每秒 14.75 万页 —— 显卡那会儿还没吃满，它是在等磁盘和内存。
      - 加载慢：从游戏进程出现到显卡真正跑起来花了 55 秒，这期间磁盘平均 78%。

    它不做什么：不碰 explorer / dwm / svchost / 杀毒 / 系统服务，不改注册表，不动游戏文件和反作弊进程，
    不关 Windows 更新，不超频。

    用法：
      双击同目录下的 4-开游戏前整备.bat 跟着选单走（推荐）
      powershell -ExecutionPolicy Bypass -File .\PreGame.ps1          只预演，什么都不改
      powershell -ExecutionPolicy Bypass -File .\PreGame.ps1 -Apply   真的整备
      powershell -ExecutionPolicy Bypass -File .\PreGame.ps1 -Revert  恢复上次停掉的程序
      powershell -ExecutionPolicy Bypass -File .\PreGame.ps1 -Apply -Watch   整备完一直守着，游戏退出自动恢复（无人值守）

    停哪些、恢复哪些，都写在 开游戏前整备\config.json 里，可以直接改。
#>
[CmdletBinding()]
param(
    [switch]$Apply,
    [switch]$Revert,
    [switch]$Watch,
    [switch]$NoPause,
    [string]$GameProcess = '',
    [string]$Launch = '',
    [int]$WaitMinutes = 300,
    [string]$StateDir
)

$ErrorActionPreference = 'Continue'
$Here = (Get-Location).Path
if ($PSScriptRoot) { $Here = $PSScriptRoot }
if (-not $StateDir) { $StateDir = Join-Path $Here '开游戏前整备' }
$ConfigPath = Join-Path $StateDir 'config.json'
$StatePath  = Join-Path $StateDir 'state.json'
$LogPath    = Join-Path $StateDir ('整备日志-{0}.txt' -f (Get-Date).ToString('yyyyMMdd-HHmm'))

function Write-Blank { Write-Host '' }
function Write-Title { param([string]$Text) Write-Host ''; Write-Host ('=' * 58) -ForegroundColor DarkCyan; Write-Host ('  ' + $Text) -ForegroundColor Cyan; Write-Host ('=' * 58) -ForegroundColor DarkCyan; Write-Host '' }
function Write-Step { param([string]$Text) Write-Host ('>> ' + $Text) -ForegroundColor Cyan }
function Write-Ok { param([string]$Text) Write-Host $Text -ForegroundColor Green }
function Write-Note { param([string]$Text) Write-Host $Text -ForegroundColor Gray }
function Write-Warn { param([string]$Text) Write-Host $Text -ForegroundColor Yellow }
function Write-Bad { param([string]$Text) Write-Host $Text -ForegroundColor Red }
function Write-Bullet { param([string]$Text) Write-Host ('  - ' + $Text) }

function Pause-Exit {
    if ($NoPause -or $Apply -or $Revert -or $Watch) { return }
    try { Read-Host '按回车关闭这个窗口' | Out-Null } catch { }
}

function To-GB { param($Bytes) if ($null -eq $Bytes) { return 0.0 } return [math]::Round([double]$Bytes / 1GB, 2) }

function Show-Num {
    param($Value, [int]$Digits = 1)
    if ($null -eq $Value) { return '--' }
    $fmt = '{0:F' + $Digits + '}'
    return ([string]::Format([cultureinfo]::InvariantCulture, $fmt, [double]$Value))
}

function Get-MemInfo {
    $total = 0.0
    $avail = $null
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $total = [math]::Round([double]$os.TotalVisibleMemorySize / 1MB, 2)
    } catch { }
    try {
        $m = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Memory -ErrorAction Stop
        $avail = [math]::Round([double]$m.AvailableMBytes / 1024, 2)
    } catch { }
    return New-Object psobject -Property @{ total = $total; avail = $avail }
}

function Get-PowerPlanName {
    $name = ''
    try {
        $out = (& powercfg /getactivescheme) 2>$null
        $s = [string]$out
        $m = [regex]::Match($s, '\(([^)]+)\)')
        if ($m.Success) { $name = $m.Groups[1].Value }
    } catch { }
    return $name
}

function Get-DefaultConfig {
    return [ordered]@{
        note = '要停的程序写在 sync / apps / overlay 三个列表里（写进程名，不要带 .exe，大小写无所谓）。restart 是游戏结束后帮你重新启动的程序，没写的不会自动回来，需要时自己打开。'
        sync = @('OneDrive', 'FileCoAuth', 'OneDrive.Sync.Service')
        apps = @('WeChat', 'WeChatAppEx')
        overlay = @('NVIDIA Overlay', 'nvngx_update')
        restart = @('OneDrive', 'WeChat', 'NVIDIA Overlay')
        never = @('explorer', 'dwm', 'csrss', 'winlogon', 'svchost', 'lsass', 'wininit', 'services', 'audiodg',
                  'system', 'idle', 'memory compression', 'registry', 'searchindexer', 'sihost', 'taskhostw',
                  'fontdrvhost', 'ctfmon', 'runtimebroker', 'shellexperiencehost', 'startmenuexperiencehost',
                  'textinputhost', 'applicationframehost', 'systemsettings', 'msmpeng', 'nissrv', 'mssense',
                  'securityhealthservice', 'securityhealthsystray', 'powershell', 'pwsh', 'conhost', 'cmd',
                  'windowsterminal', 'pregame', 'gameoptimize', 'steam', 'steamwebhelper')
        gameProcess = ''
        launch = ''
        watchMinutes = 300
    }
}

function Get-Config {
    $default = Get-DefaultConfig
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        return (New-Object psobject -Property $default)
    }
    try {
        $raw = Get-Content -Raw -LiteralPath $ConfigPath -Encoding UTF8
        $cfg = $raw | ConvertFrom-Json
    } catch {
        Write-Warn ('config.json 读不出来（{0}），这次用内置默认值。' -f $_.Exception.Message)
        return (New-Object psobject -Property $default)
    }
    $merged = [ordered]@{}
    foreach ($k in $default.Keys) {
        $v = $cfg.$k
        if ($null -eq $v) { $v = $default[$k] }
        $merged[$k] = $v
    }
    return (New-Object psobject -Property $merged)
}

function Save-Config {
    param($Cfg)
    if (-not (Test-Path -LiteralPath $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }
    $obj = [ordered]@{}
    foreach ($k in @('note', 'sync', 'apps', 'overlay', 'restart', 'never', 'gameProcess', 'launch', 'watchMinutes')) {
        $obj[$k] = $Cfg.$k
    }
    $json = $obj | ConvertTo-Json -Depth 5
    Save-Text -Path $ConfigPath -Text $json
}

function Save-Text {
    param([string]$Path, [string]$Text)
    $dir = [System.IO.Path]::GetDirectoryName($Path)
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($true)))
}

function Add-Log {
    param([string]$Text)
    $line = ('[{0}] {1}' -f (Get-Date).ToString('HH:mm:ss'), $Text)
    try { [System.IO.File]::AppendAllText($LogPath, $line + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($true))) } catch { }
}
function Get-TargetGroups {
    param($Cfg)
    $groups = New-Object System.Collections.Generic.List[object]
    $groups.Add((New-Object psobject -Property @{ key = 'sync';    label = '网盘同步';   names = @($Cfg.sync) })) | Out-Null
    $groups.Add((New-Object psobject -Property @{ key = 'apps';    label = '后台程序';   names = @($Cfg.apps) })) | Out-Null
    $groups.Add((New-Object psobject -Property @{ key = 'overlay'; label = '覆盖层/后台更新'; names = @($Cfg.overlay) })) | Out-Null
    return $groups
}

function Get-NameState {
    param([string]$Name, $NeverList)
    $key = $Name.ToLowerInvariant()
    if (@($NeverList) -contains $key) { return $null }
    $procs = @(Get-Process -Name $Name -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) { return $null }
    $mem = 0.0
    foreach ($pr in $procs) {
        try { $mem = $mem + [double]$pr.WorkingSet64 } catch { }
    }
    return New-Object psobject -Property @{
        name = $Name
        count = $procs.Count
        memMB = [math]::Round($mem / 1MB, 0)
        procs = $procs
    }
}

function Get-RunningTargets {
    param($Cfg, $Groups)
    $found = New-Object System.Collections.Generic.List[object]
    foreach ($g in @($Groups)) {
        foreach ($nm in @($g.names)) {
            if ([string]::IsNullOrWhiteSpace([string]$nm)) { continue }
            $st = Get-NameState -Name ([string]$nm).Trim() -NeverList $Cfg.never
            if ($st) { $st | Add-Member -NotePropertyName group -NotePropertyValue $g.label -Force; $found.Add($st) | Out-Null }
        }
    }
    return $found
}

function Show-TargetPlan {
    param($Cfg, $Groups, $Running)
    Write-Step '脚本准备做这几件事'
    foreach ($g in @($Groups)) {
        foreach ($nm in @($g.names)) {
            if ([string]::IsNullOrWhiteSpace([string]$nm)) { continue }
            $names = ([string]$nm).Trim()
            $hit = $null
            foreach ($r in @($Running)) { if ([string]$r.name -eq $names) { $hit = $r } }
            if ($hit) {
                $extra = ''
                if ($hit.count -gt 1) { $extra = ('，{0} 个进程' -f $hit.count) }
                Write-Host ('  [{0}] {1} 正在运行（内存 {2}MB{3}）' -f $g.label, $names, $hit.memMB, $extra) -ForegroundColor White
                Write-Note '        -> 整备时停掉'
            } else {
                Write-Note ('  [{0}] {1} 没在运行，跳过' -f $g.label, $names)
            }
        }
    }
}

function Close-TargetProc {
    param([System.Diagnostics.Process]$Proc, [int]$GraceSec = 5)
    $closed = $false
    try { $closed = $Proc.CloseMainWindow() } catch { $closed = $false }
    if ($closed) {
        try { $null = $Proc.WaitForExit($GraceSec * 1000) } catch { }
    }
    $alive = $true
    try { $alive = -not $Proc.HasExited } catch { $alive = $true }
    if ($alive) {
        try { Stop-Process -Id $Proc.Id -Force -ErrorAction Stop } catch { return $false }
    }
    for ($i = 0; $i -lt 12; $i++) {
        $still = Get-Process -Id $Proc.Id -ErrorAction SilentlyContinue
        if (-not $still) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Get-LaunchInfo {
    param([System.Diagnostics.Process]$Proc)
    $path = ''
    $cli = ''
    try { $path = [string]$Proc.Path } catch { $path = '' }
    if (-not $path) {
        try {
            $ci = Get-CimInstance -ClassName Win32_Process -Filter ('ProcessId = ' + [int]$Proc.Id) -ErrorAction Stop
            $path = [string]$ci.ExecutablePath
            $cli = [string]$ci.CommandLine
        } catch { }
    }
    return New-Object psobject -Property @{ path = $path; cli = $cli }
}

function Invoke-Prep {
    param($Running, [switch]$Preview)
    $stopped = New-Object System.Collections.Generic.List[object]
    foreach ($r in @($Running)) {
        foreach ($pr in @($r.procs)) {
            $info = Get-LaunchInfo -Proc $pr
            if ($Preview) { continue }
            $ok = Close-TargetProc -Proc $pr
            $rec = [ordered]@{
                name   = [string]$r.name
                pid    = [int]$pr.Id
                path   = [string]$info.path
                cli    = [string]$info.cli
                memMB  = 0
                closed = [bool]$ok
                time   = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            }
            try { $rec.memMB = [math]::Round([double]$pr.WorkingSet64 / 1MB, 0) } catch { }
            if ($rec.closed) {
                $stopped.Add($rec) | Out-Null
                Write-Ok ('  已停止 {0}（PID {1}，释放 {2}MB）' -f $rec.name, $rec.pid, $rec.memMB)
                Add-Log ('stopped {0} pid={1} mem={2}MB path={3}' -f $rec.name, $rec.pid, $rec.memMB, $rec.path)
            } else {
                Write-Warn ('  没能停掉 {0}（PID {1}），可能被别的程序保护着，跳过' -f $rec.name, $rec.pid)
                Add-Log ('FAILED to stop {0} pid={1}' -f $rec.name, $rec.pid)
            }
        }
    }
    return $stopped
}

function Save-State {
    param($Stopped, $Before, $After)
    $obj = [ordered]@{
        time        = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        machine     = [string]$env:COMPUTERNAME
        availBefore = $Before
        availAfter  = $After
        stopped     = @($Stopped)
    }
    Save-Text -Path $StatePath -Text ($obj | ConvertTo-Json -Depth 6)
}

function Get-SavedState {
    if (-not (Test-Path -LiteralPath $StatePath)) { return $null }
    try {
        $raw = Get-Content -Raw -LiteralPath $StatePath -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return ($raw | ConvertFrom-Json)
    } catch { return $null }
}

function Restore-App {
    param($Cfg, [switch]$Preview)
    $state = Get-SavedState
    if (-not $state) {
        Write-Note '还没有整备记录，没有需要恢复的东西。'
        return
    }
    $list = @($state.stopped)
    if ($list.Count -eq 0) {
        Write-Note ('上次整备（{0}）没有停过任何程序。' -f $state.time)
        return
    }
    Write-Step ('恢复上次整备停掉的程序（记录于 {0}）' -f $state.time)
    $restartList = @()
    foreach ($x in @($Cfg.restart)) { $restartList += ([string]$x).ToLowerInvariant() }
    foreach ($e in $list) {
        $nm = [string]$e.name
        $key = $nm.ToLowerInvariant()
        if ($restartList -notcontains $key) {
            Write-Note ('  {0}：清单里没写要自动恢复，需要时自己打开' -f $nm)
            continue
        }
        $alive = @(Get-Process -Name $nm -ErrorAction SilentlyContinue)
        if ($alive.Count -gt 0) {
            Write-Note ('  {0}：已经在运行了，不动它' -f $nm)
            continue
        }
        if ([string]::IsNullOrWhiteSpace([string]$e.path)) {
            Write-Warn ('  {0}：没记下程序路径，需要自己打开' -f $nm)
            continue
        }
        if (-not (Test-Path -LiteralPath ([string]$e.path))) {
            Write-Warn ('  {0}：原来的路径找不到了（{1}）' -f $nm, $e.path)
            continue
        }
        if ($Preview) {
            Write-Note ('  {0}：会重新启动 {1}' -f $nm, $e.path)
            continue
        }
        try {
            Start-Process -FilePath ([string]$e.path) -ErrorAction Stop | Out-Null
            Write-Ok ('  已重新启动 {0}' -f $nm)
            Add-Log ('restarted {0} path={1}' -f $nm, $e.path)
        } catch {
            Write-Warn ('  {0}：启动失败（{1}）' -f $nm, $_.Exception.Message)
            Add-Log ('FAILED to restart {0}: {1}' -f $nm, $_.Exception.Message)
        }
    }
}

function Show-MemoryCheck {
    param($Before, $After)
    Write-Step '内存体检'
    if ($null -eq $After.avail) {
        Write-Note '  读不到可用内存，跳过这项。'
        return
    }
    if ($null -ne $Before.avail -and $Before.avail -gt $After.avail) {
        Write-Note ('  整备前可用 {0}GB，现在 {1}GB' -f (Show-Num $Before.avail 2), (Show-Num $After.avail 2))
    } else {
        Write-Note ('  现在可用内存 {0}GB（这台机器一共 {1}GB）' -f (Show-Num $After.avail 2), (Show-Num $After.total 1))
    }
    if ($null -ne $Before.avail) {
        $freed = [math]::Round([double]$After.avail - [double]$Before.avail, 2)
        if ($freed -gt 0.05) { Write-Ok ('  这一轮腾出约 {0}GB' -f (Show-Num $freed 2)) }
    }
    $acc = @{}
    foreach ($pr in @(Get-Process -ErrorAction SilentlyContinue)) {
        $nm = [string]$pr.ProcessName
        $mb = 0.0
        try { $mb = [double]$pr.WorkingSet64 / 1MB } catch { $mb = 0.0 }
        if ($acc.ContainsKey($nm)) { $acc[$nm] = [double]$acc[$nm] + $mb } else { $acc[$nm] = $mb }
    }
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($k in $acc.Keys) { $list.Add((New-Object psobject -Property @{ name = $k; mb = [math]::Round([double]$acc[$k], 0) })) | Out-Null }
    $top = @($list | Sort-Object -Property @{ Expression = { [double]$_.mb }; Descending = $true } | Select-Object -First 10)
    if ([double]$After.avail -lt 1.5) {
        Write-Warn ('  可用内存只剩 {0}GB，实测低于 1GB 就会开始卡（系统会不停把内存换到硬盘）。' -f (Show-Num $After.avail 2))
        Write-Note '  现在最占内存的是这几个，能关就关掉：'
    } else {
        Write-Note '  现在最占内存的：'
    }
    foreach ($pr in $top) {
        $tag = ''
        if ([string]$pr.name.ToLowerInvariant() -eq 'memory compression') { $tag = '  <- 内存压缩进程，它越大说明内存越紧张' }
        Write-Host ('    {0,-32} {1,7}MB{2}' -f $pr.name, $pr.mb, $tag)
    }
    if ([double]$After.total -le 17 -and [double]$After.avail -lt 2.5) {
        Write-BLANK
        Write-Warn ('  这台机器一共 {0}GB 内存。实测那一把三角洲，游戏自己就吃掉 5.3GB，加上系统和其他程序很容易用光。' -f (Show-Num $After.total 0))
        Write-Note '  游戏时把上面几个占内存的程序关掉能缓解；如果经常不够用，加内存是这台机器最划算的升级。'
    }
}
function Get-NameFromGpuName {
    param([string]$Name)
    $m = [regex]::Match($Name, 'pid_(\d+)_')
    if ($m.Success) { return [int]$m.Groups[1].Value }
    return 0
}

function Get-GameHint {
    # 靠显卡 3D 占用猜哪个是游戏（和记录模式同一套思路）
    $bestPid = 0
    $bestVal = 0.0
    try {
        $rows = @(Get-CimInstance -ClassName Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine -ErrorAction Stop)
        $byPid = @{}
        foreach ($r in $rows) {
            if ([string]$r.Name -notmatch 'engtype_3d') { continue }
            $u = [double]$r.UtilizationPercentage
            if ($u -le 0) { continue }
            $pid2 = Get-NameFromGpuName -Name ([string]$r.Name)
            if ($pid2 -le 0) { continue }
            $prev = 0.0
            if ($byPid.ContainsKey($pid2)) { $prev = [double]$byPid[$pid2] }
            $byPid[$pid2] = $prev + $u
        }
        foreach ($k in $byPid.Keys) {
            if ([double]$byPid[$k] -gt $bestVal) { $bestVal = [double]$byPid[$k]; $bestPid = [int]$k }
        }
        if ($bestPid -gt 0 -and $bestVal -ge 20) {
            $p = Get-Process -Id $bestPid -ErrorAction SilentlyContinue
            if ($p) {
                $nm = ([string]$p.ProcessName).ToLowerInvariant()
                $skip = @('dwm', 'explorer', 'csrss', 'svchost', 'powershell', 'pwsh', 'conhost', 'windowsterminal')
                if ($skip -notcontains $nm) {
                    return New-Object psobject -Property @{ name = [string]$p.ProcessName; gpu = [math]::Round($bestVal, 1) }
                }
            }
        }
    } catch { }
    return $null
}

function Wait-Game {
    param([string]$Wanted, [int]$Minutes)
    $name = $Wanted
    if ($name) {
        Write-Step ('等你启动 {0}（最多等 15 分钟；卡住了按 Ctrl+C，停掉的程序会立刻恢复）' -f $name)
        $waitUntil = (Get-Date).AddMinutes(15)
        while ((Get-Date) -lt $waitUntil) {
            if (@(Get-Process -Name $name -ErrorAction SilentlyContinue).Count -gt 0) { break }
            Start-Sleep -Seconds 5
        }
        if (@(Get-Process -Name $name -ErrorAction SilentlyContinue).Count -eq 0) {
            Write-Warn ('等了 15 分钟也没看到 {0} 启动，就不守了。' -f $name)
            return $false
        }
    } else {
        Write-Step '没指定游戏进程，我盯着显卡占用来认（最多 15 分钟）'
        $waitUntil = (Get-Date).AddMinutes(15)
        $hint = $null
        while ((Get-Date) -lt $waitUntil) {
            $hint = Get-GameHint
            if ($hint) { break }
            Start-Sleep -Seconds 5
        }
        if (-not $hint) {
            Write-Warn '没认出来在跑什么游戏，就不守了。'
            return $false
        }
        $name = [string]$hint.name
        Write-Ok ('  认出来了：{0}（显卡 3D 占用 {1}%）' -f $name, $hint.gpu)
    }
    Write-Ok ('  已经在跑：{0}。游戏一退出我就恢复。' -f $name)
    $start = Get-Date
    $deadline = $start.AddMinutes($Minutes)
    $gone = 0
    $lastPrint = $start
    while ((Get-Date) -lt $deadline) {
        if (@(Get-Process -Name $name -ErrorAction SilentlyContinue).Count -gt 0) { $gone = 0 } else { $gone = $gone + 1 }
        if ($gone -ge 3) {
            Write-Note ('  {0} 已经退出了。' -f $name)
            return $true
        }
        if (((Get-Date) - $lastPrint).TotalSeconds -ge 60) {
            $mi = Get-MemInfo
            Write-Note ('  [{0}] 还在玩，已经 {1} 分钟，现在可用内存 {2}GB' -f (Get-Date).ToString('HH:mm'), [int]((Get-Date) - $start).TotalMinutes, (Show-Num $mi.avail 2))
            $lastPrint = Get-Date
        }
        Start-Sleep -Seconds 10
    }
    Write-Warn ('守护超过 {0} 分钟，先收工。' -f $Minutes)
    return $true
}

function Ask-Launch {
    param([string]$Path, [switch]$Silent)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Warn ('配置里记的启动路径找不到了：{0}' -f $Path)
        return
    }
    $ans = ''
    if (-not $Silent) { $ans = [string](Read-Host ('要现在就启动它吗？回车=启动，输入 n=自己启动（{0}）' -f (Split-Path -Leaf $Path))) }
    if ($Silent -or ($ans -ne 'n' -and $ans -ne 'N')) {
        try {
            Start-Process -FilePath $Path | Out-Null
            Write-Ok ('  已经帮你启动：{0}' -f (Split-Path -Leaf $Path))
            Add-Log ('launched ' + $Path)
        } catch {
            Write-Warn ('  启动失败（{0}），自己双击吧。' -f $_.Exception.Message)
        }
    }
}

# ===========================================================================
# 主流程
# ===========================================================================
Write-Title '开游戏前整备'

$cfg = Get-Config
$firstRun = $false
if (-not (Test-Path -LiteralPath $ConfigPath)) {
    $firstRun = $true
    Save-Config -Cfg $cfg
}
$groups = Get-TargetGroups -Cfg $cfg
if ($firstRun) {
    Write-Note ('  第一次运行，要停哪些程序已经写在 {0}，可以直接改。' -f $ConfigPath)
    Write-Note '  想加别的程序就加在 apps 那一行；停掉后要自动开回来的写在 restart 那一行。'
}

if ($Revert) {
    Add-Log 'mode=revert'
    Restore-App -Cfg $cfg
    Write-Blank
    Write-Note ('日志：{0}' -f $LogPath)
    Pause-Exit
    return
}

if (-not $PSBoundParameters.ContainsKey('WaitMinutes')) {
    $cfgNum = 0
    if ([int]::TryParse(([string]$cfg.watchMinutes), [ref]$cfgNum) -and $cfgNum -gt 0) { $WaitMinutes = $cfgNum }
}

$mem = Get-MemInfo
$planName = Get-PowerPlanName
Write-Note ('  时间 {0}    可用内存 {1}GB / 共 {2}GB' -f (Get-Date).ToString('HH:mm'), (Show-Num $mem.avail 2), (Show-Num $mem.total 1))
if ($planName) {
    if ($planName -match '节能|省电|power saver') {
        Write-Warn ('  电源计划：{0} —— 这个档位会压 CPU 频率，打游戏前建议换成"高性能"（控制面板 -> 电源选项）' -f $planName)
    } else {
        Write-Note ('  电源计划：{0}' -f $planName)
    }
}

$running = Get-RunningTargets -Cfg $cfg -Groups $groups
Write-Blank
if ($running.Count -eq 0) {
    Write-Note '  清单里的程序一个都没在跑，没什么要收拾的。'
} else {
    Show-TargetPlan -Cfg $cfg -Groups $groups -Running $running
    $sumMB = 0.0
    foreach ($r in @($running)) { $sumMB = $sumMB + [double]$r.memMB }
    Write-Blank
    Write-Note ('  这几样加起来占着 {0}MB 内存。' -f [math]::Round($sumMB, 0))
}

if (-not $Apply -and -not $Watch) {
    Write-Blank
    Write-Host '  [回车] 开始整备并守护（游戏退出后自动恢复）' -ForegroundColor White
    Write-Host '  [1]    只看不改，现在就退出（预演）' -ForegroundColor White
    Write-Host '  [2]    恢复上次整备停掉的程序' -ForegroundColor White
    Write-Host '  [q]    退出' -ForegroundColor White
    Write-Blank
    $ans = ''
    try { $ans = [string](Read-Host '  选一个') } catch { $ans = '1' }
    $ans = $ans.Trim()
    if ($ans -eq 'q' -or $ans -eq 'Q') { Write-Note '什么都没改，退出。'; Pause-Exit; return }
    if ($ans -eq '1') { Write-Ok '预演结束：上面就是它准备做的事，没有任何改动。'; Pause-Exit; return }
    if ($ans -eq '2') { Restore-App -Cfg $cfg; Write-Blank; Pause-Exit; return }
}

# ---- 真的来 ----
$before = Get-MemInfo
Write-Blank
Write-Step '开始整备'
$stopped = Invoke-Prep -Running $running
if ($stopped.Count -eq 0) { Write-Note '  没有停掉任何程序（可能本来就没在跑）。' }
Start-Sleep -Seconds 2
$after = Get-MemInfo
Write-Blank
Show-MemoryCheck -Before $before -After $after
Save-State -Stopped $stopped -Before $before.avail -After $after.avail

if ($stopped.Count -eq 0) { Write-Blank; Pause-Exit; return }

# ---- 启动游戏 + 守护 ----
$gp = [string]$GameProcess
if (-not $gp) { $gp = [string]$cfg.gameProcess }
$lp = [string]$Launch
if (-not $lp) { $lp = [string]$cfg.launch }

$doWatch = $true
if (-not $Watch) {
Write-Blank
Write-Step '要不要守着？（游戏一退出，我把刚才停掉的恢复回来）'
if ($gp) { Write-Note ('  直接回车 = 守着 {0}' -f $gp) } else { Write-Note '  直接回车 = 我靠显卡占用自动认（可能认错，建议填进程名）' }
Write-Note '  输入别的进程名 = 换成它；输入 n = 不守护（那停掉的程序就得自己手动开回来）'
Write-Note '  不确定进程名就填 exe 的名字，例如 DeltaForceClient-Win64-Shipping'
$gpAns = ''
try { $gpAns = [string](Read-Host '  游戏进程') } catch { $gpAns = 'n' }
$gpAns = $gpAns.Trim()
if ($gpAns -eq 'n' -or $gpAns -eq 'N') { $doWatch = $false } elseif ($gpAns -ne '') { $gp = $gpAns }
}

if ($doWatch) {
    try {
        Ask-Launch -Path $lp -Silent:$Watch
        $null = Wait-Game -Wanted $gp -Minutes $WaitMinutes
    } finally {
        Write-Blank
        Write-Step '收工，把停掉的程序恢复回来'
        Restore-App -Cfg $cfg
    }
} else {
    Write-Blank
    Write-Warn '好的，不守护。停掉的程序不会自动回来：'
    $seen = @{}
    foreach ($e in @($stopped)) {
        $k = ([string]$e.name).ToLowerInvariant()
        if ($seen.ContainsKey($k)) { continue }
        $seen[$k] = $true
        Write-Note ('  {0}（{1}）' -f $e.name, $e.path)
    }
    Write-Note '  想要它们回来，再双击 4-开游戏前整备.bat 选 [2]。'
}

Write-Blank
Write-Note ('整备日志：{0}' -f $LogPath)
Write-Note '想更准确的话，进游戏之前先跑一次 2-边玩边记录.bat，把过程记下来。'
Add-Log 'done'
Pause-Exit