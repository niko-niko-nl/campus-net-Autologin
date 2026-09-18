# =============================================================================
#  Assertions.ps1 —— 版本无关的断言助手
# =============================================================================
#  为什么不用 Pester 自带的 Should：
#    Pester 3.4.0（Windows 10/11 自带）只认 `Should Be`（无横线）；
#    Pester 5.x（GitHub Actions runner 自带）只认 `Should -Be`（有横线），
#    并且会直接报 "Legacy Should syntax (without dashes) is not supported"。
#    实测两个版本语法互斥，没有两边通吃的写法。
#
#    所以这里不用 Should —— 断言失败就 throw，任何 Pester 版本都会把
#    抛异常的 It 记为失败。Describe / It / BeforeAll / Mock 这些结构在
#    3.4 和 5.x 上行为一致，照常用。
#
#  字符串比较默认区分大小写（-ceq）。PowerShell 的 -eq 对字符串不区分大小写，
#  那会把大小写相关的 bug 放过去。
# =============================================================================

function script:Format-Actual($Value) {
    if ($null -eq $Value) { return '<null>' }
    if ($Value -is [string]) { return "'" + $Value + "'" }
    return [string]$Value
}

function script:Test-ValuesEqual($Actual, $Expected) {
    if ($Actual -is [string] -or $Expected -is [string]) {
        return ($Actual -ceq $Expected)
    }
    return ($Actual -eq $Expected)
}

function Assert-Equal {
    param($Actual, $Expected, [string]$Because = '')
    if (-not (Test-ValuesEqual $Actual $Expected)) {
        $suffix = if ($Because) { " [$Because]" } else { '' }
        throw ("Assert-Equal failed: expected {0} but got {1}{2}" -f (Format-Actual $Expected), (Format-Actual $Actual), $suffix)
    }
}

function Assert-NotEqual {
    param($Actual, $NotExpected, [string]$Because = '')
    if (Test-ValuesEqual $Actual $NotExpected) {
        $suffix = if ($Because) { " [$Because]" } else { '' }
        throw ("Assert-NotEqual failed: did not expect {0}{1}" -f (Format-Actual $Actual), $suffix)
    }
}

function Assert-True {
    param($Condition, [string]$Because = '')
    if (-not $Condition) {
        $suffix = if ($Because) { " [$Because]" } else { '' }
        throw ("Assert-True failed: condition was false, got {0}{1}" -f (Format-Actual $Condition), $suffix)
    }
}

function Assert-False {
    param($Condition, [string]$Because = '')
    if ($Condition) {
        $suffix = if ($Because) { " [$Because]" } else { '' }
        throw ("Assert-False failed: condition was true{0}" -f $suffix)
    }
}

function Assert-Match {
    param([string]$Text, [string]$Pattern, [string]$Because = '')
    if ($Text -notmatch $Pattern) {
        $suffix = if ($Because) { " [$Because]" } else { '' }
        throw ("Assert-Match failed: {0} does not match /{1}/{2}" -f (Format-Actual $Text), $Pattern, $suffix)
    }
}

function Assert-NotMatch {
    param([string]$Text, [string]$Pattern, [string]$Because = '')
    if ($Text -match $Pattern) {
        $suffix = if ($Because) { " [$Because]" } else { '' }
        throw ("Assert-NotMatch failed: {0} unexpectedly matches /{1}/{2}" -f (Format-Actual $Text), $Pattern, $suffix)
    }
}

function Assert-Empty {
    param($Value, [string]$Because = '')
    $isEmpty = ($null -eq $Value) -or ([string]$Value -eq '') -or (@($Value).Count -eq 0)
    if (-not $isEmpty) {
        $suffix = if ($Because) { " [$Because]" } else { '' }
        throw ("Assert-Empty failed: expected empty but got {0}{1}" -f (Format-Actual $Value), $suffix)
    }
}

function Assert-NotEmpty {
    param($Value, [string]$Because = '')
    $isEmpty = ($null -eq $Value) -or ([string]$Value -eq '') -or (@($Value).Count -eq 0)
    if ($isEmpty) {
        $suffix = if ($Because) { " [$Because]" } else { '' }
        throw ("Assert-NotEmpty failed: value was empty{0}" -f $suffix)
    }
}

function Assert-GreaterThan {
    param($Actual, $Threshold, [string]$Because = '')
    if (-not ($Actual -gt $Threshold)) {
        $suffix = if ($Because) { " [$Because]" } else { '' }
        throw ("Assert-GreaterThan failed: expected > {0} but got {1}{2}" -f $Threshold, (Format-Actual $Actual), $suffix)
    }
}

function Assert-Throws {
    param([scriptblock]$ScriptBlock, [string]$Because = '')
    $threw = $false
    try { & $ScriptBlock | Out-Null } catch { $threw = $true }
    if (-not $threw) {
        $suffix = if ($Because) { " [$Because]" } else { '' }
        throw ("Assert-Throws failed: expected an exception but none was thrown{0}" -f $suffix)
    }
}

function Assert-Contains {
    param($Collection, $Item, [string]$Because = '')
    if (-not (@($Collection) -contains $Item)) {
        $suffix = if ($Because) { " [$Because]" } else { '' }
        throw ("Assert-Contains failed: collection does not contain {0}{1}" -f (Format-Actual $Item), $suffix)
    }
}
