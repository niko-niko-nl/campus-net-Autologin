# 维护者笔记

面向改这份代码的人（其实就是我自己）。普通用户看 [README](../README.md) 就够了。

---

## 目录结构

```
CampusNet.ps1            主脚本
install.ps1 / .bat       安装（自部署到 %LOCALAPPDATA%\CampusNet）
uninstall.ps1 / .bat     卸载
run.bat                  立刻登录一次
run-hidden.vbs           计划任务入口（静默 + 第一层游戏守护）
gameguard.default.txt    游戏进程名单的单一数据源（install.ps1 与 build\Setup.cs 都读它）
lib\SrunRsa.ps1          门户密码加密
tools\
  gameguard-check.ps1    游戏守护自检
  test-rsa.ps1           RSA 实现回归测试（默认离线，需 Node.js）
  rsa_ref.js             ohdave RSA 等价参考实现（离线对拍的"标准答案"）
  verify-rsa.js          用门户 security.js 生成标准答案（可选第 2 层）
  make-icon.ps1          生成 app.ico（GUI 图标 / 桌面快捷方式图标共用）
  fix-encoding.ps1       批量给 .ps1 / .cs 补 UTF-8 BOM
build\                   可选的 GUI 安装器（本地编译，不随仓库分发）
  Setup.cs  build.ps1
tests\
  CampusNet.Tests.ps1    单元测试（20 项）
  Assertions.ps1         版本无关的断言助手
  Run-Tests.ps1          测试入口
.github\workflows\ci.yml GitHub Actions：BOM / 语法 / RSA 回归 / 单测
```

## 跑测试

```powershell
# 单元测试
powershell -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1

# RSA 回归（需要 Node.js）
powershell -ExecutionPolicy Bypass -File .\tools\test-rsa.ps1
```

CI 在每次 push / PR 时自动跑这四项，配置见 `.github\workflows\ci.yml`。

---

## 协议细节（实现依据）

从门户的 `login_bch.js` / `AuthInterFace.js` / `security.js` 里读出来并实测验证：

```
① 未认证时访问任意 http 网站
   → NAS 劫持并 302 到 http://10.130.128.9/eportal/index.jsp?wlanuserip=...&mac=...&nasip=...
   从跳转地址里取出带完整参数的 queryString（每个设备每次都不一样，必须现抓）

② POST /eportal/InterFace.do?method=pageInfo
   body: queryString=<双重 URL 编码的 queryString>
   → 返回 JSON：passwordEncrypt / publicKeyExponent / publicKeyModulus / service / validCodeUrl

③ POST /eportal/InterFace.do?method=login
   body: userId=..&password=..&service=..&queryString=..&operatorPwd=&operatorUserId=
         &validcode=&passwordEncrypt=..
   → {"result":"success","userIndex":"...","keepaliveInterval":...}

④ 再请求一次外网确认真的通了；失败按 retryCount 重试
```

### 四个容易踩的坑

**1. 参数要双重 URL 编码**
门户 JS 里是 `encodeURIComponent(encodeURIComponent(...))`，账号、密码、service、queryString 全部套两层。少一层在密码含特殊字符时就会失败。

**2. `service` 传空字符串**
本校门户只返回一个服务「中国电信」，页面上根本没有 `net_access_type` 元素，JS 传的就是空串。脚本默认也传空。

**3. 密码加密（`passwordEncrypt`）**
门户 `pageInfo` 返回 `true` 或 `false`：

- `false` → 明文提交（**本校当前就是这种**）
- `true` → `RSA(反转(密码 + ">" + queryString 里的 mac 值))`

用的是门户 `security.js` 里那套 **ohdave RSA**：裸模幂、**无 PKCS#1 填充**、小端分块、`chunkSize = 2 × biHighIndex(n)`（1024 位密钥是 126 而不是 128）。

⚠️ 这跟标准 RSA 库**不兼容**，直接拿 `rsa` / `RSACryptoServiceProvider` 去加密会得到服务端解不开的结果。`lib\SrunRsa.ps1` 是逐字节复刻的版本。

