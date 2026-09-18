# 维护者笔记

给自己看的。装这个工具的同学看 [README](../README.md) 就行了，这里全是开发和测试的细节。

## 目录结构

```
CampusNet.ps1            主脚本
install.ps1 / .bat       安装（自部署到 %LOCALAPPDATA%\CampusNet）
uninstall.ps1 / .bat     卸载
run.bat                  立刻登录一次
run-hidden.vbs           计划任务入口（静默 + 第一层游戏守护）
gameguard.default.txt    游戏进程名单的单一数据源，install.ps1 和 build\Setup.cs 都读它
lib\SrunRsa.ps1          门户密码加密
tools\
  gameguard-check.ps1    游戏守护自检
  test-rsa.ps1           RSA 实现回归（默认离线，要 Node.js）
  rsa_ref.js             ohdave RSA 等价参考实现，离线对拍用的标准答案
  verify-rsa.js          拿门户 security.js 生成标准答案（可选的第 2 层）
  make-icon.ps1          生成 app.ico（GUI 图标和桌面快捷方式图标共用）
  fix-encoding.ps1       批量给 .ps1 / .cs 补 UTF-8 BOM
build\                   可选的 GUI 安装器（本地编译，不随仓库分发）
  Setup.cs  build.ps1
tests\
  CampusNet.Tests.ps1    单元测试（20 项）
  Assertions.ps1         跟 Pester 版本无关的断言助手
  Run-Tests.ps1          测试入口
.github\workflows\ci.yml GitHub Actions：BOM / 语法 / RSA 回归 / 单测
```

## 跑测试

```powershell
# 单元测试
powershell -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1

# RSA 回归（要 Node.js）
powershell -ExecutionPolicy Bypass -File .\tools\test-rsa.ps1
```

CI 每次 push 和 PR 都会跑这四项，四个步骤写在 `.github\workflows\ci.yml` 里。

## 协议细节

这些是从门户的 `login_bch.js`、`AuthInterFace.js`、`security.js` 里读出来，再实测对过的。

```
① 没认证的时候访问任意 http 网站
   → NAS 劫持并 302 到 http://10.130.128.9/eportal/index.jsp?wlanuserip=...&mac=...&nasip=...
   从跳转地址里取出带完整参数的 queryString（每个设备每次都不一样，必须现抓）

② POST /eportal/InterFace.do?method=pageInfo
   body: queryString=<双重 URL 编码的 queryString>
   → 返回 JSON：passwordEncrypt / publicKeyExponent / publicKeyModulus / service / validCodeUrl

③ POST /eportal/InterFace.do?method=login
   body: userId=..&password=..&service=..&queryString=..&operatorPwd=&operatorUserId=
         &validcode=&passwordEncrypt=..
   → {"result":"success","userIndex":"...","keepaliveInterval":...}

④ 再请求一次外网确认真通了；失败按 retryCount 重试
```

踩过的坑有四个。

**参数要双重 URL 编码。** 门户 JS 里是 `encodeURIComponent(encodeURIComponent(...))`，账号、密码、service、queryString 全部套两层。少一层的话，密码里带特殊字符就会失败。

**`service` 传空字符串。** 我们学校门户只返回一个服务“中国电信”，页面上压根没有 `net_access_type` 这个元素，JS 传的就是空串，脚本默认也传空。

**密码加密看 `passwordEncrypt`。** 门户 `pageInfo` 会返回 `true` 或者 `false`。`false` 就是明文提交，我们学校现在是这种；`true` 的话要算 `RSA(反转(密码 + ">" + queryString 里的 mac 值))`。

用的加密是门户 `security.js` 里那套 ohdave RSA：裸模幂，**没有 PKCS#1 填充**，小端分块，`chunkSize = 2 × biHighIndex(n)`（1024 位密钥是 126，不是 128）。

这跟标准 RSA 库不兼容。直接拿 `rsa` 或者 `RSACryptoServiceProvider` 去加密，服务端解不开。`lib\SrunRsa.ps1` 是逐字节照抄的版本。

这里当时还踩了个坑：.NET 的 `BigInteger.ToString('x')` 在最高位大于等于 8 的时候会**多补一个前导 0**（怕被当成负数），要是直接拿去补齐到 4 的倍数，就会多补 4 个字符，大概 15% 的密文是错的。现在改成从 `ToByteArray()` 自己拼 hex，绕开了。

