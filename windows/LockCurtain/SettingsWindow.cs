// SettingsWindow.cs —— 设置窗口，对应 Mac 版 SettingsWindow.swift
//
// 左边是页面列表，右边是当前页（PageView.cs）。改动立即写进 Settings / RuleStore，没有「保存」按钮。
// 深浅色跟着系统（Program.cs 里 Application.SetColorMode），底色和卡片用 Win11 设置的配色。
//
// 侧栏顺序和 Mac 版一致（Colo A1）：通用 / 手机 / 离开模式 / 保持唤醒 / 规则 / 远程控制 / 权限。和 Mac 版的差别：
//   通用      没有「在 Dock 中显示」和「锁屏时也盖上幕布」：Windows 的锁屏界面在安全桌面上，幕布盖不上去
//   手机      同一套（A1）：配上的手机一台一行（已连上 / 没连上 · 上次连上），一台一台撤；没配过时是空状态；蓝牙横幅
//   离开模式  一样
//   保持唤醒  同一套（A3）：和托盘面板、右键菜单同一份菜单（KeepAwakeMenu）
//   规则      一样（RulesPage.cs）
//   远程控制  只有一行命令（copy §16.9，D2）；SSH 远程控制还没在 Windows 上实测过，先不写步骤
//   权限      Windows 不用系统授权，这页是「以管理员身份运行」开了没有，没开有「开启」（D5，走 install.ps1，界面上不提脚本名）

using System.ComponentModel;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Media;
using LockCurtain.Phone;

namespace LockCurtain;

internal sealed class SettingsWindow : Form
{
    const int LogicalWidth = 760, LogicalHeight = 520, NavWidth = 200, NavItemHeight = 36;

    public const string PhonePage = "手机", KeepAwakePage = "保持唤醒";

    readonly Action enterAway, showPairing, showGuide;
    readonly PhoneLink phone;
    readonly KeepAwake keepAwake;
    readonly Theme theme = Theme.Current();
    /// 手机页的「N 分钟前」、保持唤醒页的「还剩 …」跟着走
    readonly System.Windows.Forms.Timer tick = new() { Interval = 30_000 };
    /// 画好的行首图标（手机、杯子、警告），关窗时扔掉
    readonly Dictionary<string, Bitmap> icons = new();
    /// 保持唤醒页「到指定时间…」的选择框开着，和里面选的时刻（当天零点起的分钟）
    bool picking;
    int pickMinute;
    /// 权限页「开启」没开成的原因
    string? elevateError;
    readonly (string Title, Action<PageView> Build)[] pages;
    readonly Panel navPanel = new() { Dock = DockStyle.Left };
    readonly ListBox nav = new() { Dock = DockStyle.Fill, BorderStyle = BorderStyle.None, DrawMode = DrawMode.OwnerDrawFixed, IntegralHeight = false };
    readonly PageView page;
    Font? navFont;

    public SettingsWindow(RuleStore rules, Action enterAway, PhoneLink phone, KeepAwake keepAwake, Action showPairing, Action showGuide)
    {
        this.enterAway = enterAway;
        this.phone = phone;
        this.keepAwake = keepAwake;
        this.showPairing = showPairing;
        this.showGuide = showGuide;
        pages = new (string, Action<PageView>)[]
        {
            ("通用", BuildGeneral),
            (PhonePage, BuildPhone),
            ("离开模式", BuildAway),
            (KeepAwakePage, BuildKeepAwake),
            (RulesPage.Title, v => RulesPage.Build(v, rules, this)),
            ("远程控制", BuildRemote),
            ("权限", BuildPermissions),
        };
        Text = "LockCurtain 设置";
        Icon = Icon.ExtractAssociatedIcon(Environment.ProcessPath!);
        AutoScaleMode = AutoScaleMode.None;
        StartPosition = FormStartPosition.CenterScreen;
        BackColor = theme.Page;

        page = new PageView(theme) { Dock = DockStyle.Fill };
        nav.BackColor = navPanel.BackColor = theme.Page;
        nav.Items.AddRange(pages.Select(p => (object)p.Title).ToArray());
        nav.DrawItem += DrawNavItem;
        nav.SelectedIndexChanged += (_, _) => ShowPage();
        navPanel.Controls.Add(nav);
        // 先加铺满的，再加靠左的：Dock 按加入的倒序排
        Controls.Add(page);
        Controls.Add(navPanel);

        ApplyDpi();
        ClientSize = new Size(S(LogicalWidth), S(LogicalHeight));
        nav.SelectedIndex = 0;

        phone.PhonesChanged += OnPhonesChanged;
        keepAwake.Changed += OnKeepAwakeChanged;
        tick.Tick += (_, _) => { Refresh(PhonePage); Refresh(KeepAwakePage); };
        tick.Start();
    }

