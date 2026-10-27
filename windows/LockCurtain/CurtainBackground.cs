// CurtainBackground.cs —— 遮罩的背景：当前壁纸、模糊壁纸、纯黑，或者程序画的几张图（对应 Mac 版 CurtainBackground.swift）
//
// 程序画的图是静态的：每次显示遮罩时按屏幕的像素尺寸在后台线程画一张贴上去，不跑动画。
// 画法和参数照搬 Mac 版，随机数用 ArtKit.Rand（和 Mac 的 MechEye.rand 一样），同样尺寸的屏两边画出来一样。
// 坐标按点（像素 ÷ 缩放比例）、y 向下，和 Mac 版一致。
// Core Graphics 的滤色（screen）混合、柔光、四角压暗、两圆之间的径向渐变 GDI+ 都没有，这些按像素算（Pixels）；
// 路径、小圆、线性渐变还用 GDI+（Canvas.Draw）。画布一直不透明，按像素算时只管 RGB。

using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using static LockCurtain.ArtKit;

namespace LockCurtain;

internal enum CurtainBackground { Wallpaper, Blurred, Black, Starfield, Hills, Carbon }

internal static class CurtainBackgrounds
{
    public static string Title(this CurtainBackground b) => b switch
    {
        CurtainBackground.Wallpaper => "壁纸",
        CurtainBackground.Blurred => "模糊壁纸",
        CurtainBackground.Black => "纯黑",
        CurtainBackground.Starfield => "星空",
        CurtainBackground.Hills => "远山",
        _ => "碳纤维",
    };

    /// 背景要用当前壁纸
    public static bool UsesWallpaper(this CurtainBackground b) => b is CurtainBackground.Wallpaper or CurtainBackground.Blurred;

    /// 叠在背景上的黑色压暗层；程序画的图本身够暗，不再压
    public static double Dim(this CurtainBackground b) => b switch
    {
        CurtainBackground.Wallpaper => 0.28,
        CurtainBackground.Blurred => 0.35,
        _ => 0,
    };

    /// 模糊壁纸：screen 是按系统铺法画好的整屏壁纸。缩到 1/4，高斯模糊 σ 24（边缘按最近的像素延伸），饱和度 1.15。
    /// 模糊和饱和度在线性光下算：Mac 版用的 Core Image 默认就在线性光下算。返回小图，贴的时候拉伸回整屏
    public static unsafe Bitmap Blur(Image screen)
    {
        int w = Math.Max(1, screen.Width / 4), h = Math.Max(1, screen.Height / 4);
        var small = new Bitmap(w, h, PixelFormat.Format32bppPArgb);
        using (var g = Graphics.FromImage(small))
        using (var edges = new ImageAttributes())
        {
            // 边上镜像取样；不设的话边缘几个像素混进透明，模糊后整条边发暗
            edges.SetWrapMode(WrapMode.TileFlipXY);
            g.InterpolationMode = InterpolationMode.HighQualityBilinear;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            g.DrawImage(screen, new Rectangle(0, 0, w, h), 0, 0, screen.Width, screen.Height, GraphicsUnit.Pixel, edges);
        }
        var data = small.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadWrite, PixelFormat.Format32bppPArgb);
        try
        {
            var p = (uint*)data.Scan0;
            var planes = new[] { new float[w * h], new float[w * h], new float[w * h] };
            var toLinear = Enumerable.Range(0, 256).Select(v => (float)ToLinear(v / 255.0)).ToArray();
            for (var i = 0; i < w * h; i++)
                for (var c = 0; c < 3; c++)
                    planes[c][i] = toLinear[(p[i] >> (16 - 8 * c)) & 255];
            var radii = Layer.Boxes(24).Select(b => b / 2).ToArray();
            var line = new float[Math.Max(w, h)];
            foreach (var plane in planes)
                foreach (var r in radii)
                {
                    for (var y = 0; y < h; y++) BoxClamped(plane, y * w, 1, w, r, line);
                    for (var x = 0; x < w; x++) BoxClamped(plane, x, w, h, r, line);
                }
            for (var i = 0; i < w * h; i++)
            {
                float r = planes[0][i], g = planes[1][i], b = planes[2][i];
                var luma = 0.2125f * r + 0.7154f * g + 0.0721f * b;     // CIColorControls 的系数
                p[i] = 0xFF000000 | Encode(luma + 1.15f * (r - luma)) << 16 | Encode(luma + 1.15f * (g - luma)) << 8
                       | Encode(luma + 1.15f * (b - luma));
            }
        }
        finally { small.UnlockBits(data); }
        return small;
    }

    /// 程序画的背景，w×h 像素，scale 是每点几个像素（DPI / 96）；壁纸类和纯黑返回 null
    public static Bitmap? Render(this CurtainBackground b, int w, int h, float scale)
    {
        Action<Canvas>? draw = b switch
        {
            CurtainBackground.Starfield => Starfield.Draw,
            CurtainBackground.Hills => Hills.Draw,
            CurtainBackground.Carbon => CarbonFiber.Draw,
            _ => null,
        };
        if (draw == null || w <= 0 || h <= 0 || scale <= 0) return null;
        var canvas = new Canvas(w, h, scale);
        draw(canvas);
        return canvas.Bitmap;
    }

    static double ToLinear(double c) => c <= 0.04045 ? c / 12.92 : Math.Pow((c + 0.055) / 1.055, 2.4);

    static uint Encode(float linear)
    {
        double c = Math.Clamp(linear, 0, 1);
        c = c <= 0.0031308 ? 12.92 * c : 1.055 * Math.Pow(c, 1 / 2.4) - 0.055;
        return (uint)(c * 255 + 0.5);
    }

    /// 一行（或一列）做一次盒式模糊，窗口 2r+1，伸出去的部分取最近的像素。start、step、n 指出这一行在 plane 里的位置
    static void BoxClamped(float[] plane, int start, int step, int n, int r, float[] line)
    {
        for (var i = 0; i < n; i++) line[i] = plane[start + i * step];
        float sum = 0, window = 2 * r + 1;
        for (var k = -r; k <= r; k++) sum += line[Math.Clamp(k, 0, n - 1)];
        for (var i = 0; i < n; i++)
        {
            plane[start + i * step] = sum / window;
            sum += line[Math.Min(i + r + 1, n - 1)] - line[Math.Max(i - r, 0)];
        }
    }
}

