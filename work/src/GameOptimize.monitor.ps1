
# ---------------------------------------------------------------------------
# 边玩边记录：真的打一把游戏，每秒只读采样一次，再按实测数据下结论
#   只读采样，不修改任何设置、不碰游戏文件、不联网上传
# ---------------------------------------------------------------------------

function Resolve-PowerPlanLabel {
    param([string]$Name, [string]$Guid)
    $g = ''
    if ($Guid) { $g = $Guid.ToLowerInvariant() }
    $n = ''
    if ($Name) { $n = $Name }
    if ($g -eq '381b4222-f694-41f0-9685-ff5bb260df2e') { return '平衡' }
    if ($g -eq '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c') { return '高性能' }
    if ($g -eq 'e9a42b02-d5df-448d-aa00-03f14749eb61') { return '卓越性能' }
    if ($g -eq 'a1841308-3541-4fab-bc81-f71556f20b4a') { return '节能' }
    if ($n -match '性能|野兽|狂暴|超能|疾速|Turbo|Performance|Ultimate') { return '高性能' }
    if ($n -match '节能|省电|环保|Saver|Eco') { return '节能' }
    if ($n -match '平衡|安静|静音|标准|Balanced|Quiet|Silent|Cool') { return '平衡' }
    if ($n) { return $n }
    return '未知'
}

function Get-MonitorContext {
    # 轻量采集：只取判定瓶颈和挑优化项需要的机器信息（几秒内完成）
    $ctx = [ordered]@{
        generatedAt    = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        computerName   = $env:COMPUTERNAME
        isAdmin        = (Test-IsAdmin)
        isLaptop       = $false
        onAc           = $null
        batteryPct     = $null
        cpuName        = ''
        cores          = 0
        threads        = 0
        totalRamGB     = 0
        freeRamGB      = 0
        gpus           = @()
        primaryGpu     = ''
        primaryVramGB  = 0
        osCaption      = ''
        osBuild        = ''
        powerPlanName  = ''
        powerPlanGuid  = ''
        powerPlanLabel = ''
        procMaxPct     = $null
        hags           = $null
        gameMode       = $null
        gameDvr        = $null
        vbs            = $null
        readIssues     = @()
    }

    try {
        $c = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $ctx.totalRamGB = [math]::Round([double]$c.TotalPhysicalMemory / 1GB, 1)
        $ctx.threads = [int]$c.NumberOfLogicalProcessors
        if ($($c.SystemType) -eq '2') { $ctx.isLaptop = $true }
    } catch { $ctx.readIssues += 'computer' }

    try {
        $o = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $ctx.osCaption = $($o.Caption)
        $ctx.osBuild = $($o.BuildNumber)
        $ctx.freeRamGB = [math]::Round([double]$o.FreePhysicalMemory / 1MB, 2)
    } catch { $ctx.readIssues += 'os' }

    try {
        $p = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
        $ctx.cpuName = $($p.Name).Trim()
        $ctx.cores = [int]$p.NumberOfCores
        if (-not $ctx.threads) { $ctx.threads = [int]$p.NumberOfLogicalProcessors }
    } catch { $ctx.readIssues += 'cpu' }

    try {
        $b = @(Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)
        $bat = $b | Where-Object { $null -ne $_.BatteryStatus } | Select-Object -First 1
        if ($bat) {
            $ctx.isLaptop = $true
            $ctx.batteryPct = $bat.EstimatedChargeRemaining
            $ctx.onAc = ($bat.BatteryStatus -eq 2 -or $bat.BatteryStatus -eq 6 -or $bat.BatteryStatus -eq 7 -or $bat.BatteryStatus -eq 8)
        }
    } catch { $ctx.readIssues += 'battery' }

    try {
        $vram = @()
        $base = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
        Get-ChildItem -Path $base -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -match '^\d{4}$' } |
            ForEach-Object {
                $q = Get-RegInfo -Path $_.PSPath -Name 'HardwareInformation.qwMemorySize'
                if ($q -and $q.value) { $vram += [double]$q.value }
            }
        $i = 0
        $list = New-Object 'System.Collections.Generic.List[object]'
        foreach ($v in @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue)) {
            $bytes = 0
            if ($i -lt $vram.Count) { $bytes = $vram[$i] }
            elseif ($v.AdapterRAM -and $v.AdapterRAM -gt 0) { $bytes = [double]$v.AdapterRAM }
            $gb = 0
            if ($bytes -gt 0) { $gb = [math]::Round($bytes / 1GB, 1) }
            $list.Add([ordered]@{ name = $($v.Name); vramGB = $gb; driver = $($v.DriverVersion) }) | Out-Null
            $i++
        }
        $ctx.gpus = $list.ToArray()
        $best = $null
        foreach ($g in $list) {
            if (-not $best) { $best = $g }
            elseif ([double]$g.vramGB -gt [double]$best.vramGB) { $best = $g }
        }
        if ($best) {
            $ctx.primaryGpu = $($best.name)
            $ctx.primaryVramGB = [double]$best.vramGB
        }
    } catch { $ctx.readIssues += 'gpus' }

    try {
        $out = @(powercfg /getactivescheme)
        if ($out.Count -gt 0) {
            $line = $($out[0])
            if ($line -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
                $ctx.powerPlanGuid = $Matches[1].ToLowerInvariant()
            }
            if ($line -match '\(([^)]+)\)') { $ctx.powerPlanName = $Matches[1].Trim() }
        }
    } catch { $ctx.readIssues += 'powercfg' }
    $ctx.powerPlanLabel = Resolve-PowerPlanLabel -Name $ctx.powerPlanName -Guid $ctx.powerPlanGuid
    if ($ctx.powerPlanGuid) {
        $key = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes\' + $ctx.powerPlanGuid +
               '\54533251-82be-4824-96c1-47b60b740d00\bc5038f7-23e0-4960-96da-33abaf5935ec'
        $v = Get-RegValue -Path $key -Name 'ACSettingIndex'
        if ($null -ne $v) { $ctx.procMaxPct = [int]$v }
    }

    try {
        $v = Get-RegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name 'HwSchMode'
        if ($null -ne $v) { $ctx.hags = ([int]$v -eq 2) } else { $ctx.hags = $false }
    } catch { }
    try {
        $v = Get-RegValue -Path 'HKCU:\Software\Microsoft\GameBar' -Name 'AutoGameModeEnabled'
        if ($null -ne $v) { $ctx.gameMode = ([int]$v -eq 1) }
    } catch { }
    try {
        $v = Get-RegValue -Path 'HKCU:\System\GameConfigStore' -Name 'GameDVR_Enabled'
        if ($null -ne $v) { $ctx.gameDvr = ([int]$v -eq 1) }
    } catch { }
    try {
        $v = Get-RegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' -Name 'Enabled'
        if ($null -ne $v) { $ctx.vbs = ([int]$v -eq 1) }
    } catch { }

    return $ctx
}

function Test-MonitorAbility {
    # 探测这台机器能读到哪些数据；读不到的项在报告里会写清楚，不会假装有数据
    param($Session)
    $cap = [ordered]@{ memory = $false; disk = $false; net = $false; gpu = $false; gpuMem = $false; procIo = $false }
    if (-not $Session) { return $cap }
    try { $null = Get-CimInstance -CimSession $Session -ClassName Win32_PerfFormattedData_PerfOS_Memory -ErrorAction Stop; $cap.memory = $true } catch { }
    try { $d = @(Get-CimInstance -CimSession $Session -ClassName Win32_PerfFormattedData_PerfDisk_PhysicalDisk -ErrorAction Stop); if ($d.Count -gt 0) { $cap.disk = $true } } catch { }
    try { $n = @(Get-CimInstance -CimSession $Session -ClassName Win32_PerfFormattedData_Tcpip_NetworkInterface -ErrorAction Stop); if ($n.Count -gt 0) { $cap.net = $true } } catch { }
    try { $g = @(Get-CimInstance -CimSession $Session -ClassName Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine -ErrorAction Stop); if ($g.Count -gt 0) { $cap.gpu = $true } } catch { }
    try { $g = @(Get-CimInstance -CimSession $Session -ClassName Win32_PerfFormattedData_GPUPerformanceCounters_GPUAdapterMemory -ErrorAction Stop); if ($g.Count -gt 0) { $cap.gpuMem = $true } } catch { }
    try { $p = @(Get-CimInstance -CimSession $Session -ClassName Win32_PerfFormattedData_PerfProc_Process -ErrorAction Stop); if ($p.Count -gt 0) { $cap.procIo = $true } } catch { }
    return $cap
}

function Get-PidFromGpuName {
    param([string]$Name)
    if (-not $Name) { return 0 }
    if ($Name -match '^pid_(\d+)_') { return [int]$Matches[1] }
    return 0
}

function Add-MonitorSystemMetrics {
    # 内存 / 磁盘（读一次约半秒，所以每几秒才读一次）
    param($Session, $Cap, $Sample)
    if ($Cap.memory) {
        try {
            $m = Get-CimInstance -CimSession $Session -ClassName Win32_PerfFormattedData_PerfOS_Memory -ErrorAction Stop
            $Sample.avail = [math]::Round([double]$m.AvailableMBytes / 1024, 2)
            $Sample.cmt = [double]$m.PercentCommittedBytesInUse
            $Sample.pgf = [double]$m.PagesPerSec
        } catch { }
    }
    if ($Cap.disk) {
        $d = $null
        try {
            $rows = @(Get-CimInstance -CimSession $Session -ClassName Win32_PerfFormattedData_PerfDisk_PhysicalDisk -ErrorAction Stop)
            foreach ($r in $rows) {
                if ([string]$r.Name -eq '_Total') { $d = $r }
            }
        } catch { $d = $null }
        if ($d) {
            $pct = [double]$d.PercentDiskTime
            if ($pct -gt 100) { $pct = 100 }
            $Sample.disk = [math]::Round($pct, 1)
            $Sample.dq = [math]::Round([double]$d.AvgDiskQueueLength, 2)
            $Sample.dmb = [math]::Round([double]$d.DiskBytesPersec / 1MB, 2)
        }
    }
}

function Add-MonitorGpuMetrics {
    # 显卡 3D 引擎占用 / 显存占用（整机和游戏进程分开算）
    param($Session, $Cap, $Sample, $State)
    if ($Cap.gpu) {
        try {
            $rows = @(Get-CimInstance -CimSession $Session -ClassName Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine -ErrorAction Stop)
            $total = 0.0
            $game = 0.0
            $peak = 0.0
            foreach ($r in $rows) {
                if ($($r.Name) -notmatch 'engtype_3d') { continue }
                $u = [double]$r.UtilizationPercentage
                if ($u -lt 0) { continue }
                $total = $total + $u
                if ($u -gt $peak) { $peak = $u }
                $pid2 = Get-PidFromGpuName -Name $($r.Name)
                if ($pid2 -gt 0 -and $State.gamePids -contains $pid2) { $game = $game + $u }
            }
            if ($total -gt 100) { $total = 100 }
            if ($game -gt 100) { $game = 100 }
            $Sample.gpu = [math]::Round($total, 1)
            $Sample.ggpu = [math]::Round($game, 1)
            $Sample.gpk = [math]::Round($peak, 1)
        } catch { }
    }
    if ($Cap.gpuMem) {
        try {
            $rows = @(Get-CimInstance -CimSession $Session -ClassName Win32_PerfFormattedData_GPUPerformanceCounters_GPUAdapterMemory -ErrorAction Stop)
            $sum = 0.0
            foreach ($r in $rows) { $sum = $sum + [double]$r.DedicatedUsage }
            $Sample.vram = [math]::Round($sum / 1GB, 2)
        } catch { }
        try {
            $rows = @(Get-CimInstance -CimSession $Session -ClassName Win32_PerfFormattedData_GPUPerformanceCounters_GPUProcessMemory -ErrorAction Stop)
            $sum = 0.0
            foreach ($r in $rows) {
                $pid2 = Get-PidFromGpuName -Name $($r.Name)
                if ($pid2 -gt 0 -and $State.gamePids -contains $pid2) { $sum = $sum + [double]$r.DedicatedUsage }
            }
            $Sample.gvram = [math]::Round($sum / 1GB, 2)
        } catch { }
    }
}

