// TrayFlyout.cs —— 左键点托盘图标弹出的浮窗；右键是系统原生菜单（TrayApp.ShowMenu）
//
// 照 Ledge Windows 版的 Native/TrayFlyout.cpp 做：Win11 浮窗的中性色和尺寸，GDI 画字，
// 圆角交给 DWM。深浅色跟「应用」的设置（AppsUseLightTheme）走，和右键菜单一致。
// 浮窗对准托盘图标、离任务栏 12 像素；失去焦点或按 Esc 关闭，方向键 / Tab 移动，回车 / 空格执行。
// Ledge 用 Shell_NotifyIconGetRect 拿图标位置，NotifyIcon 不公开这个，这里用点击时的鼠标位置。

using System.Drawing.Drawing2D;
using Microsoft.Win32;

namespace LockCurtain;

/// 托盘里的一个命令，浮窗和右键菜单共用一份
internal sealed record TrayCommand(string Label, Action Run, bool Enabled = true, bool SeparatorBefore = false);

internal sealed class TrayFlyout : Form
{
    // 96 DPI 下的尺寸，和 Ledge 一样。行高是下限，系统字号调大时跟着长
    const int LogicalWidth = 340, Inset = 12, HoverInset = 4, Corner = 4, Gap = 8,
              ActionHeight = 32, SeparatorHeight = 9, TaskbarGap = 12;

    const TextFormatFlags LineFlags = TextFormatFlags.SingleLine | TextFormatFlags.VerticalCenter
                                    | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix | TextFormatFlags.NoPadding;
    const TextFormatFlags WrapFlags = TextFormatFlags.WordBreak | TextFormatFlags.NoPrefix | TextFormatFlags.NoPadding;

    /// Win11 Fluent 的中性色。悬停、按下的底色从文字色混出来，跟着深浅色走
    readonly record struct Palette(Color Background, Color Text, Color Secondary, Color Disabled, Color Separator);
    static readonly Palette Light = new(Color.FromArgb(249, 249, 249), Color.FromArgb(27, 27, 27),
        Color.FromArgb(96, 96, 96), Color.FromArgb(160, 160, 160), Color.FromArgb(229, 229, 229));
    static readonly Palette Dark = new(Color.FromArgb(44, 44, 44), Color.FromArgb(255, 255, 255),
        Color.FromArgb(206, 206, 206), Color.FromArgb(120, 120, 120), Color.FromArgb(64, 64, 64));

    readonly string headline, detail;
    readonly IReadOnlyList<TrayCommand> commands;
    readonly bool dark;
    readonly Palette palette;
    readonly int dpi;
    readonly Font body, strong;
    readonly int strongLine;
    readonly Rectangle header;
    readonly List<Rectangle> separators = new();
    readonly Rectangle[] rows;
    int hot = -1;
    bool pressed, closing;

    public TrayFlyout(string headline, string detail, IReadOnlyList<TrayCommand> commands, Point anchor)
    {
        this.headline = headline;
        this.detail = detail;
        this.commands = commands;
        dark = AppsUseDarkTheme();
        palette = dark ? Dark : Light;
        var monitor = Native.MonitorFromPoint(anchor, Native.MONITOR_DEFAULTTONEAREST);
        dpi = Native.GetDpiForMonitor(monitor, Native.MDT_EFFECTIVE_DPI, out var dpiX, out _) == 0 ? (int)dpiX : 96;

        // 系统的消息字体，按这块屏的 DPI 换成像素，跟着「文本大小」设置走
        var system = SystemFonts.MessageBoxFont ?? DefaultFont;
        body = new Font(system.FontFamily, system.SizeInPoints * dpi / 72f, FontStyle.Regular, GraphicsUnit.Pixel);
        strong = new Font(system.FontFamily, body.Size, FontStyle.Bold, GraphicsUnit.Pixel);

        // 布局：标题和状态 → 分隔线 → 各项命令，SeparatorBefore 的项上面再加一条分隔线
        int width = S(LogicalWidth), inset = S(Inset), textWidth = width - inset * 2;
        strongLine = LineHeight(strong);
        var detailHeight = detail.Length == 0 ? 0
            : TextRenderer.MeasureText(detail, body, new Size(textWidth, int.MaxValue), WrapFlags).Height;
        header = new Rectangle(inset, S(Gap), textWidth, strongLine + detailHeight);
        var y = header.Bottom + S(Gap);
        AddSeparator(ref y, width);
        var actionHeight = Math.Max(S(ActionHeight), LineHeight(body) + S(Gap) * 2);
        rows = new Rectangle[commands.Count];
        for (var i = 0; i < commands.Count; i++)
        {
            if (commands[i].SeparatorBefore) AddSeparator(ref y, width);
            rows[i] = new Rectangle(S(HoverInset), y, width - S(HoverInset) * 2, actionHeight);
            y += actionHeight;
        }
        y += S(HoverInset);

        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        TopMost = true;
        StartPosition = FormStartPosition.Manual;
        AutoScaleMode = AutoScaleMode.None;
        DoubleBuffered = true;
        BackColor = palette.Background;
        Text = headline;
        Bounds = new Rectangle(Place(anchor, new Size(width, y), S(TaskbarGap)), new Size(width, y));
    }