// MARK: - 画布

/// 程序画的背景用的画布：Draw() 用 GDI+ 画，Lock() 按像素改。坐标都按点
internal sealed class Canvas(int width, int height, float scale)
{
    public readonly Bitmap Bitmap = new(width, height, PixelFormat.Format32bppPArgb);
    public readonly float Scale = scale;
    /// 尺寸，按点
    public double W => Bitmap.Width / (double)Scale;
    public double H => Bitmap.Height / (double)Scale;

    public Graphics Draw()
    {
        var g = Graphics.FromImage(Bitmap);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.PixelOffsetMode = PixelOffsetMode.HighQuality;
        g.ScaleTransform(Scale, Scale);
        return g;
    }

    /// 锁一次像素做一批运算；LockBits 每次都要拷整张图，别每团光锁一次
    public Pixels Lock() => new(Bitmap, Scale);

    /// 沿 from→to 的线性渐变填满 area，两头以外延续端点的颜色（CG 的 drawsBefore/AfterStartLocation）。
    /// at 是各颜色的位置，不给时平均分
    public static void FillLinear(Graphics g, GraphicsPath area, PointF from, PointF to, (uint Hex, double A)[] colors, double[]? at = null)
    {
        at ??= colors.Select((_, i) => i / (double)(colors.Length - 1)).ToArray();
        // 把渐变的两头拉长到盖住整个 area，位置跟着换算；GDI+ 的线性渐变超出两头是重复，不是延续
        double dx = to.X - from.X, dy = to.Y - from.Y, len2 = dx * dx + dy * dy;
        var bounds = area.GetBounds();
        var ts = new[] { (bounds.Left, bounds.Top), (bounds.Right, bounds.Top), (bounds.Left, bounds.Bottom), (bounds.Right, bounds.Bottom) }
            .Select(p => ((p.Item1 - from.X) * dx + (p.Item2 - from.Y) * dy) / len2).ToList();
        double t0 = Math.Min(0, ts.Min()) - 0.01, t1 = Math.Max(1, ts.Max()) + 0.01;
        PointF At(double t) => new((float)(from.X + dx * t), (float)(from.Y + dy * t));
        var positions = new List<float> { 0 };
        var blend = new List<Color> { Rgb(colors[0].Hex, colors[0].A) };
        for (var i = 0; i < colors.Length; i++)
        {
            positions.Add((float)((at[i] - t0) / (t1 - t0)));
            blend.Add(Rgb(colors[i].Hex, colors[i].A));
        }
        positions.Add(1);
        blend.Add(Rgb(colors[^1].Hex, colors[^1].A));
        using var brush = new LinearGradientBrush(At(t0), At(t1), blend[0], blend[^1])
        {
            InterpolationColors = new ColorBlend { Colors = blend.ToArray(), Positions = positions.ToArray() },
            WrapMode = WrapMode.TileFlipXY,
        };
        g.FillPath(brush, area);
    }

    public static void FillLinear(Graphics g, RectangleF area, PointF from, PointF to, (uint Hex, double A)[] colors, double[]? at = null)
    {
        using var path = new GraphicsPath();
        path.AddRectangle(area);
        FillLinear(g, path, from, to, colors, at);
    }
}

