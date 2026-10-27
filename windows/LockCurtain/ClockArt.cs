// ClockArt.cs —— 机械表图案（从 Sources/ArtPresets.swift 的 ClockArt 移植，第 91–298 行）
//
// 滚花表壳、抛光表圈、太阳纹表盘、立体刻度和多面体指针。6 点位开了个窗，看得到摆轮来回摆、
// 擒纵轮一跳一格，秒针跟着一秒跳 3 下。指针显示本机当前时间。
// 坐标和动作与 Swift 版一致：原点在中心、半径 120 的坐标系，由本方法自己平移、缩放（同 MechEye.Draw）。
// GDI+ 和 SwiftUI 的差别：没有模糊阴影（用偏移的半透明轮廓代替，见 Cast）、没有滤镜和混合模式
// （用透明度近似）、没有角向渐变（用 DrawConicRing 的楔形近似）。各处注释里都标了。

using System.Drawing;
using System.Drawing.Drawing2D;
using static LockCurtain.ArtKit;

namespace LockCurtain;

internal static class ClockArt
{
    private const double Beats = 3.0;                // 每秒跳几下；摆轮一来一回是两跳
    private static readonly V Window = new(0, 50);   // 6 点位的镂空窗中心
    private const double WindowR = 21;               // 镂空窗半径

    /// 把整个图案画进 (0,0)-(side,side) 的方块里，同一个 t 画出同一帧。
    /// t 和 Swift 一样是 timeIntervalSinceReferenceDate（自 2001-01-01 UTC 起的秒数），指针用它换算本机当前时间。
    public static void Draw(Graphics g, float side, double t)
    {
        float s = side / 240f;                       // 与 Swift 的 min(size)/240 一致
        GraphicsState st = g.Save();
        g.TranslateTransform(side / 2f, side / 2f);
        g.ScaleTransform(s, s);

        DateTime local = CurtainArts.LocalTime(t);
        double frac = t - Math.Floor(t);             // 时区偏移都是整秒，小数部分直接取 t 的
        double beat = Math.Floor(frac * Beats);
        double second = local.Second + (beat + Spring((frac * Beats - beat) / Beats, 70, 0.4)) / Beats;
        double minute = local.Minute + (local.Second + frac) / 60;
        double hour = local.Hour % 12 + minute / 60;

        DrawCase(g);
        DrawDial(g);
        DrawMovement(g, t);
        DrawIndices(g);
        DrawHands(g, hour, minute, second);
        DrawCrystal(g);

        g.Restore(st);
    }

    /// 表壳：橙色余光 + 投影 + 滚花外圈 + 抛光斜面表圈
    private static void DrawCase(Graphics g)
    {
        using (var halo = Circle(116))
            StrokeSolid(g, halo, Rgb(0xFF8A3D, 0.22), 5f);

        // 投影：原版是半径 10 的模糊阴影，下移 6。GDI+ 没有模糊，和 MechEye.DrawHousing 一样用径向渐变做软边
        using (var shadow = Circle(122, 0, 6))
        using (var br = Radial(new V(0, 6), 102, 122, Black(0.55), Clear))
            g.FillPath(br, shadow);
        using (var body = Circle(112))
            FillSolid(g, body, Rgb(0x6E737C));

        // 滚花外圈：原版是 conic 拉丝金属，用 120 个楔形近似
        DrawConicRing(g, 112, 103, -20, BrushedStops);

        using (var knurl = new GraphicsPath())
        {
            for (int k = 0; k < 144; k++)
            {
                double deg = k * 2.5;
                knurl.StartFigure();
                knurl.AddLine(P(Polar(103.5, deg)), P(Polar(111.6, deg)));
            }
            StrokeSolid(g, knurl, Black(0.3), 0.8f);
        }
        using (var rim = Circle(111.3))
        using (var br = Bevel(111))
        using (var pen = new Pen(br, 1.4f))
            g.DrawPath(pen, rim);

        // 抛光表圈（斜面）：原版的 4 色线性渐变按均匀位置排布
        using (var ring = Ring(103, 93))
        using (var br = Linear(-75, -75, 75, 75, Even(Rgb(0xFAFBFC), Rgb(0xB4BAC2), Rgb(0x60656D), Rgb(0x9DA3AB))))
            g.FillPath(br, ring);
        using (var outer = Circle(103))
            StrokeSolid(g, outer, Black(0.45), 1f);
        using (var inner = Circle(93.6))
        using (var br = Bevel(93, hi: 0.3, lo: 0.6, inset: true))
        using (var pen = new Pen(br, 1.6f))
            g.DrawPath(pen, inner);
    }

