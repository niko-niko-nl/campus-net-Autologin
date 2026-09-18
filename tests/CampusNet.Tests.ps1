# =============================================================================
#  CampusNet.Tests.ps1 —— 单元测试
# =============================================================================
#  跑法（在仓库根目录）：
#      powershell -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
#    或
#      Invoke-Pester .\tests
#
#  兼容性（踩过坑，别改回去）：
#
#  1) 断言不用 Pester 的 Should，改用 tests\Assertions.ps1 里的 Assert-*。
#     Pester 3.4（Windows 自带）只认 `Should Be`，Pester 5.x（CI runner 自带）
#     只认 `Should -Be`，两边互斥、没有通吃的写法。Assert-* 失败就 throw，
#     任何 Pester 都会把它记为失败。
#
#  2) 被测函数必须在每个 Describe 的 BeforeAll 里 dot-source，不能写在文件顶层。
#     Pester 5 的 It 块运行在另一个作用域，顶层 dot-source 进来的函数在 It 里
#     会 CommandNotFoundException（实测 20 项全挂）。
#
#  3) 同理，Describe 体里直接赋值的变量在 Pester 5 下也拿不到，一律放 BeforeAll。
# =============================================================================

Describe 'Get-CnConfig 配置默认值' {

    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'CampusNet.ps1')
        . (Join-Path $PSScriptRoot 'Assertions.ps1')
        $tmpDir = Join-Path $env:TEMP ('cn_test_' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
    }

    AfterAll {
        if ($tmpDir) { Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It '空配置也能套上全部默认值' {
        $p = Join-Path $tmpDir 'minimal.json'
        '{"userId":"u1","password":"p1"}' | Set-Content -LiteralPath $p -Encoding UTF8
        $cfg = Get-CnConfig -Path $p

        Assert-Equal $cfg.userId 'u1'
        Assert-Equal $cfg.retryCount 5
        Assert-Equal $cfg.retryDelaySec 6
        Assert-Equal $cfg.timeoutSec 10
        Assert-Equal $cfg.treatAlreadyOnlineAsSuccess $true
        Assert-Equal $cfg.gameGuard $true
    }

    It 'checkUrls 为空时回落到默认探测地址' {
        $p = Join-Path $tmpDir 'emptyurls.json'
        '{"userId":"u","password":"p","checkUrls":[]}' | Set-Content -LiteralPath $p -Encoding UTF8
        $cfg = Get-CnConfig -Path $p
        Assert-GreaterThan @($cfg.checkUrls).Count 0
    }

    It 'retryCount 小于 1 时被纠正为 1' {
        $p = Join-Path $tmpDir 'badretry.json'
        '{"userId":"u","password":"p","retryCount":0}' | Set-Content -LiteralPath $p -Encoding UTF8
        $cfg = Get-CnConfig -Path $p
        Assert-Equal $cfg.retryCount 1
    }

    It 'logFile 里的环境变量会被展开' {
        $p = Join-Path $tmpDir 'envlog.json'
        '{"userId":"u","password":"p","logFile":"%LOCALAPPDATA%\\X\\y.log"}' | Set-Content -LiteralPath $p -Encoding UTF8
        $cfg = Get-CnConfig -Path $p
        Assert-NotMatch $cfg.logFile '%LOCALAPPDATA%'
    }

    It '配置文件不存在时抛出明确错误' {
        Assert-Throws { Get-CnConfig -Path (Join-Path $tmpDir 'nope.json') }
    }
}

Describe 'Get-CnWatchList 游戏守护名单归一化' {

    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'CampusNet.ps1')
        . (Join-Path $PSScriptRoot 'Assertions.ps1')
        $cfg = [pscustomobject]@{
            gameGuard     = $true
            gameProcesses = @('Valorant.exe', ' CS2 ', 'leagueclient', '', '   ')
        }
    }

    It '去掉 .exe 后缀、转小写、丢掉空项' {
        $list = @(Get-CnWatchList -Cfg $cfg)
        Assert-Equal $list.Count 3
        Assert-Contains $list 'valorant'
        Assert-Contains $list 'cs2'
        Assert-Contains $list 'leagueclient'
    }

    It 'gameGuard 关闭时返回空列表' {
        $c2 = [pscustomobject]@{ gameGuard = $false; gameProcesses = @('valorant') }
        Assert-Equal @(Get-CnWatchList -Cfg $c2).Count 0
    }
}

