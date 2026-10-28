// DemonEyeArt.cs —— 遮罩上的魔瞳图案（从 Sources/ArtPresets.swift 的 enum DemonEye 移植，第 589–735 行）
//
// 竖着的杏仁形眼眶里一只发光的竖瞳，背后一圈慢慢转的符文法阵。
// 眼珠沿用机械眼的注视节奏（MechEye.PoseAt），上下转得多、左右转得少；转眼时竖瞳先张开、再收窄对焦；偶尔眨一下眼。
// 有人动鼠标时同机械眼一样转过去盯着光标（见 MechEye.Stare）。
// 整个图案是时间 t 的纯函数，由调用方按帧调用 Draw。

using System.Drawing;
using System.Drawing.Drawing2D;
using static LockCurtain.ArtKit;

namespace LockCurtain;

internal static class DemonEye
{
    internal readonly record struct Pose(V Gaze, double Slit, double Open, double Glow);

    /// 眼珠、竖瞳、眼睑和发光强度。注视直接用机械眼的，再按魔瞳的比例压扁、拉长
    internal static Pose PoseAt(double t, MechEye.Stare? stare = null)
    {
        var p = MechEye.PoseAt(t, stare);
        int i = MechEye.SlotIndex(t);
        double tau = t - MechEye.MoveTime(i);
        double slit = 3.5 + 3.5 * Rand(i, 8) + 7 * MechEye.Kick(tau, 0.15);
        double open = 1.0;
        if (Rand(i, 7) < 0.18)
        {
            double b = tau - 1.0;
            if (b > 0 && b < 0.07) open = 1 - b / 0.07;
            else if (b >= 0.07 && b < 0.11) open = 0;
            else if (b >= 0.11) open = Math.Min(1, Spring(b - 0.11, 24, 0.7));
        }
        // 盯光标时竖瞳收窄，每跳一下先张开再收回；不眨眼
        if (stare is { } s)
        {
            double l = MechEye.Lock(t, s);
            slit += (2.5 + 7 * MechEye.Kick(t - s.Hop.T, 0.15) - slit) * l;
            open += (1 - open) * l;
        }
        return new Pose(new V(p.Gaze.X * 0.9, p.Gaze.Y * 1.9), slit, open, p.Glow);
    }

    /// 把整个图案画进 (0,0)-(side,side) 的方块里，同一个 t 画出同一帧。
    /// 调用方已把 g 平移到方块左上角。
    public static void Draw(Graphics g, float side, double t, MechEye.Stare? stare)
    {
        using var c = Layer.Canvas(side);
        var p = PoseAt(t, stare);

        DrawSigil(c, t, p.Glow);
        using var eye = Almond(p.Open);

        // 眼眶外的一圈光晕：加亮混合 + 模糊
        using (var rim = c.Sub())
        {
            using var pen = new Pen(Rgb(0xFF5A1F, 0.55 * p.Glow), 7f);
            rim.G.DrawPath(pen, eye);
            rim.Blur(7);
            c.Composite(rim, Blend.PlusLighter);
        }

        // 眼眶里面：先画内容，再统一裁成眼形
        using (var inside = c.Sub())
        {
            using (var box = new GraphicsPath())
            {
                box.AddRectangle(new RectangleF(-100, -100, 200, 200));
                using var br = Radial(new V(0, 0), 10, 100, Rgb(0x2E0B0D), Rgb(0x0A0203));
                inside.G.FillPath(br, box);
            }

            DrawIris(inside, p);

            // 眼睑压在眼球上的阴影顺着眼眶走，光从左上来，阴影往右下偏；上下眼角压暗
            using (var shade = inside.Sub())
            {
                shade.G.TranslateTransform(1.5f, 2.5f);
                using var pen = new Pen(Black(0.85), 20f);
                shade.G.DrawPath(pen, eye);
                shade.Blur(7);
                inside.Composite(shade, Blend.Normal);
            }

            using (var box = new GraphicsPath())
            {
                box.AddRectangle(new RectangleF(-100, -100, 200, 200));
                using var br = Radial(new V(0, 0), 50, 100, Clear, Black(0.65));
                inside.G.FillPath(br, box);
            }

            inside.Clip(eye);
            c.Composite(inside, Blend.Normal);
        }

        using (var pen = new Pen(Rgb(0x140405), 3f))
            c.G.DrawPath(pen, eye);
        using (var pen = new Pen(Rgb(0xFF8A3D, 0.5), 0.8f))
            c.G.DrawPath(pen, eye);

        c.DrawTo(g);
    }