/// 锁住的像素（预乘 ARGB，不透明）。坐标按点，进来就乘 scale
internal readonly unsafe struct Pixels : IDisposable
{
    readonly Bitmap bitmap;
    readonly BitmapData data;
    readonly uint* p;
    readonly int w, h;
    readonly double s;

    public Pixels(Bitmap bitmap, float scale)
    {
        this.bitmap = bitmap;
        w = bitmap.Width;
        h = bitmap.Height;
        s = scale;
        data = bitmap.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadWrite, PixelFormat.Format32bppPArgb);
        p = (uint*)data.Scan0;
    }

    public void Dispose() => bitmap.UnlockBits(data);

    /// 一团柔光（Mac 的 glow）：中心不透明度 a，0.4 处降到 0.4a，边缘为 0；先横向拉长 stretch 倍再转 angle。
    /// screen 时按滤色叠（只会更亮），否则普通叠加。clip 给了时只画在那个圆里（边缘抗锯齿）
    public void Glow(double cx, double cy, double r, uint hex, double a, bool screen, double stretch = 1, double angle = 0,
                     (double X, double Y, double R)? clip = null)
    {
        double pcx = cx * s, pcy = cy * s, pr = r * s;
        if (pr <= 0 || a <= 0) return;
        double cos = Math.Cos(angle), sin = Math.Sin(angle), ax = pr * stretch;
        double hx = Math.Sqrt(ax * cos * ax * cos + pr * sin * pr * sin), hy = Math.Sqrt(ax * sin * ax * sin + pr * cos * pr * cos);
        int x0 = Math.Max(0, (int)Math.Floor(pcx - hx)), x1 = Math.Min(w, (int)Math.Ceiling(pcx + hx));
        int y0 = Math.Max(0, (int)Math.Floor(pcy - hy)), y1 = Math.Min(h, (int)Math.Ceiling(pcy + hy));
        double invStretch = 1 / stretch, invR = 1 / pr;
        double ccx = 0, ccy = 0, ccr = 0;
        if (clip is { } c) (ccx, ccy, ccr) = (c.X * s, c.Y * s, c.R * s);
        for (var y = y0; y < y1; y++)
        {
            var dy = y + 0.5 - pcy;
            var row = p + y * w;
            for (var x = x0; x < x1; x++)
            {
                var dx = x + 0.5 - pcx;
                double qx = (dx * cos + dy * sin) * invStretch, qy = dy * cos - dx * sin;
                var t = Math.Sqrt(qx * qx + qy * qy) * invR;
                if (t >= 1) continue;
                var alpha = t < 0.4 ? a * (1 - 1.5 * t) : a * (1 - t) / 1.5;
                if (clip != null) alpha *= Coverage(ccr - Math.Sqrt((x + 0.5 - ccx) * (x + 0.5 - ccx) + (y + 0.5 - ccy) * (y + 0.5 - ccy)));
                if (alpha <= 0) continue;
                row[x] = screen ? Screen(row[x], hex, alpha) : Over(row[x], hex, alpha);
            }
        }
    }

    /// 一根线段，从 from 的 a 渐变到 to 的 0，按滤色叠（亮星的十字星芒）。width 按点，两头平头
    public void Spike(double fx, double fy, double tx, double ty, uint hex, double a, double width)
    {
        double ax = fx * s, ay = fy * s, bx = tx * s, by = ty * s, half = width * s / 2;
        double len = Math.Sqrt((bx - ax) * (bx - ax) + (by - ay) * (by - ay));
        if (len <= 0) return;
        double ux = (bx - ax) / len, uy = (by - ay) / len, pad = half + 1;
        int x0 = Math.Max(0, (int)Math.Floor(Math.Min(ax, bx) - pad)), x1 = Math.Min(w, (int)Math.Ceiling(Math.Max(ax, bx) + pad));
        int y0 = Math.Max(0, (int)Math.Floor(Math.Min(ay, by) - pad)), y1 = Math.Min(h, (int)Math.Ceiling(Math.Max(ay, by) + pad));
        var thin = Math.Min(1, 2 * half);     // 比一个像素还细的线，整体按宽度变淡
        for (var y = y0; y < y1; y++)
            for (var x = x0; x < x1; x++)
            {
                double dx = x + 0.5 - ax, dy = y + 0.5 - ay;
                var along = dx * ux + dy * uy;
                if (along < 0 || along > len) continue;
                var alpha = a * (1 - along / len) * Coverage(half - Math.Abs(dx * uy - dy * ux)) * thin;
                if (alpha > 0) p[y * w + x] = Screen(p[y * w + x], hex, alpha);
            }
    }

    /// 四角压暗：中心到对角线一半的 50% 以内不变，往外压到 a（超出照最外圈）
    public void Vignette(double a)
    {
        double cx = w / 2.0, cy = h / 2.0, reach = Math.Sqrt(cx * cx + cy * cy);
        for (var y = 0; y < h; y++)
            for (var x = 0; x < w; x++)
            {
                double dx = x + 0.5 - cx, dy = y + 0.5 - cy, t = Math.Sqrt(dx * dx + dy * dy) / reach;
                if (t > 0.5) p[y * w + x] = Over(p[y * w + x], 0, a * Math.Min(1, (t - 0.5) / 0.5));
            }
    }

    /// 屏幕中间（图案和文案那块）压暗一点
    public void CalmCenter(double width, double height, uint hex, double a) =>
        Glow(width / 2, height / 2 - 25, Math.Min(height * 0.34, width * 0.3), hex, a, screen: false, stretch: 1.5);

    /// 两圆之间的径向渐变，只画在 clip 圆里（远山的月面）：起点圆心 (fx, fy) 半径 0，终点圆心 (cx, cy) 半径 r，
    /// 超出终点圆照最后的颜色；colors 是不透明的
    public void FocalGradient(double fx, double fy, double cx, double cy, double r, (uint Hex, double At)[] colors,
                              (double X, double Y, double R) clip)
    {
        double f0 = fx * s, f1 = fy * s, dcx = (cx - fx) * s, dcy = (cy - fy) * s, r1 = r * s;
        double kx = clip.X * s, ky = clip.Y * s, kr = clip.R * s;
        var a2 = dcx * dcx + dcy * dcy - r1 * r1;      // 起点在终点圆里，小于 0
        int x0 = Math.Max(0, (int)Math.Floor(kx - kr - 1)), x1 = Math.Min(w, (int)Math.Ceiling(kx + kr + 1));
        int y0 = Math.Max(0, (int)Math.Floor(ky - kr - 1)), y1 = Math.Min(h, (int)Math.Ceiling(ky + kr + 1));
        for (var y = y0; y < y1; y++)
            for (var x = x0; x < x1; x++)
            {
                var cover = Coverage(kr - Math.Sqrt((x + 0.5 - kx) * (x + 0.5 - kx) + (y + 0.5 - ky) * (y + 0.5 - ky)));
                if (cover <= 0) continue;
                // 解 |点 − 圆心(t)| = 半径(t)，取 t ≥ 0 的根
                double ex = x + 0.5 - f0, ey = y + 0.5 - f1, b = ex * dcx + ey * dcy;
                var t = Math.Min(1, (b - Math.Sqrt(Math.Max(0, b * b - a2 * (ex * ex + ey * ey)))) / a2);
                var i = 1;
                while (i < colors.Length - 1 && t > colors[i].At) i++;
                var u = Math.Clamp((t - colors[i - 1].At) / (colors[i].At - colors[i - 1].At), 0, 1);
                uint Mix(int shift) => (uint)Math.Round(Ch(colors[i - 1].Hex, shift) * (1 - u) + Ch(colors[i].Hex, shift) * u);
                p[y * w + x] = Over(p[y * w + x], Mix(16) << 16 | Mix(8) << 8 | Mix(0), cover);
            }
    }

    /// 每个像素换成 f(x, y, 原来的颜色)，坐标按像素
    public void Map(Func<int, int, uint, uint> f)
    {
        for (var y = 0; y < h; y++)
            for (var x = 0; x < w; x++)
                p[y * w + x] = f(x, y, p[y * w + x]);
    }

    /// 边缘抗锯齿：distance 是到边界的像素数，里面为正
    static double Coverage(double distance) => Math.Clamp(distance + 0.5, 0, 1);

    static double Ch(uint c, int shift) => (c >> shift) & 255;

    /// 普通叠加：S + D × (1 − a)，S 是 hex 乘 a
    static uint Over(uint d, uint hex, double a)
    {
        uint C(int shift) => (uint)Math.Clamp(Math.Round(Ch(hex, shift) * a + Ch(d, shift) * (1 - a)), 0, 255);
        return 0xFF000000 | C(16) << 16 | C(8) << 8 | C(0);
    }

    /// 滤色：D + S × (1 − D)
    static uint Screen(uint d, uint hex, double a)
    {
        uint C(int shift) => (uint)Math.Clamp(Math.Round(Ch(d, shift) + Ch(hex, shift) * a * (255 - Ch(d, shift)) / 255), 0, 255);
        return 0xFF000000 | C(16) << 16 | C(8) << 8 | C(0);
    }
}