function Add-MonitorIoMetrics {
    # 网络吞吐 + 每个进程的磁盘/设备 IO（用来找后台下载、杀毒扫描这类真正拖后腿的家伙）
    param($Session, $Cap, $Sample, $State)
    if ($Cap.net) {
        try {
            $rows = @(Get-CimInstance -CimSession $Session -ClassName Win32_PerfFormattedData_Tcpip_NetworkInterface -ErrorAction Stop)
            $sum = 0.0
            foreach ($r in $rows) { $sum = $sum + [double]$r.BytesTotalPersec }
            $Sample.net = [math]::Round($sum / 1MB, 2)
        } catch { }
    }
    if ($Cap.procIo) {
        try {
            $rows = @(Get-CimInstance -CimSession $Session -ClassName Win32_PerfFormattedData_PerfProc_Process -ErrorAction Stop)
            $list = New-Object 'System.Collections.Generic.List[object]'
            foreach ($r in $rows) {
                $io = [double]$r.IOReadBytesPersec + [double]$r.IOWriteBytesPersec
                if ($io -lt 262144) { continue }
                $pid2 = [int]$r.IDProcess
                $nm = $($r.Name)
                if ($nm -eq '_Total' -or $nm -eq 'Idle') { continue }
                $list.Add([ordered]@{ n = $nm; pid = $pid2; ioMB = [math]::Round($io / 1MB, 2) }) | Out-Null
                $key = $nm.ToLowerInvariant()
                $prev = 0.0
                if ($State.procIo.ContainsKey($key)) { $prev = [double]$State.procIo[$key] }
                $State.procIo[$key] = $prev + $io
            }
            if ($list.Count -gt 0) {
                $sorted = @($list | Sort-Object -Property @{ Expression = { [double]$_.ioMB } } -Descending)
                $Sample.io = @($sorted | Select-Object -First 5)
            }
        } catch { }
    }
}

function Get-MonitorTick {
    # 一个采样点：进程快照每次都做（便宜），内存/显卡/磁盘/网络按节奏轮着做
    param($Session, $Cap, $State, $T0, [int]$Index)

    $now = Get-Date
    $dt = 0.0
    if ($State.lastTime) { $dt = ($now - $State.lastTime).TotalSeconds }
    $State.lastTime = $now
    $threads = [int]$State.threads
    if ($threads -lt 1) { $threads = 1 }

    $s = [ordered]@{
        t = [math]::Round(($now - $T0).TotalSeconds, 1)
        clk = $now.ToString('HH:mm:ss')
        cpu = 0.0
        game = 0.0
        core = 0.0
        gmem = 0.0
        procs = 0
        avail = $null
        cmt = $null
        pgf = $null
        disk = $null
        dq = $null
        dmb = $null
        gpu = $null
        ggpu = $null
        gpk = $null
        vram = $null
        gvram = $null
        net = $null
        top = $null
        io = $null
        note = $null
    }

    # ---- 进程快照：整机 CPU、游戏进程、后台占用排行都从这里来 ----
    $cur = @{}
    $grp = @{}
    $totalDelta = 0.0
    $gameDelta = 0.0
    $gameMem = 0.0
    $procCount = 0
    foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
        $procCount++
        $sec = -1.0
        try { $sec = $p.TotalProcessorTime.TotalSeconds } catch { $sec = -1.0 }
        $ws = 0.0
        try { $ws = [double]$p.WorkingSet64 } catch { $ws = 0.0 }
        $nm = $($p.ProcessName)
        $rec = [ordered]@{ name = $nm; pid = $p.Id; sec = $sec; ws = $ws; delta = 0.0; pct = 0.0 }
        $pkey = [string]$p.Id
        $cur[$pkey] = $rec

        $pv = $null
        if ($State.prevProc.ContainsKey($pkey)) { $pv = $State.prevProc[$pkey] }
        if ($pv -and $sec -ge 0 -and [double]$pv.sec -ge 0 -and $dt -gt 0.05) {
            $d = $sec - [double]$pv.sec
            if ($d -ge 0 -and $d -le ($dt * $threads + 1.0)) { $rec.delta = $d }
        }
        if ($dt -gt 0.05) { $rec.pct = [math]::Round($rec.delta / ($dt * $threads) * 100.0, 2) }
        $totalDelta = $totalDelta + $rec.delta

        $isGame = $false
        if ($State.gameNames -contains $nm.ToLowerInvariant()) { $isGame = $true }
        if ($State.gamePids -contains [int]$p.Id) { $isGame = $true }
        if ($isGame) {
            $gameDelta = $gameDelta + $rec.delta
            $gameMem = $gameMem + $ws
        }

        $key = $nm.ToLowerInvariant()
        $g = $null
        if ($grp.ContainsKey($key)) { $g = $grp[$key] } else { $g = [ordered]@{ n = $nm; c = 0; pct = 0.0; mb = 0.0 }; $grp[$key] = $g }
        $g.c = $g.c + 1
        $g.pct = $g.pct + [double]$rec.pct
        $g.mb = $g.mb + [math]::Round($ws / 1MB, 1)
    }
    $State.prevProc = $cur
    $s.procs = $procCount
    if ($dt -gt 0.05) {
        $s.cpu = [math]::Round($totalDelta / ($dt * $threads) * 100.0, 1)
        $s.game = [math]::Round($gameDelta / ($dt * $threads) * 100.0, 1)
        $s.core = [math]::Round($s.game * $threads, 0)
    }
    $s.gmem = [math]::Round($gameMem / 1GB, 2)

    # ---- 会话级累计：谁在这段时间里一直在吃资源 ----
    foreach ($key in $grp.Keys) {
        $g = $grp[$key]
        $acc = $null
        if ($State.procCpu.ContainsKey($key)) { $acc = $State.procCpu[$key] }
        else { $acc = [ordered]@{ n = $g.n; sum = 0.0; max = 0.0; mem = 0.0; samples = 0 }; $State.procCpu[$key] = $acc }
        $acc.sum = $acc.sum + [double]$g.pct
        if ([double]$g.pct -gt [double]$acc.max) { $acc.max = [double]$g.pct }
        if ([double]$g.mb -gt [double]$acc.mem) { $acc.mem = [double]$g.mb }
        $acc.samples = $acc.samples + 1
    }

    if (($Index % 5) -eq 0) {
        $rows = New-Object 'System.Collections.Generic.List[object]'
        foreach ($key in $grp.Keys) {
            $g = $grp[$key]
            if ($State.gameNames -contains $key) { continue }
            if ($State.selfNames -contains $key) { continue }
            $rows.Add([ordered]@{ n = $g.n; c = [int]$g.c; pct = [math]::Round([double]$g.pct, 1); mb = [math]::Round([double]$g.mb, 0) }) | Out-Null
        }
        $sorted = @($rows | Sort-Object -Property @{ Expression = { [double]$_.pct } } -Descending)
        if ($sorted.Count -gt 0) { $s.top = @($sorted | Select-Object -First 8) }
    }

    # ---- 显卡 / 内存 / 磁盘 / 网络 ----
    if (($Index % 3) -eq 0) { Add-MonitorSystemMetrics -Session $Session -Cap $Cap -Sample $s }
    if ((($Index + 1) % 3) -eq 0) { Add-MonitorGpuMetrics -Session $Session -Cap $Cap -Sample $s -State $State }
    if (($Index % 5) -eq 0) { Add-MonitorIoMetrics -Session $Session -Cap $Cap -Sample $s -State $State }

    # 显卡/内存/磁盘/网络不是每轮都采样，这里把最近一次读到的值补上，
    # 让每个采样点都有完整画面，报告里就不会整片显示 --
    foreach ($mk in @('avail', 'cmt', 'pgf', 'disk', 'dq', 'dmb', 'gpu', 'ggpu', 'gpk', 'vram', 'gvram', 'net')) {
        if ($null -eq $s[$mk]) {
            if ($State.lastMetrics.ContainsKey($mk)) { $s[$mk] = $State.lastMetrics[$mk] }
        } else {
            $State.lastMetrics[$mk] = $s[$mk]
        }
    }

    return $s
}

function Format-Duration {
    param([double]$Seconds)
    $s = [int][math]::Round($Seconds, 0)
    $m = [int][math]::Floor($s / 60)
    $r = $s - ($m * 60)
    return ('{0}:{1:00}' -f $m, $r)
}

function Show-Num {
    param($Value, [int]$Digits = 1)
    if ($null -eq $Value) { return '--' }
    $fmt = '{0:F' + $Digits + '}'
    return ([string]::Format([cultureinfo]::InvariantCulture, $fmt, [double]$Value))
}

function Get-RunningGameHint {
    # 用一次显卡采样猜一下现在正在跑的游戏是哪个进程，省得用户自己填
    $hint = $null
    try {
        $rows = @(Get-CimInstance -ClassName Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine -ErrorAction Stop)
        $byPid = @{}
        foreach ($r in $rows) {
            if ($($r.Name) -notmatch 'engtype_3d') { continue }
            $u = [double]$r.UtilizationPercentage
            if ($u -le 0) { continue }
            $pid2 = Get-PidFromGpuName -Name ([string]$r.Name)
            if ($pid2 -le 0) { continue }
            $prev = 0.0
            if ($byPid.ContainsKey($pid2)) { $prev = [double]$byPid[$pid2] }
            $byPid[$pid2] = $prev + $u
        }
        $bestPid = 0
        $bestVal = 0.0
        foreach ($k in $byPid.Keys) {
            if ([double]$byPid[$k] -gt $bestVal) { $bestVal = [double]$byPid[$k]; $bestPid = [int]$k }
        }
        if ($bestPid -gt 0 -and $bestVal -ge 8) {
            $p = Get-Process -Id $bestPid -ErrorAction SilentlyContinue
            $skipNames = @('dwm', 'explorer', 'csrss', 'winlogon', 'svchost', 'runtimebroker', 'searchapp', 'searchhost')
            $skipNames += @('shellexperiencehost', 'startmenuexperiencehost', 'textinputhost', 'applicationframehost', 'systemsettings')
            $skipNames += @('chrome', 'msedge', 'firefox', 'opera', 'powershell', 'pwsh', 'windowsterminal', 'code', 'conhost')
            $pname = ''
            if ($p) { $pname = ([string]$p.ProcessName).ToLowerInvariant() }
            if ($p -and ($skipNames -notcontains $pname)) {
                $hint = [ordered]@{ pid = $bestPid; name = ([string]$p.ProcessName); gpu = [math]::Round($bestVal, 1); path = '' }
                try { if ($p.Path) { $hint.path = ([string]$p.Path) } } catch { }
            }
        }
    } catch { }
    return $hint
}

