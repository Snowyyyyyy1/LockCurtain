// MechEye.cs —— 遮罩上的机械眼球（从 Sources/MechEye.swift 移植，参考 Lakr233/Sentry 的 EyeView，MIT）
//
// 结构从外到内：金属外壳（刻度 + 螺丝）→ 棘轮齿圈 → 眼窝 → 会转动的眼球
// （橙红虹膜 + 8 片光圈叶片 + 红色指示灯）→ 玻璃罩高光。
// 整只眼是时间 t 的纯函数，由调用方按帧调用 Draw。
// 动作都是「机械」的：齿圈一格一格跳、眼球快速转到新位置再带一点过冲停住、
// 光圈跟着重新对焦，偶尔整个合上再打开（眨眼）。

using System.Drawing;
using System.Drawing.Drawing2D;

namespace LockCurtain;

internal static class MechEye
{
    // 设计坐标：原点在中心，半径 120 的坐标系（与 Swift 相同）
    private const double Slot = 1.7;       // 注视点切换的时间片
    private const double MaxGaze = 15.0;   // 注视点最大偏移

    private static readonly Color Clear = Color.FromArgb(0, 0, 0, 0);

    // 拉丝金属的 9 个停靠色（Swift 里 Gradient(colors:) 均匀分布）
    private static readonly Color[] BrushedStops =
    {
        Rgb(0x8A8F98), Rgb(0xDCE0E6), Rgb(0x6B7079), Rgb(0xC4C9D1), Rgb(0x777C85),
        Rgb(0xE8EBEF), Rgb(0x70757E), Rgb(0xB8BDC5), Rgb(0x8A8F98),
    };

    // 与 Swift 的 Gaze 结构对应的二维向量
    private readonly record struct V(double X, double Y)
    {
        public static V operator +(V a, V b) => new(a.X + b.X, a.Y + b.Y);
        public static V operator -(V a, V b) => new(a.X - b.X, a.Y - b.Y);
        public static V operator *(V a, double k) => new(a.X * k, a.Y * k);
    }

    private readonly record struct Pose(V Gaze, double Pupil, double Gear, double Iris, double Glow);

    // MARK: - 动作

    /// 阻尼弹簧，0 → 1，带一点过冲。omega 越大越快
    private static double Spring(double tau, double omega = 26, double zeta = 0.42)
    {
        if (!(tau > 0)) return 0;
        double wd = omega * Math.Sqrt(1 - zeta * zeta);
        return 1 - Math.Exp(-zeta * omega * tau) * (Math.Cos(wd * tau) + zeta * omega / wd * Math.Sin(wd * tau));
    }

    /// 0..1 的伪随机数，只由 (i, salt) 决定（SplitMix64 风格，UInt64 回绕）
    private static double Rand(int i, ulong salt)
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
    private static double Ratchet(double t, double period, double step)
    {
        double n = Math.Floor(t / period);
        double teeth = Math.Round(360 / step, MidpointRounding.AwayFromZero);
        return (n % teeth + Spring(t - n * period, 55, 0.35)) * step;
    }

    /// 每 slot 秒可能换一次注视点，换的时刻在 slot 开头 0.6 秒内随机
    private static double MoveTime(int i) => i * Slot + 0.6 * Rand(i, 1);

    private static V GazeTarget(int i)
    {
        if (Rand(i, 2) < 0.28) return new V(0, 0);             // 时不时回正
        double a = Rand(i, 3) * 2 * Math.PI;
        double r = MaxGaze * (0.45 + 0.55 * Rand(i, 4));
        return new V(Math.Cos(a) * r, Math.Sin(a) * r * 0.7);  // 左右看得比上下多
    }