Describe 'Test-CnGameRunning 进程匹配' {

    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'CampusNet.ps1')
        . (Join-Path $PSScriptRoot 'Assertions.ps1')
    }

    It '命中时返回进程名' {
        $cfg = [pscustomobject]@{ gameGuard = $true; gameProcesses = @('notepad') }
        Mock Get-Process { [pscustomobject]@{ ProcessName = 'notepad' } }
        Assert-Equal (Test-CnGameRunning -Cfg $cfg) 'notepad'
    }

    It '没命中时返回 null' {
        $cfg = [pscustomobject]@{ gameGuard = $true; gameProcesses = @('valorant') }
        Mock Get-Process { [pscustomobject]@{ ProcessName = 'explorer' } }
        Assert-Empty (Test-CnGameRunning -Cfg $cfg)
    }

    It '大小写不敏感' {
        $cfg = [pscustomobject]@{ gameGuard = $true; gameProcesses = @('VALORANT') }
        Mock Get-Process { [pscustomobject]@{ ProcessName = 'Valorant' } }
        Assert-NotEmpty (Test-CnGameRunning -Cfg $cfg)
    }
}

Describe 'Test-CnOnline 联网判定' {

    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'CampusNet.ps1')
        . (Join-Path $PSScriptRoot 'Assertions.ps1')
        $baseCfg = [pscustomobject]@{
            checkUrls     = @('http://probe.invalid/generate_204')
            timeoutSec    = 5
            gameGuard     = $false
            gameProcesses = @()
        }
    }

    It '302 跳到门户 => 离线，并带出门户地址' {
        Mock Invoke-CnHttp {
            [pscustomobject]@{ StatusCode = 302; Location = 'http://10.0.0.1/eportal/index.jsp?wlanuserip=abc'; Body = ''; FinalUrl = '' }
        }
        $r = Test-CnOnline -Cfg $baseCfg
        Assert-Equal $r.Online $false
        Assert-Match $r.PortalUrl 'eportal'
    }

    It '302 跳到非门户 => 离线，但没有门户地址' {
        Mock Invoke-CnHttp {
            [pscustomobject]@{ StatusCode = 302; Location = 'http://example.com/'; Body = ''; FinalUrl = '' }
        }
        $r = Test-CnOnline -Cfg $baseCfg
        Assert-Equal $r.Online $false
        Assert-Empty $r.PortalUrl
    }

    It '204 => 在线' {
        Mock Invoke-CnHttp {
            [pscustomobject]@{ StatusCode = 204; Location = $null; Body = ''; FinalUrl = '' }
        }
        Assert-Equal (Test-CnOnline -Cfg $baseCfg).Online $true
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
        Assert-Equal $r.Online $false
        Assert-Match $r.PortalUrl 'eportal'
    }

    It '200 且是干净响应 => 在线' {
        Mock Invoke-CnHttp {
            [pscustomobject]@{ StatusCode = 200; Location = $null; Body = '<html>ok</html>'; FinalUrl = '' }
        }
        Assert-Equal (Test-CnOnline -Cfg $baseCfg).Online $true
    }

    It '探测全部抛异常 => 离线（保守判定）' {
        Mock Invoke-CnHttp { throw 'network down' }
        Assert-Equal (Test-CnOnline -Cfg $baseCfg).Online $false
    }
}

Describe 'ConvertTo-CnDoubleEncoded 双重编码' {

    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'CampusNet.ps1')
        . (Join-Path $PSScriptRoot 'Assertions.ps1')
    }

    It '等价于 encodeURIComponent(encodeURIComponent(x))' {
        # & 单层编码是 %26，双层是 %2526
        Assert-Equal (ConvertTo-CnDoubleEncoded 'a&b') 'a%2526b'
    }

    It '等号双层的正确形式' {
        Assert-Equal (ConvertTo-CnDoubleEncoded 'a=b') 'a%253Db'
    }

    It '空串返回空串' {
        Assert-Equal (ConvertTo-CnDoubleEncoded '') ''
    }
}

Describe 'SrunRsa 空串契约' {

    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\SrunRsa.ps1')
        . (Join-Path $PSScriptRoot 'Assertions.ps1')
        $mod = 'f60fc3ee3a1886e7bed85388dc0a862c1a45fedb9d59abddf0e6f16c829645106690235100bf1aec52e74cb6a7905dc1d8c1eba610fd982653121299e6c21c1450f54ec3c5e4fe465edba75d9ac141fbd7f3b5024cf1f1f86852cf26c0f14b5b1c3fcf3d4880b07fb2690d951fc8e3b9431d39e1ca53f0c5a194f22fb944caab'
    }

    It '空串输入返回空串（与门户原版一致，不是一个空块）' {
        Assert-Equal (ConvertTo-SrunRsa -PlainText '' -ExponentHex '10001' -ModulusHex $mod) ''
    }
}

