#Requires -Version 5.1
<#
=============================================================================
  install.ps1 —— 安装校园网开机自动登录
=============================================================================
  做三件事：
    1. 把你的账号密码写进 config.json（密码用 Windows DPAPI 加密，不存明文）
    2. 跑一次诊断，确认门户协议和你的账号配置对得上
    3. 注册计划任务：登录时自动执行 + 每 5 分钟检查一次掉线重连

  不需要管理员权限（计划任务以当前用户身份、仅在登录状态下运行）。

  用法：
      powershell -ExecutionPolicy Bypass -File install.ps1
      powershell -ExecutionPolicy Bypass -File install.ps1 -IntervalMinutes 3
      powershell -ExecutionPolicy Bypass -File install.ps1 -NoTask   # 只写配置不建任务
=============================================================================
#>
[CmdletBinding()]
param(
    [string]$UserId,
    [System.Security.SecureString]$Password,

    # 明文密码，仅供自动化/无人值守调用。脚本仍只会把 DPAPI 密文写进 config.json。
    # 交互式使用请不要传这个参数，直接让它提示输入更安全。
    [string]$PlainPassword,

    [string]$Service = '',

    # 门户 IP。正常情况下脚本会在未认证时自动从 NAS 重定向里抓到真实门户地址，
    # 这个值只是「抓不到重定向」时的兜底，本校本就是 10.130.128.9。
    [string]$PortalHost = '10.130.128.9',
    [int]$IntervalMinutes = 5,
    [string]$TaskName = 'CampusNet-AutoLogin',
    [switch]$NoTask,
    [switch]$Force,

    # 安装目录。默认 %LOCALAPPDATA%\CampusNet（与本脚本所在位置无关，
    # 所以从「下载」文件夹里双击也能装到稳定位置）
    [string]$InstallDir = '',
    [switch]$NoDeploy,

    # 图形安装器会把 config.json 先写好，然后用这个开关调用本脚本：
    # 跳过所有问答和配置写入，只做诊断 + 注册计划任务
    [switch]$UseExistingConfig,

    # 命令行安装时关闭游戏守护
    [switch]$NoGameGuard,

    # 不在桌面创建快捷方式
    [switch]$NoShortcut
)

