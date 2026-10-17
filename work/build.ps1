<#
    把 work\src 和 work\assets 组装成可以直接发给别人的成品：
      outputs\游戏优化助手\
      outputs\游戏优化助手.zip

    组装时统一处理编码：
      .ps1 / .txt / .md  -> UTF-8 with BOM（Windows PowerShell 5.1 读中文才不会出错）
      .bat               -> UTF-8 without BOM（内容本来就是纯 ASCII）
      所有文本统一 CRLF 换行
#>
[CmdletBinding()]
param(
    [string]$Root
)

$ErrorActionPreference = 'Stop'
if (-not $Root) {
    # 默认取本脚本所在目录的上一级作为仓库根目录，这样在别人电脑上也能直接跑
    if ($PSScriptRoot) { $Root = (Split-Path -Parent $PSScriptRoot) } else { $Root = (Get-Location).Path }
}
$srcDir = Join-Path $Root 'work\src'
if (-not (Test-Path -LiteralPath $srcDir)) {
    throw ('没找到源码目录：{0}。请把本脚本放在仓库的 work 目录下，或用 -Root 指定仓库根目录。' -f $srcDir)
}
$assetDir = Join-Path $Root 'work\assets'
$outRoot = Join-Path $Root 'outputs'
$appDir = Join-Path $outRoot '游戏优化助手'
$zipPath = Join-Path $outRoot '游戏优化助手.zip'

function Read-Source {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "缺少源文件：$Path" }
    # 必须显式按 UTF-8 读：源文件是 UTF-8（无 BOM），用默认编码读会变成乱码。
    $text = Get-Content -Raw -LiteralPath $Path -Encoding UTF8
    if ($null -eq $text) { return '' }
    return $text.TrimStart([char]0xFEFF)
}

function Normalize-Newlines {
    param([string]$Text)
    return $Text.Replace("`r`n", "`n").Replace("`n", "`r`n")
}

function Write-Encoded {
    param([string]$Path, [string]$Text, [bool]$Bom = $true)
    $dir = [System.IO.Path]::GetDirectoryName($Path)
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $enc = New-Object System.Text.UTF8Encoding($Bom)
    [System.IO.File]::WriteAllText($Path, $Text, $enc)
    Write-Host ("  wrote {0}  ({1} chars, bom={2})" -f (Split-Path -Leaf $Path), $Text.Length, $Bom)
}

Write-Host 'Building...'
if (Test-Path -LiteralPath $appDir) { Remove-Item -LiteralPath $appDir -Recurse -Force }
New-Item -ItemType Directory -Path $appDir -Force | Out-Null

# 1. 引擎 = 三个源文件按顺序拼接（param 块必须排在最前面）
$parts = @('GameOptimize.ps1', 'GameOptimize.extra.ps1', 'GameOptimize.monitor.ps1', 'GameOptimize.extra2.ps1')
$engine = ''
foreach ($p in $parts) {
    $text = Read-Source -Path (Join-Path $srcDir $p)
    $engine = $engine + (Normalize-Newlines $text)
}
Write-Encoded -Path (Join-Path $appDir 'GameOptimize.ps1') -Text $engine -Bom $true

# 1b. 语法自检：解析不过就立刻失败，别把坏文件发出去
$parseErrors = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $appDir 'GameOptimize.ps1'), [ref]$null, [ref]$parseErrors)
if ($parseErrors -and $parseErrors.Count -gt 0) {
    foreach ($e in $parseErrors) {
        Write-Host ("  SYNTAX ERROR line {0} col {1}: {2}" -f $e.Extent.StartLineNumber, $e.Extent.StartColumnNumber, $e.Message) -ForegroundColor Red
    }
    throw ('GameOptimize.ps1 有 {0} 处语法错误，已停止打包。' -f $parseErrors.Count)
}
Write-Host '  syntax check passed (engine parses clean)'

# 2. 静态资源
foreach ($name in @('使用说明.txt', 'PreGame.ps1')) {
    $text = Read-Source -Path (Join-Path $assetDir $name)
    Write-Encoded -Path (Join-Path $appDir $name) -Text (Normalize-Newlines $text) -Bom $true
}
foreach ($name in @('1-开始体检.bat', '2-边玩边记录.bat', '3-一键回滚.bat', '4-开游戏前整备.bat')) {
    $text = Read-Source -Path (Join-Path $srcDir $name)
    Write-Encoded -Path (Join-Path $appDir $name) -Text (Normalize-Newlines $text) -Bom $false
}

# 3. 打包
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
Compress-Archive -Path $appDir -DestinationPath $zipPath -CompressionLevel Optimal
Write-Host ''
Write-Host ('Folder : ' + $appDir)
Write-Host ('Zip    : ' + $zipPath)
Get-ChildItem -LiteralPath $appDir | Select-Object Name, Length | Format-Table -AutoSize | Out-String | Write-Host
Write-Host 'Done.'
