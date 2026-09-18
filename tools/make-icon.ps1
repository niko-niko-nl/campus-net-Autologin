#Requires -Version 5.1
<#
=============================================================================
  make-icon.ps1 —— 生成程序图标 app.ico
=============================================================================
  用 System.Drawing 画一个圆角方块 + 白色字符，再按 ICO 容器格式封装。
  Vista 以上支持 PNG 压缩的 ICO 条目，所以直接塞 PNG 即可。
=============================================================================
#>
[CmdletBinding()]
param(
    [string]$OutFile,
    [string]$Glyph = '网'
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

if (-not $OutFile) { $OutFile = Join-Path $PSScriptRoot 'app.ico' }

$sizes = @(16, 32, 48, 64, 128, 256)
$pngs = @()

foreach ($size in $sizes) {
    $bmp = New-Object System.Drawing.Bitmap($size, $size)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $g.Clear([System.Drawing.Color]::Transparent)

    # 圆角方块背景
    $pad = [Math]::Max(1, [int]($size * 0.04))
    $rect = New-Object System.Drawing.Rectangle($pad, $pad, ($size - 2 * $pad), ($size - 2 * $pad))
    $radius = [int]($size * 0.22)
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = 2 * $radius
    $path.AddArc($rect.X, $rect.Y, $d, $d, 180, 90)
    $path.AddArc(($rect.Right - $d), $rect.Y, $d, $d, 270, 90)
    $path.AddArc(($rect.Right - $d), ($rect.Bottom - $d), $d, $d, 0, 90)
    $path.AddArc($rect.X, ($rect.Bottom - $d), $d, $d, 90, 90)
    $path.CloseFigure()

    $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        $rect,
        [System.Drawing.Color]::FromArgb(255, 0, 120, 212),
        [System.Drawing.Color]::FromArgb(255, 0, 78, 152),
        [System.Drawing.Drawing2D.LinearGradientMode]::ForwardDiagonal)
    $g.FillPath($brush, $path)

    # 白色字符
    $fontSize = [float]($size * 0.58)
    $font = New-Object System.Drawing.Font('Microsoft YaHei', $fontSize, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    $fmt = New-Object System.Drawing.StringFormat
    $fmt.Alignment = [System.Drawing.StringAlignment]::Center
    $fmt.LineAlignment = [System.Drawing.StringAlignment]::Center
    $white = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
    $g.DrawString($Glyph, $font, $white, (New-Object System.Drawing.RectangleF(0, 0, $size, $size)), $fmt)

    $g.Dispose()

    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $pngs += , @{ Size = $size; Bytes = $ms.ToArray() }
    $ms.Dispose()
    $bmp.Dispose()
    $brush.Dispose(); $font.Dispose(); $white.Dispose(); $path.Dispose()
}

# ---- 封装成 ICO ----
$fs = [System.IO.File]::Create($OutFile)
$bw = New-Object System.IO.BinaryWriter($fs)
try {
    $bw.Write([UInt16]0)              # reserved
    $bw.Write([UInt16]1)              # type = icon
    $bw.Write([UInt16]$pngs.Count)    # count

    $offset = 6 + 16 * $pngs.Count
    foreach ($p in $pngs) {
        $dim = if ($p.Size -ge 256) { 0 } else { $p.Size }
        $bw.Write([Byte]$dim)         # width
        $bw.Write([Byte]$dim)         # height
        $bw.Write([Byte]0)            # color count
        $bw.Write([Byte]0)            # reserved
        $bw.Write([UInt16]1)          # planes
        $bw.Write([UInt16]32)         # bpp
        $bw.Write([UInt32]$p.Bytes.Length)
        $bw.Write([UInt32]$offset)
        $offset += $p.Bytes.Length
    }
    foreach ($p in $pngs) { $bw.Write($p.Bytes) }
} finally {
    $bw.Flush(); $bw.Close(); $fs.Dispose()
}

Write-Host ("[OK] 图标已生成：{0} ({1:N0} B, {2} 个尺寸)" -f $OutFile, (Get-Item $OutFile).Length, $pngs.Count) -ForegroundColor Green
