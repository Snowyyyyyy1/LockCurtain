// PadlockArt.cs —— 遮罩上的挂锁图案（从 Sources/ArtPresets.swift 的 enum PadlockArt 移植，写法同 MechEye.cs）
//
// 叠片钢挂锁：抛光钢锁梁、一片片叠起来的拉丝钢锁身、四角铆钉、黄铜锁芯。
// 每 7 秒验一次锁：锁芯拧一下，锁梁往下一沉坐实、锁身跟着一震，锁芯回位，一道反光从锁身扫过。
// 整个图案是时间 t 的纯函数，由调用方按帧调用 Draw。

using System.Drawing;
using System.Drawing.Drawing2D;
using static LockCurtain.ArtKit;

namespace LockCurtain;

internal static class PadlockArt
{
    private const double Cycle = 7.0;

    // 锁身矩形（设计坐标）：x -56…56，y -16…70
    private const double BodyX = -56, BodyY = -16, BodyW = 112, BodyH = 86;
    private const double BodyRight = BodyX + BodyW, BodyBottom = BodyY + BodyH;

    private static readonly V Plug = new(0, 34);   // 锁芯圆心

    /// 把整个图案画进 (0,0)-(side,side) 的方块里，同一个 t 画出同一帧
    public static void Draw(Graphics g, float side, double t)
    {
        float s = side / 240f;                 // 与 Swift 的 min(size)/240 一致

        GraphicsState st = g.Save();
        g.TranslateTransform(side / 2f, side / 2f);
        g.ScaleTransform(s, s);
        g.TranslateTransform(0, 10);           // 锁梁在上，整体视觉中心往下挪一点

        double tau = t - Math.Floor(t / Cycle) * Cycle;
        double turn = 38 * (Spring(tau, 30, 0.55) - Spring(tau - 0.75, 26, 0.5));
        double seat = 3 * (Spring(tau - 0.3, 60, 0.4) - Spring(tau - 0.5, 30, 0.45));
        double hit = tau - 0.32;
        double shake = hit > 0 ? 1.1 * Math.Exp(-hit * 10) * Math.Sin(hit * 75) : 0;
        double glow = 0.55 + 0.25 * Math.Sin(t * 2 * Math.PI / 3.2) + 0.4 * Math.Max(0, 1 - Math.Abs(tau - 0.4) / 0.4);

        // 锁身震动：锁梁、锁身、锁芯、反光都在同一个平移里
        GraphicsState lockState = g.Save();
        g.TranslateTransform((float)(shake * 0.3), (float)shake);
        DrawShackle(g, seat);
        DrawBody(g);
        DrawPlug(g, turn, glow);
        DrawShine(g, tau);
        g.Restore(lockState);

        g.Restore(st);
    }

    // MARK: - 绘制

    /// 锁梁：粗钢棒弯成 U 形，按圆柱打光：左腿和顶上外侧亮、右腿里侧亮
    private static void DrawShackle(Graphics g, double drop)
    {
        double y0 = BodyY + 6, top = BodyY - 30 + drop, r = 36;

        using (var bar = Shackle(r, top, y0, 180, 360, true, true))
        {
            // 投影：原版是半径 6、偏移 (2,5)、黑 0.5 的模糊阴影。GDI+ 没有模糊，
            // 用三圈向外变宽、透明度递减的偏移粗线叠出软边
            GraphicsState sh = g.Save();
            g.TranslateTransform(2, 5);
            foreach (var (grow, a) in new[] { (6.0, 0.08), (3.0, 0.12), (0.0, 0.2) })
                StrokeSolid(g, bar, Black(a), (float)(17 + 2 * grow));
            g.Restore(sh);

            StrokeSolid(g, bar, Rgb(0x33373D), 17);   // 锁梁暗色底
            using (var br = Linear(-40, top - 40, 40, y0,
                                   Even(Rgb(0xEEF1F5), Rgb(0xA4ABB5), Rgb(0x6A7079), Rgb(0x9097A1))))
            using (var pen = new Pen(br, 14.5f))
                g.DrawPath(pen, bar);
        }

        using (var hl = Shackle(r + 3.6, top, y0, 180, 290, true, false))
            StrokeRound(g, hl, White(0.75), 2.2f);
        using (var hl = Line(new V(r - 3.6, top + 4), new V(r - 3.6, y0)))
            StrokeRound(g, hl, White(0.45), 1.6f);
        using (var sh = Shackle(r + 4, top, y0, 310, 360, false, true))
            StrokeRound(g, sh, Black(0.35), 2.4f);
        using (var sh = Shackle(r - 4, top, y0, 200, 300, false, false))
            StrokeRound(g, sh, Black(0.25), 2f);
    }

