# =====================================================================
#  深澜 (Srun) eportal 密码加密 —— PowerShell 实现
#  严格复刻门户 security.js 中 ohdave RSA 的 encryptedString()
#
#  JS 原始逻辑:
#     RSAUtils.setMaxDigits(400)
#     key = RSAUtils.getKeyPair(publicKeyExponent, "", publicKeyModulus)
#     cipher = RSAUtils.encryptedString(key, text.split("").reverse().join(""))
#
#  与该库常见 "标准 RSA" 的差别（必须一致，否则服务端解不开）:
#     1. 没有 PKCS#1 填充，是裸的模幂运算  c = m^e mod n
#     2. 明文按 chunkSize 字节分块，每块按【小端】解释为大整数
#     3. chunkSize = 2 * biHighIndex(n)，即 modulus 的 16bit 位数减一，
#        1024bit 密钥 => 64 位 => chunkSize = 126（不是 128）
#     4. 密文输出 16 进制，每个 16bit 位固定补足 4 位；多块之间用空格连接
# =====================================================================

Set-StrictMode -Version 2.0

function ConvertTo-SrunRsa {
    <#
    .SYNOPSIS
        深澜 eportal 的密码加密（等价于 security.js 的 RSAUtils.encryptedString）。
    .PARAMETER PlainText
        明文（门户侧是先反转再传入，反转由调用方完成，本函数不做反转）。
    .PARAMETER ExponentHex
        门户 pageInfo 返回的 publicKeyExponent，通常是 "10001"。
    .PARAMETER ModulusHex
        门户 pageInfo 返回的 publicKeyModulus（16 进制字符串）。
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$PlainText,
        [Parameter(Mandatory = $true)][string]$ExponentHex,
        [Parameter(Mandatory = $true)][string]$ModulusHex
    )

    $hexStyle = [System.Globalization.NumberStyles]::AllowHexSpecifier

    # 前置 '0' 保证按无符号（正数）解析
    $e = [System.Numerics.BigInteger]::Parse('0' + $ExponentHex.Trim(), $hexStyle)
    $mod = $ModulusHex.Trim().ToLowerInvariant()
    if ($mod.Length % 4 -ne 0) { $mod = ('0' * (4 - ($mod.Length % 4))) + $mod }
    $m = [System.Numerics.BigInteger]::Parse('0' + $mod, $hexStyle)

    if ($m -le [System.Numerics.BigInteger]::Zero) { throw "公钥模数无效：$ModulusHex" }
    if ($e -le [System.Numerics.BigInteger]::Zero) { throw "公钥指数无效：$ExponentHex" }

    # ---- 计算 chunkSize = 2 * biHighIndex(m) ----
    $digitCount = $mod.Length / 4
    $lead = 0
    while ($lead -lt ($digitCount - 1) -and $mod.Substring($lead * 4, 4) -eq '0000') { $lead++ }
    $highIndex = $digitCount - 1 - $lead
    $chunkSize = 2 * $highIndex
    if ($chunkSize -lt 1) { throw "公钥模数过短，无法分块：$ModulusHex" }

    # ---- 明文转成 UTF-16 码元数组（对应 JS 的 charCodeAt）----
    $units = New-Object 'int[]' ([Math]::Max($PlainText.Length, 1))
    for ($i = 0; $i -lt $PlainText.Length; $i++) { $units[$i] = [int][char]$PlainText[$i] }

    # ---- 补齐到 chunkSize 的整数倍（JS: while (a.length % chunkSize != 0) a[i++] = 0）----
    $rem = $PlainText.Length % $chunkSize
    $total = if ($rem -eq 0) { $PlainText.Length } else { $PlainText.Length + ($chunkSize - $rem) }
    if ($total -eq 0) { $total = $chunkSize }

    $blocks = New-Object System.Collections.Generic.List[string]

    for ($off = 0; $off -lt $total; $off += $chunkSize) {
        # 小端序字节数组，末尾补 0 字节保证 BigInteger 为正
        $buf = New-Object byte[] ($chunkSize + 1)
        for ($k = 0; $k -lt $chunkSize; $k++) {
            $idx = $off + $k
            $v = if ($idx -lt $PlainText.Length) { $units[$idx] } else { 0 }
            $buf[$k] = [byte]($v -band 0xFF)
        }
        $buf[$chunkSize] = 0

        $block = New-Object -TypeName System.Numerics.BigInteger -ArgumentList (, $buf)
        $cipher = [System.Numerics.BigInteger]::ModPow($block, $e, $m)

        # 等价于 JS 的 RSAUtils.biToHex()：每位 16bit 固定补足 4 个 16 进制字符
        $blocks.Add((ConvertTo-CnRsaHex -Value $cipher))
    }

    return ($blocks -join ' ')
}

function ConvertTo-CnRsaHex {
    <#
      把 BigInteger 转成 JS biToHex() 的等价输出。

      ⚠️ 不能直接用 $x.ToString('x')：.NET 在最高位 >= 8 时会额外补一个前导 '0'
      （防止该串被 AllowHexSpecifier 当成负数）。那个 0 不是数值的一部分，
      直接参与「补齐到 4 的倍数」会多补出 4 个字符，加密结果就错了。
      实测：约 15% 的密文会触发（最高位 >= 8 时），服务端会解不开。

      这里改从 ToByteArray()（小端补码）自己拼 hex，先去掉高位补的 0x00，
      再左侧补齐到 4 的倍数 —— 正好等于「按 16bit 位分组的固定 4 字符」。
    #>
    param([Parameter(Mandatory = $true)][System.Numerics.BigInteger]$Value)

    $bytes = $Value.ToByteArray()          # 小端序、二进制补码
    $hi = $bytes.Length - 1
    while ($hi -gt 0 -and $bytes[$hi] -eq 0) { $hi-- }   # 去掉符号保护用的高位 0

    $sb = New-Object System.Text.StringBuilder
    for ($k = $hi; $k -ge 0; $k--) { [void]$sb.Append($bytes[$k].ToString('x2')) }

    $h = $sb.ToString()
    if ($h.Length % 4 -ne 0) { $h = ('0' * (4 - ($h.Length % 4))) + $h }
    return $h
}
