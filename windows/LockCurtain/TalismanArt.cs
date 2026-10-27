// TalismanArt.cs —— 遮罩上的镇宅符图案（从 Sources/ArtPresets.swift 的 enum TalismanArt 移植，第 742–1012 行）
//
// 朱砂写在一张毛边黄纸上：纸绕上边中点轻轻摆，笔画按顺序一笔一笔写下去，写完后整张纸亮一下、余光慢慢散。
// 笔画是照着影印本描下来的，坐标不做简化。整个图案是时间 t 的纯函数，由调用方按帧调用 Draw。
// 模糊、混合模式、软边裁剪都走 Layer（见 ArtLayer.cs）。

using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Linq;
using static LockCurtain.ArtKit;

namespace LockCurtain;

internal static class TalismanArt
{
    public const double Cycle = 14.0, Still = 10.0;   // 周期；停在一帧时取周期里的这一刻：写完了、余光还在

    private const uint Cinnabar = 0xC42218;

    /// 纸面：中心在原点，92 × 212
    private static readonly RectangleF Paper = new(-46, -106, 92, 212);

    /// 书写时段（周期内）
    private static readonly (double Start, double End) Writing = (0.5, 7.5);

    private sealed record Stroke(V[] Pts, double Width, bool Smooth = false);

    /// 写完的笔画形状是固定的，先算好（不释放）；正在写的那一笔每帧现算
    private sealed class Shape : IDisposable
    {
        public GraphicsPath? Body;                           // 不到两个截面时为空
        public GraphicsPath Caps = new(FillMode.Winding);    // 两头的圆
        public V Tip;
        public void Dispose() { Body?.Dispose(); Caps.Dispose(); }
    }

    // 静态字段按声明顺序初始化，依赖关系：Strokes → Shapes、Schedule
    private static readonly Stroke[] Strokes = BuildStrokes();
    private static readonly Shape[] Shapes = Strokes.Select(s => BrushShape(s, 1)).ToArray();
    private static readonly (double Start, double End)[] Schedule = BuildSchedule();
    private static readonly GraphicsPath Sheet = BuildSheet();

    /// 原图坐标（影印本裁图上的像素）换到纸面坐标
    private static V Src(double x, double y) => new((x - 169.5) * 0.33, (y - 398.5) * 0.33);

