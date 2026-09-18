// ===========================================================================
//  CampusNet-Setup.exe  —— 校园网自动登录 一键配置程序
//
//  单文件自解压 + 图形界面。双击后：
//    1. 把内嵌的脚本释放到 %LOCALAPPDATA%\CampusNet
//    2. 用 Windows DPAPI 加密保存密码，写成 config.json（密码不落明文、不进命令行）
//    3. 调用 install.ps1 注册计划任务（登录自启 + 定时掉线重连）
//    4. 立刻认证一次
//
//  命令行（便于自动化/自测，普通用户直接双击即可）：
//    --install --user U --pass-stdin [--service S] [--interval N]
//        （密码从 stdin 读一行；故意不提供 --pass —— 命令行参数会被同机
//          其他用户在进程列表里看到）
//    --ensure | --status | --gamecheck | --uninstall [--purge] | --selftest | --extract-only
// ===========================================================================
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace CampusNetSetup
{
    // -----------------------------------------------------------------------
    //  内嵌载荷（由 build.ps1 注入）
    // -----------------------------------------------------------------------
    internal static class Payload
    {
        /*__PAYLOAD__*/
    }

    // -----------------------------------------------------------------------
    //  路径与核心操作
    // -----------------------------------------------------------------------
    internal static class App
    {
        public const string TaskName = "CampusNet-AutoLogin";

        public static string Root
        {
            get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CampusNet"); }
        }
        public static string ConfigPath { get { return Path.Combine(Root, "config.json"); } }
        public static string LogPath { get { return Path.Combine(Root, "login.log"); } }
        public static string MainPs1 { get { return Path.Combine(Root, "CampusNet.ps1"); } }
        public static string InstallPs1 { get { return Path.Combine(Root, "install.ps1"); } }
        public static string UninstallPs1 { get { return Path.Combine(Root, "uninstall.ps1"); } }

        public static string PowerShellExe
        {
            get
            {
                string p = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),
                                        @"WindowsPowerShell\v1.0\powershell.exe");
                return File.Exists(p) ? p : "powershell.exe";
            }
        }

        // ---- 释放内嵌脚本 ----
        public static string Extract()
        {
            Directory.CreateDirectory(Root);
            for (int i = 0; i < Payload.Files.Length; i++)
            {
                string rel = Payload.Files[i].Replace('/', Path.DirectorySeparatorChar);
                string full = Path.Combine(Root, rel);
                string dir = Path.GetDirectoryName(full);
                if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
                File.WriteAllBytes(full, Convert.FromBase64String(Payload.Data[i]));
            }
            return Root;
        }

        // ---- DPAPI 加密（与 PowerShell 的 ConvertFrom-SecureString 格式一致）----
        public static string ProtectPassword(string plain)
        {
            byte[] blob = ProtectedData.Protect(Encoding.Unicode.GetBytes(plain), null,
                                                DataProtectionScope.CurrentUser);
            StringBuilder sb = new StringBuilder(blob.Length * 2);
            foreach (byte b in blob) sb.Append(b.ToString("x2"));
            return sb.ToString();
        }

        public static string ReadExistingEncryptedPassword()
        {
            try
            {
                if (!File.Exists(ConfigPath)) return null;
                string text = File.ReadAllText(ConfigPath, Encoding.UTF8);
                Match m = Regex.Match(text, "\"passwordEncrypted\"\\s*:\\s*\"([^\"]*)\"");
                if (m.Success && m.Groups[1].Value.Length > 0) return m.Groups[1].Value;
            }
            catch { }
            return null;
        }

        public static string ReadExistingUserId()
        {
            try
            {
                if (!File.Exists(ConfigPath)) return "";
                string text = File.ReadAllText(ConfigPath, Encoding.UTF8);
                Match m = Regex.Match(text, "\"userId\"\\s*:\\s*\"([^\"]*)\"");
                if (m.Success) return m.Groups[1].Value;
            }
            catch { }
            return "";
        }

        public static bool HasConfig
        {
            get
            {
                return File.Exists(ConfigPath)
                    && (!string.IsNullOrEmpty(ReadExistingUserId()))
                    && (!string.IsNullOrEmpty(ReadExistingEncryptedPassword()));
            }
        }

        private static string Js(string s)
        {
            if (s == null) s = "";
            StringBuilder sb = new StringBuilder();
            foreach (char c in s)
            {
                switch (c)
                {
                    case '"': sb.Append("\\\""); break;
                    case '\\': sb.Append("\\\\"); break;
                    case '\n': sb.Append("\\n"); break;
                    case '\r': sb.Append("\\r"); break;
                    case '\t': sb.Append("\\t"); break;
                    default:
                        if (c < 0x20) sb.Append("\\u").Append(((int)c).ToString("x4"));
                        else sb.Append(c);
                        break;
                }
            }
            return "\"" + sb + "\"";
        }

        // ---- 写 config.json ----
        public static void WriteConfig(string user, string password, string service, bool keepExistingPassword,
                                       bool gameGuard, string[] gameProcesses)
        {
            string enc;
            if (!string.IsNullOrEmpty(password))
            {
                enc = ProtectPassword(password);
            }
            else if (keepExistingPassword)
            {
                enc = ReadExistingEncryptedPassword();
            }
            else
            {
                throw new InvalidOperationException("密码不能为空。");
            }
            if (string.IsNullOrEmpty(enc)) throw new InvalidOperationException("没有可用的密码（首次配置必须输入密码）。");

            StringBuilder json = new StringBuilder();
            json.Append("{\r\n");
            json.Append("  \"userId\": ").Append(Js(user)).Append(",\r\n");
            json.Append("  \"password\": \"\",\r\n");
            json.Append("  \"passwordEncrypted\": ").Append(Js(enc)).Append(",\r\n");
            json.Append("  \"service\": ").Append(Js(service == null ? "" : service)).Append(",\r\n");
            json.Append("  \"portalHost\": \"10.130.128.9\",\r\n");
            json.Append("  \"checkUrls\": [\"http://connect.rom.miui.com/generate_204\", \"http://www.baidu.com\"],\r\n");
            json.Append("  \"logFile\": \"%LOCALAPPDATA%\\\\CampusNet\\\\login.log\",\r\n");
            json.Append("  \"retryCount\": 5,\r\n");
            json.Append("  \"retryDelaySec\": 6,\r\n");
            json.Append("  \"timeoutSec\": 10,\r\n");
            json.Append("  \"treatAlreadyOnlineAsSuccess\": true,\r\n");
            json.Append("  \"gameGuard\": ").Append(gameGuard ? "true" : "false").Append(",\r\n");
            json.Append("  \"gameProcesses\": [");
            if (gameProcesses != null)
            {
                for (int i = 0; i < gameProcesses.Length; i++)
                {
                    if (i > 0) json.Append(", ");
                    json.Append(Js(gameProcesses[i]));
                }
            }
            json.Append("]\r\n");
            json.Append("}\r\n");

            File.WriteAllText(ConfigPath, json.ToString(), new UTF8Encoding(false));
            WriteGameGuardList(gameGuard, gameProcesses);
        }

        // ---- 写 run-hidden.vbs 读的游戏守护名单（禁用时删掉）----
        public static void WriteGameGuardList(bool gameGuard, string[] gameProcesses)
        {
            string lst = Path.Combine(Root, "gameguard.lst");
            try
            {
                if (!gameGuard || gameProcesses == null || gameProcesses.Length == 0)
                {
                    if (File.Exists(lst)) File.Delete(lst);
                    return;
                }
                StringBuilder sb = new StringBuilder();
                sb.Append("# 游戏守护名单：run-hidden.vbs 读这个文件，命中任一进程名就不启动 PowerShell。\r\n");
                sb.Append("# 由安装程序 / CampusNet.ps1 自动生成，请不要手改。\r\n");
                foreach (string g in gameProcesses) sb.Append(g.Trim()).Append("\r\n");
                File.WriteAllText(lst, sb.ToString(), new UTF8Encoding(false));
            }
            catch { }
        }

        // ---- 读回已配置的游戏名单（重跑安装时预填界面）----
        public static string[] ReadExistingGames()
        {
            try
            {
                if (!File.Exists(ConfigPath)) return null;
                string text = File.ReadAllText(ConfigPath, Encoding.UTF8);
                Match m = Regex.Match(text, "\"gameProcesses\"\\s*:\\s*\\[(.*?)\\]", RegexOptions.Singleline);
                if (!m.Success) return null;
                List<string> list = new List<string>();
                foreach (Match g in Regex.Matches(m.Groups[1].Value, "\"([^\"]*)\""))
                {
                    string v = g.Groups[1].Value.Trim();
                    if (v.Length > 0) list.Add(v);
                }
                return list.Count > 0 ? list.ToArray() : null;
            }
            catch { }
            return null;
        }

        public static bool ReadExistingGuardEnabled()
        {
            try
            {
                if (!File.Exists(ConfigPath)) return true;
                string text = File.ReadAllText(ConfigPath, Encoding.UTF8);
                Match m = Regex.Match(text, "\"gameGuard\"\\s*:\\s*(true|false)");
                if (m.Success) return m.Groups[1].Value == "true";
            }
            catch { }
            return true;
        }

        // ---- 读出计划任务当前的检查间隔（分钟），没有则返回 0 ----
        public static int DetectInterval()
        {
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo("schtasks.exe",
                    "/query /tn \"" + TaskName + "\" /xml");
                psi.UseShellExecute = false;
                psi.RedirectStandardOutput = true;
                psi.RedirectStandardError = true;
                psi.CreateNoWindow = true;
                using (Process p = Process.Start(psi))
                {
                    // 同样要并发读，避免 stderr 写满导致死锁
                    Task<string> outTask = p.StandardOutput.ReadToEndAsync();
                    Task<string> errTask = p.StandardError.ReadToEndAsync();
                    p.WaitForExit(8000);
                    string xml = "";
                    try { if (outTask.Wait(2000)) xml = outTask.Result ?? ""; } catch { }
                    try { errTask.Wait(2000); } catch { }

                    Match m = Regex.Match(xml, "<Interval>PT(\\d+)M</Interval>");
                    if (m.Success)
                    {
                        int v;
                        if (int.TryParse(m.Groups[1].Value, out v) && v >= 1 && v <= 1440) return v;
                    }
                }
            }
            catch { }
            return 0;
        }

        // ---- 默认游戏/反作弊进程名单 ----
        // 单一数据源：随程序释放的 gameguard.default.txt（install.ps1 读同一份）。
        // 以前这里和 install.ps1 各写一份，加了游戏就要改两处，容易漂移。
        private static readonly string[] FallbackGames = new string[] {
            "SGuard64", "SGuardSvc64", "valorant", "cs2", "LeagueClient", "TslGame"
        };

        public static string[] GetDefaultGames()
        {
            try
            {
                string f = Path.Combine(Root, "gameguard.default.txt");
                if (File.Exists(f))
                {
                    List<string> list = new List<string>();
                    foreach (string raw in File.ReadAllLines(f, Encoding.UTF8))
                    {
                        string t = raw.Trim();
                        if (t.Length == 0 || t.StartsWith("#")) continue;
                        list.Add(t);
                    }
                    if (list.Count > 0) return list.ToArray();
                }
            }
            catch { }
            return FallbackGames;
        }

        // ---- 调用 PowerShell 脚本（输出经临时文件回传，避免编码问题）----
        public static int RunScript(string scriptPath, string extraArgs, out string output, int timeoutMs)
        {
            output = "";
            string stamp = Guid.NewGuid().ToString("N");
            string wrapper = Path.Combine(Path.GetTempPath(), "cn_wrap_" + stamp + ".ps1");
            string outFile = Path.Combine(Path.GetTempPath(), "cn_out_" + stamp + ".txt");

            // 把整段调用写进一个临时 .ps1，避免命令行引号地狱
            StringBuilder w = new StringBuilder();
            w.Append("$ErrorActionPreference = 'Continue'\r\n");
            w.Append("& '").Append(scriptPath.Replace("'", "''")).Append("' ").Append(extraArgs);
            w.Append(" *>&1 | Out-File -LiteralPath '").Append(outFile.Replace("'", "''")).Append("' -Encoding UTF8\r\n");
            w.Append("$c = $LASTEXITCODE\r\n");
            w.Append("if ($null -eq $c) { $c = 0 }\r\n");
            w.Append("exit $c\r\n");
            File.WriteAllText(wrapper, w.ToString(), new UTF8Encoding(true));

            try
            {
                ProcessStartInfo psi = new ProcessStartInfo();
                psi.FileName = PowerShellExe;
                psi.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" + wrapper + "\"";
                psi.UseShellExecute = false;
                psi.CreateNoWindow = true;
                psi.RedirectStandardOutput = true;
                psi.RedirectStandardError = true;

                using (Process p = Process.Start(psi))
                {
                    // 必须并发读两个管道。经典写法「先 ReadToEnd(stdout) 再 ReadToEnd(stderr)」
                    // 会在子进程把 stderr 缓冲区（默认 4KB）写满时死锁：
                    // 子进程阻塞在写 stderr，而我们在等 stdout 结束，双方互等。
                    Task<string> outTask = p.StandardOutput.ReadToEndAsync();
                    Task<string> errTask = p.StandardError.ReadToEndAsync();

                    if (!p.WaitForExit(timeoutMs))
                    {
                        try { p.Kill(); } catch { }
                        output = "（超时 " + (timeoutMs / 1000) + " 秒，已终止）\r\n";
                        return -9;
                    }

                    // 进程已退出，这里只是把管道排空，不会阻塞太久
                    try { outTask.Wait(2000); } catch { }
                    try { errTask.Wait(2000); } catch { }

                    if (File.Exists(outFile))
                    {
                        output = File.ReadAllText(outFile, Encoding.UTF8);
                    }
                    return p.ExitCode;
                }
            }
            catch (Exception ex)
            {
                output = "调用 PowerShell 失败：" + ex.Message + "\r\n";
                return -1;
            }
            finally
            {
                try { if (File.Exists(wrapper)) File.Delete(wrapper); } catch { }
                try { if (File.Exists(outFile)) File.Delete(outFile); } catch { }
            }
        }

        public static int RunInstall(int intervalMinutes, out string output)
        {
            string args = "-UseExistingConfig -Force -TaskName \"" + TaskName + "\" -IntervalMinutes " + intervalMinutes;
            return RunScript(InstallPs1, args, out output, 120000);
        }

        public static int RunEnsure(out string output)
        {
            return RunScript(MainPs1, "-Mode ensure", out output, 120000);
        }

        public static int RunStatus(out string output)
        {
            return RunScript(MainPs1, "-Mode status", out output, 60000);
        }

        public static int RunUninstall(bool purge, out string output)
        {
            string args = "-TaskName \"" + TaskName + "\"" + (purge ? " -Purge" : "");
            return RunScript(UninstallPs1, args, out output, 60000);
        }
    }

    // -----------------------------------------------------------------------
    //  图形界面
    // -----------------------------------------------------------------------
    internal sealed class MainForm : Form
    {
        private TextBox _user;
        private TextBox _pass;
        private TextBox _service;
        private TextBox _interval;
        private TextBox _output;
        private TextBox _txtGames;
        private CheckBox _chkGuard;
        private Label _status;
        private Button _btnMain, _btnLogin, _btnStatus, _btnLog, _btnUninstall, _btnFolder;
        private bool _busy;

        private static readonly Color Accent = Color.FromArgb(0, 120, 212);
        private static readonly Color Bg = Color.FromArgb(250, 250, 250);

        public MainForm()
        {
            Font = new Font("Microsoft YaHei UI", 9F, FontStyle.Regular, GraphicsUnit.Point);

            Text = "校园网自动登录 · 一键配置";
            ClientSize = new Size(660, 648);
            FormBorderStyle = FormBorderStyle.FixedSingle;
            MaximizeBox = false;
            StartPosition = FormStartPosition.CenterScreen;
            BackColor = Bg;

            Label title = new Label();
            title.Text = "校园网自动登录（深澜 eportal）";
            title.Font = new Font("Microsoft YaHei UI", 13F, FontStyle.Bold);
            title.ForeColor = Accent;
            title.Location = new Point(18, 14);
            title.Size = new Size(500, 28);
            Controls.Add(title);

            Label sub = new Label();
            sub.Text = "填好账号密码，点下面按钮即可。不需要管理员权限，密码本机加密保存。";
            sub.ForeColor = Color.DimGray;
            sub.Location = new Point(20, 44);
            sub.Size = new Size(620, 20);
            Controls.Add(sub);

            _user = AddRow("账号（身份证号）", 76, false);
            _pass = AddRow("密码（身份证后6位）", 110, true);
            _service = AddRow("认证服务名", 144, false);
            _service.Text = "";
            _interval = AddRow("检查间隔（分钟）", 178, false);
            _interval.Text = "5";

            Label hint = new Label();
            hint.Text = "账号填身份证号；密码是身份证后 6 位。服务名不知道就留空，间隔建议 5。";
            hint.ForeColor = Color.Gray;
            hint.Location = new Point(142, 206);
            hint.Size = new Size(500, 18);
            Controls.Add(hint);

            _chkGuard = new CheckBox();
            _chkGuard.Text = "游戏守护：检测到游戏 / 反作弊在运行就暂停自动登录";
            _chkGuard.Checked = true;
            _chkGuard.Location = new Point(144, 228);
            _chkGuard.Size = new Size(430, 22);
            _chkGuard.ForeColor = Color.FromArgb(60, 60, 60);
            _chkGuard.CheckedChanged += delegate { _txtGames.Enabled = _chkGuard.Checked; };
            Controls.Add(_chkGuard);

            Label glabel = new Label();
            glabel.Text = "进程名单";
            glabel.TextAlign = ContentAlignment.TopRight;
            glabel.Location = new Point(8, 258);
            glabel.Size = new Size(132, 20);
            Controls.Add(glabel);

            _txtGames = new TextBox();
            _txtGames.Multiline = true;
            _txtGames.ScrollBars = ScrollBars.Vertical;
            _txtGames.Location = new Point(146, 254);
            _txtGames.Size = new Size(304, 50);
            _txtGames.Font = new Font("Consolas", 8.5F);
            _txtGames.Text = string.Join(", ", App.GetDefaultGames());
            Controls.Add(_txtGames);

            Label ghint = new Label();
            ghint.Text = "逗号或换行分隔。玩游戏时跑一下 tools\\gameguard-check.ps1 可确认是否生效。";
            ghint.ForeColor = Color.Gray;
            ghint.Location = new Point(146, 306);
            ghint.Size = new Size(500, 18);
            Controls.Add(ghint);

            _btnMain = new Button();
            _btnMain.Text = "一键配置并启用";
            _btnMain.Font = new Font("Microsoft YaHei UI", 11F, FontStyle.Bold);
            _btnMain.Location = new Point(146, 330);
            _btnMain.Size = new Size(210, 44);
            _btnMain.BackColor = Accent;
            _btnMain.ForeColor = Color.White;
            _btnMain.FlatStyle = FlatStyle.Flat;
            _btnMain.FlatAppearance.BorderSize = 0;
            _btnMain.Click += OnMainClick;
            Controls.Add(_btnMain);

            _status = new Label();
            _status.Text = "就绪";
            _status.Location = new Point(370, 342);
            _status.Size = new Size(280, 24);
            _status.ForeColor = Color.DimGray;
            Controls.Add(_status);

            _output = new TextBox();
            _output.Multiline = true;
            _output.ReadOnly = true;
            _output.ScrollBars = ScrollBars.Vertical;
            _output.Location = new Point(18, 388);
            _output.Size = new Size(624, 196);
            _output.BackColor = Color.White;
            _output.Font = new Font("Consolas", 8.5F);
            _output.WordWrap = false;
            Controls.Add(_output);

            _btnLogin = AddSmall("立即登录", 18, OnLoginClick);
            _btnStatus = AddSmall("检测状态", 124, OnStatusClick);
            _btnLog = AddSmall("查看日志", 230, OnLogClick);
            _btnFolder = AddSmall("打开目录", 336, OnFolderClick);
            _btnUninstall = AddSmall("卸载", 442, OnUninstallClick);

            Shown += delegate
            {
                try { App.Extract(); } catch (Exception ex) { Append("释放程序文件失败：" + ex.Message); }

                int iv = App.DetectInterval();
                if (iv > 0) _interval.Text = iv.ToString();

                string[] savedGames = App.ReadExistingGames();
                if (savedGames != null) _txtGames.Text = string.Join(", ", savedGames);
                _chkGuard.Checked = App.ReadExistingGuardEnabled();
                _txtGames.Enabled = _chkGuard.Checked;

                if (App.HasConfig)
                {
                    _user.Text = App.ReadExistingUserId();
                    _btnMain.Text = "更新配置并重新启用";
                    _status.Text = "已配置，可更新密码或改间隔";
                    _status.ForeColor = Color.SeaGreen;
                    Append("检测到已有配置，账号 " + _user.Text + "。密码留空则保持原密码不变。");
                    if (iv > 0) Append("当前检查间隔：" + iv + " 分钟（已读出，不改就直接沿用）。");
                }
                else
                {
                    Append("首次使用：账号填身份证号，密码填身份证后 6 位，然后点「一键配置并启用」。");
                }
                Append("");
                Append("游戏守护：" + (_chkGuard.Checked ? "已启用" : "已关闭"));
                Append("程序目录：" + App.Root);
                Append("日志文件：" + App.LogPath);
            };
        }

        // 把界面上的进程名单文本解析成数组（逗号 / 分号 / 换行 都能当分隔符）
        private string[] ParseGames()
        {
            string[] raw = _txtGames.Text.Split(new char[] { ',', ';', '\r', '\n', '\t', '|' });
            List<string> list = new List<string>();
            foreach (string s in raw)
            {
                string v = s.Trim();
                if (v.Length > 0 && !list.Contains(v)) list.Add(v);
            }
            return list.ToArray();
        }

        private TextBox AddRow(string label, int y, bool isPassword)
        {
            Label l = new Label();
            l.Text = label;
            l.TextAlign = ContentAlignment.MiddleRight;
            // 标签列放宽到 132，容得下「密码（身份证后6位）」这种长标签
            l.Location = new Point(8, y + 3);
            l.Size = new Size(132, 22);
            Controls.Add(l);

            TextBox t = new TextBox();
            t.Location = new Point(146, y);
            t.Size = new Size(304, 24);
            if (isPassword) t.UseSystemPasswordChar = true;
            Controls.Add(t);
            return t;
        }

        private Button AddSmall(string text, int x, EventHandler handler)
        {
            Button b = new Button();
            b.Text = text;
            b.Location = new Point(x, 596);
            b.Size = new Size(100, 32);
            b.FlatStyle = FlatStyle.System;
            b.Click += handler;
            Controls.Add(b);
            return b;
        }

        private void SetBusy(bool busy, string statusText)
        {
            _busy = busy;
            foreach (Control c in Controls)
            {
                Button b = c as Button;
                if (b != null) b.Enabled = !busy;
            }
            _status.Text = statusText;
            _status.ForeColor = busy ? Accent : Color.DimGray;
            Cursor = busy ? Cursors.WaitCursor : Cursors.Default;
            _status.Update();
            this.Update();
        }

        private void Append(string text)
        {
            _output.AppendText(text + "\r\n");
            _output.SelectionStart = _output.TextLength;
            _output.ScrollToCaret();
        }

        private void AppendBlock(string text)
        {
            if (string.IsNullOrEmpty(text)) return;
            foreach (string line in text.Replace("\r\n", "\n").Split('\n'))
            {
                if (line.Length > 0) Append(line);
            }
        }

        private int IntervalValue()
        {
            int n;
            if (!int.TryParse(_interval.Text.Trim(), out n) || n < 1 || n > 1440) return 5;
            return n;
        }

        // ---------------- 一键配置 ----------------
        private void OnMainClick(object sender, EventArgs e)
        {
            if (_busy) return;

            string user = _user.Text.Trim();
            if (user.Length == 0) { Warn("请填写账号（身份证号）。"); _user.Focus(); return; }

            string pass = _pass.Text;
            bool hasOld = App.HasConfig;
            if (pass.Length == 0 && !hasOld) { Warn("请填写密码（身份证后 6 位）。"); _pass.Focus(); return; }

            if (hasOld)
            {
                DialogResult dr = MessageBox.Show(
                    "已有配置，是否更新后重新启用？\r\n\r\n账号：" + user,
                    "确认更新", MessageBoxButtons.OKCancel, MessageBoxIcon.Question);
                if (dr != DialogResult.OK) return;
            }

            SetBusy(true, "正在配置…");
            Append("");
            Append("========== " + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " 开始配置 ==========");

            try
            {
                Append("[1/4] 释放程序文件 …");
                string root = App.Extract();
                Append("      " + root);

                Append("[2/4] 加密保存配置（DPAPI）…");
                App.WriteConfig(user, pass, _service.Text.Trim(), hasOld,
                                _chkGuard.Checked, ParseGames());
                _pass.Clear();
                Append("      已写入 " + App.ConfigPath + "（不含明文密码）");
                if (_chkGuard.Checked)
                {
                    Append("      游戏守护：已启用，监控 " + ParseGames().Length + " 个进程名");
                }
                else
                {
                    Append("      游戏守护：已关闭");
                }

                Append("[3/4] 注册开机自启计划任务 …");
                string out1;
                int c1 = App.RunInstall(IntervalValue(), out out1);
                AppendBlock(out1);

                if (c1 != 0)
                {
                    Append("配置未完全成功（退出码 " + c1 + "）。详见上面输出或日志文件。");
                    SetBusy(false, "配置未完成");
                    _status.ForeColor = Color.Firebrick;
                    return;
                }

                Append("[4/4] 立即认证一次 …");
                string out2;
                int c2 = App.RunEnsure(out out2);
                AppendBlock(out2);

                if (c2 == 0)
                {
                    Append("");
                    Append("完成！已联网，并已设置好开机自动登录与掉线重连。");
                    SetBusy(false, "配置成功，已联网");
                    _status.ForeColor = Color.SeaGreen;
                    _btnMain.Text = "更新配置并重新启用";
                    MessageBox.Show("配置完成，当前已联网。\r\n\r\n以后开机会自动登录，掉线也会自动重连。",
                                    "成功", MessageBoxButtons.OK, MessageBoxIcon.Information);
                }
                else
                {
                    Append("");
                    Append("计划任务已装好，但这次没连上（退出码 " + c2 + "）。");
                    Append("登录失败常见原因：密码不对、账号未开通、当前不在校园网内。");
                    SetBusy(false, "已安装，但未联网");
                    _status.ForeColor = Color.DarkOrange;
                }
            }
            catch (Exception ex)
            {
                Append("出错：" + ex.Message);
                SetBusy(false, "配置失败");
                _status.ForeColor = Color.Firebrick;
            }
        }

        private void OnLoginClick(object sender, EventArgs e)
        {
            if (_busy) return;
            SetBusy(true, "正在登录…");
            try
            {
                string o;
                int c = App.RunEnsure(out o);
                AppendBlock(o);
                SetBusy(false, c == 0 ? "已联网" : "未联网");
                _status.ForeColor = c == 0 ? Color.SeaGreen : Color.DarkOrange;
            }
            catch (Exception ex) { Append("出错：" + ex.Message); SetBusy(false, "出错"); }
        }

        private void OnStatusClick(object sender, EventArgs e)
        {
            if (_busy) return;
            SetBusy(true, "检测中…");
            try
            {
                string o;
                int c = App.RunStatus(out o);
                AppendBlock(o);
                SetBusy(false, c == 0 ? "在线" : "离线");
                _status.ForeColor = c == 0 ? Color.SeaGreen : Color.DarkOrange;
            }
            catch (Exception ex) { Append("出错：" + ex.Message); SetBusy(false, "出错"); }
        }

        private void OnLogClick(object sender, EventArgs e)
        {
            try
            {
                if (!File.Exists(App.LogPath)) { Warn("还没有日志文件。先点一次「立即登录」。"); return; }
                string[] lines = File.ReadAllLines(App.LogPath, Encoding.UTF8);
                int start = Math.Max(0, lines.Length - 100);
                _output.Clear();
                Append("========== 日志尾部（最多 100 行） ==========");
                for (int i = start; i < lines.Length; i++) Append(lines[i]);
                Process.Start("notepad.exe", "\"" + App.LogPath + "\"");
            }
            catch (Exception ex) { Warn("读取日志失败：" + ex.Message); }
        }

        private void OnFolderClick(object sender, EventArgs e)
        {
            try { Process.Start("explorer.exe", "\"" + App.Root + "\""); }
            catch (Exception ex) { Warn("打开目录失败：" + ex.Message); }
        }

        private void OnUninstallClick(object sender, EventArgs e)
        {
            if (_busy) return;
            DialogResult dr = MessageBox.Show(
                "确定要卸载吗？\r\n\r\n" +
                "将删除：\r\n" +
                "  · 计划任务（开机自动登录、定时重连）\r\n" +
                "  · 本机保存的账号密码（DPAPI 密文）\r\n" +
                "  · 运行日志\r\n\r\n" +
                "程序文件会保留，以后还能再配置。",
                "卸载", MessageBoxButtons.OKCancel, MessageBoxIcon.Warning);
            if (dr != DialogResult.OK) return;

            SetBusy(true, "正在卸载…");
            try
            {
                string o;
                int c = App.RunUninstall(false, out o);
                AppendBlock(o);
                Append(c == 0 ? "已卸载。程序文件仍在 " + App.Root + "，需要彻底删除就手动删掉这个文件夹。"
                              : "卸载未完全成功（退出码 " + c + "）。");
                _user.Clear();
                _pass.Clear();
                _btnMain.Text = "一键配置并启用";
                SetBusy(false, "已卸载");
                _status.ForeColor = Color.DimGray;
            }
            catch (Exception ex) { Append("出错：" + ex.Message); SetBusy(false, "出错"); }
        }

        private void Warn(string msg)
        {
            MessageBox.Show(msg, "提示", MessageBoxButtons.OK, MessageBoxIcon.Information);
        }
    }

    // -----------------------------------------------------------------------
    //  入口
    // -----------------------------------------------------------------------
    internal static class Program
    {
        [STAThread]
        private static int Main(string[] args)
        {
            if (args.Length == 0)
            {
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                Application.Run(new MainForm());
                return 0;
            }
            return RunCli(args);
        }

        private static string ArgValue(string[] args, string name, string fallback)
        {
            for (int i = 0; i < args.Length - 1; i++)
            {
                if (string.Equals(args[i], name, StringComparison.OrdinalIgnoreCase)) return args[i + 1];
            }
            return fallback;
        }

        private static bool HasFlag(string[] args, string name)
        {
            foreach (string a in args)
            {
                if (string.Equals(a, name, StringComparison.OrdinalIgnoreCase)) return true;
            }
            return false;
        }

        private static int RunCli(string[] args)
        {
            try
            {
                // 控制台交互时用控制台自身的编码（中文系统为 GBK，能正常显示）；
                // 输出被重定向/管道时改用 UTF-8，避免中文乱码。
                if (Console.IsOutputRedirected)
                {
                    StreamWriter sw = new StreamWriter(Console.OpenStandardOutput(), new UTF8Encoding(false));
                    sw.AutoFlush = true;
                    Console.SetOut(sw);
                }
                else
                {
                    try { Console.OutputEncoding = Encoding.UTF8; } catch { }
                }

                if (HasFlag(args, "--selftest"))
                {
                    Console.WriteLine("Root       : " + App.Root);
                    string root = App.Extract();
                    Console.WriteLine("Extracted  : " + root + " (" + Payload.Files.Length + " files)");
                    foreach (string f in Payload.Files)
                    {
                        string full = Path.Combine(root, f.Replace('/', Path.DirectorySeparatorChar));
                        Console.WriteLine(string.Format("  {0,-26} {1,8} bytes", f, new FileInfo(full).Length));
                    }
                    string probe = "RoundTrip!123";
                    string hex = App.ProtectPassword(probe);
                    byte[] back = ProtectedData.Unprotect(HexToBytes(hex), null, DataProtectionScope.CurrentUser);
                    string dec = Encoding.Unicode.GetString(back);
                    Console.WriteLine("DPAPI      : " + (dec == probe ? "OK" : "FAIL"));
                    Console.WriteLine("PowerShell : " + App.PowerShellExe);
                    return 0;
                }

                if (HasFlag(args, "--extract-only"))
                {
                    Console.WriteLine(App.Extract());
                    return 0;
                }

                if (HasFlag(args, "--install"))
                {
                    App.Extract();
                    string user = ArgValue(args, "--user", "");
                    string service = ArgValue(args, "--service", "");
                    int interval = 5;
                    int.TryParse(ArgValue(args, "--interval", "5"), out interval);
                    if (interval < 1) interval = 5;
                    if (user.Length == 0) { Console.Error.WriteLine("缺少 --user"); return 2; }

                    // 密码不从命令行取。命令行参数会出现在进程列表里（任务管理器、
                    // Get-CimInstance Win32_Process 都能看到），同一台机器上其他用户
                    // 就能读到明文密码。改成从 stdin 读一行。
                    // 图形界面那条路径本来就不经命令行，不受影响。
                    string pass = "";
                    if (HasFlag(args, "--pass-stdin"))
                    {
                        pass = Console.ReadLine() ?? "";
                        pass = pass.TrimEnd('\r', '\n');
                    }
                    else if (ArgValue(args, "--pass", null) != null)
                    {
                        Console.Error.WriteLine("--pass 已移除：明文密码走命令行会被同机其他用户看到。");
                        Console.Error.WriteLine("请改用：echo 你的密码 | CampusNet-Setup.exe --install --user X --pass-stdin");
                        return 2;
                    }

                    // 游戏守护：默认启用 + 默认名单，可用 --noguard 关闭，--games "a,b,c" 覆盖名单
                    bool guard = !HasFlag(args, "--noguard");
                    string gamesArg = ArgValue(args, "--games", "");
                    string[] games;
                    if (gamesArg.Length > 0)
                    {
                        List<string> gl = new List<string>();
                        foreach (string s in gamesArg.Split(new char[] { ',', ';' }))
                        {
                            string v = s.Trim();
                            if (v.Length > 0) gl.Add(v);
                        }
                        games = gl.ToArray();
                    }
                    else
                    {
                        string[] existing = App.ReadExistingGames();
                        games = existing ?? App.GetDefaultGames();
                    }

                    App.WriteConfig(user, pass, service, App.HasConfig, guard, games);
                    string o1;
                    int c1 = App.RunInstall(interval, out o1);
                    Console.Write(o1);
                    if (c1 != 0) return c1;
                    string o2;
                    int c2 = App.RunEnsure(out o2);
                    Console.Write(o2);
                    return c2;
                }

                if (HasFlag(args, "--ensure")) { App.Extract(); string o; int c = App.RunEnsure(out o); Console.Write(o); return c; }
                if (HasFlag(args, "--status")) { App.Extract(); string o; int c = App.RunStatus(out o); Console.Write(o); return c; }

                // 诊断游戏守护：现在会不会拦？玩游戏时跑这个就能确认是否生效。
                if (HasFlag(args, "--gamecheck"))
                {
                    bool guard = App.ReadExistingGuardEnabled();
                    string[] games = App.ReadExistingGames() ?? App.GetDefaultGames();
                    Console.WriteLine("游戏守护      : " + (guard ? "已启用" : "已关闭（不会拦截）"));
                    Console.WriteLine("监控进程数    : " + games.Length);
                    List<string> hits = new List<string>();
                    try
                    {
                        foreach (Process p in Process.GetProcesses())
                        {
                            string n = null;
                            try { n = p.ProcessName; } catch { continue; }
                            if (string.IsNullOrEmpty(n)) continue;
                            foreach (string g in games)
                            {
                                string gg = g.Trim();
                                if (gg.Length == 0) continue;
                                if (gg.EndsWith(".exe", StringComparison.OrdinalIgnoreCase))
                                    gg = gg.Substring(0, gg.Length - 4);
                                if (string.Equals(n, gg, StringComparison.OrdinalIgnoreCase))
                                {
                                    if (!hits.Contains(n)) hits.Add(n);
                                    break;
                                }
                            }
                        }
                    }
                    catch (Exception ex) { Console.WriteLine("枚举进程失败：" + ex.Message); }

                    if (!guard) Console.WriteLine("当前判定      : 放行（守护已关闭）");
                    else if (hits.Count > 0)
                        Console.WriteLine("当前判定      : 会拦截 —— 发现 " + string.Join(", ", hits.ToArray()));
                    else
                        Console.WriteLine("当前判定      : 放行（没发现监控中的进程）");

                    string lst = Path.Combine(App.Root, "gameguard.lst");
                    Console.WriteLine("VBS 名单文件  : " + (File.Exists(lst) ? "存在" : "不存在") + "  " + lst);
                    return 0;
                }
                if (HasFlag(args, "--uninstall"))
                {
                    string o;
                    int c = App.RunUninstall(HasFlag(args, "--purge"), out o);
                    Console.Write(o);
                    return c;
                }

                Console.Error.WriteLine("未知参数。可用：--install --ensure --status --gamecheck --uninstall --selftest --extract-only");                return 2;
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine("错误：" + ex.Message);
                return 1;
            }
        }

        private static byte[] HexToBytes(string hex)
        {
            byte[] b = new byte[hex.Length / 2];
            for (int i = 0; i < b.Length; i++) b[i] = Convert.ToByte(hex.Substring(i * 2, 2), 16);
            return b;
        }
    }
}
