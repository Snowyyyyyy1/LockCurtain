// SettingsWindow.cs —— 设置窗口，对应 Mac 版 SettingsWindow.swift
//
// 左边是页面列表，右边是当前页（PageView.cs）。改动立即写进 Settings / RuleStore，没有「保存」按钮。
// 深浅色跟着系统（Program.cs 里 Application.SetColorMode），底色和卡片用 Win11 设置的配色。
//
// 和 Mac 版五页的差别：
//   通用      没有「在 Dock 中显示」和「锁屏时显示遮罩」：Windows 的锁屏界面在安全桌面上，遮罩画不上去
//   离开模式  一样
//   规则      一样（RulesPage.cs）
//   远程控制  只有命令行；SSH 远程控制还没在 Windows 上实测过，先不写步骤
//   权限      Windows 不用系统授权，这页显示有没有用 install.ps1 以最高权限安装

using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Media;

namespace LockCurtain;

internal sealed class SettingsWindow : Form
{
    const int LogicalWidth = 760, LogicalHeight = 520, NavWidth = 200, NavItemHeight = 36;

    readonly Action enterAway;
    readonly Theme theme = Theme.Current();
    readonly (string Title, Action<PageView> Build)[] pages;
    readonly Panel navPanel = new() { Dock = DockStyle.Left };
    readonly ListBox nav = new() { Dock = DockStyle.Fill, BorderStyle = BorderStyle.None, DrawMode = DrawMode.OwnerDrawFixed, IntegralHeight = false };
    readonly PageView page;
    Font? navFont;

    public SettingsWindow(RuleStore rules, Action enterAway)
    {
        this.enterAway = enterAway;
        pages = new (string, Action<PageView>)[]
        {
            ("通用", BuildGeneral),
            ("离开模式", BuildAway),
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
                ? "已用 install.ps1 安装：登录时由计划任务以最高权限启动。不想自动启动，用 install.ps1 -Uninstall 卸载。"
                : "")
            .Toggle("登录时打开 LockCurtain", () => installed || LoginItem.IsEnabled(), LoginItem.Set, enabled: !installed);
        v.Section("图标", () => Settings.Current.ShowTrayIcon
                ? ""
                : "隐藏后，再打开一次 LockCurtain 即可回到这里，也可以运行 LockCurtain.exe settings。")
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
        v.Section("遮罩图案", () => custom()
                ? "没选图片时用账户头像。选的图会缩小后存进 LockCurtain 的设置，原图删掉也不影响。下次显示遮罩时生效。"
                : "显示在遮罩中间、提示文案上方。下次显示遮罩时生效。")
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
        v.Section("遮罩背景", () => "壁纸和模糊壁纸用当前的桌面壁纸；星空、远山、碳纤维是程序画的。下次显示遮罩时生效。")
            .Tiles(backgroundTiles);
        _ = LoadThumbnailsAsync(backgroundTiles);
        var titleBox = CurtainTextBox(v, "标题", Settings.Current.CurtainTitle, text => Settings.Update(s => s.CurtainTitle = text));
        var subtitleBox = CurtainTextBox(v, "提示", Settings.Current.CurtainSubtitle, text => Settings.Update(s => s.CurtainSubtitle = text));
        v.Section("遮罩文字", () => "显示在图案下面，太长会自动换行。留空就不显示这一行。下次显示遮罩时生效。")
            .Controls("标题", null, titleBox)
            .Controls("提示", null, subtitleBox)
            .Only(() => Settings.Current.CurtainTitle != Settings.DefaultCurtainTitle
                        || Settings.Current.CurtainSubtitle != Settings.DefaultCurtainSubtitle, g => g
                .Button("恢复默认", () =>
                {
                    titleBox.Text = Settings.DefaultCurtainTitle;
                    subtitleBox.Text = Settings.DefaultCurtainSubtitle;
                }));
        v.Section("关于")
            .Value("版本", Updater.Version)
            .Only(() => Updater.Available, g => g
                .Toggle("自动检查更新", () => Settings.Current.AutoCheckUpdates, on => Settings.Update(s => s.AutoCheckUpdates = on)));
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
                               + "亮度只对笔记本内置屏有效，撤掉遮罩时恢复。设置在下次进入离开模式时生效。")
            .Toggle("屏幕常亮", () => Settings.Current.AwayKeepDisplayOn, on => Settings.Update(s => s.AwayKeepDisplayOn = on))
            .Toggle("亮度调到最低", () => Settings.Current.AwayDimBrightness, on => Settings.Update(s => s.AwayDimBrightness = on));
        v.Section("离开模式", () => "遮罩期间你的按键和点击会被吞掉，不会传给下层的程序；agent 的合成输入照常穿透。")
            .Value("回来时", "碰一下键盘或鼠标：先锁屏，再撤掉遮罩")
            .Button("立即进入离开模式", enterAway);
    }

    void BuildRemote(PageView v)
    {
        var exe = Path.Combine(AppContext.BaseDirectory, "LockCurtain.exe");
        var section = v.Section("命令行", () => "一行命令进，一行 JSON 出；成功时退出码 0。App 本身不监听任何网络端口，只接受本机当前用户的连接。"
                                               + "在 PowerShell 里调用要在路径前加 &。")
            .Value("路径", exe, mono: true, button: ("拷贝", () => Clipboard.SetText(exe)));
        foreach (var (cmd, what) in new[]
        {
            ("away", "进入离开模式（App 没运行时会先拉起）"),
            ("hide", "撤掉遮罩；离开模式下先锁屏再撤"),
            ("status", "查询状态，输出一行 JSON"),
            ("preview", "显示预览遮罩"),
            ("settings", "打开这个窗口"),
        })
            section.Command($"--send {cmd}", what);
    }

    void BuildPermissions(PageView v)
    {
        var installed = ElevatedTask.IsInstalled();
        v.Section("以最高权限运行", () => "以管理员身份运行的窗口在前台时，普通权限的 LockCurtain 看不到发给它的按键：按键会先落进那个窗口，"
                                       + "约 0.2 秒后才发现并锁屏。用 install.ps1 安装后，登录时以最高权限启动，能直接拦住这些按键。"
                                       + "安装和卸载各要管理员确认一次。")
            .Value("install.ps1", installed ? "已安装" : "未安装")
            .Value("当前实例", ElevatedTask.IsElevated() ? "以管理员身份运行" : "普通权限");
        v.Section("诊断")
            .Button("打开日志文件夹", Log.OpenDir);
    }
}
