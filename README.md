# 本校校园网开机自动登录

**给本校同学用的**：Windows 开机自动登录校园网，掉线自动重连，玩游戏时自动避让反作弊。

- 校园网门户：`http://10.130.128.9/eportal`（深澜 / 锐捷 eportal 网页认证）
- 只适用于**本校校园网内**——门户是内网地址，校外访问不到
- 支持 Windows 10 / 11，**不需要管理员权限，不需要安装任何东西**

> ❓ **其他学校能用吗？** 不能直接用。每家学校的门户地址、认证接口和参数都不一样，这份代码是照着本校门户写的，换了学校得自己改。

```
下载 ZIP → 解压 → 双击 install.bat → 输入账号和密码 → 完事
```

---

## 目录

- [快速开始](#快速开始)
- [它做了什么](#它做了什么)
- [工作原理（协议细节）](#工作原理协议细节)
- [游戏守护（避让反作弊）](#游戏守护避让反作弊)
- [杀毒软件 / SmartScreen 提示](#杀毒软件--smartscreen-提示)
- [配置项](#配置项)
- [排错](#排错)
- [卸载](#卸载)
- [开发与维护](#开发与维护)
- [参考项目](#参考项目)
- [安全说明](#安全说明)
- [License](#license)

---

## 快速开始

> 全程 **3 步**，不用管理员权限，不用装任何东西。需要 Windows 10 / 11。

### 第 1 步：下载

在仓库页面点绿色的 **Code** 按钮 → **Download ZIP**。

### 第 2 步：解压

把下载到的 `CampusNet-main.zip` **解压出来**（右键 → 全部解压缩）。

> ⚠️ **一定要先解压，别在压缩包里直接双击。** 压缩包预览窗口里双击会失败——Windows 只是把文件临时解到别处，脚本找不到旁边的文件。

解压到哪都行，**下载文件夹也可以**（脚本会把自己复制到稳定位置，事后你删掉这个文件夹不影响）。

### 第 3 步：双击 `install.bat`

在解压出来的文件夹里找到 **`install.bat`**，双击。

会弹出一个黑色窗口，依次问你三件事：

```
请输入校园网账号（身份证号）：
  账号（身份证号） ▮              ← 输入身份证号，回车

请输入校园网密码（身份证后 6 位；输入时不显示，仅保存在本机）：
  密码（身份证后 6 位） ▮          ← 输入身份证后 6 位（不显示字符），回车

认证服务名（不知道就直接回车，脚本会自动判断）：
  服务名 ▮                        ← 直接回车，别填
```

然后它会自动跑完，最后显示：

```
==============================================================
  安装完成
==============================================================
从现在起：
  · 每次登录 Windows 后 20 秒自动认证
  · 每 5 分钟检查一次，掉线会自动重连
```

看到 **`[OK] Install finished.`** 就成功了。按任意键关掉窗口。

### 完事

以后开机会自动登录，不用管了。

**想立刻验证一下**：双击 `run.bat`，它会打印当前联网状态并强制登录一次。

### 第一次装可能会遇到的

**窗口一闪就没了 / 报错看不清**
说明出了错。用**右键 → 在终端中打开**，然后输入 `.\install.bat` 运行，报错就能留在屏幕上了。

**诊断时显示「抓不到门户地址」**
**这不是错误。** 因为你现在本来就联着网，NAS 不会把你重定向到门户，所以抓不到——脚本只在真正掉线时才需要去抓。装完照样能用。

**「认证服务名」到底填什么**
**留空，直接回车。** 本校只有一个出口（中国电信），门户自己的登录页也是传空值。

**Windows 弹「已保护你的电脑」/ 未知发布者**
本项目不含 exe，正常不会弹。如果你自己编译了 GUI，点「更多信息 → 仍要运行」。

**杀毒软件报警 / 删文件**
看 [杀毒软件一节](#杀毒软件--smartscreen-提示)。简单说：脚本形态实测不触发，把 `%LOCALAPPDATA%\CampusNet` 加进信任区最稳。

**装完想确认真的生效了**
双击 `run.bat`，看到 `[OK] Online` 就行。或者看日志 `%LOCALAPPDATA%\CampusNet\login.log`。

**换电脑 / 重装系统了**
重新跑一遍 `install.bat` 即可。密码是绑定当前 Windows 用户加密的，**不能**把 `config.json` 拷到别的机器上用。

---

## 它做了什么

安装后所有文件都在 `%LOCALAPPDATA%\CampusNet`：

| 文件 | 作用 |
|---|---|
| `CampusNet.ps1` | 主脚本。`-Mode ensure`（确保在线）/ `login` / `status` / `test` |
| `install.ps1` / `install.bat` | 安装 |
| `uninstall.ps1` / `uninstall.bat` | 卸载 |
| `run.bat` | 双击立刻登录一次 |
| `run-hidden.vbs` | 计划任务调用的入口，静默拉起 PowerShell（不闪黑框），并做第一层游戏守护 |
| `lib\SrunRsa.ps1` | 深澜密码加密算法（复刻门户 `security.js`） |
| `config.json` | 账号 + DPAPI 密文密码 + 各项配置 |
| `login.log` | 运行日志，超过 1MB 自动轮转 |
| `tools\` | 诊断与校验工具 |

**计划任务**（无需管理员，以当前用户身份、仅登录状态下运行）：

| 触发器 | 动作 |
|---|---|
| 登录后 20 秒 | 确保在线 |
| 每 5 分钟重复 | 确保在线（掉线自愈） |

---

## 工作原理（协议细节）

脚本**不模拟点击浏览器**，而是直接调用门户自己的三个接口——和浏览器登录走同一条路。

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

都是从门户的 `login_bch.js` / `AuthInterFace.js` / `security.js` 里读出来并实测验证的：

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

`tools\test-rsa.ps1` 用**门户原始的 `security.js`** 当标准答案，交叉验证 PowerShell 实现是否逐字节一致：

```powershell
powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\CampusNet\tools\test-rsa.ps1"
```

7 个用例全部 `[OK]` 才算没问题。需要 Node.js。

值得说明的是：默认用的是**通用的 1024 位测试模数**，而不是本校的公钥。因为交叉验证只需要两边用同一个模数，用随机模数反而覆盖面更广——上面那个补位 bug 就是换了模数才暴露出来的（用本校公钥时 7 个用例恰好都没触发，概率约 32%）。

想用本校真实公钥测，加 `-Modulus <256位十六进制>`；公钥可以从 `CampusNet.ps1 -Mode test` 的输出里拿。

---

## 游戏守护（避让反作弊）

**为什么需要**：这套工具运行时会产生「启动隐藏进程 + 发 HTTP 请求」的行为。这不是作弊，但反作弊的行为引擎可能对这类活动敏感。与其赌它不管，不如**游戏在跑时彻底不活动**。

### 两层拦截

| 层 | 位置 | 行为 |
|---|---|---|
| **第一层** | `run-hidden.vbs` | 计划任务一触发就先查进程，命中就**直接退出——PowerShell 根本不会被创建** |
| **第二层** | `CampusNet.ps1` | 手动运行时再查一次，命中就跳过，**连联网检测都不做** |

第一层是关键：游戏期间这个工具的足迹是 **0 个新进程**。

### 默认监控名单（23 个）

```
SGuard64  SGuardSvc64  ACE-Guard Client  ACE-BASE     ← 腾讯 ACE 按需组件
valorant  cs2  csgo  dota2
LeagueClient  LeagueClientUx
r5apex  r5apex_dx12
TslGame  NarakaBladepoint
GenshinImpact  YuanShen  StarRail
Overwatch  RainbowSix  RainbowSixSiege
RobloxPlayerBeta  GTA5  RDR2
```

> ⚠️ **常驻进程不能列进来。** 比如腾讯 ACE 的托盘 `ACE-Tray` 一开机就在跑（本机实测确实常驻），列进去会导致守护永远生效、自动登录等于被关掉。名单里只放**游戏启动时才出现**的进程。

### 确认它对你自己玩的游戏生效

**开着游戏**跑：

```powershell
powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\CampusNet\tools\gameguard-check.ps1"
```

- 显示 **「结论：会拦截」** → 生效 ✅
- 显示 **「结论：放行」** → 名单缺你这个游戏。任务管理器 → 详细信息 → 找到游戏那一行，把 `.exe` 前面的名字加进 `config.json` 的 `gameProcesses`

### 关掉它

`config.json` 里 `"gameGuard": false`。代价是玩游戏期间掉线不会自动重连。

### 它不能保证什么

**游戏守护只降低暴露面，不能保证反作弊一定不误判。** 代码层面它不含任何作弊特征（无注入、无钩子、无驱动、无键鼠模拟），但没法核实各反作弊引擎的内部判定规则。如果玩的游戏反作弊特别激进，最稳妥的是玩之前直接停掉任务：

```powershell
Disable-ScheduledTask -TaskName CampusNet-AutoLogin   # 玩之前
Enable-ScheduledTask  -TaskName CampusNet-AutoLogin   # 玩完恢复
```

---

## 杀毒软件 / SmartScreen 提示

**先说清楚**：这类工具会被部分杀软误报，这是这个方案固有的问题，**没有任何办法能保证 100% 不触发**。原因是它的行为组合（脚本定时执行 + 发起网络请求 + 保存凭据）和某些恶意软件确实有重叠。

### 本项目的做法

- **只分发可读的 PowerShell 源码**，不发编译好的 exe。所有代码你自己能看、能审。
- **不使用**编码混淆、不用 base64 藏代码、不注入进程、不挂钩子、不装驱动、不改注册表。

### 如果被拦了

把下面这个路径加进杀软的**信任区 / 排除目录**：

```
%LOCALAPPDATA%\CampusNet
```

国内常见杀软的位置：

| 软件 | 操作 |
|---|---|
| 火绒 | 主界面 → 右上角菜单 → 信任区 → 添加目录 |
| 360 | 设置 → 白名单 → 添加目录 |
| Windows Defender | Windows 安全中心 → 病毒和威胁防护 → 排除项 |

**建议加白名单而不是关掉杀软**——长期关防护不安全，而且你迟早会忘。

### 实测数据（火绒 6.0.11.3，防护全开）

开发时做过一轮完整对照测试，结论是**脚本形态不触发查杀**：

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

> 但请注意：这只说明**火绒**、**这个版本**、**这套行为组合**没被拦。换了杀软、换了版本、或者行为模式改变，结果可能不同。**没有任何办法能保证 100% 不触发。**

### 关于 SmartScreen

本项目不含 exe，正常不会触发 SmartScreen。如果你自己编译了 GUI（见下），那是本地新生成、未签名的程序，可能出现「未知发布者」提示，点「更多信息 → 仍要运行」即可。

---

## 配置项

安装后编辑 `%LOCALAPPDATA%\CampusNet\config.json`（改完不用重装，下次运行就生效）：

| 字段 | 说明 |
|---|---|
| `userId` | 身份证号 |
| `passwordEncrypted` | DPAPI 加密的密码。**换 Windows 用户或重装系统后解不开，需重跑安装** |
| `password` | 明文密码。一般留空 |
| `service` | 认证服务名。留空 |
| `portalHost` | 门户 IP，默认 `10.130.128.9`，仅作自动发现失败时的兜底 |
| `checkUrls` | 判断是否在线的探测地址 |
| `retryCount` / `retryDelaySec` | 单次运行的失败重试次数 / 间隔 |
| `timeoutSec` | 网络超时 |
| `gameGuard` | 是否启用游戏守护 |
| `gameProcesses` | 游戏守护的进程名名单 |
| `logFile` | 日志路径（跟随安装目录） |

**改检查间隔**：间隔存在计划任务里，不在配置文件里。

```powershell
# 改成 3 分钟
powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\CampusNet\install.ps1" -UseExistingConfig -IntervalMinutes 3 -Force
```

---

## 排错

**日志在哪**：`%LOCALAPPDATA%\CampusNet\login.log`（超过 1MB 自动轮转）

**"抓不到门户地址"**
说明当前**已经联网**了，这是正常的。只有未认证时 NAS 才会把你重定向到门户。想强制测试就先在浏览器里注销。

**开机后没自动登录**
1. 看日志有没有新记录。完全没有 → 任务没跑起来（检查任务计划程序里 `CampusNet-AutoLogin` 的状态）
2. 有记录但登录失败 → 看具体报错

**"用户名或密码错误"**
重跑安装输入正确密码。注意密码里如果有首尾空格，脚本**不会**自动去掉（因为密码可能真的含空格）。

**"无法解密保存的密码（DPAPI）"**
换了 Windows 用户，或者改过 Windows 账户密码。重跑 `install.ps1 -Force`。

**"该门户开启了图形验证码"**
本校没有；如果哪天启用了，图形验证码没法自动化，只能先在浏览器登录。

**登录成功但还是上不了网**
可能是账号欠费、被限速，或者绑定设备数超限。

**多个用户共用一台电脑**
计划任务和配置都是**按 Windows 用户隔离**的。每人跑一次安装即可，互不影响。

**卸载后又想装回来**
重跑 `install.bat` 即可，配置会重新生成。

---

## 卸载

**双击 `uninstall.bat`**（或跑 `uninstall.ps1`）。

默认会删掉：计划任务、保存的密码、日志。程序文件保留。

彻底清除：

```powershell
powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\CampusNet\uninstall.ps1" -Purge
Remove-Item -Recurse -Force "$env:LOCALAPPDATA\CampusNet"
```

---

## 开发与维护

### 目录结构

```
CampusNet.ps1            主脚本
install.ps1 / .bat       安装
uninstall.ps1 / .bat     卸载
run.bat                  立刻登录一次
run-hidden.vbs           计划任务入口（静默 + 第一层游戏守护）
lib\SrunRsa.ps1          深澜密码加密
tools\
  gameguard-check.ps1    游戏守护自检
  test-rsa.ps1           RSA 实现交叉验证（需 Node.js）
  verify-rsa.js          用门户 security.js 生成标准答案
  fix-encoding.ps1       批量给 .ps1 补 UTF-8 BOM
build\                   可选的 GUI 安装器（本地编译，不随仓库分发）
  Setup.cs  build.ps1  make-icon.ps1
```

### ⚠️ 改代码必读：UTF-8 BOM

**所有含中文的 `.ps1` / `.cs` 必须存成 UTF-8 with BOM。** Windows PowerShell 5.1 会把无 BOM 的文件按 ANSI/GBK 读，中文变乱码，甚至直接语法报错。

改完跑一下：

```powershell
powershell -ExecutionPolicy Bypass -File tools\fix-encoding.ps1
```

### 编译 GUI 安装器（可选）

仓库**不附带编译好的 exe**（先不说杀软，往 git 里塞二进制本身也不是好习惯）。想要图形界面就自己编译——代码就在 `build\`，你能看见它做了什么：

```powershell
powershell -ExecutionPolicy Bypass -File build\build.ps1
```

用系统自带的 `csc.exe`（.NET Framework 4.x），无需 Visual Studio，输出单个 `CampusNet-Setup.exe`。

> 注意：这个 exe 是**自解压**形式（把脚本内嵌进去再释放），这类行为正是火绒等杀软重点关照的模式，比纯脚本更容易被拦。自己编译的话建议加白名单。

### 门户升级后怎么办

1. 跑 `CampusNet.ps1 -Mode test` 看门户返回什么（公钥、服务名、加密开关）
2. 重新下载门户的 `security.js`，跑 `tools\test-rsa.ps1` 确认加密实现还对得上
3. 如果接口变了，对着 `AuthInterFace.js` / `login_bch.js` 改 `Invoke-CnLogin`

---

## 参考项目

实现时对照过社区里几个同协议的项目：

- **[Barabama/RuijieEportal](https://github.com/Barabama/RuijieEportal)** — 同一套 `InterFace.do` 网页协议，交叉验证的主要依据
- **[Georgeupup/szu-network-guardian](https://github.com/Georgeupup/szu-network-guardian)** — 深大自动重连工具，"断线监控 + 开机自启"的结构参考
- **[Tim-Conner/SrunPortaLogin](https://github.com/Tim-Conner/SrunPortaLogin)** — 注意它走深澜**原生 `xencode/chksum`** 协议，和网页 eportal 不是一回事
- **[zu1k/srun](https://github.com/zu1k/srun)** — Go 版深澜认证

**一处有意思的对照**：`rjeportal.py` 用 `int.from_bytes(secret, 'big')` 单块加密，而门户 JS 是「先反转 + 小端分块」——对短密码而言**两者数学上完全等价**（大端解读 `"ab"` ≡ 小端解读 `"ba"`）。两条独立路径指向同一套算法，这也是对本实现正确性的一个旁证。

---

## 安全说明

- 密码用 Windows **DPAPI**（`ConvertFrom-SecureString`）加密，密钥绑定当前 Windows 用户，**换用户或重装系统就解不开**，无法在其他机器上复用。
- `config.json` 里**不含明文密码**。
- 脚本只访问校园网门户和你配置的探测地址，**没有其他外发流量**。
- 代码全部可读：无混淆、无 base64 隐藏载荷、不注入进程、不挂钩子、不装驱动、不写注册表。
- **`.gitignore` 已排除** `config.json`、`login.log`、`gameguard.lst`，不会误提交个人数据。

### ⚠️ 关于「密码是身份证后 6 位」

这是**学校的规定**，不是本项目引入的。但本仓库把它写进了公开文档，你需要知道这意味着什么：

- 任何**已经拿到你身份证号**的人（比如从某个泄露名单里），看了这个仓库就能推出你的校园网密码。
- 这个规则校内同学基本都知道，所以实际新增的风险有限，但它从「口口相传」变成了「公开可检索」。

**降低风险的做法**（任选，都不影响使用）：

- 登录学校自助服务系统**改一个独立密码**（如果学校允许），这样密码就和身份证号脱钩了。
- 或者把仓库设为 **private**，只分享给信得过的同学。

---

## License

[MIT](LICENSE)
