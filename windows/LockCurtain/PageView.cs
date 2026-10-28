// PageView.cs —— 设置窗口和规则编辑器共用的页面：标题，再一组组「小标题 + 卡片 + 灰色说明」
//
// 和 Mac 版的 grouped Form、Win11 设置的卡片一个样子。字和卡片自己画（按 DPI 算像素），
// 开关、按钮、输入框是真控件，排好位置摆上去，所以键盘、讲述人照常能用。
// 一行 = 左边标题（可带一行灰色说明）+ 右边的值和控件；或者一个占满整行的控件（IWideRow）。
// 行可以带显示条件（Only），条件变了调 Arrange() 重排，不用重建控件，焦点不丢。

using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using Microsoft.Win32;

namespace LockCurtain;

/// Win11 设置的配色。强调色读系统的，读不到用默认的蓝
internal sealed record Theme(bool Dark, Color Page, Color Card, Color Border, Color Text, Color Secondary, Color Disabled, Color Accent)
{
    public static Theme Current()
    {
        var accent = Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\DWM", "AccentColor", null) is int abgr
            ? Color.FromArgb(abgr & 0xFF, (abgr >> 8) & 0xFF, (abgr >> 16) & 0xFF)
            : Color.FromArgb(0, 120, 212);
        return Application.IsDarkModeEnabled
            ? new(true, Color.FromArgb(32, 32, 32), Color.FromArgb(43, 43, 43), Color.FromArgb(29, 29, 29),
                  Color.White, Color.FromArgb(206, 206, 206), Color.FromArgb(120, 120, 120), accent)
            : new(false, Color.FromArgb(243, 243, 243), Color.FromArgb(251, 251, 251), Color.FromArgb(229, 229, 229),
                  Color.FromArgb(27, 27, 27), Color.FromArgb(96, 96, 96), Color.FromArgb(160, 160, 160), accent);
    }

    public static Color Mix(Color first, Color second, int percent) => Color.FromArgb(
        (first.R * percent + second.R * (100 - percent)) / 100,
        (first.G * percent + second.G * (100 - percent)) / 100,
        (first.B * percent + second.B * (100 - percent)) / 100);
}

/// 占满一整行的控件：给定宽度，自己排里面的东西，返回要的高度
internal interface IWideRow
{
    int Arrange(int width, Func<int, int> s);
}

internal sealed class PageView : Panel
{
    // 96 DPI 下的尺寸
    const int PageMargin = 24, TitleGap = 16, HeaderGap = 8, FooterGap = 6, SectionGap = 24,
              RowPadX = 16, RowPadY = 12, RowMinHeight = 48, ControlGap = 12, Corner = 6, IconSize = 24;
    /// 托盘面板这类小窗口：页边距、分组间距和按钮最小宽度收紧
    const int CompactMargin = 12, CompactSectionGap = 16, ButtonMinWidth = 80, CompactButtonMinWidth = 64;

    public const TextFormatFlags LineFlags = TextFormatFlags.SingleLine | TextFormatFlags.VerticalCenter
                                           | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix | TextFormatFlags.NoPadding;
    const TextFormatFlags WrapFlags = TextFormatFlags.WordBreak | TextFormatFlags.NoPrefix | TextFormatFlags.NoPadding;

    public readonly Theme Theme;
    readonly List<Group> groups = new();
    string title = "";
    Rectangle titleRect;
    Font? titleFont, headerFont, smallFont, monoFont;
    bool arranging;

    /// 正文字号，页面上的按钮、输入框也用它
    public Font BodyFont { get; private set; } = SystemFonts.DefaultFont;

    /// 页边距和分组间距收紧，给托盘面板用
    readonly bool compact;

    /// 排好后内容的总高，托盘面板按它定窗口高度
    public int ContentHeight => AutoScrollMinSize.Height;