    private static Pose PoseAt(double t)
    {
        int i = (int)Math.Floor(t / Slot);
        if (t < MoveTime(i)) i -= 1;
        double tau = t - MoveTime(i);
        double k = Spring(tau);
        V from = GazeTarget(i - 1), to = GazeTarget(i);
        // 停住时伺服电机的细微抖动
        V hum = new(Math.Sin(t * 37) * 0.18 + Math.Sin(t * 59) * 0.1, Math.Cos(t * 43) * 0.15);
        V gaze = new(from.X + (to.X - from.X) * k + hum.X, from.Y + (to.Y - from.Y) * k + hum.Y);

        // 转完眼再对焦：光圈晚 0.12 秒跟上
        double focusFrom = 10 + 12 * Rand(i - 1, 5), focusTo = 10 + 12 * Rand(i, 5);
        double pupil = focusFrom + (focusTo - focusFrom) * Spring(tau - 0.12, 18, 0.5);
        // 眨眼：约 1/5 的 slot 在转完后合上光圈再打开
        if (Rand(i, 6) < 0.2)
        {
            double b = tau - 0.85;
            if (b > 0 && b < 0.1) pupil *= 1 - b / 0.1;
            else if (b >= 0.1 && b < 0.18) pupil = 0;
            else if (b >= 0.18) pupil *= Math.Min(1, Spring(b - 0.18, 20, 0.55));
        }

        return new Pose(gaze, Math.Max(0, pupil),
                        Ratchet(t, 1.6, 7.5),
                        -Ratchet(t + 0.4, 0.8, 2.5),
                        0.72 + 0.28 * Math.Sin(t * 2 * Math.PI / 2.6));
    }

    // MARK: - 绘制

    /// 把整只眼画进 (0,0)-(side,side) 的方块里。同一个 t 画出同一帧。
    /// 调用方已设好 SmoothingMode 并把 g 平移到方块左上角。
    public static void Draw(Graphics g, float side, double t)
    {
        float s = side / 240f;                 // 与 Swift 的 min(size)/240 一致
        Pose p = PoseAt(t);

        GraphicsState st = g.Save();
        g.TranslateTransform(side / 2f, side / 2f);
        g.ScaleTransform(s, s);

        DrawHousing(g);
        DrawGear(g, p.Gear);
        DrawCavity(g);
        DrawEyeball(g, p);
        DrawGlass(g);

        g.Restore(st);
    }

    /// 外壳：拉丝金属环 + 刻度 + 6 颗螺丝 + 一圈橙色余光
    private static void DrawHousing(Graphics g)
    {
        using (var halo = Circle(116))
        using (var pen = new Pen(Rgb(0xFF8A3D, 0.22), 5f))
            g.DrawPath(pen, halo);

        // 投影：原版是半径 10 的模糊阴影，下移 6。GDI+ 没有模糊，用径向渐变做出软边：
        // 外壳边缘内外各 10 的范围里，透明度从 0.55 线性降到 0
        using (var shadow = Circle(122, 0, 6))
        using (var br = Radial(new V(0, 6), 102, 122, Black(0.55), Clear))
            g.FillPath(br, shadow);
        using (var body = Circle(112))
            FillSolid(g, body, Rgb(0x6E737C));

        // 拉丝环：原版是 conic 角向渐变，GDI+ 没有，用 120 个 3° 楔形近似
        DrawConicRing(g, 112, 92, -20, BrushedStops);

        using (var rim = Circle(111.3))
        using (var br = Linear(-80, -80, 80, 80, White(0.55), Black(0.35)))
        using (var pen = new Pen(br, 1.4f))
            g.DrawPath(pen, rim);
        using (var groove = Circle(92.5))
        using (var br = Linear(-60, -60, 60, 60, Black(0.6), White(0.4)))
        using (var pen = new Pen(br, 1.6f))
            g.DrawPath(pen, groove);

        // 刻度：每 6° 一格，每 30° 长一格；螺丝所在位置留空
        for (int k = 0; k < 60; k++)
        {
            if (k % 10 == 5) continue;
            bool isLong = k % 5 == 0;
            double deg = k * 6.0;
            using var pen = new Pen(Black(isLong ? 0.55 : 0.35), isLong ? 1.4f : 0.9f);
            g.DrawLine(pen, P(Polar(95, deg)), P(Polar(isLong ? 101 : 98.5, deg)));
        }

        // 螺丝：球面受光（径向渐变中心偏左上 1.2）+ 一条槽
        for (int k = 0; k < 6; k++)
        {
            double deg = 30 + k * 60.0;
            V c = Polar(105, deg);
            using (var br = Radial(new V(c.X - 1.2, c.Y - 1.2), 0, 4.6, Rgb(0xF2F4F7), Rgb(0x8C919A), Rgb(0x4A4E55)))
            using (var head = Circle(4.2, c.X, c.Y))
                g.FillPath(br, head);

            // 螺丝槽：Swift 原版把 deg * 1.7 当作弧度用，这里保持一致（疑似原作笔误，未修正）
            double sa = deg * 1.7;
            double dx = 2.8 * Math.Cos(sa), dy = 2.8 * Math.Sin(sa);
            using var slotLine = new GraphicsPath();
            slotLine.AddLine(P(c.X + dx, c.Y + dy), P(c.X - dx, c.Y - dy));
            using var slotPen = new Pen(Black(0.6), 1f);
            g.DrawPath(slotPen, slotLine);
        }
    }