    /// 太阳纹表盘：亮度按 cos 2θ 起伏（左上、右下两瓣反光），叠一层极细的放射纹；外圈分钟轨
    private static void DrawDial(Graphics g)
    {
        // 原版是 conic 渐变（25 个均匀停靠点）；这里用楔形画圆盘，内径取 0
        var stops = new Color[25];
        for (int k = 0; k <= 24; k++)
        {
            double a = k / 24.0 * 2 * Math.PI;
            stops[k] = Mix(0x131925, 0x3A4762, 0.5 + 0.5 * Math.Cos(2 * (a - 1.25 * Math.PI)));
        }
        DrawConicRing(g, 93, 0, 0, stops);

        using (var rays = new GraphicsPath())
        {
            for (int k = 0; k < 240; k++)
            {
                rays.StartFigure();
                rays.AddLine(P(Polar(6, k * 1.5)), P(Polar(92, k * 1.5)));
            }
            StrokeSolid(g, rays, White(0.035), 0.5f);
        }
        // 边缘压暗（原版 startRadius 45、endRadius 93）
        using (var disk = Circle(93))
        using (var br = Radial(new V(0, 0), 45, 93, Clear, Black(0.5)))
            g.FillPath(br, disk);

        using (var c88 = Circle(88))
            StrokeSolid(g, c88, White(0.3), 0.6f);
        using (var c82 = Circle(82))
            StrokeSolid(g, c82, White(0.3), 0.6f);

        using (var ticks = new GraphicsPath())
        {
            for (int k = 0; k < 60; k++)
            {
                if (k % 5 == 0) continue;
                ticks.StartFigure();
                ticks.AddLine(P(Polar(82, k * 6.0)), P(Polar(88, k * 6.0)));
            }
            StrokeSolid(g, ticks, White(0.6), 0.8f);
        }
        for (int k = 0; k < 12; k++)
        {
            V p = Polar(85, k * 30.0);
            using var dot = Circle(1.6, p.X, p.Y);
            FillSolid(g, dot, Rgb(0xDDEFD6, 0.9));
        }
    }

    /// 机芯：镂空窗里有日内瓦波纹底板、擒纵轮、来回摆的摆轮和游丝、摆轮夹板上的红宝石。
    /// 窗口外有一圈抛光金属边（最后画，不受窗口裁剪）
    private static void DrawMovement(Graphics g, double t)
    {
        V c = Window;
        double swing = 150 * Math.Sin(Math.PI * Beats * t);   // 摆角（度）：过中点时正好跳一下

        GraphicsState st = g.Save();
        using (var clip = Circle(WindowR, c.X, c.Y))
            g.SetClip(clip, CombineMode.Intersect);

        DrawPlate(g);
        using (var hole = Circle(WindowR, c.X, c.Y))
            FillSolid(g, hole, Black(0.35));
        DrawEscapement(g, t);
        DrawBalance(g, swing);
        DrawHairspring(g, swing);
        DrawCock(g);

        g.Restore(st);

        using (var rim = Circle(WindowR + 1, c.X, c.Y))
        using (var br = Linear(c.X - WindowR, c.Y - WindowR, c.X + WindowR, c.Y + WindowR,
                               Even(Rgb(0xF4F6F9), Rgb(0x6A7079), Rgb(0xC9CED5))))
        using (var pen = new Pen(br, 2.4f))
            g.DrawPath(pen, rim);
    }