**门户地址只能现抓。** `wlanuserip`、`mac`、`nasip` 在我们学校门户那边是加密过的十六进制串，拼不出来，只能在没认证的时候从 NAS 的 302 跳转里捞。config 里的 `portalHost` 只是抓不到时的兜底。

## RSA 实现怎么校验

`tools\test-rsa.ps1` 分两层，默认那层是离线的，clone 下来就能跑。

第 1 层的标准答案是 `tools\rsa_ref.js`，仓库自带的 ohdave 等价实现，只要机器上有 Node.js。覆盖 40 个向量，包括空串、特殊符号，以及 `chunkSize=126` 的分块边界 125/126/127/251/252/253/378/379，全过才算没写坏。另外会断言非 ASCII 输入被明确拒绝。

第 2 层是可选的，拿门户原始的 `security.js` 来对拍，验证参考实现本身有没有写偏。把那个文件放到 `tools\` 下面就会自动启用，两个实现放进同一个 Node 进程里直接比，7 个向量全等才算过。

原来只依赖门户的 `security.js`，但那文件是第三方文件，仓库里不分发，结果别人 clone 下来根本跑不起来。现在默认那层完全不碰它。

测试模数用的是通用的 1024 位随机模数，不是我们学校的公钥。校验等价性只要两边用同一个模数就够了，随机模数覆盖面反而更广：之前那个十六进制补位的 bug，就是换了模数才暴露出来的（用学校公钥的时候 7 个用例恰好都没踩到，概率大概 32%）。想换成真实公钥加 `-Modulus <256位十六进制>`，公钥可以从 `CampusNet.ps1 -Mode test` 的输出里拿。

有个已知边界：只支持 ASCII。输入中文这种非 ASCII 字符的时候，门户原版、`rsa_ref.js`、PowerShell 实现三方两两都不一样。原因是 ohdave 原版把数据塞进 16bit 的数字槽、乘法时按 `& 0xFFFF` 截断，`charCodeAt` 返回大于 255 的值进到那里就是未定义行为。与其输出一个看着像对的密文，`rsa_ref.js` 直接抛错。对我们学校没影响——密码是 6 位数字，而且门户 `passwordEncrypt=false`，压根不走 RSA。

## 门户升级了怎么办

先跑 `CampusNet.ps1 -Mode test`，看门户现在返回什么（公钥、服务名、加密开关）。然后重新下载门户的 `security.js`，跑一遍 `tools\test-rsa.ps1`，确认加密实现还对得上。接口本身要是变了，对着 `AuthInterFace.js` 和 `login_bch.js` 改 `Invoke-CnLogin`。

## Pester 版本这个坑

写断言别用 Pester 的 `Should`。两个主流版本语法互斥：

| | `Should Be`（没横线） | `Should -Be`（有横线） |
|---|---|---|
| Pester **3.4.0**（Windows 10/11 自带） | 可以 | 报错 `'-Be' is not a valid Should operator` |
| Pester **5.x**（GitHub Actions runner 自带） | 报错 `Legacy Should syntax is not supported` | 可以 |

没有两边通吃的写法。所以 `tests\Assertions.ps1` 里自己写了一组 `Assert-Equal`、`Assert-True`、`Assert-Match`、`Assert-Throws` 之类的助手，失败就 `throw`，哪个 Pester 版本都会把它记成失败。字符串比较用 `-ceq`，因为 PowerShell 的 `-eq` 比字符串不区分大小写，会放过 bug。`Describe`、`It`、`BeforeAll`、`Mock` 这些结构两边行为一样，照常用。

还有两个 Pester 5 的作用域问题，已经绕开了，别改回去：

被测函数必须在每个 `Describe` 的 `BeforeAll` 里 dot-source，不能写在文件顶层。Pester 5 的 `It` 跑在另一个作用域，顶层 dot-source 的函数在 `It` 里会 `CommandNotFoundException`。

`Describe` 体里直接赋值的变量，`It` 里拿不到，得一律放进 `BeforeAll`。

## UTF-8 BOM

所有带中文的 `.ps1` 和 `.cs` 都必须存成 UTF-8 with BOM。Windows PowerShell 5.1 会把没 BOM 的文件按 ANSI/GBK 读，中文变乱码，严重的时候直接语法报错。CI 里专门有一步卡这个。

改完跑一下：

```powershell
powershell -ExecutionPolicy Bypass -File tools\fix-encoding.ps1
```

顺带说一句，这个坑我自己反复踩。用编辑器或者脚本生成 `.ps1` 的时候很容易忘了 BOM，然后拿到一堆莫名其妙的语法错误。所以含中文的辅助脚本我现在的做法是：中文全部放在 UTF-8 的文本文件里，脚本本身只写 ASCII，让它去读文件。

## 自测别碰真实安装

自测一律用隔离目录，不然会覆盖掉用户真实的 `config.json`。那个 DPAPI 密文恢复不了，用户得重新输一遍密码。

```powershell
# 脚本形态
powershell -ExecutionPolicy Bypass -File .\install.ps1 -InstallDir "$env:TEMP\cn-test" -NoShortcut