Describe 'Get-CnPortalUrl 门户地址抓取' {

    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'CampusNet.ps1')
        . (Join-Path $PSScriptRoot 'Assertions.ps1')
        # 这里只关心返回值，日志没必要真写到文件里
        Mock Write-CnLog { }

        $cfg = [pscustomobject]@{
            checkUrls  = @('http://probe.invalid/generate_204')
            timeoutSec = 5
            portalHost = '10.130.128.9'
        }
        $cfgNoHost = [pscustomobject]@{
            checkUrls  = @('http://probe.invalid/generate_204')
            timeoutSec = 5
            portalHost = ''
        }
    }

    It '302 直接跳到门户 => 返回 Location' {
        Mock Invoke-CnHttp {
            [pscustomobject]@{ StatusCode = 302; Location = 'http://10.0.0.1/eportal/index.jsp?wlanuserip=abc'; Body = ''; FinalUrl = '' }
        }
        Assert-Equal (Get-CnPortalUrl -Cfg $cfg) 'http://10.0.0.1/eportal/index.jsp?wlanuserip=abc'
    }

    It '302 先跳到别处 => 跟一次重定向，用最终地址' {
        Mock Invoke-CnHttp {
            if ($Url -like '*probe.invalid*') {
                return [pscustomobject]@{ StatusCode = 302; Location = 'http://portal.example/where'; Body = ''; FinalUrl = '' }
            }
            [pscustomobject]@{ StatusCode = 200; Location = $null; Body = ''; FinalUrl = 'http://10.0.0.2/eportal/index.jsp?wlanuserip=def' }
        }
        Assert-Equal (Get-CnPortalUrl -Cfg $cfg) 'http://10.0.0.2/eportal/index.jsp?wlanuserip=def'
    }

    It '200 且响应体里是 JS 跳转 => 从正文里抓出来' {
        Mock Invoke-CnHttp {
            [pscustomobject]@{
                StatusCode = 200
                Location   = $null
                Body       = "<html><script>location.href='http://10.0.0.3/eportal/index.jsp?wlanuserip=ghi';</script></html>"
                FinalUrl   = ''
            }
        }
        Assert-Equal (Get-CnPortalUrl -Cfg $cfg) 'http://10.0.0.3/eportal/index.jsp?wlanuserip=ghi'
    }

    It '探不到任何线索 => 用 portalHost 兜底，跟一次拿到带参数的地址' {
        Mock Invoke-CnHttp {
            if ($Url -like '*probe.invalid*') { throw 'network down' }
            [pscustomobject]@{ StatusCode = 200; Location = $null; Body = ''; FinalUrl = 'http://10.130.128.9/eportal/index.jsp?wlanuserip=zzz' }
        }
        Assert-Equal (Get-CnPortalUrl -Cfg $cfg) 'http://10.130.128.9/eportal/index.jsp?wlanuserip=zzz'
    }

    It '兜底地址也拿不到参数 => 返回 null（交给上层当 Fatal 处理）' {
        Mock Invoke-CnHttp {
            if ($Url -like '*probe.invalid*') { throw 'network down' }
            [pscustomobject]@{ StatusCode = 200; Location = $null; Body = ''; FinalUrl = 'http://10.130.128.9/eportal/index.jsp' }
        }
        Assert-Empty (Get-CnPortalUrl -Cfg $cfg)
    }

    It '没有 portalHost 又探不到 => 返回 null' {
        Mock Invoke-CnHttp { throw 'network down' }
        Assert-Empty (Get-CnPortalUrl -Cfg $cfgNoHost)
    }
}

