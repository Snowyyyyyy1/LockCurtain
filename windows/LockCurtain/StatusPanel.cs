// StatusPanel.cs —— 左键点托盘图标弹出的面板（对应 Mac 版 StatusPanel.swift）；右键还是系统原生菜单（NativeMenu）
//
// 从上到下：一排按钮（进入离开模式、预览遮罩、设置）；「阻止睡眠」卡片：保持唤醒，加上现在谁在阻止睡眠；
// 「过去 24 小时」卡片：什么时候睡着了（Windows 只做睡眠和唤醒，见 SleepHistory.cs）。
// 面板开着时每 2 秒在后台读一次 powercfg /requests，有变化才重排。读不到（没有管理员权限）时在卡片下面说明。
// 卡片和行用设置窗口的 PageView 画，跟着系统深浅色走。位置贴着任务栏、对准图标，失去焦点或按 Esc 关闭，
// 圆角交给 DWM（和 Ledge Windows 版的浮窗一样）。NotifyIcon 不公开图标位置，用点击时的鼠标位置。

using System.Diagnostics;
using System.Drawing;

namespace LockCurtain;

internal sealed class StatusPanel : Form
{
    const int LogicalWidth = 380, TaskbarGap = 12, RefreshMs = 2000;
    static readonly Color DisplayBadge = Color.FromArgb(0, 122, 255), SystemBadge = Color.FromArgb(242, 166, 30);

    readonly Point anchor;
    readonly bool idle;
    readonly Action enterAway, preview, openSettings;
    readonly KeepAwake keepAwake;
    readonly PageView page;
    readonly System.Windows.Forms.Timer refresh = new() { Interval = RefreshMs };
    SleepBlockerSnapshot? blockers;
    readonly (List<Span>? Sleeps, string? Error) history;
    string signature = "";
    bool closing, loading;
    /// 「到指定时间…」的选择框开着，和里面选的时刻（当天零点起的分钟）
    bool picking;
    int pickMinute;
    Bitmap? cup;

    public StatusPanel(Point anchor, bool idle, SleepBlockerSnapshot? blockers, (List<Span>? Sleeps, string? Error) history,
                       KeepAwake keepAwake, Action enterAway, Action preview, Action openSettings)
    {
        this.anchor = anchor;
        this.idle = idle;
        this.blockers = blockers;
        this.history = history;
        this.keepAwake = keepAwake;
        this.enterAway = enterAway;
        this.preview = preview;
        this.openSettings = openSettings;

        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        TopMost = true;
        StartPosition = FormStartPosition.Manual;
        AutoScaleMode = AutoScaleMode.None;
        Text = "LockCurtain";
        var theme = Theme.Current();
        BackColor = theme.Page;
        // 先在锚点那块屏上建窗口，DeviceDpi 才是那块屏的，再按它排版
        Location = anchor;
        _ = Handle;
        page = new PageView(theme, compact: true) { Dock = DockStyle.Fill };
        Controls.Add(page);
        Rebuild();

        keepAwake.Changed += OnKeepAwakeChanged;
        refresh.Tick += async (_, _) => await Reload();
        refresh.Start();
    }

