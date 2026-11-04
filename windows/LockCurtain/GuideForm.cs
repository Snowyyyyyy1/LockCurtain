// GuideForm.cs —— 「开始用 LockCurtain」（Colo N1，copy §16.4）
//
// 第一次打开时弹一次；以后从 设置 › 通用 › 关于 ›「再看一遍开始指南」找回来。Windows 没有权限那一行，只有两行：
//   配对手机：没配上是空心圆圈 +「配对手机…」+「手机上先装 LockCurtain。」；配上了是绿勾 +「已配上 iPhone · 11 月 4 日配上」，没有按钮
//   图标在哪儿：只是说明，不打勾，左边是个图标；Windows 11 新的托盘图标默认收在 ^ 里，配一张代码画的示意小图（copy v15.1 §17.4）
// 底部一颗「好了」。窗口和设置窗口一样跟着系统深浅色（PageView 画）。

using System.Drawing;
using System.Drawing.Drawing2D;
using LockCurtain.Phone;
using Microsoft.Win32;

namespace LockCurtain;

internal sealed class GuideForm : Form
{
    const int LogicalWidth = 480, LogicalHeight = 420;   // LogicalHeight 只是建页之前的初始值

    readonly PhoneLink phone;
    readonly Action showPairing;
    readonly Theme theme = Theme.Current();
    readonly PageView page;
    readonly Panel bar = new() { Dock = DockStyle.Bottom };
    readonly Button done;
    readonly Font doneFont;
    readonly List<Bitmap> images = new();
    string signature = "";

    public GuideForm(PhoneLink phone, Action showPairing)
    {
        this.phone = phone;
        this.showPairing = showPairing;
        Text = "开始用 LockCurtain";
        try { Icon = Icon.ExtractAssociatedIcon(Environment.ProcessPath!); } catch (Exception) { }
        AutoScaleMode = AutoScaleMode.None;
        StartPosition = FormStartPosition.CenterScreen;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = MinimizeBox = false;
        BackColor = theme.Page;
        page = new PageView(theme) { Dock = DockStyle.Fill };
        bar.BackColor = theme.Page;
        done = page.MakeButton("好了", Close, prominent: true);
        // 页面的字体每次重建都换新的，按钮栏用自己的
        done.Font = doneFont = PageView.UiFont(14, FontStyle.Regular, DeviceDpi);
        bar.Controls.Add(done);
        bar.Layout += (_, _) => ArrangeBar();
        AcceptButton = done;
        Controls.Add(page);
        Controls.Add(bar);
        ClientSize = new Size(S(LogicalWidth), S(LogicalHeight));
        Rebuild();

        phone.PhonesChanged += Rebuild;
    }

    int S(int logical) => LogicalToDeviceUnits(logical);

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        Native.UseDarkTitleBar(Handle, theme.Dark);
    }

    protected override void OnFormClosed(FormClosedEventArgs e)
    {
        phone.PhonesChanged -= Rebuild;
        foreach (var b in images) b.Dispose();
        doneFont.Dispose();
        Icon?.Dispose();
        base.OnFormClosed(e);
    }

    void ArrangeBar()
    {
        bar.Height = S(56);
        var size = PageView.Measure(done, S);
        done.SetBounds(bar.Width - S(24) - size.Width, (bar.Height - size.Height) / 2 - S(4), size.Width, size.Height);
    }

    /// 状态变了才重建（重建会丢掉焦点和悬停）
    void Rebuild()
    {
        if (IsDisposed) return;
        var phones = phone.Phones;
        var next = string.Join("|", phones.Select(p => $"{p.ID}:{p.Name}:{p.PairedAt}")) + $"|{DeviceDpi}";
        if (next == signature) return;
        signature = next;
        foreach (var b in images) b.Dispose();
        images.Clear();
        page.Build("开始用 LockCurtain", v =>
        {
            var list = v.Section();
            if (phones.Count == 0)
                list.Item(Circle(v, false), "配对手机", "手机上先装 LockCurtain。",
                          controls: v.MakeButton("配对手机…", showPairing));
            else
                // 配上了：一台一行「已配上 iPhone · 11 月 4 日配上」，日期次要颜色（和 设置 › 手机 一样），没有按钮
                foreach (var p in phones)
                    list.Add(new PageView.Row { Icon = Circle(v, true), Title = "已配上 " + p.Name,
                                                TitleNote = UiText.PhoneTitleParts(p.Name, p.PairedAt).Note });
            // 不算要做完的事：不打勾，左边是个次要颜色的图标
            var where = PageView.GlyphBitmap("\uE7F4", v.S(24), v.Theme.Secondary);     // TVMonitor
            images.Add(where);
            list.Item(where, "图标在哪儿", "LockCurtain 住在右下角，可能收在 ^ 里。想让它一直看得见，把它拖到任务栏上。");
            list.Wide(new TaskbarSketch(v.Theme));
        });
        // 窗口高度跟内容走（配没配上手机行数不一样），不留一大块空白；屏幕放不下才滚
        var work = Screen.FromControl(this).WorkingArea.Height - S(80);
        ClientSize = new Size(S(LogicalWidth), Math.Min(page.ContentHeight + S(56), work));
    }

    /// 左边的圆圈：没做完是空心，做完是绿底白勾
    Bitmap Circle(PageView v, bool checkedOff)
    {
        var size = v.S(24);
        var bmp = new Bitmap(size, size);
        using (var g = Graphics.FromImage(bmp))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            var r = new RectangleF(size * 0.1f, size * 0.1f, size * 0.8f, size * 0.8f);
            if (checkedOff)
            {
                using var fill = new SolidBrush(v.ConnectedDot);
                g.FillEllipse(fill, r);
                using var tick = new Pen(Color.White, size * 0.09f) { StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round };
                g.DrawLines(tick, [new PointF(size * 0.32f, size * 0.52f), new PointF(size * 0.45f, size * 0.65f), new PointF(size * 0.69f, size * 0.38f)]);
            }
            else
            {
                using var ring = new Pen(v.Theme.Secondary, size * 0.07f);
                g.DrawEllipse(ring, r);
            }
        }
        images.Add(bmp);
        return bmp;
    }
}