// MARK: - 共用的小工具

file static class Noise
{
    public static double R(int i, ulong salt) => Rand(i, salt);

    /// 近似正态的随机数，-1…1，越靠 0 越多
    public static double Bell(int i, ulong salt) => (Rand(i, salt) + Rand(i, salt + 1000) + Rand(i, salt + 2000) - 1.5) / 1.5;

    /// 一维值噪声叠几层（fbm），0…1
    public static double Fbm(double x, ulong salt, int octaves = 5)
    {
        double v = 0, amp = 0.5, f = 1, total = 0;
        for (var o = 0; o < octaves; o++)
        {
            double p = x * f, t = p - Math.Floor(p);
            var i = (int)Math.Floor(p);
            double a = Rand(i, salt + (ulong)o * 77), b = Rand(i + 1, salt + (ulong)o * 77);
            v += amp * (a + (b - a) * t * t * (3 - 2 * t));
            total += amp;
            f *= 2.03;
            amp *= 0.5;
        }
        return v / total;
    }
}

// MARK: - 星空

/// 星空：一条银河从左下斜到右上、从图案上方经过，暖色的核心偏左，两边泛蓝紫，中线有暗尘带；
/// 底下撒满小星，几十颗亮星带光晕，最亮的几颗有十字星芒
file static class Starfield
{
    public static void Draw(Canvas c)
    {
        double W = c.W, H = c.H;
        using (var g = c.Draw())
            Canvas.FillLinear(g, new RectangleF(0, 0, (float)W, (float)H), PointF.Empty, new PointF(0, (float)H),
                              new[] { (0x02040Au, 1.0), (0x060A18u, 1.0), (0x0C1330u, 1.0) }, new[] { 0, 0.55, 1 });

        const double angle = -0.40;
        double dirX = Math.Cos(angle), dirY = Math.Sin(angle), nrmX = -Math.Sin(angle), nrmY = Math.Cos(angle);
        double ox = W * 0.5, oy = H * 0.30, L = Math.Sqrt(W * W + H * H) * 0.62, bw = H * 0.15;
        (double X, double Y) At(double u, double v) => (ox + dirX * u + nrmX * v, oy + dirY * u + nrmY * v);
        // 银河沿长度方向的亮度：核心在左下段，再叠一点起伏让它成团
        double Bright(double u) =>
            0.35 + 0.65 * Math.Exp(-Math.Pow((u + L * 0.28) / (L * 0.32), 2)) + 0.25 * (Noise.Fbm(u / L * 4 + 10, 5) - 0.5);

        // 小星和亮星的白核用 GDI+ 画；白色按滤色叠和普通叠加结果一样
        var cores = new List<(double X, double Y, double R, Color Color)>();
        using (var px = c.Lock())
        {
            // 银河的光：先铺一层宽的蓝紫色，再沿带子撒一堆小团，中间暖、两边冷，成团成絮
            for (var i = 0; i < 90; i++)
            {
                double u = (Noise.R(i, 1) * 2 - 1) * L, v = Noise.Bell(i, 2) * bw * 1.2;
                var (x, y) = At(u, v);
                px.Glow(x, y, H * (0.1 + 0.1 * Noise.R(i, 3)), Noise.R(i, 4) < 0.6 ? 0x4A63D8u : 0x8A55C8u,
                        0.05 * Bright(u), screen: true, stretch: 1.8, angle: angle);
            }
            for (var i = 0; i < 620; i++)
            {
                double u = (Noise.R(i, 5) * 2 - 1) * L, b = Noise.Bell(i, 6), v = b * bw;
                var warm = Math.Abs(b) < 0.35;
                var hex = warm ? (Noise.R(i, 7) < 0.5 ? 0xF4DDBAu : 0xE9C9A4u) : (Noise.R(i, 7) < 0.6 ? 0x7C96FFu : 0xB27FE8u);
                var r = H * (0.018 + 0.05 * Noise.R(i, 8)) * (1 - 0.4 * Math.Abs(b));
                var (x, y) = At(u, v);
                px.Glow(x, y, r, hex, (warm ? 0.11 : 0.07) * Bright(u), screen: true, stretch: 1.5,
                        angle: angle + 0.3 * (Noise.R(i, 9) - 0.5));
            }
            // 核心：偏左下的一大团暖光
            var core = -L * 0.28;
            for (var i = 0; i < 70; i++)
            {
                var (x, y) = At(core + Noise.Bell(i, 15) * L * 0.18, Noise.Bell(i, 16) * bw * 0.45);
                px.Glow(x, y, H * (0.03 + 0.06 * Noise.R(i, 17)), 0xFFD9A6, 0.09, screen: true, stretch: 1.4, angle: angle);
            }
            // 暗尘带：沿弯曲的中线压掉一部分光，主带两边还分出几缕
            for (var i = 0; i < 320; i++)
            {
                var u = (Noise.R(i, 11) * 2 - 1) * L * 0.9;
                var lane = Noise.R(i, 14) < 0.7 ? 0 : Noise.R(i, 14) < 0.85 ? 0.35 : -0.4;
                var v = bw * (lane + 0.12 * Math.Sin(u / L * 7 + lane * 4) + 0.12 * Noise.Bell(i, 12));
                var (x, y) = At(u, v);
                px.Glow(x, y, H * (0.006 + 0.022 * Noise.R(i, 13)), 0x03050C, 0.34 * Bright(u) * (lane == 0 ? 1 : 0.7),
                        screen: false, stretch: 2.8, angle: angle + 0.4 * (Noise.R(i, 18) - 0.5));
            }
        }

        // 小星：一半均匀撒，其余挤在银河里，银河里的更小更密
        using (var g = c.Draw())
        using (var brush = new SolidBrush(Color.White))
        {
            var n = (int)(W * H / 300);
            for (var i = 0; i < n * 5 / 2; i++)
            {
                var (x, y) = i < n ? (Noise.R(i, 21) * W, Noise.R(i, 22) * H) : At((Noise.R(i, 23) * 2 - 1) * L, Noise.Bell(i, 24) * bw * 0.9);
                var m = Math.Pow(Noise.R(i, 26), 6);
                var r = 0.28 + 0.75 * m;
                var a = Math.Min(1, 0.18 + 0.55 * Math.Pow(Noise.R(i, 27), 2.5) + 0.3 * m);
                var t = Noise.R(i, 28);
                brush.Color = Rgb(t < 0.12 ? 0xFFD6A8u : t < 0.38 ? 0xC2D4FFu : 0xFFFFFFu, a);
                g.FillEllipse(brush, (float)(x - r), (float)(y - r), (float)(2 * r), (float)(2 * r));
            }
        }

        // 亮星：光晕 + 白核，最亮的几颗带十字星芒
        using (var px = c.Lock())
            for (var i = 0; i < 34; i++)
            {
                double x = Noise.R(i, 31) * W, y = Noise.R(i, 32) * H, m = Noise.R(i, 33);
                var hex = Noise.R(i, 34) < 0.3 ? 0xFFDDB8u : 0xC9D9FFu;
                px.Glow(x, y, 5 + 11 * m, hex, 0.22 + 0.25 * m, screen: true);
                cores.Add((x, y, 0.8 + 0.7 * m, Rgb(0xFFFFFF, 0.95)));
                if (i >= 7) continue;
                for (var k = 0; k < 4; k++)
                {
                    double a = k * Math.PI / 2 + 0.12, len = 10 + 22 * m;
                    px.Spike(x, y, x + Math.Cos(a) * len, y + Math.Sin(a) * len, hex, 0.75, 0.8);
                }
            }
        using (var g = c.Draw())
            foreach (var (x, y, r, color) in cores)
            {
                using var brush = new SolidBrush(color);
                g.FillEllipse(brush, (float)(x - r), (float)(y - r), (float)(2 * r), (float)(2 * r));
            }

        using (var px = c.Lock())
        {
            px.CalmCenter(W, H, 0x02040A, 0.5);
            px.Vignette(0.55);
        }
    }
}