    protected override CreateParams CreateParams
    {
        get
        {
            var cp = base.CreateParams;
            cp.ExStyle |= Native.WS_EX_TOOLWINDOW;   // 不进 Alt+Tab
            return cp;
        }
    }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        // Win11 上圆角；更早的系统不认这两个属性，保持直角
        int round = Native.DWMWCP_ROUND;
        Native.DwmSetWindowAttribute(Handle, Native.DWMWA_WINDOW_CORNER_PREFERENCE, ref round, sizeof(int));
        Native.UseDarkTitleBar(Handle, Application.IsDarkModeEnabled);
    }

    protected override void OnDeactivate(EventArgs e)
    {
        base.OnDeactivate(e);
        CloseOnce();
    }

    protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
    {
        if (keyData == Keys.Escape)
        {
            CloseOnce();
            return true;
        }
        return base.ProcessCmdKey(ref msg, keyData);
    }

    protected override void OnFormClosed(FormClosedEventArgs e)
    {
        keepAwake.Changed -= OnKeepAwakeChanged;
        refresh.Dispose();
        cup?.Dispose();
        base.OnFormClosed(e);
    }

    /// 点按钮和失去焦点都会关窗，关窗本身又会触发失去焦点，只关一次
    void CloseOnce()
    {
        if (closing) return;
        closing = true;
        Close();
    }

    /// 顶上那排按钮：先关面板再执行，命令可能马上铺开置顶的遮罩
    void Run(Action action)
    {
        CloseOnce();
        action();
    }

    void OnKeepAwakeChanged()
    {
        picking = false;
        Rebuild();
    }

    async Task Reload()
    {
        if (loading || closing) return;
        loading = true;
        try { blockers = await Task.Run(SleepBlockers.Snapshot); }
        finally { loading = false; }
        if (!closing) Rebuild();
    }

    /// 内容没变就不动（重建会丢掉焦点和悬停）；变了重排，窗口高度跟着内容
    void Rebuild()
    {
        var rows = Rows();
        var next = string.Join("\n", rows.Select(r => $"{r.Display}|{r.Title}|{r.Reason}"))
                   + $"\n{blockers?.SystemCount}|{blockers == null}|{keepAwake.Mode}|{KeepAwakeDetail()}|{picking}";
        if (next == signature) return;
        signature = next;

        var width = LogicalToDeviceUnits(LogicalWidth);
        ClientSize = new Size(width, ClientSize.Height);
        page.Build("", v => Build(v, rows), keepScroll: true);
        var work = Screen.FromPoint(anchor).WorkingArea;
        var gap = LogicalToDeviceUnits(TaskbarGap);
        var size = new Size(width, Math.Min(page.ContentHeight, work.Height - gap * 2));
        Bounds = new Rectangle(Place(anchor, size, gap), size);
    }

    /// 一个程序的一种阻止（显示器 / 系统）合成一行，同一程序的多条原因拼起来
    sealed record BlockerRow(bool Display, string Path, string Title, string Reason);

    List<BlockerRow> Rows()
    {
        if (blockers == null) return new();
        return blockers.Programs
            .GroupBy(b => (b.Display, Path: ProcessInfo.DosPath(b.Path)))
            .Select(g => new BlockerRow(g.Key.Display, g.Key.Path, ProcessInfo.Title(g.Key.Path),
                                        string.Join("；", g.Select(b => b.Reason).Where(r => r.Length > 0).Distinct())))
            .OrderBy(r => r.Display ? 0 : 1).ThenBy(r => r.Title, StringComparer.CurrentCultureIgnoreCase)
            .ToList();
    }

    void Build(PageView v, List<BlockerRow> rows)
    {
        var away = v.MakeButton("进入离开模式", () => Run(enterAway), prominent: true);
        var look = v.MakeButton("预览遮罩", () => Run(preview));
        away.Enabled = look.Enabled = idle;
        var gear = new IconButton("\uE713", "设置…") { Font = v.BodyFont };   // Segoe Fluent Icons 的齿轮
        gear.Click += (_, _) => Run(openSettings);
        v.Section().Bare().Controls("", null, away, look, gear);

        var card = v.Section("阻止睡眠", Footer);
        var icon = v.S(24);
        if (keepAwake.Mode != null)
        {
            // exe 没有自己的图标，用托盘上保持唤醒时那只杯子
            cup ??= TrayApp.CupImage(icon, v.Theme.Text);
            card.Item(cup, "LockCurtain 保持唤醒", KeepAwakeDetail(), controls: v.MakeButton("停止", keepAwake.Stop));
        }
        else if (picking)
        {
            var picker = RuleEditor.TimePicker(v, pickMinute, "保持唤醒到");
            picker.Width = v.S(80);     // 面板窄，规则页的 90 会把「保持唤醒到」挤没
            picker.ValueChanged += (_, _) => pickMinute = picker.Minute;
            card.Controls("保持唤醒到", null, picker,
                          v.MakeButton("取消", () => { picking = false; Rebuild(); }),
                          v.MakeButton("开始", StartPicked, prominent: true));
        }
        else
        {
            Button? start = null;
            start = v.MakeButton("开始", () => ShowKeepAwakeMenu(start!));
            card.Controls("保持唤醒", "不盖遮罩，只让电脑不睡；屏幕照样会熄灭", start);
        }

        foreach (var r in rows)
            card.Item(ProcessInfo.Icon(r.Path, icon), r.Title, r.Reason.Length > 0 ? r.Reason : null,
                      r.Display ? "显示器" : "系统", r.Display ? DisplayBadge : SystemBadge);
        if (rows.Count == 0 && blockers != null) card.Text("没有程序在阻止睡眠。");

        var past = v.Section("过去 24 小时");
        if (history.Sleeps is { } sleeps) past.Wide(new SleepBar(v.Theme, sleeps, DateTime.UtcNow));
        else past.Text("读不到系统日志", history.Error);
    }

    string Footer()
    {
        if (blockers == null)
            return ElevatedTask.IsElevated()
                ? "读不到电源请求（powercfg /requests 出错），详情见日志。"
                : "要以最高权限运行（用 install.ps1 安装）才看得到谁在阻止睡眠。";
        return blockers.SystemCount > 0 ? $"另有 {blockers.SystemCount} 个系统服务或驱动也在阻止睡眠。" : "";
    }

    string KeepAwakeDetail() => keepAwake.Mode switch
    {
        KeepAwakeMode.Forever => "直到你点停止；屏幕照样会熄灭",
        KeepAwakeMode.Until u => $"到{(u.EndUtc.ToLocalTime().Date == DateTime.Today ? "" : "明天 ")}{u.EndUtc.ToLocalTime():HH:mm}，还剩 {Duration(u.EndUtc - DateTime.UtcNow)}",
        KeepAwakeMode.WhileRunning w => $"{w.Name} 退出就结束",
        _ => "",
    };

    /// 不到 1 分 / N 分 / N 小时 / N 小时 M 分（和 Mac 版一样）
    public static string Duration(TimeSpan span)
    {
        var minutes = (int)Math.Floor(span.TotalMinutes);
        if (minutes < 1) return "不到 1 分";
        if (minutes < 60) return $"{minutes} 分";
        return minutes % 60 == 0 ? $"{minutes / 60} 小时" : $"{minutes / 60} 小时 {minutes % 60} 分";
    }

    void ShowKeepAwakeMenu(Button from)
    {
        TrayCommand For(string label, TimeSpan span) =>
            new(label, () => keepAwake.Start(new KeepAwakeMode.Until(DateTime.UtcNow + span)));
        NativeMenu.Show(Handle, from.PointToScreen(new Point(0, from.Height)), new List<TrayCommand>
        {
            new("一直", () => keepAwake.Start(new KeepAwakeMode.Forever())),
            For("1 小时", TimeSpan.FromHours(1)),
            For("2 小时", TimeSpan.FromHours(2)),
            For("5 小时", TimeSpan.FromHours(5)),
            new("到指定时间…", () =>
            {
                // 默认停在至少一小时后的整点
                var at = DateTime.Now.AddHours(1);
                pickMinute = (at.Minute == 0 && at.Second == 0 ? at.Hour : at.Hour + 1) % 24 * 60;
                picking = true;
                Rebuild();
            }),
            new("某个程序开着时", () => { }, SeparatorBefore: true, Submenu: RunningApps()),
        });
    }

    /// 任务栏上有窗口的程序（不含自己），按显示名排；它退出就结束保持唤醒
    List<TrayCommand> RunningApps()
    {
        var apps = new SortedDictionary<string, TrayCommand>(StringComparer.CurrentCultureIgnoreCase);
        foreach (var pid in ProcessInfo.WithWindows())
        {
            if (pid == Environment.ProcessId || ProcessInfo.PathOf(pid) is not { } path) continue;
            var title = ProcessInfo.Title(pid, path);
            if (apps.ContainsKey(title)) continue;
            Process p;
            try { p = Process.GetProcessById(pid); }
            catch (ArgumentException) { continue; }     // 刚退出
            using (p)
                if (KeepAwake.Bind(p, title) is { } bound) apps[title] = new TrayCommand(title, () => keepAwake.Start(bound));
        }
        return apps.Count > 0 ? apps.Values.ToList() : new() { new("现在没有", () => { }, Enabled: false) };
    }

    /// 选的时刻下一次到来的时候；已经过了就是明天
    void StartPicked()
    {
        var end = DateTime.Today.AddMinutes(pickMinute);
        if (end <= DateTime.Now) end = end.AddDays(1);
        keepAwake.Start(new KeepAwakeMode.Until(end.ToUniversalTime()));
    }

    /// 贴着任务栏、对准图标，离任务栏和屏幕边缘都留 gap
    static Point Place(Point anchor, Size size, int gap)
    {
        var work = Screen.FromPoint(anchor).WorkingArea;
        static int Clamp(int v, int low, int high) => high < low ? low : Math.Clamp(v, low, high);
        var x = Clamp(anchor.X - size.Width / 2, work.Left + gap, work.Right - size.Width - gap);
        var y = Clamp(anchor.Y - size.Height / 2, work.Top + gap, work.Bottom - size.Height - gap);
        if (anchor.Y >= work.Bottom) y = work.Bottom - size.Height - gap;
        else if (anchor.Y < work.Top) y = work.Top + gap;
        else if (anchor.X >= work.Right) x = work.Right - size.Width - gap;
        else if (anchor.X < work.Left) x = work.Left + gap;
        // 图标收在「隐藏的图标」弹窗里时锚点落在工作区内。面板放在锚点上方，放不下再放下方，
        // 别盖住鼠标：盖住的话，双击图标的第二下会点到面板里的按钮
        else y = anchor.Y - size.Height - gap >= work.Top + gap
            ? anchor.Y - size.Height - gap
            : Clamp(anchor.Y + gap, work.Top + gap, work.Bottom - size.Height - gap);
        return new Point(x, y);
    }
}

