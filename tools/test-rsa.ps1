# =============================================================================
#  test-rsa.ps1 —— 交叉验证深澜密码加密的实现是否正确
# =============================================================================
#  做什么：
#    用「门户原始 security.js」当标准答案，检查 lib\SrunRsa.ps1 的输出是否逐字节一致。
#    两边必须完全相等，否则服务端解不开密码。
#
#  为什么要跑：
#    学校门户升级后加密算法可能变。改完代码跑一遍，7 个用例全 OK 才算没写坏。
#
#  依赖：
#    Node.js（用来执行 security.js）
#
#  用法：
#    powershell -ExecutionPolicy Bypass -File test-rsa.ps1
#    powershell -ExecutionPolicy Bypass -File test-rsa.ps1 -PortalHost 10.0.0.1
#    powershell -ExecutionPolicy Bypass -File test-rsa.ps1 -Modulus <256位十六进制>
#
#  没有 security.js 时会自动从门户下载一份（这是门户自己的静态文件，
#  本仓库不附带，以免分发第三方文件）。
# =============================================================================
[CmdletBinding()]
param(
    # 门户 IP，用于自动下载 security.js。留空则读 config.json 的 portalHost。
    [string]$PortalHost,

    # 公钥模数。留空则用内置的 1024 位测试模数 —— 交叉验证只需要两边用同一个
    # 模数，不需要是真实密钥。
    [string]$Modulus,

    [string]$Exponent = '10001'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\SrunRsa.ps1')
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# 内置测试模数：1024 位随机奇数，仅用于算法等价性交叉验证，不是任何学校的密钥
if (-not $Modulus) {
    $Modulus = 'f60fc3ee3a1886e7bed85388dc0a862c1a45fedb9d59abddf0e6f16c829645106690235100bf1aec52e74cb6a7905dc1d8c1eba610fd982653121299e6c21c1450f54ec3c5e4fe465edba75d9ac141fbd7f3b5024cf1f1f86852cf26c0f14b5b1c3fcf3d4880b07fb2690d951fc8e3b9431d39e1ca53f0c5a194f22fb944caab'
}

# ---- 找 security.js，没有就下载 ----
$jsFile = Join-Path $PSScriptRoot 'security.js'
if (-not (Test-Path -LiteralPath $jsFile)) {
    if (-not $PortalHost) {
        $cfgPath = Join-Path $root 'config.json'
        if (Test-Path -LiteralPath $cfgPath) {
            $cfg = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $p = @($cfg.PSObject.Properties | Where-Object { $_.Name -eq 'portalHost' })
            if ($p.Count -gt 0 -and $p[0].Value) { $PortalHost = [string]$p[0].Value }
        }
    }
    if (-not $PortalHost) {
        Write-Host '[X] 缺少 security.js，也不知道门户地址。' -ForegroundColor Red
        Write-Host '    请用 -PortalHost 指定，例如：-PortalHost 10.0.0.1' -ForegroundColor Gray
        Write-Host '    或者先把门户的 security.js 手工放到 tools\ 目录下。' -ForegroundColor Gray
        exit 2
    }

    $urls = @(
        "http://${PortalHost}:8080/eportal/interface/index_files/js/security.js",
        "http://${PortalHost}/eportal/interface/index_files/js/security.js"
    )
    $got = $false
    foreach ($u in $urls) {
        try {
            Write-Host "正在下载 $u ..." -ForegroundColor DarkGray
            $wc = New-Object System.Net.WebClient
            $wc.Headers.Add('User-Agent', 'Mozilla/5.0')
            $wc.DownloadFile($u, $jsFile)
            $got = $true
            break
        } catch { }
    }
    if (-not $got) {
        Write-Host "[X] 从 $PortalHost 下载 security.js 失败（门户地址或网络不对？）" -ForegroundColor Red
        exit 2
    }
    Write-Host "  已保存到 $jsFile" -ForegroundColor DarkGray
}

# ---- 检查 Node.js ----
$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) {
    Write-Host '[X] 找不到 Node.js。这个交叉验证需要它来执行门户原始的 security.js。' -ForegroundColor Red
    Write-Host '    装一个 Node.js 再跑，或者跳过这个测试（它只用于开发期校验）。' -ForegroundColor Gray
    exit 2
}

$js = Join-Path $PSScriptRoot 'verify-rsa.js'
if (-not (Test-Path -LiteralPath $js)) {
    Write-Host "[X] 缺少 $js" -ForegroundColor Red
    exit 2
}

Write-Host ''
Write-Host '===== RSA 实现交叉验证 =====' -ForegroundColor Cyan
Write-Host "标准答案：门户 security.js"
Write-Host "待测实现：lib\SrunRsa.ps1"
Write-Host "模数    ：$($Modulus.Substring(0,24))...（$($Modulus.Length) 位十六进制）"
Write-Host ''

$cases = @(
    'a',
    'test',
    'abc123',
    'Passw0rd!',
    '0123456789012345678901234567890123456789',
    'p@ss word with space',
    'Test1234>deadbeefdeadbeefdeadbeefdeadbeef'
)

$pass = 0; $fail = 0
foreach ($pwd in $cases) {
    $expected = (& node $js $Exponent $Modulus $pwd) -join ''
    # 门户侧做法: RSAUtils.encryptedString(key, password.split("").reverse().join(""))
    $rev = -join ($pwd.ToCharArray()[[int[]](($pwd.Length - 1)..0)])
    $actual = ConvertTo-SrunRsa -PlainText $rev -ExponentHex $Exponent -ModulusHex $Modulus

    if ($expected -ceq $actual) {
        $pass++
        Write-Host ("[OK]   {0,-46} len={1}" -f $pwd, $actual.Length) -ForegroundColor Green
    } else {
        $fail++
        Write-Host ("[FAIL] {0}" -f $pwd) -ForegroundColor Red
        Write-Host ("   JS : {0}" -f $expected)
        Write-Host ("   PS : {0}" -f $actual)
    }
}

Write-Host ''
Write-Host ("通过 {0} / 失败 {1}" -f $pass, $fail) -ForegroundColor ($(if ($fail -eq 0) { 'Green' } else { 'Red' }))
if ($fail -gt 0) { exit 1 }