    string CurrentTitle => pages[Math.Max(0, nav.SelectedIndex)].Title;

    /// 换到某一页（托盘菜单、面板「手机」那一行、开始指南用）
    public void Select(string title)
    {
        var i = Array.FindIndex(pages, p => p.Title == title);
        if (i >= 0) nav.SelectedIndex = i;
    }

    /// 右键菜单「保持唤醒 ▸ 到指定时间…」：到保持唤醒页，展开选时刻的框
    public void PickKeepAwakeTime()
    {
        pickMinute = KeepAwakeMenu.DefaultPickMinute();
        picking = true;
        if (CurrentTitle == KeepAwakePage) Refresh(KeepAwakePage);
        else Select(KeepAwakePage);
    }

    /// 这一页正开着就重建（停在原来滚到的位置）。点的按钮可能还在处理 Click（比如撤销配对），等它返回再重建
    void Refresh(string title)
    {
        if (IsDisposed || !IsHandleCreated || CurrentTitle != title) return;
        BeginInvoke(() =>
        {
            if (IsDisposed || CurrentTitle != title) return;
            var index = Math.Max(0, nav.SelectedIndex);
            page.Build(pages[index].Title, pages[index].Build, keepScroll: true);
        });
    }

    void OnPhonesChanged() => Refresh(PhonePage);

    void OnKeepAwakeChanged()
    {
        picking = false;
        Refresh(KeepAwakePage);
    }

    Bitmap Icon24(string key, Func<int, Bitmap> make)
    {
        key = $"{key}@{DeviceDpi}";
        if (!icons.TryGetValue(key, out var bmp)) icons[key] = bmp = make(S(24));
        return bmp;
    }

    int S(int logical) => LogicalToDeviceUnits(logical);

    void ApplyDpi()
    {
        MinimumSize = SizeFromClientSize(new Size(S(680), S(440)));
        navPanel.Width = S(NavWidth);
        navPanel.Padding = new Padding(S(8), S(12), S(8), S(12));
        navFont?.Dispose();
        navFont = PageView.UiFont(14, FontStyle.Regular, DeviceDpi);
        nav.ItemHeight = S(NavItemHeight);
    }