    /// 棘轮齿圈：48 齿，一格一格转
    private static void DrawGear(Graphics g, double angle)
    {
        using (var body = Ring(92, 80))
            FillSolid(g, body, Rgb(0x2A2E35));

        using var teeth = new GraphicsPath();
        for (int k = 0; k < 48; k++)
        {
            double a = angle + k * 7.5;
            teeth.AddPolygon(new[]
            {
                P(Polar(84, a - 2.2)), P(Polar(90.5, a - 1.3)),
                P(Polar(90.5, a + 1.3)), P(Polar(84, a + 2.2)),
            });
        }
        using (var br = Linear(-90, -90, 90, 90, Rgb(0x7A808B), Rgb(0x3C4049)))
            g.FillPath(br, teeth);

        using (var edge = Circle(84))
            StrokeSolid(g, edge, Black(0.5), 0.8f);
    }

    /// 眼窝：中心深黑，边缘略亮
    private static void DrawCavity(Graphics g)
    {
        using (var pit = Circle(80))
        using (var br = Radial(new V(0, 0), 40, 80, Rgb(0x050506), Rgb(0x16181C)))
            g.FillPath(br, pit);
        using (var wall = Circle(79))
            StrokeSolid(g, wall, Black(0.85), 3f);
    }

    /// 眼球：深色金属球 + 随注视点平移、沿方向压扁的虹膜和光圈（假装是球面在转）
    private static void DrawEyeball(Graphics g, Pose p)
    {
        GraphicsState st = g.Save();
        using (var clip = Circle(77))
            g.SetClip(clip, CombineMode.Intersect);

        V hl = new(-22 + p.Gaze.X * 0.5, -26 + p.Gaze.Y * 0.5);
        using (var ball = Circle(76))
        using (var br = Radial(hl, 0, 95, Rgb(0x4A505A), Rgb(0x1E2126), Rgb(0x0A0B0D)))
            g.FillPath(br, ball);

        double d = Math.Sqrt(p.Gaze.X * p.Gaze.X + p.Gaze.Y * p.Gaze.Y);
        double dirDeg = Math.Atan2(p.Gaze.Y, p.Gaze.X) * 180 / Math.PI;
        GraphicsState eye = g.Save();
        g.TranslateTransform((float)p.Gaze.X, (float)p.Gaze.Y);
        g.RotateTransform((float)dirDeg);
        g.ScaleTransform((float)(1 - 0.22 * Math.Min(d / MaxGaze, 1.2)), 1f);
        g.RotateTransform((float)-dirDeg);

        DrawIris(g, p.Iris);
        DrawAperture(g, p.Pupil, p.Glow);

        g.Restore(eye);
        g.Restore(st);
    }

