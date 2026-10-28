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
    /// 初代 Mac，和 App 图标、Mac 版菜单栏图标同一个造型。平时屏幕上是笑脸，遮罩显示中屏幕涂满、抠出一把锁。
    /// 16 格里放不下 Mac 版笑脸的鼻子，这里只有眼睛和嘴
    internal static Icon MacIcon(bool locked) => Glyph((g, brush, s) => DrawMac(g, brush, s, locked));

    internal static void DrawMac(Graphics g, Brush brush, float s, bool locked)
    {
        // 边都落在整格上，100%（一格一像素）和 200% 缩放下不发虚。GDI+ 默认像素中心在整数坐标上，
        // 整格上的 1 像素线会糊成两格灰，所以把像素边对到整数上
        g.PixelOffsetMode = PixelOffsetMode.Half;
        RectangleF R(float x, float y, float w, float h) => new(x * s, y * s, w * s, h * s);
        // 机身外框（GraphicsPath 默认奇偶填充，里圈抠掉）、软驱口
        using (var body = ArtKit.RoundedRect(1 * s, 1 * s, 14 * s, 14 * s, 2.5 * s))
        {
            ArtKit.AddRoundedRect(body, 2 * s, 2 * s, 12 * s, 12 * s, 1.5 * s);
            g.FillPath(brush, body);
        }
        g.FillRectangle(brush, R(8, 12, 4, 1));
        // 屏幕：遮罩显示中整块涂满，锁梁和锁身抠出来；平时是一圈框，里面两只眼、一道笑
        using var screen = ArtKit.RoundedRect(3 * s, 3 * s, 10 * s, 8 * s, 1.5 * s);
        if (locked)
            screen.AddRectangles([R(7, 4, 2, 1), R(6, 5, 1, 2), R(9, 5, 1, 2), R(5, 7, 6, 3)]);
        else
            screen.AddRectangle(R(4, 4, 8, 6));
        g.FillPath(brush, screen);
        if (!locked)
            g.FillRectangles(brush, [R(6, 5, 1, 2), R(9, 5, 1, 2), R(5, 8, 1, 1), R(10, 8, 1, 1), R(6, 9, 4, 1)]);
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