> 实现时踩过一个坑：.NET 的 `BigInteger.ToString('x')` 在最高位 ≥ 8 时会**额外补一个前导 0**（防止被当成负数）。如果直接参与「补齐到 4 的倍数」就会多补 4 个字符，导致约 **15% 的密文算错**。现在改成从 `ToByteArray()` 自己拼 hex，规避了这个问题。

**4. 门户地址必须现抓**
`wlanuserip` / `mac` / `nasip` 这些参数在本校门户里是加密过的 16 进制串，没法自己拼，只能在未认证时从 NAS 的 302 跳转里捞。config 里的 `portalHost` 只是抓不到时的兜底。

### 怎么确认实现没写错

`tools\test-rsa.ps1` 分两层校验，**默认那层是离线、开箱即跑的**：

| 层 | 标准答案 | 需要什么 |
|---|---|---|
| **第 1 层（默认）** | `tools\rsa_ref.js` —— 本仓库自带的 ohdave 等价实现 | 只要 Node.js |
| 第 2 层（可选） | 门户原始的 `security.js` | 把该文件放到 `tools\` 下即可自动启用 |

第 1 层覆盖 **40 个向量**（含空串、特殊符号、以及 `chunkSize=126` 的分块边界 125/126/127/251/252/253/378/379），全部通过才算没写坏；并会断言非 ASCII 输入被明确拒绝。

第 2 层是拿来验证"参考实现本身没写偏"的：把两个实现放进同一个 Node 进程直接比对，7 个向量全等才算过。

> 本来只依赖门户的 `security.js`，但那文件是本仓库不分发的第三方文件，结果 clone 下来根本跑不起来。现在默认那层完全不依赖它。

**关于测试模数**：默认用**通用的 1024 位随机模数**，而不是本校公钥。因为等价性验证只需要两边用同一个模数，随机模数覆盖面反而更广——曾经有个十六进制补位的 bug，就是换了模数才暴露出来的（用本校公钥时 7 个用例恰好都没触发，概率约 32%）。想换成真实公钥：`-Modulus <256位十六进制>`，公钥可以从 `CampusNet.ps1 -Mode test` 的输出里拿。

**已知边界：只支持 ASCII**。非 ASCII（中文等）输入时，门户原版 / `rsa_ref.js` / PowerShell 实现**三方两两都不同**——因为 ohdave 原版把数据放进 16bit 数字槽、乘法时按 `& 0xFFFF` 截断，`charCodeAt` 返回的 >255 的值进到那里就是未定义行为。与其输出一个"看起来对"的密文，`rsa_ref.js` 直接抛错。对本校无影响（密码是 6 位数字，且门户 `passwordEncrypt=false` 根本不走 RSA）。

### 门户升级后怎么办

1. 跑 `CampusNet.ps1 -Mode test` 看门户返回什么（公钥、服务名、加密开关）
2. 重新下载门户的 `security.js`，跑 `tools\test-rsa.ps1` 确认加密实现还对得上
3. 如果接口变了，对着 `AuthInterFace.js` / `login_bch.js` 改 `Invoke-CnLogin`

---

## ⚠️ 写测试必读：Pester 版本陷阱

**断言不要用 Pester 的 `Should`。** 实测两个主流版本语法互斥：

| | `Should Be`（无横线） | `Should -Be`（有横线） |
|---|---|---|
| Pester **3.4.0**（Windows 10/11 自带） | ✅ | ❌ `'-Be' is not a valid Should operator` |
| Pester **5.x**（GitHub Actions runner 自带） | ❌ `Legacy Should syntax is not supported` | ✅ |

没有两边通吃的写法。所以 `tests\Assertions.ps1` 提供 `Assert-Equal` / `Assert-True` /
`Assert-Match` / `Assert-Throws` 等助手 —— 失败就 `throw`，任何 Pester 版本都会把它记为失败。
字符串比较用 `-ceq`，避免 PowerShell `-eq` 对字符串不区分大小写而放过 bug。
`Describe` / `It` / `BeforeAll` / `Mock` 这些结构在两边行为一致，照常用。

还有两个 Pester 5 的坑（已规避，别改回去）：

- **被测函数必须在每个 `Describe` 的 `BeforeAll` 里 dot-source**，不能写在文件顶层。
  Pester 5 的 `It` 运行在另一个作用域，顶层 dot-source 的函数在 `It` 里会
  `CommandNotFoundException`。
- **`Describe` 体里直接赋值的变量，`It` 里拿不到**，一律放 `BeforeAll`。

## ⚠️ 改代码必读：UTF-8 BOM

**所有含中文的 `.ps1` / `.cs` 必须存成 UTF-8 with BOM。** Windows PowerShell 5.1 会把无 BOM 的文件按 ANSI/GBK 读，中文变乱码，甚至直接语法报错。CI 里有一步专门卡这个。

改完跑一下：

```powershell
powershell -ExecutionPolicy Bypass -File tools\fix-encoding.ps1
```

## ⚠️ 自测必读：别碰真实安装

自测一律用隔离目录，否则会覆盖用户真实的 `config.json`（DPAPI 密文不可恢复，用户得重新输密码）：

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

## 编译 GUI 安装器（可选）

仓库**不附带编译好的 exe**（先不说杀软，往 git 里塞二进制本身也不是好习惯）。想要图形界面就自己编译：

```powershell
powershell -ExecutionPolicy Bypass -File build\build.ps1
```

用系统自带的 `csc.exe`（.NET Framework 4.x），无需 Visual Studio，输出单个 `CampusNet-Setup.exe`。

> 注意：这个 exe 是**自解压**形式（把脚本内嵌进去再释放），这类行为正是火绒等杀软重点关照的模式，比纯脚本更容易被拦。自己编译的话建议加白名单。

---

## 杀毒软件对照测试原始数据

火绒 6.0.11.3，防护全开：

| 测试项 | 结果 |
|---|---|
| 带 MOTW（「来自互联网」标记）的 18 文件下载包 → 安装 | ✅ 正常部署 14 个文件 |
| 安装目录静置 30 秒 | ✅ 零删除、零修改（SHA256 逐个比对） |
| 计划任务连续触发 5 次（wscript → 隐藏 PowerShell） | ✅ 5/5 结果码 0，日志正常 |
| VBS 游戏守护拦截 | ✅ 正常拦截 |
| 隔离区变化 | ✅ **零新增** |
| 关键脚本完整性 | ✅ 全部完好 |

**对照组**：同一台机器上编译出的自解压 `CampusNet-Setup.exe`，**5 秒内被静默隔离**，无任何弹窗提示。

隔离区历史记录也印证了这一点——**13 条记录全部是 exe（121KB–303KB），没有一条是脚本**。

所以本项目最终**只分发可读的 PowerShell 源码，不附带编译好的 exe**。这不是为了绕过杀软，而是因为：

1. 脚本你能逐行审，exe 不能；
2. 把二进制塞进 git 本身也不是好习惯；
3. 实测下来脚本形态确实更不容易被误伤。

---

## 参考项目

实现时对照过社区里几个同协议的项目：

- **[Barabama/RuijieEportal](https://github.com/Barabama/RuijieEportal)** — 同一套 `InterFace.do` 网页协议，交叉验证的主要依据
- **[Georgeupup/szu-network-guardian](https://github.com/Georgeupup/szu-network-guardian)** — 深大自动重连工具，"断线监控 + 开机自启"的结构参考
- **[Tim-Conner/SrunPortaLogin](https://github.com/Tim-Conner/SrunPortaLogin)** — 注意它走深澜**原生 `xencode/chksum`** 协议，和网页 eportal 不是一回事
- **[zu1k/srun](https://github.com/zu1k/srun)** — Go 版深澜认证

**一处有意思的对照**：`rjeportal.py` 用 `int.from_bytes(secret, 'big')` 单块加密，而门户 JS 是「先反转 + 小端分块」——对短密码而言**两者数学上完全等价**（大端解读 `"ab"` ≡ 小端解读 `"ba"`）。两条独立路径指向同一套算法，这也是对本实现正确性的一个旁证。