    /// 橙红虹膜 + 放射纹理（沿用 Sentry 的配色），纹理圈反向一格一格转
    private static void DrawIris(Graphics g, double angle)
    {
        using (var rim = Circle(60.5))
        using (var pen = new Pen(Rgb(0xFF9A4A, 0.35), 2f))
            g.DrawPath(pen, rim);
        using (var disk = Circle(59))
        using (var br = Radial(new V(0, 0), 34, 59, Rgb(0xD81F12), Rgb(0xFF7A1A), Rgb(0xFF9B3D), Rgb(0xC0140C)))
            g.FillPath(br, disk);

        using (var coarse = new GraphicsPath())
        {
            for (int k = 0; k < 36; k++)
            {
                double a = angle + k * 10.0;
                coarse.StartFigure();
                coarse.AddLine(P(Polar(40, a)), P(Polar(58, a)));
            }
            using var coarsePen = new Pen(Black(0.32), 1.1f);
            g.DrawPath(coarsePen, coarse);
        }

        using (var fine = new GraphicsPath())
        {
            for (int k = 0; k < 24; k++)
            {
                double a = -angle * 0.5 + k * 15.0 + 5;
                fine.StartFigure();
                fine.AddLine(P(Polar(40, a)), P(Polar(50, a)));
            }
            using var finePen = new Pen(Rgb(0x7A0A05, 0.45), 0.6f);
            g.DrawPath(finePen, fine);
        }

        using (var outline = Circle(59))
            StrokeSolid(g, outline, Black(0.6), 1.6f);
    }

    /// 8 片光圈叶片。开口是内切圆半径为 pupil 的正八边形，开得越大叶片转得越多
    private static void DrawAperture(Graphics g, double pupil, double glow)
    {
        const int n = 8;
        const double outer = 39;
        const double far = outer * 3;
        double twist = pupil * 0.035;
        double circR = pupil / Math.Cos(Math.PI / n);
        var v = new V[n];
        for (int k = 0; k < n; k++)
        {
            double a = twist + k * 2 * Math.PI / n;
            v[k] = new V(circR * Math.Cos(a), circR * Math.Sin(a));
        }

        GraphicsState st = g.Save();
        using (var clip = Circle(outer))
            g.SetClip(clip, CombineMode.Intersect);

        // 开口里面：镜头 + 红色指示灯
        using (var lens = Circle(outer))
            FillSolid(g, lens, Color.Black);
        using (var lamp = Circle(pupil * 0.95 + 3))
        using (var br = Radial(new V(0, 0), 0, pupil * 0.95 + 3,
                               Rgb(0xFF2A1A, 0.95 * glow), Rgb(0xB00A05, 0.55 * glow), Clear))
            g.FillPath(br, lamp);
        if (pupil * 0.62 > 0)
        {
            using var lensRing = Circle(pupil * 0.62);
            StrokeSolid(g, lensRing, White(0.07), 0.8f);
        }
        using (var dot = Circle(2.4))
            FillSolid(g, dot, Rgb(0xFFD0C0, 0.6 + 0.4 * glow));

        // 叶片：顶点 v[k+1] 处，夹在第 k 条边的延长线和第 k+1 条边之间的楔形
        for (int k = 0; k < n; k++)
        {
            V apex = v[(k + 1) % n];
            V d0 = DirOf(twist, n, k), d1 = DirOf(twist, n, k + 1);
            V far0 = apex + d0 * far, far1 = apex + d1 * far;
            V mid = apex + (d0 + d1) * 20;
            int shade = k % 2 == 0 ? 0x5A616C : 0x4C525C;
            using (var blade = new GraphicsPath())
            {
                blade.AddPolygon(new[] { P(apex), P(far0), P(far1) });
                using var bladeBrush = Linear(apex.X, apex.Y, mid.X, mid.Y, Rgb((uint)shade), Rgb(0x1C1F24));
                g.FillPath(bladeBrush, blade);
            }
            // 叶片边缘被虹膜照到的一线暖光
            using (var edge = new GraphicsPath())
            {
                edge.AddLine(P(apex), P(far0));
                using var edgePen = new Pen(Rgb(0xFFA060, 0.75), 0.8f);
                g.DrawPath(edgePen, edge);
            }
        }
        using (var hole = new GraphicsPath())
        {
            hole.AddPolygon(v.Select(q => P(q)).ToArray());
            StrokeSolid(g, hole, Black(0.8), 0.8f);
        }

        // 指示灯的余光漫到叶片上（原版是 plusLighter 叠加，这里用普通透明度近似）
        using (var bloom = Circle(pupil + 12))
        using (var br = Radial(new V(0, 0), pupil * 0.5, pupil + 12, Rgb(0xFF3020, 0.4 * glow), Clear))
            g.FillPath(br, bloom);

        g.Restore(st);

        using (var rimOuter = Circle(outer))
            StrokeSolid(g, rimOuter, Black(0.75), 2f);
        using (var rimLight = Circle(outer + 1.2))
            StrokeSolid(g, rimLight, Rgb(0xFFB070, 0.25), 0.8f);
    }