    private static Stroke[] BuildStrokes()
    {
        var s = new List<Stroke>();
        void line(params (double X, double Y)[] p) => s.Add(new Stroke(p.Select(q => Src(q.X, q.Y)).ToArray(), 1.6));
        void curve(params (double X, double Y)[] p) => s.Add(new Stroke(p.Select(q => Src(q.X, q.Y)).ToArray(), 1.6, true));
        /// 星点：从正上方起顺时针一圈
        void star(double x, double y) => s.Add(new Stroke(
            Enumerable.Range(0, 25).Select(k => Src(x + 6 * Math.Sin(k * Math.PI / 12), y - 6 * Math.Cos(k * Math.PI / 12))).ToArray(), 1.2));
        /// 两点之间的连线，碰到星点的一头留出星的半径
        void link((double X, double Y) a, (double X, double Y) b, bool fromStar = true, bool toStar = true)
        {
            double len = Math.Sqrt((b.X - a.X) * (b.X - a.X) + (b.Y - a.Y) * (b.Y - a.Y));
            double ux = (b.X - a.X) / len, uy = (b.Y - a.Y) / len;
            double ra = fromStar ? 6.0 : 0, rb = toStar ? 6.0 : 0;
            line((a.X + ux * ra, a.Y + uy * ra), (b.X - ux * rb, b.Y - uy * rb));
        }
        /// 日字框：左竖、上横、右竖、中横、下横，四个角往外挑一下；mid 为 null 时是口字
        void box(double x0, double x1, double y0, double? mid, double y1, double? midFrom = null)
        {
            const double d = 3.0;
            line((x0, y0), (x0, y1));
            line((x0 - d, y0 - d), (x0, y0), (x1, y0), (x1 + d, y0 - d));
            line((x1, y0), (x1, y1));
            if (mid is double m) line((midFrom ?? x0, m), (x1, m));
            line((x0 - d, y1 + d), (x0, y1), (x1, y1), (x1 + d, y1 + d));
        }
        void left(double y0, double mid, double y1, double? midFrom = null) => box(77.5, 135, y0, mid, y1, midFrom);
        void right(double y0, double mid, double y1) => box(207, 261.5, y0, mid, y1);

        // 星点和连线
        star(75.6, 136); link((75.6, 136), (253.4, 135.3)); star(253.4, 135.3);
        star(75.3, 167); link((75.3, 167), (122, 148.4)); star(122, 148.4); link((122, 148.4), (168.4, 164.7)); star(168.4, 164.7);
        var ul = (115.4, 186.3); var ur = (219.3, 185.9); var cc = (167.5, 207.2); var ll = (115.4, 227.5); var lr = (220.8, 227.5);
        star(ul.Item1, ul.Item2); link(ul, cc); star(cc.Item1, cc.Item2); link(cc, lr); star(lr.Item1, lr.Item2);
        star(ll.Item1, ll.Item2); link(ll, cc); link(cc, ur); star(ur.Item1, ur.Item2);
        foreach (var y in new[] { 203.0, 235 }) star(75.3, y);
        star(77, 274.4);
        foreach (var y in new[] { 168.4, 203, 237 }) star(252.3, y);
        star(256.6, 273.4);
        link((93.4, 269), (135.6, 255.6), fromStar: false); star(135.6, 255.6); link((135.6, 255.6), (203, 276)); star(203, 276);

        // 第一行：日、共、己字回折
        left(289.3, 309, 328.6, midFrom: 82);
        line((141, 295), (195.6, 295)); line((156, 283.6), (156, 309)); line((178.8, 283.6), (178.8, 309));
        line((139, 313.6), (195.6, 313.6)); line((157, 321), (147, 332.4)); line((175, 321), (190, 332.4));
        line((199.2, 286.7), (207.1, 292.2), (261.5, 292.2), (264.6, 288.6)); line((261.5, 292.2), (261.5, 310), (264.6, 315.5));
        line((199.8, 304.4), (207.1, 310), (261.5, 310)); line((207.1, 310), (207.1, 330.1), (203.4, 333.8));
        line((207.1, 330.1), (261.5, 330.1));
        // 第二行：日、罒、缺左上角的日
        left(345.5, 364.6, 382);
        line((145, 345.5), (145, 363)); line((145, 345.5), (197.5, 345.5), (197.5, 363));
        line((162, 345.5), (162, 363)); line((176, 345.5), (176, 363)); line((145, 363), (197.5, 363));
        line((265.2, 325.2), (261.5, 330.1), (261.5, 380.9), (269.5, 386.4)); line((201.6, 350.3), (205.9, 354), (261.5, 354));
        line((207.1, 354), (207.1, 380.9)); line((203.4, 383.9), (207.1, 380.9), (261.5, 380.9));
        // 第三行：日、非、日
        left(397, 412.6, 429);
        line((162, 365), (162, 421), (159.5, 427));
        foreach (var y in new[] { 379.0, 395, 407.4 }) line((143, y), (162, y));
        line((178, 365), (178, 426));
        foreach (var y in new[] { 375.5, 391.4, 405.5 }) line((178, y), (192, y));
        right(395, 412, 428);
        // 第四到第八行：左右都是日字框，中间日、生、大、土、口
        left(443, 458.4, 474, midFrom: 85); box(151.6, 189, 435.5, 455.2, 476.8); right(443, 459, 473);
        left(489.3, 505.2, 522);
        line((152, 491), (146, 502)); line((149, 495), (190, 495)); line((149.7, 512.7), (190, 512.7));
        line((169.4, 478), (169.4, 528.6)); line((145, 528.6), (193.8, 528.6));
        right(489.3, 505.2, 521);
        left(537, 554, 569.5);
        line((143, 554), (193.8, 554)); line((169.4, 536), (169.4, 558.6));
        curve((167.5, 561.4), (157.2, 568), (152.5, 583), (147.8, 597)); curve((175, 562.4), (186.3, 568), (190, 583), (198.4, 598));
        right(536, 552, 569);
        left(585, 601.8, 617.7);
        line((145, 606.4), (195.6, 606.4)); line((169.4, 593), (169.4, 620.5)); line((148.8, 619.6), (190, 619.6));
        right(584, 601.8, 616.8);
        left(631.8, 647.7, 663.6); box(154.4, 189, 631.8, null, 659); right(631.8, 647.7, 663.6);
        return s.ToArray();
    }