    public PageView(Theme theme, bool compact = false)
    {
        Theme = theme;
        this.compact = compact;
        AutoScroll = true;
        BackColor = theme.Page;
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer
                 | ControlStyles.ResizeRedraw, true);
    }

    public int S(int logical) => LogicalToDeviceUnits(logical);

    /// 系统界面字体（中文系统是微软雅黑 UI），按 DPI 换成像素
    public static Font UiFont(float logicalPixels, FontStyle style, int dpi) =>
        new((SystemFonts.MessageBoxFont ?? SystemFonts.DefaultFont).FontFamily, logicalPixels * dpi / 96f, style, GraphicsUnit.Pixel);

    /// 图标字体：Win11 的 Segoe Fluent Icons，Win10 上退回 MDL2，常用图标两边是同一个码位
    public static readonly string IconFontFamily =
        FontFamily.Families.Any(f => f.Name == "Segoe Fluent Icons") ? "Segoe Fluent Icons" : "Segoe MDL2 Assets";

    static int LineHeight(Font font) =>
        TextRenderer.MeasureText(" ", font, Size.Empty, TextFormatFlags.SingleLine | TextFormatFlags.NoPadding).Height;

    static int WrappedHeight(string text, Font font, int width) =>
        TextRenderer.MeasureText(text, font, new Size(Math.Max(1, width), int.MaxValue), WrapFlags).Height;

    static int TextWidth(string text, Font font) =>
        TextRenderer.MeasureText(text, font, Size.Empty, TextFormatFlags.SingleLine | TextFormatFlags.NoPadding).Width;

    void DisposeFonts()
    {
        foreach (var f in new[] { titleFont, headerFont, smallFont, monoFont }) f?.Dispose();
        if (BodyFont != SystemFonts.DefaultFont) BodyFont.Dispose();
    }

    protected override void Dispose(bool disposing)
    {
        // 先关控件再扔字体，和 Build 里一样：控件还在用这些字体
        base.Dispose(disposing);
        if (disposing) DisposeFonts();
    }

    /// 换页、换 DPI、列表增删时重建：旧控件和字体都扔掉。keepScroll：停在原来滚到的位置
    public void Build(string pageTitle, Action<PageView> build, bool keepScroll = false)
    {
        var scroll = AutoScrollPosition;
        SuspendLayout();
        foreach (var c in Controls.Cast<Control>().ToList()) c.Dispose();
        groups.Clear();
        DisposeFonts();
        titleFont = UiFont(26, FontStyle.Bold, DeviceDpi);
        headerFont = UiFont(14, FontStyle.Bold, DeviceDpi);
        BodyFont = UiFont(14, FontStyle.Regular, DeviceDpi);
        smallFont = UiFont(12, FontStyle.Regular, DeviceDpi);
        monoFont = new Font("Consolas", 13f * DeviceDpi / 96f, FontStyle.Regular, GraphicsUnit.Pixel);
        title = pageTitle;
        AutoScrollPosition = Point.Empty;
        build(this);
        ResumeLayout();
        Arrange();
        if (keepScroll) AutoScrollPosition = new Point(-scroll.X, -scroll.Y);
    }

    public Group Section(string header = "", Func<string>? footer = null)
    {
        var g = new Group(this, header, footer);
        groups.Add(g);
        return g;
    }

    protected override void OnResize(EventArgs e)
    {
        base.OnResize(e);
        Arrange();
    }

    // 字和卡片是自己画的，滚动后整页重画
    protected override void OnScroll(ScrollEventArgs se)
    {
        base.OnScroll(se);
        Invalidate();
    }

    protected override void OnMouseWheel(MouseEventArgs e)
    {
        base.OnMouseWheel(e);
        Invalidate();
    }

    /// 排版：算出每块卡片、每一行、每段字的位置，控件挪过去。说明文字、显示条件会跟着设置变，所以设置一改就重排
    public void Arrange()
    {
        if (arranging || titleFont == null) return;
        arranging = true;
        try
        {
            // 竖滚动条出现或消失会改变可用宽度，宽度变了再排一次
            for (var pass = 0; pass < 2; pass++)
            {
                var clientWidth = ClientSize.Width;
                AutoScrollMinSize = new Size(0, ArrangeOnce());
                if (ClientSize.Width == clientWidth) break;
            }
            Invalidate();
        }
        finally { arranging = false; }
    }

    /// 排一遍，返回内容总高
    int ArrangeOnce()
    {
        var scroll = AutoScrollPosition;
        var margin = S(compact ? CompactMargin : PageMargin);
        int x = margin, width = Math.Max(S(200), ClientSize.Width - margin * 2), y = margin;
        // 规则编辑器这类对话框没有页标题
        titleRect = new Rectangle(x, y, width, title.Length == 0 ? 0 : LineHeight(titleFont!));
        if (title.Length > 0) y = titleRect.Bottom + S(TitleGap);
        foreach (var g in groups)
        {
            if (g.Header.Length > 0)
            {
                g.HeaderRect = new Rectangle(x, y, width, LineHeight(headerFont!));
                y = g.HeaderRect.Bottom + S(HeaderGap);
            }
            var top = y;
            foreach (var row in g.Rows)
            {
                row.Shown = row.When?.Invoke() ?? true;
                foreach (var c in row.AllControls) c.Visible = row.Shown;
                if (row.Shown) y += ArrangeRow(row, x, y, width, scroll, g.IsBare ? 0 : S(RowPadX));
            }
            g.CardRect = new Rectangle(x, top, width, y - top);
            g.FooterText = g.Footer?.Invoke() ?? "";
            if (g.FooterText.Length > 0)
            {
                y += S(FooterGap);
                g.FooterRect = new Rectangle(x + S(4), y, width - S(4), WrappedHeight(g.FooterText, smallFont!, width - S(4)));
                y = g.FooterRect.Bottom;
            }
            y += S(compact ? CompactSectionGap : SectionGap);
        }
        return y;
    }

    /// 控件摆上去的大小。s 把 96 DPI 下的尺寸换成像素。按钮宽度按字量：用 Button.PreferredSize 时，托盘面板重建几次后同一个按钮会变宽
    public static Size Measure(Control c, Func<int, int> s, int buttonMinWidth = ButtonMinWidth) => c switch
    {
        ToggleSwitch => new Size(s(44), s(24)),
        IconButton => new Size(s(36), s(32)),
        Button => new Size(Math.Max(s(buttonMinWidth), TextRenderer.MeasureText(c.Text, c.Font).Width + s(24)), s(32)),
        Label => c.PreferredSize,
        _ => c.Size,    // 输入框、数字框、星期按钮这类：建的时候定好宽，高度用它自己的
    };

    /// 排一行，返回行高。左边是图标、标题和说明，右边依次是值和控件；没有标题的按钮行，控件靠左
    int ArrangeRow(Row row, int x, int y, int width, Point scroll, int padX)
    {
        int innerX = x + padX, innerW = width - padX * 2, h;
        if (row.Wide is { } wide)
        {
            var wideHeight = ((IWideRow)wide).Arrange(innerW, S);
            h = Math.Max(S(RowMinHeight), wideHeight + S(RowPadY) * 2);
            wide.SetBounds(innerX, y + (h - wideHeight) / 2 + scroll.Y, innerW, wideHeight);
            row.Rect = new Rectangle(x, y, width, h);
            return h;
        }

        var sizes = row.Controls.Select(c => Measure(c, S, compact ? CompactButtonMinWidth : ButtonMinWidth)).ToList();
        var controlsW = sizes.Sum(s => s.Width) + S(ControlGap) * Math.Max(0, sizes.Count - 1);
        var controlsH = sizes.Count == 0 ? 0 : sizes.Max(s => s.Height);
        var leading = row.Title.Length == 0;
        var right = sizes.Count == 0 || leading ? 0 : controlsW + S(ControlGap);
        var titleFont = row.MonoTitle ? monoFont! : BodyFont;
        var valueFont = row.MonoValue ? monoFont! : BodyFont;
        // 值靠右，最多占掉标题之外的地方；路径这类长值在中间省略
        var valueW = row.Value == null ? 0
            : row.ValueColor != null ? TextWidth(row.Value, smallFont!) + S(BadgePadX) * 2
            : Math.Min(TextWidth(row.Value, valueFont), Math.Max(S(40), innerW - right - TextWidth(row.Title, titleFont) - S(ControlGap)));
        var iconW = row.Icon == null ? 0 : S(IconSize) + S(ControlGap);
        var textW = innerW - iconW - right - (valueW > 0 ? valueW + S(ControlGap) : 0);
        var titleH = leading ? 0 : LineHeight(titleFont);
        var detailH = row.Detail == null ? 0 : S(2) + WrappedHeight(row.Detail, smallFont!, textW);
        h = Math.Max(S(RowMinHeight), Math.Max(titleH + detailH, controlsH) + S(RowPadY) * 2);

        row.Rect = new Rectangle(x, y, width, h);
        row.TitleHeight = titleH;
        row.IconRect = new Rectangle(innerX, y + (h - S(IconSize)) / 2, S(IconSize), S(IconSize));
        row.TextRect = new Rectangle(innerX + iconW, y + (h - titleH - detailH) / 2, textW, titleH + detailH);
        row.ValueRect = new Rectangle(innerX + innerW - right - valueW, y, valueW, h);
        var cx = leading ? innerX : innerX + innerW - controlsW;
        for (var i = 0; i < row.Controls.Length; i++)
        {
            row.Controls[i].SetBounds(cx, y + (h - sizes[i].Height) / 2 + scroll.Y, sizes[i].Width, sizes[i].Height);
            cx += sizes[i].Width + S(ControlGap);
        }
        return h;
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.Clear(Theme.Page);
        if (titleFont == null) return;
        var o = AutoScrollPosition;
        Rectangle At(Rectangle r) => new(r.X + o.X, r.Y + o.Y, r.Width, r.Height);

        TextRenderer.DrawText(g, title, titleFont, At(titleRect), Theme.Text, LineFlags);
        using var cardFill = new SolidBrush(Theme.Card);
        using var border = new Pen(Theme.Border);
        using var separator = new SolidBrush(Theme.Border);
        foreach (var grp in groups)
        {
            if (grp.Header.Length > 0) TextRenderer.DrawText(g, grp.Header, headerFont, At(grp.HeaderRect), Theme.Text, LineFlags);
            if (grp.CardRect.Height > 0 && !grp.IsBare) FillRounded(g, cardFill, border, At(grp.CardRect), S(Corner));
            var first = true;
            foreach (var row in grp.Rows.Where(r => r.Shown))
            {
                if (!first && !grp.IsBare) g.FillRectangle(separator, At(new Rectangle(row.Rect.X + S(1), row.Rect.Y, row.Rect.Width - S(2), 1)));
                first = false;
                if (row.Wide != null) continue;
                if (row.Icon != null)
                {
                    g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                    g.DrawImage(row.Icon, At(row.IconRect));
                }
                var text = At(row.TextRect);
                if (row.TitleHeight > 0)
                    TextRenderer.DrawText(g, row.Title, row.MonoTitle ? monoFont : BodyFont,
                                          new Rectangle(text.X, text.Y, text.Width, row.TitleHeight), Theme.Text, LineFlags);
                if (row.Detail != null)
                    TextRenderer.DrawText(g, row.Detail, smallFont,
                                          Rectangle.FromLTRB(text.Left, text.Top + row.TitleHeight + S(2), text.Right, text.Bottom),
                                          Theme.Secondary, WrapFlags);
                if (row.Value != null && row.ValueColor is { } badge)
                    DrawBadge(g, row.Value, badge, At(row.ValueRect));
                else if (row.Value != null)
                    TextRenderer.DrawText(g, row.Value, row.MonoValue ? monoFont : BodyFont, At(row.ValueRect), Theme.Secondary,
                                          (LineFlags & ~TextFormatFlags.EndEllipsis) | TextFormatFlags.Right
                                          | (row.MonoValue ? TextFormatFlags.PathEllipsis : TextFormatFlags.EndEllipsis));
            }
            if (grp.FooterText.Length > 0)
                TextRenderer.DrawText(g, grp.FooterText, smallFont, At(grp.FooterRect), Theme.Secondary, WrapFlags);
        }
    }

    const int BadgePadX = 8;

    /// 值画成一个带底色的小胶囊（Mac 版 KindBadge）：底色是 color 调淡，字是 color 往正文色靠一点，深浅色下都看得清
    void DrawBadge(Graphics g, string text, Color color, Rectangle valueRect)
    {
        var h = LineHeight(smallFont!) + S(4);
        var r = new Rectangle(valueRect.X, valueRect.Y + (valueRect.Height - h) / 2, valueRect.Width, h);
        using (var fill = new SolidBrush(Color.FromArgb(Theme.Dark ? 64 : 36, color)))
            FillRounded(g, fill, null, r, h / 2);
        TextRenderer.DrawText(g, text, smallFont, r, Theme.Mix(color, Theme.Text, 70),
                              (LineFlags & ~TextFormatFlags.EndEllipsis) | TextFormatFlags.HorizontalCenter);
    }

    public static void FillRounded(Graphics g, Brush? fill, Pen? border, Rectangle r, int radius)
    {
        var d = Math.Max(1, radius * 2);
        using var path = new GraphicsPath();
        path.AddArc(r.Left, r.Top, d, d, 180, 90);
        path.AddArc(r.Right - d - 1, r.Top, d, d, 270, 90);
        path.AddArc(r.Right - d - 1, r.Bottom - d - 1, d, d, 0, 90);
        path.AddArc(r.Left, r.Bottom - d - 1, d, d, 90, 90);
        path.CloseFigure();
        var mode = g.SmoothingMode;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        if (fill != null) g.FillPath(fill, path);
        if (border != null) g.DrawPath(border, path);
        g.SmoothingMode = mode;
    }

    /// prominent：强调色底、白字，一页里最主要的那个操作（Mac 的 borderedProminent）
    public Button MakeButton(string label, Action run, bool prominent = false)
    {
        var b = new Button { Text = label, Font = BodyFont, UseVisualStyleBackColor = true, AutoSize = false };
        if (prominent)
        {
            b.FlatStyle = FlatStyle.Flat;
            b.UseVisualStyleBackColor = false;
            b.BackColor = Theme.Accent;
            b.ForeColor = Color.White;
            b.FlatAppearance.BorderSize = 0;
            b.FlatAppearance.MouseOverBackColor = Theme.Mix(Theme.Accent, Color.White, 90);
            b.FlatAppearance.MouseDownBackColor = Theme.Mix(Theme.Accent, Color.Black, 85);
        }
        b.Click += (_, _) => run();
        return b;
    }

    // MARK: - 行和分组

    internal sealed class Row
    {
        public string Title = "";
        public string? Detail, Value;
        public bool MonoTitle, MonoValue;
        /// 靠右排，最后一个在最右；没有标题时靠左排
        public Control[] Controls = Array.Empty<Control>();
        /// 占满整行的控件（实现 IWideRow），有它时上面几项不用
        public Control? Wide;
        /// 返回 false 时这一行不显示
        public Func<bool>? When;
        /// 标题左边的图标（托盘面板里的程序图标），画成 24 见方
        public Image? Icon;
        /// 有它时值画成这个颜色的小胶囊
        public Color? ValueColor;
        public bool Shown = true;
        public int TitleHeight;
        public Rectangle Rect, TextRect, ValueRect, IconRect;

        public IEnumerable<Control> AllControls => Wide == null ? Controls : Controls.Append(Wide);
    }

    internal sealed class Group(PageView view, string header, Func<string>? footer)
    {
        public readonly string Header = header;
        public readonly Func<string>? Footer = footer;
        public readonly List<Row> Rows = new();
        public string FooterText = "";
        public Rectangle HeaderRect, CardRect, FooterRect;
        public bool IsBare;
        Func<bool>? when;

        public Group Add(Row row)
        {
            row.When ??= when;
            Rows.Add(row);
            foreach (var c in row.AllControls) view.Controls.Add(c);
            return this;
        }

        /// add 里加的行只在 condition 成立时显示
        public Group Only(Func<bool> condition, Action<Group> add)
        {
            var outer = when;
            when = outer == null ? condition : () => outer() && condition();
            add(this);
            when = outer;
            return this;
        }

        /// 开关：改完再读一遍实际状态（写注册表可能失败），说明和显示条件可能跟着变，重排
        public Group Toggle(string title, Func<bool> get, Action<bool> set, bool enabled = true, string? detail = null)
        {
            var toggle = view.MakeToggle(title, get, set);
            toggle.Enabled = enabled;
            return Add(new Row { Title = title, Detail = detail, Controls = new Control[] { toggle } });
        }

        public Group Value(string title, string value, bool mono = false, (string Label, Action Run)? button = null)
        {
            var controls = button is { } b ? new Control[] { view.MakeButton(b.Label, b.Run) } : Array.Empty<Control>();
            return Add(new Row { Title = title, Value = value, MonoValue = mono, Controls = controls });
        }

        /// 等宽字的标题加一行说明，比如命令行的各个命令
        public Group Command(string command, string what) =>
            Add(new Row { Title = command, MonoTitle = true, Detail = what });

        public Group Text(string title, string? detail = null) => Add(new Row { Title = title, Detail = detail });

        public Group Button(string label, Action run) => Add(new Row { Controls = new Control[] { view.MakeButton(label, run) } });

        public Group Controls(string title, string? detail, params Control[] controls) =>
            Add(new Row { Title = title, Detail = detail, Controls = controls });

        public Group Wide(Control control) => Add(new Row { Wide = control });

        /// 带图标的一行，值可以画成彩色小胶囊（valueColor）
        public Group Item(Image? icon, string title, string? detail, string? value = null, Color? valueColor = null,
                          params Control[] controls) =>
            Add(new Row { Icon = icon, Title = title, Detail = detail, Value = value, ValueColor = valueColor, Controls = controls });

        /// 不画卡片和分隔线，行也不往里缩：一排按钮直接放在页面上
        public Group Bare()
        {
            IsBare = true;
            return this;
        }

        public Group Tiles(IEnumerable<Tile> tiles)
        {
            var grid = new TileGrid { BackColor = view.Theme.Card };
            grid.Controls.AddRange(tiles.ToArray());
            return Wide(grid);
        }
    }

    public ToggleSwitch MakeToggle(string name, Func<bool> get, Action<bool> set)
    {
        var toggle = new ToggleSwitch(Theme) { Checked = get(), AccessibleName = name };
        toggle.CheckedChanged += (_, _) =>
        {
            if (toggle.Checked == get()) return;
            set(toggle.Checked);
            toggle.Checked = get();
            Arrange();
        };
        return toggle;
    }
}