    /// 玻璃罩：左上一道弧形反光 + 一个小高光点，不跟着眼球动
    private static void DrawGlass(Graphics g)
    {
        GraphicsState st = g.Save();
        using (var clip = Circle(79))
            g.SetClip(clip, CombineMode.Intersect);

        using (var arc = new GraphicsPath())
        {
            arc.AddArc(-66f, -66f, 132f, 132f, 200f, 55f);   // 200° → 255°，角度递增
            using var arcPen = new Pen(White(0.22), 7f) { StartCap = LineCap.Round, EndCap = LineCap.Round };
            g.DrawPath(arcPen, arc);
        }

        // 高光点原版带 blur(3)，GDI+ 不支持模糊，这里直接画实心小圆
        using (var spot = Circle(5, -36, -44))
            FillSolid(g, spot, White(0.35));

        using (var lensEdge = Circle(79))
        using (var br = Radial(new V(0, 0), 55, 80, Clear, Black(0.35)))
            g.FillPath(br, lensEdge);

        g.Restore(st);
    }

    // MARK: - 几何与颜色辅助

    /// 圆（路径，调用方负责 Dispose）
    private static GraphicsPath Circle(double r, double cx = 0, double cy = 0)
    {
        var p = new GraphicsPath();
        AddCircle(p, r, cx, cy);
        return p;
    }

    /// 环：外圆 + 内圆，奇偶规则填充得到中空环
    private static GraphicsPath Ring(double outer, double inner)
    {
        var p = new GraphicsPath(FillMode.Alternate);
        AddCircle(p, outer, 0, 0);
        AddCircle(p, inner, 0, 0);
        return p;
    }

    private static void AddCircle(GraphicsPath p, double r, double cx, double cy)
    {
        p.AddEllipse((float)(cx - r), (float)(cy - r), (float)(2 * r), (float)(2 * r));
    }

    private static V Polar(double r, double deg) =>
        new(r * Math.Cos(deg * Math.PI / 180), r * Math.Sin(deg * Math.PI / 180));

    /// 第 k 条边的方向（正八边形按角度算，开口为 0 时也成立）
    private static V DirOf(double twist, int n, int k)
    {
        double a = twist + (k + 0.5) * 2 * Math.PI / n + Math.PI / 2;
        return new V(Math.Cos(a), Math.Sin(a));
    }

    private static PointF P(double x, double y) => new((float)x, (float)y);

    private static PointF P(V v) => new((float)v.X, (float)v.Y);

    /// 与 Swift Color.rgb 对应：hex 为 0xRRGGBB，a 为不透明度 0..1
    private static Color Rgb(uint hex, double a = 1) =>
        Color.FromArgb(A(a), (int)((hex >> 16) & 0xff), (int)((hex >> 8) & 0xff), (int)(hex & 0xff));

    private static Color Black(double a) => Color.FromArgb(A(a), 0, 0, 0);

    private static Color White(double a) => Color.FromArgb(A(a), 255, 255, 255);

    /// 不透明度 → alpha：(int)(opacity * 255)，夹在 0..255
    private static int A(double opacity) => Math.Clamp((int)(opacity * 255), 0, 255);