    /// 「应用」用深色。和 Ledge 一样读 AppsUseLightTheme；托盘图标的颜色另看任务栏的 SystemUsesLightTheme
    public static bool AppsUseDarkTheme() =>
        Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize",
                          "AppsUseLightTheme", 1) is int v && v == 0;

    int S(int logical) => (int)Math.Round(logical * dpi / 96.0);

    static int LineHeight(Font font) =>
        TextRenderer.MeasureText(" ", font, Size.Empty, TextFormatFlags.SingleLine | TextFormatFlags.NoPadding).Height;

    void AddSeparator(ref int y, int width)
    {
        separators.Add(new Rectangle(S(HoverInset), y + S(SeparatorHeight) / 2, width - S(HoverInset) * 2, 1));
        y += S(SeparatorHeight);
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
        // 图标收在「隐藏的图标」弹窗里时锚点落在工作区内。浮窗放在锚点上方，放不下再放下方，
        // 别盖住鼠标：盖住的话，双击图标的第二下会点到浮窗里的命令
        else y = anchor.Y - size.Height - gap >= work.Top + gap
            ? anchor.Y - size.Height - gap
            : Clamp(anchor.Y + gap, work.Top + gap, work.Bottom - size.Height - gap);
        return new Point(x, y);
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
        int round = Native.DWMWCP_ROUND, darkMode = dark ? 1 : 0;
        Native.DwmSetWindowAttribute(Handle, Native.DWMWA_WINDOW_CORNER_PREFERENCE, ref round, sizeof(int));
        Native.DwmSetWindowAttribute(Handle, Native.DWMWA_USE_IMMERSIVE_DARK_MODE, ref darkMode, sizeof(int));
    }

    protected override void OnDeactivate(EventArgs e)
    {
        base.OnDeactivate(e);
        CloseOnce();
    }

    protected override void OnFormClosed(FormClosedEventArgs e)
    {
        body.Dispose();
        strong.Dispose();
        base.OnFormClosed(e);
    }

    /// 选中一项和失去焦点都会关窗，关窗本身又会触发失去焦点，只关一次
    void CloseOnce()
    {
        if (closing) return;
        closing = true;
        Close();
    }

    void Run(int index)
    {
        if (index < 0 || !commands[index].Enabled) return;
        CloseOnce();    // 先关浮窗：命令可能马上铺开置顶的遮罩
        commands[index].Run();
    }

    int HitTest(Point p)
    {
        for (var i = 0; i < rows.Length; i++)
            if (rows[i].Contains(p)) return commands[i].Enabled ? i : -1;
        return -1;
    }

    void SetHot(int index)
    {
        if (hot == index) return;
        hot = index;
        Invalidate();
    }

    /// 从 from 往 step 方向找下一个能点的项，到头绕回来
    int NextEnabled(int from, int step)
    {
        for (var i = 1; i <= rows.Length; i++)
        {
            var index = ((from + step * i) % rows.Length + rows.Length) % rows.Length;
            if (commands[index].Enabled) return index;
        }
        return -1;
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        SetHot(HitTest(e.Location));
    }

    protected override void OnMouseLeave(EventArgs e)
    {
        base.OnMouseLeave(e);
        pressed = false;
        SetHot(-1);
    }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        base.OnMouseDown(e);
        if (e.Button != MouseButtons.Left) return;
        pressed = true;
        SetHot(HitTest(e.Location));
        Invalidate();
    }

    protected override void OnMouseUp(MouseEventArgs e)
    {
        base.OnMouseUp(e);
        if (e.Button != MouseButtons.Left) return;
        var wasPressed = pressed;
        pressed = false;
        Invalidate();
        // 按下和松开在同一项上才算点了它
        var hit = HitTest(e.Location);
        if (wasPressed && hit >= 0 && hit == hot) Run(hit);
    }

    protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
    {
        switch (keyData)
        {
            case Keys.Escape: CloseOnce(); return true;
            case Keys.Down or Keys.Tab: SetHot(NextEnabled(hot, 1)); return true;
            case Keys.Up or (Keys.Shift | Keys.Tab): SetHot(NextEnabled(hot < 0 ? 0 : hot, -1)); return true;
            case Keys.Enter or Keys.Space: Run(hot); return true;
        }
        return base.ProcessCmdKey(ref msg, keyData);
    }

    protected override void OnPaintBackground(PaintEventArgs e) { }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.Clear(palette.Background);
        TextRenderer.DrawText(g, headline, strong, new Rectangle(header.X, header.Y, header.Width, strongLine),
                              palette.Text, LineFlags);
        if (detail.Length > 0)
            TextRenderer.DrawText(g, detail, body,
                                  Rectangle.FromLTRB(header.Left, header.Top + strongLine, header.Right, header.Bottom),
                                  palette.Secondary, WrapFlags);

        using (var line = new SolidBrush(palette.Separator))
            foreach (var r in separators) g.FillRectangle(line, r);

        for (var i = 0; i < rows.Length; i++)
        {
            if (i == hot)
            {
                using var fill = new SolidBrush(Mix(palette.Text, palette.Background, pressed ? 9 : 6));
                FillRounded(g, fill, rows[i], S(Corner));
            }
            var text = Rectangle.Inflate(rows[i], -(S(Inset) - S(HoverInset)), 0);
            TextRenderer.DrawText(g, commands[i].Label, body, text,
                                  commands[i].Enabled ? palette.Text : palette.Disabled, LineFlags);
        }
    }

    static Color Mix(Color first, Color second, int percent) => Color.FromArgb(
        (first.R * percent + second.R * (100 - percent)) / 100,
        (first.G * percent + second.G * (100 - percent)) / 100,
        (first.B * percent + second.B * (100 - percent)) / 100);

    static void FillRounded(Graphics g, Brush brush, Rectangle r, int radius)
    {
        var d = radius * 2;
        using var path = new GraphicsPath();
        path.AddArc(r.Left, r.Top, d, d, 180, 90);
        path.AddArc(r.Right - d, r.Top, d, d, 270, 90);
        path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        path.AddArc(r.Left, r.Bottom - d, d, d, 90, 90);
        path.CloseFigure();
        var mode = g.SmoothingMode;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.FillPath(brush, path);
        g.SmoothingMode = mode;
    }
}