function Invoke-MonitorRun {
    # 真正的记录循环：等游戏起来 -> 每秒采样 -> 游戏退出或时间到自动收尾
    param(
        $Ctx,
        [string]$GameName,
        [string]$ProcName,
        [string]$ExePath,
        [string]$GameFolder,
        [int]$Seconds,
        [string]$RawPath,
        [bool]$LaunchGame
    )

    $result = [ordered]@{
        startedAt     = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        gameName      = $GameName
        procName      = $ProcName
        exePath       = $ExePath
        targetSeconds = $Seconds
        gameDetected  = $false
        stopReason    = ''
        durationSec   = 0
        intervalMs    = 2000
        selfCpuPct    = 0
        marks         = @()
        capability    = $null
        samples       = @()
        gamePids      = @()
        procStats     = $null
        ioStats       = $null
    }

    $sessionCim = $null
    try { $sessionCim = New-CimSession -ErrorAction Stop } catch { $sessionCim = $null }
    if (-not $sessionCim) { Write-Warn '  无法建立性能数据通道，这次只记录进程级数据。' }
    $cap = Test-MonitorAbility -Session $sessionCim
    $result.capability = $cap

    $state = @{
        threads    = [int]$Ctx.threads
        prevProc   = @{}
        procCpu    = @{}
        procIo     = @{}
        gameNames  = @()
        gamePids   = @()
        gameFolder = ''
        selfNames  = @('powershell', 'pwsh', 'conhost', 'cmd', 'windowsterminal', 'openconsole')
        lastTime   = $null
        lastMetrics = @{}
    }
    if ($ProcName) { $state.gameNames = @($ProcName.ToLowerInvariant()) }
    if ($GameFolder) { $state.gameFolder = ([string]$GameFolder) }

    if ($LaunchGame -and $ExePath) {
        Write-Step '正在启动游戏'
        try {
            Start-Process -FilePath $ExePath | Out-Null
            Write-Ok ('已启动：' + $ExePath)
            Write-Note '如果弹出来的是启动器，请在启动器里点进游戏。'
        } catch {
            Write-Warn ('自动启动失败（' + $_.Exception.Message + '），请自己手动打开游戏。')
        }
    }

    if ($state.gameNames.Count -gt 0) {
        Write-Host ''
        Write-Note '正在等游戏进程出现（最多 4 分钟，这段时间还没开始记录）...'
        $waited = 0
        $foundGame = $false
        while ($waited -lt 240) {
            $hit = @(Get-Process -Name $state.gameNames -ErrorAction SilentlyContinue)
            if ($hit.Count -gt 0) {
                $foundGame = $true
                $state.gamePids = @($hit | ForEach-Object { [int]$_.Id })
                break
            }
            Start-Sleep -Seconds 2
            $waited = $waited + 2
            if (($waited % 30) -eq 0) { Write-Note ('  还在等（已等 ' + $waited + ' 秒）...') }
        }
        if ($foundGame) {
            $result.gameDetected = $true
            Write-Ok ('检测到游戏进程：' + ($state.gameNames -join ', '))
            Write-Note '3 秒后正式开始记录，现在可以切进游戏了。'
            Start-Sleep -Seconds 3
        } else {
            Write-Warn '没有等到游戏进程。接下来按整机来记录，你照样可以现在开游戏。'
        }
    } else {
        Write-Warn '这次没有指定游戏进程，按整机来记录。'
    }

    $T0 = Get-Date
    $samples = New-Object 'System.Collections.Generic.List[object]'
    $index = 0
    $intervalMs = 2000
    $slowCount = 0
    $emptyStreak = 0
    $lastSeen = 0
    $ctrlC = $false
    $lastStatus = -100
    $keyOk = $false
    try { [Console]::TreatControlCAsInput = $true; $keyOk = $true } catch { $keyOk = $false }
    $selfCpuStart = 0.0
    try { $selfCpuStart = (Get-Process -Id $PID).TotalProcessorTime.TotalSeconds } catch { }

    Write-Host ''
    Write-Host '  ===== 开始记录了，去玩吧 =====' -ForegroundColor Green
    Write-Note '  提前结束：切回这个窗口按 Ctrl+C'
    Write-Note '  想标出刚才卡了一下：切回窗口按一下回车，报告里会留一个标记点'
    Write-Note '  游戏退出、或者时间到，会自动结束并生成报告'
    Write-Host ''

    $stopReason = ''
    try {
        while ($true) {
            $tickStart = Get-Date
            $s = Get-MonitorTick -Session $sessionCim -Cap $cap -State $state -T0 $T0 -Index $index

            if ($keyOk) {
                try {
                    while ([Console]::KeyAvailable) {
                        $k = [Console]::ReadKey($true)
                        $isCtrlC = $false
                        if ($k.Key -eq [System.ConsoleKey]::C) {
                            if (($k.Modifiers -band [System.ConsoleModifiers]::Control) -ne 0) { $isCtrlC = $true }
                        }
                        if ($isCtrlC) {
                            $ctrlC = $true
                        } else {
                            $s.note = '用户标记（这一刻觉得卡）'
                            $result.marks = @($result.marks) + @($s.clk)
                            Write-Host ''
                            Write-Warn ('  [' + $s.clk + '] 记下了：这一刻你觉得卡')
                        }
                    }
                } catch { $keyOk = $false }
            }

            $samples.Add($s) | Out-Null
            if ($RawPath) {
                try { Add-Content -LiteralPath $RawPath -Value ($s | ConvertTo-Json -Depth 4 -Compress) -Encoding UTF8 } catch { }
            }
            $index++
            $elapsed = [math]::Round(((Get-Date) - $T0).TotalSeconds, 0)

            if (($elapsed - $lastStatus) -ge 15) {
                $lastStatus = $elapsed
                $line = '  [' + (Format-Duration $elapsed) + ']  整机CPU ' + (Show-Num $s.cpu) + '%  游戏CPU ' + (Show-Num $s.game) + '%'
                if ($null -ne $s.gpu) { $line = $line + '  显卡 ' + (Show-Num $s.gpu) + '%' }
                if ($null -ne $s.vram) { $line = $line + '  显存 ' + (Show-Num $s.vram 2) + 'GB' }
                if ($null -ne $s.avail) { $line = $line + '  可用内存 ' + (Show-Num $s.avail 2) + 'GB' }
                if ($null -ne $s.disk) { $line = $line + '  磁盘 ' + (Show-Num $s.disk) + '%' }
                Write-Host $line -ForegroundColor DarkGray
            }

            if ($ctrlC) { $stopReason = '你手动按了 Ctrl+C'; break }
            if ($Seconds -gt 0 -and $elapsed -ge $Seconds) { $stopReason = '时间到'; break }
            if ([double]$s.gmem -gt 0.001 -or [double]$s.game -gt 0.01) {
                $lastSeen = $elapsed
                $emptyStreak = 0
            } else {
                $emptyStreak++
            }
            if ($result.gameDetected -and ($elapsed - $lastSeen) -gt 15 -and $emptyStreak -ge 5) {
                $stopReason = '游戏已退出'
                break
            }

            $cost = [math]::Round(((Get-Date) - $tickStart).TotalMilliseconds, 0)
            if ($cost -gt ($intervalMs * 0.6)) {
                $slowCount++
                if ($slowCount -ge 4 -and $intervalMs -lt 4000) {
                    $intervalMs = $intervalMs + 500
                    $slowCount = 0
                    Write-Note ('  这台电脑上采样有点吃力，已自动把间隔放慢到 ' + ($intervalMs / 1000.0) + ' 秒，尽量不打搅游戏')
                }
            } else {
                $slowCount = 0
            }
            $sleepMs = $intervalMs - $cost
            if ($sleepMs -gt 60) { Start-Sleep -Milliseconds ([int]$sleepMs) }
        }
    } finally {
        if ($keyOk) { try { [Console]::TreatControlCAsInput = $false } catch { } }
    }

    $wallSec = ((Get-Date) - $T0).TotalSeconds
    $selfEnd = 0.0
    try { $selfEnd = (Get-Process -Id $PID).TotalProcessorTime.TotalSeconds } catch { }
    if ($wallSec -gt 1 -and [int]$state.threads -gt 0) {
        $result.selfCpuPct = [math]::Round((($selfEnd - $selfCpuStart) / ($wallSec * [int]$state.threads)) * 100.0, 2)
    }

    $result.samples = $samples.ToArray()
    $result.durationSec = [math]::Round($wallSec, 0)
    $result.stopReason = $stopReason
    $result.intervalMs = $intervalMs
    $result.gamePids = $state.gamePids
    $result.procStats = $state.procCpu
    $result.ioStats = $state.procIo
    try { if ($sessionCim) { Remove-CimSession -CimSession $sessionCim -ErrorAction SilentlyContinue } } catch { }

    Write-Host ''
    Write-Ok ('记录结束（' + $stopReason + '）：' + $samples.Count + ' 个采样点，时长 ' + (Format-Duration $result.durationSec) + '。')
    return $result
}

function Get-MonitorStat {
    param($Values)
    $vals = New-Object 'System.Collections.Generic.List[double]'
    foreach ($v in $Values) {
        if ($null -eq $v) { continue }
        $vals.Add([double]$v) | Out-Null
    }
    if ($vals.Count -eq 0) { return $null }
    $sorted = @($vals | Sort-Object)
    $sum = 0.0
    foreach ($v in $sorted) { $sum = $sum + $v }
    $avg = $sum / $sorted.Count
    $idx = [int][math]::Round(($sorted.Count - 1) * 0.95, 0)
    if ($idx -lt 0) { $idx = 0 }
    if ($idx -ge $sorted.Count) { $idx = $sorted.Count - 1 }
    return [ordered]@{
        n   = $sorted.Count
        avg = [math]::Round($avg, 1)
        p95 = [math]::Round($sorted[$idx], 1)
        max = [math]::Round($sorted[$sorted.Count - 1], 1)
        min = [math]::Round($sorted[0], 1)
    }
}