# exe（GUI）
CampusNet-Setup.exe --install-dir "$env:TEMP\cn-test" --task-name CampusNet-AutoLogin-Test
```

改完确认真实配置没被动过：

```powershell
(Get-FileHash "$env:LOCALAPPDATA\CampusNet\config.json" -Algorithm SHA256).Hash
```

## 编译 GUI（可选）

仓库不发编译好的 exe。想要图形界面就自己编译，代码在 `build\`，你能看见它干了什么：

```powershell
powershell -ExecutionPolicy Bypass -File build\build.ps1
```

用系统自带的 `csc.exe`(.NET Framework 4.x)，不用装 Visual Studio，出来是单个 `CampusNet-Setup.exe`。

这个 exe 是自解压形式，把脚本内嵌进去再释放出来。这种行为正是火绒这类杀软重点盯的模式，比纯脚本容易被拦，自己编译的话建议加白名单。

## 火绒对照测试

火绒 6.0.11.3，防护全开：

| 测试项 | 结果 |
|---|---|
| 带 MOTW（“来自互联网”标记）的 18 文件下载包 → 安装 | 正常部署 14 个文件 |
| 安装目录静置 30 秒 | 没删没改（SHA256 逐个比对） |
| 计划任务连续触发 5 次（wscript → 隐藏 PowerShell） | 5/5 结果码 0，日志正常 |
| VBS 游戏守护拦截 | 正常拦截 |
| 隔离区变化 | 零新增 |
| 关键脚本完整性 | 全部完好 |

对照组是同一台机器上编译出来的自解压 `CampusNet-Setup.exe`,5 秒内被静默隔离，没有任何弹窗。隔离区历史也印证了这一点：13 条记录全是 exe(121KB–303KB)，没有一条是脚本。

所以最后决定只发可读的 PowerShell 源码，不带 exe。倒不是为了绕杀软，主要是脚本你能逐行审、exe 不能；而且往 git 里塞二进制本身也不是好习惯。实测下来脚本形态确实更不容易被误伤，算是顺带的。

## 参考项目

写的时候对照过社区里几个同协议的项目：

- [Barabama/RuijieEportal](https://github.com/Barabama/RuijieEportal) — 同一套 `InterFace.do` 网页协议，交叉验证主要靠它
- [Georgeupup/szu-network-guardian](https://github.com/Georgeupup/szu-network-guardian) — 深大的自动重连工具，“断线监控 + 开机自启”这个结构是参考它的
- [Tim-Conner/SrunPortaLogin](https://github.com/Tim-Conner/SrunPortaLogin) — 注意它走的是深澜原生 `xencode/chksum` 协议，跟网页 eportal 不是一回事
- [zu1k/srun](https://github.com/zu1k/srun) — Go 版的深澜认证

有个地方挺有意思：`rjeportal.py` 用的是 `int.from_bytes(secret, 'big')` 单块加密，门户 JS 是“先反转 + 小端分块”，对短密码来说这两个在数学上完全等价(大端读 `"ab"` 等于小端读 `"ba"`)。两条互相独立的路走到同一套算法上，算是给这个实现多了一点旁证。
