<#
    GameOptimize.ps1  --  游戏性能体检与优化方案生成器

    它做什么：
      1) 只读采集这台电脑的硬件、驱动、电源、磁盘、后台占用等现状（不改任何设置）
      2) 用几个简单的选择题问清游戏侧的设置和症状
      3) 按"症状 -> 排查顺序"定位瓶颈，输出一份 Markdown 报告
      4) 顺手生成一份只针对这台电脑的优化脚本（默认预演，可回滚）

    它不做什么：
      不关 Defender、不关 Windows Update、不批量禁用服务、不碰游戏文件、
      不碰反作弊进程、不做超频、不把改动写成一堆没收益的注册表。

    用法：
      powershell -ExecutionPolicy Bypass -File GameOptimize.ps1
      可选：-NonInteractive -AnswersFile answers.json   （无人值守/自动化用）
            -SystemJson system.json                     （复用上次的采集结果）
            -OutDir <目录>

    关于编码：本文件保存为 UTF-8 with BOM。Windows PowerShell 5.1 会把没有 BOM 的
    UTF-8 文件按本地编码读，中文会导致语法错误，所以务必保留 BOM。
#>
[CmdletBinding()]
param(
    [string]$OutDir,
    [string]$GameName,
    [string]$GameProcess,
    [switch]$NonInteractive,
    [string]$AnswersFile,
    [string]$SystemJson,
    [switch]$RevertLatest,
    [switch]$Elevate,
    [switch]$NoPause,
    [switch]$Monitor,
    [string]$MonitorGame,
    [int]$MonitorSeconds,
    [switch]$MonitorNoLaunch,
    [string]$MonitorExe
)

# 边玩边记录模式（-Monitor）用到的参数：
#   -MonitorGame     这次记录哪个游戏（可以留空，程序会问）
#   -MonitorSeconds  记录多少秒（0 表示由用户选择或手动结束）
#   -MonitorNoLaunch 不要自动启动游戏，只等它自己起来
#   -GameProcess     游戏进程名（可选，给了就不问）

$ErrorActionPreference = 'Continue'

if ($PSScriptRoot) { $script:BaseDir = $PSScriptRoot } else { $script:BaseDir = (Get-Location).Path }
if (-not $OutDir) { $OutDir = Join-Path $script:BaseDir '优化与方案' }
if (-not [System.IO.Path]::IsPathRooted($OutDir)) { $OutDir = Join-Path $script:BaseDir $OutDir }
$script:OutDir = $OutDir
$script:Issues = New-Object 'System.Collections.Generic.List[string]'
$script:Answers = @{}
$script:IsNonInteractive = [bool]$NonInteractive

# 不要动 [Console]::OutputEncoding：保持控制台默认编码，powercfg / netsh 这类
# 系统命令的中文输出才能被正确解码。中文界面文字走 Write-Host，本来就是 Unicode。

if ($AnswersFile) {
    try {
        $raw = [System.IO.File]::ReadAllText($AnswersFile, [System.Text.Encoding]::UTF8)
        $obj = $raw | ConvertFrom-Json
        foreach ($p in $obj.PSObject.Properties) { $script:Answers[$p.Name] = $p.Value }
        if (-not $NonInteractive) { $script:IsNonInteractive = $true }
    } catch {
        Write-Host ("无法读取答案文件 {0}：{1}" -f $AnswersFile, $_.Exception.Message) -ForegroundColor Red
        $script:IsNonInteractive = $false
    }
}

# ---------------------------------------------------------------------------
# 终端输出小工具
# ---------------------------------------------------------------------------
function Write-Blank { Write-Host '' }
function Write-Title {
    param([string]$Text)
    Write-Host ''
    Write-Host ('-' * 70) -ForegroundColor DarkGray
    Write-Host $Text -ForegroundColor Cyan
    Write-Host ('-' * 70) -ForegroundColor DarkGray
}
function Write-Step {
    param([string]$Text)
    Write-Host ''
    Write-Host ("== " + $Text) -ForegroundColor Yellow
}
function Write-Ok { param([string]$Text) Write-Host $Text -ForegroundColor Green }
function Write-Note { param([string]$Text) Write-Host $Text -ForegroundColor Gray }
function Write-Warn { param([string]$Text) Write-Host $Text -ForegroundColor Yellow }
function Write-Bad { param([string]$Text) Write-Host $Text -ForegroundColor Red }
function Write-Bullet { param([string]$Text) Write-Host ("  - " + $Text) }

function Wait-Key {
    param([string]$Message = '按回车继续...')
    if ($script:IsNonInteractive -or $NoPause) { return }
    Write-Blank
    Read-Host $Message | Out-Null
}

# ---------------------------------------------------------------------------
# 问答引擎：交互式菜单 / 文本输入，也可以在无人值守模式下从答案文件取值
# ---------------------------------------------------------------------------
function Resolve-MenuInput {
    param([string]$RawInput, [string[]]$Options, [switch]$Multi, [int]$MaxPick = 3)
    $picked = New-Object 'System.Collections.Generic.List[string]'
    if ($null -eq $RawInput) { return @() }
    $tokens = @($RawInput -split '[,，、;；\s]+' | Where-Object { $_ -ne '' })
    foreach ($tok in $tokens) {
        $idx = 0
        if ([int]::TryParse($tok, [ref]$idx)) {
            if ($idx -ge 1 -and $idx -le $Options.Count) {
                if (-not $picked.Contains($Options[$idx - 1])) { $picked.Add($Options[$idx - 1]) }
            }
            continue
        }
        $hit = $Options | Where-Object { $_ -like ("*" + $tok + "*") } | Select-Object -First 1
        if ($hit -and -not $picked.Contains($hit)) { $picked.Add($hit) }
    }
    if ($Multi -and $picked.Count -gt $MaxPick) {
        return @($picked | Select-Object -First $MaxPick)
    }
    return @($picked)
}

function Ask-Question {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Title,
        [string[]]$Options,
        [int]$DefaultIndex = 1,
        [switch]$Multi,
        [int]$MaxPick = 3,
        [switch]$Text,
        [string]$DefaultText = '',
        [string]$Hint = '',
        [switch]$Optional
    )

    # 无人值守模式：直接从答案文件取值，缺项就走默认值
    if ($script:IsNonInteractive) {
        $val = $null
        if ($script:Answers.ContainsKey($Id) -and $null -ne $script:Answers[$Id]) { $val = "$($script:Answers[$Id])" }
        if ($Text) {
            if ($null -ne $val -and $val.Trim().Length -gt 0) { return $val.Trim() }
            return $DefaultText
        }
        $picked = @(Resolve-MenuInput -RawInput $val -Options $Options -Multi:$Multi -MaxPick $MaxPick)
        if ($picked.Count -eq 0) { $picked = @($Options[$DefaultIndex - 1]) }
        if ($Multi) { return $picked }
        return $picked[0]
    }

    if ($Text) {
        while ($true) {
            Write-Blank
            Write-Host ("  " + $Title) -ForegroundColor White
            if ($Hint) { Write-Note ("    " + $Hint) }
            if ($DefaultText) { Write-Note ("    直接回车 = " + $DefaultText) }
            $line = Read-Host '  > '
            if ($null -eq $line) { $line = '' }
            $line = $line.Trim()
            if ($line.Length -eq 0) {
                if ($DefaultText) { return $DefaultText }
                if ($Optional) { return '' }
                Write-Warn '    这一项不能留空，请再输入一次。'
                continue
            }
            return $line
        }
    }

    while ($true) {
        Write-Blank
        Write-Host ("  " + $Title) -ForegroundColor White
        if ($Hint) { Write-Note ("    " + $Hint) }
        for ($i = 0; $i -lt $Options.Count; $i++) {
            $mark = '   '
            if (-not $Multi -and ($i + 1) -eq $DefaultIndex) { $mark = '  *' }
            Write-Host ("   {0}{1}) {2}" -f $mark, ($i + 1), $Options[$i])
        }
        if ($Multi) {
            Write-Note ("    可以选多个，用逗号隔开，例如：1,3（最多 " + $MaxPick + " 项；直接回车 = 1）")
        } else {
            Write-Note ("    输入编号后回车（直接回车 = " + $DefaultIndex + "）")
        }
        $line = Read-Host '  > '
        if ($null -eq $line) { $line = '' }
        $line = $line.Trim()
        if ($line.Length -eq 0) {
            if ($Multi) { return @($Options[0]) }
            return $Options[$DefaultIndex - 1]
        }
        $picked = @(Resolve-MenuInput -RawInput $line -Options $Options -Multi:$Multi -MaxPick $MaxPick)
        if ($picked.Count -eq 0) {
            Write-Warn '    没看懂这个输入，请输入选项前面的编号。'
            continue
        }
        if ($Multi) { return $picked }
        return $picked[0]
    }
}

# ---------------------------------------------------------------------------
# 只读采集（不修改任何设置）
# ---------------------------------------------------------------------------
function To-GB {
    param($Bytes)
    if ($null -eq $Bytes) { return $null }
    return [math]::Round([double]$Bytes / 1GB, 2)
}

function Invoke-Read {
    param([string]$Name, [scriptblock]$Block)
    try {
        return & $Block
    } catch {
        $script:Issues.Add(("{0}: {1}" -f $Name, $_.Exception.Message)) | Out-Null
        return $null
    }
}

function Get-RegInfo {
    param([string]$Path, [string]$Name)
    try {
        $key = Get-Item -Path $Path -ErrorAction Stop
        if ($null -eq $key.GetValue($Name, $null, 'DoNotExpandEnvironmentNames')) { return $null }
        $kind = $key.GetValueKind($Name)
        return [ordered]@{ value = $key.GetValue($Name); kind = "$kind" }
    } catch {
        return $null
    }
}

function Get-RegValue {
    param([string]$Path, [string]$Name)
    $info = Get-RegInfo -Path $Path -Name $Name
    if ($null -eq $info) { return $null }
    return $info.value
}

function Test-RegPath {
    param([string]$Path)
    try { return (Test-Path -Path $Path -ErrorAction Stop) } catch { return $false }
}