/// 缩略图的格子：一行放得下几个放几个
internal sealed class TileGrid : Panel, IWideRow
{
    public int Arrange(int width, Func<int, int> s)
    {
        if (Controls.Count == 0) return 0;
        var size = ((Tile)Controls[0]).LogicalSize;
        int tileW = s(size.Width), tileH = s(size.Height), gap = s(12);
        var perRow = Math.Max(1, (width + gap) / (tileW + gap));
        for (var i = 0; i < Controls.Count; i++)
            Controls[i].SetBounds(i % perRow * (tileW + gap), i / perRow * (tileH + gap), tileW, tileH);
        var rows = (Controls.Count + perRow - 1) / perRow;
        return Math.Max(0, rows * tileH + (rows - 1) * gap);
    }
}

/// Win11 的拨动开关。底下还是 CheckBox，键盘（空格）、讲述人照常能用
internal sealed class ToggleSwitch : CheckBox
{
    readonly Theme theme;

    public ToggleSwitch(Theme theme)
    {
        this.theme = theme;
        AutoSize = false;
        Text = "";
        Cursor = Cursors.Hand;
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer, true);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.Clear(theme.Card);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        var inset = LogicalToDeviceUnits(2);
        var pill = new RectangleF(inset + 0.5f, inset + 0.5f, Width - inset * 2 - 1, Height - inset * 2 - 1);
        using var path = Pill(pill);
        var on = Checked;
        var color = !Enabled ? theme.Disabled : on ? theme.Accent : theme.Secondary;
        if (on)
        {
            using var fill = new SolidBrush(color);
            g.FillPath(fill, path);
        }
        else
        {
            using var pen = new Pen(color, LogicalToDeviceUnits(1));
            g.DrawPath(pen, path);
        }
        var knob = pill.Height * 0.6f;
        var margin = (pill.Height - knob) / 2;
        var knobX = on ? pill.Right - margin - knob : pill.Left + margin;
        using (var brush = new SolidBrush(on ? (theme.Dark ? Color.Black : Color.White) : color))
            g.FillEllipse(brush, knobX, pill.Top + margin, knob, knob);
        if (Focused && ShowFocusCues)
        {
            using var focus = new Pen(theme.Text, LogicalToDeviceUnits(1)) { DashStyle = DashStyle.Dot };
            g.DrawRectangle(focus, 0, 0, Width - 1, Height - 1);
        }
    }

    static GraphicsPath Pill(RectangleF r)
    {
        var path = new GraphicsPath();
        path.AddArc(r.Left, r.Top, r.Height, r.Height, 90, 180);
        path.AddArc(r.Right - r.Height, r.Top, r.Height, r.Height, 270, 180);
        path.CloseFigure();
        return path;
    }
}

