# =============================================================================
#  CampusNet.Tests.ps1 —— Pester 单元测试
# =============================================================================
#  跑法（在仓库根目录）：
#      Invoke-Pester .\tests
#    或
#      .\tests\Run-Tests.ps1
#
#  兼容内置的 Pester 3.4.0（Windows 10/11 自带），不需要额外装模块。
#
#  设计说明：
#    CampusNet.ps1 平时是"加载即执行"的，为了能测它的函数，脚本入口处加了
#    一个 dot-source 守卫：被 `. .\CampusNet.ps1` 引入时只加载函数、不跑主流程。
# =============================================================================

$here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $here
$script:MainScript = Join-Path $repoRoot 'CampusNet.ps1'

# 把被测脚本的函数加载进来（守卫保证不会真的去登录）
. $script:MainScript

Describe 'Get-CnConfig 配置默认值' {

    $tmpDir = Join-Path $env:TEMP ('cn_test_' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null

    It '空配置也能套上全部默认值' {
        $p = Join-Path $tmpDir 'minimal.json'
        '{"userId":"u1","password":"p1"}' | Set-Content -LiteralPath $p -Encoding UTF8
        $cfg = Get-CnConfig -Path $p

        $cfg.userId | Should Be 'u1'
        $cfg.retryCount | Should Be 5
        $cfg.retryDelaySec | Should Be 6
        $cfg.timeoutSec | Should Be 10
        $cfg.treatAlreadyOnlineAsSuccess | Should Be $true
        $cfg.gameGuard | Should Be $true
    }

    It 'checkUrls 为空时回落到默认探测地址' {
        $p = Join-Path $tmpDir 'emptyurls.json'
        '{"userId":"u","password":"p","checkUrls":[]}' | Set-Content -LiteralPath $p -Encoding UTF8
        $cfg = Get-CnConfig -Path $p
        @($cfg.checkUrls).Count | Should BeGreaterThan 0
    }

    It 'retryCount 小于 1 时被纠正为 1' {
        $p = Join-Path $tmpDir 'badretry.json'
        '{"userId":"u","password":"p","retryCount":0}' | Set-Content -LiteralPath $p -Encoding UTF8
        $cfg = Get-CnConfig -Path $p
        $cfg.retryCount | Should Be 1
    }

    It 'logFile 里的环境变量会被展开' {
        $p = Join-Path $tmpDir 'envlog.json'
        '{"userId":"u","password":"p","logFile":"%LOCALAPPDATA%\\X\\y.log"}' | Set-Content -LiteralPath $p -Encoding UTF8
        $cfg = Get-CnConfig -Path $p
        $cfg.logFile | Should Not Match '%LOCALAPPDATA%'
    }

    It '配置文件不存在时抛出明确错误' {
        { Get-CnConfig -Path (Join-Path $tmpDir 'nope.json') } | Should Throw
    }

    Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Get-CnWatchList 游戏守护名单归一化' {

    $cfg = [pscustomobject]@{
        gameGuard     = $true
        gameProcesses = @('Valorant.exe', ' CS2 ', 'leagueclient', '', '   ')
    }

    It '去掉 .exe 后缀、转小写、丢掉空项' {
        $list = @(Get-CnWatchList -Cfg $cfg)
        $list.Count | Should Be 3
        # 不用 Should Contain —— Pester 3.4 那个断言拿到数组会当文件路径去解析
        ($list -contains 'valorant') | Should Be $true
        ($list -contains 'cs2') | Should Be $true
        ($list -contains 'leagueclient') | Should Be $true
    }

    It 'gameGuard 关闭时返回空列表' {
        $c2 = [pscustomobject]@{ gameGuard = $false; gameProcesses = @('valorant') }
        @(Get-CnWatchList -Cfg $c2).Count | Should Be 0
    }
}

Describe 'Test-CnGameRunning 进程匹配' {

    It '命中时返回进程名' {
        $cfg = [pscustomobject]@{ gameGuard = $true; gameProcesses = @('notepad') }
        Mock Get-Process { [pscustomobject]@{ ProcessName = 'notepad' } }
        Test-CnGameRunning -Cfg $cfg | Should Be 'notepad'
    }

    It '没命中时返回 null' {
        $cfg = [pscustomobject]@{ gameGuard = $true; gameProcesses = @('valorant') }
        Mock Get-Process { [pscustomobject]@{ ProcessName = 'explorer' } }
        Test-CnGameRunning -Cfg $cfg | Should BeNullOrEmpty
    }

    It '大小写不敏感' {
        $cfg = [pscustomobject]@{ gameGuard = $true; gameProcesses = @('VALORANT') }
        Mock Get-Process { [pscustomobject]@{ ProcessName = 'Valorant' } }
        Test-CnGameRunning -Cfg $cfg | Should Not BeNullOrEmpty
    }
}

Describe 'Test-CnOnline 联网判定' {

    $baseCfg = [pscustomobject]@{
        checkUrls    = @('http://probe.invalid/generate_204')
        timeoutSec   = 5
        gameGuard    = $false
        gameProcesses = @()
    }

    It '302 跳到门户 => 离线，并带出门户地址' {
        Mock Invoke-CnHttp {
            [pscustomobject]@{ StatusCode = 302; Location = 'http://10.0.0.1/eportal/index.jsp?wlanuserip=abc'; Body = ''; FinalUrl = '' }
        }
        $r = Test-CnOnline -Cfg $baseCfg
        $r.Online | Should Be $false
        $r.PortalUrl | Should Match 'eportal'
    }

    It '302 跳到非门户 => 离线，但没有门户地址' {
        Mock Invoke-CnHttp {
            [pscustomobject]@{ StatusCode = 302; Location = 'http://example.com/'; Body = ''; FinalUrl = '' }
        }
        $r = Test-CnOnline -Cfg $baseCfg
        $r.Online | Should Be $false
        $r.PortalUrl | Should BeNullOrEmpty
    }

    It '204 => 在线' {
        Mock Invoke-CnHttp {
            [pscustomobject]@{ StatusCode = 204; Location = $null; Body = ''; FinalUrl = '' }
        }
        (Test-CnOnline -Cfg $baseCfg).Online | Should Be $true
    }

    It '200 且响应体里藏了门户地址 => 离线（劫持返回 200+HTML 的常见形态）' {
        Mock Invoke-CnHttp {
            [pscustomobject]@{
                StatusCode = 200
                Location   = $null
                Body       = "<script>location.href='http://10.0.0.1/eportal/index.jsp?wlanuserip=xyz';</script>"
                FinalUrl   = ''
            }
        }
        $r = Test-CnOnline -Cfg $baseCfg
        $r.Online | Should Be $false
        $r.PortalUrl | Should Match 'eportal'
    }

    It '200 且是干净响应 => 在线' {
        Mock Invoke-CnHttp {
            [pscustomobject]@{ StatusCode = 200; Location = $null; Body = '<html>ok</html>'; FinalUrl = '' }
        }
        (Test-CnOnline -Cfg $baseCfg).Online | Should Be $true
    }

    It '探测全部抛异常 => 离线（保守判定）' {
        Mock Invoke-CnHttp { throw 'network down' }
        (Test-CnOnline -Cfg $baseCfg).Online | Should Be $false
    }
}

Describe 'ConvertTo-CnDoubleEncoded 双重编码' {

    It '等价于 encodeURIComponent(encodeURIComponent(x))' {
        # & 单层编码是 %26，双层是 %2526
        ConvertTo-CnDoubleEncoded 'a&b' | Should Be 'a%2526b'
    }

    It '等号双层的正确形式' {
        ConvertTo-CnDoubleEncoded 'a=b' | Should Be 'a%253Db'
    }

    It '空串返回空串' {
        ConvertTo-CnDoubleEncoded '' | Should Be ''
    }
}

Describe 'Reverse-String / RSA 输入预处理契约' {

    It '空串输入时 SrunRsa 返回空串（与门户原版一致，不是一个空块）' {
        . (Join-Path $repoRoot 'lib\SrunRsa.ps1')
        $mod = 'f60fc3ee3a1886e7bed85388dc0a862c1a45fedb9d59abddf0e6f16c829645106690235100bf1aec52e74cb6a7905dc1d8c1eba610fd982653121299e6c21c1450f54ec3c5e4fe465edba75d9ac141fbd7f3b5024cf1f1f86852cf26c0f14b5b1c3fcf3d4880b07fb2690d951fc8e3b9431d39e1ca53f0c5a194f22fb944caab'
        ConvertTo-SrunRsa -PlainText '' -ExponentHex '10001' -ModulusHex $mod | Should Be ''
    }
}
