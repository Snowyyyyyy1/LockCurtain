// RulesPage.cs —— 设置窗口的「规则」页和规则编辑器（对应 Mac 版 RulesPane.swift）
//
// 规则页：每条规则一行（名字、摘要、编辑、开关），底下「新建规则…」。
// 编辑器是模态对话框，改的是规则的副本：点「添加 / 保存」才写回 RuleStore，「取消」什么也不改。
// 条件打开时才显示它的细项（行的显示条件，见 PageView.Only）；进程名列表增删时整页重建，焦点放回输入框。
// 和 Mac 版的差别：Windows 没有 bundle ID，列表里填进程名（.exe 可省略）；
// 「有程序在阻止睡眠」要以最高权限运行才读得到（见 SleepBlockers.cs）。

using System.Diagnostics;
using System.Drawing;

namespace LockCurtain;

internal static class RulesPage
{
    public const string Title = "规则";

    public static void Build(PageView v, RuleStore store, IWin32Window owner)
    {
        var list = v.Section("自动进入离开模式", () =>
            "一条规则里开着的条件全部满足时，进入离开模式，并且只在「刚满足」的那一刻触发一次：你回来撤掉遮罩后，"
            + "要等条件先不成立、再次成立，才会再触发。锁屏期间不触发。");
        if (store.Rules.Count == 0) list.Text("还没有规则。");
        foreach (var rule in store.Rules)
        {
            var name = rule.Name.Trim().Length == 0 ? "未命名规则" : rule.Name;
            var toggle = v.MakeToggle(name, () => rule.Enabled, on =>
            {
                rule.Enabled = on;
                store.Save();
            });
            list.Controls(name, rule.Summary(), v.MakeButton("编辑", () => Edit(v, store, owner, rule)), toggle);
        }
        v.Section().Button("新建规则…", () => Edit(v, store, owner, new CurtainRule { Name = "离开 10 分钟", IdleMinutes = 10 }));
    }

    static void Edit(PageView v, RuleStore store, IWin32Window owner, CurtainRule rule)
    {
        var index = store.Rules.IndexOf(rule);
        using var editor = new RuleEditor(rule.Clone(), isNew: index < 0, v.Theme);
        switch (editor.ShowDialog(owner))
        {
            case DialogResult.OK when index < 0: store.Rules.Add(editor.Rule); break;
            case DialogResult.OK: store.Rules[index] = editor.Rule; break;
            case DialogResult.Abort when index >= 0: store.Rules.RemoveAt(index); break;    // 删除规则
            default: return;
        }
        store.Save();
        // 点的按钮还在处理 Click，等它返回再重建这一页
        v.BeginInvoke(() => v.Build(Title, p => Build(p, store, owner), keepScroll: true));
    }
}

internal sealed class RuleEditor : Form
{
    readonly bool isNew;
    readonly PageView page;
    readonly Panel bar = new() { Dock = DockStyle.Bottom };
    readonly Button save, cancel, delete;
    /// 重建后要把焦点放回去的输入框名字
    string? focusAfterBuild;

    public CurtainRule Rule { get; }

    public RuleEditor(CurtainRule rule, bool isNew, Theme theme)
    {
        Rule = rule;
        this.isNew = isNew;
        Text = isNew ? "新建规则" : "编辑规则";
        AutoScaleMode = AutoScaleMode.None;
        StartPosition = FormStartPosition.CenterParent;
        MinimizeBox = MaximizeBox = false;
        ShowInTaskbar = false;
        BackColor = theme.Page;
        page = new PageView(theme) { Dock = DockStyle.Fill };
        bar.BackColor = theme.Card;
        save = new Button { Text = isNew ? "添加" : "保存", DialogResult = DialogResult.OK, UseVisualStyleBackColor = true };
        cancel = new Button { Text = "取消", DialogResult = DialogResult.Cancel, UseVisualStyleBackColor = true };
        delete = new Button { Text = "删除规则", DialogResult = DialogResult.Abort, UseVisualStyleBackColor = true, Visible = !isNew };
        bar.Controls.AddRange(new Control[] { delete, cancel, save });
        bar.Layout += (_, _) => ArrangeBar();
        AcceptButton = save;
        CancelButton = cancel;
        Controls.Add(page);
        Controls.Add(bar);
        ClientSize = new Size(S(520), S(600));
        MinimumSize = SizeFromClientSize(new Size(S(440), S(400)));
        Rebuild();
    }

