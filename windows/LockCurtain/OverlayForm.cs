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
// 画面从下到上：壁纸（等比铺满）→ 黑色 28% → 机械眼 → 两行文案。
// 尺寸照搬 Mac 版的 pt，乘以这块屏的缩放比例（DPI / 96）。

using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;
using System.Runtime.InteropServices;
using System.Text;

namespace LockCurtain;

internal sealed class OverlayForm : Form
{
    const float EyeSize = 160, EyeOffsetY = -88;
    const string Title = "LockCurtain is Using Your PC";
    const string Subtitle = "Press any key or click to unlock";

    readonly bool stealth;
    readonly bool animate;
    readonly long startTimestamp = Stopwatch.GetTimestamp();
    readonly System.Windows.Forms.Timer frameTimer = new() { Interval = 33 };   // 30 帧，和 Mac 版一样
    Image? wallpaper;
    bool wallpaperResolved;
    Bitmap? background;
    bool artFailureLogged;

    /// 排除捕获设置成功了没有
    public bool Stealthed { get; private set; }

    public OverlayForm(Screen screen, bool stealth)
    {
        this.stealth = stealth;
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        AutoScaleMode = AutoScaleMode.None;
        BackColor = Color.Black;
        Bounds = screen.Bounds;
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer, true);
        // 系统关了「动画效果」时停在一帧
        animate = !Native.SystemParametersInfoW(Native.SPI_GETCLIENTAREAANIMATION, 0, out int on, 0) || on != 0;
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
        background?.Dispose();
        base.OnFormClosed(e);
    }

    /// 壁纸异步读完后调用；null 表示纯色桌面
    public void SetWallpaper(Image? image)
    {
        wallpaper = image;
        wallpaperResolved = true;
        background?.Dispose();
        background = null;
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
            if (Native.DwmGetWindowAttribute(h, Native.DWMWA_CLOAKED, out var cloaked, sizeof(int)) == 0 && cloaked != 0) continue;
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
        var side = EyeSize * DpiScale;
        var c = new PointF(ClientSize.Width / 2f, ClientSize.Height / 2f + EyeOffsetY * DpiScale);
        return new RectangleF(c.X - side / 2, c.Y - side / 2, side, side);
    }

    protected override void OnPaintBackground(PaintEventArgs e) { }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        background ??= BuildBackground();
        g.DrawImage(background, e.ClipRectangle, e.ClipRectangle, GraphicsUnit.Pixel);

        var eye = EyeRect();
        if (!eye.IntersectsWith(e.ClipRectangle)) return;
        var t = animate ? Stopwatch.GetElapsedTime(startTimestamp).TotalSeconds : 0;
        var state = g.Save();
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TranslateTransform(eye.X, eye.Y);
        // OnPaint 抛一次异常，WinForms 就把整个窗口标成出错、以后不再绘制，遮罩只剩一片黑。
        // 眼睛只是装饰：画不出来就跳过这一帧，记一次日志（新图案先用 Tools/EyePreview 逐帧检查）
        try { MechEye.Draw(g, eye.Width, t); }
        catch (ExternalException ex)
        {
            if (!artFailureLogged) Log.Write($"机械眼 t={t:F3} 画失败，跳过这一帧: {ex.Message}");
            artFailureLogged = true;
        }
        g.Restore(state);
    }

    /// 不动的部分（壁纸、压暗、文案）画一次存起来，每帧只重画眼睛那一块
    Bitmap BuildBackground()
    {
        int w = Math.Max(1, ClientSize.Width), h = Math.Max(1, ClientSize.Height);
        var bmp = new Bitmap(w, h, PixelFormat.Format32bppPArgb);
        using var g = Graphics.FromImage(bmp);
        // 壁纸还没读完时是黑底，读完发现是纯色桌面就用桌面背景色
        g.Clear(wallpaperResolved && wallpaper == null ? Wallpaper.DesktopColor() : Color.Black);
        if (wallpaper != null)
        {
            var s = Math.Max((float)w / wallpaper.Width, (float)h / wallpaper.Height);
            float dw = wallpaper.Width * s, dh = wallpaper.Height * s;
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            g.DrawImage(wallpaper, (w - dw) / 2, (h - dh) / 2, dw, dh);
        }
        using (var dim = new SolidBrush(Color.FromArgb(71, 0, 0, 0)))   // 黑色 alpha 0.28
            g.FillRectangle(dim, 0, 0, w, h);
        DrawText(g, w, h);
        return bmp;
    }

    /// 两行居中，行高 18 / 14，间距 15，整组中心在屏幕中心往下 33.5
    void DrawText(Graphics g, int w, int h)
    {
        var s = DpiScale;
        g.TextRenderingHint = TextRenderingHint.AntiAlias;
        using var brush = new SolidBrush(Color.FromArgb(128, 255, 255, 255));
        using var format = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
        using var titleFont = new Font("Segoe UI Semibold", 15 * s, FontStyle.Regular, GraphicsUnit.Pixel);
        using var subFont = new Font("Segoe UI Semibold", 12 * s, FontStyle.Regular, GraphicsUnit.Pixel);
        var top = h / 2f + 33.5f * s - (18 + 15 + 14) * s / 2;
        g.DrawString(Title, titleFont, brush, new RectangleF(0, top, w, 18 * s), format);
        g.DrawString(Subtitle, subFont, brush, new RectangleF(0, top + 33 * s, w, 14 * s), format);
    }
}
