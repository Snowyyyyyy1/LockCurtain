// ArtKit.cs —— 遮罩图案共用的画法：几何、颜色、渐变、动作曲线和金属材质
//
// 从 MechEye.cs 里提出来，加上 Mac 版 ArtPresets.swift 开头那几个公共函数（来光方向、倒角、
// 抛光圆柱、金属球、起棱的金属条）。所有图案都画在「原点在中心、半径 120」的坐标系里，
// 和 Swift 版一样；调用方先把 Graphics 平移、缩放好（见 MechEye.Draw）。
// GDI+ 和 SwiftUI 的差别（渐变超出端点、没有模糊、没有角向渐变）在各函数的注释里。

using System.Drawing;
using System.Drawing.Drawing2D;

namespace LockCurtain;

internal static class ArtKit
{
    public static readonly Color Clear = Color.FromArgb(0, 0, 0, 0);

    // 拉丝金属的 9 个停靠色（Swift 里 Gradient(colors:) 均匀分布）
    public static readonly Color[] BrushedStops =
    {
        Rgb(0x8A8F98), Rgb(0xDCE0E6), Rgb(0x6B7079), Rgb(0xC4C9D1), Rgb(0x777C85),
        Rgb(0xE8EBEF), Rgb(0x70757E), Rgb(0xB8BDC5), Rgb(0x8A8F98),
    };

    // 与 Swift 的 Gaze 结构对应的二维向量
    public readonly record struct V(double X, double Y)
    {
        public static V operator +(V a, V b) => new(a.X + b.X, a.Y + b.Y);
        public static V operator -(V a, V b) => new(a.X - b.X, a.Y - b.Y);
        public static V operator *(V a, double k) => new(a.X * k, a.Y * k);
    }

    // MARK: - 动作

    /// 阻尼弹簧，0 → 1，带一点过冲。omega 越大越快
    public static double Spring(double tau, double omega = 26, double zeta = 0.42)
    {
        if (!(tau > 0)) return 0;
        double wd = omega * Math.Sqrt(1 - zeta * zeta);
        return 1 - Math.Exp(-zeta * omega * tau) * (Math.Cos(wd * tau) + zeta * omega / wd * Math.Sin(wd * tau));
    }

    /// 0..1 的伪随机数，只由 (i, salt) 决定（SplitMix64 风格，UInt64 回绕）
    public static double Rand(int i, ulong salt)
    {
        unchecked
        {
            ulong z = (ulong)(long)i + salt * 0x9E3779B97F4A7C15UL;
            z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9UL;
            z = (z ^ (z >> 27)) * 0x94D049BB133111EBUL;
            z ^= z >> 31;
            return (double)(z >> 11) / (double)(1UL << 53);
        }
    }

    /// 棘轮：每 period 秒跳一格 step（度），跳的时候带过冲
    public static double Ratchet(double t, double period, double step)
    {
        double n = Math.Floor(t / period);
        double teeth = Math.Round(360 / step, MidpointRounding.AwayFromZero);
        return (n % teeth + Spring(t - n * period, 55, 0.35)) * step;
    }

    // MARK: - 几何与颜色辅助

    /// 圆（路径，调用方负责 Dispose）
    public static GraphicsPath Circle(double r, double cx = 0, double cy = 0)
    {
        var p = new GraphicsPath();
        AddCircle(p, r, cx, cy);
        return p;
    }

    /// 环：外圆 + 内圆，奇偶规则填充得到中空环
    public static GraphicsPath Ring(double outer, double inner)
    {
        var p = new GraphicsPath(FillMode.Alternate);
        AddCircle(p, outer, 0, 0);
        AddCircle(p, inner, 0, 0);
        return p;
    }

    public static void AddCircle(GraphicsPath p, double r, double cx, double cy)
    {
        p.AddEllipse((float)(cx - r), (float)(cy - r), (float)(2 * r), (float)(2 * r));
    }

    /// 圆角矩形路径（调用方负责 Dispose）
    public static GraphicsPath RoundedRect(double x, double y, double w, double h, double r)
    {
        var p = new GraphicsPath();
        AddRoundedRect(p, x, y, w, h, r);
        return p;
    }

    /// 圆角矩形：四段 90° 圆弧，顺时针
    public static void AddRoundedRect(GraphicsPath p, double x, double y, double w, double h, double r)
    {
        float d = (float)(2 * r);
        p.AddArc((float)x, (float)y, d, d, 180, 90);
        p.AddArc((float)(x + w - d), (float)y, d, d, 270, 90);
        p.AddArc((float)(x + w - d), (float)(y + h - d), d, d, 0, 90);
        p.AddArc((float)x, (float)(y + h - d), d, d, 90, 90);
        p.CloseFigure();
    }