    /// 每一笔开始和写完的时刻（周期内）：先按长度排出时长（太短的也给一点时间），笔与笔之间稍停，再整体缩放到书写时段里
    private static (double Start, double End)[] BuildSchedule()
    {
        double t = 0;
        var raw = new (double Start, double End)[Strokes.Length];
        for (int i = 0; i < Strokes.Length; i++)
        {
            var pts = Strokes[i].Pts;
            double len = 0;
            for (int j = 1; j < pts.Length; j++) len += Dist(pts[j - 1], pts[j]);
            double d = Math.Max(0.05, len / 300);
            raw[i] = (t, t + d);
            t += d + 0.03;
        }
        double k = (Writing.End - Writing.Start) / raw[^1].End;
        return raw.Select(r => (Writing.Start + r.Start * k, Writing.Start + r.End * k)).ToArray();
    }

    /// 毛边纸：长边每隔几个单位抖一点
    private static GraphicsPath BuildSheet()
    {
        double x0 = Paper.Left, x1 = Paper.Right, y0 = Paper.Top, y1 = Paper.Bottom;
        static double J(int i) => (Rand(i, 95) - 0.5) * 1.2;
        var pts = new List<PointF>();
        for (int i = 0; i <= 11; i++) pts.Add(P(x0 + (x1 - x0) * i / 11.0, y0 + J(i)));
        for (int i = 1; i <= 26; i++) pts.Add(P(x1 + J(100 + i), y0 + (y1 - y0) * i / 26.0));
        for (int i = 1; i <= 11; i++) pts.Add(P(x1 - (x1 - x0) * i / 11.0, y1 + J(200 + i)));
        for (int i = 1; i < 26; i++) pts.Add(P(x0 + J(300 + i), y1 - (y1 - y0) * i / 26.0));
        var p = new GraphicsPath();
        p.AddPolygon(pts.ToArray());
        return p;
    }

    /// 把整个图案画进 (0,0)-(side,side) 的方块里；同一个 t 画出同一帧。
    public static void Draw(Graphics g, float side, double t)
    {
        using var c = Layer.Canvas(side);
        double tc = t % Cycle;
        // 纸绕上边中点轻轻摆，整张上下浮
        c.G.TranslateTransform(0, (float)(2.5 * Math.Sin(t * 2 * Math.PI / 4.3) + Paper.Top));
        c.G.RotateTransform((float)(1.3 * Math.Sin(t * 2 * Math.PI / 6.5)));
        c.G.TranslateTransform(0, (float)-Paper.Top);
        DrawPaper(c);

        double done = Schedule[^1].End;
        double fade = 1 - Smoothstep((tc - Cycle + 1.4) / 1.0);
        double charge = tc < done ? 0 : (Math.Exp(-(tc - done) / 0.35) + 0.18 + 0.1 * Math.Sin((tc - done) * 2 * Math.PI / 2.4)) * fade;

        // 余光：整张纸的边缘泛橙光
        if (charge > 0)
        {
            using var aura = c.Sub();
            using (var pen = new Pen(Rgb(0xFFB14A, 0.6 * charge), 4f))
                aura.G.DrawPath(pen, Sheet);
            aura.Blur(8);
            c.Composite(aura, Blend.PlusLighter);
        }

        // 墨色：朱砂吃进纸里
        if (fade > 0)
        {
            using var ink = c.Sub();
            Paint(ink, tc, Rgb(Cinnabar), i => 1);
            c.Composite(ink, Blend.Multiply, fade);
        }

        // 刚写下的笔画发烫，过半秒冷下来；写完整张一起亮
        using (var glow = c.Sub())
        {
            Paint(glow, tc, Rgb(0xFFA43C), i =>
                Math.Min(1, (tc < Schedule[i].End ? 1 : Math.Exp(-(tc - Schedule[i].End) / 0.5)) * fade + charge));
            glow.Blur(3);
            c.Composite(glow, Blend.PlusLighter);
        }

        // 笔尖
        for (int i = 0; i < Strokes.Length; i++)
        {
            if (!(tc >= Schedule[i].Start && tc < Schedule[i].End)) continue;
            double f = (tc - Schedule[i].Start) / (Schedule[i].End - Schedule[i].Start);
            using var b = BrushShape(Strokes[i], f);
            using (var hot = c.Sub())
            {
                using var dot = Circle(3.5, b.Tip.X, b.Tip.Y);
                FillSolid(hot.G, dot, Rgb(0xFFE2A0, 0.9));
                hot.Blur(2);
                c.Composite(hot, Blend.PlusLighter);
            }
            using var core = Circle(1.1, b.Tip.X, b.Tip.Y);
            FillSolid(c.G, core, White(0.9));
        }

        c.DrawTo(g);
    }