# 游戏守护默认名单：只放「游戏启动时才出现」的进程。
# 常驻进程（如腾讯 ACE-Tray）故意不列入，否则守护会一直生效、自动登录等于被关掉。
$DefaultGameProcesses = @(
    'SGuard64', 'SGuardSvc64', 'ACE-Guard Client', 'ACE-BASE',
    'valorant', 'cs2', 'csgo', 'dota2',
    'LeagueClient', 'LeagueClientUx',
    'r5apex', 'r5apex_dx12',
    'TslGame', 'NarakaBladepoint',
    'GenshinImpact', 'YuanShen', 'StarRail',
    'Overwatch', 'RainbowSix', 'RainbowSixSiege',
    'RobloxPlayerBeta', 'GTA5', 'RDR2'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$sourceDir = Split-Path -Parent $MyInvocation.MyCommand.Path

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

function Say {
    param([string]$Text, [string]$Color = 'Gray')
    Write-Host $Text -ForegroundColor $Color
}
function Title([string]$T) {
    Write-Host ''
    Write-Host ('=' * 62) -ForegroundColor DarkCyan
    Write-Host "  $T" -ForegroundColor Cyan
    Write-Host ('=' * 62) -ForegroundColor DarkCyan
}

# --------------------------------------------------------------------------
#  桌面快捷方式
#  用处：掉线时想手动登录一次，不用去 %LOCALAPPDATA% 里翻 run.bat
# --------------------------------------------------------------------------
function New-CnDesktopShortcut {
    param(
        [string]$RootDir,
        [string]$LinkName = '校园网自动登录'
    )

    $target = Join-Path $RootDir 'run.bat'
    if (-not (Test-Path -LiteralPath $target)) { return '没找到 run.bat' }

    $desktop = [Environment]::GetFolderPath('Desktop')
    if (-not $desktop -or -not (Test-Path -LiteralPath $desktop)) { return '找不到桌面目录' }
    $link = Join-Path $desktop ($LinkName + '.lnk')

    # 图标：本地生成，仓库里不放二进制
    $icon = Join-Path $RootDir 'app.ico'
    if (-not (Test-Path -LiteralPath $icon)) {
        $mk = Join-Path $RootDir 'tools\make-icon.ps1'
        if (Test-Path -LiteralPath $mk) {
            try {
                & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $mk -OutFile $icon 2>&1 | Out-Null
            } catch { }
        }
    }
    if (-not (Test-Path -LiteralPath $icon)) {
        # 兜底：用 PowerShell 自带图标
        $icon = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    }

    try {
        $ws = New-Object -ComObject WScript.Shell
        $sc = $ws.CreateShortcut($link)
        $sc.TargetPath = $target
        $sc.WorkingDirectory = $RootDir
        $sc.Description = '校园网自动登录 —— 双击立即检查状态并登录一次'
        $sc.IconLocation = "$icon,0"
        $sc.WindowStyle = 1
        $sc.Save()
        return $null    # $null = 成功
    } catch {
        return $_.Exception.Message
    }
}

Title '校园网开机自动登录 —— 安装'

# --------------------------------------------------------------------------
# 0. 自部署
#    从「下载」文件夹里双击也能用：先把整个程序复制到一个稳定目录，
#    之后配置、日志、计划任务全部指向那里。这样你事后删掉下载的压缩包也不会坏。
# --------------------------------------------------------------------------
if (-not $InstallDir) { $InstallDir = Join-Path $env:LOCALAPPDATA 'CampusNet' }
$InstallDir = [Environment]::ExpandEnvironmentVariables($InstallDir)

if (-not $NoDeploy) {
    $sameDir = $false
    try {
        $sameDir = ([IO.Path]::GetFullPath($sourceDir).TrimEnd('\') -ieq [IO.Path]::GetFullPath($InstallDir).TrimEnd('\'))
    } catch { $sameDir = $false }

    if ($sameDir) {
        Say "已在安装目录内运行：$InstallDir" 'DarkGray'
    } else {
        Say "正在安装到：$InstallDir"
        $deployFiles = @(
            'CampusNet.ps1', 'install.ps1', 'install.bat', 'uninstall.ps1', 'uninstall.bat', 'run.bat',
            'run-hidden.vbs', 'README.md', 'LICENSE', 'lib\SrunRsa.ps1',
            'tools\gameguard-check.ps1', 'tools\test-rsa.ps1', 'tools\verify-rsa.js',
            'tools\fix-encoding.ps1', 'tools\make-icon.ps1'
        )
        $copied = 0
        foreach ($f in $deployFiles) {
            $s = Join-Path $sourceDir $f
            if (-not (Test-Path -LiteralPath $s)) { continue }
            $d = Join-Path $InstallDir $f
            $dDir = Split-Path -Parent $d
            if (-not (Test-Path -LiteralPath $dDir)) { New-Item -ItemType Directory -Force -Path $dDir | Out-Null }
            Copy-Item -LiteralPath $s -Destination $d -Force
            # 从网上下载解压出来的文件会带「来自互联网」标记（MOTW），
            # Copy-Item 会把它一起复制过去。解开它，免得以后手工运行脚本被策略拦住。
            try { Unblock-File -LiteralPath $d -ErrorAction SilentlyContinue } catch { }
            $copied++
        }
        if ($copied -eq 0) {
            throw "自部署失败：在 $sourceDir 里没找到任何程序文件。请确认解压完整后再运行。"
        }
        Say "  已复制 $copied 个文件（已解除「来自互联网」标记）" 'DarkGray'
    }
}

# 从这里开始，一切都以安装目录为准
$root = $InstallDir
$configPath = Join-Path $root 'config.json'


# --------------------------------------------------------------------------
# 1. 收集账号密码
# --------------------------------------------------------------------------
# 非交互式环境（计划任务、管道）里 Read-Host 会返回 null，先判断能不能问
$script:CanPrompt = $false
try {
    $script:CanPrompt = [Environment]::UserInteractive -and ($Host.Name -eq 'ConsoleHost')
} catch { $script:CanPrompt = $false }

function Read-Input {
    param([string]$Prompt, [switch]$Secret)
    if (-not $script:CanPrompt) { return $null }
    if ($Secret) { return Read-Host $Prompt -AsSecureString }
    $v = Read-Host $Prompt
    if ($null -eq $v) { return $null }
    return $v.Trim()
}

function Get-Prop {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $p = @($Object.PSObject.Properties | Where-Object { $_.Name -eq $Name })
    if ($p.Count -gt 0 -and $null -ne $p[0].Value) { return $p[0].Value }
    return $Default
}

if ($UseExistingConfig) {
    # 图形界面已经写好 config.json 了，这里只做校验和装任务，不再问账号密码
    if (-not (Test-Path -LiteralPath $configPath)) {
        throw "指定了 -UseExistingConfig，但找不到配置文件：$configPath"
    }
    $cfgNow = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $curUser = [string](Get-Prop $cfgNow 'userId' '')
    $hasPwd = [bool]((Get-Prop $cfgNow 'passwordEncrypted' '') -or (Get-Prop $cfgNow 'password' ''))

    if (-not $curUser) { throw 'config.json 里没有 userId。' }
    if (-not $hasPwd) { throw 'config.json 里没有密码。' }

    Say "使用现有配置：账号 $curUser" 'White'
    $UserId = $curUser
    $writeConfig = $false
} else {

if (-not $UserId) {
    Say '请输入校园网账号（身份证号）：' 'White'
    $UserId = Read-Input '  账号（身份证号）'
}
if (-not $UserId) { throw '账号不能为空。请用 -UserId 参数指定，或交互式运行本脚本。' }

if (-not $Password -and $PlainPassword) {
    $Password = ConvertTo-SecureString $PlainPassword -AsPlainText -Force
}

if (-not $Password) {
    Say '请输入校园网密码（身份证后 6 位；输入时不显示，仅保存在本机）：' 'White'
    $Password = Read-Input '  密码（身份证后 6 位）' -Secret
}
if (-not $Password) { throw '密码不能为空。请用 -PlainPassword 参数指定，或交互式运行本脚本。' }

$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
try {
    if ([string]::IsNullOrEmpty([Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr))) {
        throw '密码不能为空。'
    }
} finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
}

if (-not $PSBoundParameters.ContainsKey('Service')) {
    Say '认证服务名（不知道就直接回车，脚本会自动判断）：' 'White'
    $svc = Read-Input '  服务名'
    if ($svc) { $Service = $svc } else { $Service = '' }
}

$writeConfig = $true
}

# --------------------------------------------------------------------------
# 2. 写配置（密码 DPAPI 加密）
# --------------------------------------------------------------------------
if ($writeConfig) {
    if ((Test-Path -LiteralPath $configPath) -and -not $Force) {
        Say "`n已存在配置文件：$configPath" 'Yellow'
        $ans = Read-Input '覆盖它？(y/N)'
        if (-not $ans) { $ans = '' }
        $ans = $ans.ToLower()
        if ($ans -ne 'y' -and $ans -ne 'yes') { Say '已取消。' 'Yellow'; exit 1 }
    }

    $encrypted = ConvertFrom-SecureString $Password   # DPAPI，绑定当前 Windows 用户

    $config = [ordered]@{
        userId                      = $UserId
        password                    = ''
        passwordEncrypted           = $encrypted
        service                     = $Service
        portalHost                  = $PortalHost
        checkUrls                   = @(
            'http://connect.rom.miui.com/generate_204',
            'http://www.baidu.com'
        )
        # 日志跟着安装目录走，不要写死 %LOCALAPPDATA%，
        # 否则用 -InstallDir 装到别处时会污染默认位置的日志
        logFile                     = (Join-Path $root 'login.log')
        retryCount                  = 5
        retryDelaySec               = 6
        timeoutSec                  = 10
        treatAlreadyOnlineAsSuccess = $true
        gameGuard                   = (-not $NoGameGuard)
        gameProcesses               = $DefaultGameProcesses
    }

    $json = $config | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($configPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    Say "`n[OK] 配置已写入：$configPath" 'Green'
    Say "     密码以 DPAPI 加密存储，换 Windows 用户或改了账户密码后需要重跑本脚本。" 'DarkGray'
    if ($NoGameGuard) {
        Say '     游戏守护：已关闭' 'DarkGray'
    } else {
        Say "     游戏守护：已启用，监控 $($DefaultGameProcesses.Count) 个进程名" 'DarkGray'
    }
    # 顺手同步给 VBS 启动器（它读纯文本，不解析 JSON）
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'CampusNet.ps1') -Mode status -Quiet 2>&1 | Out-Null
}

# --------------------------------------------------------------------------
# 3. 诊断
# --------------------------------------------------------------------------
Title '连接诊断'

$script = Join-Path $root 'CampusNet.ps1'
Say '正在检测门户协议、抓取公钥、试算登录报文（不会真的登录）...' 'DarkGray'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script -Mode test
$testCode = $LASTEXITCODE

if ($testCode -eq 0) {
    Say "`n[OK] 诊断通过。" 'Green'
} else {
    Say "`n[!] 诊断未完全通过（退出码 $testCode）。" 'Yellow'
    Say '    如果当前本来就已联网，"抓不到门户地址"是正常现象。' 'DarkGray'
    Say "    详细日志：$env:LOCALAPPDATA\CampusNet\login.log" 'DarkGray'
}

# --------------------------------------------------------------------------
# 4. 注册计划任务
# --------------------------------------------------------------------------
if ($NoTask) {
    Say "`n已跳过计划任务创建（-NoTask）。手动运行方式：" 'Yellow'
    Say "  powershell -ExecutionPolicy Bypass -File `"$script`" -Mode ensure" 'White'
    exit 0
}

Title '注册计划任务'

$vbs = Join-Path $root 'run-hidden.vbs'
if (-not (Test-Path -LiteralPath $vbs)) {
    Say "找不到 $vbs，跳过计划任务。" 'Yellow'
    exit 1
}

$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing) {
    Say "已存在同名任务，先删除旧的。" 'DarkGray'
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

# 用 wscript 跑 VBS，再由 VBS 静默拉起 PowerShell —— 避免每 5 分钟闪一次黑框
$action = New-ScheduledTaskAction -Execute 'wscript.exe' `
    -Argument ('//B "{0}"' -f $vbs) `
    -WorkingDirectory $root

# 触发器 1：登录后 20 秒（等 Wi-Fi 连上）
$trigLogon = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$trigLogon.Delay = 'PT20S'

# 触发器 2：立刻开始，每 N 分钟一次，长期重复（掉线自愈）
$trigRepeat = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) `
    -RepetitionDuration (New-TimeSpan -Days 3650)

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -DontStopOnIdleEnd `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 15) `
    -Hidden

$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
    -LogonType Interactive -RunLevel Limited

try {
    Register-ScheduledTask -TaskName $TaskName -Action $action `
        -Trigger @($trigLogon, $trigRepeat) -Settings $settings -Principal $principal `
        -Description '校园网(深澜 eportal)开机自动登录 / 掉线自动重连' -Force | Out-Null
    Say "[OK] 计划任务已注册：$TaskName" 'Green'
} catch {
    Say "[X] 计划任务注册失败：$($_.Exception.Message)" 'Red'
    Say '    （不建任务也能用，可直接把 CampusNet.ps1 放到启动文件夹）' 'DarkGray'
    exit 1
}

# 回读校验
$t = Get-ScheduledTask -TaskName $TaskName
$info = Get-ScheduledTaskInfo -TaskName $TaskName
Say "     状态：$($t.State)" 'DarkGray'
Say "     触发器：$(($t.Triggers | ForEach-Object { $_.CimClass.CimClassName }) -join ', ')" 'DarkGray'

Title '安装完成'
Say '从现在起：' 'White'
Say '  · 每次登录 Windows 后 20 秒自动认证' 'Gray'
Say "  · 每 $IntervalMinutes 分钟检查一次，掉线会自动重连" 'Gray'

# ---- 桌面快捷方式 ----
if (-not $NoShortcut) {
    $err = New-CnDesktopShortcut -RootDir $root
    if ($null -eq $err) {
        Say "  · 桌面已创建快捷方式「校园网自动登录」，双击可立即检查/登录一次" 'Gray'
    } else {
        Say "  · 桌面快捷方式创建失败（$err），不影响自动登录" 'DarkGray'
    }
}

Say ''
Say '常用命令：' 'White'
Say "  立即测试   powershell -ExecutionPolicy Bypass -File `"$script`" -Mode ensure" 'Gray'
Say "  看状态     powershell -ExecutionPolicy Bypass -File `"$script`" -Mode status" 'Gray'
Say "  看日志     notepad `"$(Join-Path $root 'login.log')`"" 'Gray'
Say "  立即执行任务  Start-ScheduledTask -TaskName $TaskName" 'Gray'
Say "  卸载       powershell -ExecutionPolicy Bypass -File `"$(Join-Path $root 'uninstall.ps1')`"" 'Gray'
Say ''
