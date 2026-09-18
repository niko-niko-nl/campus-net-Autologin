# 四川大学锦江学院 校园网自动登录

每次开机都要打开浏览器点一下登录，太麻烦了，所以写了这个。装完之后开机自动连校园网，掉线了自己重连，你打游戏的时候它什么都不做。

走的是学校门户那套网页认证(`http://10.130.128.9/eportal`，深澜/锐捷的 eportal)。它不是模拟点浏览器，是直接调门户自己的接口。

只能在校内用，门户是内网地址，校外连不上。Windows 10 和 11 都行，不用管理员权限，也不用装别的东西。

别的学校用不了。各家门户的地址和登录参数都不一样，这份是照我们学校写的，换个学校得自己改代码。

## 安装

下载 ZIP，解压，双击 `install.bat`，填一下账号密码，就完了。

有句话得先说：**一定要先解压再点**。在压缩包的预览窗口里直接双击 `install.bat` 会失败，因为那时候 Windows 只是把文件临时解到别的地方去了，脚本找不到跟自己放在一起的其他文件。

解压到哪都行，下载文件夹也可以。脚本会把自己复制到一个固定位置，装完你把那个文件夹删掉也没影响。

打开解压出来的文件夹，双击 `install.bat`。会弹一个黑窗口，依次问你三件事：

```
请输入校园网账号（身份证号）：
  账号（身份证号） ▮

请输入校园网密码（身份证后 6 位；输入时不显示，仅保存在本机）：
  密码（身份证后 6 位） ▮

认证服务名（不知道就直接回车，脚本会自动判断）：
  服务名 ▮
```

账号填身份证号，密码填身份证后 6 位。密码打的时候屏幕上不显示字符，这是正常的。最后那个服务名直接回车别填，我们学校只有一个出口（中国电信），门户自己的登录页传的也是空值。

跑完是这些字：

```
==============================================================
  安装完成
==============================================================
从现在起：
  · 每次登录 Windows 后 20 秒自动认证
  · 每 5 分钟检查一次，掉线会自动重连
```

看到 `[OK] Install finished.` 就是成了，按任意键关掉窗口。

以后开机会自己登录，不用再管。想现在就看一眼效果，双击 `run.bat`，它会打印当前联网状态，再强制登录一次。

### 第一次装可能会碰到的

**窗口一闪就没了**：说明出错了，只是报错没来得及看。右键文件夹里的空白处，选“在终端中打开”，输入 `.\install.bat` 回车，报错就会留在屏幕上。

**诊断时显示“抓不到门户地址”**：这个不是错误。你现在本来就连着网，NAS 不会把你重定向到门户，所以抓不到。脚本只在真掉线的时候才需要去抓，装完照样能用。

**Windows 弹“已保护你的电脑”**：这个项目里没有 exe，一般不会弹。你自己编译了图形界面的话，点“更多信息”，再点“仍要运行”。