function Get-MonitorAnalysis {
    param($Ctx, $Session)

    $all = @($Session.samples)
    $skip = 0
    if ($Session.gameDetected) { $skip = 60 }
    $use = @($all | Where-Object { [double]$_.t -ge $skip })
    if ($use.Count -lt 4) { $use = $all }

    $ana = [ordered]@{
        sampleCount = $all.Count
        usedCount   = $use.Count
        skippedSec  = $skip
        durationSec = [double]$Session.durationSec
        stats       = [ordered]@{}
        gpuBands    = $null
        cpuBands    = $null
        timeline    = @()
        suspects    = @()
        background  = @()
        ioTop       = @()
        marks       = @($Session.marks)
        findings    = New-Object 'System.Collections.Generic.List[object]'
        tweaks      = New-Object 'System.Collections.Generic.List[object]'
        manual      = New-Object 'System.Collections.Generic.List[object]'
        summary     = ''
        verdict     = ''
    }

    $m = [ordered]@{}
    foreach ($key in @('cpu', 'game', 'core', 'gmem', 'avail', 'cmt', 'disk', 'dq', 'gpu', 'ggpu', 'gpk', 'vram', 'gvram', 'net', 'pgf', 'procs')) {
        $m[$key] = Get-MonitorStat -Values @($use | ForEach-Object { $_.$key })
    }
    $ana.stats = $m

    # 显卡占用分布：多少时间是真的满载
    foreach ($pair in @(@('gpu', 'gpuBands'), @('cpu', 'cpuBands'))) {
        $src = $pair[0]
        $vals = @()
        foreach ($s2 in $use) {
            if ($null -eq $s2.$src) { continue }
            $vals += [double]$s2.$src
        }
        if ($vals.Count -gt 0) {
            $b1 = 0; $b2 = 0; $b3 = 0; $b4 = 0
            foreach ($v in $vals) {
                if ($v -lt 50) { $b1++ }
                elseif ($v -lt 80) { $b2++ }
                elseif ($v -lt 95) { $b3++ }
                else { $b4++ }
            }
            $tot = $vals.Count
            $bands = [ordered]@{
                low  = [math]::Round($b1 / $tot * 100, 0)
                mid  = [math]::Round($b2 / $tot * 100, 0)
                high = [math]::Round($b3 / $tot * 100, 0)
                full = [math]::Round($b4 / $tot * 100, 0)
            }
            if ($pair[1] -eq 'gpuBands') { $ana.gpuBands = $bands } else { $ana.cpuBands = $bands }
        }
    }

    # 每 30 秒一段的时间线
    $buckets = @{}
    foreach ($s2 in $all) {
        $b = [int][math]::Floor([double]$s2.t / 30)
        $row = $null
        if ($buckets.ContainsKey($b)) { $row = $buckets[$b] }
        else {
            $row = [ordered]@{ idx = $b; clk = ([string]$s2.clk); cpu = @(); game = @(); gpu = @(); vram = @(); avail = @(); disk = @(); net = @() }
            $buckets[$b] = $row
        }
        $row.cpu += $s2.cpu
        $row.game += $s2.game
        if ($null -ne $s2.gpu) { $row.gpu += $s2.gpu }
        if ($null -ne $s2.vram) { $row.vram += $s2.vram }
        if ($null -ne $s2.avail) { $row.avail += $s2.avail }
        if ($null -ne $s2.disk) { $row.disk += $s2.disk }
        if ($null -ne $s2.net) { $row.net += $s2.net }
    }
    $tl = New-Object 'System.Collections.Generic.List[object]'
    foreach ($b in @($buckets.Keys | Sort-Object)) {
        $row = $buckets[$b]
        if (@($row.cpu).Count -lt 2) { continue }
        $tl.Add([ordered]@{
            clk   = $row.clk
            cpu   = [math]::Round((@($row.cpu) | Measure-Object -Average).Average, 0)
            game  = [math]::Round((@($row.game) | Measure-Object -Average).Average, 0)
            gpu   = (Get-MonitorStat -Values @($row.gpu)).avg
            vram  = (Get-MonitorStat -Values @($row.vram)).avg
            avail = (Get-MonitorStat -Values @($row.avail)).avg
            disk  = (Get-MonitorStat -Values @($row.disk)).avg
            net   = (Get-MonitorStat -Values @($row.net)).avg
        }) | Out-Null
    }
    $ana.timeline = $tl.ToArray()

    # 疑似卡顿的时刻：磁盘打满、内存吃紧、游戏核被占满、后台进程突然起来
    $sus = New-Object 'System.Collections.Generic.List[object]'
    foreach ($s2 in $all) {
        $score = 0
        $why = New-Object 'System.Collections.Generic.List[string]'
        if ($null -ne $s2.disk -and [double]$s2.disk -ge 90) { $score = $score + 2; $why.Add('磁盘忙到 90% 以上') | Out-Null }
        if ($null -ne $s2.cmt -and [double]$s2.cmt -ge 90) { $score = $score + 1; $why.Add('内存已提交比例超过 90%') | Out-Null }
        if ($null -ne $s2.avail -and [double]$s2.avail -lt 0.8) { $score = $score + 2; $why.Add('可用内存不足 0.8GB') | Out-Null }
        if ($null -ne $s2.pgf -and [double]$s2.pgf -ge 8000) { $score = $score + 1; $why.Add('每秒硬页错误很高（内存不够用）') | Out-Null }
        if ([double]$s2.core -ge 150) { $score = $score + 1; $why.Add('游戏把多个核心都吃满了') | Out-Null }
        if ($null -ne $s2.net -and [double]$s2.net -ge 8) { $score = $score + 1; $why.Add('后台有 8MB/s 以上的下载流量') | Out-Null }
        if ($null -ne $s2.note) { $score = $score + 3; $why.Add('你自己标记的时刻') | Out-Null }
        if ($score -ge 2) {
            $sus.Add([ordered]@{ t = $s2.t; clk = $s2.clk; score = $score; why = ($why -join '；'); cpu = $s2.cpu; gpu = $s2.gpu; disk = $s2.disk; avail = $s2.avail; net = $s2.net; note = $s2.note }) | Out-Null
        }
    }
    $ranked = @($sus | Sort-Object -Property @{ Expression = { [int]$_.score } } -Descending)
    $picked = New-Object 'System.Collections.Generic.List[object]'
    $lastT = -999
    foreach ($r in $ranked) {
        if (([double]$r.t - $lastT) -lt 30 -and [string]$r.note -eq '') { continue }
        $picked.Add($r) | Out-Null
        $lastT = [double]$r.t
        if ($picked.Count -ge 10) { break }
    }
    $ana.suspects = $picked.ToArray()

    # 后台占用排行（不含游戏和本程序自己）
    $bg = New-Object 'System.Collections.Generic.List[object]'
    if ($Session.procStats) {
        foreach ($k in $Session.procStats.Keys) {
            $acc = $Session.procStats[$k]
            if ([int]$acc.samples -lt 2) { continue }
            $isGame = $false
            if ($Session.procName -and $k -eq ([string]$Session.procName).ToLowerInvariant()) { $isGame = $true }
            if ($isGame) { continue }
            foreach ($sn in @('powershell', 'pwsh', 'conhost', 'cmd', 'windowsterminal', 'openconsole')) {
                if ($k -eq $sn) { $isGame = $true }
            }
            if ($isGame) { continue }
            $avg = [double]$acc.sum / [double]$acc.samples
            if ($avg -lt 0.3 -and [double]$acc.mem -lt 300) { continue }
            $bg.Add([ordered]@{ name = [string]$acc.n; avg = [math]::Round($avg, 1); max = [math]::Round([double]$acc.max, 1); memGB = [math]::Round([double]$acc.mem / 1024, 2) }) | Out-Null
        }
    }
    $ana.background = @($bg | Sort-Object -Property @{ Expression = { [double]$_.avg } } -Descending | Select-Object -First 15)

    $io = New-Object 'System.Collections.Generic.List[object]'
    if ($Session.ioStats) {
        foreach ($k in $Session.ioStats.Keys) {
            $bytes = [double]$Session.ioStats[$k]
            if ($bytes -lt 20MB) { continue }
            $io.Add([ordered]@{ name = $k; mb = [math]::Round($bytes / 1MB, 0) }) | Out-Null
        }
    }
    $ana.ioTop = @($io | Sort-Object -Property @{ Expression = { [double]$_.mb } } -Descending | Select-Object -First 10)

    return Get-MonitorVerdict -Ctx $Ctx -Session $Session -Ana $ana
}

