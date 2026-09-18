#Requires -Version 5.1
<#
=============================================================================
  CampusNet.ps1 —— 深澜 (Srun) eportal 校园网开机自动登录
=============================================================================
  适用：门户地址形如  http://<portal>/eportal/index.jsp?wlanuserip=...
        (深澜 Srun / eportal 认证，常见于高校校园网)

  用法：
      powershell -ExecutionPolicy Bypass -File CampusNet.ps1 -Mode ensure
      powershell -ExecutionPolicy Bypass -File CampusNet.ps1 -Mode status
      powershell -ExecutionPolicy Bypass -File CampusNet.ps1 -Mode test

  模式说明：
      ensure  确保在线（默认）。已在线则直接退出；否则抓取门户地址并登录。
              失败会按配置重试，适合放计划任务里周期性跑。
      login   强制走一次登录流程（已在线也会尝试，一般用不到）。
      status  只检测联网状态，不登录。退出码 0=在线，1=离线。
      test    只做诊断：打印配置、探测 Redirect、调用 pageInfo，
              把将要提交的报文展示出来（密码打码），不会真正登录。

  退出码：0 = 在线/成功；1 = 离线/失败；2 = 配置或运行错误
=============================================================================
#>
[CmdletBinding()]
param(
    [ValidateSet('ensure', 'login', 'status', 'test')]
    [string]$Mode = 'ensure',

    [string]$ConfigPath,

    # 手动指定门户地址（平时不用填，脚本会自己在未认证时抓 NAS 重定向）。
    # 形如 http://<门户IP>/eportal/index.jsp?wlanuserip=...&mac=...&nasip=...
    [string]$PortalUrl,

    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$script:ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'

# 控制台中文输出
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch { }

# --------------------------------------------------------------------------
#  日志
# --------------------------------------------------------------------------
function Write-CnLog {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'OK', 'WARN', 'ERROR', 'DEBUG')][string]$Level = 'INFO'
    )
    $line = '{0} [{1,-5}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message

    $color = switch ($Level) {
        'OK' { 'Green' } 'WARN' { 'Yellow' } 'ERROR' { 'Red' } 'DEBUG' { 'DarkGray' } default { 'Gray' }
    }
    if (-not $Quiet) { Write-Host $line -ForegroundColor $color }

    if ($script:LogFile) {
        try {
            $dir = Split-Path -Parent $script:LogFile
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
            # 超过 1MB 轮转一次
            if ((Test-Path -LiteralPath $script:LogFile) -and
                (Get-Item -LiteralPath $script:LogFile).Length -gt 1MB) {
                $bak = "$script:LogFile.1"
                if (Test-Path -LiteralPath $bak) { Remove-Item -LiteralPath $bak -Force }
                Move-Item -LiteralPath $script:LogFile -Destination $bak -Force
            }
            Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8
        } catch { }
    }
}

# --------------------------------------------------------------------------
#  配置
# --------------------------------------------------------------------------
function Get-JsonValue {
    <# 安全取 JSON 字段：字段不存在或为 null 时返回默认值（StrictMode 下也不会炸） #>
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $p = @($Object.PSObject.Properties | Where-Object { $_.Name -eq $Name })
    if ($p.Count -gt 0 -and $null -ne $p[0].Value) { return $p[0].Value }
    return $Default
}