    /// 把已经写到的部分画出来；alpha(i) 是第 i 笔的不透明度
    private static void Paint(Layer l, double tc, Color color, Func<int, double> alpha)
    {
        for (int i = 0; i < Strokes.Length; i++)
        {
            if (!(tc > Schedule[i].Start)) continue;
            double f = (tc - Schedule[i].Start) / (Schedule[i].End - Schedule[i].Start);
            Color col = Scaled(color, alpha(i));
            if (f >= 1) FillShape(l.G, Shapes[i], col);
            else
            {
                using var b = BrushShape(Strokes[i], f);
                FillShape(l.G, b, col);
            }
        }
    }

    private static Color Scaled(Color c, double k) => Color.FromArgb(A(k * c.A / 255.0), c);

    private static void FillShape(Graphics g, Shape s, Color c)
    {
        if (s.Body != null) FillSolid(g, s.Body, c);
        FillSolid(g, s.Caps, c);
    }

    private static void DrawPaper(Layer c)
    {
        // 投影：偏移 (3, 7)，模糊 9，黑 50%
        using (var sh = c.Sub())
        {
            sh.G.TranslateTransform(3, 7);
            FillSolid(sh.G, Sheet, Black(0.5));
            sh.Blur(9);
            c.Composite(sh, Blend.Normal);
        }
        FillSolid(c.G, Sheet, Rgb(0xE2B84E));
        using (var br = Linear(Paper.Left, Paper.Top, Paper.Right, Paper.Bottom,
                               Even(Rgb(0xF6DC86), Rgb(0xE8BE55), Rgb(0xCF9A35))))
            c.G.FillPath(br, Sheet);
        // 纸面微微拱起：两边暗一点，靠左那条亮一点
        using (var br = Linear(Paper.Left, 0, Paper.Right, 0,
                               (Black(0.1), 0.0), (White(0.08), 0.3), (Clear, 0.6), (Black(0.16), 1.0)))
            c.G.FillPath(br, Sheet);

        // 纸纤维：不模糊，但要裁在纸内
        using (var fib = c.Sub())
        {
            var dark = new GraphicsPath();
            var bright = new GraphicsPath();
            for (int i = 0; i < 180; i++)
            {
                V ctr = new(Paper.Left + Paper.Width * Rand(i, 91), Paper.Top + Paper.Height * Rand(i, 92));
                V d = Polar(1.5 + 3.5 * Rand(i, 94), 360 * Rand(i, 93));
                var path = i % 2 == 0 ? dark : bright;
                path.StartFigure();
                path.AddLine(P(ctr - d), P(ctr + d));
            }
            using (var pd = new Pen(Rgb(0x9A6A1C, 0.22), 0.5f)) fib.G.DrawPath(pd, dark);
            using (var pb = new Pen(Rgb(0xFFF3C4, 0.3), 0.5f)) fib.G.DrawPath(pb, bright);
            dark.Dispose();
            bright.Dispose();
            fib.Clip(Sheet);
            c.Composite(fib, Blend.Normal);
        }

        // 边缘做旧，往里晕一圈褐色：先模糊再裁
        using (var edge = c.Sub())
        {
            using (var pen = new Pen(Rgb(0x7A4A10, 0.45), 7f)) edge.G.DrawPath(pen, Sheet);
            edge.Blur(4);
            edge.Clip(Sheet);
            c.Composite(edge, Blend.Normal);
        }

        // 印好的朱砂边框：正片叠底，吃进纸里
        using (var frame = c.Sub())
        {
            using (var p1 = new Pen(Rgb(Cinnabar, 0.9), 1.6f))
            using (var outer = RectPath(RectangleF.Inflate(Paper, -6, -6)))
                frame.G.DrawPath(p1, outer);
            using (var p2 = new Pen(Rgb(Cinnabar, 0.8), 0.6f))
            using (var inner = RectPath(RectangleF.Inflate(Paper, -9, -9)))
                frame.G.DrawPath(p2, inner);
            c.Composite(frame, Blend.Multiply);
        }
    }