/// 设置页的缩略图格子（遮罩图案、遮罩背景）：上面一块图，下面一行标题；选中时画强调色圈，键盘焦点画虚线框。
/// 底下是 RadioButton：同一组里只能选一个，方向键能换选
internal abstract class Tile : RadioButton
{
    protected readonly Theme theme;
    readonly string title;
    /// 第一次画时按当时的 DPI 建；换 DPI 时整页的缩略图会重建
    Font? caption;

    protected Tile(string title, Theme theme)
    {
        this.title = title;
        this.theme = theme;
        AutoSize = false;
        Text = "";
        AccessibleName = title;
        Cursor = Cursors.Hand;
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer, true);
    }

    /// 一格的宽、高（96 DPI 下），TileGrid 按它排
    public abstract Size LogicalSize { get; }

    /// 选中时存进设置
    protected abstract void Save();

    protected override void OnCheckedChanged(EventArgs e)
    {
        // 先存再发 CheckedChanged：设置页靠这个事件重排「自定义图片」那几行，要读到新图案。
        // 关设置窗口时 DestroyWindow 会把焦点还给先前拿过焦点的格子，RadioButton 一拿到焦点就勾上自己（OnEnter → OnClick）：
        // 那不是用户选的，不存
        if (Checked && TopLevelControl is not { Disposing: true }) Save();
        base.OnCheckedChanged(e);
        Invalidate();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) caption?.Dispose();
        base.Dispose(disposing);
    }

    protected int S(int logical) => LogicalToDeviceUnits(logical);

    /// 选中圈画在 ring 这个圆角框的内侧；焦点框围住整块图（tile），标题在图下面
    protected void PaintChrome(Graphics g, Rectangle tile, Rectangle ring, int radius, float ringWidth)
    {
        if (Checked)
        {
            using var pen = new Pen(theme.Accent, ringWidth) { Alignment = PenAlignment.Inset };
            PageView.FillRounded(g, null, pen, ring, radius);
        }
        if (Focused && ShowFocusCues)
        {
            using var focus = new Pen(theme.Text, 1) { DashStyle = DashStyle.Dot };
            g.DrawRectangle(focus, 0, 0, Width - 1, tile.Height - 1);
        }
        caption ??= PageView.UiFont(12, FontStyle.Regular, DeviceDpi);
        TextRenderer.DrawText(g, title, caption, Rectangle.FromLTRB(0, tile.Bottom + S(4), Width, Height), theme.Text,
                              PageView.LineFlags | TextFormatFlags.HorizontalCenter);
    }
}