function Get-CnConfig {
    param([string]$Path)

    if (-not $Path) { $Path = Join-Path $script:ScriptDir 'config.json' }
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "找不到配置文件：$Path`n请先运行 install.ps1 生成配置。"
    }

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json

    # 默认值 + 用户配置覆盖
    $defaults = [ordered]@{
        userId                      = ''
        password                    = ''
        passwordEncrypted           = ''
        service                     = ''
        portalHost                  = ''
        checkUrls                   = @('http://connect.rom.miui.com/generate_204', 'http://www.baidu.com')
        logFile                     = '%LOCALAPPDATA%\CampusNet\login.log'
        retryCount                  = 5
        retryDelaySec               = 6
        timeoutSec                  = 10
        treatAlreadyOnlineAsSuccess = $true
        gameGuard                   = $true
        gameProcesses               = @()
    }

    foreach ($k in @($defaults.Keys)) {
        $p = @($raw.PSObject.Properties | Where-Object { $_.Name -eq $k })
        if ($p.Count -gt 0 -and $null -ne $p[0].Value) { $defaults[$k] = $p[0].Value }
    }

    $cfg = [pscustomobject]@{
        userId                      = [string]$defaults['userId']
        password                    = [string]$defaults['password']
        passwordEncrypted           = [string]$defaults['passwordEncrypted']
        service                     = [string]$defaults['service']
        portalHost                  = [string]$defaults['portalHost']
        checkUrls                   = @($defaults['checkUrls'])
        logFile                     = [string]$defaults['logFile']
        retryCount                  = [int]$defaults['retryCount']
        retryDelaySec               = [int]$defaults['retryDelaySec']
        timeoutSec                  = [int]$defaults['timeoutSec']
        treatAlreadyOnlineAsSuccess = [bool]$defaults['treatAlreadyOnlineAsSuccess']
        gameGuard                   = [bool]$defaults['gameGuard']
        gameProcesses               = @($defaults['gameProcesses'])
    }

    if (-not $cfg.checkUrls -or $cfg.checkUrls.Count -eq 0) {
        $cfg.checkUrls = @('http://connect.rom.miui.com/generate_204', 'http://www.baidu.com')
    }
    if ($cfg.retryCount -lt 1) { $cfg.retryCount = 1 }
    if ($cfg.timeoutSec -lt 3) { $cfg.timeoutSec = 3 }

    if (-not $cfg.logFile) { $cfg.logFile = '%LOCALAPPDATA%\CampusNet\login.log' }
    $cfg.logFile = [Environment]::ExpandEnvironmentVariables($cfg.logFile)

    $script:LogFile = $cfg.logFile
    return $cfg
}

function Get-CnPassword {
    param($Cfg)

    if ($Cfg.passwordEncrypted) {
        try {
            $sec = ConvertTo-SecureString $Cfg.passwordEncrypted
            $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
            try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
            finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
        } catch {
            throw "无法解密保存的密码（DPAPI）。可能是换了 Windows 用户或账户密码变更，请重新运行 install.ps1。原始错误：$($_.Exception.Message)"
        }
    }
    if ($Cfg.password) { return [string]$Cfg.password }
    throw '配置里没有密码，请运行 install.ps1 重新配置。'
}

# --------------------------------------------------------------------------
#  游戏守护
#  目的：游戏/反作弊在运行时，本进程做任何事都可能被行为引擎盯上。
#        所以宁可这次不登录，也不在游戏期间活动。
#  这是第二道防线（第一道在 run-hidden.vbs 里，游戏运行时连 PowerShell 都不会启动）。
# --------------------------------------------------------------------------
function Get-CnWatchList {
    param($Cfg)
    if (-not $Cfg.gameGuard) { return @() }
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($n in @($Cfg.gameProcesses)) {
        $k = ([string]$n).Trim().ToLowerInvariant()
        if ($k -like '*.exe') { $k = $k.Substring(0, $k.Length - 4) }
        if ($k) { $out.Add($k) }
    }
    return $out
}

function Test-CnGameRunning {
    <# 返回正在运行的匹配进程名；没有则返回 $null #>
    param($Cfg)

    # 注意：@() 必须加。PowerShell 函数返回空集合/单元素集合时会被解包，
    # 不加就会变成 $null 或裸字符串，下面的 .Count 会直接报错。
    $watch = @(Get-CnWatchList -Cfg $Cfg)
    if ($watch.Count -eq 0) { return $null }

    $set = @{}
    foreach ($w in $watch) { $set[$w] = $true }

    $procs = @(Get-Process -ErrorAction SilentlyContinue)
    foreach ($p in $procs) {
        $name = ''
        try { $name = $p.ProcessName.ToLowerInvariant() } catch { continue }
        if ($name -and $set.ContainsKey($name)) { return $p.ProcessName }
    }
    return $null
}

