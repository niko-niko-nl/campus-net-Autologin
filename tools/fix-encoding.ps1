# Re-save all .ps1 files as UTF-8 WITH BOM.
# Windows PowerShell 5.1 reads BOM-less .ps1 as ANSI/GBK, which corrupts
# non-ASCII text and can even break parsing. Keep this ASCII-only.
param([string]$Root = (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)))

$utf8Bom = New-Object System.Text.UTF8Encoding($true)
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$files = Get-ChildItem -Path $Root -Filter *.ps1 -Recurse -File
foreach ($f in $files) {
    $text = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText($f.FullName, $text, $utf8Bom)
    Write-Host ("[BOM] " + $f.FullName)
}
Write-Host ("done: " + $files.Count + " file(s)")