    int S(int logical) => LogicalToDeviceUnits(logical);

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        Native.UseDarkTitleBar(Handle, page.Theme.Dark);
    }

    protected override void OnDpiChanged(DpiChangedEventArgs e)
    {
        base.OnDpiChanged(e);
        Rebuild(keepScroll: true);
    }

    void ArrangeBar()
    {
        bar.Height = S(64);
        var size = (Control b) => PageView.Measure(b, S);
        int pad = S(16), y = (bar.Height - size(save).Height) / 2;
        var x = bar.ClientSize.Width - pad;
        foreach (var b in new[] { save, cancel })
        {
            x -= size(b).Width;
            b.SetBounds(x, y, size(b).Width, size(b).Height);
            x -= S(8);
        }
        delete.SetBounds(pad, y, size(delete).Width, size(delete).Height);
    }

    void Rebuild(bool keepScroll = false)
    {
        page.Build("", BuildPage, keepScroll);
        foreach (Control b in bar.Controls) b.Font = page.BodyFont;     // 旧字体随页面重建释放了
        save.Enabled = Rule.Name.Trim().Length > 0;
        bar.PerformLayout();
        if (focusAfterBuild != null && page.Controls.Find(focusAfterBuild, searchAllChildren: true).FirstOrDefault() is { } box)
            box.Focus();
        focusAfterBuild = null;
    }

    /// 列表增删、改 DPI 时整页重建。在按钮的 Click 里调用，等它返回再建
    void RebuildLater(string? focus)
    {
        focusAfterBuild = focus;
        BeginInvoke(() => Rebuild(keepScroll: true));
    }

    void BuildPage(PageView v)
    {
        var rule = Rule;
        var name = new TextBox { Text = rule.Name, PlaceholderText = "名称", Font = v.BodyFont, AccessibleName = "名称" };
        name.TextChanged += (_, _) =>
        {
            rule.Name = name.Text;
            save.Enabled = rule.Name.Trim().Length > 0;
        };
        v.Section().Wide(new HStack(name) { BackColor = v.Theme.Card, Controls = { name } });

        var conditions = v.Section("以下条件全部满足时进入离开模式",
                                   () => rule.HasConditions ? "" : "至少打开一个条件，否则这条规则不会触发。");

        // 空闲
        var idle = new NumericUpDown { Minimum = 1, Maximum = 240, Value = rule.IdleMinutes ?? 10, Width = v.S(80), Font = v.BodyFont,
                                       AccessibleName = "分钟数" };
        idle.ValueChanged += (_, _) => { if (rule.IdleMinutes != null) rule.IdleMinutes = (int)idle.Value; };
        conditions
            .Toggle("空闲一段时间", () => rule.IdleMinutes != null, on => rule.IdleMinutes = on ? (int)idle.Value : null)
            .Only(() => rule.IdleMinutes != null, g => g.Controls("键盘和鼠标没动的分钟数", null, idle));

        // 进程
        conditions
            .Toggle("某个程序在运行", () => rule.Processes != null, on => rule.Processes = on ? new() : null)
            .Only(() => rule.Processes != null, g => NameList(v, g, "processes", () => rule.Processes,
                "进程名，如 claude", "运行中的程序", RunningChoices,
                "列表里任意一个在运行即满足。填进程名，.exe 可以省略；命令行工具（比如 claude）也填它的进程名。"));

        // 阻止睡眠
        var elevated = ElevatedTask.IsElevated();
        conditions
            .Toggle("有程序在阻止睡眠", () => rule.SleepBlockers != null, on => rule.SleepBlockers = on ? new() : null)
            .Only(() => rule.SleepBlockers != null, g => NameList(v, g, "blockers", () => rule.SleepBlockers,
                "进程名，如 vlc", "正在阻止睡眠的", BlockerChoices,
                ((rule.SleepBlockers?.Count ?? 0) == 0
                    ? "留空 = 任意程序在阻止睡眠即满足；系统服务、驱动和 LockCurtain 自己不算。"
                    : "列表里任意一个在阻止睡眠即满足。")
                + (elevated ? "" : "要以最高权限运行（用 install.ps1 安装）才读得到谁在阻止睡眠，现在这个条件不会满足。")));

        // 时间段
        var window = rule.TimeWindow ?? TimeWindow.Default;
        var from = TimePicker(v, window.Start, "从");
        var to = TimePicker(v, window.End, "到");
        var days = new HStack(null) { BackColor = v.Theme.Card };
        foreach (var d in new[] { 2, 3, 4, 5, 6, 7, 1 })    // 周一开头，Mac 的 weekday（1 = 周日）
            days.Controls.Add(new DayToggle(v.Theme, d, "日一二三四五六"[d - 1].ToString(), window.Weekdays.Contains(d))
                              { Font = v.BodyFont, Size = new Size(v.S(36), v.S(32)) });
        TimeWindow FromControls() => new()
        {
            Start = from.Minute,
            End = to.Minute,
            Weekdays = days.Controls.OfType<DayToggle>().Where(t => t.Checked).Select(t => t.Weekday).Order().ToList(),
        };
        void TimeChanged()
        {
            if (rule.TimeWindow == null) return;
            rule.TimeWindow = FromControls();
            v.Arrange();
        }
        from.ValueChanged += (_, _) => TimeChanged();
        to.ValueChanged += (_, _) => TimeChanged();
        foreach (var t in days.Controls.OfType<DayToggle>()) t.CheckedChanged += (_, _) => TimeChanged();
        conditions
            .Toggle("在某个时间段内", () => rule.TimeWindow != null, on => rule.TimeWindow = on ? FromControls() : null)
            .Only(() => rule.TimeWindow != null, g => g
                .Wide(new HStack(null) { BackColor = v.Theme.Card, Controls = { Caption(v, "从"), from, Caption(v, "到"), to } })
                .Wide(days)
                .Only(() => rule.TimeWindow is { } w && w.Start > w.End, h => h.Text("", "跨午夜：后半夜算开始那天。")));

        conditions.Toggle("接着电源", () => rule.RequireACPower, on => rule.RequireACPower = on);
    }

    /// 进程名列表：每项一行带「移除」，底下是输入框、「添加」和从菜单里挑。
    /// 条件关着时这几行也照样建好、只是不显示（PageView.Only），那时 list() 是 null
    void NameList(PageView v, PageView.Group g, string key, Func<List<string>?> list, string placeholder,
                  string menuTitle, Func<List<string>?> choices, string hint)
    {
        foreach (var item in list() ?? [])
            g.Controls(item, null, v.MakeButton("移除", () =>
            {
                list()?.Remove(item);
                RebuildLater(null);
            }));
        var box = new TextBox { Name = key, PlaceholderText = placeholder, Font = v.BodyFont, AccessibleName = placeholder };
        void Add(string text)
        {
            var name = text.Trim();
            if (name.Length == 0 || list() is not { } names || names.Any(n => RuleFacts.Normalize(n) == RuleFacts.Normalize(name))) return;
            names.Add(name);
            RebuildLater(key);
        }
        var add = v.MakeButton("添加", () => Add(box.Text));
        // 输入框里按回车是添加，不是保存整条规则
        box.Enter += (_, _) => AcceptButton = null;
        box.Leave += (_, _) => AcceptButton = save;
        box.KeyDown += (_, e) =>
        {
            if (e.KeyCode != Keys.Enter) return;
            e.SuppressKeyPress = true;
            Add(box.Text);
        };
        Button? menu = null;
        menu = v.MakeButton(menuTitle + " ▾", () =>
        {
            var names = choices();
            var commands = names == null ? new List<TrayCommand> { new("要以最高权限运行才读得到", () => { }, Enabled: false) }
                : names.Count == 0 ? new List<TrayCommand> { new("现在没有", () => { }, Enabled: false) }
                : names.Select(n => new TrayCommand(n, () => Add(n))).ToList();
            NativeMenu.Show(Handle, menu!.PointToScreen(new Point(0, menu.Height)), commands);
        });
        g.Wide(new HStack(box) { BackColor = v.Theme.Card, Controls = { box, add, menu } });
        g.Text("", hint);
    }

    /// 有窗口的程序（和 Mac 版「运行中的 app」一样只列前台程序），按名字排
    static List<string>? RunningChoices()
    {
        var self = Environment.ProcessId;
        var names = new SortedSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var p in Process.GetProcesses())
            using (p)
                if (p.Id != self && p.MainWindowHandle != 0) names.Add(p.ProcessName);
        return names.ToList();
    }

    static List<string>? BlockerChoices() =>
        SleepBlockers.Snapshot()?.Programs.Select(b => b.Name).Distinct().Order().ToList();

    /// 时:分 输入框，托盘面板的「保持唤醒到」也用它
    internal static TimeBox TimePicker(PageView v, int minute, string name) => new(minute)
    {
        Width = v.S(90),
        Font = v.BodyFont,
        AccessibleName = name,
    };

    static Label Caption(PageView v, string text) =>
        new() { Text = text, AutoSize = true, Font = v.BodyFont, ForeColor = v.Theme.Text, BackColor = v.Theme.Card };
}