function Update-CnGameGuardList {
    <# 把 config.json 里的名单同步成给 run-hidden.vbs 读的纯文本 #>
    param($Cfg)

    $lstPath = Join-Path $script:ScriptDir 'gameguard.lst'
    try {
        $watch = @(Get-CnWatchList -Cfg $Cfg)
        if ($watch.Count -eq 0) {
            if (Test-Path -LiteralPath $lstPath) { Remove-Item -LiteralPath $lstPath -Force -ErrorAction SilentlyContinue }
            return
        }
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine('# 游戏守护名单：VBS 启动器会读这个文件，命中任一进程名就不启动 PowerShell。')
        [void]$sb.AppendLine('# 由 CampusNet.ps1 / 安装程序自动生成，不要手改；改 config.json 里的 gameProcesses。')
        foreach ($w in ($watch | Sort-Object -Unique)) { [void]$sb.AppendLine($w) }
        $newText = $sb.ToString()

        # 内容没变就不要写。这个函数每次运行都会调用（包括 5 分钟一次的定时任务
        # 和 -Mode status），无脑重写等于每 5 分钟改一次文件的修改时间。
        if (Test-Path -LiteralPath $lstPath) {
            $old = [System.IO.File]::ReadAllText($lstPath, [System.Text.Encoding]::UTF8)
            if ($old -ceq $newText) { return }
        }

        [System.IO.File]::WriteAllText($lstPath, $newText, (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}

# --------------------------------------------------------------------------
#  HTTP
# --------------------------------------------------------------------------
function ConvertTo-CnDoubleEncoded {
    <# 等价于 JS 的 encodeURIComponent(encodeURIComponent(s)) #>
    param([AllowEmptyString()][string]$Value)
    return [System.Uri]::EscapeDataString([System.Uri]::EscapeDataString($Value))
}

function Invoke-CnHttp {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [string]$Method = 'GET',
        [AllowNull()][string]$Body = $null,
        [int]$TimeoutSec = 10,
        [switch]$NoRedirect,
        [string]$Referer,
        [System.Net.CookieContainer]$Cookies
    )

    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.Method = $Method
    $req.Timeout = $TimeoutSec * 1000
    $req.ReadWriteTimeout = $TimeoutSec * 1000
    $req.AllowAutoRedirect = (-not $NoRedirect)
    $req.MaximumAutomaticRedirections = 5
    $req.UserAgent = $script:UserAgent
    $req.Proxy = $null
    $req.KeepAlive = $false
    if ($Referer) { $req.Referer = $Referer }
    if ($Cookies) { $req.CookieContainer = $Cookies }

    if ($Method -ne 'GET' -and $null -ne $Body) {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
        $req.ContentType = 'application/x-www-form-urlencoded; charset=UTF-8'
        $req.ContentLength = $bytes.Length
        $rs = $req.GetRequestStream()
        $rs.Write($bytes, 0, $bytes.Length)
        $rs.Close()
    }

    $resp = $null
    try {
        $resp = $req.GetResponse()
    } catch [System.Net.WebException] {
        if ($_.Exception.Response) { $resp = $_.Exception.Response } else { throw }
    }

    $status = [int]$resp.StatusCode
    $location = $null
    try { $location = $resp.Headers['Location'] } catch { }
    $finalUrl = $null
    try { $finalUrl = $resp.ResponseUri.AbsoluteUri } catch { }

    # 门户页面是 GBK，接口是 UTF-8；这里按 UTF-8 读，GBK 页面只用于正则抓 URL，够用
    $sr = New-Object System.IO.StreamReader($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
    $text = $sr.ReadToEnd()
    $sr.Close()
    $resp.Close()

    return [pscustomobject]@{
        StatusCode = $status
        Location   = $location
        FinalUrl   = $finalUrl
        Body       = $text
        RequestUrl = $Url
    }
}

# --------------------------------------------------------------------------
#  在响应体里找门户地址（部分 NAS 不返回 302，而是 200 + JS / meta 跳转）
# --------------------------------------------------------------------------
function Find-CnPortalUrlInBody {
    param([AllowEmptyString()][string]$Body)

    if (-not $Body) { return $null }
    $patterns = @(
        '(?i)(https?://[\d\.]+(?::\d+)?/eportal/index\.jsp\?[^"''\s<>\\]+)',
        '(?i)location\.(?:href|replace)\s*[=(]\s*["'']([^"'']+eportal[^"'']*)["'']',
        '(?i)<meta[^>]+http-equiv\s*=\s*["'']?refresh["'']?[^>]+url\s*=\s*([^"''>\s]+)'
    )
    foreach ($p in $patterns) {
        $m = [regex]::Match($Body, $p)
        if ($m.Success) { return $m.Groups[1].Value.Trim() }
    }
    return $null
}

function Get-CnPortalUrl {
    <# 未认证时访问外网会被 NAS 劫持并 302 到认证门户，从中取出带完整参数的地址 #>
    param($Cfg)

    $candidates = New-Object System.Collections.Generic.List[string]

    foreach ($u in $Cfg.checkUrls) {
        try {
            $r = Invoke-CnHttp -Url $u -TimeoutSec $Cfg.timeoutSec -NoRedirect
        } catch {
            Write-CnLog "探测 $u 失败：$($_.Exception.Message)" 'DEBUG'
            continue
        }

        if ($r.StatusCode -ge 300 -and $r.StatusCode -lt 400 -and $r.Location) {
            if ($r.Location -match 'eportal') { $candidates.Add($r.Location) }
            else {
                # 可能先跳到别的地址，跟一次
                try {
                    $r2 = Invoke-CnHttp -Url $r.Location -TimeoutSec $Cfg.timeoutSec
                    if ($r2.FinalUrl -and $r2.FinalUrl -match 'eportal') { $candidates.Add($r2.FinalUrl) }
                } catch { }
            }
        }
        elseif ($r.StatusCode -eq 200) {
            $fromBody = Find-CnPortalUrlInBody -Body $r.Body
            if ($fromBody) { $candidates.Add($fromBody) }
        }
    }

    # 兜底：直接用配置里的门户地址
    if ($candidates.Count -eq 0 -and $Cfg.portalHost) {
        $candidates.Add("http://$($Cfg.portalHost)/eportal/index.jsp")
    }

    foreach ($c in $candidates) {
        if ($c -notmatch '^https?://') { continue }
        # 地址没带参数时，跟一次重定向拿到完整 URL
        if ($c -notmatch '\?') {
            try {
                $r = Invoke-CnHttp -Url $c -TimeoutSec $Cfg.timeoutSec
                if ($r.FinalUrl -and $r.FinalUrl -match '\?') { return $r.FinalUrl }
            } catch { }
            continue
        }
        return $c
    }

    return $null
}

# --------------------------------------------------------------------------
#  联网状态
# --------------------------------------------------------------------------
function Test-CnOnline {
    <# 返回 @{ Online = $true/$false; PortalUrl = <离线时抓到的门户地址> } #>
    param($Cfg)

    foreach ($u in $Cfg.checkUrls) {
        try {
            $r = Invoke-CnHttp -Url $u -TimeoutSec $Cfg.timeoutSec -NoRedirect
        } catch {
            Write-CnLog "联网检测 $u 失败：$($_.Exception.Message)" 'DEBUG'
            continue
        }

        if ($r.StatusCode -ge 300 -and $r.StatusCode -lt 400) {
            $loc = $r.Location
            if ($loc -and $loc -match 'eportal') {
                return [pscustomobject]@{ Online = $false; PortalUrl = $loc }
            }
            return [pscustomobject]@{ Online = $false; PortalUrl = $null }
        }

        if ($r.StatusCode -eq 204) { return [pscustomobject]@{ Online = $true; PortalUrl = $null } }

        if ($r.StatusCode -eq 200) {
            $bodyPortal = Find-CnPortalUrlInBody -Body $r.Body
            if ($bodyPortal) { return [pscustomobject]@{ Online = $false; PortalUrl = $bodyPortal } }
            return [pscustomobject]@{ Online = $true; PortalUrl = $null }
        }
    }

    return [pscustomobject]@{ Online = $false; PortalUrl = $null }
}

# --------------------------------------------------------------------------
#  登录
# --------------------------------------------------------------------------
function Invoke-CnLogin {
    param(
        $Cfg,
        [string]$PortalUrl,
        [switch]$DryRun
    )

    if (-not $PortalUrl) {
        $PortalUrl = Get-CnPortalUrl -Cfg $Cfg
    }
    if (-not $PortalUrl) {
        return [pscustomobject]@{ Success = $false; Message = '无法获取认证门户地址（未检测到 NAS 重定向）'; Fatal = $true }
    }
    if ($PortalUrl -notmatch 'eportal') {
        return [pscustomobject]@{ Success = $false; Message = "门户地址异常：$PortalUrl"; Fatal = $true }
    }

    $uri = [System.Uri]$PortalUrl
    $portalBase = '{0}://{1}' -f $uri.Scheme, $uri.Host
    if (-not $uri.IsDefaultPort) { $portalBase = '{0}:{1}' -f $portalBase, $uri.Port }
    $queryString = $uri.Query.TrimStart('?')
    $qsEnc = ConvertTo-CnDoubleEncoded $queryString

    Write-CnLog "门户地址：$portalBase"
    Write-CnLog "queryString 长度：$($queryString.Length)"

    $cookies = New-Object System.Net.CookieContainer

    # ---- 1. pageInfo ----
    $pageInfoUrl = "$portalBase/eportal/InterFace.do?method=pageInfo"
    $referer = "$portalBase/eportal/index.jsp?$queryString"
    try {
        $piResp = Invoke-CnHttp -Url $pageInfoUrl -Method POST -Body ("queryString=$qsEnc") `
            -TimeoutSec $Cfg.timeoutSec -Referer $referer -Cookies $cookies
    } catch {
        return [pscustomobject]@{ Success = $false; Message = "pageInfo 请求失败：$($_.Exception.Message)"; Fatal = $false }
    }
    if ($piResp.StatusCode -ne 200) {
        return [pscustomobject]@{ Success = $false; Message = "pageInfo 返回 HTTP $($piResp.StatusCode)"; Fatal = $false }
    }

    try { $pageInfo = $piResp.Body | ConvertFrom-Json }
    catch { return [pscustomobject]@{ Success = $false; Message = "pageInfo 返回的不是 JSON：$($piResp.Body.Substring(0,[Math]::Min(200,$piResp.Body.Length)))"; Fatal = $false } }

    # 必须用 Get-JsonValue 取：Set-StrictMode -Version 2.0 下直接写
    # $pageInfo.validCodeUrl，一旦门户没返回这个字段就抛
    # PropertyNotFoundException，整个登录流程会以「运行错误」结束。
    # 补 Invoke-CnLogin 单测时就是这么第一次撞上的。
    $validCodeUrl = [string](Get-JsonValue $pageInfo 'validCodeUrl' '')
    if ($validCodeUrl) {
        Write-CnLog "门户要求图形验证码：$validCodeUrl" 'WARN'
        return [pscustomobject]@{ Success = $false; Message = '该门户开启了图形验证码，脚本无法自动登录，请先在浏览器里登录一次或联系网管关闭验证码'; Fatal = $true }
    }

    # ---- 2. 处理密码 ----
    $plain = Get-CnPassword -Cfg $Cfg
    $encryptFlag = 'false'
    $passwordValue = $plain

    $piEncrypt = [string](Get-JsonValue $pageInfo 'passwordEncrypt' 'false')
    if ($piEncrypt -eq 'true') {
        # 门户开了密码加密：明文 = 密码 + ">" + queryString 里的 mac 参数，再整体反转后 RSA
        $macParam = $null
        foreach ($kv in $queryString.Split('&')) {
            $eq = $kv.IndexOf('=')
            if ($eq -gt 0 -and $kv.Substring(0, $eq) -eq 'mac') {
                $macParam = [System.Uri]::UnescapeDataString($kv.Substring($eq + 1))
            }
        }
        if ([string]::IsNullOrEmpty($macParam)) { $macParam = '111111111' }

        $toEncrypt = $plain + '>' + $macParam
        $reversed = -join ($toEncrypt.ToCharArray()[[int[]]((($toEncrypt.Length - 1))..0)])

        try {
            $passwordValue = ConvertTo-SrunRsa -PlainText $reversed `
                -ExponentHex ([string](Get-JsonValue $pageInfo 'publicKeyExponent' '')) `
                -ModulusHex ([string](Get-JsonValue $pageInfo 'publicKeyModulus' ''))
            $encryptFlag = 'true'
            Write-CnLog '门户启用了密码 RSA 加密，已按 security.js 算法加密' 'DEBUG'
        } catch {
            return [pscustomobject]@{ Success = $false; Message = "密码加密失败：$($_.Exception.Message)"; Fatal = $true }
        }
    }

    # ---- 3. 服务名 ----
    $serviceName = $Cfg.service
    $serviceObj = Get-JsonValue $pageInfo 'service' $null
    if (-not $serviceName -and $serviceObj) {
        $props = @($serviceObj.PSObject.Properties)
        if ($props.Count -gt 1) {
            $def = $props | Where-Object { (Get-JsonValue $_.Value 'serviceDefault' 'false') -eq 'true' } | Select-Object -First 1
            if ($def) { $serviceName = $def.Name }
        }
    }

    # ---- 4. 组装 login 报文 ----
    $userIdEnc = ConvertTo-CnDoubleEncoded $Cfg.userId
    $pwdEnc = ConvertTo-CnDoubleEncoded $passwordValue
    $svcEnc = ConvertTo-CnDoubleEncoded $serviceName
    $flagEnc = ConvertTo-CnDoubleEncoded $encryptFlag

    $loginBody = 'userId={0}&password={1}&service={2}&queryString={3}&operatorPwd=&operatorUserId=&validcode=&passwordEncrypt={4}' -f `
        $userIdEnc, $pwdEnc, $svcEnc, $qsEnc, $flagEnc

    $masked = $loginBody -replace 'password=[^&]*', ('password=<' + $passwordValue.Length + '字符密文>')
    Write-CnLog "登录报文：$($masked.Substring(0, [Math]::Min(240, $masked.Length)))..." 'DEBUG'

    if ($DryRun) {
        return [pscustomobject]@{ Success = $true; Message = 'DRY-RUN：未真正提交'; DryRun = $true; LoginBody = $loginBody }
    }

    # ---- 5. 提交 ----
    $loginUrl = "$portalBase/eportal/InterFace.do?method=login"
    try {
        $loginResp = Invoke-CnHttp -Url $loginUrl -Method POST -Body $loginBody `
            -TimeoutSec ($Cfg.timeoutSec + 5) -Referer $referer -Cookies $cookies
    } catch {
        return [pscustomobject]@{ Success = $false; Message = "login 请求失败：$($_.Exception.Message)"; Fatal = $false }
    }

    try { $result = $loginResp.Body | ConvertFrom-Json }
    catch { return [pscustomobject]@{ Success = $false; Message = "login 返回的不是 JSON：$($loginResp.Body.Substring(0,[Math]::Min(200,$loginResp.Body.Length)))"; Fatal = $false } }

    $msg = [string](Get-JsonValue $result 'message' '')
    $resFlag = [string](Get-JsonValue $result 'result' 'fail')

    if ($resFlag -eq 'success') {
        $uid = Get-JsonValue $result 'userIndex' ''
        $kai = Get-JsonValue $result 'keepaliveInterval' ''
        Write-CnLog "登录成功（userIndex=$uid，保活间隔 $kai s）" 'OK'
        return [pscustomobject]@{ Success = $true; Message = $msg; UserIndex = $uid; KeepaliveInterval = $kai }
    }

    # 设备上已经有在线用户 —— 对本机来说等于已联网
    if ($Cfg.treatAlreadyOnlineAsSuccess -and $msg -match '已存在在线用户|已经在线|已在别处登录|重复登录') {
        Write-CnLog "服务端提示：$msg（本机已在线，按成功处理）" 'OK'
        return [pscustomobject]@{ Success = $true; Message = $msg; AlreadyOnline = $true }
    }

    # 服务名相关错误，用默认服务名重试一次
    if ($msg -match '服务' -and -not $serviceName -and $serviceObj) {
        $props = @($serviceObj.PSObject.Properties)
        if ($props.Count -ge 1) {
            $retryService = $props[0].Name
            Write-CnLog "服务名可能不对，改用「$retryService」重试一次" 'WARN'
            $retryBody = 'userId={0}&password={1}&service={2}&queryString={3}&operatorPwd=&operatorUserId=&validcode=&passwordEncrypt={4}' -f `
                $userIdEnc, $pwdEnc, (ConvertTo-CnDoubleEncoded $retryService), $qsEnc, $flagEnc
            try {
                $r2 = Invoke-CnHttp -Url $loginUrl -Method POST -Body $retryBody -TimeoutSec ($Cfg.timeoutSec + 5) -Referer $referer -Cookies $cookies
                $res2 = $r2.Body | ConvertFrom-Json
                if ([string](Get-JsonValue $res2 'result' 'fail') -eq 'success') {
                    $uid2 = Get-JsonValue $res2 'userIndex' ''
                    Write-CnLog "登录成功（服务名=$retryService，userIndex=$uid2）" 'OK'
                    return [pscustomobject]@{ Success = $true; Message = [string](Get-JsonValue $res2 'message' ''); UserIndex = $uid2 }
                }
                $msg = [string](Get-JsonValue $res2 'message' $msg)
            } catch { }
        }
    }

    return [pscustomobject]@{ Success = $false; Message = $msg; Fatal = $false }
}

# --------------------------------------------------------------------------
#  主流程
# --------------------------------------------------------------------------
function Invoke-CnEnsure {
    param($Cfg)

    # 游戏守护放在最前面：游戏/反作弊在跑的时候，连联网检测都不做，
    # 让本进程的生命周期缩到最短、动作降到最少。
    $game = Test-CnGameRunning -Cfg $Cfg
    if ($game) {
        Write-CnLog "游戏守护：检测到「$game」正在运行，本次跳过（不做任何网络请求）" 'WARN'
        return 0
    }

    for ($i = 1; $i -le $Cfg.retryCount; $i++) {
        $state = Test-CnOnline -Cfg $Cfg
        if ($state.Online) {
            Write-CnLog '已联网，无需登录' 'OK'
            return 0
        }

        Write-CnLog "检测到未认证（第 $i/$($Cfg.retryCount) 次尝试）"
        $r = Invoke-CnLogin -Cfg $Cfg -PortalUrl $state.PortalUrl

        if ($r.Success) {
            Start-Sleep -Seconds 2
            $after = Test-CnOnline -Cfg $Cfg
            if ($after.Online) {
                Write-CnLog '认证后联网验证通过' 'OK'
                return 0
            }
            Write-CnLog '登录接口返回成功，但联网验证未通过' 'WARN'
        } else {
            Write-CnLog "登录失败：$($r.Message)" 'ERROR'
            if ($r.Fatal) { return 2 }
        }

        if ($i -lt $Cfg.retryCount) { Start-Sleep -Seconds $Cfg.retryDelaySec }
    }

    Write-CnLog "连续 $($Cfg.retryCount) 次尝试均失败" 'ERROR'
    return 1
}

function Invoke-CnStatus {
    param($Cfg)
    $state = Test-CnOnline -Cfg $Cfg
    if ($state.Online) {
        Write-CnLog '在线' 'OK'
        return 0
    }
    if ($state.PortalUrl) {
        Write-CnLog "离线（门户：$($state.PortalUrl.Substring(0,[Math]::Min(120,$state.PortalUrl.Length)))...)" 'WARN'
    } else {
        Write-CnLog '离线（未检测到门户重定向）' 'WARN'
    }
    return 1
}

function Invoke-CnTest {
    param($Cfg)

    Write-CnLog '===== 诊断模式 ====='
    Write-CnLog "账号：$($Cfg.userId)"
    Write-CnLog "密码来源：$(if ($Cfg.passwordEncrypted) { 'DPAPI 加密存储' } elseif ($Cfg.password) { '明文配置' } else { '未配置' })"
    Write-CnLog "服务名：$(if ($Cfg.service) { $Cfg.service } else { '(自动/空)' })"
    Write-CnLog "探测地址：$($Cfg.checkUrls -join ', ')"

    $state = Test-CnOnline -Cfg $Cfg
    Write-CnLog "联网状态：$(if ($state.Online) { '在线' } else { '离线' })"

    $portal = $state.PortalUrl
    if (-not $portal) { $portal = $PortalUrl }
    if (-not $portal) { $portal = Get-CnPortalUrl -Cfg $Cfg }
    Write-CnLog "门户地址：$(if ($portal) { $portal } else { '(未抓到)' })"

    if (-not $portal) {
        if ($state.Online) {
            # 新人第一次装的时候多半本来就在线，这不是错误，别吓人
            Write-CnLog '当前已联网，所以抓不到门户地址 —— 这是正常的。' 'OK'
            Write-CnLog '脚本只在真正掉线（未认证）时才需要去抓门户地址。' 'INFO'
        } else {
            Write-CnLog '当前离线，但没抓到门户地址。' 'WARN'
            Write-CnLog '可能原因：CAS 还没就绪 / 探测地址被放行 / 需要手工填 config.json 的 portalHost。' 'INFO'
        }
        return 0
    }

    # 只跑到 pageInfo 为止
    $uri = [System.Uri]$portal
    $base = '{0}://{1}' -f $uri.Scheme, $uri.Host
    if (-not $uri.IsDefaultPort) { $base = '{0}:{1}' -f $base, $uri.Port }
    $qs = $uri.Query.TrimStart('?')
    $cookies = New-Object System.Net.CookieContainer
    try {
        $r = Invoke-CnHttp -Url "$base/eportal/InterFace.do?method=pageInfo" -Method POST `
            -Body ('queryString=' + (ConvertTo-CnDoubleEncoded $qs)) -TimeoutSec $Cfg.timeoutSec `
            -Referer "$base/eportal/index.jsp?$qs" -Cookies $cookies
        $pi = $r.Body | ConvertFrom-Json
        $piService = Get-JsonValue $pi 'service' $null
        $svcNames = if ($piService) { (@($piService.PSObject.Properties) | ForEach-Object { $_.Name }) -join ', ' } else { '(无)' }
        Write-CnLog "passwordEncrypt = $(Get-JsonValue $pi 'passwordEncrypt' 'false')"
        Write-CnLog "publicKeyExponent = $(Get-JsonValue $pi 'publicKeyExponent' '')"
        Write-CnLog "publicKeyModulus 长度 = $(([string](Get-JsonValue $pi 'publicKeyModulus' '')).Length)"
        Write-CnLog "提供服务：$svcNames"
        Write-CnLog "验证码：$(if (Get-JsonValue $pi 'validCodeUrl' '') { Get-JsonValue $pi 'validCodeUrl' '' } else { '无' })"
    } catch {
        Write-CnLog "pageInfo 失败：$($_.Exception.Message)" 'ERROR'
    }

    $dry = Invoke-CnLogin -Cfg $Cfg -PortalUrl $portal -DryRun
    Write-CnLog "DRY-RUN 结果：$($dry.Message)" 'OK'
    return 0
}

# ==========================================================================
#  入口
#
#  注意这个 if：被 dot-source 时（InvocationName 是 "."）只加载函数定义，
#  不执行主流程。tests\CampusNet.Tests.ps1 靠这个拿到函数做单元测试，
#  否则一 source 就会真的去登录、甚至 exit 掉测试进程。
# ==========================================================================
if ($MyInvocation.InvocationName -eq '.') { return }

try {
    . (Join-Path $script:ScriptDir 'lib\SrunRsa.ps1')
    $cfg = Get-CnConfig -Path $ConfigPath

    Write-CnLog "===== CampusNet [$Mode] 启动 =====" 'DEBUG'

    # 同步游戏守护名单给 VBS 启动器（它读纯文本，避免解析 JSON）
    Update-CnGameGuardList -Cfg $cfg

    switch ($Mode) {
        'ensure' { exit (Invoke-CnEnsure -Cfg $cfg) }
        'login' {
            $game = Test-CnGameRunning -Cfg $cfg
            if ($game) {
                Write-CnLog "游戏守护：检测到「$game」正在运行，已跳过强制登录" 'WARN'
                exit 0
            }
            $state = Test-CnOnline -Cfg $cfg
            $target = if ($PortalUrl) { $PortalUrl } else { $state.PortalUrl }
            $r = Invoke-CnLogin -Cfg $cfg -PortalUrl $target
            if ($r.Success) { Write-CnLog $r.Message 'OK'; exit 0 }
            Write-CnLog $r.Message 'ERROR'; exit 1
        }
        'status' { exit (Invoke-CnStatus -Cfg $cfg) }
        'test' { exit (Invoke-CnTest -Cfg $cfg) }
    }
} catch {
    Write-CnLog "运行错误：$($_.Exception.Message)" 'ERROR'
    if (-not $Quiet) {
        Write-Host ''
        Write-Host '详细调用栈：' -ForegroundColor DarkGray
        Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    }
    exit 2
}