/// 图案缩略图：深色底上画一份，选中的那个在动（和 Mac 版 ArtTile 一样）
internal sealed class ArtTile : Tile
{
    public const int LogicalWidth = 96, LogicalHeight = 118, ArtSide = 76;
    static readonly Color TileBack = Color.FromArgb(26, 28, 43);

    readonly CurtainArt art;
    public CurtainArt Art => art;
    readonly System.Windows.Forms.Timer frameTimer = new() { Interval = 33 };
    readonly bool animate = !Native.SystemParametersInfoW(Native.SPI_GETCLIENTAREAANIMATION, 0, out int on, 0) || on != 0;
    bool artFailureLogged;

    public ArtTile(CurtainArt art, Theme theme) : base(art.Title(), theme)
    {
        this.art = art;
        frameTimer.Tick += (_, _) => Invalidate();
    }

    public override Size LogicalSize => new(LogicalWidth, LogicalHeight);

    protected override void Save()
    {
        if (Settings.Current.CurtainArt != art) Settings.Update(s => s.CurtainArt = art);
    }

    protected override void OnCheckedChanged(EventArgs e)
    {
        base.OnCheckedChanged(e);
        UpdateTimer();
    }

    protected override void OnVisibleChanged(EventArgs e)
    {
        base.OnVisibleChanged(e);
        UpdateTimer();
    }