// MARK: - 远山

/// 远山：月夜的水墨群山。五层山脊由远到近、由淡到黑，每层山顶浓、往下化进雾里；
/// 中间低两边高，图案和文案落在山谷上方的夜空里。右上角一轮月亮，云丝从前面飘过
file static class Hills
{
    public static void Draw(Canvas c)
    {
        double W = c.W, H = c.H;
        var all = new RectangleF(0, 0, (float)W, (float)H);
        using (var g = c.Draw())
            Canvas.FillLinear(g, all, PointF.Empty, new PointF(0, (float)(H * 0.78)),
                              new[] { (0x05080Fu, 1.0), (0x0B111Eu, 1.0), (0x1A2335u, 1.0) }, new[] { 0, 0.5, 1 });

        // 月亮：大片冷光、贴边一圈亮晕，月面左上亮、带几块月海
        double mx = W * 0.8, my = H * 0.2, mr = H * 0.042;
        using (var px = c.Lock())
        {
            px.Glow(mx, my, mr * 11, 0x7F95BF, 0.16, screen: true);
            px.Glow(mx, my, mr * 2.4, 0xD5DDEC, 0.28, screen: true);
            var moon = (mx, my, mr);
            px.FocalGradient(mx - mr * 0.35, my - mr * 0.35, mx, my, mr * 1.05,
                             new[] { (0xFBF7EAu, 0.0), (0xE6E0CBu, 0.65), (0xBDB59Du, 1.0) }, moon);
            for (var i = 0; i < 7; i++)
                px.Glow(mx + (Noise.R(i, 41) - 0.45) * mr * 1.3, my + (Noise.R(i, 42) - 0.45) * mr * 1.3,
                        mr * (0.18 + 0.3 * Noise.R(i, 43)), 0x9A927A, 0.3, screen: false, clip: moon);
            for (var i = 0; i < 5; i++)
                px.Glow(mx + (Noise.R(i, 44) - 0.6) * mr * 9, my + (Noise.R(i, 45) - 0.2) * mr * 2.4,
                        mr * (1.6 + 2 * Noise.R(i, 46)), 0x8792A8, 0.09, screen: false, stretch: 4.5);
        }

        // 山：(山脚高度, 最高峰, 山顶颜色, 峰数)。每层由几座尖峰叠成，左右坡宽窄不一，
        // 坡上再叠随高度变大的起伏，越高越嶙峋；越靠两边峰越高，中间留出山谷
        var layers = new (double Base, double Amp, uint Ink, int Peaks)[]
        {
            (0.72, 0.17, 0x2E3A50, 4),
            (0.78, 0.24, 0x202A3C, 5),
            (0.85, 0.27, 0x141B29, 4),
            (0.92, 0.25, 0x0A0E17, 5),
            (0.99, 0.21, 0x04060B, 6),
        };
        const uint mist = 0x35425C;
        using (var g = c.Draw())
            for (var li = 0; li < layers.Length; li++)
            {
                var l = layers[li];
                var salt = (ulong)(50 + li * 7);
                var peaks = Enumerable.Range(0, l.Peaks).Select(k =>
                {
                    var center = (k + 0.15 + 0.7 * Noise.R(k, salt)) / l.Peaks * W * 1.1 - W * 0.05;
                    var edge = Math.Pow(Math.Min(Math.Abs(center / W - 0.5) * 2, 1), 1.3);
                    var width = W / l.Peaks * 0.85;
                    return (C: center, Hgt: H * l.Amp * (0.3 + 0.7 * edge) * (0.65 + 0.35 * Noise.R(k, salt + 1)),
                            WL: width * (0.6 + 0.6 * Noise.R(k, salt + 2)), WR: width * (0.6 + 0.6 * Noise.R(k, salt + 3)));
                }).ToList();
                var points = new List<PointF> { new(0, (float)H) };
                var top = H;
                for (double x = 0; x <= W + 2; x += 2)
                {
                    double ht = 0;
                    foreach (var pk in peaks)
                    {
                        var d = (x - pk.C) / (x < pk.C ? pk.WL : pk.WR);
                        if (Math.Abs(d) < 1) ht = Math.Max(ht, pk.Hgt * Math.Pow(1 - Math.Abs(d), 1.35));
                    }
                    ht *= 1 + 0.32 * (Noise.Fbm(x / W * 9, salt + 8) - 0.5) + 0.12 * (Noise.Fbm(x / W * 38, salt + 9) - 0.5);
                    var y = H * l.Base - ht;
                    top = Math.Min(top, y);
                    points.Add(new PointF((float)x, (float)y));
                }
                points.Add(new PointF((float)W, (float)H));
                using var ridge = new GraphicsPath();
                ridge.AddLines(points.ToArray());
                ridge.CloseFigure();

                // 峰顶浓、往下淡进雾里
                Canvas.FillLinear(g, ridge, new PointF(0, (float)top), new PointF(0, (float)(H * (l.Base + 0.02))),
                                  new[] { (l.Ink, 1.0), (l.Ink, 1.0), (mist, 1.0) }, new[] { 0, 0.3, 1 });
                // 山脊一道墨线，近处的浓
                using (var pen = new Pen(Rgb(0x020306, 0.15 + 0.1 * li), 1.1f))
                    g.DrawPath(pen, ridge);

                // 山脚一层雾，盖住下一层山的接缝
                if (li < layers.Length - 1)
                {
                    var y = H * (l.Base + 0.01);
                    float from = (float)(y - H * 0.06), to = (float)(y + H * 0.05);
                    Canvas.FillLinear(g, new RectangleF(0, from, (float)W, to - from), new PointF(0, from), new PointF(0, to),
                                      new[] { (mist, 0.0), (mist, 0.55), (mist, 0.0) });
                }
            }

        using (var px = c.Lock())
        {
            px.CalmCenter(W, H, 0x05080F, 0.35);
            px.Vignette(0.5);
        }
    }
}