    public static V Polar(double r, double deg) =>
        new(r * Math.Cos(deg * Math.PI / 180), r * Math.Sin(deg * Math.PI / 180));

    public static PointF P(double x, double y) => new((float)x, (float)y);

    public static PointF P(V v) => new((float)v.X, (float)v.Y);

    /// 与 Swift Color.rgb 对应：hex 为 0xRRGGBB，a 为不透明度 0..1
    public static Color Rgb(uint hex, double a = 1) =>
        Color.FromArgb(A(a), (int)((hex >> 16) & 0xff), (int)((hex >> 8) & 0xff), (int)(hex & 0xff));

    public static Color Black(double a) => Color.FromArgb(A(a), 0, 0, 0);

    public static Color White(double a) => Color.FromArgb(A(a), 255, 255, 255);

    /// 不透明度 → alpha：(int)(opacity * 255)，夹在 0..255
    public static int A(double opacity) => Math.Clamp((int)(opacity * 255), 0, 255);

    public static Color Lerp(Color a, Color b, double u)
    {
        static int Mix(int x, int y, double k) => (int)Math.Round(x + (y - x) * k);
        return Color.FromArgb(Mix(a.A, b.A, u), Mix(a.R, b.R, u), Mix(a.G, b.G, u), Mix(a.B, b.B, u));
    }

    /// 均匀分布的多色停靠点在角度 deg 上的颜色（从 startDeg 起顺时针）
    public static Color ConicColor(double deg, double startDeg, Color[] stops)
    {
        double f = (((deg - startDeg) % 360) + 360) % 360 / 360.0;
        double x = f * (stops.Length - 1);
        int i = Math.Min((int)Math.Floor(x), stops.Length - 2);
        return Lerp(stops[i], stops[i + 1], x - i);
    }

    public static void FillSolid(Graphics g, GraphicsPath path, Color c)
    {
        using var b = new SolidBrush(c);
        g.FillPath(b, path);
    }

    public static void StrokeSolid(Graphics g, GraphicsPath path, Color c, float width)
    {
        using var pen = new Pen(c, width);
        g.DrawPath(pen, path);
    }

    /// 线性渐变。端点和路径在同一个坐标系里，Graphics 的世界变换会同时作用于两者，画刷不用再设变换。
    /// GDI+ 的线性渐变超出端点会重复，不能像 SwiftUI 那样延用端点色（WrapMode.Clamp 会抛异常），
    /// 所以把渐变线两头各延长 4 倍，原来的端点以外填端点色。
    /// 渐变线几乎水平或竖直时（眨眼合上那几帧 twist 为 0，叶片方向落在坐标轴上，cos(π/2) 只是接近 0），
    /// GDI+ 建画刷会失败；正好水平或竖直它能处理，所以把浮点残差归零。
    public static LinearGradientBrush Linear(double x0, double y0, double x1, double y1, Color c0, Color c1) =>
        Linear(x0, y0, x1, y1, (c0, 0), (c1, 1));

    /// 多个停靠点的线性渐变（Swift 的 Gradient(stops:)），At 是 0..1 上的位置，要从小到大
    public static LinearGradientBrush Linear(double x0, double y0, double x1, double y1, params (Color Color, double At)[] stops)
    {
        const double k = 4;
        double dx = x1 - x0, dy = y1 - y0;
        if (Math.Abs(dx) < 1e-6) dx = 0;
        if (Math.Abs(dy) < 1e-6) dy = 0;
        (x1, y1) = (x0 + dx, y0 + dy);
        Color first = stops[0].Color, last = stops[^1].Color;
        var br = new LinearGradientBrush(P(x0 - dx * k, y0 - dy * k), P(x1 + dx * k, y1 + dy * k), first, last);
        double a = k / (2 * k + 1), b = (k + 1) / (2 * k + 1);
        br.InterpolationColors = new ColorBlend
        {
            Positions = stops.Select(st => (float)(a + (b - a) * st.At)).Prepend(0f).Append(1f).ToArray(),
            Colors = stops.Select(st => st.Color).Prepend(first).Append(last).ToArray(),
        };
        return br;
    }

    /// 均匀分布的颜色（Swift 的 Gradient(colors:)）
    public static (Color, double)[] Even(params Color[] colors) =>
        colors.Select((c, i) => (c, colors.Length == 1 ? 0.0 : (double)i / (colors.Length - 1))).ToArray();

