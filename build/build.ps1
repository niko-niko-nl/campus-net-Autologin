#Requires -Version 5.1
<#
=============================================================================
  build.ps1 —— 把整个项目打包成单文件 CampusNet-Setup.exe
=============================================================================
  做两件事：
    1. 把要发布的脚本 base64 内嵌进 Setup.cs 的载荷占位处
    2. 用系统自带的 csc.exe 编译成 WinForms 单文件 exe（无外部依赖）

  用法：powershell -ExecutionPolicy Bypass -File build.ps1
=============================================================================
#>
[CmdletBinding()]
param(
    [string]$SourceDir,
    [string]$OutFile
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$buildDir = $PSScriptRoot
if (-not $SourceDir) { $SourceDir = Split-Path -Parent $buildDir }
if (-not $OutFile) { $OutFile = Join-Path $SourceDir 'CampusNet-Setup.exe' }

# 打进 exe 里的文件清单（相对路径）
$payloadFiles = @(
    'CampusNet.ps1',
    'install.ps1',
    'install.bat',
    'uninstall.ps1',
    'uninstall.bat',
    'run.bat',
    'run-hidden.vbs',
    'LICENSE',
    'gameguard.default.txt',
    'lib\SrunRsa.ps1',
    'README.md',
    'tools\fix-encoding.ps1',
    'tools\test-rsa.ps1',
    'tools\rsa_ref.js',
    'tools\gameguard-check.ps1',
    'tools\make-icon.ps1',
    'tools\verify-rsa.js'
)

Write-Host '===== 打包 CampusNet-Setup.exe =====' -ForegroundColor Cyan

# ---- 1. 生成载荷 ----
$names = New-Object System.Collections.Generic.List[string]
$datas = New-Object System.Collections.Generic.List[string]

foreach ($rel in $payloadFiles) {
    $full = Join-Path $SourceDir $rel
    if (-not (Test-Path -LiteralPath $full)) {
        throw "缺少文件：$full"
    }
    $bytes = [System.IO.File]::ReadAllBytes($full)
    $names.Add($rel.Replace('\', '/'))
    $datas.Add([Convert]::ToBase64String($bytes))
    Write-Host ("  + {0,-24} {1,8:N0} B" -f $rel, $bytes.Length) -ForegroundColor DarkGray
}

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('public static readonly string[] Files = new string[] {')
[void]$sb.AppendLine('    ' + (($names | ForEach-Object { '"' + $_ + '"' }) -join ', '))
[void]$sb.AppendLine('};')
[void]$sb.AppendLine('public static readonly string[] Data = new string[] {')
foreach ($d in $datas) {
    [void]$sb.AppendLine('    "' + $d + '",')
}
[void]$sb.AppendLine('};')

Write-Host ("载荷总计 {0:N0} B（base64 后 {1:N0} B）" -f ($datas | ForEach-Object { $_.Length } | Measure-Object -Sum).Sum, ($sb.Length)) -ForegroundColor DarkGray

# ---- 2. 注入到 Setup.cs ----
$template = [System.IO.File]::ReadAllText((Join-Path $buildDir 'Setup.cs'), [System.Text.Encoding]::UTF8)
if ($template -notmatch [regex]::Escape('/*__PAYLOAD__*/')) {
    throw 'Setup.cs 里找不到 /*__PAYLOAD__*/ 占位符。'
}
$source = $template -replace [regex]::Escape('/*__PAYLOAD__*/'), $sb.ToString().TrimEnd()

$genCs = Join-Path $buildDir 'Setup.generated.cs'
# 必须带 BOM，否则 csc 会按 ANSI 读中文
[System.IO.File]::WriteAllText($genCs, $source, (New-Object System.Text.UTF8Encoding($true)))
Write-Host "已生成 $genCs" -ForegroundColor DarkGray

# ---- 3. 编译 ----
$csc = @(
    "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
    "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $csc) { throw '找不到 csc.exe（需要 .NET Framework 4.x）。' }
Write-Host "编译器：$csc" -ForegroundColor DarkGray

if (Test-Path -LiteralPath $OutFile) { Remove-Item -LiteralPath $OutFile -Force }

$cscArgs = New-Object System.Collections.Generic.List[string]
$cscArgs.Add('/nologo')
$cscArgs.Add('/target:winexe')
$cscArgs.Add('/platform:anycpu')
$cscArgs.Add('/optimize+')
$cscArgs.Add('/codepage:65001')

$icon = Join-Path $buildDir 'app.ico'
if (-not (Test-Path -LiteralPath $icon)) {
    # 图标生成器放在 tools\ 下（安装程序生成桌面快捷方式图标时也要用它）
    $mk = Join-Path (Split-Path -Parent $buildDir) 'tools\make-icon.ps1'
    if (Test-Path -LiteralPath $mk) {
        Write-Host '生成图标 app.ico …' -ForegroundColor DarkGray
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $mk -OutFile $icon | Out-Null
    }
}
if (Test-Path -LiteralPath $icon) {
    $cscArgs.Add('/win32icon:' + $icon)
    Write-Host "图标：$icon" -ForegroundColor DarkGray
}

$cscArgs.Add("/out:$OutFile")
$cscArgs.Add('/reference:System.dll')
$cscArgs.Add('/reference:System.Drawing.dll')
$cscArgs.Add('/reference:System.Windows.Forms.dll')
$cscArgs.Add('/reference:System.Security.dll')
$cscArgs.Add($genCs)

& $csc $cscArgs.ToArray()
if ($LASTEXITCODE -ne 0) { throw "编译失败，csc 退出码 $LASTEXITCODE" }

$exe = Get-Item -LiteralPath $OutFile
Write-Host ''
Write-Host ("[OK] 已生成 {0}  ({1:N0} B)" -f $exe.FullName, $exe.Length) -ForegroundColor Green