    /// 锁身：9 片拉丝钢叠起来，每片反光位置略错开；两侧压暗显出厚度；四角铆钉；锁梁入口的护圈
    private static void DrawBody(Graphics g)
    {
        using var shape = RoundedRect(BodyX, BodyY, BodyW, BodyH, 9);

        // 投影：原版是半径 9、向下偏移 6、黑 0.55 的模糊阴影。用三圈向下偏移、逐圈变窄的半透明圆角矩形近似
        foreach (var (grow, a) in new[] { (9.0, 0.06), (4.5, 0.10), (0.0, 0.18) })
        using (var halo = RoundedRect(BodyX - grow, BodyY - grow + 6, BodyW + 2 * grow, BodyH + 2 * grow, 9 + grow))
            FillSolid(g, halo, Black(a));
        FillSolid(g, shape, Rgb(0x6E737C));

        // 叠片：裁到锁身圆角里
        GraphicsState clip = g.Save();
        g.SetClip(shape, CombineMode.Intersect);
        var sheen = Even(Rgb(0x7C838D), Rgb(0xC9CED5), Rgb(0xEEF1F4), Rgb(0xA3AAB3), Rgb(0xD3D8DE), Rgb(0x8A919B));
        const int n = 9;
        double h = BodyH / n;
        for (int k = 0; k < n; k++)
        {
            double y = BodyY + k * h;
            double shift = (Rand(k, 41) - 0.5) * 22;
            using (var plate = Rect(BodyX, y, BodyW, h))
            using (var br = Linear(BodyX + shift, 0, BodyRight + shift, 0, sheen))
                g.FillPath(br, plate);
            using (var topEdge = Line(new V(BodyX, y + 0.5), new V(BodyRight, y + 0.5)))
                StrokeSolid(g, topEdge, White(0.5), 0.8f);
            using (var bottomEdge = Line(new V(BodyX, y + h - 0.4), new V(BodyRight, y + h - 0.4)))
                StrokeSolid(g, bottomEdge, Black(0.45), 0.8f);
        }

        // 两侧压暗：渐变端点在锁身左右边缘，中间 12%…88% 透明
        using (var fade = Rect(BodyX, BodyY, BodyW, BodyH))
        using (var br = Linear(BodyX, 0, BodyRight, 0,
                               (Black(0.35), 0.0), (Clear, 0.12), (Clear, 0.88), (Black(0.45), 1.0)))
            g.FillPath(br, fade);
        g.Restore(clip);

        StrokeSolid(g, shape, Black(0.5), 1);

        // 四角铆钉：先画一圈偏移的阴影，再画球面
        foreach (double x in new[] { BodyX + 9, BodyRight - 9 })
            foreach (double y in new[] { BodyY + 9, BodyBottom - 9 })
            {
                using (var shadow = Circle(4.3, x + 0.6, y + 1))
                    FillSolid(g, shadow, Black(0.35));
                Sphere(g, new V(x, y), 3.8);
            }

        // 锁梁入口的护圈：两个小圆角条压在锁身顶边上
        foreach (double x in new[] { -36.0, 36 })
        {
            using var collar = RoundedRect(x - 11, BodyY - 3.5, 22, 7.5, 3.5);
            using (var br = Linear(x, BodyY - 3.5, x, BodyY + 4,
                                   Even(Rgb(0xF4F6F9), Rgb(0x8C929B), Rgb(0x5A6068))))
                g.FillPath(br, collar);
            StrokeSolid(g, collar, Black(0.4), 0.8f);
        }
    }

