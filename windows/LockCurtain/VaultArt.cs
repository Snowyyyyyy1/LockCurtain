// VaultArt.cs —— 遮罩上的保险库门图案（从 Sources/ArtPresets.swift 的 enum VaultArt 移植，第 301–444 行）
//
// 方形拉丝钢墙板里嵌一扇厚圆门，门中间是船舵式转轮，轮毂是密码盘。
// 密码盘每 1.6 秒拨到一个新数字（左右交替，带过冲），拨完三个数，转轮拧 90° 再回位。
// 整个图案是时间 t 的纯函数，由调用方按帧调用 Draw。

using System.Drawing;
using System.Drawing.Drawing2D;
using static LockCurtain.ArtKit;

namespace LockCurtain;

internal static class VaultArt
{
    // 设计坐标：原点在中心，半径 120 的坐标系（与 Swift 相同）
    private const double Slot = 1.6;   // 每个拨号的时间片

    /// 第 m 次拨号停在的角度
    private static double Stop(int m) => Rand(m, 51) * 360;

    /// 第 m 次拨号拨到一半时的角度：偶数次顺时针、奇数次逆时针，至少转 120°
    private static double DialAngle(int m, double tau)
    {
        double dir = m % 2 == 0 ? 1.0 : -1.0;
        double delta = ((Stop(m) - Stop(m - 1)) * dir) % 360;
        if (delta < 0) delta += 360;
        if (delta < 120) delta += 360;
        return Stop(m - 1) + dir * delta * Spring(tau, 9, 0.7);
    }

    /// 把整个图案画进 (0,0)-(side,side) 的方块里，同一个 t 画出同一帧。
    /// 调用方已设好 SmoothingMode。
    public static void Draw(Graphics g, float side, double t)
    {
        float s = side / 240f;                 // 与 Swift 的 min(size)/240 一致
        GraphicsState st = g.Save();
        g.TranslateTransform(side / 2f, side / 2f);
        g.ScaleTransform(s, s);

        // 一轮 4 段：前 3 段各拨一个数，第 4 段拧转轮
        double cycleLen = 4 * Slot;
        int cycle = (int)Math.Floor(t / cycleLen);
        double within = t - cycle * cycleLen;
        int k = Math.Min(3, (int)Math.Floor(within / Slot));
        double tau = within - k * Slot;
        double dial = k < 3 ? DialAngle(cycle * 3 + k, tau) : DialAngle(cycle * 3 + 2, Slot);
        double wheel = k < 3 ? 0 : 90 * (Spring(tau - 0.1, 14, 0.55) - Spring(tau - 0.8, 14, 0.6));

        DrawWall(g);
        DrawDoor(g);
        DrawWheel(g, wheel);
        DrawDial(g, dial);

        g.Restore(st);
    }

    /// 软阴影近似：圆盘外缘内外各 blur 的范围里，透明度从 alpha 线性降到 0（同 MechEye.DrawHousing 的做法）。
    /// GDI+ 没有模糊，这是近似，不是高斯模糊。
    private static void SoftDiskShadow(Graphics g, double r, V off, double blur, double alpha)
    {
        using var shadow = Circle(r + blur, off.X, off.Y);
        using var br = Radial(off, r - blur, r + blur, Black(alpha), Clear);
        g.FillPath(br, shadow);
    }

    /// 一根方向性的实心条（阴影用，没有金属渐变）
    private static void Bar(Graphics g, V a, V b, double w0, double w1, Color c)
    {
        double len = Math.Sqrt((b.X - a.X) * (b.X - a.X) + (b.Y - a.Y) * (b.Y - a.Y));
        var n = new V(-(b.Y - a.Y) / len, (b.X - a.X) / len);
        using var path = new GraphicsPath();
        path.AddPolygon(new[] { P(a + n * (w0 / 2)), P(b + n * (w1 / 2)), P(b - n * (w1 / 2)), P(a - n * (w0 / 2)) });
        FillSolid(g, path, c);
    }

