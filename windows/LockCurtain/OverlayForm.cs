// OverlayForm.cs —— 一块屏幕上的遮罩窗口
//
// 窗口样式：
//   WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE   置顶，不进任务栏和 Alt+Tab，不抢焦点
//   WS_EX_LAYERED | WS_EX_TRANSPARENT                     鼠标穿透到下层：agent 合成的点击落到下面的窗口，
//                                                         真人的点击由 InputFilter 吞掉
//   SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)      对人可见，对屏幕捕获不可见（Windows 10 2004 起）
//
// 分层窗口要设过一次不透明度才会显示，这里设成完全不透明。
// Chromium 系浏览器被别的窗口整个挡住时会停止渲染页面，但实测（2026-10-26，Win11 25H2 ARM，Edge）
// 遮罩盖住时 Edge 照常渲染：requestAnimationFrame 不停，visibilityState 一直是 visible。
//
// 画面从下到上：背景（CurtainBackground.cs：壁纸照系统的铺法，见 Wallpaper.cs；模糊壁纸拉伸铺满；
// 程序画的图和屏一样大；纯黑什么也不画）→ 黑色压暗（壁纸 28%、模糊壁纸 35%，其余不压）→ 图案 → 两行文案。
// 尺寸照搬 Mac 版的 pt，乘以这块屏的缩放比例（DPI / 96）。

using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;
using System.Runtime.InteropServices;
using System.Text;

namespace LockCurtain;

internal sealed class OverlayForm : Form
{
    /// 标题和提示在设置里改，建窗口时读一次，下次显示遮罩时生效
    readonly string title = Settings.Current.CurtainTitle.Trim(), subtitle = Settings.Current.CurtainSubtitle.Trim();
    readonly bool stealth;
    readonly CurtainArt art;
    readonly CurtainBackground curtainBackground;
    readonly bool animate;
    readonly System.Windows.Forms.Timer frameTimer = new() { Interval = 33 };   // 30 帧，和 Mac 版一样
    /// 还没读完时是 null，先画黑底
    WallpaperInfo? wallpaper;
    /// 模糊壁纸（缩小过的）或程序画的背景，后台准备好之前是 null
    Bitmap? backgroundImage;
    /// 不动的部分画好存起来
    Bitmap? still;
    bool artFailureLogged;

    /// 排除捕获设置成功了没有
    public bool Stealthed { get; private set; }

    /// 这个窗口盖的那块屏
    public Screen Display { get; }

