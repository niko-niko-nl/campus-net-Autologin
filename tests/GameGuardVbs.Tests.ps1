# =============================================================================
#  GameGuardVbs.Tests.ps1 —— run-hidden.vbs（第一层游戏守护）的 smoke 测试
# =============================================================================
#  为什么单独测这一层：游戏守护真正起作用的就是它。CampusNet.ps1 里那层只是
#  手动运行时的兜底，而 VBS 这层决定了「游戏期间会不会多出一个 PowerShell
#  进程」。在这之前这层完全没有测试。
#
#  做法：把 run-hidden.vbs 复制到临时目录，放一个 gameguard.lst，再放一个
#  「诱饵」CampusNet.ps1 —— 守护一旦失效，VBS 会真的把诱饵拉起来，诱饵就会
#  写下一个标记文件。断言标记文件不出现，比去数进程数可靠得多：powershell.exe
#  可能起来就又退了，数进程经常抓不到。
#
#  还带一个反向对照：名单故意写一个不存在的进程名，诱饵必须被拉起来。没有这
#  一步的话，cscript 根本没跑成功时测试也会「通过」。
#
#  名单里放的是当前测试进程自己的名字（powershell / pwsh），它在本地和 CI 上
#  都一定在跑；用 explorer.exe 这种就不一定了，CI runner 上未必有。
# =============================================================================

Describe 'run-hidden.vbs 第一层游戏守护' {

    BeforeAll {
        . (Join-Path $PSScriptRoot 'Assertions.ps1')

        $scriptRoot = Split-Path -Parent $PSScriptRoot
        $tmp = Join-Path $env:TEMP ('cn_vbs_' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $tmp | Out-Null

        $vbs     = Join-Path $tmp 'run-hidden.vbs'
        $lst     = Join-Path $tmp 'gameguard.lst'
        $log     = Join-Path $tmp 'login.log'
        $marker  = Join-Path $tmp 'ps-launched.txt'
        $decoy   = Join-Path $tmp 'CampusNet.ps1'
        $cscript = Join-Path $env:WINDIR 'System32\cscript.exe'

        Copy-Item -LiteralPath (Join-Path $scriptRoot 'run-hidden.vbs') -Destination $vbs -Force

        # 诱饵：被拉起来就留个标记。内容全是 ASCII，不需要 BOM。
        $content = @"
param([string]`$Mode, [switch]`$Quiet)
Set-Content -LiteralPath '$marker' -Value 'launched' -Encoding ASCII
"@
        Set-Content -LiteralPath $decoy -Value $content -Encoding ASCII

        # 一定在跑的进程名（就是跑测试的这个 powershell）
        $self = (Get-Process -Id $PID).ProcessName.ToLowerInvariant()

        if (-not (Test-Path -LiteralPath $cscript)) {
            throw "找不到 cscript.exe：$cscript"
        }
    }

    AfterAll {
        if ($tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It '名单命中正在运行的进程 => 不拉起 PowerShell，日志留下拦截记录' {
        Set-Content -LiteralPath $lst -Value $self -Encoding ASCII
        Remove-Item -LiteralPath $marker, $log -Force -ErrorAction SilentlyContinue

        & $cscript //B //NoLogo $vbs | Out-Null
        Assert-Equal $LASTEXITCODE 0

        # 反向等待：诱饵要是真被拉起来了，这几秒足够它写下标记
        $waited = 0
        while ($waited -lt 3000) {
            Start-Sleep -Milliseconds 250
            $waited += 250
            if (Test-Path -LiteralPath $marker) { break }
        }

        Assert-False (Test-Path -LiteralPath $marker)
        Assert-True (Test-Path -LiteralPath $log)
        $text = Get-Content -LiteralPath $log -Raw
        Assert-Match $text 'game guard'
        Assert-Match $text $self
        Assert-Match $text 'PowerShell not launched'
    }

    It '反向对照：名单没命中就正常拉起（证明上一条不是假通过）' {
        Set-Content -LiteralPath $lst -Value 'cn-definitely-not-running' -Encoding ASCII
        Remove-Item -LiteralPath $marker, $log -Force -ErrorAction SilentlyContinue

        & $cscript //B //NoLogo $vbs | Out-Null
        Assert-Equal $LASTEXITCODE 0

        $waited = 0
        while ($waited -lt 10000) {
            if (Test-Path -LiteralPath $marker) { break }
            Start-Sleep -Milliseconds 250
            $waited += 250
        }
        Assert-True (Test-Path -LiteralPath $marker)
    }

    It '没有 gameguard.lst => 照常拉起（删掉名单等于关掉这一层）' {
        Remove-Item -LiteralPath $lst -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue

        & $cscript //B //NoLogo $vbs | Out-Null
        Assert-Equal $LASTEXITCODE 0

        $waited = 0
        while ($waited -lt 10000) {
            if (Test-Path -LiteralPath $marker) { break }
            Start-Sleep -Milliseconds 250
            $waited += 250
        }
        Assert-True (Test-Path -LiteralPath $marker)
    }
}