    /// 墙板：横向拉丝的方形钢板（比门暗一档，把门衬出来）+ 四角螺丝 + 门缝
    private static void DrawWall(Graphics g)
    {
        using var plate = RoundedRect(-108, -108, 216, 216, 28);

        // 投影（原版 radius 10、y 下移 6、透明度 0.55）：GDI+ 没有模糊，用 5 层向外扩张的
        // 圆角矩形叠出软边，每层透明度 0.12，中心处约 0.47，越往外越淡
        for (int i = 0; i < 5; i++)
        {
            double e = 10.0 * (i + 1) / 5;
            using var halo = RoundedRect(-108 - e, -108 - e + 6, 216 + 2 * e, 216 + 2 * e, 28 + e);
            FillSolid(g, halo, Black(0.12));
        }

        FillSolid(g, plate, Rgb(0x6E737C));
        using (var br = Linear(-108, -108, 108, 108,
                               Even(Rgb(0x4F565F), Rgb(0x8A919B), Rgb(0x5E656E), Rgb(0x9AA1AA), Rgb(0x535A63))))
            g.FillPath(br, plate);

        // 拉丝纹：72 条横线，裁在板子里面
        GraphicsState st = g.Save();
        g.SetClip(plate, CombineMode.Intersect);
        using (var lines = new GraphicsPath())
        {
            for (int k = 0; k < 72; k++)
            {
                double y = -108 + k * 3.0;
                lines.StartFigure();
                lines.AddLine(P(-108, y), P(108, y));
            }
            using var pen = new Pen(White(0.06), 0.6f);
            g.DrawPath(pen, lines);
        }
        g.Restore(st);

        using (var br = Bevel(108, hi: 0.6, lo: 0.45))
        using (var pen = new Pen(br, 1.6f))
            g.DrawPath(pen, plate);

        foreach (var (x, y) in new[] { (-1.0, -1.0), (1.0, -1.0), (-1.0, 1.0), (1.0, 1.0) })
            Screw(g, new V(x * 92, y * 92), 4.6, x * y * 0.7);

        using (var hole = Circle(100))
        {
            FillSolid(g, hole, Rgb(0x0A0B0D));
            using var br = Bevel(100, hi: 0.4, lo: 0.7, inset: true);
            using var pen = new Pen(br, 1.6f);
            g.DrawPath(pen, hole);
        }
    }

    /// 门：一圈很宽的抛光斜边显出门的厚度，门面拉丝 + 几道浅车削纹，边缘压暗
    private static void DrawDoor(Graphics g)
    {
        SoftDiskShadow(g, 96, new V(0, 3), 4, 0.6);
        using (var face = Circle(96))
            FillSolid(g, face, Rgb(0x6E737C));

        using (var ring = Ring(96, 84))
        using (var br = Linear(-80, -80, 80, 80, Even(Rgb(0xF4F6F9), Rgb(0xA9AFB8), Rgb(0x5D636B), Rgb(0x8E959E))))
            g.FillPath(br, ring);

        using (var edge = Circle(95.4))
        using (var br = Bevel(95))
        using (var pen = new Pen(br, 1.2f))
            g.DrawPath(pen, edge);
        using (var seam = Circle(84))
        using (var pen = new Pen(Black(0.45), 1.2f))
            g.DrawPath(pen, seam);

        // 门面拉丝：原版是 conic 角向渐变，这里用 DrawConicRing 的楔形（inner=0）近似
        DrawConicRing(g, 83.4, 0, 70, BrushedStops);

        using (var lathe = new GraphicsPath())
        {
            for (int k = 0; k < 4; k++) AddCircle(lathe, 64 + k * 5.0, 0, 0);
            using var pen = new Pen(Black(0.12), 0.8f);
            g.DrawPath(pen, lathe);
        }

        // 门边压暗：径向渐变，半径 50 以内透明，84 处透明度 0.28
        using (var shade = Circle(83.4))
        using (var br = Radial(new V(0, 0), 50, 84, Clear, Black(0.28)))
            g.FillPath(br, shade);
    }