    /// 日内瓦波纹底板：旋转 -28° 的竖条，每条自带一道明暗渐变
    private static void DrawPlate(Graphics g)
    {
        GraphicsState st = g.Save();
        g.TranslateTransform((float)Window.X, (float)Window.Y);
        g.RotateTransform(-28);
        for (int k = -5; k <= 5; k++)
        {
            double x = k * 5.0;
            using var bar = new GraphicsPath();
            bar.AddRectangle(new RectangleF((float)(x - 2.5), (float)(-WindowR - 4), 5f, (float)(2 * WindowR + 8)));
            using var br = Linear(x - 2.5, 0, x + 2.5, 0, Even(Rgb(0x7A808A), Rgb(0xC9CED5), Rgb(0x6C727B)));
            g.FillPath(br, bar);
        }
        g.Restore(st);
    }

    /// 擒纵轮：一跳转半个齿（过冲的弹簧跳动），齿是 15 个三角折线
    private static void DrawEscapement(Graphics g, double t)
    {
        double b = Math.Floor(t * Beats);
        double esc = (b + Spring((t * Beats - b) / Beats, 80, 0.4)) * 12;
        V ec = new(Window.X + 10, Window.Y + 8);

        using (var teeth = new GraphicsPath())
        {
            for (int k = 0; k < 15; k++)
            {
                double a = esc + k * 24;
                teeth.StartFigure();
                teeth.AddLines(new[] { P(ec + Polar(4, a)), P(ec + Polar(8.5, a + 9)), P(ec + Polar(6.5, a + 16)) });
            }
            using (var hub = Circle(6.6, ec.X, ec.Y))
                FillSolid(g, hub, Rgb(0xB8893A));
            StrokeSolid(g, teeth, Rgb(0xD9AE5C), 1f);
        }
        using (var pivot = Circle(4, ec.X, ec.Y))
            FillSolid(g, pivot, Rgb(0x3A3F46));
    }

    /// 摆轮：金色圆环 + 三根辐条 + 四颗宝石点；圆环带一道偏移的半透明黑影代替模糊投影
    private static void DrawBalance(Graphics g, double swing)
    {
        GraphicsState st = g.Save();
        g.TranslateTransform((float)Window.X, (float)Window.Y);
        g.RotateTransform((float)swing);

        // 投影：原版是半径 1.5 的模糊阴影，偏移 (1, 1.5)（摆轮局部坐标）
        using (var shadowRing = Circle(13.5))
            SoftShadow(g, 1, 1.5, 1.5, 0.6, c => StrokeSolid(g, shadowRing, c, 2.6f));

        using (var ring = Circle(13.5))
        using (var br = Linear(-13, -13, 13, 13, Even(Rgb(0xF6DC9A), Rgb(0xC79A45), Rgb(0x7D5A1E))))
        using (var pen = new Pen(br, 2.6f))
            g.DrawPath(pen, ring);

        for (int k = 0; k < 3; k++)
        {
            using var spoke = Line(new V(0, 0), Polar(12.5, k * 120.0));
            StrokeSolid(g, spoke, Rgb(0xC79A45), 1.5f);
        }
        for (int k = 0; k < 4; k++)
        {
            V p = Polar(15.2, k * 90.0 + 45);
            using var jewel = Circle(1.3, p.X, p.Y);
            FillSolid(g, jewel, Rgb(0xF1D58E));
        }
        g.Restore(st);
    }

    /// 游丝：外端固定、内端跟着摆轮转，看起来一松一紧（91 个点的折线，在机芯坐标里画）
    private static void DrawHairspring(Graphics g, double swing)
    {
        var pts = new PointF[91];
        for (int i = 0; i <= 90; i++)
        {
            double u = i / 90.0;
            double a = u * 3.5 * 360 + swing * (1 - u);   // 与原版的 u*3.5*2π + swing*(1-u)（弧度）相同，这里用度
            pts[i] = P(Window + Polar(2.2 + 7.6 * u, a));
        }
        using var coil = new GraphicsPath();
        coil.AddLines(pts);
        StrokeSolid(g, coil, Rgb(0x6F8FD8, 0.9), 0.5f);
    }

