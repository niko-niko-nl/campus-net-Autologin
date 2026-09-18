# Re-save every source file that may contain non-ASCII as UTF-8 WITH BOM.
#
#   .ps1  Windows PowerShell 5.1 reads a BOM-less .ps1 as ANSI/GBK, which
#         corrupts Chinese text and can even break parsing (a mangled string
#         can swallow the closing quote and turn the rest into operators).
#   .cs   csc is invoked with /codepage:65001, but a BOM is what actually
#         makes the file self-describing. Keep it consistent with the .ps1 rule
#         so a hand-run csc without /codepage still works.
#
# This file itself stays ASCII-only on purpose.
param([string]$Root = (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)))

$utf8Bom = New-Object System.Text.UTF8Encoding($true)

$files = @()
$files += Get-ChildItem -Path $Root -Filter *.ps1 -Recurse -File -ErrorAction SilentlyContinue
$files += Get-ChildItem -Path $Root -Filter *.psm1 -Recurse -File -ErrorAction SilentlyContinue
$files += Get-ChildItem -Path $Root -Filter *.cs  -Recurse -File -ErrorAction SilentlyContinue

# Skip generated / third-party files
$files = $files | Where-Object {
    $_.Name -ne 'Setup.generated.cs' -and $_.Name -ne 'security.js'
}

$n = 0
foreach ($f in $files) {
    $text = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText($f.FullName, $text, $utf8Bom)
    $n++
    Write-Host ("[BOM] " + $f.FullName)
}
Write-Host ("done: " + $n + " file(s)")