/// 过去 24 小时的睡眠条（对应 Mac 版「过去 24 小时」卡片的那根条）：条下面是时间刻度，再下面是图例和时长
internal sealed class SleepBar : Control, IWideRow
{
    static readonly Color Asleep = Color.FromArgb(94, 92, 230);    // Mac 的 systemIndigo

    readonly Theme theme;
    readonly List<Span> sleeps;
    readonly DateTime now;
    Font? small;
    int lineHeight;

    public SleepBar(Theme theme, List<Span> sleeps, DateTime now)
    {
        this.theme = theme;
        this.sleeps = sleeps;
        this.now = now;
        BackColor = theme.Card;
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer, true);
    }

    int S(int logical) => LogicalToDeviceUnits(logical);
    Color Track => Theme.Mix(theme.Text, theme.Card, 14);

    public int Arrange(int width, Func<int, int> s)
    {
        small ??= PageView.UiFont(12, FontStyle.Regular, DeviceDpi);
        lineHeight = TextRenderer.MeasureText(" ", small, Size.Empty, TextFormatFlags.SingleLine | TextFormatFlags.NoPadding).Height;
        return s(12) + s(4) + lineHeight + s(10) + lineHeight;
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) small?.Dispose();
        base.Dispose(disposing);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.Clear(theme.Card);
        if (small == null) return;
        var bar = new Rectangle(0, 0, Width, S(12));
        using (var track = new SolidBrush(Track)) PageView.FillRounded(g, track, null, bar, S(3));
        var from = now - SleepHistory.Window;
        using (var clip = new System.Drawing.Drawing2D.GraphicsPath())
        using (var fill = new SolidBrush(Asleep))
        {
            // 两头的圆角里也要裁掉睡眠的颜色
            var d = S(3) * 2;
            clip.AddArc(bar.Left, bar.Top, d, d, 180, 90);
            clip.AddArc(bar.Right - d, bar.Top, d, d, 270, 90);
            clip.AddArc(bar.Right - d, bar.Bottom - d, d, d, 0, 90);
            clip.AddArc(bar.Left, bar.Bottom - d, d, d, 90, 90);
            clip.CloseFigure();
            var state = g.Save();
            g.SetClip(clip);
            foreach (var s in sleeps)
            {
                float x0 = X(s.Start), x1 = Math.Max(X(s.End), x0 + 1);    // 太短的也至少留一条线
                g.FillRectangle(fill, x0, bar.Top, x1 - x0, bar.Height);
            }
            g.Restore(state);
        }

        var labels = new Rectangle(0, bar.Bottom + S(4), Width, lineHeight);
        const TextFormatFlags Line = TextFormatFlags.SingleLine | TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix;
        TextRenderer.DrawText(g, "24 小时前", small, labels, theme.Secondary, Line);
        TextRenderer.DrawText(g, "12 小时前", small, labels, theme.Secondary, Line | TextFormatFlags.HorizontalCenter);
        TextRenderer.DrawText(g, "现在", small, labels, theme.Secondary, Line | TextFormatFlags.Right);

        var asleep = SleepHistory.Total(sleeps);
        var x = 0;
        var y = labels.Bottom + S(10);
        foreach (var (color, text) in new[] { (Asleep, $"睡眠 {StatusPanel.Duration(asleep)}"),
                                              (Track, $"醒着 {StatusPanel.Duration(SleepHistory.Window - asleep)}") })
        {
            var dot = S(8);
            using (var b = new SolidBrush(color))
            {
                g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
                g.FillEllipse(b, x, y + (lineHeight - dot) / 2f, dot, dot);
            }
            x += dot + S(6);
            TextRenderer.DrawText(g, text, small, new Point(x, y), theme.Text, Line);
            x += TextRenderer.MeasureText(text, small, Size.Empty, Line).Width + S(18);
        }

        float X(DateTime t) => (float)(Width * Math.Clamp((t - from) / SleepHistory.Window, 0, 1));
    }
}

/// 只有一个图标字的方按钮（Mac 版面板右上角的齿轮），鼠标悬停显示说明
internal sealed class IconButton : Button
{
    readonly ToolTip tip = new();
    Font? glyphFont;

    public IconButton(string glyph, string name)
    {
        Text = glyph;
        AccessibleName = name;
        UseVisualStyleBackColor = true;
        tip.SetToolTip(this, name);
    }

    protected override void OnFontChanged(EventArgs e)
    {
        base.OnFontChanged(e);
        var family = PageView.IconFontFamily;
        if (base.Font.Name == family) return;
        var old = glyphFont;
        base.Font = glyphFont = new Font(family, base.Font.Size, FontStyle.Regular, GraphicsUnit.Pixel);
        old?.Dispose();
    }

    protected override void Dispose(bool disposing)
    {
        base.Dispose(disposing);
        if (disposing)
        {
            tip.Dispose();
            glyphFont?.Dispose();
        }
    }
}