    /// 摆轮夹板 + 红宝石轴承。夹板和轴承的投影用偏移 (1,2) 的半透明黑色轮廓代替模糊阴影
    private static void DrawCock(Graphics g)
    {
        V c = Window;
        V a = new(c.X - 26, c.Y - 12);
        using (var bar = Silhouette(a, c, (0.0, 3.5), (1.0, 2.5)))
            Cast(g, bar, 1, 2, 2, 0.55);
        using (var bearing = Circle(4.2, c.X, c.Y))
            Cast(g, bearing, 1, 2, 2, 0.55);

        Cylinder(g, a, c, 7, 5);
        using (var bearing = Circle(4.2, c.X, c.Y))
        using (var br = Radial(new V(c.X - 1.5, c.Y - 1.5), 0, 6, Rgb(0xF4F6F9), Rgb(0x8C929B)))
            g.FillPath(br, bearing);

        // 红宝石
        using (var ruby = Circle(1.9, c.X, c.Y))
        using (var br = Radial(new V(c.X - 0.6, c.Y - 0.6), 0, 2.2, Rgb(0xFF6A7A), Rgb(0xA0102A)))
            g.FillPath(br, ruby);
        using (var glint = Circle(0.6, c.X - 0.7, c.Y - 0.7))
            FillSolid(g, glint, White(0.8));
        using (var edge = Circle(WindowR - 0.5, c.X, c.Y))
            StrokeSolid(g, edge, Black(0.55), 3f);
    }

    /// 抛光立体刻度，12 点是双条；6 点被镂空窗占了。刻度的投影用偏移的半透明黑色轮廓代替（原版 radius 1.5，偏移 (0.8, 1.4)）
    private static void DrawIndices(Graphics g)
    {
        // 先画所有投影，再画刻度，和原版把整层当一个阴影层来画的顺序一致
        for (int k = 0; k < 12; k++)
        {
            if (k == 6) continue;
            foreach (var (a, b, hw) in TickSegments(k))
            {
                using var shape = Silhouette(a, b, (0.0, hw), (1.0, hw));
                Cast(g, shape, 0.8, 1.4, 1.5, 0.65);
            }
        }
        for (int k = 0; k < 12; k++)
        {
            if (k == 6) continue;
            foreach (var (a, b, hw) in TickSegments(k))
                Ridged(g, a, b, (0.0, hw), (1.0, hw));
        }
    }

    /// 第 k 个刻度的线段（12 点是两条，各偏 ±3.6）：(起点, 终点, 半宽)
    private static IEnumerable<(V A, V B, double HalfWidth)> TickSegments(int k)
    {
        double deg = k * 30.0 - 90;
        double rad = deg * Math.PI / 180;
        var n = new V(-Math.Sin(rad), Math.Cos(rad));
        double hw = k == 0 ? 2.2 : (k % 3 == 0 ? 3.2 : 2.6);
        double[] offsets = k == 0 ? new[] { -3.6, 3.6 } : new[] { 0.0 };
        foreach (double o in offsets)
            yield return (Polar(63, deg) + n * o, Polar(79, deg) + n * o, hw);
    }

    /// 多面体（dauphine）时针、分针，橙色秒针带配重圈；三根针离表盘高度不同，影子也错开
    private static void DrawHands(Graphics g, double hour, double minute, double second)
    {
        Hand(g, hour, 12, tail: 10, length: 52, width: 5.5, height: 2);
        Hand(g, minute, 60, tail: 12, length: 78, width: 4.6, height: 3);
        Sphere(g, new V(0, 0), 5.2);
        SecondHand(g, second);
        using (var hub = Circle(1.1))
            FillSolid(g, hub, Rgb(0x2A1A10));
    }