    /// 竖着的杏仁形眼眶；左右两片眼睑往中间合，open = 0 时合成一条竖线
    internal static GraphicsPath Almond(double open)
    {
        // open 为 0 时控制点全压在中线上，路径退化；裁剪前留一个极小的正值
        open = Math.Max(open, 1e-3);
        var p = new GraphicsPath();
        p.StartFigure();
        QuadTo(p, new V(3, -94), new V(84 * open, -4), new V(-2, 94));
        QuadTo(p, new V(-2, 94), new V(-80 * open, 6), new V(3, -94));
        p.CloseFigure();
        return p;
    }

    /// 二次贝塞尔段（Swift 的 addQuadCurve）：GDI+ 只有三次，控制点按 2/3 换算
    private static void QuadTo(GraphicsPath path, V from, V control, V to)
    {
        path.AddBezier(P(from), P(from + (control - from) * (2.0 / 3)),
                       P(to + (control - to) * (2.0 / 3)), P(to));
    }

    /// 符文法阵：三道细圈夹着一圈 24 个符文，60 秒转一圈，带一层余光。
    /// 每个符文是一根竖笔加上几种附加笔画（横、斜、顶上的小圈、尖角），组合由编号决定
    private static void DrawSigil(Layer c, double t, double glow)
    {
        var st = c.G.Save();
        c.G.RotateTransform((float)(t * 6));

        using var rings = new GraphicsPath();
        foreach (var r in new[] { 114.0, 110.5, 95.5 }) AddCircle(rings, r, 0, 0);

        using var glyphs = new GraphicsPath();
        for (int k = 0; k < 24; k++)
        {
            double baseDeg = k * 15.0;
            V Pt(double u, double v) => Polar(98.5 + v * 9.5, baseDeg + u * 3.2);
            int bits = (int)(Rand(k, 61) * 16);
            glyphs.StartFigure(); glyphs.AddLine(P(Pt(0, 0)), P(Pt(0, 1)));
            if ((bits & 1) != 0) { glyphs.StartFigure(); glyphs.AddLine(P(Pt(-0.8, 0.45)), P(Pt(0.8, 0.45))); }
            if ((bits & 2) != 0) { glyphs.StartFigure(); glyphs.AddLine(P(Pt(0, 0.7)), P(Pt(0.9, 0.2))); }
            if ((bits & 4) != 0)
            {
                glyphs.StartFigure();
                glyphs.AddLines(new[] { P(Pt(-0.9, 1)), P(Pt(0, 0.65)), P(Pt(0.9, 1)) });
            }
            if ((bits & 8) != 0 || bits == 0) { glyphs.StartFigure(); glyphs.AddLine(P(Pt(-0.8, 0)), P(Pt(0, 0.3))); }
            V dot = Polar(102.8, baseDeg + 7.5);
            AddCircle(glyphs, 0.9, dot.X, dot.Y);
        }

        // 余光：加亮混合 + 模糊，画在清晰线条下面
        using (var halo = c.Sub())
        {
            using (var pen = new Pen(Rgb(0xFF5A1F, 0.45 * glow), 2.5f))
                halo.G.DrawPath(pen, rings);
            using (var pen = new Pen(Rgb(0xFF5A1F, 0.55 * glow), 2.5f))
                halo.G.DrawPath(pen, glyphs);
            halo.Blur(3);
            c.Composite(halo, Blend.PlusLighter);
        }

        using (var pen = new Pen(Rgb(0xFFB070, 0.7), 0.8f))
            c.G.DrawPath(pen, rings);
        using (var pen = new Pen(Rgb(0xFFCF9A, 0.9), 1.1f) { StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round })
            c.G.DrawPath(pen, glyphs);

        c.G.Restore(st);
    }

