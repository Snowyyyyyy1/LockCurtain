// ArtLayer.cs —— 按像素合成的图层：给魔瞳、镇宅符补上 GDI+ 没有的模糊、混合模式和软边裁剪
//
// SwiftUI 的 GraphicsContext 可以 addFilter(.blur)、设 blendMode（plusLighter 发光、multiply 墨色吃进纸里）、
// clip(to:) 后再画、drawLayer 先合成一层再叠上去。GDI+ 只有普通叠加，读不到目标像素，所以这两个图案
// 先画进自己的画布（Layer.Canvas），要特殊处理的部分画进子层（Sub），在子层上做模糊、裁剪，
// 再按混合模式合回父层，最后整块贴到遮罩上（DrawTo）。
// 像素格式是预乘 alpha 的 32 位 ARGB；模糊是三次盒式模糊，近似 σ = radius 的高斯模糊（和 CIGaussianBlur 一样）。
// 半径、偏移都按设计坐标（半径 120 的那套）给，换算成像素时乘 side/240。

using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;

namespace LockCurtain;

internal enum Blend { Normal, PlusLighter, Multiply }

internal sealed unsafe class Layer : IDisposable
{
    readonly Bitmap bitmap;
    readonly float unit;     // 一个设计单位多少像素
    /// 在这一层上画：已经换到设计坐标，原点在中心
    public readonly Graphics G;

    Layer(int px, float unit, Matrix? transform)
    {
        this.unit = unit;
        bitmap = new Bitmap(px, px, PixelFormat.Format32bppPArgb);
        G = Graphics.FromImage(bitmap);
        G.SmoothingMode = SmoothingMode.AntiAlias;
        G.PixelOffsetMode = PixelOffsetMode.HighQuality;
        if (transform != null) G.Transform = transform;
        else
        {
            G.TranslateTransform(px / 2f, px / 2f);
            G.ScaleTransform(unit, unit);
        }
    }

    /// side 像素见方的透明画布，对应 Swift 里 unitSpace 之后的 g
    public static Layer Canvas(float side) => new((int)Math.Ceiling(side), side / 240f, null);

    /// 同样大小的透明子层，坐标变换照搬父层现在的（Swift 里 var x = g 复制一份 context）
    public Layer Sub()
    {
        using var m = G.Transform;
        return new Layer(bitmap.Width, unit, m);
    }

    /// 贴到目标上：调用方已经把 g 平移到图案方块的左上角
    public void DrawTo(Graphics g)
    {
        G.Flush();
        g.DrawImage(bitmap, 0, 0, bitmap.Width, bitmap.Height);
    }

    /// 高斯模糊，radius 按设计坐标（Swift 的 addFilter(.blur(radius:))）。超出画布的部分当透明
    public void Blur(double radius)
    {
        var sigma = radius * unit;
        if (sigma < 0.3) return;
        using var px = new Pixels(this, ImageLockMode.ReadWrite);
        var boxes = Boxes(sigma);
        // 只处理有内容的范围，往外留出模糊能扩散到的距离；范围以外本来就是透明的，算了也还是透明
        var area = Bounds(px);
        if (area.IsEmpty) return;
        var reach = boxes.Sum(b => b / 2);
        area.Inflate(reach, reach);
        area.Intersect(new Rectangle(0, 0, px.W, px.H));
        fixed (uint* tmp = Scratch(px.W * px.H))
            foreach (var box in boxes)
            {
                BoxPass(px.P, tmp, px.W, area, box / 2, horizontal: true);
                BoxPass(tmp, px.P, px.W, area, box / 2, horizontal: false);
            }
    }

    /// 只留 path 里面的部分，边缘抗锯齿（Swift 的 clip(to:) 之后画的东西）。path 按这一层现在的坐标变换
    public void Clip(GraphicsPath path)
    {
        using var mask = Sub();
        mask.G.FillPath(Brushes.White, path);
        using var m = new Pixels(mask, ImageLockMode.ReadOnly);
        using var px = new Pixels(this, ImageLockMode.ReadWrite);
        var area = Bounds(px);
        for (var y = area.Top; y < area.Bottom; y++)
            for (int x = area.Left, i = y * px.W + x; x < area.Right; x++, i++)
            {
                var a = m.P[i] >> 24;
                if (a == 255) continue;
                px.P[i] = a == 0 ? 0 : Scale(px.P[i], a);
            }
    }

    /// 把 src 按混合模式合到这一层上，opacity 是 src 整体的不透明度（Swift 的 context.opacity）
    public void Composite(Layer src, Blend mode, double opacity = 1)
    {
        var k = (uint)Math.Clamp((int)Math.Round(opacity * 255), 0, 255);
        if (k == 0) return;
        using var s = new Pixels(src, ImageLockMode.ReadOnly);
        using var d = new Pixels(this, ImageLockMode.ReadWrite);
        var area = Bounds(s);
        for (var y = area.Top; y < area.Bottom; y++)
            for (int x = area.Left, i = y * d.W + x; x < area.Right; x++, i++)
            {
                var sp = s.P[i];
                if (sp == 0) continue;
                if (k < 255) sp = Scale(sp, k);
                d.P[i] = mode switch
                {
                    Blend.PlusLighter => Plus(sp, d.P[i]),
                    Blend.Multiply => Multiply(sp, d.P[i]),
                    _ => Over(sp, d.P[i]),
                };
            }
    }

    public void Dispose()
    {
        G.Dispose();
        bitmap.Dispose();
    }

    // MARK: - 像素运算（预乘 ARGB，每个通道 0..255）

    static uint Ch(uint p, int shift) => (p >> shift) & 255;
    static uint Pack(uint a, uint r, uint g, uint b) => (a << 24) | (r << 16) | (g << 8) | b;
    static uint Mul(uint x, uint y) => (x * y + 127) / 255;