    private static void Hand(Graphics g, double value, double period, double tail, double length, double width, double height)
    {
        double deg = value / period * 360 - 90;
        V a = Polar(-tail, deg), b = Polar(length, deg);
        var profile = new[] { (0.0, width * 0.55), (0.16, width), (1.0, 0.0) };

        // 投影：原版是半径 1+height*0.6 的模糊阴影，偏移 (height*0.5, height)
        using (var shape = Silhouette(a, b, profile))
            Cast(g, shape, height * 0.5, height, 1 + height * 0.6, 0.55);

        Ridged(g, a, b, profile);
        using var glint = Line(Polar(length * 0.3, deg), Polar(length * 0.78, deg));
        using var pen = new Pen(Rgb(0xDDEFD6, 0.85), 1.4f) { StartCap = LineCap.Round, EndCap = LineCap.Round };
        g.DrawPath(pen, glint);
    }

    /// 秒针：细针 + 尾端短杆 + 配重圈 + 圆心圆盘。投影是同一套线条（原版半径 2.5，偏移 (2, 4)）
    private static void SecondHand(Graphics g, double second)
    {
        double deg = second / 60 * 360 - 90;
        SoftShadow(g, 2, 4, 2.5, 0.5, c => Needle(g, deg, c));
        Needle(g, deg, Rgb(0xFF8A3D));
    }

    private static void Needle(Graphics g, double deg, Color c)
    {
        using (var stick = Line(Polar(-12, deg), Polar(86, deg)))
        using (var pen = new Pen(c, 1.3f) { StartCap = LineCap.Round, EndCap = LineCap.Round })
            g.DrawPath(pen, stick);
        using (var tail = Line(Polar(-12, deg), Polar(-24, deg)))
            StrokeSolid(g, tail, c, 2.2f);
        V counter = Polar(-20, deg);
        using (var ring = Circle(3.4, counter.X, counter.Y))
        using (var pen = new Pen(c, 1.4f))
            g.DrawPath(pen, ring);
        using (var disc = Circle(3.2))
            FillSolid(g, disc, c);
    }

    /// 表镜：左上一道弧形反光 + 小高光点 + 边缘压暗
    private static void DrawCrystal(Graphics g)
    {
        GraphicsState st = g.Save();
        using (var clip = Circle(93))
            g.SetClip(clip, CombineMode.Intersect);

        using (var arc = new GraphicsPath())
        {
            arc.AddArc(-80f, -80f, 160f, 160f, 200f, 55f);   // 200° → 255°，角度递增（和 MechEye.DrawGlass 一样）
            using var pen = new Pen(White(0.16), 8f) { StartCap = LineCap.Round, EndCap = LineCap.Round };
            g.DrawPath(pen, arc);
        }

        SoftDot(g, new V(-44, -54), 5, 3, White(0.3));

        using (var edge = Circle(93))
        using (var br = Radial(new V(0, 0), 65, 94, Clear, Black(0.3)))
            g.FillPath(br, edge);

        g.Restore(st);
    }

    /// 沿 a→b 的金属条轮廓（两侧按 profile 的半宽展开）。Cylinder、刻度、指针的投影都用它
    private static GraphicsPath Silhouette(V a, V b, params (double U, double HalfWidth)[] profile)
    {
        V d = b - a;
        double len = Math.Sqrt(d.X * d.X + d.Y * d.Y);
        var n = new V(-d.Y / len, d.X / len);
        V Pt(double u, double s) => a + d * u + n * s;

        var pts = new List<PointF>();
        foreach (var q in profile) pts.Add(P(Pt(q.U, q.HalfWidth)));
        for (int i = profile.Length - 1; i >= 0; i--) pts.Add(P(Pt(profile[i].U, -profile[i].HalfWidth)));
        var path = new GraphicsPath();
        path.AddPolygon(pts.ToArray());
        return path;
    }

    /// 一个轮廓的模糊投影，见 ArtKit.SoftShadow
    private static void Cast(Graphics g, GraphicsPath shape, double dx, double dy, double blur, double alpha) =>
        SoftShadow(g, dx, dy, blur, alpha, c => FillSolid(g, shape, c));
}
