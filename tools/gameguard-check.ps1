#Requires -Version 5.1
<#
=============================================================================
  gameguard-check.ps1 —— 游戏守护自检
=============================================================================
  作用：告诉你「现在这一刻，游戏守护会不会拦下自动登录」。

  用法：
      1. 先把游戏开起来（进到对局里）
      2. 运行：powershell -ExecutionPolicy Bypass -File gameguard-check.ps1
      3. 如果显示「放行」，说明名单里还缺你那个游戏的进程名，
         把它的名字加进 config.json 的 gameProcesses 即可。

  怎么找游戏进程名：任务管理器 → 详细信息 → 找游戏那一行，看 .exe 前面的名字。
=============================================================================
#>
[CmdletBinding()]
param(
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
if ($root -like '*\tools') { $root = Split-Path -Parent $root }
if (-not $ConfigPath) { $ConfigPath = Join-Path $root 'config.json' }

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

Write-Host ''
Write-Host '===== 游戏守护自检 =====' -ForegroundColor Cyan

# ---- 读配置 ----
if (-not (Test-Path -LiteralPath $ConfigPath)) {
    Write-Host "[X] 找不到配置：$ConfigPath" -ForegroundColor Red
    exit 2
}
$cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json

function Prop($o, $n, $d) {
    $p = @($o.PSObject.Properties | Where-Object { $_.Name -eq $n })
    if ($p.Count -gt 0 -and $null -ne $p[0].Value) { return $p[0].Value }
    return $d
}

$guard = [bool](Prop $cfg 'gameGuard' $true)
$games = @(Prop $cfg 'gameProcesses' @())

Write-Host "守护开关    : $(if ($guard) { '已启用' } else { '已关闭（永远不会拦）' })"
Write-Host "监控进程数  : $($games.Count)"

$lst = Join-Path $root 'gameguard.lst'
Write-Host "VBS 名单文件: $(if (Test-Path $lst) { '存在（第一层拦截生效中）' } else { '不存在（第一层不会拦，只走 PS 层）' })"
Write-Host ''

if (-not $guard) { Write-Host '守护已关闭，结论：放行。' -ForegroundColor Yellow; exit 0 }
if ($games.Count -eq 0) { Write-Host '名单为空，结论：放行。' -ForegroundColor Yellow; exit 0 }

# ---- 比对正在运行的进程 ----
$watch = @{}
foreach ($g in $games) {
    $k = ([string]$g).Trim().ToLowerInvariant()
    if ($k -like '*.exe') { $k = $k.Substring(0, $k.Length - 4) }
    if ($k) { $watch[$k] = $true }
}

$hits = New-Object System.Collections.Generic.List[string]
foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
    $n = ''
    try { $n = $p.ProcessName.ToLowerInvariant() } catch { continue }
    if ($n -and $watch.ContainsKey($n) -and -not $hits.Contains($n)) { $hits.Add($n) }
}

Write-Host '当前会命中的进程：' -ForegroundColor White
if ($hits.Count -eq 0) {
    Write-Host '  （无）' -ForegroundColor DarkGray
} else {
    $hits | ForEach-Object { Write-Host "  * $_" -ForegroundColor Yellow }
}

Write-Host ''
if ($hits.Count -gt 0) {
    Write-Host '结论：会拦截。游戏运行期间不会启动 PowerShell、不做任何网络请求。' -ForegroundColor Green
    Write-Host '      （所以玩游戏时如果掉线，需要自己手动登录或等游戏结束）' -ForegroundColor DarkGray
} else {
    Write-Host '结论：放行。' -ForegroundColor Yellow
    Write-Host '      如果你此刻正在游戏里，说明名单缺了你这个游戏的进程名。' -ForegroundColor DarkGray
    Write-Host '      去任务管理器 → 详细信息，找游戏那一行，把 .exe 前面的名字加进 config.json 的 gameProcesses。' -ForegroundColor DarkGray
}

Write-Host ''
Write-Host '最近 8 条游戏守护记录：' -ForegroundColor White
$log = Join-Path $root 'login.log'
if (Test-Path $log) {
    $lines = @(Get-Content $log -Encoding UTF8 | Where-Object { $_ -match 'game guard|游戏守护' })
    if ($lines.Count -gt 0) {
        $lines | Select-Object -Last 8 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
    } else {
        Write-Host '  （暂无拦截记录）' -ForegroundColor DarkGray
    }
}
Write-Host ''