    void UpdateTimer() => frameTimer.Enabled = Checked && Visible && animate && art.Draw() != null;

    protected override void Dispose(bool disposing)
    {
        if (disposing) frameTimer.Dispose();
        base.Dispose(disposing);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.Clear(theme.Card);
        var tile = new Rectangle(0, 0, Width, S(LogicalWidth));
        using (var back = new SolidBrush(TileBack))
            PageView.FillRounded(g, back, null, Rectangle.Inflate(tile, -S(2), -S(2)), S(10));

        // 和遮罩上一样，自定义图片比动画图案小一点
        var side = S(ArtSide) * art.Size() / CurtainArt.MechEye.Size();
        var draw = art == CurtainArt.Custom ? (cg, cs, ct, _) => CustomArt.Draw(cg, cs, ct) : art.Draw();
        if (draw == null)
        {
            // 对应 Mac 的 SF Symbol circle.slash
            var d = S(22);
            var c = new Rectangle((Width - d) / 2, (tile.Height - d) / 2, d, d);
            using var pen = new Pen(Color.FromArgb(115, 255, 255, 255), S(2));
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.DrawEllipse(pen, c);
            g.DrawLine(pen, c.Left + d * 0.15f, c.Bottom - d * 0.15f, c.Right - d * 0.15f, c.Top + d * 0.15f);
        }
        else
        {
            // 没选中的缩略图停在一帧
            var t = frameTimer.Enabled ? CurtainArts.Now : art.StillTime(CurtainArts.Now);
            var state = g.Save();
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.TranslateTransform((Width - side) / 2f, (tile.Height - side) / 2f);
            // 缩略图不盯光标，传 null
            try { draw(g, side, t, null); }
            catch (ExternalException ex)
            {
                if (!artFailureLogged) Log.Write($"缩略图 {art} t={t:F3} 画失败，跳过这一帧: {ex.Message}");
                artFailureLogged = true;
            }
            g.Restore(state);
        }

        PaintChrome(g, tile, Rectangle.Inflate(tile, -S(1), -S(1)), S(10), S(2));
    }
}