    /// 径向渐变：Swift 的 colors 在半径 [r0, r1] 上均匀分布，r0 以内取首色，r1 以外取末色。
    public static PathGradientBrush Radial(V center, double r0, double r1, params Color[] stops) =>
        Radial(center, r0, r1, Even(stops));

    /// 停靠点带位置的径向渐变（Swift 的 Gradient(stops:)），At 是 [r0, r1] 上 0..1 的位置，要从小到大。
    /// PathGradientBrush 只画源路径以内，而且位置 0 在边界、1 在中心，所以源路径取一个
    /// 比 r1 大得多的圆，r1 到这个圆之间都填末色，位置按半径倒过来换算。
    public static PathGradientBrush Radial(V center, double r0, double r1, params (Color Color, double At)[] stops)
    {
        int n = stops.Length;
        double outer = r1 * 4 + 200;
        var pos = new List<float> { 0f };
        var cols = new List<Color> { stops[n - 1].Color };
        for (int i = n - 1; i >= 0; i--)
        {
            double r = r0 + (r1 - r0) * stops[i].At;
            pos.Add((float)(1 - r / outer));
            cols.Add(stops[i].Color);
        }
        if (r0 > 0)
        {
            pos.Add(1f);                // 圆心到 r0 之间取首色
            cols.Add(stops[0].Color);
        }

        using var src = Circle(outer, center.X, center.Y);
        return new PathGradientBrush(src)
        {
            CenterPoint = P(center),
            InterpolationColors = new ColorBlend { Positions = pos.ToArray(), Colors = cols.ToArray() },
        };
    }

    /// 拉丝环：把 conic 渐变拆成 120 个 3° 楔形（每块两侧略重叠防缝）
    public static void DrawConicRing(Graphics g, double outer, double inner, double startDeg, Color[] stops)
    {
        const int n = 120;
        for (int k = 0; k < n; k++)
        {
            double a0 = k * 360.0 / n, a1 = (k + 1) * 360.0 / n;
            Color c = ConicColor((a0 + a1) / 2, startDeg, stops);
            using var wedge = new GraphicsPath();
            wedge.AddPolygon(new[]
            {
                P(Polar(outer, a0 - 0.3)), P(Polar(outer, a1 + 0.3)),
                P(Polar(inner, a1 + 0.3)), P(Polar(inner, a0 - 0.3)),
            });
            FillSolid(g, wedge, c);
        }
    }

    /// 一字螺丝：球面受光（径向渐变中心偏左上）+ 一条槽，slot 是槽口方向（弧度）
    /// 模糊过的实心圆（SwiftUI 里 blur(radius:) 之后再 fill 圆）。GDI+ 没有模糊：
    /// 用径向渐变铺出软边，不透明度按高斯模糊后边缘的 logistic 近似往外衰减
    public static void SoftDot(Graphics g, V c, double r, double blur, Color color)
    {
        double reach = r + 2.5 * blur;
        var stops = new Color[6];
        for (int i = 0; i < stops.Length; i++)
        {
            double rho = reach * i / (stops.Length - 1);
            stops[i] = Color.FromArgb((int)(color.A / (1 + Math.Exp(1.7 * (rho - r) / blur))), color);
        }
        using var dot = Circle(reach, c.X, c.Y);
        using var brush = Radial(c, 0, reach, stops);
        g.FillPath(brush, dot);
    }

    /// 模糊投影（SwiftUI 的 .shadow(color: .black.opacity(o), radius:, x:, y:)）。GDI+ 没有模糊：
    /// 在偏移点和它周围一圈各画一遍半透明剪影，每遍的透明度按叠满后等于 opacity 来分，
    /// 重叠的中间和原版一样深，边缘渐淡；细的形状叠不满，投影也跟着变浅，和真的模糊一样。
    /// draw 用给的颜色把整层形状画一遍
    public static void SoftShadow(Graphics g, double dx, double dy, double blur, double opacity, Action<Color> draw)
    {
        const int ring = 6;
        var tap = Black(1 - Math.Pow(1 - opacity, 1.0 / (ring + 1)));
        for (int k = 0; k <= ring; k++)
        {
            V o = new V(dx, dy) + (k == 0 ? new V(0, 0) : Polar(blur * 0.7, k * 360.0 / ring));
            GraphicsState st = g.Save();
            g.TranslateTransform((float)o.X, (float)o.Y);
            draw(tap);
            g.Restore(st);
        }
    }