    public OverlayForm(Screen screen, bool stealth, CurtainArt art, CurtainBackground curtainBackground)
    {
        Display = screen;
        this.stealth = stealth;
        this.art = art;
        this.curtainBackground = curtainBackground;
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        AutoScaleMode = AutoScaleMode.None;
        BackColor = Color.Black;
        Bounds = screen.Bounds;
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer, true);
        // 系统关了「动画效果」时停在一帧；自定义图片和没有图案时不用动
        animate = art.Draw() != null
                  && (!Native.SystemParametersInfoW(Native.SPI_GETCLIENTAREAANIMATION, 0, out int on, 0) || on != 0);
        frameTimer.Tick += (_, _) => Invalidate(Rectangle.Ceiling(EyeRect()));
    }

    protected override bool ShowWithoutActivation => true;

    protected override CreateParams CreateParams
    {
        get
        {
            var cp = base.CreateParams;
            cp.ExStyle |= Native.WS_EX_TOPMOST | Native.WS_EX_TOOLWINDOW | Native.WS_EX_NOACTIVATE
                        | Native.WS_EX_LAYERED | Native.WS_EX_TRANSPARENT;
            return cp;
        }
    }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        Native.SetLayeredWindowAttributes(Handle, 0, 255, Native.LWA_ALPHA);
        if (stealth)
        {
            Stealthed = Native.SetWindowDisplayAffinity(Handle, Native.WDA_EXCLUDEFROMCAPTURE);
            if (!Stealthed) Log.Write($"SetWindowDisplayAffinity 失败 error={Marshal.GetLastWin32Error()}，遮罩会出现在截图里");
        }
    }

    protected override void OnShown(EventArgs e)
    {
        base.OnShown(e);
        if (animate) frameTimer.Start();
    }

    protected override void OnFormClosed(FormClosedEventArgs e)
    {
        frameTimer.Dispose();
        still?.Dispose();
        backgroundImage?.Dispose();
        base.OnFormClosed(e);
    }

    /// 壁纸异步读完后调用
    public void SetWallpaper(WallpaperInfo info)
    {
        wallpaper = info;
        Repaint();
    }

    /// 模糊壁纸或程序画的背景在后台准备好后调用；窗口已经关了就把图扔掉
    public void SetBackgroundImage(Bitmap image)
    {
        if (IsDisposed)
        {
            image.Dispose();
            return;
        }
        backgroundImage?.Dispose();
        backgroundImage = image;
        Repaint();
    }

    void Repaint()
    {
        still?.Dispose();
        still = null;
        Invalidate();
    }

    /// 有别的进程的可见窗口压在上面（和这块屏有重叠）就重新置顶，返回它的窗口类名
    public string? EnsureTopmost()
    {
        var me = (uint)Environment.ProcessId;
        for (var h = Native.GetWindow(Handle, Native.GW_HWNDPREV); h != 0; h = Native.GetWindow(h, Native.GW_HWNDPREV))
        {
            if (!Native.IsWindowVisible(h)) continue;
            Native.GetWindowThreadProcessId(h, out var pid);
            if (pid == me) continue;
            if (Native.IsCloaked(h)) continue;
            if (!Native.GetWindowRect(h, out var r)) continue;
            if (!Bounds.IntersectsWith(Rectangle.FromLTRB(r.Left, r.Top, r.Right, r.Bottom))) continue;

            Native.SetWindowPos(Handle, Native.HWND_TOPMOST, 0, 0, 0, 0,
                                Native.SWP_NOMOVE | Native.SWP_NOSIZE | Native.SWP_NOACTIVATE | Native.SWP_NOOWNERZORDER);
            var name = new StringBuilder(256);
            Native.GetClassNameW(h, name, name.Capacity);
            return name.ToString();
        }
        return null;
    }

    float DpiScale => DeviceDpi / 96f;

    RectangleF EyeRect()
    {
        var side = art.Size() * DpiScale;
        var c = new PointF(ClientSize.Width / 2f, ClientSize.Height / 2f + art.OffsetY() * DpiScale);
        return new RectangleF(c.X - side / 2, c.Y - side / 2, side, side);
    }

    protected override void OnPaintBackground(PaintEventArgs e) { }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        still ??= BuildStill();
        g.DrawImage(still, e.ClipRectangle, e.ClipRectangle, GraphicsUnit.Pixel);

        var eye = EyeRect();
        var draw = art == CurtainArt.Custom ? CustomArt.Draw : art.Draw();
        if (draw == null || !eye.IntersectsWith(e.ClipRectangle)) return;
        var t = animate ? CurtainArts.Now : art.StillTime(CurtainArts.Now);   // 系统关了动画效果就停在一帧
        var state = g.Save();
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TranslateTransform(eye.X, eye.Y);
        // OnPaint 抛一次异常，WinForms 就把整个窗口标成出错、以后不再绘制，遮罩只剩一片黑。
        // 图案只是装饰：画不出来就跳过这一帧，记一次日志（新图案先用 Tools/EyePreview 逐帧检查）
        try { draw(g, eye.Width, t); }
        catch (ExternalException ex)
        {
            if (!artFailureLogged) Log.Write($"{art.Title()} t={t:F3} 画失败，跳过这一帧: {ex.Message}");
            artFailureLogged = true;
        }
        g.Restore(state);
    }

    /// 不动的部分（背景、压暗、文案）画一次存起来，每帧只重画眼睛那一块
    Bitmap BuildStill()
    {
        int w = Math.Max(1, ClientSize.Width), h = Math.Max(1, ClientSize.Height);
        var bmp = new Bitmap(w, h, PixelFormat.Format32bppPArgb);
        using var g = Graphics.FromImage(bmp);
        g.Clear(Color.Black);
        if (curtainBackground == CurtainBackground.Wallpaper && wallpaper != null)
            PaintWallpaper(g, wallpaper, Display.Bounds, new Size(w, h));
        else if (backgroundImage != null)
        {
            // 程序画的图和屏一样大，原样贴上；模糊壁纸是 1/4 的小图，拉伸回整屏，边缘按镜像取样，不然四边会混进透明变暗
            g.InterpolationMode = InterpolationMode.HighQualityBilinear;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            using var edges = new ImageAttributes();
            edges.SetWrapMode(WrapMode.TileFlipXY);
            g.DrawImage(backgroundImage, new Rectangle(0, 0, w, h), 0, 0, backgroundImage.Width, backgroundImage.Height,
                        GraphicsUnit.Pixel, edges);
        }
        var dim = curtainBackground.Dim();
        if (dim > 0)
            using (var brush = new SolidBrush(Color.FromArgb((int)Math.Round(dim * 255), 0, 0, 0)))
                g.FillRectangle(brush, 0, 0, w, h);
        DrawText(g, w, h);
        return bmp;
    }

    /// 画进一张屏幕大小的新图，参数同 PaintWallpaper
    internal static Bitmap RenderWallpaper(WallpaperInfo wallpaper, Rectangle display, Size size)
    {
        var bmp = new Bitmap(Math.Max(1, size.Width), Math.Max(1, size.Height), PixelFormat.Format32bppPArgb);
        using var g = Graphics.FromImage(bmp);
        PaintWallpaper(g, wallpaper, display, size);
        return bmp;
    }

    /// 照系统的铺法画一块屏的壁纸：先铺底色（适应、居中没铺满的地方露出它，纯色桌面就只有底色），再画图。
    /// 坐标是这块屏的物理像素，图片按像素尺寸算（居中是 1:1，不跟着缩放比例放大）；display 是这块屏在桌面上的位置，跨屏铺法要用。
    /// 模糊壁纸在后台线程调用：多块屏共用缓存里的同一张图，GDI+ 的图不能两个线程同时画，所以锁住
    internal static void PaintWallpaper(Graphics g, WallpaperInfo wallpaper, Rectangle display, Size size)
    {
        g.Clear(wallpaper.Background);
        if (wallpaper.Image is not { } image) return;
        var client = new Rectangle(Point.Empty, size);
        g.InterpolationMode = InterpolationMode.HighQualityBicubic;
        g.PixelOffsetMode = PixelOffsetMode.HighQuality;
        lock (image)
            switch (wallpaper.Fit)
            {
                case WallpaperFit.Stretch:
                    g.DrawImage(image, client);
                    break;
                case WallpaperFit.Center:
                    g.DrawImage(image, (client.Width - image.Width) / 2, (client.Height - image.Height) / 2, image.Width, image.Height);
                    break;
                case WallpaperFit.Tile:
                    // 从这块屏的左上角开始铺（推断：Win8 起每块屏单独画壁纸）
                    using (var brush = new TextureBrush(image)) g.FillRectangle(brush, client);
                    break;
                case WallpaperFit.Fit:
                    DrawScaled(g, image, client, cover: false);
                    break;
                case WallpaperFit.Span:
                    // 一张图铺满所有屏的外接矩形，这块屏只画自己那一块
                    var desk = SystemInformation.VirtualScreen;
                    desk.Offset(-display.X, -display.Y);
                    DrawScaled(g, image, desk, cover: true);
                    break;
                default:
                    DrawScaled(g, image, client, cover: true);
                    break;
            }
    }

    /// 等比缩放后居中放进 area：cover 铺满（多出的裁掉），否则整张放得下
    static void DrawScaled(Graphics g, Image image, Rectangle area, bool cover)
    {
        float sx = (float)area.Width / image.Width, sy = (float)area.Height / image.Height;
        var s = cover ? Math.Max(sx, sy) : Math.Min(sx, sy);
        float dw = image.Width * s, dh = image.Height * s;
        g.DrawImage(image, area.X + (area.Width - dw) / 2, area.Y + (area.Height - dh) / 2, dw, dh);
    }

    /// 标题在上、提示在下，各自水平居中，间距 15，顶边在屏幕中心往下 10，换行只往下长、不压图案；
    /// 超过 480 宽换行，空的那行不画、也不留空位（和 Mac 版 buildText 一样）
    void DrawText(Graphics g, int w, int h)
    {
        var s = DpiScale;
        g.TextRenderingHint = TextRenderingHint.AntiAlias;
        using var brush = new SolidBrush(Color.FromArgb(128, 255, 255, 255));
        using var format = new StringFormat { Alignment = StringAlignment.Center };
        using var titleFont = new Font("Segoe UI Semibold", 15 * s, FontStyle.Regular, GraphicsUnit.Pixel);
        using var subFont = new Font("Segoe UI Semibold", 12 * s, FontStyle.Regular, GraphicsUnit.Pixel);
        float y = h / 2f + 10 * s, maxWidth = 480 * s;
        foreach (var (text, font) in new[] { (title, titleFont), (subtitle, subFont) })
        {
            if (text.Length == 0) continue;
            var height = g.MeasureString(text, font, (int)maxWidth, format).Height;
            g.DrawString(text, font, brush, new RectangleF((w - maxWidth) / 2, y, maxWidth, height), format);
            y += height + 15 * s;
        }
    }
}
