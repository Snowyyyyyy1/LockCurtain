// MechEye.cs —— 遮罩上的机械眼球（从 Sources/MechEye.swift 移植，参考 Lakr233/Sentry 的 EyeView，MIT）
//
// 结构从外到内：金属外壳（刻度 + 螺丝）→ 棘轮齿圈 → 眼窝 → 会转动的眼球
// （橙红虹膜 + 8 片光圈叶片 + 红色指示灯）→ 玻璃罩高光。
// 整只眼是时间 t（和盯光标的状态 Stare）的纯函数，由调用方按帧调用 Draw。
// 动作都是「机械」的：齿圈一格一格跳、眼球快速转到新位置再带一点过冲停住、
// 光圈跟着重新对焦，偶尔整个合上再打开（眨眼）。有人动鼠标时转过去盯着光标。

using System.Drawing;
using System.Drawing.Drawing2D;
using static LockCurtain.ArtKit;

namespace LockCurtain;

internal static class MechEye
{
    // 设计坐标：原点在中心，半径 120 的坐标系（与 Swift 相同）
    internal const double Slot = 1.7;       // 注视点切换的时间片
    internal const double MaxGaze = 15.0;   // 注视点最大偏移

    internal readonly record struct Pose(V Gaze, double Pupil, double Gear, double Iris, double Glow);

    // MARK: - 动作

    /// 每 slot 秒可能换一次注视点，换的时刻在 slot 开头 0.6 秒内随机
    internal static double MoveTime(int i) => i * Slot + 0.6 * Rand(i, 1);

    /// t 时刻看的是第几个注视点：这个 slot 换眼的时刻还没到，就还是上一个
    internal static int SlotIndex(double t)
    {
        int i = (int)Math.Floor(t / Slot);
        return t < MoveTime(i) ? i - 1 : i;
    }

    private static V GazeTarget(int i)
    {
        if (Rand(i, 2) < 0.28) return new V(0, 0);             // 时不时回正
        double a = Rand(i, 3) * 2 * Math.PI;
        double r = MaxGaze * (0.45 + 0.55 * Rand(i, 4));
        return new V(Math.Cos(a) * r, Math.Sin(a) * r * 0.7);  // 左右看得比上下多
    }

    /// 自己东张西望时的注视点（不含抖动）
    internal static V Wander(double t)
    {
        int i = SlotIndex(t);
        return Lerp(GazeTarget(i - 1), GazeTarget(i), Spring(t - MoveTime(i)));
    }

    internal static V Lerp(V a, V b, double k) => new(a.X + (b.X - a.X) * k, a.Y + (b.Y - a.Y) * k);

    /// 先冲上去再落回来的一下，peak 秒时最大（= 1）
    internal static double Kick(double h, double peak) =>
        h > 0 && double.IsFinite(h) ? h / peak * Math.Exp(1 - h / peak) : 0;

    // MARK: - 盯光标

    /// 有人动鼠标时，眼球转过去盯着光标：光圈收小、指示灯常亮、不眨眼；光标停下 Hold 秒后回去东张西望。
    /// 遮罩每帧把光标位置喂进来。这里只记几个时刻和注视点，所以 PoseAt(t, stare) 仍然只由参数决定
    internal sealed class Stare
    {
        internal const double Hold = 3.0;      // 光标停下多久后回去东张西望
        internal const double Step = 0.15;     // 两跳之间至少隔这么久：光标一直在动时，眼球一小跳一小跳地跟

        internal double Since { get; private set; } = double.NegativeInfinity;      // 这一轮开始盯的时刻
        internal double LastMove { get; private set; } = double.NegativeInfinity;   // 光标最后一次动的时刻
        internal (double T, V From, V To) Hop { get; private set; } = (double.NegativeInfinity, default, default);   // 最近一跳
        private V? cursor;

        /// c 和 eye 都是屏幕坐标（原点在左上，单位是这块屏的逻辑像素），eye 是图案中心
        internal void Feed(double t, V c, V eye)
        {
            V now = Look(t, this);                      // 先记下这一刻的注视点，新的一跳从这里出发
            bool was = t - LastMove < Hold;
            if (cursor is { } last && Dist(c, last) > 0.5) LastMove = t;
            cursor = c;                                 // 第一帧只记位置：遮罩刚盖上时不算有人动
            if (!(t - LastMove < Hold)) return;
            if (!was) Since = t;
            V to = Aim(c, eye);
            if (!was || (Dist(to, Hop.To) > 1 && t - Hop.T > Step)) Hop = (t, now, to);
        }