/// 示意小图（220×80）：任务栏右下角一段，^ 弹出的小框里是 LockCurtain 的图标，箭头指向任务栏上它该待的地方
internal sealed class TaskbarSketch : Control, IWideRow
{
    const int SketchWidth = 220, SketchHeight = 80;
    readonly Theme theme;

    public TaskbarSketch(Theme theme)
    {
        this.theme = theme;
        BackColor = theme.Card;
        AccessibleName = "LockCurtain 住在右下角，可能收在 ^ 里。想让它一直看得见，把它拖到任务栏上。";
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer, true);
    }

    int S(int logical) => LogicalToDeviceUnits(logical);

    public int Arrange(int width, Func<int, int> s) => s(SketchHeight);

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.Clear(theme.Card);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        var ox = (Width - S(SketchWidth)) / 2f;
        RectangleF R(float x, float y, float w, float h) => new(ox + S((int)x), S((int)y), S((int)w), S((int)h));
        var ink = theme.Text;
        var faint = Theme.Mix(theme.Text, theme.Card, 12);
        var line = Theme.Mix(theme.Text, theme.Card, 35);

        // 任务栏（底下一条）
        using (var strip = new SolidBrush(faint)) g.FillRectangle(strip, R(0, 52, 220, 28));
        // ^（溢出按钮）和右边几个系统图标、时钟
        using var glyphFont = new Font(PageView.IconFontFamily, S(11), FontStyle.Regular, GraphicsUnit.Pixel);
        using var inkBrush = new SolidBrush(ink);
        using var center = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
        g.DrawString("\uE70E", glyphFont, inkBrush, R(96, 56, 20, 20), center);     // ChevronUp
        using (var dim = new SolidBrush(line))
        {
            g.FillEllipse(dim, R(150, 62, 8, 8));
            g.FillEllipse(dim, R(164, 62, 8, 8));
            g.FillRectangle(dim, R(180, 61, 30, 4));
            g.FillRectangle(dim, R(184, 68, 22, 3));
        }
        // ^ 弹出的小框，里面是 LockCurtain
        var popup = R(80, 6, 52, 40);
        using (var card = new SolidBrush(theme.Page))
        using (var border = new Pen(line))
            PageView.FillRounded(g, card, border, Rectangle.Round(popup), S(5));
        var iconBox = R(96, 16, 20, 20);
        var state = g.Save();
        g.TranslateTransform(iconBox.X + S(2), iconBox.Y + S(2));
        TrayApp.DrawMac(g, inkBrush, S(16) / 16f, locked: false);
        g.Restore(state);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        // 箭头：从小框拖到任务栏上 ^ 左边的空位
        using var arrow = new Pen(theme.Accent, S(2)) { CustomEndCap = new AdjustableArrowCap(4, 4), DashStyle = DashStyle.Dash };
        g.DrawBezier(arrow, new PointF(popup.Left - S(2), popup.Top + popup.Height / 2), new PointF(ox + S(50), S(26)),
                     new PointF(ox + S(54), S(46)), new PointF(ox + S(64), S(62)));
        using var slot = new Pen(theme.Accent, S(1)) { DashStyle = DashStyle.Dot };
        g.DrawRectangle(slot, Rectangle.Round(R(62, 56, 20, 20)));
    }
}