function Get-MonitorVerdict {
    # 把实测数字翻译成人话：瓶颈在哪、能改什么
    param($Ctx, $Session, $Ana)

    $f = $Ana.findings
    $t = $Ana.tweaks
    $mn = $Ana.manual
    $st = $Ana.stats

    $cpuAvg = 0.0; if ($st.cpu) { $cpuAvg = [double]$st.cpu.avg }
    $gpuAvg = 0.0; if ($st.gpu) { $gpuAvg = [double]$st.gpu.avg }
    $gpuMax = 0.0; if ($st.gpu) { $gpuMax = [double]$st.gpu.max }
    $gpuLow = 0; if ($Ana.gpuBands) { $gpuLow = [int]$Ana.gpuBands.low }
    $gpuFull = 0; if ($Ana.gpuBands) { $gpuFull = [int]$Ana.gpuBands.full }
    $gameAvg = 0.0; if ($st.game) { $gameAvg = [double]$st.game.avg }
    $coreAvg = 0.0; if ($st.core) { $coreAvg = [double]$st.core.avg }
    $availMin = 999.0; if ($st.avail) { $availMin = [double]$st.avail.min }
    $cmtAvg = 0.0; if ($st.cmt) { $cmtAvg = [double]$st.cmt.avg }
    $diskAvg = 0.0; if ($st.disk) { $diskAvg = [double]$st.disk.avg }
    $diskMax = 0.0; if ($st.disk) { $diskMax = [double]$st.disk.max }
    $dqAvg = 0.0; if ($st.dq) { $dqAvg = [double]$st.dq.avg }
    $vramMax = 0.0; if ($st.vram) { $vramMax = [double]$st.vram.max }
    $netMax = 0.0; if ($st.net) { $netMax = [double]$st.net.max }
    $pgfAvg = 0.0; if ($st.pgf) { $pgfAvg = [double]$st.pgf.avg }
    $vramCap = [double]$Ctx.primaryVramGB

    $feel = 0
    $feelTmp = 0
    if ([int]::TryParse(([string]$Session.userFeel), [ref]$feelTmp)) { $feel = $feelTmp }

    $bgSum = 0.0
    $bgNames = New-Object 'System.Collections.Generic.List[string]'
    foreach ($b in @($Ana.background)) {
        $bgSum = $bgSum + [double]$b.avg
        if ($bgNames.Count -lt 5) { $bgNames.Add(([string]$b.name) + '（平均 ' + (Show-Num $b.avg) + '%）') | Out-Null }
    }
    $gameDriveSsd = $true
    if ($Ctx.gameDriveMediaType) {
        if (([string]$Ctx.gameDriveMediaType) -match '(?i)HDD') { $gameDriveSsd = $false }
    }

    if ($st.gpu) {
        if ($gpuAvg -ge 88) {
            Add-Finding -List $f -Title '显卡已经跑满' -Severity 2 `
                -Conclusion '瓶颈在显卡：画面设置已经把这台显卡压到极限，往下调画质就能直接换帧数' `
                -Evidence ('显卡 3D 引擎平均 ' + (Show-Num $gpuAvg) + '%，最高 ' + (Show-Num $gpuMax) + '%，接近满载的时间占 ' + $gpuFull + '%')
        } elseif ($gpuAvg -ge 75) {
            Add-Finding -List $f -Title '显卡接近满载' -Severity 2 `
                -Conclusion '显卡比较吃力，降到中高画质或者开一档超分辨率（DLSS/FSR）通常最有效' `
                -Evidence ('显卡 3D 引擎平均 ' + (Show-Num $gpuAvg) + '%，最高 ' + (Show-Num $gpuMax) + '%')
        } elseif ($gpuAvg -lt 60 -and $feel -ge 3) {
            Add-Finding -List $f -Title '显卡还有余力却没跑顺' -Severity 2 `
                -Conclusion '显卡没吃满，说明卡顿多半不是画质太高，而是 CPU、内存、磁盘或网络的问题' `
                -Evidence ('显卡 3D 引擎平均只有 ' + (Show-Num $gpuAvg) + '%，低于 50% 的时间占 ' + $gpuLow + '%')
        }
    }

    $cpuBound = $false
    if ($coreAvg -ge 85) { $cpuBound = $true }
    if ($st.gpu -and $gpuAvg -lt 72 -and $cpuAvg -ge 65) { $cpuBound = $true }
    if ($cpuBound) {
        Add-Finding -List $f -Title 'CPU 拖了后腿' -Severity 2 `
            -Conclusion '瓶颈在 CPU：优先关后台程序，游戏里把视距、人流密度、物理、光追这类吃 CPU 的项降下来' `
            -Evidence ('整机 CPU 平均 ' + (Show-Num $cpuAvg) + '%，游戏进程相当于吃满 ' + (Show-Num $coreAvg 0) + '% 个核心，显卡平均只有 ' + (Show-Num $gpuAvg) + '%')
    }

    $memShort = $false
    if ($st.avail) {
        if ($availMin -lt 0.8 -or $cmtAvg -ge 92) {
            $memShort = $true
            Add-Finding -List $f -Title '内存不够用' -Severity 3 `
                -Conclusion '内存被吃得很紧，系统会反复读写硬盘，卡顿和掉帧多半来自这里' `
                -Evidence ('可用内存最低只剩 ' + (Show-Num $availMin 2) + 'GB，内存提交比例平均 ' + (Show-Num $cmtAvg 0) + '%')
        } elseif ($availMin -lt 1.5 -or $cmtAvg -ge 85) {
            Add-Finding -List $f -Title '内存余量偏紧' -Severity 2 `
                -Conclusion '内存余量不多，后台再多开点东西（浏览器、录屏）就容易开始卡' `
                -Evidence ('可用内存最低 ' + (Show-Num $availMin 2) + 'GB，内存提交比例平均 ' + (Show-Num $cmtAvg 0) + '%')
        } elseif ($pgfAvg -ge 6000) {
            Add-Finding -List $f -Title '内存压力偏大' -Severity 1 `
                -Conclusion '虽然还有余量，但缺页偏高，说明内存压力在上升' `
                -Evidence ('每秒硬页错误平均 ' + (Show-Num $pgfAvg 0))
        }
    }

    if ($vramMax -gt 0 -and $vramCap -gt 0) {
        $ratio = $vramMax / $vramCap
        if ($ratio -ge 0.92) {
            Add-Finding -List $f -Title '显存已经吃满' -Severity 2 `
                -Conclusion '显存几乎占满，材质会被挤到内存里，表现就是忽然顿一下' `
                -Evidence ('显存峰值 ' + (Show-Num $vramMax 2) + 'GB，显卡一共有 ' + (Show-Num $vramCap 1) + 'GB')
        } elseif ($ratio -ge 0.8) {
            Add-Finding -List $f -Title '显存余量不多' -Severity 1 `
                -Conclusion '显存用量偏高，把纹理质量降一档会更稳' `
                -Evidence ('显存峰值 ' + (Show-Num $vramMax 2) + 'GB，显卡一共有 ' + (Show-Num $vramCap 1) + 'GB')
        }
    }

    if ($st.disk) {
        if ($diskMax -ge 95 -and ($diskAvg -ge 20 -or -not $gameDriveSsd)) {
            Add-Finding -List $f -Title '磁盘在拖后腿' -Severity 2 `
                -Conclusion '磁盘被打满过，读图和贴图加载的瞬间最容易卡住一下' `
                -Evidence ('磁盘繁忙峰值 ' + (Show-Num $diskMax) + '%，平均 ' + (Show-Num $diskAvg) + '%，队列平均 ' + (Show-Num $dqAvg 2))
        }
    }

    if ($bgSum -ge 10) {
        Add-Finding -List $f -Title '后台程序抢了不少资源' -Severity 2 `
            -Conclusion '游戏以外还有程序在持续占用 CPU 和内存，关掉它们等于白捡帧数' `
            -Evidence ('后台合计平均占 ' + (Show-Num $bgSum) + '% 的 CPU；主要来自：' + ($bgNames -join '、'))
    }
    if ($netMax -ge 8) {
        Add-Finding -List $f -Title '后台有下载流量' -Severity 2 `
            -Conclusion '有程序在偷偷下载（游戏平台更新、系统更新、网盘同步），联网游戏会因此突然卡顿' `
            -Evidence ('网络峰值 ' + (Show-Num $netMax 1) + ' MB/s')
    }

    if ($Ctx.isLaptop -and $Ctx.onAc -eq $false) {
        Add-Finding -List $f -Title '笔记本在用电池打游戏' -Severity 3 `
            -Conclusion '电池供电时显卡和 CPU 会被强制降频，帧数掉一半很常见；插上电源重测一次才准' `
            -Evidence ('当前供电：电池，电量 ' + ([string]$Ctx.batteryPct) + '%')
    }
    if ($Ctx.powerPlanLabel -eq '平衡' -or $Ctx.powerPlanLabel -eq '节能') {
        Add-Finding -List $f -Title '电源模式不是高性能' -Severity 2 `
            -Conclusion '当前电源计划会让 CPU 提前降频，切成高性能通常能减少掉帧' `
            -Evidence ('当前电源计划：' + ([string]$Ctx.powerPlanLabel) + '（' + ([string]$Ctx.powerPlanName) + '）')
    }
    if ($null -ne $Ctx.procMaxPct -and [int]$Ctx.procMaxPct -lt 100) {
        Add-Finding -List $f -Title 'CPU 最大频率被限制' -Severity 2 `
            -Conclusion ('电源设置把处理器最大状态限制到了 ' + [string]$Ctx.procMaxPct + '%，等于自己给自己降频') `
            -Evidence ('注册表里读到的处理器最大状态：' + [string]$Ctx.procMaxPct + '%')
    }

    if (@($Ana.suspects).Count -gt 0) {
        $s0 = @($Ana.suspects)[0]
        Add-Finding -List $f -Title '记录到可疑的卡顿时刻' -Severity 1 `
            -Conclusion '报告里列了具体时刻和当时的各项占用，可以对照着看是什么引起的' `
            -Evidence ('最可疑的一处是 ' + ([string]$s0.clk) + '：' + ([string]$s0.why))
    }

    if ($gpuAvg -ge 75) {
        Add-Manual -List $mn -Priority 1 -Title '画质按这个顺序往下调（显卡吃紧）' `
            -Detail '先降：分辨率缩放或渲染倍率 → 阴影质量 → 体积雾与体积云 → 屏幕空间反射 → 环境光遮蔽 → 抗锯齿档位。如果游戏支持 DLSS / FSR / XeSS，直接切到平衡或性能档，通常比降画质更划算。'
    }
    if ($cpuBound) {
        Add-Manual -List $mn -Priority 1 -Title 'CPU 吃紧时先关这些' `
            -Detail '关掉浏览器（尤其是几十个标签页）、录屏与直播软件、同时开着的多个游戏加速器、杀毒软件的全盘扫描；游戏内优先降：视距与绘制距离、人流与载具密度、物理破坏、光追阴影。'
    }
    if ($memShort -or $availMin -lt 1.5) {
        Add-Manual -List $mn -Priority 1 -Title '内存不足的处理办法' `
            -Detail '打游戏前关掉浏览器、聊天软件的大文件传输、云盘同步；虚拟内存保持系统自动管理并放在 SSD 上；如果经常不够用，加一条内存是这台机器最划算的升级。'
    }
    if ($vramCap -gt 0 -and $vramMax -gt 0 -and ($vramMax / $vramCap) -ge 0.85) {
        Add-Manual -List $mn -Priority 2 -Title '显存吃紧时先降这些' `
            -Detail '纹理质量或材质细节降一档、关掉高清材质包、分辨率或渲染倍率降一档、关闭光追。这些项见效快，也能顺带缓解显卡满载。'
    }
    if ($diskMax -ge 90) {
        Add-Manual -List $mn -Priority 2 -Title '磁盘被打满时' `
            -Detail '进游戏前让 Steam / Epic 的更新先跑完，暂停网盘同步；游戏如果装在机械盘上，挪到 SSD 收益非常大；着色器编译阶段的卡顿属正常，编译完就好。'
    }
    if ($netMax -ge 8) {
        Add-Manual -List $mn -Priority 2 -Title '打游戏时别让后台下载' `
            -Detail 'Steam 设置里把下载时段限制在你不玩的时候，Windows 更新改成手动，网盘改成按需同步。'
    }
    $bgKill = New-Object 'System.Collections.Generic.List[string]'
    foreach ($b in @($Ana.background)) {
        if ([double]$b.avg -lt 1.5) { continue }
        $nm = ([string]$b.name).ToLowerInvariant()
        if ($nm -eq 'msmpeng' -or $nm -eq 'system' -or $nm -eq 'dwm' -or $nm -eq 'explorer') { continue }
        if ($nm -eq 'audiodg' -or $nm -eq 'svchost' -or $nm -eq 'searchindexer' -or $nm -eq 'csrss') { continue }
        if ($bgKill.Count -lt 6) { $bgKill.Add([string]$b.name) | Out-Null }
    }
    if ($bgKill.Count -gt 0) {
        Add-Manual -List $mn -Priority 1 -Title '这次实测里一直在偷偷吃资源的程序' `
            -Detail ('实测期间持续占用 CPU、又和游戏无关的：' + ($bgKill -join '、') + '。进游戏前把它们关掉（或者从开机启动项里去掉），比任何优化软件都管用。')
    }
    if (@($Ana.marks).Count -gt 0) {
        Add-Manual -List $mn -Priority 1 -Title '你自己标记的卡顿点' `
            -Detail ('你按回车标记的时刻：' + (@($Ana.marks) -join '、') + '。报告第 5 节有这些时刻的占用情况，对着看能定位原因。')
    }

    if ($Ctx.powerPlanLabel -eq '平衡' -or $Ctx.powerPlanLabel -eq '节能') {
        Add-Tweak -List $t -Id 'POWER_PLAN_HIGH' -Priority 1 -Reason '实测发现电源计划不是高性能，CPU 会提前降频'
    }
    if ($Ctx.gameMode -eq $false) {
        Add-Tweak -List $t -Id 'GAME_MODE' -Priority 2 -Reason '游戏模式没开，打开能减少后台打扰'
    } elseif ($null -eq $Ctx.gameMode) {
        Add-Tweak -List $t -Id 'GAME_MODE' -Priority 3 -Reason '没能读到游戏模式的开关状态，直接打开是安全的'
    }
    if ($Ctx.gameDvr -eq $true) {
        Add-Tweak -List $t -Id 'GAME_DVR_OFF' -Priority 2 -Reason '后台录制开着会持续占用显卡和磁盘'
    }
    if ($coreAvg -ge 85) {
        Add-Tweak -List $t -Id 'GAME_PRIORITY' -Priority 2 -Reason ('游戏进程几乎吃满 CPU（约 ' + (Show-Num $coreAvg 0) + '% 个核心），提高优先级能少被后台抢占')
    } elseif ($bgSum -ge 5) {
        Add-Tweak -List $t -Id 'GAME_PRIORITY' -Priority 2 -Reason ('后台程序合计占用 CPU ' + (Show-Num $bgSum) + '%，提高游戏优先级能减少被抢占')
    }
    if (@($Ctx.gpus).Count -gt 1 -and $Session.exePath) {
        Add-Tweak -List $t -Id 'GPU_PREF_HIGH' -Priority 1 -Reason '这台机器有多个显卡，明确指定用独显最稳妥'
    }
    if ($Ctx.hags -eq $false -and $gpuAvg -ge 80) {
        Add-Tweak -List $t -Id 'HAGS_ON' -Priority 2 -Reason '显卡长期接近满载，开启硬件加速 GPU 计划通常能改善帧生成（需要重启）'
    }
    if ($cpuBound -and $Ctx.vbs -eq $true -and $feel -ge 3) {
        Add-Tweak -List $t -Id 'VBS_OFF' -Priority 3 -Reason 'CPU 是瓶颈且内存完整性开着，关掉通常能多几帧（属于高风险项，要你自己确认后才会执行）'
    }

    $verdict = ''
    if ($memShort) { $verdict = '内存是主要瓶颈' }
    elseif ($gpuAvg -ge 88) { $verdict = '显卡已经跑满，降画质最有效' }
    elseif ($cpuBound) { $verdict = 'CPU 是瓶颈，先关后台再降吃 CPU 的画质' }
    elseif ($gpuAvg -ge 75) { $verdict = '显卡偏吃力，画质降一档' }
    elseif ($diskMax -ge 95) { $verdict = '磁盘被打满，注意后台下载和游戏安装盘' }
    elseif ($bgSum -ge 10) { $verdict = '后台程序在抢资源，关掉就有收益' }
    elseif ($gpuAvg -gt 0) { $verdict = '整体负载不高，问题多半在游戏设置、驱动或网络' }
    if (-not $verdict) {
        if (-not $st.gpu -and $Ana.durationSec -ge 90) { $verdict = '这台机器读不到显卡占用，结论以 CPU、内存、磁盘和网络为准' }
        else { $verdict = '这次数据太少，建议再录一把' }
    }
    $Ana.verdict = $verdict

    $bits = New-Object 'System.Collections.Generic.List[string]'
    $bits.Add('实测 ' + (Format-Duration $Ana.durationSec) + '，' + $Ana.usedCount + ' 个采样点') | Out-Null
    if ($st.gpu) { $bits.Add('显卡 3D 引擎平均 ' + (Show-Num $gpuAvg) + '%（满载时间 ' + $gpuFull + '%）') | Out-Null }
    $bits.Add('整机 CPU 平均 ' + (Show-Num $cpuAvg) + '%，游戏进程 CPU 平均 ' + (Show-Num $gameAvg) + '%') | Out-Null
    if ($st.avail) { $bits.Add('可用内存最低 ' + (Show-Num $availMin 2) + 'GB') | Out-Null }
    if ($st.vram) { $bits.Add('显存峰值 ' + (Show-Num $vramMax 2) + 'GB') | Out-Null }
    if ($st.disk) { $bits.Add('磁盘繁忙平均 ' + (Show-Num $diskAvg) + '% / 峰值 ' + (Show-Num $diskMax) + '%') | Out-Null }
    $bits.Add('结论：' + $verdict) | Out-Null
    $Ana.summary = ($bits -join '；')

    return $Ana
}

