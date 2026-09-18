#Requires -Version 5.1
<#
=============================================================================
  uninstall.ps1 —— 卸载校园网自动登录
=============================================================================
  默认：删除计划任务 + 凭据 + 日志，保留程序文件（方便以后再配置）
  加 -Purge：连整个程序目录一起删掉

  用法：
      powershell -ExecutionPolicy Bypass -File uninstall.ps1
      powershell -ExecutionPolicy Bypass -File uninstall.ps1 -Purge
=============================================================================
#>
[CmdletBinding()]
param(
    [string]$TaskName = 'CampusNet-AutoLogin',

    # 要卸载哪个安装目录。留空 = 本脚本所在目录。
    # ⚠️ 显式指定可以避免「在 A 目录跑脚本、却动了 B 目录」这类事故。
    [string]$InstallDir = '',

    [switch]$Quiet,
    [switch]$Purge
)

$ErrorActionPreference = 'Stop'

$root = if ($InstallDir) {
    [Environment]::ExpandEnvironmentVariables($InstallDir)
} else {
    Split-Path -Parent $MyInvocation.MyCommand.Path
}
$configPath = Join-Path $root 'config.json'
$logFile = Join-Path $root 'login.log'

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

Write-Host ''
Write-Host '===== 卸载校园网自动登录 =====' -ForegroundColor Cyan
Write-Host "  目标目录：$root" -ForegroundColor DarkGray

# ---- 1. 删除计划任务 ----
$t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($t) {
    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "[OK] 已删除计划任务：$TaskName" -ForegroundColor Green
    } catch {
        Write-Host "[X] 删除计划任务失败：$($_.Exception.Message)" -ForegroundColor Red
    }
} else {
    Write-Host "[--] 没有找到计划任务 $TaskName" -ForegroundColor DarkGray
}

# ---- 2. 结束可能还在跑的实例 ----
# 只结束计划任务/run-hidden.vbs 拉起的那个（命令行里同时含 CampusNet.ps1 和 -Mode ensure），
# 避免误杀用户自己开的、只是路径里碰巧带 CampusNet.ps1 的 PowerShell 窗口。
$running = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object {
        $_.CommandLine -and
        $_.CommandLine -like '*CampusNet.ps1*' -and
        $_.CommandLine -like '*-Mode ensure*'
    }
foreach ($p in @($running)) {
    try {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop
        Write-Host "[OK] 已结束进程 $($p.ProcessId)" -ForegroundColor Green
    } catch { }
}

# ---- 3. 抹掉凭据和日志 ----
foreach ($f in @($configPath, $logFile, "$logFile.1")) {
    if (Test-Path -LiteralPath $f) {
        Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
        Write-Host "[OK] 已删除 $f" -ForegroundColor Green
    }
}

# ---- 4. 删掉桌面快捷方式 ----
$lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) '校园网自动登录.lnk'
if (Test-Path -LiteralPath $lnk) {
    Remove-Item -LiteralPath $lnk -Force -ErrorAction SilentlyContinue
    Write-Host "[OK] 已删除桌面快捷方式" -ForegroundColor Green
}

# ---- 5. 可选：整个程序目录 ----
if ($Purge) {
    # 脚本自己就在待删目录里，交给一个后台进程稍后删除，避免删到一半失败。
    #
    # 路径不走字符串拼接 —— 目录名里只要有个单引号，拼进 -Command 就会把脚本
    # 撕开（轻则删不掉，重则等于把路径当代码执行）。改成用环境变量传：
    # 子进程继承环境变量，路径怎么长什么样都不会被解析。
    $env:CN_PURGE_DIR = $root
    Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-WindowStyle', 'Hidden', '-Command',
        'Start-Sleep -Milliseconds 900; Remove-Item -LiteralPath $env:CN_PURGE_DIR -Recurse -Force -ErrorAction SilentlyContinue'
    ) | Out-Null

    Write-Host "[OK] 已安排删除整个程序目录：$root（后台执行，约 1 秒完成）" -ForegroundColor Green
} else {
    Write-Host ''
    Write-Host '计划任务、密码和日志都已清除。程序文件保留在：' -ForegroundColor DarkGray
    Write-Host "    $root" -ForegroundColor Gray
    Write-Host '想连程序文件一起删，加 -Purge 再跑一次，或直接删除上面这个文件夹。' -ForegroundColor DarkGray
}

Write-Host ''
