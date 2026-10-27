// TrayGlyphs.cs —— 通知区域的单色小图标，也给托盘面板用（TrayApp 的另一半）
//
// 在 16×16 的设计网格里画（y 朝下），按图标的像素尺寸放大；颜色跟着任务栏深浅色走。
// 单独一个文件，EyePreview 可以只编译这一半，把各尺寸画出来看（EyePreview.exe <输出目录> glyphs）。

using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using Microsoft.Win32;

namespace LockCurtain;

internal partial class TrayApp
{
    /// 显示器上一把锁，和 App 图标、Mac 版的 SF Symbol lock.display / lock.open.display 一样。
    /// 没有遮罩时锁是开的，遮罩显示中锁上
    internal static Icon LockIcon(bool locked) => Glyph((g, brush, s) => DrawLock(g, brush, s, locked));

    internal static void DrawLock(Graphics g, Brush brush, float s, bool locked)
    {
        // 边都落在整格上，100%（一格一像素）和 200% 缩放下不发虚。GDI+ 默认像素中心在整数坐标上，
        // 整格上的 1 像素线会糊成两格灰，所以把像素边对到整数上
        g.PixelOffsetMode = PixelOffsetMode.Half;
        using var pen = new Pen(brush, 1 * s);
        using (var screen = ArtKit.RoundedRect(1.5 * s, 1.5 * s, 13 * s, 10 * s, 1.5 * s))
            g.DrawPath(pen, screen);
        g.FillRectangle(brush, 7 * s, 12 * s, 2 * s, 2 * s);
        using (var stand = ArtKit.RoundedRect(4 * s, 14 * s, 8 * s, 1 * s, 0.5 * s))
            g.FillPath(brush, stand);
        using (var body = ArtKit.RoundedRect(5 * s, 7 * s, 6 * s, 3 * s, 0.5 * s))
            g.FillPath(brush, body);
        // 锁梁：两条腿加半圆。开着的整体抬高一格，右腿停在锁身上方，留出一格缝
        float top = locked ? 6 : 5, rightEnd = locked ? 7 : 6;
        using var shackle = new GraphicsPath();
        shackle.AddLine(6.5f * s, 7 * s, 6.5f * s, top * s);
        shackle.AddArc(6.5f * s, (top - 1.5f) * s, 3 * s, 3 * s, 180, 180);
        shackle.AddLine(9.5f * s, top * s, 9.5f * s, rightEnd * s);
        g.DrawPath(pen, shackle);
    }

    /// 保持唤醒中：托盘上的杯子和碟子（Mac 版是 SF Symbol cup.and.saucer.fill）
    static Icon CupIcon() => Glyph(DrawCup);

    /// 托盘面板「LockCurtain 保持唤醒」那一行的图标
    internal static Bitmap CupImage(int size, Color color) => GlyphImage(size, color, DrawCup);

    internal static void DrawCup(Graphics g, Brush brush, float s)
    {
        // 杯身：上宽下窄，底边圆角
        using (var cup = new GraphicsPath())
        {
            cup.AddLine(2 * s, 3.5f * s, 11.5f * s, 3.5f * s);
            cup.AddLine(11.5f * s, 3.5f * s, 10.5f * s, 9.5f * s);
            cup.AddBezier(10.5f * s, 9.5f * s, 10.2f * s, 11.2f * s, 9.2f * s, 11.5f * s, 8 * s, 11.5f * s);
            cup.AddLine(8 * s, 11.5f * s, 5.5f * s, 11.5f * s);
            cup.AddBezier(5.5f * s, 11.5f * s, 4.3f * s, 11.5f * s, 3.3f * s, 11.2f * s, 3 * s, 9.5f * s);
            cup.CloseFigure();
            g.FillPath(brush, cup);
        }
        // 把手
        using (var pen = new Pen(brush, 1.4f * s))
            g.DrawArc(pen, 9.6f * s, 4.6f * s, 4.4f * s, 4.2f * s, -80, 190);
        // 碟子
        using var saucer = new GraphicsPath();
        saucer.AddArc(0.8f * s, 12.6f * s, 1.6f * s, 1.6f * s, 90, 180);
        saucer.AddArc(12.6f * s, 12.6f * s, 1.6f * s, 1.6f * s, 270, 180);
        saucer.CloseFigure();
        g.FillPath(brush, saucer);
    }

    /// 托盘小图标：在 16×16 的设计网格里画（s 是一格的像素），颜色跟着任务栏深浅色走
    static Icon Glyph(Action<Graphics, Brush, float> draw)
    {
        var light = Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize",
                                      "SystemUsesLightTheme", 0) is int v && v == 1;
        using var bmp = GlyphImage(SystemInformation.SmallIconSize.Width, light ? Color.Black : Color.White, draw);
        var hicon = bmp.GetHicon();
        var icon = (Icon)Icon.FromHandle(hicon).Clone();
        DestroyIcon(hicon);
        return icon;
    }

    internal static Bitmap GlyphImage(int size, Color color, Action<Graphics, Brush, float> draw)
    {
        var bmp = new Bitmap(size, size);
        using var g = Graphics.FromImage(bmp);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        using var brush = new SolidBrush(color);
        draw(g, brush, size / 16f);
        return bmp;
    }

    [DllImport("user32.dll")]
    static extern bool DestroyIcon(nint hicon);
}