/// 一排横着放的控件，fill 那一个吃掉剩下的宽度（没有就都按自己的宽度从左排）
internal sealed class HStack(Control? fill) : Panel, IWideRow
{
    public int Arrange(int width, Func<int, int> s)
    {
        var controls = Controls.Cast<Control>().ToList();
        if (controls.Count == 0) return 0;
        var gap = s(8);
        var sizes = controls.Select(c => PageView.Measure(c, s)).ToList();
        var fixedWidth = sizes.Where((_, i) => controls[i] != fill).Sum(z => z.Width) + gap * (controls.Count - 1);
        var height = sizes.Max(z => z.Height);
        var x = 0;
        for (var i = 0; i < controls.Count; i++)
        {
            var w = controls[i] == fill ? Math.Max(s(60), width - fixedWidth) : sizes[i].Width;
            controls[i].SetBounds(x, (height - sizes[i].Height) / 2, w, sizes[i].Height);
            x += w + gap;
        }
        return height;
    }
}

/// 星期几的切换按钮：选中是强调色底，和 Mac 版 tint 过的按钮一样
internal sealed class DayToggle : CheckBox
{
    readonly Theme theme;

    public int Weekday { get; }

    public DayToggle(Theme theme, int weekday, string label, bool on)
    {
        this.theme = theme;
        Weekday = weekday;
        Text = label;
        Checked = on;
        AutoSize = false;
        AccessibleName = "周" + label;
        Cursor = Cursors.Hand;
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer, true);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.Clear(theme.Card);
        var r = new Rectangle(0, 0, Width - 1, Height - 1);
        var radius = LogicalToDeviceUnits(4);
        if (Checked)
        {
            using var fill = new SolidBrush(theme.Accent);
            PageView.FillRounded(g, fill, null, r, radius);
        }
        else
        {
            using var border = new Pen(theme.Secondary);
            PageView.FillRounded(g, null, border, r, radius);
        }
        TextRenderer.DrawText(g, Text, Font, r, Checked ? (theme.Dark ? Color.Black : Color.White) : theme.Text,
                              TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine);
        if (Focused && ShowFocusCues) ControlPaint.DrawFocusRectangle(g, Rectangle.Inflate(r, -2, -2));
    }
}