Describe 'Invoke-CnLogin 登录流程' {

    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'CampusNet.ps1')
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\SrunRsa.ps1')
        . (Join-Path $PSScriptRoot 'Assertions.ps1')

        # 关键：把日志函数挡掉。登录流程里到处是 Write-CnLog，不挡的话可能写到
        # 真实的 %LOCALAPPDATA%\CampusNet\login.log，污染用户那份日志。
        Mock Write-CnLog { }

        $portal = 'http://10.0.0.1/eportal/index.jsp?wlanuserip=abc&mac=112233445566&nasip=10.0.0.9'

        # mock 的 body 里一律只写字面量：Pester 3.4 和 5.x 下 mock 执行时的
        # 作用域不完全一样，引用外层变量或外层函数很容易踩空。要改配置就在
        # It 里用 PSObject.Copy() 派生一份。
        $cfgBase = [pscustomobject]@{
            userId                      = 'student1'
            password                    = 'pw123456'
            passwordEncrypted           = ''
            service                     = ''
            portalHost                  = '10.0.0.1'
            checkUrls                   = @('http://probe.invalid/generate_204')
            logFile                     = ''
            retryCount                  = 1
            retryDelaySec               = 1
            timeoutSec                  = 5
            treatAlreadyOnlineAsSuccess = $true
            gameGuard                   = $false
            gameProcesses               = @()
        }
    }

    It '登录成功 => Success，带出 userIndex 和保活间隔' {
        Mock Invoke-CnHttp {
            if ($Url -like '*pageInfo*') {
                return [pscustomobject]@{ StatusCode = 200; Location = $null; Body = '{"passwordEncrypt":"false"}'; FinalUrl = '' }
            }
            [pscustomobject]@{ StatusCode = 200; Location = $null; Body = '{"result":"success","userIndex":"u-42","keepaliveInterval":60,"message":"ok"}'; FinalUrl = '' }
        }
        $r = Invoke-CnLogin -Cfg $cfgBase -PortalUrl $portal
        Assert-True $r.Success
        Assert-Equal $r.UserIndex 'u-42'
        Assert-Equal $r.KeepaliveInterval 60
    }

    It 'DryRun 报文字段和双重编码都对（不真正提交）' {
        Mock Invoke-CnHttp {
            [pscustomobject]@{ StatusCode = 200; Location = $null; Body = '{"passwordEncrypt":"false"}'; FinalUrl = '' }
        }
        $cfg = $cfgBase.PSObject.Copy()
        $cfg.userId = '5101&x'
        $cfg.password = 'p=w'

        $r = Invoke-CnLogin -Cfg $cfg -PortalUrl $portal -DryRun
        Assert-True $r.Success
        Assert-True $r.DryRun
        Assert-Match $r.LoginBody 'userId=5101%2526x'                      # & 双层编码
        Assert-Match $r.LoginBody 'password=p%253Dw'                        # = 双层编码
        Assert-Match $r.LoginBody 'queryString=wlanuserip%253Dabc'
        Assert-Match $r.LoginBody 'passwordEncrypt=false'
        Assert-Match $r.LoginBody 'operatorPwd=&operatorUserId=&validcode='
    }

    It '服务端说已存在在线用户 => 按成功处理（设备上已经有会话）' {
        Mock Invoke-CnHttp {
            if ($Url -like '*pageInfo*') {
                return [pscustomobject]@{ StatusCode = 200; Location = $null; Body = '{"passwordEncrypt":"false"}'; FinalUrl = '' }
            }
            [pscustomobject]@{ StatusCode = 200; Location = $null; Body = '{"result":"fail","message":"该账号已存在在线用户"}'; FinalUrl = '' }
        }
        $r = Invoke-CnLogin -Cfg $cfgBase -PortalUrl $portal
        Assert-True $r.Success
        Assert-True $r.AlreadyOnline
    }

    It 'treatAlreadyOnlineAsSuccess=false 时同样的响应算失败' {
        Mock Invoke-CnHttp {
            if ($Url -like '*pageInfo*') {
                return [pscustomobject]@{ StatusCode = 200; Location = $null; Body = '{"passwordEncrypt":"false"}'; FinalUrl = '' }
            }
            [pscustomobject]@{ StatusCode = 200; Location = $null; Body = '{"result":"fail","message":"该账号已存在在线用户"}'; FinalUrl = '' }
        }
        $cfg = $cfgBase.PSObject.Copy()
        $cfg.treatAlreadyOnlineAsSuccess = $false

        $r = Invoke-CnLogin -Cfg $cfg -PortalUrl $portal
        Assert-False $r.Success
        # 注意别去取 $r.AlreadyOnline：这条分支返回的对象里根本没这个属性，
        # dot-source 进来的 Set-StrictMode 2.0 会直接抛 PropertyNotFoundException
        Assert-Match $r.Message '已存在在线用户'
    }

    It '服务名报错 => 用门户返回的第一个服务名重试一次' {
        # 服务对象只有一项时脚本不会自动挑，service 保持空 -> 服务端报服务名错
        # -> 脚本拿 $props[0].Name 重试一次
        Mock Invoke-CnHttp {
            if ($Url -like '*pageInfo*') {
                return [pscustomobject]@{
                    StatusCode = 200; Location = $null; FinalUrl = ''
                    Body = '{"passwordEncrypt":"false","service":{"中国电信":{"serviceDefault":"true"}}}'
                }
            }
            if ($Body -match 'service=&') {
                return [pscustomobject]@{ StatusCode = 200; Location = $null; Body = '{"result":"fail","message":"服务名不正确"}'; FinalUrl = '' }
            }
            [pscustomobject]@{ StatusCode = 200; Location = $null; Body = '{"result":"success","userIndex":"u-retry","message":"ok"}'; FinalUrl = '' }
        }
        $r = Invoke-CnLogin -Cfg $cfgBase -PortalUrl $portal
        Assert-True $r.Success
        Assert-Equal $r.UserIndex 'u-retry'
    }

    It '门户开了图形验证码 => Fatal，而且根本不提交 login' {
        Mock Invoke-CnHttp {
            if ($Url -notlike '*pageInfo*') { throw '验证码开着的时候不该去提交登录' }
            [pscustomobject]@{ StatusCode = 200; Location = $null; Body = '{"passwordEncrypt":"false","validCodeUrl":"/eportal/validcode.jsp"}'; FinalUrl = '' }
        }
        $r = Invoke-CnLogin -Cfg $cfgBase -PortalUrl $portal
        Assert-False $r.Success
        Assert-True $r.Fatal
        Assert-Match $r.Message '验证码'
    }

    It 'pageInfo 不是 JSON => 普通失败（可重试，不是 Fatal）' {
        Mock Invoke-CnHttp {
            [pscustomobject]@{ StatusCode = 200; Location = $null; Body = '<html>500</html>'; FinalUrl = '' }
        }
        $r = Invoke-CnLogin -Cfg $cfgBase -PortalUrl $portal
        Assert-False $r.Success
        Assert-False $r.Fatal
    }

    It 'login 返回不是 JSON => 普通失败' {
        Mock Invoke-CnHttp {
            if ($Url -like '*pageInfo*') {
                return [pscustomobject]@{ StatusCode = 200; Location = $null; Body = '{"passwordEncrypt":"false"}'; FinalUrl = '' }
            }
            [pscustomobject]@{ StatusCode = 200; Location = $null; Body = 'gateway timeout'; FinalUrl = '' }
        }
        $r = Invoke-CnLogin -Cfg $cfgBase -PortalUrl $portal
        Assert-False $r.Success
        Assert-False $r.Fatal
    }

    It '门户地址不像 eportal => Fatal，不发任何请求' {
        Mock Invoke-CnHttp { throw '不该发请求' }
        $r = Invoke-CnLogin -Cfg $cfgBase -PortalUrl 'http://example.com/login'
        Assert-False $r.Success
        Assert-True $r.Fatal
    }

    It '拿不到门户地址 => Fatal' {
        Mock Get-CnPortalUrl { $null }
        Mock Invoke-CnHttp { throw '不该发请求' }
        $r = Invoke-CnLogin -Cfg $cfgBase
        Assert-False $r.Success
        Assert-True $r.Fatal
    }

    It 'passwordEncrypt=true => 走 RSA，报文里带的是密文不是明文' {
        Mock Invoke-CnHttp {
            [pscustomobject]@{
                StatusCode = 200; Location = $null; FinalUrl = ''
                Body = '{"passwordEncrypt":"true","publicKeyExponent":"10001","publicKeyModulus":"f60fc3ee3a1886e7bed85388dc0a862c1a45fedb9d59abddf0e6f16c829645106690235100bf1aec52e74cb6a7905dc1d8c1eba610fd982653121299e6c21c1450f54ec3c5e4fe465edba75d9ac141fbd7f3b5024cf1f1f86852cf26c0f14b5b1c3fcf3d4880b07fb2690d951fc8e3b9431d39e1ca53f0c5a194f22fb944caab"}'
            }
        }
        $r = Invoke-CnLogin -Cfg $cfgBase -PortalUrl $portal -DryRun
        Assert-True $r.Success
        Assert-Match $r.LoginBody 'passwordEncrypt=true'
        Assert-NotMatch $r.LoginBody 'password=pw123456'
    }
}