function New-MonitorReport {
    param($Ctx, $Session, $Ana, [string]$Stamp, [string]$RawPath, [string]$ScriptName, [string]$SkippedText)

    $L = New-Object 'System.Collections.Generic.List[string]'
    $gameTitle = '（未指定游戏）'
    if ($Session.gameName) { $gameTitle = [string]$Session.gameName }
    elseif ($Session.procName) { $gameTitle = [string]$Session.procName }

    $L.Add('# 游戏性能实测报告：' + $gameTitle) | Out-Null
    $L.Add('') | Out-Null
    $L.Add('- 生成时间：' + ([string]$Ctx.generatedAt)) | Out-Null
    $L.Add('- 记录时长：' + (Format-Duration $Ana.durationSec) + '（结束原因：' + ([string]$Session.stopReason) + '）') | Out-Null
    $L.Add('- 采样点数：' + $Ana.sampleCount + ' 个，用于统计的有效点 ' + $Ana.usedCount + ' 个，约每 ' + (Show-Num ([double]$Session.intervalMs / 1000.0) 1) + ' 秒一个') | Out-Null
    $L.Add('- 数据来源：游戏运行期间的只读采样，没有修改任何系统设置，也没有上传任何数据') | Out-Null
    if ($Ana.skippedSec -gt 0) { $L.Add('- 统计时已排除开头 ' + $Ana.skippedSec + ' 秒（进游戏加载阶段的磁盘与 CPU 波动属于正常现象）') | Out-Null }
    $L.Add('') | Out-Null
    $L.Add('## 一句话结论') | Out-Null
    $L.Add('') | Out-Null
    $L.Add('**' + ([string]$Ana.verdict) + '** —— ' + ([string]$Ana.summary)) | Out-Null
    $L.Add('') | Out-Null
    $L.Add('## 1. 记录时的机器状态') | Out-Null
    $L.Add('') | Out-Null
    $L.Add('| 项目 | 值 |') | Out-Null
    $L.Add('| --- | --- |') | Out-Null
    $L.Add('| 电脑 | ' + ([string]$Ctx.computerName) + (Format-MonitorLaptop -Ctx $Ctx) + ' |') | Out-Null
    $L.Add('| 处理器 | ' + ([string]$Ctx.cpuName) + '（' + [string]$Ctx.cores + ' 核 / ' + [string]$Ctx.threads + ' 线程） |') | Out-Null
    $L.Add('| 显卡 | ' + ([string]$Ctx.primaryGpu) + '，显存 ' + (Show-Num $Ctx.primaryVramGB 1) + ' GB |') | Out-Null
    $L.Add('| 内存 | ' + (Show-Num $Ctx.totalRamGB 1) + ' GB |') | Out-Null
    $L.Add('| 系统 | ' + ([string]$Ctx.osCaption) + '（内部版本 ' + ([string]$Ctx.osBuild) + '） |') | Out-Null
    $L.Add('| 电源计划 | ' + ([string]$Ctx.powerPlanLabel) + '（' + ([string]$Ctx.powerPlanName) + '） |') | Out-Null
    $procLabel = [string]$Session.procName
    if (-not $procLabel) { $procLabel = '（未指定，按整机记录）' }
    $L.Add('| 监控的进程 | ' + $procLabel + ' |') | Out-Null
    $L.Add('| 采样程序自身占用 | 平均 ' + (Show-Num $Session.selfCpuPct 2) + '% 的 CPU，可以忽略 |') | Out-Null
    $L.Add('') | Out-Null
    $L.Add('## 2. 关键指标') | Out-Null
    $L.Add('') | Out-Null
    $L.Add('| 指标 | 平均 | 峰值 | 说明 |') | Out-Null
    $L.Add('| --- | --- | --- | --- |') | Out-Null
    if ($Ana.stats.cpu) { $L.Add('| 整机 CPU | ' + (Show-Num $Ana.stats.cpu.avg) + '% | ' + (Show-Num $Ana.stats.cpu.max) + '% | 所有程序加起来 |') | Out-Null }
    if ($Ana.stats.game) { $L.Add('| 游戏进程 CPU | ' + (Show-Num $Ana.stats.game.avg) + '% | ' + (Show-Num $Ana.stats.game.max) + '% | 相当于吃满 ' + (Show-Num $Ana.stats.core.avg 0) + '% 个核心 |') | Out-Null }
    if ($Ana.stats.gpu) { $L.Add('| 显卡 3D 引擎 | ' + (Show-Num $Ana.stats.gpu.avg) + '% | ' + (Show-Num $Ana.stats.gpu.max) + '% | 贴近 100% 说明显卡是瓶颈 |') | Out-Null }
    if ($Ana.stats.vram) { $L.Add('| 显存占用 | ' + (Show-Num $Ana.stats.vram.avg 2) + ' GB | ' + (Show-Num $Ana.stats.vram.max 2) + ' GB | 显卡一共 ' + (Show-Num $Ctx.primaryVramGB 1) + ' GB |') | Out-Null }
    if ($Ana.stats.avail) { $L.Add('| 可用内存 | ' + (Show-Num $Ana.stats.avail.avg 2) + ' GB | 最低 ' + (Show-Num $Ana.stats.avail.min 2) + ' GB | 低于 1GB 就容易开始卡 |') | Out-Null }
    if ($Ana.stats.cmt) { $L.Add('| 内存提交比例 | ' + (Show-Num $Ana.stats.cmt.avg 0) + '% | ' + (Show-Num $Ana.stats.cmt.max 0) + '% | 超过 90% 说明内存吃紧 |') | Out-Null }
    if ($Ana.stats.disk) { $L.Add('| 磁盘繁忙 | ' + (Show-Num $Ana.stats.disk.avg) + '% | ' + (Show-Num $Ana.stats.disk.max) + '% | 长期高于 80% 会拖累加载 |') | Out-Null }
    if ($Ana.stats.net) { $L.Add('| 网络吞吐 | ' + (Show-Num $Ana.stats.net.avg 2) + ' MB/s | ' + (Show-Num $Ana.stats.net.max 2) + ' MB/s | 后台下载会在峰值上露出来 |') | Out-Null }
    $L.Add('') | Out-Null
    if ($Ana.gpuBands) {
        $L.Add('显卡占用分布：低于 50% 占 ' + $Ana.gpuBands.low + '%，50% 到 80% 占 ' + $Ana.gpuBands.mid + '%，80% 到 95% 占 ' + $Ana.gpuBands.high + '%，95% 以上占 ' + $Ana.gpuBands.full + '%') | Out-Null
        $L.Add('') | Out-Null
    }
    $L.Add('## 3. 时间线（每 30 秒一个点）') | Out-Null
    $L.Add('') | Out-Null
    $L.Add('| 时间 | 整机CPU | 游戏CPU | 显卡3D | 显存 | 可用内存 | 磁盘 | 网络 |') | Out-Null
    $L.Add('| --- | --- | --- | --- | --- | --- | --- | --- |') | Out-Null
    foreach ($r in @($Ana.timeline)) {
        $gpuCell = '--'
        if ($null -ne $r.gpu) { $gpuCell = (Show-Num $r.gpu 0) + '% ' + (New-MonitorBar -Value $r.gpu -Width 6) }
        $diskCell = '--'
        if ($null -ne $r.disk) { $diskCell = (Show-Num $r.disk 0) + '% ' + (New-MonitorBar -Value $r.disk -Width 6) }
        $L.Add('| ' + ([string]$r.clk) + ' | ' + (Show-Num $r.cpu 0) + '% ' + (New-MonitorBar -Value $r.cpu -Width 6) + ' | ' + (Show-Num $r.game 0) + '% | ' + $gpuCell + ' | ' + (Show-Num $r.vram 2) + 'G | ' + (Show-Num $r.avail 2) + 'G | ' + $diskCell + ' | ' + (Show-Num $r.net 1) + 'M |') | Out-Null
    }
    $L.Add('') | Out-Null

    $L.Add('## 4. 后台程序占用排行（游戏以外）') | Out-Null
    $L.Add('') | Out-Null
    if (@($Ana.background).Count -eq 0) {
        $L.Add('这次记录期间，游戏以外没有明显的资源占用。') | Out-Null
    } else {
        $L.Add('| 程序 | 平均 CPU | 峰值 CPU | 峰值内存 | 处理建议 |') | Out-Null
        $L.Add('| --- | --- | --- | --- | --- |') | Out-Null
        foreach ($b in @($Ana.background)) {
            $nm = ([string]$b.name).ToLowerInvariant()
            $tip = '进游戏前可以关掉'
            if ($nm -eq 'msmpeng' -or $nm -eq 'nissrv') { $tip = '这是 Windows Defender，不要关，保持默认' }
            elseif ($nm -eq 'dwm' -or $nm -eq 'explorer') { $tip = '系统桌面相关，不要关' }
            elseif ($nm -eq 'svchost' -or $nm -eq 'system' -or $nm -eq 'audiodg' -or $nm -eq 'csrss' -or $nm -eq 'lsass') { $tip = '系统进程，不要动' }
            elseif ($nm -eq 'searchindexer') { $tip = '搜索索引，可以等它空闲时再跑' }
            elseif ($nm -match 'steam|epic|battle|weixin|qq|chrome|msedge|firefox|discord') { $tip = '不玩的时候关掉，或改成开机不启动' }
            $L.Add('| ' + ([string]$b.name) + ' | ' + (Show-Num $b.avg) + '% | ' + (Show-Num $b.max) + '% | ' + (Show-Num $b.memGB 2) + ' GB | ' + $tip + ' |') | Out-Null
        }
    }
    $L.Add('') | Out-Null
    if (@($Ana.ioTop).Count -gt 0) {
        $L.Add('磁盘读写最多的程序（累计量）：') | Out-Null
        $L.Add('') | Out-Null
        foreach ($io in @($Ana.ioTop)) { $L.Add('- ' + ([string]$io.name) + '：' + (Show-Num $io.mb 0) + ' MB') | Out-Null }
        $L.Add('') | Out-Null
    }
    $L.Add('## 5. 可疑的卡顿时刻') | Out-Null
    $L.Add('') | Out-Null
    if (@($Ana.suspects).Count -eq 0) {
        $L.Add('这次记录里没有发现明显的异常时刻（磁盘、内存、网络都在合理范围）。') | Out-Null
    } else {
        $L.Add('| 时刻 | 整机CPU | 显卡3D | 磁盘 | 可用内存 | 网络 | 可能原因 |') | Out-Null
        $L.Add('| --- | --- | --- | --- | --- | --- | --- |') | Out-Null
        foreach ($s in @($Ana.suspects)) {
            $gpuCell = '--'
            if ($null -ne $s.gpu) { $gpuCell = (Show-Num $s.gpu 0) + '%' }
            $diskCell = '--'
            if ($null -ne $s.disk) { $diskCell = (Show-Num $s.disk 0) + '%' }
            $avCell = '--'
            if ($null -ne $s.avail) { $avCell = (Show-Num $s.avail 2) + 'G' }
            $netCell = '--'
            if ($null -ne $s.net) { $netCell = (Show-Num $s.net 1) + 'M' }
            $L.Add('| ' + ([string]$s.clk) + ' | ' + (Show-Num $s.cpu 0) + '% | ' + $gpuCell + ' | ' + $diskCell + ' | ' + $avCell + ' | ' + $netCell + ' | ' + ([string]$s.why) + ' |') | Out-Null
        }
    }
    $L.Add('') | Out-Null
    $L.Add('## 6. 结论与建议') | Out-Null
    $L.Add('') | Out-Null
    $L.Add('### 6.1 实测发现的问题（按严重程度）') | Out-Null
    $L.Add('') | Out-Null
    $tmpFind = @($Ana.findings | Sort-Object -Property @{ Expression = { [int]$_.seq } })
    $sorted = @($tmpFind | Sort-Object -Property @{ Expression = { [int]$_.severity } } -Descending)
    if ($sorted.Count -eq 0) {
        $L.Add('没有发现明显的问题项。') | Out-Null
    } else {
        foreach ($fd in $sorted) {
            $L.Add('**[ ' + (Get-SeverityText -Severity ([int]$fd.severity)) + ' ] ' + ([string]$fd.title) + '**') | Out-Null
            $L.Add('') | Out-Null
            $L.Add('- 结论：' + ([string]$fd.conclusion)) | Out-Null
            $L.Add('- 依据：' + ([string]$fd.evidence)) | Out-Null
            $L.Add('') | Out-Null
        }
    }
    $L.Add('### 6.2 你需要手动做的（游戏内设置与关后台）') | Out-Null
    $L.Add('') | Out-Null
    $ms = @($Ana.manual | Sort-Object -Property @{ Expression = { [int]$_.priority } })
    if ($ms.Count -eq 0) {
        $L.Add('没有额外的手动步骤。') | Out-Null
    } else {
        foreach ($m in $ms) {
            $L.Add('- **' + ([string]$m.title) + '**：' + ([string]$m.detail)) | Out-Null
        }
    }
    $L.Add('') | Out-Null
    $L.Add('### 6.3 脚本可以代劳的开关') | Out-Null
    $L.Add('') | Out-Null
    if ($Ana.tweaks.Count -eq 0) {
        $L.Add('这次没有需要改系统设置的项（该改的都是游戏内画质和后台程序）。') | Out-Null
    } else {
        foreach ($tw in $Ana.tweaks) {
            $cat = $script:TweakCatalog[$tw.id]
            $title = [string]$tw.id
            if ($cat) { $title = [string]$cat.Title }
            $L.Add('- ' + $title + ' —— 依据：' + ([string]$tw.reason)) | Out-Null
        }
        $L.Add('') | Out-Null
        if ($ScriptName) {
            $L.Add('已经生成补充优化脚本 **' + $ScriptName + '**（就在这份报告旁边，双击 3-预演不改动.bat 可以先看它要改什么，确认没问题再双击 4-真正应用优化.bat）。') | Out-Null
        } else {
            $L.Add('（这次要改的项在体检脚本里已经包含过了，就不重复生成脚本。）') | Out-Null
        }
    }
    if ($SkippedText) {
        $L.Add('') | Out-Null
        $L.Add('说明：' + $SkippedText) | Out-Null
    }
    $L.Add('') | Out-Null
    $L.Add('## 7. 文件与后续') | Out-Null
    $L.Add('') | Out-Null
    if ($RawPath) { $L.Add('- 逐秒原始数据（想让作者继续深挖就把它一起发过去）：' + $RawPath) | Out-Null }
    $L.Add('- 建议顺序：先做 6.2 里的手动项，再考虑跑脚本；改完可以再录一把做对比。') | Out-Null
    $L.Add('- 如果方便，把这份报告和原始数据发回给作者，可以按你这台机器的实际情况再细化。') | Out-Null
    $L.Add('') | Out-Null
    $L.Add('## 8. 说明与限制') | Out-Null
    $L.Add('') | Out-Null
    $L.Add('- 帧数（FPS）没办法在不注入游戏的前提下自动测量，所以帧数只能靠你自己填。') | Out-Null
    $L.Add('- 显卡占用取的是 3D 引擎利用率；同时开着直播或多引擎并行时，数字会比任务管理器略高。') | Out-Null
    $L.Add('- 采样程序自身占用 CPU 很低（见第 1 节），不会影响你的游戏表现。') | Out-Null
    $miss = New-Object 'System.Collections.Generic.List[string]'
    if ($Session.capability) {
        if (-not $Session.capability.gpu) { $miss.Add('显卡占用（这台机器的 GPU 计数器没启用）') | Out-Null }
        if (-not $Session.capability.memory) { $miss.Add('内存明细') | Out-Null }
        if (-not $Session.capability.disk) { $miss.Add('磁盘繁忙') | Out-Null }
        if (-not $Session.capability.net) { $miss.Add('网络吞吐') | Out-Null }
    }
    if ($miss.Count -gt 0) {
        $L.Add('- 这次没有读到的数据：' + ($miss -join '、') + '。报告里这些项会显示为 --，不影响其余结论。') | Out-Null
    }
    $L.Add('- 本报告由只读采样生成，没有修改任何系统设置，所有数据都留在这台电脑上。') | Out-Null
    $L.Add('') | Out-Null
    $L.Add('（报告结束 · ' + $Stamp + '）') | Out-Null

    return ($L -join [Environment]::NewLine)
}