/// 遮罩背景的缩略图：屏幕比例的小图，叠上和遮罩一样的压暗（对应 Mac 版 BackgroundTile）
internal sealed class BackgroundTile : Tile
{
    public const int LogicalWidth = 96, ImageHeight = 60, LogicalHeight = 82;

    /// 后台画好之前是 null
    Bitmap? thumbnail;
    Font? glyph;

    public CurtainBackground Background { get; }

    public BackgroundTile(CurtainBackground background, Theme theme) : base(background.Title(), theme) => Background = background;

    public override Size LogicalSize => new(LogicalWidth, LogicalHeight);

    protected override void Save()
    {
        if (Settings.Current.CurtainBackground != Background) Settings.Update(s => s.CurtainBackground = Background);
    }

    /// 缩略图在后台画好后调用；控件已经关了就把图扔掉
    public void SetThumbnail(Bitmap image)
    {
        if (IsDisposed)
        {
            image.Dispose();
            return;
        }
        thumbnail?.Dispose();
        thumbnail = image;
        Invalidate();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            thumbnail?.Dispose();
            glyph?.Dispose();
        }
        base.Dispose(disposing);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.Clear(theme.Card);
        var tile = new Rectangle(0, 0, Width, S(ImageHeight));
        var radius = S(8);
        PageView.FillRounded(g, Brushes.Black, null, tile, radius);
        if (thumbnail != null)
        {
            // 等比铺满，多出的裁掉；用贴图画刷填圆角框，圆角边缘有抗锯齿
            var scale = Math.Max((float)tile.Width / thumbnail.Width, (float)tile.Height / thumbnail.Height);
            using var brush = new TextureBrush(thumbnail, WrapMode.Clamp);
            brush.TranslateTransform((tile.Width - thumbnail.Width * scale) / 2, (tile.Height - thumbnail.Height * scale) / 2);
            brush.ScaleTransform(scale, scale);
            PageView.FillRounded(g, brush, null, tile, radius);
            if (Background.Dim() > 0)
                using (var dim = new SolidBrush(Color.FromArgb((int)Math.Round(Background.Dim() * 255), 0, 0, 0)))
                    PageView.FillRounded(g, dim, null, tile, radius);
        }
        else if (Background.UsesWallpaper())
        {
            // 壁纸还没读到：对应 Mac 的 SF Symbol photo
            glyph ??= new Font(PageView.IconFontFamily, S(18), FontStyle.Regular, GraphicsUnit.Pixel);
            TextRenderer.DrawText(g, "\uE91B", glyph, tile, Color.FromArgb(115, 255, 255, 255),
                                  TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
        }
        // 选中圈 2.5 点宽，和 Mac 的 strokeBorder 一样
        PaintChrome(g, tile, tile, radius, S(5) / 2f);
    }
}