    /// 虹膜：金 → 橙 → 深红的放射纤维，外圈一道暗环；竖瞳边缘发烫；跟着注视方向压扁，假装是球面在转
    private static void DrawIris(Layer layer, Pose p)
    {
        const double r = 44;
        double d = Math.Sqrt(p.Gaze.X * p.Gaze.X + p.Gaze.Y * p.Gaze.Y);
        double dirDeg = Math.Atan2(p.Gaze.Y, p.Gaze.X) * 180 / Math.PI;
        var st = layer.G.Save();
        layer.G.TranslateTransform((float)p.Gaze.X, (float)p.Gaze.Y);
        layer.G.RotateTransform((float)dirDeg);
        layer.G.ScaleTransform((float)(1 - 0.16 * Math.Min(d / (MechEye.MaxGaze * 1.9), 1.2)), 1f);
        layer.G.RotateTransform((float)-dirDeg);

        // 外晕：加亮混合，不模糊
        using (var bloom = layer.Sub())
        {
            using var glow = Radial(new V(0, 0), r - 6, r + 20, Rgb(0xFF5A1F, 0.4 * p.Glow), Clear);
            using var halo = Circle(r + 20);
            bloom.G.FillPath(glow, halo);
            layer.Composite(bloom, Blend.PlusLighter);
        }

        using (var disk = Circle(r))
        using (var br = Radial(new V(0, 0), 0, r,
                               (Rgb(0xFFE08A), 0.0), (Rgb(0xFFA22E), 0.26), (Rgb(0xE8451A), 0.52),
                               (Rgb(0x9E0E12), 0.8), (Rgb(0x2A0204), 1.0)))
            layer.G.FillPath(br, disk);

        // 放射纤维：偶数根亮、奇数根暗
        using (var bright = new GraphicsPath())
        using (var dark = new GraphicsPath())
        {
            for (int k = 0; k < 120; k++)
            {
                double a = k * 3 + 2 * Rand(k, 71);
                double r0 = 8 + 10 * Rand(k, 72), r1 = 28 + 14 * Rand(k, 73);
                var path = k % 2 == 0 ? bright : dark;
                path.StartFigure();
                path.AddLine(P(Polar(r0, a)), P(Polar(r1, a)));
            }
            using (var pen = new Pen(Rgb(0xFFD27A, 0.35), 0.7f))
                layer.G.DrawPath(pen, bright);
            using (var pen = new Pen(Rgb(0x3A0306, 0.45), 0.8f))
                layer.G.DrawPath(pen, dark);
        }

        using (var collar = new GraphicsPath())
        {
            var pts = new PointF[49];
            for (int k = 0; k <= 48; k++) pts[k] = P(Polar(16 + 2.5 * Rand(k % 48, 74), k * 7.5));
            collar.AddLines(pts);
            using var pen = new Pen(Rgb(0xFFE6A0, 0.4), 0.9f);
            layer.G.DrawPath(pen, collar);
        }

        using (var ring = Circle(r - 1.2))
        using (var pen = new Pen(Black(0.75), 3f))
            layer.G.DrawPath(pen, ring);

        using var slit = new GraphicsPath();
        slit.StartFigure();
        QuadTo(slit, new V(0, -36), new V(p.Slit * 2, 0), new V(0, 36));
        QuadTo(slit, new V(0, 36), new V(-p.Slit * 2, 0), new V(0, -36));

        // 竖瞳边缘发烫：加亮混合 + 模糊，画在黑瞳下面
        using (var hot = layer.Sub())
        {
            using var pen = new Pen(Rgb(0xFFB040, 0.6 * p.Glow), 3.5f);
            hot.G.DrawPath(pen, slit);
            hot.Blur(3);
            layer.Composite(hot, Blend.PlusLighter);
        }
        FillSolid(layer.G, slit, Color.Black);

        // 角膜上的湿润反光，跟着眼珠走
        using (var wet = layer.Sub())
        {
            using var lid = new GraphicsPath();
            lid.AddEllipse(-24f, -27f, 13f, 7f);
            using var spot = Circle(2, 15, 17);
            FillSolid(wet.G, lid, White(0.7));
            FillSolid(wet.G, spot, White(0.35));
            wet.Blur(1.2);
            layer.Composite(wet, Blend.Normal);
        }

        layer.G.Restore(st);
    }
}