        /// 朝光标方向看：离得越远转得越多，光标停在眼睛上时直视。屏幕的 y 朝下，和画布一样，不用反过来
        internal static V Aim(V c, V eye)
        {
            double dx = c.X - eye.X, dy = c.Y - eye.Y;
            double d = Math.Sqrt(dx * dx + dy * dy);
            if (d <= 1) return new V(0, 0);
            double r = MaxGaze * (1 - Math.Exp(-d / 200));
            return new V(dx / d * r, dy / d * r * 0.8);
        }

        private static double Dist(V a, V b) => Math.Sqrt((a.X - b.X) * (a.X - b.X) + (a.Y - b.Y) * (a.Y - b.Y));
    }

    /// 注视点（不含抖动）：盯光标时弹到最近一跳的落点，光标停下 Hold 秒后再弹回东张西望
    internal static V Look(double t, Stare? stare)
    {
        V w = Wander(t);
        if (stare is not { } s || double.IsNegativeInfinity(s.Hop.T)) return w;
        V held = Lerp(s.Hop.From, s.Hop.To, Spring(t - s.Hop.T));
        double back = t - s.LastMove - Stare.Hold;
        return back > 0 ? Lerp(held, w, Spring(back)) : held;
    }

    /// 盯人的程度 0..1：开始盯时升到 1，回去东张西望时降回 0
    internal static double Lock(double t, Stare s) =>
        Smoothstep((t - s.Since) / 0.25) * (1 - Smoothstep((t - s.LastMove - Stare.Hold) / 0.4));

    internal static Pose PoseAt(double t, Stare? stare = null)
    {
        int i = SlotIndex(t);
        double tau = t - MoveTime(i);
        // 停住时伺服电机的细微抖动
        V hum = new(Math.Sin(t * 37) * 0.18 + Math.Sin(t * 59) * 0.1, Math.Cos(t * 43) * 0.15);
        V baseGaze = Look(t, stare);
        V gaze = new(baseGaze.X + hum.X, baseGaze.Y + hum.Y);

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

        // 盯人时光圈收小，每跳一下先张开一点再收回去对焦；指示灯常亮，不眨眼
        double glow = 0.72 + 0.28 * Math.Sin(t * 2 * Math.PI / 2.6);
        if (stare is { } s)
        {
            double l = Lock(t, s);
            pupil += (7 + 6 * Kick(t - s.Hop.T, 0.12) - pupil) * l;
            glow += (1 - glow) * l;
        }

        return new Pose(gaze, Math.Max(0, pupil),
                        Ratchet(t, 1.6, 7.5),
                        -Ratchet(t + 0.4, 0.8, 2.5),
                        glow);
    }

    // MARK: - 绘制

    /// 把整只眼画进 (0,0)-(side,side) 的方块里。同一个 t 画出同一帧。
    /// 调用方已设好 SmoothingMode 并把 g 平移到方块左上角。
    public static void Draw(Graphics g, float side, double t, Stare? stare)
    {
        float s = side / 240f;                 // 与 Swift 的 min(size)/240 一致
        Pose p = PoseAt(t, stare);

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

        // 螺丝槽：Swift 原版把 deg * 1.7 当作弧度用，这里保持一致（疑似原作笔误，未修正）
        for (int k = 0; k < 6; k++)
        {
            double deg = 30 + k * 60.0;
            Screw(g, Polar(105, deg), slot: deg * 1.7);
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

        SoftDot(g, new V(-36, -44), 5, 3, White(0.35));

        using (var lensEdge = Circle(79))
        using (var br = Radial(new V(0, 0), 55, 80, Clear, Black(0.35)))
            g.FillPath(br, lensEdge);

        g.Restore(st);
    }

    /// 第 k 条边的方向（正八边形按角度算，开口为 0 时也成立）
    private static V DirOf(double twist, int n, int k)
    {
        double a = twist + (k + 0.5) * 2 * Math.PI / n + Math.PI / 2;
        return new V(Math.Cos(a), Math.Sin(a));
    }
}