    public static void Screw(Graphics g, V c, double r = 4.2, double slot = 0)
    {
        double k = r / 4.2;
        using (var br = Radial(new V(c.X - 1.2 * k, c.Y - 1.2 * k), 0, 4.6 * k, Rgb(0xF2F4F7), Rgb(0x8C919A), Rgb(0x4A4E55)))
        using (var head = Circle(r, c.X, c.Y))
            g.FillPath(br, head);
        double dx = 2.8 * k * Math.Cos(slot), dy = 2.8 * k * Math.Sin(slot);
        using var slotLine = new GraphicsPath();
        slotLine.AddLine(P(c.X + dx, c.Y + dy), P(c.X - dx, c.Y - dy));
        using var slotPen = new Pen(Black(0.6), (float)k);
        g.DrawPath(slotPen, slotLine);
    }

    // MARK: - 金属材质（Mac 版 ArtPresets.swift 开头的公共函数）

    /// 来光方向（单位向量，指向光源）：左上
    public static readonly V Light = new(-0.6, -0.8);

    public static GraphicsPath Line(V a, V b)
    {
        var p = new GraphicsPath();
        p.AddLine(P(a), P(b));
        return p;
    }

    public static double Smoothstep(double x)
    {
        x = Math.Clamp(x, 0, 1);
        return x * x * (3 - 2 * x);
    }

    /// 两个 0xRRGGBB 颜色按 k（0..1）混合
    public static Color Mix(uint a, uint b, double k) => Lerp(Rgb(a), Rgb(b), Math.Clamp(k, 0, 1));

    /// 倒角描边用的画刷：左上亮、右下暗；inset 反过来，看起来是往下凹的
    public static LinearGradientBrush Bevel(double r, V c = default, double hi = 0.55, double lo = 0.4, bool inset = false)
    {
        Color top = White(hi), bottom = Black(lo);
        if (inset) (top, bottom) = (bottom, top);
        return Linear(c.X - r * 0.7, c.Y - r * 0.7, c.X + r * 0.7, c.Y + r * 0.7, top, bottom);
    }

    /// 抛光金属圆柱，从 a 到 b，两端宽 w0、w1；高光落在朝向光源的一侧
    public static void Cylinder(Graphics g, V a, V b, double w0, double w1)
    {
        double len = Math.Sqrt((b.X - a.X) * (b.X - a.X) + (b.Y - a.Y) * (b.Y - a.Y));
        var n = new V(-(b.Y - a.Y) / len, (b.X - a.X) / len);
        double lit = n.X * Light.X + n.Y * Light.Y;
        using var path = new GraphicsPath();
        path.AddPolygon(new[] { P(a + n * (w0 / 2)), P(b + n * (w1 / 2)), P(b - n * (w1 / 2)), P(a - n * (w0 / 2)) });
        var m = new V((a.X + b.X) / 2, (a.Y + b.Y) / 2);
        double w = Math.Max(w0, w1) / 2;
        V from = m + n * w, to = m - n * w;
        using var br = Linear(from.X, from.Y, to.X, to.Y,
                              (Rgb(0x5C626B), 0), (Rgb(0xF4F6F9), 0.5 - 0.3 * lit), (Rgb(0x41464E), 1));
        g.FillPath(br, path);
    }

    /// 抛光金属球：铆钉、把手球头
    public static void Sphere(Graphics g, V c, double r)
    {
        using var ball = Circle(r, c.X, c.Y);
        using var br = Radial(c + Light * (r * 0.45), 0, r * 1.5, Rgb(0xF7F8FA), Rgb(0x9097A0), Rgb(0x41454C));
        g.FillPath(br, ball);
    }

    /// 中间起一道棱的金属条（刻度、指针）：两个斜面按来光方向一亮一暗。
    /// profile 是沿长度（0…1）各处的半宽
    public static void Ridged(Graphics g, V a, V b, params (double U, double HalfWidth)[] profile)
    {
        var d = b - a;
        double len = Math.Sqrt(d.X * d.X + d.Y * d.Y);
        var n = new V(-d.Y / len, d.X / len);
        double lit = n.X * Light.X + n.Y * Light.Y;
        V Pt(double u, double s) => a + d * u + n * s;
        foreach (var side in new[] { 1.0, -1.0 })
        {
            var points = new List<PointF> { P(Pt(profile[0].U, 0)) };
            points.AddRange(profile.Select(q => P(Pt(q.U, q.HalfWidth * side))));
            points.Add(P(Pt(profile[^1].U, 0)));
            using var path = new GraphicsPath();
            path.AddPolygon(points.ToArray());
            double k = 0.5 + 0.5 * lit * side;
            using var br = Linear(a.X, a.Y, b.X, b.Y, Mix(0x50565F, 0xFFFFFF, k), Mix(0x3E434A, 0xDDE2E8, k));
            g.FillPath(br, path);
        }
    }
}