/// 时:分 输入框，值是一天里的第几分钟。DateTimePicker 在深色主题下还是白底，这里借跟着主题走的 NumericUpDown：
/// 上下键、滚轮、右边的箭头调光标所在的那一段（冒号前是时，后面是分），到头绕回；也能直接打 7:30 或 0730
internal sealed class TimeBox : NumericUpDown
{
    const int Day = 24 * 60;

    public TimeBox(int minute)
    {
        Maximum = Day - 1;
        Value = minute;
    }

    public int Minute => (int)Value;

    TextBox Edit => Controls.OfType<TextBox>().First();

    protected override void UpdateEditText()
    {
        ChangingText = true;     // 程序改的字，不算用户输入（UserEdit）
        Text = $"{Minute / 60:00}:{Minute % 60:00}";
    }

    protected override void ValidateEditText()
    {
        UserEdit = false;        // 先清掉：UserEdit 为真时读 Value 会再进这里
        if (Parse(Text) is { } m) Value = m;
        UpdateEditText();
    }

    // NumericUpDown 只收数字，冒号会被吞掉并响一声
    protected override void OnTextBoxKeyPress(object? source, KeyPressEventArgs e)
    {
        if (e.KeyChar != ':') base.OnTextBoxKeyPress(source, e);
    }

    public override void UpButton() => Step(1);

    public override void DownButton() => Step(-1);

    void Step(int sign)
    {
        var caret = Edit.SelectionStart;
        if (UserEdit) ValidateEditText();
        Value = ((Minute + sign * (caret <= 2 ? 60 : 1)) % Day + Day) % Day;
        Edit.SelectionStart = caret;     // 改 Text 会把光标挪到开头
    }

    /// "7:30"、"07:30"、"730"、"0730"、"7"；不像时间返回 null
    static int? Parse(string text)
    {
        var parts = text.Trim().Split(':');
        int h, m = 0;
        if (parts.Length == 2) { if (!int.TryParse(parts[0], out h) || !int.TryParse(parts[1], out m)) return null; }
        else if (parts.Length == 1 && int.TryParse(parts[0], out var n)) { (h, m) = parts[0].Length > 2 ? (n / 100, n % 100) : (n, 0); }
        else return null;
        return h is >= 0 and < 24 && m is >= 0 and < 60 ? h * 60 + m : null;
    }
}