    /// 船舵式转轮：6 根辐条伸出轮缘，末端是握把和球头
    private static void DrawWheel(Graphics g, double angle)
    {
        // 投影（原版 radius 5、偏移 (2.5, 5)、透明度 0.6）
        SoftShadow(g, 2.5, 5, 5, 0.6, shadow =>
        {
            for (int k = 0; k < 6; k++)
            {
                double deg = angle - 90 + k * 60.0;
                Bar(g, Polar(20, deg), Polar(60, deg), 8.5, 6, shadow);
                Bar(g, Polar(59, deg), Polar(68, deg), 7.4, 7.4, shadow);
                using var ball = Circle(5.8, Polar(70.5, deg).X, Polar(70.5, deg).Y);
                FillSolid(g, ball, shadow);
            }
            using var ring = Ring(53, 45);
            FillSolid(g, ring, shadow);
        });

        for (int k = 0; k < 6; k++)
        {
            double deg = angle - 90 + k * 60.0;
            Cylinder(g, Polar(20, deg), Polar(60, deg), 8.5, 6);
            Cylinder(g, Polar(59, deg), Polar(68, deg), 7.4, 7.4);
            Sphere(g, Polar(70.5, deg), 5.8);
        }

        using (var ring = Ring(53, 45))
        using (var br = Linear(-48, -48, 48, 48, Even(Rgb(0xF1F3F6), Rgb(0xA7ADB6), Rgb(0x5D636B), Rgb(0x8E959E))))
            g.FillPath(br, ring);
        using (var outer = Circle(53))
        using (var br = Bevel(53, hi: 0.7, lo: 0.5))
        using (var pen = new Pen(br, 1f))
            g.DrawPath(pen, outer);
        using (var inner = Circle(45))
        using (var br = Bevel(45, hi: 0.4, lo: 0.6, inset: true))
        using (var pen = new Pen(br, 1f))
            g.DrawPath(pen, inner);
    }

    /// 密码盘：抛光底座 + 转动的黑色刻度盘（50 格）+ 滚花旋钮；12 点固定一个橙色对位标
    private static void DrawDial(Graphics g, double angle)
    {
        Color orange = Rgb(0xFF8A3D);

        SoftDiskShadow(g, 28, new V(0, 2.5), 3, 0.55);
        using (var baseDisk = Circle(28))
        using (var br = Radial(new V(-9, -11), 0, 40, Rgb(0xF4F6F9), Rgb(0x9AA1AA), Rgb(0x4E535B)))
            g.FillPath(br, baseDisk);
        using (var rim = Circle(28))
        using (var pen = new Pen(Black(0.45), 1f))
            g.DrawPath(pen, rim);

        // 以下在刻度盘坐标系里画（随 angle 转动）
        GraphicsState dst = g.Save();
        g.RotateTransform((float)angle);

        using (var disk = Circle(24))
        using (var br = Radial(new V(0, 0), 8, 24, Rgb(0x2A2E35), Rgb(0x0C0D10)))
            g.FillPath(br, disk);

        using (var minor = new GraphicsPath())
        using (var major = new GraphicsPath())
        {
            for (int k = 0; k < 50; k++)
            {
                double deg = k * 7.2;
                // 每一格都是单独一段（Swift 的 move(to:)），不然 AddLine 会把相邻两格连起来
                var path = k % 5 == 0 ? major : minor;
                path.StartFigure();
                path.AddLine(P(Polar(k % 5 == 0 ? 16.5 : 19.5, deg)), P(Polar(23, deg)));
            }
            using (var pen = new Pen(White(0.45), 0.6f)) g.DrawPath(pen, minor);
            using (var pen = new Pen(White(0.9), 1.1f)) g.DrawPath(pen, major);
        }
        V marker = Polar(14, -90);
        using (var dot = Circle(1.6, marker.X, marker.Y))
            FillSolid(g, dot, orange);

        // 旋钮（投影在刻度盘坐标系里偏移，所以随盘转动）
        SoftDiskShadow(g, 12.5, new V(0, 1.5), 2, 0.6);
        using (var knob = Circle(12.5))
        using (var br = Radial(new V(-4, -5), 0, 18, Rgb(0xF7F8FA), Rgb(0x9097A0), Rgb(0x41454C)))
            g.FillPath(br, knob);

        using (var knurl = new GraphicsPath())
        {
            for (int k = 0; k < 30; k++)
            {
                knurl.StartFigure();
                knurl.AddLine(P(Polar(10.6, k * 12.0)), P(Polar(12.4, k * 12.0)));
            }
            using var pen = new Pen(Black(0.35), 0.8f);
            g.DrawPath(pen, knurl);
        }
        using (var hub = Circle(5.5))
        using (var br = Radial(new V(-1.8, -2.2), 0, 7, Rgb(0xFFFFFF), Rgb(0xA8AEB7)))
            g.FillPath(br, hub);

        g.Restore(dst);

        // 12 点固定的对位标（不随盘转）
        using (var mark = new GraphicsPath())
        {
            mark.AddPolygon(new[] { P(Polar(24.5, -90)), P(Polar(29.5, -95)), P(Polar(29.5, -85)) });
            FillSolid(g, mark, orange);
        }
    }
}
