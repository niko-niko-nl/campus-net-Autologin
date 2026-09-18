# =============================================================================
#  test-rsa.ps1 —— RSA 实现回归测试
# =============================================================================
#  两层校验：
#    第 1 层（默认，离线）：tools\rsa_ref.js 是与门户 security.js 等价的参考实现，
#                          不需要联网、不需要门户文件，开箱即可回归。
#    第 2 层（可选）：如果手上有一份门户原始的 security.js，再拿它当"真·标准答案"
#                    交叉验证 rsa_ref.js —— 用来确认参考实现本身没写偏。
#
#  为什么分两层：
#    门户的 security.js 是第三方文件，本仓库不分发。原来只依赖它，导致
#    clone 下来根本跑不起来。现在默认走离线那层。
#
#  前置：Node.js（用来执行参考实现）
#
#  用法：
#    powershell -ExecutionPolicy Bypass -File test-rsa.ps1
#    powershell -ExecutionPolicy Bypass -File test-rsa.ps1 -Modulus <256位十六进制>
#    powershell -ExecutionPolicy Bypass -File test-rsa.ps1 -SkipPortal
#
#  已知边界：只覆盖码元 <= 255 的输入。非 ASCII 在 ohdave 原版里就是未定义行为，
#            三方实现两两都不同，故参考实现会直接抛错（本脚本会验证这一点）。
# =============================================================================
[CmdletBinding()]
param(
    # 公钥模数。留空用内置的 1024 位测试模数 —— 交叉验证只需要两边用同一个模数。
    [string]$Modulus,

    [string]$Exponent = '10001',

    # 即使本地有 security.js 也跳过第 2 层
    [switch]$SkipPortal
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\SrunRsa.ps1')
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# 内置测试模数：1024 位随机奇数，仅用于算法等价性验证，不是任何学校的密钥
if (-not $Modulus) {
    $Modulus = 'f60fc3ee3a1886e7bed85388dc0a862c1a45fedb9d59abddf0e6f16c829645106690235100bf1aec52e74cb6a7905dc1d8c1eba610fd982653121299e6c21c1450f54ec3c5e4fe465edba75d9ac141fbd7f3b5024cf1f1f86852cf26c0f14b5b1c3fcf3d4880b07fb2690d951fc8e3b9431d39e1ca53f0c5a194f22fb944caab'
}

function Assert-Node {
    if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
        Write-Host '[X] 找不到 Node.js —— 这个回归测试需要它来执行参考实现。' -ForegroundColor Red
        Write-Host '    装一个 Node.js 再跑；或者跳过（它只用于开发期校验，不影响自动登录）。' -ForegroundColor Gray
        exit 2
    }
}

# ---------------------------------------------------------------------------
#  测试向量：覆盖短口令、特殊符号、以及 chunkSize(=126) 的分块边界
# ---------------------------------------------------------------------------
function Get-TestVectors {
    $v = New-Object System.Collections.Generic.List[string]
    foreach ($x in @('a', 'ab', 'abc', 'test', 'abc123', 'Passw0rd!', '0123456789',
                     'p@ss word with space', 'Test1234>deadbeefdeadbeefdeadbeefdeadbeef',
                     '!@#$%^&*()_+-=[]{}|;:,.<>?', '~`')) { $v.Add($x) }
    foreach ($n in 1, 2, 63, 64, 125, 126, 127, 251, 252, 253, 260, 378, 379) {
        $v.Add('x' * $n)
    }
    $p = 0
    while ($v.Count -lt 40) { $v.Add('pad' + $p + '!#' + ('-' * $p)); $p++ }
    return $v
}

function Invoke-NodeEncrypt {
    param([string]$JsPath, [string]$Pwd)
    $out = & node $JsPath $Exponent $Modulus $Pwd 2>&1
    if ($LASTEXITCODE -ne 0) { throw "node 执行失败：$out" }
    return ($out -join '')
}

function Reverse-String([string]$s) {
    if ($s.Length -le 1) { return $s }
    return -join ($s.ToCharArray()[[int[]](($s.Length - 1)..0)])
}