function Test-IsAdmin {
    try {
        return ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Get-GpuTier {
    param([string]$Name)
    if (-not $Name) { return 'unknown' }
    $n = $Name.ToUpperInvariant() -replace '\(TM\)', '' -replace '\(R\)', '' -replace '\s+', ' '

    # 核显/入门：判断是否集成显卡
    $integratedPatterns = @('INTEL(R) HD', 'INTEL HD', 'UHD GRAPHICS', 'IRIS', 'INTEL(R) GRAPHICS',
        'RADEON GRAPHICS', 'VEGA 8', 'VEGA 11', 'RADEON(TM) GRAPHICS', 'VEGA 3', 'VEGA 6', 'RADEON 610M', 'RADEON 660M', 'RADEON 680M', 'RADEON 760M', 'RADEON 780M', 'RADEON 880M')
    foreach ($p in $integratedPatterns) { if ($n.Contains($p)) { return 'integrated' } }
    if ($n.Contains('MICROSOFT BASIC')) { return 'basic' }

    # 独显档次
    $high = @('RTX 4090', 'RTX 4080', 'RTX 4070', 'RTX 3090', 'RTX 3080', 'RTX 3070', 'RTX 5070', 'RTX 5080', 'RTX 5090',
        'RTX 2080', 'RX 7900', 'RX 7800', 'RX 7700', 'RX 6900', 'RX 6800', 'RX 6700', 'RX 9070', 'ARC B580', 'ARC A770')
    $mid = @('RTX 4060', 'RTX 3060', 'RTX 2060', 'GTX 1660', 'GTX 1070', 'GTX 1080', 'RTX 3050', 'RTX 4050', 'RTX 5050',
        'RX 6600', 'RX 6650', 'RX 7600', 'RX 5700', 'RX 580', 'RX 590', 'RX 5600', 'ARC A750', 'ARC A580', 'RTX 2070')
    $low = @('GTX 1050', 'GTX 1050 TI', 'GTX 1060', 'GT 1030', 'GT 730', 'GTX 960', 'GTX 970', 'GTX 950',
        'MX150', 'MX250', 'MX350', 'MX450', 'RX 550', 'RX 560', 'RX 6400', 'R7 240', 'R5 240')
    foreach ($p in $high) { if ($n.Contains($p)) { return 'high' } }
    foreach ($p in $mid) { if ($n.Contains($p)) { return 'mid' } }
    foreach ($p in $low) { if ($n.Contains($p)) { return 'low' } }
    if ($n.Contains('NVIDIA') -or $n.Contains('RADEON RX') -or $n.Contains('GEFORCE')) { return 'mid' }
    return 'unknown'
}

function Get-DriveMediaMap {
    $map = @{}
    $ok = $false
    try {
        $parts = @(Get-Partition -ErrorAction Stop | Where-Object { $_.DriveLetter })
        $disks = @(Get-PhysicalDisk -ErrorAction SilentlyContinue)
        foreach ($p in $parts) {
            $d = $disks | Where-Object { $_.DeviceNumber -eq $p.DiskNumber } | Select-Object -First 1
            if ($d) {
                $map[[string]$p.DriveLetter] = [ordered]@{
                    model     = "$($d.FriendlyName)"
                    mediaType = "$($d.MediaType)"
                    busType   = "$($d.BusType)"
                    sizeGB    = (To-GB $d.Size)
                    source    = 'Get-PhysicalDisk'
                }
                $ok = $true
            }
        }
    } catch {
        $script:Issues.Add("driveMedia: $($_.Exception.Message)") | Out-Null
    }

    if (-not $ok) {
        try {
            $links = @(Get-CimInstance -ClassName Win32_LogicalDiskToPartition -ErrorAction Stop)
            $drives = @(Get-CimInstance -ClassName Win32_DiskDrive -ErrorAction Stop)
            foreach ($l in $links) {
                $drive = ''
                $partId = ''
                if ($l.Dependent -match '"([A-Za-z]):"') { $drive = $Matches[1] }
                if ($l.Antecedent -match 'Disk #(\d+)') { $partId = $Matches[1] }
                if (-not $drive -or -not $partId) { continue }
                $dd = $drives | Where-Object { "$($_.Index)" -eq $partId } | Select-Object -First 1
                if (-not $dd) { continue }
                $guess = 'unknown'
                $model = "$($dd.Model)"
                if ($model -match '(?i)SSD|NVMe|Solid|Samsung|KIOXIA|WD Blue SN|Kingston') { $guess = 'SSD' }
                elseif ($model -match '(?i)^ST\d|WD\d|WDC WD|HTS|TOSHIBA MQ|Hitachi') { $guess = 'HDD' }
                $map[[string]$drive] = [ordered]@{
                    model     = $model
                    mediaType = $guess
                    busType   = "$($dd.InterfaceType)"
                    sizeGB    = (To-GB $dd.Size)
                    source    = 'Win32_DiskDrive(推测)'
                }
            }
        } catch {
            $script:Issues.Add("driveMedia-fallback: $($_.Exception.Message)") | Out-Null
        }
    }
    return $map
}

function Get-DisplayInfo {
    $out = [ordered]@{ currentHz = $null; maxHz = $null; currentW = $null; currentH = $null; note = ''; monitors = @() }
    try {
        $vc = @(Get-CimInstance Win32_VideoController -ErrorAction Stop)
        foreach ($v in $vc) {
            if ($v.CurrentRefreshRate -and $v.CurrentHorizontalResolution) {
                $out.currentHz = $v.CurrentRefreshRate
                $out.currentW = $v.CurrentHorizontalResolution
                $out.currentH = $v.CurrentVerticalResolution
                break
            }
        }
    } catch {
        $script:Issues.Add("display-current: $($_.Exception.Message)") | Out-Null
    }
    try {
        $modes = @(Get-CimInstance -Namespace 'root\wmi' -ClassName WmiMonitorListedSupportedSourceModes -ErrorAction Stop)
        $bestAny = 0
        $bestSame = 0
        $curW = $out.currentW
        $curH = $out.currentH
        foreach ($m in $modes) {
            foreach ($md in $m.MonitorSourceModes) {
                $num = $md.VerticalRefreshRateNumerator
                $den = $md.VerticalRefreshRateDenominator
                if ($null -ne $num -and $null -ne $den -and [double]$den -ne 0) {
                    $hz = [int][math]::Round(([double]$num) / ([double]$den))
                    if ($hz -le 0 -or $hz -ge 1000) { continue }
                    if ($hz -gt $bestAny) { $bestAny = $hz }
                    if ($null -ne $curW -and $null -ne $curH) {
                        if ($md.HorizontalActivePixels -eq $curW -and $md.VerticalActivePixels -eq $curH) {
                            if ($hz -gt $bestSame) { $bestSame = $hz }
                        }
                    }
                }
            }
        }
        # 优先取"当前分辨率下"能支持的最高刷新率，避免被显示器 EDID 里的低分辨率模式带偏
        if ($bestSame -gt 0) { $out.maxHz = $bestSame }
        elseif ($bestAny -gt 0) { $out.maxHz = $bestAny }
    } catch {
        $script:Issues.Add("display-modes: $($_.Exception.Message)") | Out-Null
    }
    if ($null -eq $out.maxHz) {
        $out.note = '未能读取显示器支持的刷新率列表，请手动在"显示设置 - 高级显示设置"里确认'
    }
    return $out
}

function Find-GameInstall {
    param([string]$Name, [string]$ProcessName)
    $candidates = New-Object 'System.Collections.Generic.List[string]'

    # 1) 正在运行的进程
    foreach ($pn in @($ProcessName, $Name)) {
        if (-not $pn) { continue }
        try {
            $p = Get-Process -Name $pn -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($p -and $p.Path) { $candidates.Add($p.Path) }
        } catch { }
    }

    # 2) Steam 库
    try {
        $steamPath = Get-RegValue 'HKCU:\Software\Valve\Steam' 'SteamPath'
        if (-not $steamPath) { $steamPath = Get-RegValue 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam' 'InstallPath' }
        if ($steamPath) {
            $folders = @(Join-Path $steamPath 'steamapps\libraryfolders.vdf')
            $libs = @($steamPath)
            foreach ($f in $folders) {
                if (Test-Path -LiteralPath $f) {
                    $txt = [System.IO.File]::ReadAllText($f)
                    foreach ($m in [regex]::Matches($txt, '"path"\s+"([^"]+)"')) {
                        $libs += ($m.Groups[1].Value -replace '\\\\', '\')
                    }
                }
            }
            foreach ($lib in ($libs | Select-Object -Unique)) {
                $steamapps = Join-Path $lib 'steamapps'
                if (-not (Test-Path -LiteralPath $steamapps)) { continue }
                foreach ($acf in @(Get-ChildItem -LiteralPath $steamapps -Filter 'appmanifest_*.acf' -ErrorAction SilentlyContinue)) {
                    $txt = [System.IO.File]::ReadAllText($acf.FullName)
                    $appName = ''
                    $installDir = ''
                    if ($txt -match '"name"\s+"([^"]+)"') { $appName = $Matches[1] }
                    if ($txt -match '"installdir"\s+"([^"]+)"') { $installDir = $Matches[1] }
                    if (-not $installDir) { continue }
                    $hit = $false
                    if ($Name -and $appName -and ($appName -like ("*" + $Name + "*") -or $Name -like ("*" + $appName + "*"))) { $hit = $true }
                    if (-not $hit -and $Name -and $installDir -like ("*" + $Name + "*")) { $hit = $true }
                    if ($hit) {
                        $full = Join-Path (Join-Path $steamapps 'common') $installDir
                        if (Test-Path -LiteralPath $full) { $candidates.Add($full) }
                    }
                }
            }
        }
    } catch {
        $script:Issues.Add("steam-scan: $($_.Exception.Message)") | Out-Null
    }

    # 3) 卸载信息表
    if ($Name) {
        foreach ($root in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
                            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
                            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')) {
            try {
                foreach ($sub in @(Get-ChildItem -Path $root -ErrorAction SilentlyContinue)) {
                    $dn = Get-RegValue -Path $sub.PSPath -Name 'DisplayName'
                    if (-not $dn) { continue }
                    if ($dn -like ("*" + $Name + "*")) {
                        $loc = Get-RegValue -Path $sub.PSPath -Name 'InstallLocation'
                        if ($loc -and (Test-Path -LiteralPath $loc)) { $candidates.Add($loc) }
                        $icon = Get-RegValue -Path $sub.PSPath -Name 'DisplayIcon'
                        if ($icon) {
                            $iconPath = ($icon -split ',')[0].Trim('"')
                            if ($iconPath -and (Test-Path -LiteralPath $iconPath)) { $candidates.Add($iconPath) }
                        }
                    }
                }
            } catch { }
        }
    }

    # 4) 常见安装目录
    if ($Name) {
        foreach ($root in @("$env:ProgramFiles", "${env:ProgramFiles(x86)}", "$env:SystemDrive\Games", "$env:SystemDrive\Game", "$env:SystemDrive\Program Files", "$env:LOCALAPPDATA")) {
            if (-not $root) { continue }
            try {
                $dir = Join-Path $root $Name
                if (Test-Path -LiteralPath $dir) { $candidates.Add($dir) }
            } catch { }
        }
    }

    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    return $null
}

function Get-UserGpuPreference {
    param([string]$ExePath)
    if (-not $ExePath) { return $null }
    $key = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
    $info = Get-RegInfo -Path $key -Name $ExePath
    if ($null -eq $info) { return $null }
    return $info
}

$script:HogPatterns = @(
    @{ pattern = 'chrome';            label = 'Chrome 浏览器' }
    @{ pattern = 'msedge';            label = 'Edge 浏览器' }
    @{ pattern = 'firefox';           label = 'Firefox 浏览器' }
    @{ pattern = 'QQ';                label = 'QQ' }
    @{ pattern = 'WeChat';            label = '微信' }
    @{ pattern = 'TIM';               label = 'TIM' }
    @{ pattern = 'DingTalk';          label = '钉钉' }
    @{ pattern = 'OneDrive';          label = 'OneDrive 同步' }
    @{ pattern = 'Dropbox';           label = 'Dropbox 同步' }
    @{ pattern = 'BaiduNetdisk';      label = '百度网盘' }
    @{ pattern = 'Thunder';           label = '迅雷' }
    @{ pattern = 'XunLei';            label = '迅雷' }
    @{ pattern = 'Wallpaper';         label = '动态壁纸（Wallpaper Engine 等）' }
    @{ pattern = 'Discord';           label = 'Discord' }
    @{ pattern = 'Overwolf';          label = 'Overwolf 叠加层' }
    @{ pattern = 'obs';               label = 'OBS 录屏/推流' }
    @{ pattern = 'RivaTuner';         label = 'RivaTuner 叠加层' }
    @{ pattern = 'MSIAfterburner';    label = 'MSI Afterburner' }
    @{ pattern = 'NVIDIA Share';      label = 'NVIDIA 即时重放/叠加层' }
    @{ pattern = 'NVIDIA Overlay';    label = 'NVIDIA 叠加层' }
    @{ pattern = 'GameBar';           label = 'Xbox Game Bar' }
    @{ pattern = 'XboxGameBar';       label = 'Xbox Game Bar' }
    @{ pattern = 'steam';             label = 'Steam 客户端' }
    @{ pattern = 'EpicGamesLauncher'; label = 'Epic 启动器' }
    @{ pattern = 'WindowsUpdate';     label = 'Windows 更新' }
    @{ pattern = 'TiWorker';          label = 'Windows 更新组件' }
    @{ pattern = 'MoUsoCoreWorker';   label = 'Windows 更新组件' }
    @{ pattern = 'SearchIndexer';     label = 'Windows 搜索索引' }
    @{ pattern = 'Dwm';               label = '桌面窗口管理器' }
    @{ pattern = 'Antimalware';       label = 'Defender 实时扫描' }
)

$script:SecurityPatterns = @(
    @{ pattern = '360tray';    label = '360 安全卫士' }
    @{ pattern = '360safe';    label = '360 安全卫士' }
    @{ pattern = 'ZhuDongFangYu'; label = '360 主动防御' }
    @{ pattern = 'QQPCTray';   label = '腾讯电脑管家' }
    @{ pattern = 'QQPCRTP';    label = '腾讯电脑管家' }
    @{ pattern = 'kxescore';   label = '金山毒霸' }
    @{ pattern = 'KxETray';    label = '金山毒霸' }
    @{ pattern = 'HipsTray';   label = '火绒' }
    @{ pattern = 'HipsDaemon'; label = '火绒' }
    @{ pattern = 'AvastUI';    label = 'Avast' }
    @{ pattern = 'avp';        label = '卡巴斯基' }
    @{ pattern = 'NortonSecurity'; label = 'Norton' }
    @{ pattern = 'McAfee';     label = 'McAfee' }
)

function Get-BackgroundLoad {
    $procs = @()
    try {
        $procs = @(Get-Process -ErrorAction Stop)
    } catch {
        $script:Issues.Add("processes: $($_.Exception.Message)") | Out-Null
        return $null
    }
    $byMem = @($procs | Sort-Object WorkingSet64 -Descending | Select-Object -First 15 | ForEach-Object {
        [ordered]@{ name = $_.ProcessName; id = $_.Id; memoryMB = [math]::Round($_.WorkingSet64 / 1MB, 1) }
    })
    $hogs = New-Object 'System.Collections.Generic.List[object]'
    $securityFound = New-Object 'System.Collections.Generic.List[string]'
    foreach ($p in $procs) {
        $nm = "$($p.ProcessName)"
        foreach ($h in $script:HogPatterns) {
            if ($nm -like ("*" + $h.pattern + "*")) {
                $memMB = [math]::Round($p.WorkingSet64 / 1MB, 0)
                $hogs.Add([ordered]@{ name = $nm; label = $h.label; memoryMB = $memMB; id = $p.Id }) | Out-Null
                break
            }
        }
        foreach ($s in $script:SecurityPatterns) {
            if ($nm -like ("*" + $s.pattern + "*")) {
                if (-not $securityFound.Contains($s.label)) { $securityFound.Add($s.label) | Out-Null }
                break
            }
        }
    }
    # 按"程序名"合并：Steam / 浏览器这类程序会有十几个子进程，
    # 逐条列出来只会刷屏，合并成"约 XXX MB，N 个进程"更好读。
    $grouped = New-Object 'System.Collections.Generic.List[object]'
    $byLabel = @{}
    foreach ($h in @($hogs | Sort-Object -Property memoryMB -Descending)) {
        $key = "$($h.label)"
        if ($byLabel.ContainsKey($key)) {
            $byLabel[$key].memoryMB = [int]$byLabel[$key].memoryMB + [int]$h.memoryMB
            $byLabel[$key].procCount = [int]$byLabel[$key].procCount + 1
        } else {
            $item = [ordered]@{ name = "$($h.name)"; label = $key; memoryMB = [int]$h.memoryMB; procCount = 1 }
            $byLabel[$key] = $item
            $grouped.Add($item) | Out-Null
        }
    }
    $groupedSorted = @($grouped | Sort-Object -Property memoryMB -Descending)

    return [ordered]@{
        topByMemory  = $byMem
        matchedHogs  = [object[]]$groupedSorted
        securityApps = @($securityFound)
        processCount = $procs.Count
    }
}

function Collect-System {
    param([string]$Game)

    $os = Invoke-Read 'os' {
        $o = Get-CimInstance Win32_OperatingSystem
        [ordered]@{
            caption     = "$($o.Caption)"
            version     = "$($o.Version)"
            build       = "$($o.BuildNumber)"
            arch        = "$($o.OSArchitecture)"
            lastBoot    = "$($o.LastBootUpTime)"
            uptimeHours = [math]::Round(((Get-Date) - $o.LastBootUpTime).TotalHours, 1)
            freeRamGB   = [math]::Round([double]$o.FreePhysicalMemory / 1MB, 2)
            totalRamGB  = [math]::Round([double]$o.TotalVisibleMemorySize / 1MB, 2)
        }
    }

    $computer = Invoke-Read 'computer' {
        $c = Get-CimInstance Win32_ComputerSystem
        [ordered]@{
            manufacturer             = "$($c.Manufacturer)"
            model                    = "$($c.Model)"
            systemType               = "$($c.SystemType)"
            totalRamGB               = (To-GB $c.TotalPhysicalMemory)
            logicalProcessors        = $c.NumberOfLogicalProcessors
            automaticManagedPagefile = $c.AutomaticManagedPagefile
        }
    }

    $cpu = Invoke-Read 'cpu' {
        Get-CimInstance Win32_Processor | Select-Object -First 1 | ForEach-Object {
            [ordered]@{
                name            = "$($_.Name)".Trim()
                cores           = $_.NumberOfCores
                threads         = $_.NumberOfLogicalProcessors
                maxClockMHz     = $_.MaxClockSpeed
                currentClockMHz = $_.CurrentClockSpeed
                loadPercent     = $_.LoadPercentage
            }
        }
    }

    $isLaptop = $false
    $batteryInfo = Invoke-Read 'battery' {
        $b = @(Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)
        $bat = $b | Where-Object { $_.EstimatedChargeRemaining -ne $null -or $_.BatteryStatus -ne $null } | Select-Object -First 1
        if ($bat) {
            return [ordered]@{
                present    = $true
                chargePct  = $bat.EstimatedChargeRemaining
                onAc       = ($bat.BatteryStatus -eq 2 -or $bat.BatteryStatus -eq 6 -or $bat.BatteryStatus -eq 7 -or $bat.BatteryStatus -eq 8)
                statusCode = $bat.BatteryStatus
            }
        }
        return [ordered]@{ present = $false; chargePct = $null; onAc = $null; statusCode = $null }
    }
    if ($batteryInfo -and $batteryInfo.present) { $isLaptop = $true }
    if ($computer -and "$($computer.systemType)" -eq '2') { $isLaptop = $true }

    $vramFromRegistry = Invoke-Read 'vram-registry' {
        $base = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
        $values = @()
        Get-ChildItem -Path $base -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -match '^\d{4}$' } |
            ForEach-Object {
                $q = Get-RegInfo -Path $_.PSPath -Name 'HardwareInformation.qwMemorySize'
                if ($q -and $q.value) { $values += (To-GB ([int64]$q.value)) }
            }
        if ($values.Count -gt 0) { return $values } else { return $null }
    }

    $gpus = Invoke-Read 'gpus' {
        $index = 0
        $list = New-Object 'System.Collections.Generic.List[object]'
        foreach ($v in @(Get-CimInstance Win32_VideoController)) {
            $vram = $null
            if ($vramFromRegistry -and $index -lt $vramFromRegistry.Count) {
                $vram = $vramFromRegistry[$index]
            } elseif ($v.AdapterRAM -and $v.AdapterRAM -gt 0) {
                $vram = (To-GB $v.AdapterRAM)
            }
            $ddText = $null
            $ddAge = $null
            try {
                if ($v.DriverDate) {
                    $dd = [datetime]$v.DriverDate
                    $ddText = $dd.ToString('yyyy-MM-dd')
                    $ddAge = [math]::Round(((Get-Date) - $dd).TotalDays / 30.44, 1)
                }
            } catch {
                $script:Issues.Add("driverdate: $($_.Exception.Message)") | Out-Null
            }
            $list.Add([ordered]@{
                name          = "$($v.Name)"
                driverVersion = "$($v.DriverVersion)"
                driverDate    = $ddText
                driverAgeMonths = $ddAge
                vramGB        = $vram
                resolution    = ("{0}x{1}" -f $v.CurrentHorizontalResolution, $v.CurrentVerticalResolution)
                refreshRate   = $v.CurrentRefreshRate
                status        = "$($v.Status)"
                tier          = (Get-GpuTier -Name "$($v.Name)")
            }) | Out-Null
            $index++
        }
        # 注意：PowerShell 5.1 下 @(List[object]) 会抛 "Argument types do not match"，
        # 必须用 [object[]] 强制转换。
        return [object[]]$list
    }

    $memoryModules = Invoke-Read 'memory' {
        Get-CimInstance Win32_PhysicalMemory | ForEach-Object {
            [ordered]@{
                slot         = "$($_.DeviceLocator)"
                capacityGB   = (To-GB $_.Capacity)
                ratedMHz     = $_.Speed
                runningMHz   = $_.ConfiguredClockSpeed
                manufacturer = "$($_.Manufacturer)"
                partNumber   = "$($_.PartNumber)".Trim()
            }
        }
    }

    $disks = Invoke-Read 'disks' {
        Get-PhysicalDisk | ForEach-Object {
            [ordered]@{
                name       = "$($_.FriendlyName)"
                mediaType  = "$($_.MediaType)"
                busType    = "$($_.BusType)"
                sizeGB     = (To-GB $_.Size)
                health     = "$($_.HealthStatus)"
                spindleRPM = $_.SpindleSpeed
            }
        }
    }

    $volumes = Invoke-Read 'volumes' {
        Get-Volume | Where-Object { $_.DriveType -eq 'Fixed' } | ForEach-Object {
            $freePct = $null
            if ($_.Size -gt 0) { $freePct = [math]::Round(100 * $_.SizeRemaining / $_.Size, 1) }
            [ordered]@{
                drive       = "$($_.DriveLetter)"
                label       = "$($_.FileSystemLabel)"
                sizeGB      = (To-GB $_.Size)
                freeGB      = (To-GB $_.SizeRemaining)
                freePercent = $freePct
            }
        }
    }

    $driveMedia = Invoke-Read 'driveMedia' { Get-DriveMediaMap }

    $power = Invoke-Read 'power' {
        $active = ((& powercfg /getactivescheme) -join ' ')
        $list = ((& powercfg /list) -join "`n")
        $planGuid = ''
        if ($active -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
            $planGuid = $Matches[1]
        }
        # 厂商自定义计划（联想"野兽模式"之类）读不到友好名时，直接读注册表里的
        # "最大处理器状态"：不受语言影响，能判断这个计划是不是在压 CPU。
        $planName = ''
        if ($active -match '\(([^)]+)\)') { $planName = $Matches[1].Trim() }
        $maxAc = $null
        $maxDc = $null
        if ($planGuid) {
            $throttleKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes\' + $planGuid +
                '\54533251-82be-4824-96c1-47b60b740d00\bc5038f7-23e0-4960-96da-33abaf5935ec'
            $maxAc = Get-RegValue -Path $throttleKey -Name 'ACSettingIndex'
            $maxDc = Get-RegValue -Path $throttleKey -Name 'DCSettingIndex'
        }
        [ordered]@{
            activePlan            = $active
            planList              = $list
            planGuid              = $planGuid
            planName              = $planName
            procMaxAc             = $maxAc
            procMaxDc             = $maxDc
            ultimatePlanAvailable = [bool]($list -match 'e9a42b02-d5df-448d-aa00-03f14749eb61')
            fastStartupEnabled    = (Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled')
        }
    }

    $graphics = Invoke-Read 'graphics' {
        $g = Get-RegInfo 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode'
        $hags = $null
        if ($g) { $hags = $g.value }
        [ordered]@{
            hagsHwSchMode       = $hags
            gameDvrEnabled      = (Get-RegValue 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled')
            appCaptureEnabled   = (Get-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled')
            autoGameModeEnabled = (Get-RegValue 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled')
            directXVersion      = (Get-RegValue 'HKLM:\SOFTWARE\Microsoft\DirectX' 'Version')
        }
    }

    $display = Invoke-Read 'display' { Get-DisplayInfo }

    $security = Invoke-Read 'security' {
        $defender = $null
        try {
            $mp = Get-MpComputerStatus -ErrorAction Stop
            $defender = [ordered]@{
                antivirusEnabled          = $mp.AntivirusEnabled
                realTimeProtectionEnabled = $mp.RealTimeProtectionEnabled
                engineVersion             = "$($mp.AMEngineVersion)"
            }
        } catch {
            $script:Issues.Add("defender: $($_.Exception.Message)") | Out-Null
        }
        $vbs = $null
        try {
            $dg = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName Win32_DeviceGuard -ErrorAction Stop
            $vbs = [ordered]@{
                vbsStatus                  = $dg.VirtualizationBasedSecurityStatus
                securityServicesRunning    = ($dg.SecurityServicesRunning -join ',')
                securityServicesConfigured = ($dg.SecurityServicesConfigured -join ',')
            }
        } catch {
            $script:Issues.Add("deviceguard: $($_.Exception.Message)") | Out-Null
        }
        return [ordered]@{ defender = $defender; deviceGuard = $vbs }
    }

    $background = Invoke-Read 'background' { Get-BackgroundLoad }

    $startupItems = Invoke-Read 'startup' {
        Get-CimInstance Win32_StartupCommand | ForEach-Object {
            [ordered]@{ name = "$($_.Name)"; location = "$($_.Location)"; command = "$($_.Command)"; user = "$($_.User)" }
        }
    }

    $services = Invoke-Read 'services' {
        $names = @('SysMain', 'WSearch', 'XblAuthManager', 'XblGameSave', 'XboxGipSvc', 'GameInputSvc', 'BITS', 'DiagTrack', 'Spooler', 'Audiosrv', 'NvContainerLocalSystem')
        foreach ($name in $names) {
            $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
            if ($svc) {
                [ordered]@{ name = $svc.Name; status = "$($svc.Status)"; startType = "$($svc.StartType)" }
            } else {
                [ordered]@{ name = $name; status = 'not-installed'; startType = '' }
            }
        }
    }

    $network = Invoke-Read 'network' {
        $adapters = @()
        try {
            $adapters = @(Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' } | ForEach-Object {
                [ordered]@{
                    name          = "$($_.Name)"
                    description   = "$($_.InterfaceDescription)"
                    linkSpeed     = "$($_.LinkSpeed)"
                    driverVersion = "$($_.DriverVersion)"
                    driverDate    = "$($_.DriverDate)"
                }
            })
        } catch {
            $script:Issues.Add("netadapter: $($_.Exception.Message)") | Out-Null
        }
        # 有线/无线只看网卡本身，避免依赖本地化的命令输出文字
        $wiredUp = $false
        $wirelessUp = $false
        foreach ($a in $adapters) {
            $desc = "$($a.description)"
            if ($desc -match '(?i)Wi-?Fi|Wireless|WLAN|802\.11|无线') { $wirelessUp = $true }
            elseif ($desc -match '(?i)Ethernet|以太网|Realtek PCIe|Intel\(R\) Ethernet|Killer E') { $wiredUp = $true }
        }
        return [ordered]@{ adapters = $adapters; wiredUp = $wiredUp; wirelessUp = $wirelessUp }
    }

    $thermal = Invoke-Read 'thermal' {
        Get-CimInstance -Namespace 'root/wmi' -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop |
            ForEach-Object {
                [ordered]@{
                    zone         = "$($_.InstanceName)"
                    temperatureC = [math]::Round(($_.CurrentTemperature / 10) - 273.15, 1)
                }
            }
    }

    $pendingReboot = Invoke-Read 'pendingReboot' {
        [ordered]@{
            windowsUpdateRebootRequired = (Test-RegPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
            componentBasedServicing     = (Test-RegPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')
            pendingFileRename           = [bool](Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' 'PendingFileRenameOperations')
        }
    }

    $gameInfo = $null
    if ($Game) {
        $gameInfo = Invoke-Read 'game' {
            $path = Find-GameInstall -Name $Game -ProcessName $Game
            $procs = @(Get-Process -Name $Game -ErrorAction SilentlyContinue)
            $running = $procs.Count -gt 0
            if (-not $path -and $running -and $procs[0].Path) { $path = $procs[0].Path }
            $pref = $null
            if ($path -and $path.ToLower().EndsWith('.exe')) { $pref = Get-UserGpuPreference -ExePath $path }
            $prefValue = $null
            $prefKind = $null
            if ($pref) {
                $prefValue = "$($pref.value)"
                $prefKind = "$($pref.kind)"
            }
            return [ordered]@{
                searchName     = $Game
                running        = $running
                installPath    = $path
                gpuPreference  = $prefValue
                gpuPrefKind    = $prefKind
                processCount   = $procs.Count
            }
        }
    }

    return [ordered]@{
        generatedAt    = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        computerName   = $env:COMPUTERNAME
        collectedBy    = 'GameOptimize.ps1（只读采集，未修改任何设置）'
        isAdmin        = (Test-IsAdmin)
        isLaptop       = $isLaptop
        battery        = $batteryInfo
        os             = $os
        computer       = $computer
        cpu            = $cpu
        gpus           = $gpus
        memoryModules  = $memoryModules
        disks          = $disks
        volumes        = $volumes
        driveMedia     = $driveMedia
        power          = $power
        graphics       = $graphics
        display        = $display
        security       = $security
        background     = $background
        startupItems   = $startupItems
        services       = $services
        network        = $network
        thermal        = $thermal
        pendingReboot  = $pendingReboot
        game           = $gameInfo
        readIssues     = @($script:Issues)
    }
}

# ---------------------------------------------------------------------------
# 问诊：把采集脚本读不到的游戏侧信息问清楚
# ---------------------------------------------------------------------------
function Invoke-Interview {
    param($Sys)

    $total = 13
    $q = 0
    $a = @{}

    $defaultName = $GameName
    if (-not $defaultName -and $Sys -and $Sys.game) { $defaultName = '' }

    $q++
    $a.gameName = Ask-Question -Id 'gameName' -Title ("第 {0}/{1} 题  你要优化的游戏叫什么名字？" -f $q, $total) `
        -Text -DefaultText $defaultName -Hint '随便写个名字就行，用来给报告和脚本起名' -Optional

    $q++
    $a.symptoms = Ask-Question -Id 'symptoms' -Title ("第 {0}/{1} 题  最主要的症状是什么？（最多选 3 项）" -f $q, $total) `
        -Options @('帧数整体偏低，画面不流畅', '帧数忽高忽低，会突然掉帧卡顿', '加载慢、进图卡、读盘时间长',
                   '手感迟滞，鼠标转视角有延迟', '网络延迟高、丢包（联机时明显）', '发热高、风扇吵，用一会儿就降速',
                   '偶尔闪退或卡死') `
        -Multi -MaxPick 3

    $q++
    $a.scene = Ask-Question -Id 'scene' -Title ("第 {0}/{1} 题  卡顿最容易出现在什么场景？" -f $q, $total) `
        -Options @('团战、多人混战或特效很多的场面', '加载、进图、读盘的时候', '一进游戏就一直卡，稳定地低',
                   '切出游戏再切回来之后', '说不准，没规律')

    $q++
    $a.resolution = Ask-Question -Id 'resolution' -Title ("第 {0}/{1} 题  游戏内分辨率大概是多少？" -f $q, $total) `
        -Options @('1080p 或更低', '2K（2560x1440）', '4K（3840x2160）', '不清楚')

    $q++
    $a.preset = Ask-Question -Id 'preset' -Title ("第 {0}/{1} 题  游戏内的画质档位是？" -f $q, $total) `
        -Options @('低', '中', '高', '极高 / 特效全开（含光追）', '不清楚')

    $q++
    $a.frameCap = Ask-Question -Id 'frameCap' -Title ("第 {0}/{1} 题  帧率上限和垂直同步是怎么设的？" -f $q, $total) `
        -Options @('不限帧，也没开垂直同步', '锁了 60 帧（或别的固定值）', '开了垂直同步', '不清楚')

    $q++
    $a.fullscreen = Ask-Question -Id 'fullscreen' -Title ("第 {0}/{1} 题  游戏是哪种全屏方式？" -f $q, $total) `
        -Options @('独占全屏', '窗口化 / 无边框窗口', '不清楚')

    $deviceDefault = 1
    if ($Sys -and $Sys.isLaptop) {
        $deviceDefault = 2
        if ($Sys.battery -and $Sys.battery.onAc -eq $false) { $deviceDefault = 3 }
    }
    $q++
    $a.device = Ask-Question -Id 'device' -Title ("第 {0}/{1} 题  你平时怎么玩？" -f $q, $total) `
        -Options @('台式机', '笔记本，插着电源玩', '笔记本，用电池玩') -DefaultIndex $deviceDefault

    $netDefault = 1
    if ($Sys -and $Sys.network) {
        if ($Sys.network.wirelessUp -and -not $Sys.network.wiredUp) { $netDefault = 3 }
        elseif ($Sys.network.wiredUp) { $netDefault = 2 }
    }
    $q++
    $a.network = Ask-Question -Id 'network' -Title ("第 {0}/{1} 题  玩这个游戏时是联网玩还是单机？走有线还是无线？" -f $q, $total) `
        -Options @('单机，不联机', '联机，走网线', '联机，走 Wi-Fi') -DefaultIndex $netDefault

    $q++
    $a.recording = Ask-Question -Id 'recording' -Title ("第 {0}/{1} 题  你会录屏、直播，或者用带叠加层的工具吗？" -f $q, $total) `
        -Options @('都不会', '偶尔录一下 / 开个帧数显示之类的叠加层', '经常录屏或直播')

    $q++
    $a.gpuPanel = Ask-Question -Id 'gpuPanel' -Title ("第 {0}/{1} 题  显卡控制面板（NVIDIA 控制面板 / AMD Software）里的设置你调过吗？" -f $q, $total) `
        -Options @('没调过 / 不清楚', '按"性能优先"调过', '调成了"质量优先"或省电')

    $q++
    $a.risk = Ask-Question -Id 'risk' -Title ("第 {0}/{1} 题  你能接受多大范围的改动？" -f $q, $total) `
        -Hint '建议先选 1：只做零风险的，效果不够下次再来做第 2 步' `
        -Options @('只做零风险的改动（推荐）', '允许需要管理员权限的改动（改注册表开关 / 电源计划）',
                   '也允许需要降低一点系统安全性的改动（会明确告知代价）')

    $pathDefault = ''
    if ($Sys -and $Sys.game -and $Sys.game.installPath) { $pathDefault = "$($Sys.game.installPath)" }
    $q++
    $a.gamePath = Ask-Question -Id 'gamePath' -Title ("第 {0}/{1} 题  游戏装在哪个文件夹？（不知道就直接回车）" -f $q, $total) `
        -Text -DefaultText $pathDefault -Hint '用来判断是装在固态还是机械硬盘' -Optional

    return $a
}

function Show-Answers {
    param([hashtable]$A)
    $sx = $A.symptoms
    if ($sx -is [array]) { $sx = ($sx -join ' / ') }
    $nameText = '（未填写）'
    if ($A.gameName) { $nameText = "$($A.gameName)" }
    $pathText = '（未提供）'
    if ($A.gamePath) { $pathText = "$($A.gamePath)" }

    Write-Step '你的回答'
    Write-Host ("  游戏            : " + $nameText)
    Write-Host ("  主要症状        : " + $sx)
    Write-Host ("  卡顿场景        : " + $A.scene)
    Write-Host ("  分辨率          : " + $A.resolution)
    Write-Host ("  画质档          : " + $A.preset)
    Write-Host ("  帧率/垂直同步   : " + $A.frameCap)
    Write-Host ("  全屏方式        : " + $A.fullscreen)
    Write-Host ("  设备            : " + $A.device)
    Write-Host ("  网络            : " + $A.network)
    Write-Host ("  录制/叠加层     : " + $A.recording)
    Write-Host ("  显卡控制面板    : " + $A.gpuPanel)
    Write-Host ("  可接受的改动    : " + $A.risk)
    Write-Host ("  游戏路径        : " + $pathText)
}

# ---------------------------------------------------------------------------
# 改动项清单：只有这里列出的项才可能被写进优化脚本
# 每一项都必须可回滚；有安全代价的项放在 Risky 后面，默认不执行。
# ---------------------------------------------------------------------------
$script:TweakCatalog = [ordered]@{
    POWER_PLAN_HIGH  = [ordered]@{
        Title = '电源计划切换为高性能/卓越性能'; Risk = '低'; Admin = $true; Reboot = $false; Risky = $false
        Benefit = 'CPU 频率更稳，减少降频导致的掉帧（笔记本插电时收益更明显）'
        Revert = '切换回原来的电源计划（脚本已记录原计划并一键还原）'
    }
    GAME_MODE        = [ordered]@{
        Title = '打开 Windows 游戏模式'; Risk = '低'; Admin = $false; Reboot = $false; Risky = $false
        Benefit = '游戏运行时减少后台程序的干扰，掉帧略减少'
        Revert = '改回原来的开关状态'
    }
    GAME_DVR_OFF     = [ordered]@{
        Title = '关闭游戏 DVR / 后台录制'; Risk = '低'; Admin = $false; Reboot = $false; Risky = $false
        Benefit = '去掉后台录制的叠加层开销，减少掉帧'
        Revert = '改回原来的开关状态（需要录屏时也可以手动打开）'
    }
    GPU_PREF_HIGH    = [ordered]@{
        Title = '把游戏指定为"高性能"GPU'; Risk = '低'; Admin = $false; Reboot = $false; Risky = $false
        Benefit = '避免笔记本把游戏交给核显跑（这类问题一改就是几十帧的差距）'
        Revert = '删掉这条指定，回到系统自动选择'
    }
    GAME_PRIORITY    = [ordered]@{
        Title = '提高游戏进程优先级'; Risk = '低'; Admin = $false; Reboot = $false; Risky = $false
        Benefit = '游戏运行时更少被后台程序抢占 CPU'
        Revert = '关掉游戏就自动恢复，无需处理'
    }
    FAST_STARTUP_OFF = [ordered]@{
        Title = '关闭快速启动'; Risk = '低'; Admin = $true; Reboot = $false; Risky = $false
        Benefit = '避免关机后残留驱动/外设状态导致的小毛病；开机略慢一两秒'
        Revert = '改回原来的开关状态'
    }
    HAGS_ON          = [ordered]@{
        Title = '开启硬件加速 GPU 计划（HAGS）'; Risk = '中'; Admin = $true; Reboot = $true; Risky = $false
        Benefit = '部分游戏帧生成更顺、延迟略降（少数驱动组合下反而更差，所以可以一键回滚）'
        Revert = '改回原来的值并重启'
    }
    VBS_OFF          = [ordered]@{
        Title = '关闭基于虚拟化的安全性 / 内存完整性'; Risk = '高'; Admin = $true; Reboot = $true; Risky = $true
        Benefit = '部分游戏能多出 5%~10% 帧数'
        Revert = '改回原来的值并重启'
    }
}

function Add-Finding {
    param($List, [string]$Title, [string]$Conclusion, [string]$Evidence, [int]$Severity = 2)
    foreach ($f in $List) { if ($f.title -eq $Title) { return } }
    if ($null -eq $script:FindingSeq) { $script:FindingSeq = 0 }
    $script:FindingSeq++
    # seq 用于同severity时的稳定排序：先出现的（硬件/驱动/磁盘）排在前面
    $List.Add([ordered]@{ title = $Title; conclusion = $Conclusion; evidence = $Evidence; severity = $Severity; seq = $script:FindingSeq }) | Out-Null
}

function Add-Tweak {
    param($List, [string]$Id, [string]$Reason, [int]$Priority = 2)
    foreach ($t in $List) { if ($t.id -eq $Id) { return } }
    $List.Add([ordered]@{ id = $Id; reason = $Reason; priority = $Priority }) | Out-Null
}

function Add-Manual {
    param($List, [string]$Title, [string]$Detail, [int]$Priority = 2, [string]$SettingsUri = '')
    foreach ($m in $List) { if ($m.title -eq $Title) { return } }
    $List.Add([ordered]@{ title = $Title; detail = $Detail; priority = $Priority; uri = $SettingsUri }) | Out-Null
}

function Get-DriveLetterOfPath {
    param([string]$Path)
    if (-not $Path) { return $null }
    if ($Path -match '^([A-Za-z]):') { return $Matches[1].ToUpperInvariant() }
    return $null
}

function Invoke-Diagnosis {
    param($Sys, [hashtable]$A)

    $findings = New-Object 'System.Collections.Generic.List[object]'
    $tweaks   = New-Object 'System.Collections.Generic.List[object]'
    $manual   = New-Object 'System.Collections.Generic.List[object]'
    $avoid    = New-Object 'System.Collections.Generic.List[string]'
    $unknown  = New-Object 'System.Collections.Generic.List[string]'
    $script:FindingSeq = 0

    # ---- 先把采集到的数据整理成好用的变量 -------------------------------
    $gpus = @($Sys.gpus)
    $discrete = @($gpus | Where-Object { $_.tier -ne 'integrated' -and $_.tier -ne 'basic' -and $_.tier -ne 'unknown' })
    $integrated = @($gpus | Where-Object { $_.tier -eq 'integrated' })
    $tierRank = @{ 'integrated' = 1; 'basic' = 0; 'low' = 2; 'mid' = 3; 'high' = 4; 'unknown' = 0 }
    $bestTier = 'unknown'
    $bestRank = -1
    foreach ($g in $gpus) {
        $r = 0
        if ($tierRank.ContainsKey("$($g.tier)")) { $r = $tierRank["$($g.tier)"] }
        if ($r -gt $bestRank) { $bestRank = $r; $bestTier = "$($g.tier)" }
    }
    $bestGpuName = ''
    foreach ($g in $gpus) { if ("$($g.tier)" -eq $bestTier) { $bestGpuName = "$($g.name)"; break } }

    $ramTotal = $null
    if ($Sys.computer -and $Sys.computer.totalRamGB) { $ramTotal = [double]$Sys.computer.totalRamGB }
    elseif ($Sys.os -and $Sys.os.totalRamGB) { $ramTotal = [double]$Sys.os.totalRamGB }
    $ramFree = $null
    if ($Sys.os -and $Sys.os.freeRamGB) { $ramFree = [double]$Sys.os.freeRamGB }
    $ramFreePct = $null
    if ($ramTotal -and $ramFree -ne $null -and $ramTotal -gt 0) { $ramFreePct = [math]::Round(100 * $ramFree / $ramTotal, 1) }

    $sysDriveLetter = "$env:SystemDrive".TrimEnd(':').ToUpperInvariant()
    $sysVolume = $null
    foreach ($v in @($Sys.volumes)) { if ("$($v.drive)" -eq $sysDriveLetter) { $sysVolume = $v; break } }

    $gamePath = "$($A.gamePath)"
    if (-not $gamePath -and $Sys.game -and $Sys.game.installPath) { $gamePath = "$($Sys.game.installPath)" }
    $gameDriveLetter = Get-DriveLetterOfPath -Path $gamePath
    $gameVolume = $null
    foreach ($v in @($Sys.volumes)) { if ("$($v.drive)" -eq $gameDriveLetter) { $gameVolume = $v; break } }
    $gameMedia = $null
    if ($gameDriveLetter -and $Sys.driveMedia -and $Sys.driveMedia.ContainsKey($gameDriveLetter)) {
        $gameMedia = $Sys.driveMedia[$gameDriveLetter]
    }

    $sx = ''
    if ($A.symptoms -is [array]) { $sx = ($A.symptoms -join ' ') } else { $sx = "$($A.symptoms)" }
    $hasLowFps    = $sx -like '*帧数整体偏低*'
    $hasStutter   = $sx -like '*掉帧卡顿*'
    $hasSlowLoad  = $sx -like '*加载慢*'
    $hasInputLag  = $sx -like '*手感迟滞*'
    $hasNetLag    = $sx -like '*网络延迟*'
    $hasHeat      = $sx -like '*发热高*'
    $hasCrash     = $sx -like '*闪退*'

    $presetHigh   = ($A.preset -like '*高*' -and $A.preset -notlike '*不清楚*') -or $A.preset -like '*极高*'
    $presetUltra  = $A.preset -like '*极高*'
    $res4k        = $A.resolution -like '*4K*'
    $res2k        = $A.resolution -like '*2K*'
    $resHigh      = $res4k -or $res2k
    $vsyncOn      = $A.frameCap -like '*垂直同步*'
    $framelocked60 = $A.frameCap -like '*锁了 60*'
    $windowed     = $A.fullscreen -like '*窗口*'
    $onBattery    = $A.device -like '*电池*'
    $isLaptopLike = $A.device -like '*笔记本*'
    $onWifi       = $A.network -like '*Wi-Fi*'
    $onlineGame   = -not ($A.network -like '*单机*')
    $neverRecord  = $A.recording -like '*都不会*'
    $gpuPanelPerf = $A.gpuPanel -like '*性能优先*'
    $gpuPanelQual = $A.gpuPanel -like '*质量优先*' -or $A.gpuPanel -like '*省电*'

    $riskLevel = 2
    if ($A.risk -like '*只做零风险*') { $riskLevel = 1 }
    elseif ($A.risk -like '*安全性*') { $riskLevel = 3 }

    # ---- 一、显卡与画质档是否匹配 ---------------------------------------
    if ($gpus.Count -eq 0) {
        $unknown.Add('没能读到显卡信息，显卡相关的判断只能靠你手动确认') | Out-Null
    } elseif ($bestTier -eq 'integrated' -or $bestTier -eq 'basic') {
        Add-Finding -List $findings -Severity 3 -Title '显卡：只有核显/集成显卡' `
            -Conclusion '这台机器没有独立显卡（或独显没被识别）。现代 3D 游戏帧数低是硬件上限决定的，优化只能让帧数更稳一些，不会变成本质上的流畅。最有效的办法是降画质档、降分辨率、开超分（FSR/XeSS）。' `
            -Evidence ("显卡：" + (($gpus | ForEach-Object { $_.name }) -join '、'))
    } elseif ($presetUltra -and ($bestTier -eq 'low' -or $bestTier -eq 'mid')) {
        Add-Finding -List $findings -Severity 3 -Title '画质档明显高于显卡能力' `
            -Conclusion '显卡属于中低档，游戏却开到了极高/光追全开，这是帧数低最直接的原因。降档的收益远大于任何系统设置调整。' `
            -Evidence ("显卡：" + $bestGpuName + "；游戏内画质：" + $A.preset)
        Add-Manual -List $manual -Priority 1 -Title '把画质档降到显卡吃得下的水平' `
            -Detail '建议：纹理/阴影/体积云/光线追踪 这几项往下降两档，也可以换成厂商预设里的"中"或"平衡"。降完进游戏看帧数，一档一档试到自己满意为止。'
    } elseif ($res4k -and $bestTier -ne 'high') {
        Add-Finding -List $findings -Severity 3 -Title '4K 分辨率超出显卡能力' `
            -Conclusion '非高端显卡跑 4K 很吃力。开到超分辨率（DLSS/FSR/XeSS）的"性能"档，或把渲染分辨率降到 2K，通常是帧数提升最大的一步。' `
            -Evidence ("显卡：" + $bestGpuName + "；分辨率：" + $A.resolution)
        Add-Manual -List $manual -Priority 1 -Title '开超分或降低渲染分辨率' `
            -Detail '优先用游戏里的 DLSS / FSR / XeSS，开"性能"档；游戏没有超分功能，就把分辨率降到 2560x1440 或 1920x1080。'
    } elseif ($presetHigh -and $bestTier -eq 'low') {
        Add-Finding -List $findings -Severity 2 -Title '画质档偏高' `
            -Conclusion '入门级显卡配高画质档，帧数会一直贴着下限走，建议降一到两档换取稳定帧数。' `
            -Evidence ("显卡：" + $bestGpuName + "；游戏内画质：" + $A.preset)
        Add-Manual -List $manual -Priority 2 -Title '画质档往下调一到两档' `
            -Detail '优先降：阴影、体积云、光线追踪、后处理；纹理和模型细节可以保留。'
    }

    # ---- 二、显卡驱动 ------------------------------------------------
    foreach ($g in $gpus) {
        if ($g.name -like '*Basic Display*') { continue }
        $age = $null
        if ($g.driverAgeMonths -ne $null) { $age = [double]$g.driverAgeMonths }
        if ($age -ne $null -and $age -gt 12) {
            Add-Finding -List $findings -Severity 3 -Title '显卡驱动太旧' `
                -Conclusion '驱动版本已经一年多没更新了。更新显卡驱动是所有办法里收益最大、最稳的一步，建议优先做。' `
                -Evidence ("{0}：驱动 {1}（{2}，约 {3} 个月前）" -f $g.name, $g.driverVersion, $g.driverDate, [math]::Round($age, 0))
            Add-Manual -List $manual -Priority 1 -Title '更新显卡驱动' `
                -Detail 'NVIDIA 用户装 NVIDIA App，AMD 用户装 AMD Software，Intel 核显装 Intel 驱动助理，在里面点"检查更新"。装完重启一次再测帧数。笔记本也可以直接去品牌官网下载对应机型的驱动。'
            break
        } elseif ($age -ne $null -and $age -gt 6) {
            Add-Manual -List $manual -Priority 2 -Title '显卡驱动可以顺手更新一下' `
                -Detail ("{0} 的驱动是 {1} 的，距今约 {2} 个月。如果玩的是最近出的新游戏，更新驱动通常能直接改善帧数和崩溃问题。" -f $g.name, $g.driverDate, [math]::Round($age, 0))
            break
        }
    }

    # ---- 三、游戏是否跑在核显上（双显卡笔记本） -------------------------
    if ($discrete.Count -ge 1 -and $integrated.Count -ge 1) {
        $pref = "$($Sys.game.gpuPreference)"
        if ($pref -notlike '*2*') {
            $exeKnown = $false
            if ($gamePath -and $gamePath.ToLower().EndsWith('.exe')) { $exeKnown = $true }
            if ($exeKnown) {
                Add-Tweak -List $tweaks -Id 'GPU_PREF_HIGH' -Priority 2 `
                    -Reason '这台机器有独显也有核显，游戏目前没有被指定用"高性能"GPU。系统有可能把游戏交给核显跑（这是掉帧里最常见也最容易被忽略的一条）。'
            } else {
                Add-Manual -List $manual -Priority 2 -Title '确认游戏用的是独显' `
                    -Detail '设置 → 系统 → 屏幕 → 显示卡 → 找到这个游戏的 exe → 选项 → 选"高性能"。如果游戏已经被系统交给核显跑，这一步的收益会非常大。' `
                    -SettingsUri 'ms-settings:display-advancedgraphics'
            }
        }
    }

    # ---- 四、显卡控制面板 ---------------------------------------------
    if ($gpuPanelQual) {
        Add-Manual -List $manual -Priority 2 -Title '把显卡控制面板改回性能优先' `
            -Detail 'NVIDIA 控制面板 → 管理 3D 设置 → 电源管理模式改成"最高性能优先"，低延迟模式开"超高"；AMD Software 里把"等待垂直刷新"设为"始终关闭"。被设成质量优先或省电时显卡会主动降频。'
    } elseif ($gpuPanelPerf) {
        Add-Finding -List $findings -Severity 1 -Title '显卡控制面板已按性能优先设置' `
            -Conclusion '这一项已经是优化状态，不用再动。' `
            -Evidence '用户确认：显卡控制面板按性能优先调过'
    }

    # ---- 五、内存 ------------------------------------------------------
    if ($ramTotal -and $ramTotal -le 8) {
        Add-Finding -List $findings -Severity 2 -Title ('内存偏小（{0} GB）' -f $ramTotal) `
            -Conclusion '现在的大型游戏 8GB 内存会比较紧张，容易出现切图卡顿和掉帧。玩之前把浏览器、聊天软件等占内存的程序关掉能明显缓解；如果主板有空槽，加一条内存是最划算的升级。' `
            -Evidence ('物理内存合计 {0} GB' -f $ramTotal)
    }
    if ($ramFreePct -ne $null -and $ramFreePct -lt 15) {
        Add-Finding -List $findings -Severity 3 -Title ('内存占用偏高（剩余 {0}%）' -f $ramFreePct) `
            -Conclusion '内存快满了，系统会开始频繁读写页面文件，表现就是玩一会儿突然一顿。' `
            -Evidence ('采集时剩余内存 {0} GB / 共 {1} GB' -f $ramFree, $ramTotal)
    }

    $hogs = @($Sys.background.matchedHogs)
    $hogNames = @($hogs | Select-Object -First 6 | ForEach-Object { $_.label })
    $hogBig = $false
    if ($hogs.Count -ge 1 -and [int]$hogs[0].memoryMB -ge 500) { $hogBig = $true }
    if ($hogs.Count -ge 2 -or $hogBig) {
        $hogText = ($hogs | Select-Object -First 6 | ForEach-Object {
            $pc = 1
            if ($_.procCount) { $pc = [int]$_.procCount }
            '{0}（约 {1} MB，{2} 个进程）' -f $_.label, $_.memoryMB, $pc
        }) -join '、'
        Add-Finding -List $findings -Severity 2 -Title '后台程序占着内存和 CPU' `
            -Conclusion '这些程序正在后台运行，其中浏览器、网盘同步、动态壁纸、游戏平台叠加层是最常见的掉帧来源。玩之前关掉它们是最省事的优化。' `
            -Evidence $hogText
        Add-Manual -List $manual -Priority 1 -Title '玩之前关掉后台程序' `
            -Detail ('重点关：' + (($hogNames | Select-Object -First 5) -join '、') + '。动态壁纸（Wallpaper Engine 之类）在游戏时一定要暂停或退出；浏览器标签页也是内存大户。')
    }

    $secApps = @($Sys.background.securityApps)
    if ($secApps.Count -ge 1) {
        Add-Finding -List $findings -Severity 2 -Title '第三方安全软件在后台运行' `
            -Conclusion '这类软件会做实时扫描，游戏读盘时容易被它们打断，表现就是莫名其妙的卡顿。建议玩游戏时先退出（不是卸载）。' `
            -Evidence ('正在运行：' + ($secApps -join '、'))
        Add-Manual -List $manual -Priority 2 -Title '玩游戏时先退出第三方安全软件' `
            -Detail ('在托盘里退出：' + ($secApps -join '、') + '。注意：Windows 自带的 Defender 不用关，也不建议关。')
    }

    # ---- 六、磁盘 ------------------------------------------------------
    if ($gameMedia -and "$($gameMedia.mediaType)" -match '(?i)HDD|Unspecified' -and "$($gameMedia.mediaType)" -notmatch '(?i)SSD') {
        Add-Finding -List $findings -Severity 3 -Title ('游戏装在机械硬盘上（{0} 盘）' -f $gameDriveLetter) `
            -Conclusion '机械硬盘的随机读取慢，是"加载慢、进图卡、走两步一顿"的最常见原因。把游戏挪到固态硬盘（SSD）通常比任何系统设置都有效。' `
            -Evidence ("{0} 盘：{1}，类型 {2}" -f $gameDriveLetter, $gameMedia.model, $gameMedia.mediaType)
        Add-Manual -List $manual -Priority 1 -Title '把游戏移到固态硬盘（SSD）' `
            -Detail 'Steam/Epic 都支持"移动游戏安装目录"，不用重新下载。做完这一步，加载和进图会有肉眼可见的变化。'
    } elseif ($gameMedia -and "$($gameMedia.mediaType)" -match '(?i)SSD') {
        Add-Finding -List $findings -Severity 1 -Title ('游戏所在的盘是固态（{0} 盘）' -f $gameDriveLetter) `
            -Conclusion '这块不是瓶颈，加载慢的原因要从内存或后台占用上找。' `
            -Evidence ("{0} 盘：{1}（{2}）" -f $gameDriveLetter, $gameMedia.model, $gameMedia.busType)
    } else {
        $unknown.Add('没能判断游戏装在固态还是机械硬盘——如果你知道游戏的安装文件夹，重新运行一次并在最后一题里填上路径，就能判断了') | Out-Null
    }

    foreach ($v in @($Sys.volumes)) {
        if ($v.freePercent -eq $null) { continue }
        if ([double]$v.freePercent -lt 10) {
            Add-Finding -List $findings -Severity 2 -Title ('{0} 盘快满了（剩余 {1}%）' -f $v.drive, $v.freePercent) `
                -Conclusion '磁盘剩下的空间太少时，系统写入会变慢，游戏加载和存档都会受影响。' `
                -Evidence ('{0} 盘剩余 {1} GB / 共 {2} GB' -f $v.drive, $v.freeGB, $v.sizeGB)
            Add-Manual -List $manual -Priority 2 -Title ('清理 {0} 盘，留出至少 15% 的空余空间' -f $v.drive) `
                -Detail '用系统自带的"存储感知"和"磁盘清理"先清一遍，重点看下载文件夹、回收站、以及游戏平台里没在玩的游戏。'
        }
    }

    if ($Sys.disks) {
        foreach ($d in @($Sys.disks)) {
            if ("$($d.health)" -and "$($d.health)" -ne 'Healthy') {
                Add-Finding -List $findings -Severity 3 -Title '硬盘健康状态异常' `
                    -Conclusion '采集到硬盘健康状态不是 Healthy，这可能才是卡顿和卡死的真正原因，建议先备份重要文件再排查硬件。' `
                    -Evidence ('{0}：健康状态 {1}' -f $d.name, $d.health)
            }
        }
    }

    # ---- 七、电源计划 --------------------------------------------------
    $planGuid = ''
    if ($Sys.power -and "$($Sys.power.planGuid)") {
        $planGuid = "$($Sys.power.planGuid)".ToLowerInvariant()
    } elseif ($Sys.power -and "$($Sys.power.activePlan)" -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
        $planGuid = $Matches[1].ToLowerInvariant()
    }
    $planRaw = ''
    if ($Sys.power -and "$($Sys.power.planName)") { $planRaw = "$($Sys.power.planName)" }
    if (-not $planRaw) { $planRaw = $planGuid }

    $planName = '未知'
    if ($planGuid -eq '381b4222-f694-41f0-9685-ff5bb260df2e') { $planName = '平衡' }
    elseif ($planGuid -eq '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c') { $planName = '高性能' }
    elseif ($planGuid -eq 'e9a42b02-d5df-448d-aa00-03f14749eb61') { $planName = '卓越性能' }
    elseif ($planGuid -eq 'a1841308-3541-4fab-bc81-f71556f20b4a') { $planName = '节能' }
    # 厂商自定义计划（联想"野兽模式"、华硕性能模式之类）不在标准 GUID 表里，按名字猜
    if ($planName -eq '未知' -and $planRaw) {
        if ($planRaw -match '性能|野兽|狂暴|超能|疾速|Turbo|Performance|Ultimate') { $planName = '高性能' }
        elseif ($planRaw -match '节能|省电|环保|Saver|Eco') { $planName = '节能' }
        elseif ($planRaw -match '平衡|安静|静音|标准|Balanced|Quiet|Silent|Cool') { $planName = '平衡' }
    }

    $procMax = $null
    if ($Sys.power -and $Sys.power.procMaxAc -ne $null) { $procMax = [int]$Sys.power.procMaxAc }

    if ($procMax -ne $null -and $procMax -lt 100) {
        Add-Finding -List $findings -Severity 3 -Title ('电源计划把 CPU 最大状态限制在 {0}%' -f $procMax) `
            -Conclusion ('当前计划"{0}"没给 CPU 放权：最高只能跑到 {1}%。这属于"不是硬件不行，是被限着"这一类问题，改完立刻能看出差别。' -f $planRaw, $procMax) `
            -Evidence ('电源计划：{0}；处理器最大状态：{1}%' -f $planRaw, $procMax)
        Add-Tweak -List $tweaks -Id 'POWER_PLAN_HIGH' -Priority 2 `
            -Reason ('当前电源计划"{0}"把 CPU 最大状态限制在 {1}%，切到高性能可以让它放开跑。' -f $planRaw, $procMax)
        if ($planName -eq '平衡' -or $planName -eq '节能') {
            Add-Manual -List $manual -Priority 2 -Title '在厂商工具里切到性能模式' `
                -Detail ('"{0}"这类计划通常是笔记本厂商自带的。除了改 Windows 电源计划，更直接的办法是打开厂商的性能控制台（联想拯救者空间 / 华硕奥创 / 惠普 OMEN Gaming Hub / 戴尔外星人控制中心），把性能模式切到"性能"或"野兽/狂暴"。' -f $planRaw)
        }
    } elseif ($planName -eq '节能') {
        Add-Finding -List $findings -Severity 3 -Title '电源计划是"节能"' `
            -Conclusion '节能计划会让 CPU 主动降频，游戏里表现就是"一直上不去"。换成高性能是纯收益，代价只是耗电和发热略增。' `
            -Evidence ('当前电源计划：{0}' -f $planRaw)
        Add-Tweak -List $tweaks -Id 'POWER_PLAN_HIGH' -Priority 2 `
            -Reason '当前是节能电源计划，CPU 会主动降频省电，切到高性能可以让频率更稳定。'
    } elseif ($planName -eq '平衡') {
        if ($hasStutter -or $hasLowFps) {
            Add-Finding -List $findings -Severity 2 -Title ('电源计划是"{0}"' -f $planRaw) `
                -Conclusion '平衡计划在负载波动时会压一压频率。换成高性能可以让帧数更稳一些（代价是耗电和发热略增）。' `
                -Evidence ('当前电源计划：{0}' -f $planRaw)
            Add-Tweak -List $tweaks -Id 'POWER_PLAN_HIGH' -Priority 3 `
                -Reason ('当前是"{0}"计划，负载波动时会压频率，切到高性能可以让帧数更稳。' -f $planRaw)
        }
    } elseif ($planName -eq '高性能' -or $planName -eq '卓越性能') {
        $detail = '这一项没问题，不用改。'
        if ($procMax -ne $null) { $detail = ('这一项没问题：处理器最大状态已经是 {0}%。' -f $procMax) }
        Add-Finding -List $findings -Severity 1 -Title ('电源计划已经是"{0}"' -f $planRaw) `
            -Conclusion $detail -Evidence ('当前电源计划：{0}' -f $planRaw)
    } else {
        $unknown.Add(('没能识别当前电源计划"{0}"的性能档位，可以在控制面板-电源选项里自己看一眼，或者用厂商的性能控制台切到性能模式' -f $planRaw)) | Out-Null
    }

    if ($onBattery) {
        Add-Finding -List $findings -Severity 3 -Title '笔记本在用电池玩' `
            -Conclusion '用电池时系统会强制压低 CPU 和显卡功耗，帧数会掉一大截。插上电源是最有效的一步。' `
            -Evidence '用户确认：用电池玩'
        Add-Manual -List $manual -Priority 1 -Title '插上电源再玩' `
            -Detail '插电后在厂商工具里（联想的拯救者空间、华硕奥创、惠普 OMEN Gaming Hub 等）把性能模式设为"性能/狂暴"，同时确认电源计划是高性能。' `
            -SettingsUri 'powercfg.cpl'
    } elseif ($isLaptopLike) {
        Add-Manual -List $manual -Priority 2 -Title '确认笔记本在性能模式、且插着电' `
            -Detail '厂商自带的性能控制台（联想/华硕/惠普/戴尔）里通常有"安静/平衡/性能"三档，玩大型游戏时选性能档；同时确认插座是接着的。' `
            -SettingsUri 'powercfg.cpl'
    }

    if ($Sys.computer -and $Sys.computer.automaticManagedPagefile -eq $false) {
        Add-Manual -List $manual -Priority 2 -Title '把虚拟内存改回"由系统管理"' `
            -Detail '这台机器的虚拟内存被手动设置过。手动设小会导致内存不足时直接卡死，建议改回系统托管：系统属性 → 高级 → 性能设置 → 高级 → 虚拟内存 → 更改 → 勾选"自动管理所有驱动器的分页文件大小"。'
    }

    # ---- 八、刷新率 -----------------------------------------------------
    $hzNow = $Sys.display.currentHz
    $hzMax = $Sys.display.maxHz
    if ($hzNow -and $hzMax -and [int]$hzMax -gt [int]$hzNow) {
        Add-Finding -List $findings -Severity 3 -Title ('显示器刷新率没开到最高（现在 {0}Hz，支持 {1}Hz）' -f $hzNow, $hzMax) `
            -Conclusion '如果你觉得"帧数上不去、画面不够顺"，很可能只是刷新率被锁在 60Hz 了。这一项几乎零成本、收益直接。' `
            -Evidence ('当前 {0}Hz，显示器支持的刷新率里有 {1}Hz' -f $hzNow, $hzMax)
        Add-Manual -List $manual -Priority 1 -Title ('把刷新率调到 {0}Hz' -f $hzMax) `
            -Detail '右键桌面 → 显示设置 → 高级显示设置 → 选择刷新率 → 选最高的那个。调完屏幕会黑一下，属于正常现象。' `
            -SettingsUri 'ms-settings:display-advanced'
    } elseif ($hzNow -and $hzNow -ge 100) {
        Add-Finding -List $findings -Severity 1 -Title ('刷新率已经是 {0}Hz' -f $hzNow) `
            -Conclusion '这一项没问题。' -Evidence ('当前刷新率 {0}Hz' -f $hzNow)
    } elseif (-not $hzMax) {
        $unknown.Add('没能读到显示器支持的刷新率列表，请自己右键桌面-显示设置-高级显示设置，确认刷新率是不是开到了最高') | Out-Null
    }

    # ---- 九、输入延迟 / 帧生成 ------------------------------------------
    if ($hasInputLag -or $vsyncOn -or $windowed) {
        $bits = New-Object 'System.Collections.Generic.List[string]'
        if ($vsyncOn) { $bits.Add('开了垂直同步') | Out-Null }
        if ($windowed) { $bits.Add('用的是窗口化/无边框窗口') | Out-Null }
        if ($framelocked60) { $bits.Add('帧率锁在 60') | Out-Null }
        if ($bits.Count -gt 0) {
            Add-Finding -List $findings -Severity 2 -Title '设置上存在额外的操作延迟' `
                -Conclusion '垂直同步、窗口化模式、锁帧这几项加起来会让"鼠标转视角"感觉更黏。如果你在意手感，把它们放开是关键。' `
                -Evidence ('当前：' + ($bits -join '，'))
            Add-Manual -List $manual -Priority 2 -Title '调整帧率与全屏设置来降低延迟' `
                -Detail '优先顺序：① 改成独占全屏；② 关掉垂直同步，改用驱动或游戏自带的帧率上限（比显示器刷新率低 3~5 帧）；③ 显示器支持 G-Sync/FreeSync 的话把它打开，这样不锁帧也不会撕裂。'
        }
    }

    # ---- 十、发热与散热 ------------------------------------------------
    $thermalOk = $false
    $maxTemp = $null
    if ($Sys.thermal) {
        foreach ($t in @($Sys.thermal)) {
            if ($t.temperatureC -eq $null) { continue }
            $thermalOk = $true
            if ($maxTemp -eq $null -or [double]$t.temperatureC -gt [double]$maxTemp) { $maxTemp = [double]$t.temperatureC }
        }
    }
    if ($thermalOk -and $maxTemp -ne $null -and $maxTemp -ge 80) {
        Add-Finding -List $findings -Severity 3 -Title ('温度偏高（{0} 摄氏度）' -f $maxTemp) `
            -Conclusion '温度高的时候 CPU/显卡会自动降频，表现就是玩十分钟后开始卡。先解决散热，别的优化才有意义。' `
            -Evidence ('采集到最高温度 {0} 摄氏度' -f $maxTemp)
        Add-Manual -List $manual -Priority 1 -Title '改善散热' `
            -Detail '笔记本：垫高机身或用散热底座，别放在床上；确认风扇出风口没被挡住。台式机：清一下灰尘。用了两年以上的话，可以考虑重新涂硅脂（这一步建议找会弄的人做）。' `
    } elseif (-not $thermalOk) {
        $unknown.Add('温度读不到（大多数主板和笔记本不开放这个接口），需要你自己感受：如果玩十几分钟后明显变卡、风扇狂转，那就是散热问题') | Out-Null
    }
    if ($hasHeat) {
        Add-Manual -List $manual -Priority 2 -Title '监控温度，确认是不是热到降频' `
            -Detail '装一个 HWiNFO64 之类的工具，玩游戏时看 CPU/GPU 温度：持续超过 90 度基本就是在降频了。也可以直接在游戏里开帧数显示，观察是不是"开局流畅、十分钟后掉"。'
    }

    # ---- 十一、网络 ----------------------------------------------------
    if ($onlineGame -and $onWifi) {
        Add-Finding -List $findings -Severity 3 -Title '联机游戏走的是 Wi-Fi' `
            -Conclusion 'Wi-Fi 受干扰和隔墙影响，延迟会波动、偶尔丢包，表现就是"瞬移、技能放不出来"。接网线是解决延迟最稳的一步。' `
            -Evidence '用户确认：联机游戏走 Wi-Fi'
        Add-Manual -List $manual -Priority 1 -Title '联机游戏尽量接网线' `
            -Detail '实在拉不了网线，退一步用电力猫或 5GHz 频段的 Wi-Fi（2.4GHz 干扰大），并确保路由器离电脑近、中间不要有墙。'
    } elseif ($onlineGame -and $Sys.network -and $Sys.network.wirelessUp -and -not $Sys.network.wiredUp -and $hasNetLag) {
        Add-Manual -List $manual -Priority 2 -Title '联机时优先走有线' `
            -Detail '采集到的网卡里只有无线在工作。如果延迟高、丢包，接一根网线是最直接的排查方式。'
    }

    # ---- 十二、系统开关（可脚本化的小改动） ------------------------------
    $recordingOn = ("$($Sys.graphics.gameDvrEnabled)" -eq '1') -or ("$($Sys.graphics.appCaptureEnabled)" -eq '1')
    if ($recordingOn -and $neverRecord) {
        Add-Finding -List $findings -Severity 2 -Title '后台录制/游戏录制是开着的' `
            -Conclusion 'Windows 的游戏录制会在后台持续编码，占用显存和磁盘。你又说自己从不录屏，那就关掉。' `
            -Evidence ('GameDVR_Enabled={0}，AppCaptureEnabled={1}' -f $Sys.graphics.gameDvrEnabled, $Sys.graphics.appCaptureEnabled)
        Add-Tweak -List $tweaks -Id 'GAME_DVR_OFF' -Priority 2 `
            -Reason '系统里的游戏录制/后台捕获是开着的，你又不录屏，关掉能省下显存和磁盘占用。'
    }

    if ("$($Sys.graphics.autoGameModeEnabled)" -ne '1' -and $hogs.Count -ge 2) {
        Add-Tweak -List $tweaks -Id 'GAME_MODE' -Priority 3 `
            -Reason '后台程序比较多，打开游戏模式可以让系统在游戏运行时减少它们的干扰。'
    }

    $build = 0
    if ($Sys.os -and "$($Sys.os.build)") { $build = [int]("$($Sys.os.build)" -replace '\D', '') }
    if ($build -ge 19041 -and $discrete.Count -ge 1 -and $Sys.graphics -and "$($Sys.graphics.hagsHwSchMode)" -ne '2' -and "$($Sys.graphics.hagsHwSchMode)" -ne '') {
        Add-Tweak -List $tweaks -Id 'HAGS_ON' -Priority 3 `
            -Reason '你的系统版本和显卡都支持硬件加速 GPU 计划，它有独立显卡时通常值得打开（个别驱动组合下可能变差，脚本支持一键还原）。'
    }

    if ("$($Sys.power.fastStartupEnabled)" -eq '1' -and ($hasCrash -or $hasInputLag -or $hasStutter)) {
        Add-Tweak -List $tweaks -Id 'FAST_STARTUP_OFF' -Priority 3 `
            -Reason '快速启动会让驱动和外设状态在关机后残留，你反映的卡顿/手感异常有可能是它引起的，关掉后重启一次状态更干净。'
    }

    if ($Sys.game -and $Sys.game.running) {
        Add-Tweak -List $tweaks -Id 'GAME_PRIORITY' -Priority 3 `
            -Reason '游戏正在运行，可以直接把它提到高优先级，减少被后台程序抢 CPU 的情况。'
    }

    # ---- 十三、VBS / 内存完整性 -----------------------------------------
    $vbsRunning = $false
    if ($Sys.security -and $Sys.security.deviceGuard) {
        if ("$($Sys.security.deviceGuard.vbsStatus)" -eq '2') { $vbsRunning = $true }
    }
    if ($vbsRunning) {
        if ($riskLevel -ge 3) {
            Add-Finding -List $findings -Severity 2 -Title '系统开启了基于虚拟化的安全性（VBS）' `
                -Conclusion 'VBS / 内存完整性开着会占用一部分 CPU 和内存带宽，部分游戏会因此少 5%~10% 帧数。你选择了允许这类改动，所以脚本里会包含它——但请清楚代价：关掉会降低系统对抗恶意软件的能力。' `
                -Evidence ('DeviceGuard VBS 状态：{0}（2 = 正在运行）' -f $Sys.security.deviceGuard.vbsStatus)
            Add-Tweak -List $tweaks -Id 'VBS_OFF' -Priority 4 `
                -Reason 'VBS 正在运行。这是本次诊断里唯一有安全代价的项，默认不执行，只有在脚本里显式加 -AllowRisky 才会生效。'
        } else {
            $avoid.Add('你的系统开着"内存完整性/VBS"。理论上关掉它能让部分游戏多出 5%~10% 帧数，但代价是降低系统抗攻击能力，所以这次我没有把它写进方案。如果你愿意承担这个代价，重新运行并选择第 3 项。') | Out-Null
        }
    }

    # ---- 十四、重启与开机时间 --------------------------------------------
    $pending = $false
    if ($Sys.pendingReboot) {
        if ($Sys.pendingReboot.windowsUpdateRebootRequired -or $Sys.pendingReboot.componentBasedServicing -or $Sys.pendingReboot.pendingFileRename) { $pending = $true }
    }
    if ($pending) {
        Add-Finding -List $findings -Severity 2 -Title '系统有未完成的重启' `
            -Conclusion '有更新或驱动安装还在等重启，没重启完之前测出来的帧数不准，也可能出现各种异常卡顿。' `
            -Evidence '检测到待重启标记'
        Add-Manual -List $manual -Priority 1 -Title '先重启一次' -Detail '重启完再做优化和测试，否则测出来的数据不可比。'
    } elseif ($Sys.os -and $Sys.os.uptimeHours -ne $null -and [double]$Sys.os.uptimeHours -gt 96) {
        Add-Finding -List $findings -Severity 1 -Title ('这台机器已经开了 {0} 天' -f [math]::Round([double]$Sys.os.uptimeHours / 24, 1)) `
            -Conclusion '长时间不重启会积累内存碎片和残留的后台进程，开机几个小时后再玩游戏容易莫名卡顿。' `
            -Evidence ('已运行 {0} 小时' -f [math]::Round([double]$Sys.os.uptimeHours, 0))
        Add-Manual -List $manual -Priority 3 -Title '玩游戏前重启一次' -Detail '这是零成本、经常有效的一招。'
    }

    # ---- 十五、启动项与 CPU ---------------------------------------------
    $startupCount = @($Sys.startupItems).Count
    if ($startupCount -ge 10) {
        Add-Finding -List $findings -Severity 1 -Title ('开机启动项偏多（{0} 项）' -f $startupCount) `
            -Conclusion '启动项本身不一定直接影响游戏，但它们往往和后台常驻程序是同一批，值得清一遍。' `
            -Evidence ('开机启动项 {0} 项' -f $startupCount)
        Add-Manual -List $manual -Priority 3 -Title '清理开机启动项' `
            -Detail '任务管理器 → 启动应用，把不认识、不需要开机就跑的项禁用掉（可以随时重新启用，不会卸载程序）。' `
            -SettingsUri 'ms-settings:startupapps'
    }

    if ($Sys.cpu) {
        if ($Sys.cpu.cores -ne $null -and [int]$Sys.cpu.cores -le 2) {
            Add-Finding -List $findings -Severity 2 -Title 'CPU 核心数偏少' `
                -Conclusion '双核 CPU 跑现代游戏会比较吃力，尤其在团战和复杂场景。优化能改善稳定性，但硬件的天花板在这。' `
                -Evidence ('{0}，{1} 核 {2} 线程' -f $Sys.cpu.name, $Sys.cpu.cores, $Sys.cpu.threads)
        }
        if ($Sys.cpu.loadPercent -ne $null -and [int]$Sys.cpu.loadPercent -ge 60) {
            Add-Finding -List $findings -Severity 2 -Title ('采集时 CPU 占用已经 {0}%' -f $Sys.cpu.loadPercent) `
                -Conclusion '还没开游戏 CPU 就已经占用很高了，说明后台有东西在忙。开游戏前把它们关掉。' `
                -Evidence ('CPU 当前负载 {0}%' -f $Sys.cpu.loadPercent)
        }
    }

    # ---- 十六、反面清单（与本次相关的才列出来） ---------------------------
    $avoid.Add('不要装网上的"一键优化"注册表包、内存清理工具或第三方"游戏加速器"，这些要么没收益、要么把系统改乱，出问题很难回滚。') | Out-Null
    $avoid.Add('不要关闭 Windows Defender 的实时保护，也不要关闭 Windows 更新，安全上的代价远大于性能收益。') | Out-Null
    $avoid.Add('不要批量禁用系统服务（SysMain、搜索索引、遥测服务之类），现在的 Windows 上收益极小，副作用明显。') | Out-Null
    $avoid.Add('不要对反作弊进程做任何注入、挂起或修改，除了封号没有任何好处。') | Out-Null
    $avoid.Add('不要清理"预读文件"、删除系统缓存目录、关闭页面文件，这些都没有持续收益。') | Out-Null
    $avoid.Add('超频、改电压、改 BIOS 不在本次方案内。想折腾的话请用厂商提供的工具，并且一次只改一项。') | Out-Null
    if ($Sys.thermal) {
        $avoid.Add('不要为了降温把风扇转速在 BIOS 里调到最高后就不管——噪音和寿命问题不值得，先解决风道和灰尘。') | Out-Null
    }

    # ---- 十七、按风险等级筛选改动项 ---------------------------------------
    $selected = New-Object 'System.Collections.Generic.List[object]'
    $skipped  = New-Object 'System.Collections.Generic.List[object]'
    foreach ($t in @($tweaks | Sort-Object { $_['priority'] })) {
        $cat = $script:TweakCatalog[$t.id]
        if ($null -eq $cat) { continue }
        if ($cat.Risky -and $riskLevel -lt 3) { $skipped.Add($t) | Out-Null; continue }
        if ($cat.Admin -and $riskLevel -lt 2) { $skipped.Add($t) | Out-Null; continue }
        $selected.Add([ordered]@{ id = $t.id; reason = $t.reason; priority = $t.priority; title = $cat.Title }) | Out-Null
    }
    if ($selected.Count -gt 8) {
        $selected = @($selected | Select-Object -First 8)
    }

    # ---- 一句话结论 -------------------------------------------------------
    # 影响程度优先；同档按出现的先后（硬件/驱动/磁盘在前，外围因素在后）
    $sortedFindings = @($findings | Sort-Object -Property @{ Expression = { $_['severity'] }; Descending = $true }, @{ Expression = { $_['seq'] }; Descending = $false })
    $sortedManual   = @($manual | Sort-Object { $_['priority'] })
    $summaryBits = New-Object 'System.Collections.Generic.List[string]'
    if ($sortedFindings.Count -ge 1) {
        $summaryBits.Add(('最可能的主因是「{0}」' -f $sortedFindings[0].title)) | Out-Null
    } else {
        $summaryBits.Add('这次没采集到明显的问题项') | Out-Null
    }
    if ($sortedFindings.Count -ge 2) {
        $summaryBits.Add(('其次是「{0}」' -f $sortedFindings[1].title)) | Out-Null
    }
    if ($sortedManual.Count -ge 1) {
        $summaryBits.Add(('第一个该动手做的是：{0}' -f $sortedManual[0].title)) | Out-Null
    }
    if ($selected.Count -ge 1) {
        $summaryBits.Add(('另有 {0} 项已经写进自动优化脚本，默认只预演、可一键回滚' -f $selected.Count)) | Out-Null
    } else {
        $summaryBits.Add('这次没有需要脚本代劳的开关类改动') | Out-Null
    }
    $summary = ($summaryBits -join '；') + '。'

    return [ordered]@{
        summary   = $summary
        findings  = $sortedFindings
        tweaks    = [object[]]$selected
        skipped   = [object[]]$skipped
        manual    = $sortedManual
        avoid     = @($avoid)
        unknown   = @($unknown)
        riskLevel = $riskLevel
        planName  = $planName
    }
}

# ---------------------------------------------------------------------------
# 报告
# ---------------------------------------------------------------------------
function Get-SafeFileName {
    param([string]$Name, [string]$Fallback = '游戏')
    if (-not $Name) { return $Fallback }
    $n = $Name
    foreach ($c in [System.IO.Path]::GetInvalidFileNameChars()) { $n = $n.Replace($c, '_') }
    $n = $n.Trim()
    if ($n.Length -eq 0) { return $Fallback }
    if ($n.Length -gt 40) { $n = $n.Substring(0, 40) }
    return $n
}

function Format-Severity {
    param([int]$Severity)
    if ($Severity -ge 3) { return '高' }
    if ($Severity -eq 2) { return '中' }
    return '低'
}

function New-Report {
    param($Sys, [hashtable]$A, $Diag, [string]$Stamp, [string]$SystemJsonPath)

    $lines = New-Object 'System.Collections.Generic.List[string]'
    $add = { param([string]$t) $lines.Add($t) | Out-Null }

    $gameLabel = "$($A.gameName)"
    if (-not $gameLabel) { $gameLabel = '未命名游戏' }
    $machine = '未知机型'
    if ($Sys.computer) { $machine = ("{0} {1}" -f $Sys.computer.manufacturer, $Sys.computer.model).Trim() }

    & $add ("# {0} 性能诊断报告" -f $gameLabel)
    & $add ''
    & $add ("诊断时间：{0}" -f $Sys.generatedAt)
    & $add ("机器：{0}" -f $machine)

    $cpuText = 'CPU 未知'
    if ($Sys.cpu) { $cpuText = "$($Sys.cpu.name)" }
    $gpuText = '显卡 未知'
    if (@($Sys.gpus).Count -gt 0) { $gpuText = ((@($Sys.gpus) | ForEach-Object { $_.name }) -join ' + ') }
    $ramText = '内存 未知'
    if ($Sys.computer -and $Sys.computer.totalRamGB) { $ramText = "$($Sys.computer.totalRamGB) GB" }
    & $add ("主要配置：{0} / {1} / {2}" -f $cpuText, $gpuText, $ramText)
    & $add '采集方式：本机只读采集（未修改任何设置）+ 你回答的游戏侧信息'
    & $add ''
    & $add '> 一句话结论：' + $Diag.summary
    & $add ''

    # 一、机器与游戏现状
    & $add '## 一、机器与游戏现状'
    & $add ''
    & $add '| 项目 | 现状 |'
    & $add '|---|---|'
    $formText = '台式机'
    if ($Sys.isLaptop) { $formText = '笔记本' }
    if ($Sys.battery) {
        if ($Sys.battery.onAc -eq $true) { $formText = $formText + '（采集时接着电源）' }
        elseif ($Sys.battery.onAc -eq $false) { $formText = $formText + '（采集时用电池）' }
    }
    & $add ("| 系统 | {0}（内部版本 {1}） |" -f $Sys.os.caption, $Sys.os.build)
    & $add ("| 形态 | {0} |" -f $formText)
    & $add ("| CPU | {0}（{1} 核 {2} 线程） |" -f $Sys.cpu.name, $Sys.cpu.cores, $Sys.cpu.threads)
    foreach ($g in @($Sys.gpus)) {
        & $add ("| 显卡 | {0}，驱动 {1}（{2}），显存 {3} GB |" -f $g.name, $g.driverVersion, $g.driverDate, $g.vramGB)
    }
    foreach ($m in @($Sys.memoryModules)) {
        & $add ("| 内存 | {0}：{1} GB，{2} MHz（实际 {3} MHz） |" -f $m.slot, $m.capacityGB, $m.ratedMHz, $m.runningMHz)
    }
    foreach ($d in @($Sys.disks)) {
        & $add ("| 硬盘 | {0}：{1} GB，类型 {2}，接口 {3}，健康 {4} |" -f $d.name, $d.sizeGB, $d.mediaType, $d.busType, $d.health)
    }
    foreach ($v in @($Sys.volumes)) {
        & $add ("| 分区 {0} | 剩余 {1} GB / 共 {2} GB（{3}%） |" -f $v.drive, $v.freeGB, $v.sizeGB, $v.freePercent)
    }
    $planText = '未能读取'
    if ($Sys.power) {
        if ("$($Sys.power.planName)") { $planText = "$($Sys.power.planName)" }
        elseif ("$($Sys.power.planGuid)") { $planText = "$($Sys.power.planGuid)" }
        if ($Sys.power.procMaxAc -ne $null) { $planText = $planText + ('，CPU 最大状态 {0}%' -f $Sys.power.procMaxAc) }
    }
    & $add ("| 电源计划 | {0} |" -f $planText)
    $dispText = ('{0}x{1} @ {2}Hz' -f $Sys.display.currentW, $Sys.display.currentH, $Sys.display.currentHz)
    if ($Sys.display.maxHz -and $Sys.display.currentHz -and [int]$Sys.display.maxHz -gt [int]$Sys.display.currentHz) {
        $dispText = $dispText + ('，显示器支持最高 {0}Hz（建议调到最高）' -f $Sys.display.maxHz)
    }
    & $add ("| 显示器 | {0} |" -f $dispText)
    & $add ("| 游戏模式 | {0} |" -f (Format-OnOff -Value $Sys.graphics.autoGameModeEnabled))
    & $add ("| 后台录制 DVR | {0} |" -f (Format-OnOff -Value $Sys.graphics.gameDvrEnabled))
    & $add ("| 硬件加速 GPU 计划 | {0} |" -f (Format-Hags -Value $Sys.graphics.hagsHwSchMode))
    & $add ("| 快速启动 | {0} |" -f (Format-OnOff -Value $Sys.power.fastStartupEnabled))
    & $add ("| 内核隔离/VBS | {0} |" -f (Format-Vbs -Sys $Sys))
    & $add ("| 上次开机 | {0}（已运行 {1} 小时） |" -f $Sys.os.lastBoot, $Sys.os.uptimeHours)
    & $add ''

    # 二、游戏侧设置
    & $add '## 二、游戏侧设置'
    & $add ''
    & $add '（这一节全部来自你的回答，程序读不到游戏内部设置）'
    & $add ''
    & $add ("- 分辨率：{0}" -f $A.resolution)
    & $add ("- 画质档：{0}" -f $A.preset)
    & $add ("- 帧率上限 / 垂直同步：{0}" -f $A.frameCap)
    & $add ("- 全屏方式：{0}" -f $A.fullscreen)
    & $add ("- 显卡控制面板：{0}" -f $A.gpuPanel)
    & $add ("- 设备：{0}" -f $A.device)
    & $add ("- 网络：{0}" -f $A.network)
    & $add ("- 录制/叠加层：{0}" -f $A.recording)
    if ($A.gamePath) { & $add ("- 游戏路径：{0}" -f $A.gamePath) }
    & $add ''

    # 三、症状与实测
    & $add '## 三、症状与实测'
    & $add ''
    $sxList = $A.symptoms
    if ($sxList -isnot [array]) { $sxList = @($sxList) }
    & $add '你描述的症状：'
    foreach ($s in $sxList) { & $add ("- {0}" -f $s) }
    & $add ("- 最容易卡在：{0}" -f $A.scene)
    & $add ''
    & $add '本机能测到的数据：'
    & $add ("- 采集时 CPU 负载 {0}%，空闲内存 {1} GB / {2} GB" -f $Sys.cpu.loadPercent, $Sys.os.freeRamGB, $Sys.os.totalRamGB)
    & $add ("- 后台进程 {0} 个" -f $Sys.background.processCount)
    & $add ("- 开机启动项 {0} 项" -f (@($Sys.startupItems).Count))
    & $add ''

    # 四、瓶颈判断
    & $add '## 四、瓶颈判断'
    & $add ''
    if (@($Diag.findings).Count -eq 0) {
        & $add '这次采集没有发现明显的问题项。可以参考第五节的建议，或者补充更多症状描述后再测一次。'
    } else {
        $i = 0
        foreach ($f in @($Diag.findings)) {
            $i++
            & $add ("### {0}. {1}（影响程度：{2}）" -f $i, $f.title, (Format-Severity -Severity $f.severity))
            & $add ''
            & $add ("**判断：** {0}" -f $f.conclusion)
            & $add ''
            & $add ("**依据：** {0}" -f $f.evidence)
            & $add ''
        }
    }

    # 五、优化清单
    & $add '## 五、优化清单（按收益/风险排序）'
    & $add ''
    & $add '### 5.1 脚本可以自动完成的（每一行都能一键回滚）'
    & $add ''
    if (@($Diag.tweaks).Count -eq 0) {
        & $add '这次没有需要脚本代劳的项，做好下面的手动步骤就够了。'
        & $add ''
    } else {
        & $add '| 序号 | 改动 | 预期收益 | 风险 | 需要管理员 | 需要重启 | 回滚方式 |'
        & $add '|---|---|---|---|---|---|---|'
        $i = 0
        foreach ($t in @($Diag.tweaks)) {
            $i++
            $cat = $script:TweakCatalog[$t.id]
            $adminText = '否'
            if ($cat.Admin) { $adminText = '是' }
            $rebootText = '否'
            if ($cat.Reboot) { $rebootText = '是' }
            & $add ("| {0} | {1} | {2} | {3} | {4} | {5} | {6} |" -f $i, $cat.Title, $cat.Benefit, $cat.Risk, $adminText, $rebootText, $cat.Revert)
        }
        & $add ''
        & $add '为什么是这几项：'
        $i = 0
        foreach ($t in @($Diag.tweaks)) {
            $i++
            $cat = $script:TweakCatalog[$t.id]
            & $add ("- 第 {0} 项（{1}）：{2}" -f $i, $cat.Title, $t.reason)
        }
        & $add ''
    }

    if (@($Diag.skipped).Count -gt 0) {
        & $add '### 5.2 按你的选择被暂时跳过的'
        & $add ''
        & $add '你选择了较小的改动范围，下面这几项与本次症状相关，但被排除了。想要的话，重新运行一次，在最后一题里放宽范围即可。'
        & $add ''
        foreach ($t in @($Diag.skipped)) {
            $cat = $script:TweakCatalog[$t.id]
            $why = '需要管理员权限'
            if ($cat.Risky) { $why = '需要降低系统安全性' }
            & $add ("- {0}（跳过原因：{1}；收益：{2}）" -f $cat.Title, $why, $cat.Benefit)
        }
        & $add ''
    }

    & $add '### 5.3 需要你手动做的（脚本不会替你做）'
    & $add ''
    if (@($Diag.manual).Count -eq 0) {
        & $add '这次没有额外的手动步骤。'
    } else {
        $i = 0
        foreach ($m in @($Diag.manual)) {
            $i++
            & $add ("{0}. **{1}**" -f $i, $m.title)
            & $add ("   {0}" -f $m.detail)
        }
    }
    & $add ''

    # 六、不建议做的
    & $add '## 六、不建议做的'
    & $add ''
    foreach ($x in @($Diag.avoid)) { & $add ("- {0}" -f $x) }
    & $add ''

    # 七、脚本使用说明
    & $add '## 七、怎么用这份方案'
    & $add ''
    & $add '生成的优化脚本默认是"只看不改"：直接运行它不会动任何设置，只会把计划打印出来。'
    & $add ''
    & $add '1. 先预演（不改任何东西）：双击 `3-预演不改动.bat`，看清楚列出来的项目；'
    & $add '2. 确认无误再真正应用：双击 `4-真正应用优化.bat`；'
    & $add '3. 觉得不对劲就回滚：双击 `5-一键回滚.bat`，或者主目录里的 `3-一键回滚.bat`。'
    & $add ''
    & $add ('应用前会先把每个开关的原值记到日志里（' + 'optimize-logs 文件夹' + '），回滚就是照着日志还原。')
    & $add ''

    # 八、未能确认的
    & $add '## 八、未能确认的项'
    & $add ''
    if (@($Diag.unknown).Count -eq 0) {
        & $add '这次采集覆盖到了所有需要的项。'
    } else {
        foreach ($u in @($Diag.unknown)) { & $add ("- {0}" -f $u) }
    }
    & $add ''
    if (@($Sys.readIssues).Count -gt 0) {
        & $add '读取失败的项（这些项按"没有数据"处理，不代表设置不存在）：'
        & $add ''
        foreach ($r in @($Sys.readIssues)) { & $add ("- {0}" -f $r) }
        & $add ''
    }
    & $add '---'
    & $add ''
    & $add ('原始采集数据：`{0}`' -f $SystemJsonPath)
    & $add ''

    return ($lines -join "`r`n")
}

function Format-OnOff {
    param($Value)
    if ("$Value" -eq '1') { return '已开启' }
    if ("$Value" -eq '0') { return '已关闭' }
    return '未设置（按默认状态算）'
}

function Format-Hags {
    param($Value)
    if ("$Value" -eq '2') { return '已开启' }
    if ("$Value" -eq '1') { return '已关闭' }
    if ("$Value" -eq '0') { return '已关闭' }
    return '未能读取'
}

function Format-Vbs {
    param($Sys)
    if (-not $Sys.security -or -not $Sys.security.deviceGuard) { return '未能读取' }
    $s = "$($Sys.security.deviceGuard.vbsStatus)"
    if ($s -eq '2') { return '正在运行' }
    if ($s -eq '1') { return '已启用但未运行（需重启）' }
    if ($s -eq '0') { return '未启用' }
    return '未能读取'
}

# @@PART5-END@@