    private static GraphicsPath RectPath(RectangleF r)
    {
        var p = new GraphicsPath();
        p.AddRectangle(r);
        return p;
    }

    private static double Dist(V a, V b) => Math.Sqrt((b.X - a.X) * (b.X - a.X) + (b.Y - a.Y) * (b.Y - a.Y));

    private static double CatmullRom(double a, double b, double c, double d, double u, double u2, double u3) =>
        0.5 * (2 * b + (c - a) * u + (2 * a - 5 * b + 4 * c - d) * u2 + (3 * b - a - 3 * c + d) * u3);

    /// Catmull-Rom 插值，让笔画顺滑地经过每个点
    private static List<V> Spline(V[] p)
    {
        var o = new List<V>();
        for (int i = 0; i < p.Length - 1; i++)
        {
            V p0 = p[Math.Max(i - 1, 0)], p1 = p[i], p2 = p[i + 1], p3 = p[Math.Min(i + 2, p.Length - 1)];
            for (int s = 0; s < 8; s++)
            {
                double u = s / 8.0, u2 = u * u, u3 = u2 * u;
                o.Add(new V(CatmullRom(p0.X, p1.X, p2.X, p3.X, u, u2, u3),
                            CatmullRom(p0.Y, p1.Y, p2.Y, p3.Y, u, u2, u3)));
            }
        }
        o.Add(p[^1]);
        return o;
    }

    /// 折线按 2 个单位一段加密，好让笔宽沿长度变化；转角处的点保留，转角还是尖的
    private static List<V> Densify(V[] p)
    {
        var o = new List<V> { p[0] };
        for (int i = 0; i + 1 < p.Length; i++)
        {
            V a = p[i], b = p[i + 1];
            int n = Math.Max(1, (int)Math.Ceiling(Dist(a, b) / 2));
            for (int k = 1; k <= n; k++) o.Add(a + (b - a) * ((double)k / n));
        }
        return o;
    }

    /// 笔画：起笔略重、收笔稍提的一条带子，两头是圆的；只画前 f（0…1），顺便给出笔尖位置
    private static Shape BrushShape(Stroke st, double f)
    {
        var s = st.Smooth ? Spline(st.Pts) : Densify(st.Pts);
        var acc = new double[s.Count];
        for (int i = 1; i < s.Count; i++) acc[i] = acc[i - 1] + Dist(s[i - 1], s[i]);
        double total = acc[^1], end = total * f;
        var left = new List<V>();
        var right = new List<V>();
        var caps = new List<(V C, double R)>();
        for (int i = 0; i < s.Count; i++)
        {
            V c = s[i];
            double d = acc[i];
            if (d > end && i > 0)
            {
                double k = (end - acc[i - 1]) / (d - acc[i - 1]);
                c = s[i - 1] + (c - s[i - 1]) * k;
                d = end;
            }
            V a = s[Math.Max(i - 1, 0)], b = s[Math.Min(i + 1, s.Count - 1)];
            double len = Math.Max(Dist(a, b), 0.001);
            double u = total > 0 ? d / total : 0;
            double r = st.Width / 2 * (1.1 - 0.15 * Smoothstep(u / 0.2)) * (1 - 0.45 * Smoothstep((u - 0.75) / 0.25));
            double ox = (b.Y - a.Y) / len * r, oy = (b.X - a.X) / len * r;
            left.Add(new V(c.X - ox, c.Y + oy));
            right.Add(new V(c.X + ox, c.Y - oy));
            if (i == 0 || d >= end) caps.Add((c, r));
            if (d >= end) break;
        }

        var shape = new Shape();
        if (left.Count >= 2)
        {
            var pts = new List<V>(left);
            for (int i = right.Count - 1; i >= 0; i--) pts.Add(right[i]);
            shape.Body = new GraphicsPath(FillMode.Winding);
            shape.Body.AddPolygon(pts.Select(v => P(v)).ToArray());
        }
        foreach (var (c, r) in caps)
        {
            shape.Caps.StartFigure();
            AddCircle(shape.Caps, r, c.X, c.Y);
        }
        shape.Tip = caps[^1].C;
        return shape;
    }
}