**杀毒软件报警**：看下面[杀毒软件](#杀毒软件)那节。简单说，脚本形态没被拦过；实在不放心，把 `%LOCALAPPDATA%\CampusNet` 加进信任区。

**想确认真的生效了**：双击 `run.bat`，看到 `[OK] Online` 就行。日志在 `%LOCALAPPDATA%\CampusNet\login.log`。

**换电脑或者重装了系统**：重新跑一遍 `install.bat`。密码是拿当前 Windows 用户加密的，`config.json` 拷到别的机器上解不开。

## 装了哪些东西

文件都在 `%LOCALAPPDATA%\CampusNet`：

| 文件 | 干什么的 |
|---|---|
| `CampusNet.ps1` | 主脚本。`-Mode ensure` 保证在线，还有 `login` / `status` / `test` |
| `install.bat` / `uninstall.bat` | 安装、卸载 |
| `run.bat` | 双击立刻登录一次 |
| `run-hidden.vbs` | 计划任务实际调用的入口，用来静默拉起 PowerShell（不然会闪黑框），顺便做第一层游戏守护 |
| `lib\SrunRsa.ps1` | 门户的密码加密算法 |
| `config.json` | 账号、加密后的密码、各项配置 |
| `login.log` | 运行日志，超过 1MB 自己轮转 |
| `tools\` | 几个诊断和校验用的小工具 |

任务计划程序里会多一个 `CampusNet-AutoLogin`。它不需要管理员权限，是以你自己的身份运行，只在你登录的时候跑。登录后 20 秒触发一次，之后每 5 分钟一次。

## 它是怎么登录的

不模拟点浏览器，直接调门户自己的接口：

```
① 没认证的时候访问任意 http 网站 → 被 NAS 302 到门户，从跳转地址里抓出这次要用的参数
② POST InterFace.do?method=pageInfo → 拿到加密开关、服务名这些
③ POST InterFace.do?method=login → 提交账号密码
④ 再请求一次外网确认真通了；失败就按次数重试
```

那些参数(`wlanuserip`、`mac`、`nasip`)每个设备每次都不一样，门户那边给的是加密过的十六进制串，没法自己拼，只能现抓。

我们学校门户返回的 `passwordEncrypt` 是 `false`，也就是登录请求里的密码是明文的，而且走的是 http。这跟你自己在浏览器里登录走的是同一条路，不是脚本让它变得不安全。这事在下面[关于密码](#关于密码)里说得细一点。

## 游戏守护

默认开着。加这个是因为怕影响反作弊。

工具跑的时候会拉起一个隐藏进程，再发几个 HTTP 请求。这不是作弊，但反作弊的行为引擎看到这类动作会不会有反应，谁也说不准。与其赌它不管，不如你打游戏的时候让它彻底别动。

做了两层：

第一层在 `run-hidden.vbs` 里，也就是计划任务实际调用的那个入口。它一上来先看进程，发现游戏在跑就直接退出，PowerShell 根本不会被创建。

第二层在 `CampusNet.ps1` 里。你手动跑 `run.bat` 的时候它会再看一次，命中就跳过，连联网检测都不做。

第一层是关键：你打游戏的时候，这个工具产生的新进程是 0 个。

默认盯这些进程（23 个）：

```
SGuard64  SGuardSvc64  ACE-Guard Client  ACE-BASE     ← 腾讯 ACE 的按需组件
valorant  cs2  csgo  dota2
LeagueClient  LeagueClientUx
r5apex  r5apex_dx12
TslGame  NarakaBladepoint
GenshinImpact  YuanShen  StarRail
Overwatch  RainbowSix  RainbowSixSiege
RobloxPlayerBeta  GTA5  RDR2
```

名单里只能放游戏启动时才出现的进程。腾讯 ACE 的托盘 `ACE-Tray` 是一开机就在跑的，加进去守护会一直生效，等于把自动登录关掉了。

想确认你自己玩的游戏在不在里面，开着游戏跑：

```powershell
powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\CampusNet\tools\gameguard-check.ps1"
```

显示“结论：会拦截”就是生效了。显示“放行”说明名单里没有你这个游戏，去任务管理器“详细信息”那一栏找到游戏进程，把 `.exe` 前面的名字加到 `config.json` 的 `gameProcesses` 里。

不想用就把 `config.json` 里的 `gameGuard` 改成 `false`，代价是打游戏期间掉线不会自动重连。

最后还是那句：这只能降低暴露面，保证不了反作弊一定不误判。代码里没有任何作弊特征——不注入进程、不挂钩子、不装驱动、也不模拟键鼠——但各家反作弊内部怎么判的，我核实不了。你要是玩的反作弊特别严，最稳的办法是玩之前直接把任务停掉：

```powershell
Disable-ScheduledTask -TaskName CampusNet-AutoLogin    # 玩之前
Enable-ScheduledTask  -TaskName CampusNet-AutoLogin    # 玩完恢复
```

## 杀毒软件

这类工具被误报挺常见的，我也没法保证一定不触发。它干的事——定时跑脚本、往外发请求、把凭据存下来——跟某些恶意软件确实有重叠。

所以我没发编译好的 exe，只发能读的 PowerShell 源码。代码你随便看，没有混淆，没有拿 base64 藏东西，不注入进程，不挂钩子，不装驱动，不写注册表。

真被拦了，就把这个目录加进信任区或者排除目录：

```
%LOCALAPPDATA%\CampusNet
```

火绒在右上角菜单里找信任区 → 添加目录；360 在设置 → 白名单；Windows Defender 在 Windows 安全中心 → 病毒和威胁防护 → 排除项。建议加白名单，别直接关杀软，关了迟早会忘记开回来。

我自己在火绒 6.0.11.3 上测过一轮，防护全开：带着“来自互联网”标记的下载包安装正常；装完目录静置 30 秒，没有文件被删或者被改（一个个比过 SHA256）；计划任务连着触发 5 次全部成功；隔离区零新增。

对照组是我自己编译的自解压 `CampusNet-Setup.exe`,5 秒内被静默隔离，连提示都没有。隔离区历史里 13 条记录全是 exe，没有一条是脚本。

不过这只说明火绒这个版本没拦。换个杀软、换个版本，结果可能就不一样了。

自己编译图形界面的说明在 [docs/MAINTAINER.md](docs/MAINTAINER.md)。那个 exe 是本地新生成、没签名的程序，可能提示“未知发布者”，点“更多信息 → 仍要运行”。

## 配置

装完想改设置，编辑 `%LOCALAPPDATA%\CampusNet\config.json`，不用重装，下次运行就生效。

| 字段 | 说明 |
|---|---|
| `userId` | 身份证号 |
| `passwordEncrypted` | 加密后的密码。换了 Windows 用户或者重装系统就解不开，得重跑安装 |
| `password` | 明文密码。一般留空 |
| `service` | 认证服务名，留空 |
| `portalHost` | 门户 IP，默认 `10.130.128.9`，只在自动发现失败时兜底用 |
| `checkUrls` | 判断在不在线的探测地址 |
| `retryCount` / `retryDelaySec` | 单次运行失败后重试几次、隔多久 |
| `timeoutSec` | 网络超时 |
| `gameGuard` | 要不要游戏守护 |
| `gameProcesses` | 游戏守护的进程名名单 |
| `logFile` | 日志路径，跟着安装目录走 |

检查的间隔不在这个文件里，在计划任务里。要改成 3 分钟：

```powershell
powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\CampusNet\install.ps1" -UseExistingConfig -IntervalMinutes 3 -Force
```

## 出问题了看这里

日志在 `%LOCALAPPDATA%\CampusNet\login.log`，超过 1MB 会自己轮转。

**抓不到门户地址**：说明你现在已经连着网了，正常。只有没认证的时候 NAS 才会把你重定向到门户。想强制测一次，先在浏览器里注销。

**开机后没自动登录**：先看日志有没有新记录。一条都没有，就是任务没跑起来，去任务计划程序里看 `CampusNet-AutoLogin` 的状态；有记录但登录失败，看它报的什么错。

**用户名或密码错误**：重跑安装，把密码输对。密码首尾如果真有空格，脚本不会替你删掉。

**无法解密保存的密码(DPAPI)**：换过 Windows 用户，或者改过 Windows 账户密码。重跑 `install.ps1 -Force`。

**该门户开启了图形验证码**：我们学校没有。哪天启用了就只能先在浏览器登录，验证码没法自动填。

**登录成功了但还是上不了网**：可能是欠费、被限速，或者绑定的设备数超了。

**几个人共用一台电脑**：计划任务和配置都是按 Windows 用户分开的，各装各的，互不影响。

**卸载了想装回来**：重跑 `install.bat`，配置会重新生成。

## 卸载

双击 `uninstall.bat`。默认删掉计划任务、保存的密码、日志，程序文件留着。

想删干净：

```powershell
powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\CampusNet\uninstall.ps1" -Purge
Remove-Item -Recurse -Force "$env:LOCALAPPDATA\CampusNet"
```

## 关于密码

密码用 Windows 的 DPAPI(`ConvertFrom-SecureString`)加密，密钥跟当前 Windows 用户绑着，换用户或者重装系统就解不开，也没法拿到别的机器上用。`config.json` 里没有明文密码。

脚本只访问校园网门户和你配的探测地址，没有别的外发流量。`.gitignore` 里排掉了 `config.json`、`login.log`、`gameguard.lst`，不会不小心提交上去。

但“仅保存在本机”说的是存下来的时候，传输是另一回事。前面提过，我们学校门户的 `passwordEncrypt` 是 `false`，登录请求里的密码是明文，走的 http。跟浏览器登录是同一条路，不是脚本让它变差的。不过在校园网里抓包的人——同一个局域网，或者控制了 AP 和网关的人——理论上能看到你的密码。

能做的：校园网门户本身就在校内，校外访问不到，实际也就同网段的人。学校要是允许，去自助服务系统里把密码改成一个跟身份证无关的；真在意的话就别用这类工具，每次自己手输。

## License

MIT，见 [LICENSE](LICENSE)。

开发环境、怎么跑测试、编码上的约定，写在 [docs/MAINTAINER.md](docs/MAINTAINER.md)。