function Test-OneVector {
    param([string]$Pwd, [string]$Expected)
    $rev = Reverse-String $Pwd
    $actual = ConvertTo-SrunRsa -PlainText $rev -ExponentHex $Exponent -ModulusHex $Modulus
    return ($Expected -ceq $actual)
}

$refJs = Join-Path $PSScriptRoot 'rsa_ref.js'
if (-not (Test-Path -LiteralPath $refJs)) {
    Write-Host "[X] 缺少 $refJs" -ForegroundColor Red
    exit 2
}

Write-Host ''
Write-Host '===== RSA 实现回归测试 =====' -ForegroundColor Cyan
Write-Host '待测实现：lib\SrunRsa.ps1'
Write-Host "模数    ：$($Modulus.Substring(0,24))...（$($Modulus.Length) 位十六进制）"
Write-Host ''

Assert-Node
$vectors = Get-TestVectors

# ---------------------------------------------------------------------------
#  第 1 层：与离线参考实现比对
# ---------------------------------------------------------------------------
Write-Host '--- 第 1 层：与 tools\rsa_ref.js（离线参考实现）比对 ---' -ForegroundColor White
$pass = 0; $fail = 0
foreach ($pwd in $vectors) {
    $expected = Invoke-NodeEncrypt -JsPath $refJs -Pwd $pwd
    if (Test-OneVector -Pwd $pwd -Expected $expected) {
        $pass++
    } else {
        $fail++
        if ($fail -le 3) {
            Write-Host ("[FAIL] 口令长度 {0}" -f $pwd.Length) -ForegroundColor Red
            Write-Host ("   参考: {0}" -f $expected.Substring(0, [Math]::Min(48, $expected.Length)))
            $rev = Reverse-String $pwd
            $got = ConvertTo-SrunRsa -PlainText $rev -ExponentHex $Exponent -ModulusHex $Modulus
            Write-Host ("   实测: {0}" -f $got.Substring(0, [Math]::Min(48, $got.Length)))
        }
    }
}
Write-Host ("  向量 {0} 个：通过 {1} / 失败 {2}" -f $vectors.Count, $pass, $fail) `
    -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })

# 空串是特殊分支（原版返回空串而不是一个块），单独断言。
# 注意：不能用命令行把空串传给 node —— PowerShell 会把空参数丢掉，
# node 收到的是 undefined。所以这里用一个进程内的小探针。
$emptyProbe = @'
const r = require(process.argv[2]);
process.stdout.write(r.encryptedString(process.argv[3], process.argv[4], ''));
'@
$emptyFile = Join-Path $env:TEMP ('cn_empty_' + [Guid]::NewGuid().ToString('N') + '.js')
Set-Content -LiteralPath $emptyFile -Value $emptyProbe -Encoding UTF8
$emptyOk = $false
try {
    $e = ((& node $emptyFile $refJs $Exponent $Modulus 2>&1) -join '')
    $a = ConvertTo-SrunRsa -PlainText '' -ExponentHex $Exponent -ModulusHex $Modulus
    $emptyOk = ($e -ceq $a)
    if (-not $emptyOk) { Write-Host ("   参考: '{0}'  实测: '{1}'" -f $e, $a) -ForegroundColor DarkRed }
} catch { $emptyOk = $false }
finally { Remove-Item -LiteralPath $emptyFile -Force -ErrorAction SilentlyContinue }
Write-Host ("  空串分支：{0}" -f $(if ($emptyOk) { '通过（两边都返回空串）' } else { '失败' })) `
    -ForegroundColor $(if ($emptyOk) { 'Green' } else { 'Red' })
if (-not $emptyOk) { $fail++ }