    private static Color Lerp(Color a, Color b, double u)
    {
        static int Mix(int x, int y, double k) => (int)Math.Round(x + (y - x) * k);
        return Color.FromArgb(Mix(a.A, b.A, u), Mix(a.R, b.R, u), Mix(a.G, b.G, u), Mix(a.B, b.B, u));
    }

    /// 均匀分布的多色停靠点在角度 deg 上的颜色（从 startDeg 起顺时针）
    private static Color ConicColor(double deg, double startDeg, Color[] stops)
    {
        double f = (((deg - startDeg) % 360) + 360) % 360 / 360.0;
        double x = f * (stops.Length - 1);
        int i = Math.Min((int)Math.Floor(x), stops.Length - 2);
        return Lerp(stops[i], stops[i + 1], x - i);
    }

    private static void FillSolid(Graphics g, GraphicsPath path, Color c)
    {
        using var b = new SolidBrush(c);
        g.FillPath(b, path);
    }

    private static void StrokeSolid(Graphics g, GraphicsPath path, Color c, float width)
    {
        using var pen = new Pen(c, width);
        g.DrawPath(pen, path);
    }

    /// 线性渐变。端点和路径在同一个坐标系里，Graphics 的世界变换会同时作用于两者，画刷不用再设变换。
    /// GDI+ 的线性渐变超出端点会重复，不能像 SwiftUI 那样延用端点色（WrapMode.Clamp 会抛异常），
    /// 所以把渐变线两头各延长 4 倍，原来的端点以外填端点色。
    /// 渐变线几乎水平或竖直时（眨眼合上那几帧 twist 为 0，叶片方向落在坐标轴上，cos(π/2) 只是接近 0），
    /// GDI+ 建画刷会失败；正好水平或竖直它能处理，所以把浮点残差归零。
    private static LinearGradientBrush Linear(double x0, double y0, double x1, double y1, Color c0, Color c1)
    {
        const double k = 4;
        double dx = x1 - x0, dy = y1 - y0;
        if (Math.Abs(dx) < 1e-6) dx = 0;
        if (Math.Abs(dy) < 1e-6) dy = 0;
        (x1, y1) = (x0 + dx, y0 + dy);
        var br = new LinearGradientBrush(P(x0 - dx * k, y0 - dy * k), P(x1 + dx * k, y1 + dy * k), c0, c1);
        float a = (float)(k / (2 * k + 1)), b = (float)((k + 1) / (2 * k + 1));
        br.InterpolationColors = new ColorBlend { Positions = new[] { 0f, a, b, 1f }, Colors = new[] { c0, c0, c1, c1 } };
        return br;
    }

    /// 径向渐变：Swift 的 colors 在半径 [r0, r1] 上均匀分布，r0 以内取首色，r1 以外取末色。
    /// PathGradientBrush 只画源路径以内，而且位置 0 在边界、1 在中心，所以源路径取一个
    /// 比 r1 大得多的圆，r1 到这个圆之间都填末色，位置按半径倒过来换算。
    private static PathGradientBrush Radial(V center, double r0, double r1, params Color[] stops)
    {
        int n = stops.Length;
        double outer = r1 * 4 + 200;
        var pos = new List<float> { 0f };
        var cols = new List<Color> { stops[n - 1] };
        for (int i = n - 1; i >= 0; i--)
        {
            double r = r0 + (r1 - r0) * i / (n - 1);
            pos.Add((float)(1 - r / outer));
            cols.Add(stops[i]);
        }
        if (r0 > 0)
        {
            pos.Add(1f);                // 圆心到 r0 之间取首色
            cols.Add(stops[0]);
        }

        using var src = Circle(outer, center.X, center.Y);
        return new PathGradientBrush(src)
        {
            CenterPoint = P(center),
            InterpolationColors = new ColorBlend { Positions = pos.ToArray(), Colors = cols.ToArray() },
        };
    }

    /// 拉丝环：把 conic 渐变拆成 120 个 3° 楔形（每块两侧略重叠防缝）
    private static void DrawConicRing(Graphics g, double outer, double inner, double startDeg, Color[] stops)
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
}