function Invoke-MonitorMode {
    # 交互入口：选定游戏 -> 陪你打一把 -> 出实测报告 + 补充优化脚本
    param(
        [string]$GameName,
        [int]$Seconds,
        [string]$Dir,
        [string]$GameProcess,
        [string]$ExePath,
        [switch]$NoLaunch
    )

    Write-Title '边玩边记录：真打一把游戏，用实测数据找瓶颈'
    Write-Host '这个模式会做三件事：'
    Write-Bullet '陪你打完这把游戏（也可以从这里帮你启动游戏）'
    Write-Bullet '全程只读记录：CPU、显卡、显存、内存、磁盘、网络，以及后台都有谁在抢资源'
    Write-Bullet '打完出一份实测报告，再按实测结果挑一份补充优化脚本（照样可以先预演、一键回滚）'
    Write-Host ''
    Write-Host '它不会动：游戏文件、反作弊进程、系统设置（只有你确认后要跑的脚本才会改东西）。'
    Write-Host '所有数据都留在本机，不会上传。'
    Write-Host ''

    Write-Step '第一步：读取本机信息（几秒钟）'
    $ctx = Get-MonitorContext
    Write-Ok ('处理器 ' + ([string]$ctx.cpuName) + '；显卡 ' + ([string]$ctx.primaryGpu) + '；内存 ' + (Show-Num $ctx.totalRamGB 1) + ' GB')
    Write-Note ('电源计划：' + ([string]$ctx.powerPlanLabel) + (Format-MonitorLaptop -Ctx $ctx))

    # ---- 选游戏 ----
    $procName = ''
    $exePath = [string]$ExePath
    $gameFolder = ''
    if ($GameProcess) { $procName = [string]$GameProcess }
    Write-Step '第二步：确认这次要记录哪个游戏'
    $hint = Get-RunningGameHint
    if ($hint) {
        Write-Ok ('看样子你正在跑：' + ([string]$hint.name) + '（显卡占用 ' + (Show-Num $hint.gpu) + '%）')
        if (-not $procName) { $procName = [string]$hint.name }
        if (-not $GameName) { $GameName = [string]$hint.name }
        if ($hint.path) { $exePath = [string]$hint.path }
    }
    if (-not $GameName) {
        $GameName = Ask-Question -Id 'monitorGame' -Title '游戏叫什么名字？（输入游戏名就行，例如 永劫无间；拿不准就直接回车）' `
            -Text -DefaultText '本次记录' -Hint '填了名字能顺便帮你找安装位置、判断装在机械盘还是固态盘'
    }
    if (-not $exePath -and $GameName) {
        $found = Find-GameInstall -Name $GameName -ProcessName $procName
        if ($found) {
            if ($found.ToLower().EndsWith('.exe')) { $exePath = $found }
            else { $gameFolder = $found }
        }
    }
    if (-not $exePath -and $gameFolder) {
        try {
            $cand = @(Get-ChildItem -LiteralPath $gameFolder -Filter '*.exe' -File -Recurse -Depth 2 -ErrorAction SilentlyContinue | Sort-Object -Property Length -Descending | Select-Object -First 1)
            if ($cand.Count -gt 0) { $exePath = $cand[0].FullName }
        } catch { }
    }
    if (-not $exePath -and -not $script:IsNonInteractive) {
        $typed = Ask-Question -Id 'monitorExe' -Title '要不要指定游戏主程序（.exe）？知道就填完整路径，不知道直接回车' `
            -Text -DefaultText '' -Optional -Hint '例如 D:\Games\Naraka\NarakaBladepoint.exe（填了才能帮你自动启动游戏）'
        if ($typed -and (Test-Path -LiteralPath $typed)) { $exePath = $typed }
    }
    if ($exePath -and -not $procName) {
        $procName = [System.IO.Path]::GetFileNameWithoutExtension($exePath)
    }
    if ($exePath) { Write-Ok ('游戏主程序：' + $exePath) }
    elseif ($procName) { Write-Note ('这次按进程名监控：' + $procName) }
    else { Write-Warn '没识别到游戏进程名，这次就按整机来记录（照样能看出瓶颈）。' }

    if ($exePath -or $gameFolder) {
        $probePath = $exePath
        if (-not $probePath) { $probePath = $gameFolder }
        $letter = Get-DriveLetterOfPath -Path $probePath
        if ($letter) {
            try {
                $dm = Get-DriveMediaMap
                $mt = $null
                if ($dm -is [System.Collections.IDictionary]) {
                    if ($dm.Contains($letter)) { $mt = $dm[$letter] }
                } elseif ($dm.PSObject.Properties[$letter]) { $mt = $dm.$letter }
                if ($mt) {
                    $ctx['gameDriveLetter'] = $letter
                    $ctx['gameDriveMediaType'] = [string]$mt.mediaType
                    Write-Note ('游戏装在 ' + $letter + ' 盘，介质类型：' + [string]$mt.mediaType)
                }
            } catch { }
        }
    }

    # ---- 记录多长 ----
    if ($Seconds -le 0) {
        $pick = Ask-Question -Id 'monitorMinutes' -Title '这次想记录多久？' `
            -Options @('3 分钟（只跑一局快速对局）', '5 分钟', '10 分钟（推荐）', '15 分钟', '20 分钟', '我自己按 Ctrl+C 结束') -DefaultIndex 3
        if ($pick -match '3 分钟') { $Seconds = 180 }
        elseif ($pick -match '5 分钟') { $Seconds = 300 }
        elseif ($pick -match '10 分钟') { $Seconds = 600 }
        elseif ($pick -match '15 分钟') { $Seconds = 900 }
        elseif ($pick -match '20 分钟') { $Seconds = 1200 }
        else { $Seconds = 0 }
    }
    if ($Seconds -gt 0) { Write-Note ('计划记录 ' + (Format-Duration $Seconds)) } else { Write-Note '不设时长，按 Ctrl+C 或游戏退出时结束' }

    # ---- 是否帮忙启动 ----
    $launch = $false
    if ($NoLaunch) {
        Write-Note '按要求不自动启动游戏：请你自己打开，程序会等它出现。'
    } elseif ($exePath) {
        $ans = Ask-Question -Id 'monitorLaunch' -Title '要现在帮你启动游戏吗？' `
            -Options @('好，现在就启动（推荐）', '我自己启动，你先开始等') -DefaultIndex 1
        if ($ans -match '现在就启动') { $launch = $true }
    } else {
        Write-Note '没有找到游戏主程序，请你自己打开游戏；程序会等你。'
    }

    # ---- 输出目录 ----
    if (-not $Dir) { $Dir = Join-Path $script:BaseDir '性能记录' }
    if (-not [System.IO.Path]::IsPathRooted($Dir)) { $Dir = Join-Path $script:BaseDir $Dir }
    try {
        if (-not (Test-Path -LiteralPath $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }
    } catch {
        Write-Bad ('无法创建输出文件夹：' + $Dir)
        Write-Bad ('错误：' + $_.Exception.Message)
        Wait-Key
        return
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmm'
    $gameTag = Get-SafeFileName -Name $GameName
    $rawPath = Join-Path $Dir ('原始采样-' + $gameTag + '-' + $stamp + '.jsonl')

    Write-Host ''
    Write-Note '小提示：接下来自己去玩就行，不用管这个窗口。'
    Write-Note '如果中途明显卡了一下，可以切回这个窗口按一下回车，报告里会留下一个标记点（切窗口本身可能让游戏卡一瞬，所以别频繁切）。'
    Wait-Key '准备好了按回车开始'

    $session = Invoke-MonitorRun -Ctx $ctx -GameName $GameName -ProcName $procName -ExePath $exePath `
        -GameFolder $gameFolder -Seconds $Seconds -RawPath $rawPath -LaunchGame $launch

    Write-Step '第三步：问问你的手感（这比数字更能说明问题）'
    $feelPick = Ask-Question -Id 'monitorFeel' -Title '这一把玩下来感觉怎么样？' `
        -Options @('很流畅，没什么好挑的', '基本流畅，偶尔有一点小卡', '明显会卡，但还能玩', '卡得比较难受，影响操作', '卡到没法玩') -DefaultIndex 2
    $feel = '3'
    if ($feelPick -match '很流畅') { $feel = '1' }
    elseif ($feelPick -match '基本流畅') { $feel = '2' }
    elseif ($feelPick -match '明显会卡') { $feel = '3' }
    elseif ($feelPick -match '比较难受') { $feel = '4' }
    elseif ($feelPick -match '没法玩') { $feel = '5' }
    $session['userFeel'] = $feel
    $session['userFeelText'] = [string]$feelPick
    $fps = Ask-Question -Id 'monitorFps' -Title '大概多少帧？（不知道就直接回车跳过，例如 60-90 或 平均 80）' -Text -DefaultText '' -Optional
    $session['userFps'] = [string]$fps
    $whenPick = Ask-Question -Id 'monitorWhen' -Title '主要是在什么时候卡？' `
        -Options @('进游戏、加载、读图的时候', '战斗里人多或者特效多的时候', '随机突然卡一下', '说不太清楚') -DefaultIndex 4
    $session['userWhen'] = [string]$whenPick

    Write-Step '第四步：分析实测数据'
    $ana = Get-MonitorAnalysis -Ctx $ctx -Session $session
    if ([int]$feel -ge 4) {
        Add-Finding -List $ana.findings -Title '你自己觉得卡得比较明显' -Severity 3 `
            -Conclusion '手感也是证据：这种情况先按报告 6.2 的手动项一条条排除，再考虑动系统设置' `
            -Evidence ('手感评分：' + [string]$feelPick + '；主要在：' + [string]$whenPick)
    }
    if ($fps) {
        Add-Manual -List $ana.manual -Priority 1 -Title '你这次观察到的帧数' `
            -Detail ('你填的是「' + [string]$fps + '」。如果这个数字比显示器刷新率低不少，而显卡占用又没到 90% 以上，基本可以确定瓶颈在 CPU / 内存 / 网络，而不是画质。')
    }

    Write-Step '第五步：生成报告和补充优化脚本'
    $dirs = New-Object 'System.Collections.Generic.List[string]'
    $dirs.Add((Join-Path $script:BaseDir '优化与方案')) | Out-Null
    $dirs.Add($script:BaseDir) | Out-Null
    $dirs.Add($Dir) | Out-Null
    $plan = Get-MonitorScriptPlan -Ana $ana -ParentDirs $dirs.ToArray()

    $optName = ''
    if ($plan.tweaks.Count -gt 0) {
        $optName = 'Optimize-' + $gameTag + '-监控补丁-' + $stamp + '.ps1'
        $fitSys = [ordered]@{
            generatedAt = [string]$ctx.generatedAt
            cpu         = @{ name = [string]$ctx.cpuName }
            gpus        = $ctx.gpus
        }
        $fitA = @{ gameName = [string]$GameName }
        $optText = New-OptimizeScript -Sys $fitSys -A $fitA -Diag $plan -Stamp $stamp -GameTag $gameTag `
            -MachineTag $env:COMPUTERNAME -ProcName $procName -TargetExe $exePath
        Save-TextFile -Path (Join-Path $Dir $optName) -Text $optText -Bom $true
        $q = [string][char]34
        New-LauncherBat -Path (Join-Path $Dir '3-预演不改动.bat') `
            -SwitchText ('powershell -NoProfile -ExecutionPolicy Bypass -File ' + $q + '%OPTFILE%' + $q) `
            -Banner 'PREVIEW ONLY - nothing will be changed.' -Hint 'preview'
        New-LauncherBat -Path (Join-Path $Dir '4-真正应用优化.bat') `
            -SwitchText ('powershell -NoProfile -ExecutionPolicy Bypass -File ' + $q + '%OPTFILE%' + $q + ' -Apply -Elevate') `
            -Banner 'APPLY - settings will be changed and journaled.' -Hint 'apply'
        New-LauncherBat -Path (Join-Path $Dir '5-一键回滚.bat') `
            -SwitchText ('powershell -NoProfile -ExecutionPolicy Bypass -File ' + $q + '%OPTFILE%' + $q + ' -Revert -Elevate') `
            -Banner 'REVERT - restore everything recorded in the journal.' -Hint 'revert'
    }

    $jsonPath = Join-Path $Dir ('实测数据-' + $gameTag + '-' + $stamp + '.json')
    $export = [ordered]@{
        generatedAt = [string]$ctx.generatedAt
        context     = $ctx
        session     = [ordered]@{
            gameName     = $session.gameName
            procName     = $session.procName
            exePath      = $session.exePath
            startedAt    = $session.startedAt
            durationSec  = $session.durationSec
            stopReason   = $session.stopReason
            intervalMs   = $session.intervalMs
            selfCpuPct   = $session.selfCpuPct
            gameDetected = $session.gameDetected
            marks        = $session.marks
            capability   = $session.capability
            feel         = $session.userFeel
            feelText     = $session.userFeelText
            fps          = $session.userFps
            stutterWhen  = $session.userWhen
        }
        analysis    = [ordered]@{
            verdict    = $ana.verdict
            summary    = $ana.summary
            stats      = $ana.stats
            gpuBands   = $ana.gpuBands
            background = $ana.background
            ioTop      = $ana.ioTop
            findings   = $ana.findings
            tweaks     = $ana.tweaks
        }
        samples     = $session.samples
    }
    try { Save-TextFile -Path $jsonPath -Text ($export | ConvertTo-Json -Depth 8) -Bom $false } catch { }

    $reportPath = Join-Path $Dir ('实测报告-' + $gameTag + '-' + $stamp + '.md')
    $skippedText = ''
    if (@($plan.skipped).Count -gt 0) {
        $skipParts = New-Object 'System.Collections.Generic.List[string]'
        foreach ($sid in @($plan.skipped)) {
            $cat = $script:TweakCatalog[[string]$sid]
            if ($cat) { $skipParts.Add([string]$cat.Title) | Out-Null }
            else { $skipParts.Add([string]$sid) | Out-Null }
        }
        $skippedText = '下面这些开关在之前的脚本里已经包含过了，这次不重复改：' + ($skipParts -join '、')
    }
    $reportText = New-MonitorReport -Ctx $ctx -Session $session -Ana $ana -Stamp $stamp -RawPath $rawPath -ScriptName $optName -SkippedText $skippedText
    Save-TextFile -Path $reportPath -Text $reportText -Bom $true

    Write-Host ''
    Write-Title '实测结论'
    Write-Host ('  ' + ([string]$ana.verdict)) -ForegroundColor Cyan
    Write-Host ''
    foreach ($bit in (([string]$ana.summary) -split '；')) {
        if ($bit.Trim().Length -gt 0) { Write-Host ('  · ' + $bit.Trim()) -ForegroundColor Cyan }
    }
    Write-Host ''
    Write-Host ('  发现问题 ' + $ana.findings.Count + ' 项；手动建议 ' + $ana.manual.Count + ' 条；脚本可代劳 ' + $plan.tweaks.Count + ' 项')
    Write-Host ''
    Write-Host '  生成的文件：' -ForegroundColor White
    Write-Bullet ('实测报告（先看这个）：' + [System.IO.Path]::GetFileName($reportPath))
    Write-Bullet ('逐秒原始数据：' + [System.IO.Path]::GetFileName($rawPath))
    Write-Bullet ('数据汇总：' + [System.IO.Path]::GetFileName($jsonPath))
    if ($optName) {
        Write-Bullet ('补充优化脚本：' + $optName + '（同目录的 3-预演不改动.bat / 4-真正应用优化.bat / 5-一键回滚.bat 都能用）')
    } else {
        Write-Bullet '这次没有需要改系统设置的项，报告里的手动建议就是全部'
    }
    Write-Host ''
    Write-Host ('  文件都在这个文件夹里：' + $Dir) -ForegroundColor White

    if (-not $script:IsNonInteractive -and -not $NoPause) {
        $q = [string][char]34
        Write-Host ''
        $ans1 = Read-Host '要现在打开报告文件夹吗？（直接回车打开，输入 n 跳过）'
        if ($ans1 -ne 'n' -and $ans1 -ne 'N') {
            try { Start-Process explorer.exe -ArgumentList ($q + $Dir + $q) | Out-Null } catch { }
        }
        Write-Host ''
        $ans2 = Read-Host '要现在打开实测报告吗？（输入 y 打开，直接回车结束）'
        if ($ans2 -eq 'y' -or $ans2 -eq 'Y') {
            try { Start-Process notepad.exe -ArgumentList ($q + $reportPath + $q) | Out-Null } catch { }
        }
    }
}

function New-MonitorBar {
    param($Value, [int]$Width = 12, [double]$Max = 100)
    if ($null -eq $Value) { return '' }
    $v = [double]$Value
    if ($v -lt 0) { $v = 0 }
    $n = [int][math]::Round(($v / $Max) * $Width, 0)
    if ($n -gt $Width) { $n = $Width }
    $bar = ''
    for ($i = 0; $i -lt $n; $i++) { $bar = $bar + '#' }
    return $bar
}

function Get-SeverityText {
    param([int]$Severity)
    if ($Severity -ge 3) { return '严重' }
    if ($Severity -eq 2) { return '注意' }
    return '提示'
}

function Format-MonitorLaptop {
    param($Ctx)
    $t = ''
    if ($Ctx.isLaptop) { $t = '（笔记本' }
    if ($Ctx.isLaptop -and $null -ne $Ctx.onAc) {
        if ($Ctx.onAc) { $t = $t + '，插着电源）' } else { $t = $t + '，用电池，性能会被限制）' }
    }
    if (-not $Ctx.isLaptop) { return '' }
    return $t
}

function Read-ExistingTweakIds {
    # 看看已经生成的优化脚本改过哪些开关，避免这次重复改同一项
    param([string]$Dir)
    $ids = New-Object 'System.Collections.Generic.List[string]'
    if (-not $Dir) { return $ids }
    if (-not (Test-Path -LiteralPath $Dir)) { return $ids }
    $cands = @(Get-ChildItem -LiteralPath $Dir -Filter 'Optimize-*.ps1' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    if ($cands.Count -eq 0) { return $ids }
    try {
        $text = Get-Content -Raw -LiteralPath $cands[0].FullName -Encoding UTF8
        $m = [regex]::Match($text, '\$SelectedTweaks\s*=\s*@\(([^)]*)\)')
        if ($m.Success) {
            foreach ($q in [regex]::Matches($m.Groups[1].Value, '([A-Z0-9_]+)')) {
                if (-not $ids.Contains($q.Groups[1].Value)) { $ids.Add($q.Groups[1].Value) | Out-Null }
            }
        }
    } catch { }
    return $ids
}

function Get-MonitorScriptPlan {
    param($Ana, $ParentDirs)
    $existing = New-Object 'System.Collections.Generic.List[string]'
    foreach ($d in @($ParentDirs)) {
        foreach ($id in @(Read-ExistingTweakIds -Dir $d)) {
            if (-not $existing.Contains($id)) { $existing.Add($id) | Out-Null }
        }
    }
    $tweaks = New-Object 'System.Collections.Generic.List[object]'
    $skipped = New-Object 'System.Collections.Generic.List[string]'
    foreach ($tw in $Ana.tweaks) {
        if ($existing.Contains([string]$tw.id)) { $skipped.Add([string]$tw.id) | Out-Null; continue }
        $tweaks.Add($tw) | Out-Null
    }
    $plan = [ordered]@{
        findings = $Ana.findings
        tweaks   = $tweaks.ToArray()
        manual   = $Ana.manual.ToArray()
        summary  = $Ana.summary
        skipped  = $skipped.ToArray()
    }
    return $plan
}