# 非 ASCII 应当被参考实现明确拒绝
$probe = @'
try {
  const r = require(process.argv[2]);
  r.encryptedString('10001', process.argv[3], '\u4e2d');
  process.stdout.write('NO-THROW');
} catch (e) { process.stdout.write('THREW'); }
'@
$probeFile = Join-Path $env:TEMP ('cn_nonascii_' + [Guid]::NewGuid().ToString('N') + '.js')
Set-Content -LiteralPath $probeFile -Value $probe -Encoding UTF8
$nonAsciiRejected = $false
try {
    $r = (& node $probeFile $refJs $Modulus 2>&1) -join ''
    $nonAsciiRejected = ($r -eq 'THREW')
} catch { $nonAsciiRejected = $false }
finally { Remove-Item -LiteralPath $probeFile -Force -ErrorAction SilentlyContinue }
Write-Host ("  非 ASCII 拒绝：{0}" -f $(if ($nonAsciiRejected) { '通过' } else { '失败（应抛错却没抛）' })) `
    -ForegroundColor $(if ($nonAsciiRejected) { 'Green' } else { 'Red' })
if (-not $nonAsciiRejected) { $fail++ }

# ---------------------------------------------------------------------------
#  第 2 层（可选）：拿门户原始 security.js 验证参考实现本身
# ---------------------------------------------------------------------------
$portalJs = Join-Path $PSScriptRoot 'security.js'
if ($SkipPortal) {
    Write-Host ''
    Write-Host '--- 第 2 层：已跳过（-SkipPortal） ---' -ForegroundColor DarkGray
} elseif (-not (Test-Path -LiteralPath $portalJs)) {
    Write-Host ''
    Write-Host '--- 第 2 层：跳过（本地没有门户的 security.js） ---' -ForegroundColor DarkGray
    Write-Host '    想跑这层：把门户的 security.js 放到 tools\ 下即可。' -ForegroundColor DarkGray
} else {
    Write-Host ''
    Write-Host '--- 第 2 层：与门户原始 security.js 比对 ---' -ForegroundColor White

    # 两个实现必须在同一个进程里比对。
    # 注意：security.js 会覆盖全局 BigInt，rsa_ref.js 内部抓的是原生实现，故不受影响。
    $cmp = @'
const fs = require('fs'), path = require('path');
const dir = process.argv[2], mod = process.argv[3];
const ref = require(path.join(dir, 'rsa_ref.js'));
global.window = global;
eval(fs.readFileSync(path.join(dir, 'security.js'), 'latin1').replace(/^\u00EF\u00BB\u00BF/, ''));
RSAUtils.setMaxDigits(400);
const pk = RSAUtils.getKeyPair('10001', '', mod);
let m = 0, mm = 0;
for (const w of ["a","123456","Passw0rd!","p@ss word with space","x".repeat(126),"x".repeat(252),"x".repeat(379)]) {
  const a = RSAUtils.encryptedString(pk, w.split('').reverse().join(''));
  const b = ref.encryptPassword('10001', mod, w);
  a === b ? m++ : mm++;
}
process.stdout.write(m + ' ' + mm);
'@
    $cmpFile = Join-Path $env:TEMP ('cn_cmp_' + [Guid]::NewGuid().ToString('N') + '.js')
    Set-Content -LiteralPath $cmpFile -Value $cmp -Encoding UTF8
    try {
        $res = ((& node $cmpFile $PSScriptRoot $Modulus 2>&1) -join '').Trim()
        $parts = $res -split ' '
        $ok = ($parts.Count -eq 2 -and [int]$parts[1] -eq 0)
        Write-Host ("  参考实现 vs 门户原版：通过 {0} / 失败 {1}" -f $parts[0], $parts[1]) `
            -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' })
        if (-not $ok) { $fail++ }
    } catch {
        Write-Host ("  第 2 层执行失败：{0}" -f $_.Exception.Message) -ForegroundColor Yellow
    } finally {
        Remove-Item -LiteralPath $cmpFile -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
Write-Host ''
if ($fail -eq 0) {
    Write-Host '结果：全部通过 ✓' -ForegroundColor Green
    exit 0
} else {
    Write-Host ("结果：有 {0} 项失败 ✗" -f $fail) -ForegroundColor Red
    exit 1
}
