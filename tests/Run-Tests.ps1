# =============================================================================
#  Run-Tests.ps1 —— 跑 Pester 单元测试
# =============================================================================
#  用法：
#      powershell -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
#
#  退出码：0 = 全通过，1 = 有失败，2 = 环境不满足
# =============================================================================
[CmdletBinding()]
param(
    [switch]$Detailed
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$pester = Get-Module -ListAvailable -Name Pester | Sort-Object Version -Descending | Select-Object -First 1
if (-not $pester) {
    Write-Host '[X] 找不到 Pester 模块。' -ForegroundColor Red
    Write-Host '    Windows 10/11 一般自带 3.4.0；没有的话装一个：' -ForegroundColor Gray
    Write-Host '      Install-Module Pester -Scope CurrentUser -Force' -ForegroundColor Gray
    exit 2
}

Write-Host ("使用 Pester {0}" -f $pester.Version) -ForegroundColor DarkGray
Import-Module Pester -ErrorAction Stop

$params = @{
    Path     = $here
    PassThru = $true
}
if ($Detailed) { $params['Show'] = 'All' }

$result = Invoke-Pester @params

Write-Host ''
if ($result.FailedCount -gt 0) {
    Write-Host ("失败 {0} / 通过 {1}" -f $result.FailedCount, $result.PassedCount) -ForegroundColor Red
    exit 1
}
Write-Host ("全部通过（{0} 项）" -f $result.PassedCount) -ForegroundColor Green
exit 0