    protected override void OnDpiChanged(DpiChangedEventArgs e)
    {
        base.OnDpiChanged(e);
        ApplyDpi();
        ShowPage();
    }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        Native.UseDarkTitleBar(Handle, theme.Dark);
    }

    protected override void OnFormClosed(FormClosedEventArgs e)
    {
        phone.PhonesChanged -= OnPhonesChanged;
        keepAwake.Changed -= OnKeepAwakeChanged;
        tick.Dispose();
        foreach (var b in icons.Values) b.Dispose();
        navFont?.Dispose();
        Icon?.Dispose();
        base.OnFormClosed(e);
    }

    void ShowPage()
    {
        var index = Math.Max(0, nav.SelectedIndex);
        page.Build(pages[index].Title, pages[index].Build);
    }

    void DrawNavItem(object? sender, DrawItemEventArgs e)
    {
        if (e.Index < 0) return;
        var g = e.Graphics;
        using (var back = new SolidBrush(theme.Page)) g.FillRectangle(back, e.Bounds);
        var r = Rectangle.Inflate(e.Bounds, 0, -S(2));
        if ((e.State & DrawItemState.Selected) != 0)
        {
            using var fill = new SolidBrush(Theme.Mix(theme.Text, theme.Page, 7));
            PageView.FillRounded(g, fill, null, r, S(4));
            // Win11 设置左边那条强调色短竖线
            using var bar = new SolidBrush(theme.Accent);
            PageView.FillRounded(g, bar, null, new Rectangle(r.X, r.Y + r.Height / 2 - S(8), S(3), S(16)), S(1));
        }
        TextRenderer.DrawText(g, pages[e.Index].Title, navFont, Rectangle.FromLTRB(r.X + S(14), r.Y, r.Right, r.Bottom),
                              theme.Text, PageView.LineFlags);
    }

    // MARK: - 各页

    void BuildGeneral(PageView v)
    {
        var installed = ElevatedTask.IsInstalled();
        v.Section("启动", () => installed
                // COPY-TODO: 原句带 install.ps1（D5 不许出现脚本名），按 §14.2「以后每次登录 Windows 都会自动启动」改写
                ? "已开启以管理员身份运行：以后每次登录 Windows 都会自动启动。"
                : "")
            .Toggle("登录时打开 LockCurtain", () => installed || LoginItem.IsEnabled(), LoginItem.Set, enabled: !installed);
        v.Section("图标", () => Settings.Current.ShowTrayIcon
                ? ""
                : $"隐藏后，再打开一次 LockCurtain 即可回到这里，也可以运行 {CommandLine("settings")}")
            .Toggle("在通知区域显示", () => Settings.Current.ShowTrayIcon, on => Settings.Update(s => s.ShowTrayIcon = on));
        var tiles = Enum.GetValues<CurtainArt>().Select(a => new ArtTile(a, theme) { Checked = a == Settings.Current.CurtainArt }).ToList();
        var customTile = tiles.Single(t => t.Art == CurtainArt.Custom);
        foreach (var t in tiles) t.CheckedChanged += (_, _) => v.Arrange();
        void SetImage(string? name)
        {
            var old = Settings.Current.CurtainImage;
            Settings.Update(s => s.CurtainImage = name);
            CustomArt.Delete(old);
            customTile.Invalidate();
            v.Arrange();
        }
        void PickImage()
        {
            using var dialog = new OpenFileDialog { Title = "选择图片", Filter = CustomArt.FileFilter };
            if (dialog.ShowDialog(this) != DialogResult.OK) return;
            // 缩小后存进设置目录，原图挪走、删掉都不影响
            if (CustomArt.Import(dialog.FileName) is { } name) SetImage(name);
            else SystemSounds.Beep.Play();
        }
        bool custom() => Settings.Current.CurtainArt == CurtainArt.Custom;
        v.Section("幕布图案", () => custom()
                ? "没选图片时用账户头像。选的图会缩小后存进 LockCurtain 的设置，原图删掉也不影响。下次盖上幕布时生效。"
                : "显示在幕布中间、提示文案上方。下次盖上幕布时生效。")
            .Tiles(tiles)
            .Only(() => custom() && Settings.Current.CurtainImage == null, g => g
                .Controls("图片", "账户头像", v.MakeButton("选择图片…", PickImage)))
            .Only(() => custom() && Settings.Current.CurtainImage != null, g => g
                .Controls("图片", "自己选的图片", v.MakeButton("改回账户头像", () => SetImage(null)), v.MakeButton("选择图片…", PickImage)))
            .Only(custom, g => g
                .Toggle("裁成圆形", () => Settings.Current.CurtainImageRound, on =>
                {
                    Settings.Update(s => s.CurtainImageRound = on);
                    customTile.Invalidate();
                }));
        var backgroundTiles = Enum.GetValues<CurtainBackground>()
            .Select(b => new BackgroundTile(b, theme) { Checked = b == Settings.Current.CurtainBackground }).ToList();
        v.Section("幕布背景", () => "壁纸和模糊壁纸用当前的桌面壁纸；星空、远山、碳纤维是程序画的。下次盖上幕布时生效。")
            .Tiles(backgroundTiles);
        _ = LoadThumbnailsAsync(backgroundTiles);
        var titleBox = CurtainTextBox(v, "标题", Settings.Current.CurtainTitle, text => Settings.Update(s => s.CurtainTitle = text));
        // 提示没自己写过时跟着模式变（copy §16.6）：框里显示离开模式那句，改回这句就是又跟着变
        var awayHint = Settings.DefaultSubtitle(CurtainMode.Away);
        var subtitleBox = CurtainTextBox(v, "提示", Settings.Current.CurtainSubtitle ?? awayHint,
                                         text => Settings.Update(s => s.CurtainSubtitle = text == awayHint ? null : text));
        v.Section("幕布文字", () => "显示在图案下面，太长会自动换行。留空就不显示这一行。下次盖上幕布时生效。")
            .Controls("标题", null, titleBox)
            .Controls("提示", null, subtitleBox)
            .Only(() => Settings.Current.CurtainTitle != Settings.DefaultCurtainTitle
                        || Settings.Current.CurtainSubtitle != null, g => g
                .Button("恢复默认", () =>
                {
                    titleBox.Text = Settings.DefaultCurtainTitle;
                    subtitleBox.Text = awayHint;
                }));
        v.Section("关于")
            .Value("版本", Updater.Version, button: Updater.Available ? ("检查更新…", new Action(Updater.CheckNow)) : null)
            .Only(() => Updater.Available, g => g
                .Toggle("自动检查更新", () => Settings.Current.AutoCheckUpdates, on => Settings.Update(s => s.AutoCheckUpdates = on)))
            .Button("再看一遍开始指南", showGuide);
    }

    /// 远程控制页教的那一行（copy §16.9）：真实路径拼好，PowerShell 里照抄就能跑
    static string CommandLine(string command) =>
        $"& \"{Path.Combine(AppContext.BaseDirectory, "LockCurtain.exe")}\" --send {command}";

    /// 「拷贝」：点了按钮字变「已拷贝」，1.5 秒后变回来（copy §16.7，D11）
    static Button CopyButton(PageView v, string text)
    {
        Button? b = null;
        b = v.MakeButton("拷贝", () =>
        {
            try { Clipboard.SetText(text); }
            catch (System.Runtime.InteropServices.ExternalException e)
            {
                // 剪贴板被别的程序占着
                Log.Write($"拷贝失败: {e.Message}");
                SystemSounds.Beep.Play();
                return;
            }
            b!.Text = "已拷贝";
            v.Arrange();
            var back = new System.Windows.Forms.Timer { Interval = 1500 };
            back.Tick += (_, _) =>
            {
                back.Dispose();
                if (b.IsDisposed) return;
                b.Text = "拷贝";
                v.Arrange();
            };
            back.Start();
        });
        return b;
    }

    /// 遮罩文字的输入框：每改一个字就存，「恢复默认」该不该显示跟着变，所以重排
    static TextBox CurtainTextBox(PageView v, string name, string text, Action<string> save)
    {
        var box = new TextBox { Text = text, PlaceholderText = "不显示", Font = v.BodyFont, Width = v.S(300), AccessibleName = name };
        box.TextChanged += (_, _) =>
        {
            save(box.Text);
            v.Arrange();
        };
        return box;
    }

    /// 背景缩略图在后台画：程序画的按 480×300 点、0.4 倍画（和 Mac 版一样）；
    /// 壁纸两格用主屏的壁纸按系统铺法画整屏，再缩小、模糊，和遮罩上看到的一致。纯黑没有图
    static async Task LoadThumbnailsAsync(List<BackgroundTile> tiles)
    {
        foreach (var tile in tiles)
            if (await Task.Run(() => tile.Background.Render(192, 120, 0.4f)) is { } image) tile.SetThumbnail(image);
        if (Screen.PrimaryScreen is not { } screen) return;
        var images = await Task.Run(() =>
        {
            if (!Wallpaper.Load([screen]).TryGetValue(screen.DeviceName, out var wallpaper)) return null;
            var size = screen.Bounds.Size;
            using var full = OverlayForm.RenderWallpaper(wallpaper, screen.Bounds, size);
            var small = new Bitmap(320, Math.Max(1, 320 * size.Height / size.Width), PixelFormat.Format32bppPArgb);
            using (var g = Graphics.FromImage(small))
            using (var edges = new ImageAttributes())
            {
                // 边上镜像取样，缩小后边缘不发灰
                edges.SetWrapMode(WrapMode.TileFlipXY);
                g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                g.DrawImage(full, new Rectangle(Point.Empty, small.Size), 0, 0, full.Width, full.Height, GraphicsUnit.Pixel, edges);
            }
            return new Dictionary<CurtainBackground, Bitmap> { [CurtainBackground.Wallpaper] = small, [CurtainBackground.Blurred] = CurtainBackgrounds.Blur(full) };
        });
        foreach (var tile in tiles)
            if (images?.Remove(tile.Background, out var image) == true) tile.SetThumbnail(image);
    }

    void BuildAway(PageView v)
    {
        v.Section("防休眠", () => "关掉「屏幕常亮」后只阻止系统休眠，屏幕可以熄灭；熄屏后要不要重新登录，看系统的登录选项和屏幕保护程序设置。"
                               + "亮度只对笔记本内置屏有效，撤下幕布时恢复。设置在下次盖上幕布时生效。")
            .Toggle("屏幕常亮", () => Settings.Current.AwayKeepDisplayOn, on => Settings.Update(s => s.AwayKeepDisplayOn = on))
            .Toggle("亮度调到最低", () => Settings.Current.AwayDimBrightness, on => Settings.Update(s => s.AwayDimBrightness = on));
        v.Section("离开模式", () => "幕布盖着的时候，你的按键和点击会被吞掉，不会传给下层的程序；agent 的合成输入照常穿透。")
            .Value("回来时", "碰一下键盘或鼠标：先锁屏，再撤下幕布")
            .Button("现在盖上幕布", enterAway);
    }

    // MARK: - 手机（Colo A1，copy §16.1）

    void BuildPhone(PageView v)
    {
        phone.Probe();      // 没配过手机也看一眼蓝牙开着没有
        var warning = Icon24("warning", size => PageView.GlyphBitmap("\uE7BA", size, Color.FromArgb(0xF2, 0xA6, 0x1E)));
        var phoneIcon = Icon24("phone", size => PageView.GlyphBitmap("\uE8EA", size, theme.Secondary));
        if (phone.BluetoothUnsupported)
            v.Section().Item(warning, "这台电脑的蓝牙用不了，手机连不上。", null);
        else if (phone.BluetoothOn == false)
            // COPY-TODO: §16.1 只说「后面配一颗按钮」，按钮字用 Colo A1 的「打开蓝牙设置」
            v.Section().Item(warning, "蓝牙关了，手机连不上。", null, controls: v.MakeButton("打开蓝牙设置", OpenBluetoothSettings));

        var phones = phone.Phones;
        // 没有配对的手机时是空状态页；但走网络的开关还开着的话照样露出来，不然关不掉（和 Mac 一样）
        if (phones.Count == 0 && !phone.NetworkEnabled)
        {
            v.Section().Item(phoneIcon, "还没配对手机",
                             "配对以后，手机上能盖上幕布、走近时撤下幕布，还能开关保持唤醒。\n手机上先装 LockCurtain。");
            v.Section().Bare().Controls("", null, v.MakeButton("配对手机…", showPairing, prominent: true));
            return;
        }
        var now = DateTime.UtcNow;
        var list = v.Section("已配对的手机");
        if (phones.Count == 0) list = v.Section();
        foreach (var p in phones)
        {
            var id = p.ID;
            list.Add(new PageView.Row
            {
                Icon = phoneIcon,
                // 「iPhone · 11 月 4 日配上」：日期次要颜色，同一行
                Title = p.Name,
                TitleNote = UiText.PhoneTitleParts(p.Name, p.PairedAt).Note,
                Detail = UiText.PhoneStatus(p.Connected, p.LastSeen, now, path: p.Path),
                DetailDot = p.Connected ? v.ConnectedDot : v.DisconnectedDot,
                Controls = [v.MakeButton("撤销配对", () => PairingForm.ConfirmUnpair(phone, id, this))],
            });
        }
        v.Section("", () => "手机能做的：盖上幕布；你走近、手机解锁着时撤下幕布；开关保持唤醒。").Bare()
            .Controls("", null, v.MakeButton("配对手机…", showPairing));
        BuildPhoneNetwork(v);
    }

    /// 走网络：开关 + 打开后每个本机地址一行（等宽 ip:port + 拷贝）。文案：Camo copy v15.13 §18.2 / §18.6（NetworkText）
    void BuildPhoneNetwork(PageView v)
    {
        var g = v.Section("网络", () => NetworkText.Allowed + "\n" + NetworkText.Tailscale);
        g.Toggle(NetworkText.Switch, () => phone.NetworkEnabled, on => phone.SetNetworkEnabled(on));
        if (!phone.NetworkEnabled) return;
        var status = phone.NetworkStatus;
        if (status.State == GatewayState.Failed)
        {
            g.Text(NetworkText.Failed);
            return;
        }
        if (status.State != GatewayState.Listening) return;
        var addresses = phone.NetworkAddresses;
        if (addresses.Count == 0) g.Text(NetworkText.NoAddress);
        foreach (var entry in addresses)
        {
            var line = entry.Text(status.Port);
            // 网络类型（Wi-Fi / Tailscale / 以太网 / 其他）放在地址右边的值位置，次要色；Mac 是行首
            g.Add(new PageView.Row { Title = line, MonoTitle = true, Value = entry.Label, Controls = [CopyButton(v, line)] });
        }
    }

    static void OpenBluetoothSettings()
    {
        try { Process.Start(new ProcessStartInfo("ms-settings:bluetooth") { UseShellExecute = true })?.Dispose(); }
        catch (Win32Exception e) { Log.Write($"打开蓝牙设置失败: {e.Message}"); }
    }

    // MARK: - 保持唤醒（Colo A3，copy §16.2）

    void BuildKeepAwake(PageView v)
    {
        var g = v.Section("保持唤醒", () => "不盖幕布，只让电脑不睡；屏幕照样会熄灭。手机上也能开关。"
                                         + "离开模式里的防休眠是另一件事，在「离开模式」那一页。");
        if (picking)
        {
            var picker = RuleEditor.TimePicker(v, pickMinute, "保持唤醒到");
            picker.ValueChanged += (_, _) => pickMinute = picker.Minute;
            g.Controls("保持唤醒到", null, picker,
                       v.MakeButton("取消", () => { picking = false; Refresh(KeepAwakePage); }),
                       v.MakeButton("开始", () => KeepAwakeMenu.StartAt(keepAwake, pickMinute), prominent: true));
        }
        else if (keepAwake.Mode != null)
        {
            var cup = Icon24("cup", size => TrayApp.CupImage(size, theme.Text));
            Button? change = null;
            // COPY-TODO: 「改时长」是 Colo A3 的字，Camo §16 没写
            change = v.MakeButton("改时长", () => ShowKeepAwakeMenu(change!));
            g.Item(cup, "LockCurtain 保持唤醒", keepAwake.Detail() + (keepAwake.StartedByPhone ? " · 手机开的" : ""),
                   controls: [change, v.MakeButton("停止", keepAwake.Stop)]);
        }
        else
        {
            Button? start = null;
            start = v.MakeButton("开始", () => ShowKeepAwakeMenu(start!));
            g.Controls("关", null, start);
        }
    }

    void ShowKeepAwakeMenu(Button from) =>
        NativeMenu.Show(Handle, from.PointToScreen(new Point(0, from.Height)), KeepAwakeMenu.Choices(keepAwake, PickKeepAwakeTime));

    /// 只教一行（copy §16.9，D2）：真实路径拼好，「拷贝」拷的就是这一行
    void BuildRemote(PageView v)
    {
        var line = CommandLine("away");
        v.Section("命令行", () => NetworkText.RemoteFooter)
            .Add(new PageView.Row { Title = line, MonoTitle = true, Controls = [CopyButton(v, line)] });
    }

    void BuildPermissions(PageView v)
    {
        var installed = ElevatedTask.IsInstalled();
        // COPY-TODO: 原段落带 install.ps1（D5），只把脚本名换成「开启」，其余照旧
        var section = v.Section("以管理员身份运行", () => "以管理员身份运行的窗口在前台时，普通权限的 LockCurtain 看不到发给它的按键："
                                         + "按键会先落进那个窗口，约 0.2 秒后才发现并锁屏。开启后，登录时以管理员身份启动，能直接拦住这些按键。"
                                         + "开启要管理员确认一次。");
        // copy v15 §17.2-3：已开 / 没开
        if (installed) section.Value("以管理员身份运行", "已开");
        else section.Add(new PageView.Row
        {
            Title = "以管理员身份运行",
            Detail = elevateError,
            Value = "没开",
            Controls = [v.MakeButton("开启", () =>
            {
                elevateError = ElevatedTask.Enable();
                Refresh("权限");
            })],
        });
        section.Value("当前实例", ElevatedTask.IsElevated() ? "以管理员身份运行" : "普通权限");
        v.Section("排查信息")
            .Button("打开日志文件夹", Log.OpenDir);
    }
}