    /// 每个通道乘 k/255
    static uint Scale(uint p, uint k) => Pack(Mul(Ch(p, 24), k), Mul(Ch(p, 16), k), Mul(Ch(p, 8), k), Mul(Ch(p, 0), k));

    /// 普通叠加：S + D × (1 − Sa)
    static uint Over(uint s, uint d)
    {
        var inv = 255 - Ch(s, 24);
        return Pack(Ch(s, 24) + Mul(Ch(d, 24), inv), Ch(s, 16) + Mul(Ch(d, 16), inv),
                    Ch(s, 8) + Mul(Ch(d, 8), inv), Ch(s, 0) + Mul(Ch(d, 0), inv));
    }

    /// plusLighter：各通道相加，封顶 255
    static uint Plus(uint s, uint d) =>
        Pack(Math.Min(255, Ch(s, 24) + Ch(d, 24)), Math.Min(255, Ch(s, 16) + Ch(d, 16)),
             Math.Min(255, Ch(s, 8) + Ch(d, 8)), Math.Min(255, Ch(s, 0) + Ch(d, 0)));

    /// multiply：S×D + S×(1 − Da) + D×(1 − Sa)；alpha 和普通叠加一样
    static uint Multiply(uint s, uint d)
    {
        uint sa = Ch(s, 24), da = Ch(d, 24);
        uint C(int shift) => Math.Min(255, Mul(Ch(s, shift), Ch(d, shift)) + Mul(Ch(s, shift), 255 - da) + Mul(Ch(d, shift), 255 - sa));
        return Pack(sa + Mul(da, 255 - sa), C(16), C(8), C(0));
    }

    /// 三次盒式模糊的窗口宽度（奇数），合起来近似 σ 的高斯
    internal static int[] Boxes(double sigma)
    {
        const int n = 3;
        var ideal = Math.Sqrt(12 * sigma * sigma / n + 1);
        var wl = (int)Math.Floor(ideal);
        if (wl % 2 == 0) wl--;
        var wu = wl + 2;
        var m = (int)Math.Round((12 * sigma * sigma - n * wl * wl - 4 * n * wl - 3 * n) / (-4.0 * wl - 4));
        return Enumerable.Range(0, n).Select(i => i < m ? wl : wu).ToArray();
    }

    /// 不全透明的像素所在的范围；整层透明时为空
    static Rectangle Bounds(in Pixels px)
    {
        int left = px.W, right = -1, top = -1, bottom = -1;
        for (var y = 0; y < px.H; y++)
        {
            var row = px.P + y * px.W;
            var first = 0;
            while (first < px.W && row[first] == 0) first++;
            if (first == px.W) continue;
            var last = px.W - 1;
            while (row[last] == 0) last--;
            if (top < 0) top = y;
            bottom = y;
            left = Math.Min(left, first);
            right = Math.Max(right, last);
        }
        return top < 0 ? Rectangle.Empty : Rectangle.FromLTRB(left, top, right + 1, bottom + 1);
    }

    /// 在 area 里沿一个方向做盒式模糊，窗口 2r+1，伸出 area 的部分按透明算。stride 是一行的像素数
    static void BoxPass(uint* src, uint* dst, int stride, Rectangle area, int r, bool horizontal)
    {
        int lines = horizontal ? area.Height : area.Width, len = horizontal ? area.Width : area.Height;
        int step = horizontal ? 1 : stride, lineStep = horizontal ? stride : 1;
        var origin = area.Top * stride + area.Left;
        var window = (uint)(2 * r + 1);
        var half = window / 2;
        for (var line = 0; line < lines; line++)
        {
            var s = src + origin + line * lineStep;
            var o = dst + origin + line * lineStep;
            uint sa = 0, sr = 0, sg = 0, sb = 0;
            for (var i = 0; i <= Math.Min(r, len - 1); i++)
            {
                var p = s[i * step];
                sa += Ch(p, 24); sr += Ch(p, 16); sg += Ch(p, 8); sb += Ch(p, 0);
            }
            for (var i = 0; i < len; i++)
            {
                o[i * step] = Pack((sa + half) / window, (sr + half) / window, (sg + half) / window, (sb + half) / window);
                var add = i + r + 1;
                if (add < len)
                {
                    var p = s[add * step];
                    sa += Ch(p, 24); sr += Ch(p, 16); sg += Ch(p, 8); sb += Ch(p, 0);
                }
                var sub = i - r;
                if (sub >= 0)
                {
                    var p = s[sub * step];
                    sa -= Ch(p, 24); sr -= Ch(p, 16); sg -= Ch(p, 8); sb -= Ch(p, 0);
                }
            }
        }
    }

    /// 模糊用的临时缓冲，按最大尺寸留一份，省得每帧在大对象堆上分配
    [ThreadStatic] static uint[]? scratch;
    static uint[] Scratch(int n) => scratch is { } s && s.Length >= n ? s : scratch = new uint[n];

    /// 锁住一层的像素直接读写；Dispose 时解锁
    readonly struct Pixels : IDisposable
    {
        readonly Bitmap bitmap;
        readonly BitmapData data;
        public readonly uint* P;
        public readonly int W, H;

        public Pixels(Layer layer, ImageLockMode mode)
        {
            layer.G.Flush();
            bitmap = layer.bitmap;
            W = bitmap.Width;
            H = bitmap.Height;
            data = bitmap.LockBits(new Rectangle(0, 0, W, H), mode, PixelFormat.Format32bppPArgb);
            P = (uint*)data.Scan0;
        }

        public void Dispose() => bitmap.UnlockBits(data);
    }
}