    /// 黄铜锁芯：下凹的钢外壳 + 车削纹黄铜芯 + 锁孔，锁孔里透出一点橙光
    private static void DrawPlug(Graphics g, double turn, double glow)
    {
        V c = Plug;

        using (var shell = Circle(19.5, c.X, c.Y))
        using (var br = Radial(c + new V(-5, -6), 0, 26, Rgb(0x5A6068), Rgb(0xB9BFC7)))
            g.FillPath(br, shell);
        using (var rim = Circle(19.5, c.X, c.Y))
        using (var br = Bevel(19.5, c, 0.55, 0.45))
        using (var pen = new Pen(br, 1.4f))
            g.DrawPath(pen, rim);
        using (var inner = Circle(15.6, c.X, c.Y))
        using (var br = Bevel(15.6, c, 0.35, 0.6, inset: true))
        using (var pen = new Pen(br, 1.4f))
            g.DrawPath(pen, inner);

        using (var disk = Circle(14.6, c.X, c.Y))
        using (var br = Radial(c + Light * 6, 0, 22, Rgb(0xFBE7B0), Rgb(0xD6A54C), Rgb(0x8A611F)))
            g.FillPath(br, disk);
        for (double rr = 4.0; rr < 14.5; rr += 1.5)
        {
            using var groove = Circle(rr, c.X, c.Y);
            StrokeSolid(g, groove, Black(0.06), 0.5f);
        }
        using (var edge = Circle(14.7, c.X, c.Y))
            StrokeSolid(g, edge, Black(0.6), 0.8f);

        // 锁孔：随锁芯转动。三块矩形（一圆角条 + 两个小台阶）取非零并集
        GraphicsState k = g.Save();
        g.TranslateTransform((float)c.X, (float)c.Y);
        g.RotateTransform((float)turn);

        using (var slot = new GraphicsPath(FillMode.Winding))
        {
            AddRoundedRect(slot, -1.9, -11, 3.8, 21, 1.5);
            AddRect(slot, -1.9, -5, 5.4, 2.6);
            AddRect(slot, -3.5, 2.5, 3.6, 2.6);
            FillSolid(g, slot, Rgb(0x15171B));

            // 锁孔里的橙光：径向渐变裁到锁孔内
            GraphicsState ember = g.Save();
            g.SetClip(slot, CombineMode.Intersect);
            using (var glowDisk = Circle(12))
            using (var br = Radial(new V(0, 0), 0, 12,
                                   Rgb(0xFF7A2A, Math.Min(1, 0.85 * glow)), Rgb(0xB0200A, 0.4 * glow), Clear))
                g.FillPath(br, glowDisk);
            g.Restore(ember);
        }
        using (var dot = Circle(1.1, 0, -12.8))
            FillSolid(g, dot, Black(0.55));

        g.Restore(k);
    }

    /// 反光：锁梁坐实之后，一条斜带 0.9 秒从左扫到右
    private static void DrawShine(Graphics g, double tau)
    {
        double k = (tau - 0.9) / 0.9;
        if (!(k > 0 && k < 1)) return;

        GraphicsState st = g.Save();
        using (var clip = RoundedRect(BodyX, BodyY, BodyW, BodyH, 9))
            g.SetClip(clip, CombineMode.Intersect);

        double x = -110 + 220 * Smoothstep(k);
        double a = 0.35 * Math.Sin(k * Math.PI);
        // 原版是 plusLighter 混合 + 半径 5 的模糊。GDI+ 没有这两者：改用普通白色半透明叠三条宽度不同的带，外圈淡、内圈浓
        foreach (var (grow, f) in new[] { (5.0, 0.15), (2.5, 0.4), (0.0, 1.0) })
        {
            using var band = Band(x, grow);
            FillSolid(g, band, White(a * f));
        }

        g.Restore(st);
    }

    // MARK: - 几何辅助

    /// 锁梁的一段：有左腿、右腿时接上直线；中间是圆心 (0, top)、半径 rr 的圆弧，从 from 扫到 to（度，与 SwiftUI 同向）
    private static GraphicsPath Shackle(double rr, double top, double y0, double from, double to, bool leftLeg, bool rightLeg)
    {
        var p = new GraphicsPath();
        if (leftLeg) p.AddLine(P(-rr, y0), P(-rr, top));
        p.AddArc((float)-rr, (float)(top - rr), (float)(2 * rr), (float)(2 * rr), (float)from, (float)(to - from));
        if (rightLeg) p.AddLine(P(rr, top), P(rr, y0));
        return p;
    }

    /// 带圆角的线条描边（端点圆头），用于锁梁的高光和暗边
    private static void StrokeRound(Graphics g, GraphicsPath path, Color c, float width)
    {
        using var pen = new Pen(c, width) { StartCap = LineCap.Round, EndCap = LineCap.Round };
        g.DrawPath(pen, path);
    }

    private static GraphicsPath Rect(double x, double y, double w, double h)
    {
        var p = new GraphicsPath();
        AddRect(p, x, y, w, h);
        return p;
    }

    /// 矩形（顺时针，和 AddRoundedRect 同向，同一路径里才能非零并集）
    private static void AddRect(GraphicsPath p, double x, double y, double w, double h) =>
        p.AddPolygon(new[] { P(x, y), P(x + w, y), P(x + w, y + h), P(x, y + h) });

    /// 反光带：斜四边形，底边在锁身下方、顶边在锁身上方；grow 让两条斜边各外扩，用来近似模糊的软边
    private static GraphicsPath Band(double x, double grow)
    {
        double bottom = BodyBottom + 4, top = BodyY - 4;
        var p = new GraphicsPath();
        p.AddPolygon(new[]
        {
            P(x - 14 - grow, bottom), P(x + 14 + grow, bottom),
            P(x + 54 + grow, top), P(x + 26 - grow, top),
        });
        return p;
    }
}