// MARK: - 碳纤维

/// 碳纤维：2×2 斜纹编织，每股纤维横截面中间亮两边暗，沿长度中间鼓起、两头钻到下面去；
/// 横股和竖股反光不一样，从左上到右下慢慢互换明暗；表面一层清漆，左上方一片柔和的高光
file static class CarbonFiber
{
    /// 一格的边长（点）
    const float Cell = 7;

    public static unsafe void Draw(Canvas c)
    {
        double W = c.W, H = c.H;
        using var a = Tile(hBright: true, c.Scale);
        using var b = Tile(hBright: false, c.Scale);
        if (a == null || b == null) return;
        // 横股亮的一层铺满，竖股亮的一层按从左上到右下的渐变盖上去（Mac 版用 destinationIn 做蒙版）
        var n = a.Width;
        var ta = a.LockBits(new Rectangle(0, 0, n, n), ImageLockMode.ReadOnly, PixelFormat.Format32bppPArgb);
        var tb = b.LockBits(new Rectangle(0, 0, n, n), ImageLockMode.ReadOnly, PixelFormat.Format32bppPArgb);
        try
        {
            uint* pa = (uint*)ta.Scan0, pb = (uint*)tb.Scan0;
            double s = c.Scale, x0 = W * 0.15 * s, dx = W * 0.7 * s, dy = H * s, len2 = dx * dx + dy * dy;
            using var px = c.Lock();
            px.Map((x, y, _) =>
            {
                var t = Math.Clamp(((x + 0.5 - x0) * dx + (y + 0.5) * dy) / len2, 0, 1);
                var m = t < 0.35 ? 0.15 * t / 0.35 : 0.15 + 0.85 * (t - 0.35) / 0.65;
                int i = y % n * n + x % n;
                uint ca = pa[i], cb = pb[i];
                uint Mix(int shift) => (uint)Math.Round(((ca >> shift) & 255) * (1 - m) + ((cb >> shift) & 255) * m);
                return 0xFF000000 | Mix(16) << 16 | Mix(8) << 8 | Mix(0);
            });
            px.Glow(W * 0.2, H * 0.1, W * 0.75, 0xD8E2F0, 0.10, screen: true, stretch: 1.3, angle: 0.5);
            px.Glow(W * 0.28, H * 0.18, W * 0.22, 0xE6EEF8, 0.07, screen: true, stretch: 2.2, angle: 0.55);
            px.CalmCenter(W, H, 0x050607, 0.35);
            px.Vignette(0.65);
        }
        finally
        {
            a.UnlockBits(ta);
            b.UnlockBits(tb);
        }
    }

    /// 4×4 格的一块，横股亮（hBright）或竖股亮。缩放比例是 25% 的整数倍时，一块正好是整数个像素
    static Bitmap? Tile(bool hBright, float scale)
    {
        var n = (int)Math.Round(Cell * 4 * scale);
        if (n <= 0) return null;
        var bmp = new Bitmap(n, n, PixelFormat.Format32bppPArgb);
        using var g = Graphics.FromImage(bmp);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.PixelOffsetMode = PixelOffsetMode.HighQuality;
        g.ScaleTransform(n / (Cell * 4), n / (Cell * 4));
        g.Clear(Rgb(0x060708));
        // 纤维丝 0.25 点宽。GDI+ 把不到 1 像素宽的线画成 1 像素宽，1 倍屏上整块会亮一截：
        // 这时按 1 像素宽画，透明度乘上原本的覆盖率
        var fiberCover = Math.Min(1, 0.25f * n / (Cell * 4));
        using var fiber = new Pen(Color.White, 0.25f / fiberCover);
        for (var j = 0; j < 4; j++)
            for (var i = 0; i < 4; i++)
            {
                var k = ((i - j) % 4 + 4) % 4;
                var horizontal = k < 2;
                const float gap = 0.22f;
                var r = new RectangleF(i * Cell, j * Cell, Cell, Cell);
                r.Inflate(horizontal ? 0 : -gap, horizontal ? -gap : 0);
                var lit = horizontal == hBright;
                var (edge, mid) = lit ? (0x141619u, 0x3B4046u) : (0x0E0F12u, 0x22252Au);
                Canvas.FillLinear(g, r, new PointF(r.Left, r.Top), horizontal ? new PointF(r.Left, r.Bottom) : new PointF(r.Right, r.Top),
                                  new[] { (edge, 1.0), (mid, 1.0), (edge, 1.0) }, new[] { 0, 0.45, 1 });
                // 纤维丝
                fiber.Color = Rgb(0xFFFFFF, (lit ? 0.06 : 0.035) * fiberCover);
                for (var f = 1; f < 4; f++)
                {
                    var o = f / 4f;
                    if (horizontal) g.DrawLine(fiber, r.Left, r.Top + r.Height * o, r.Right, r.Top + r.Height * o);
                    else g.DrawLine(fiber, r.Left + r.Width * o, r.Top, r.Left + r.Width * o, r.Bottom);
                }
                // 一股跨两格，中间鼓起最亮，两头钻到下面去，压暗
                var first = horizontal ? k == 0 : k == 3;
                var (from, to) = horizontal
                    ? (first ? (new PointF(r.Left, 0), new PointF(r.Right, 0)) : (new PointF(r.Right, 0), new PointF(r.Left, 0)))
                    : (first ? (new PointF(0, r.Top), new PointF(0, r.Bottom)) : (new PointF(0, r.Bottom), new PointF(0, r.Top)));
                Canvas.FillLinear(g, r, from, to, new[] { (0u, 0.7), (0u, 0.2), (0u, 0.0) }, new[] { 0, 0.45, 1 });
            }
        return bmp;
    }
}
