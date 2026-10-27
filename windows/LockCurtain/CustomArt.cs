// CustomArt.cs —— 「自定义图片」图案：用户选的图，没选就用账户头像（对应 Mac 版 CurtainArt.swift 的 CustomImageArt / CurtainImage）
//
// 选的图按 EXIF 方向转正、缩到最长边 512px，存进 %LOCALAPPDATA%\LockCurtain\，settings.json 里只记文件名，
// 原图挪走、删掉都不影响。带透明的存 PNG，不带的存 JPEG（质量 90）。
// 裁成圆形时像锁屏头像：直径 120 的圆，里面一圈 2 宽、0.9 白的描边；不裁就按原比例放进 140 的方框。
// 两种都带投影（黑 0.45、半径 10、下移 5）。图不会动，整张连投影画一次缓存起来：
// GDI+ 没有模糊，投影是把剪影缩小再放大画出来的，透明 PNG 的投影也跟着图的形状走。

using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using Microsoft.Win32;

namespace LockCurtain;

internal static class CustomArt
{
    /// 遮罩上最大 140 逻辑像素，200% 缩放下 280px 就够，留一点余量（和 Mac 版一样）
    const int MaxPixels = 512;
    /// 布局空间：图案方框边长 140，圆的直径 120
    const float Box = 140, Diameter = 120;
    const float ShadowBlur = 10, ShadowY = 5, ShadowOpacity = 0.45f;

    /// 当前这张图（设置的文件名 + 是否裁圆）和按尺寸缓存的成品
    static string? sourceKey;
    static Image? source;
    static readonly Dictionary<(int Side, bool Round), Bitmap> rendered = new();

    /// 打开文件对话框用的过滤器：GDI+ 能读的格式
    public const string FileFilter = "图片|*.png;*.jpg;*.jpeg;*.bmp;*.gif;*.tif;*.tiff";

    public static void Draw(Graphics g, float side, double t)
    {
        var round = Settings.Current.CurtainImageRound;
        var key = Settings.Current.CurtainImage ?? "";
        if (sourceKey != key)
        {
            Forget();
            source = Load(key);
            sourceKey = key;
        }
        if (source == null) return;
        int px = Math.Max(1, (int)Math.Round(side));
        if (!rendered.TryGetValue((px, round), out var bmp))
            rendered[(px, round)] = bmp = Render(source, px, round);
        var pad = (bmp.Width - px) / 2;
        g.DrawImage(bmp, -pad, -pad, bmp.Width, bmp.Height);
    }

    /// 选的图缩好存进设置目录，返回新文件名；读不了返回 null
    public static string? Import(string path)
    {
        using var img = LoadScaled(path);
        if (img == null) return null;
        var alpha = Image.IsAlphaPixelFormat(img.PixelFormat);
        var name = $"curtain-image-{Guid.NewGuid():N}.{(alpha ? "png" : "jpg")}";
        try
        {
            Directory.CreateDirectory(Log.Dir);
            var file = Path.Combine(Log.Dir, name);
            if (alpha) img.Save(file, ImageFormat.Png);
            else
            {
                using var quality = new EncoderParameters(1);
                quality.Param[0] = new EncoderParameter(Encoder.Quality, 90L);
                img.Save(file, ImageCodecInfo.GetImageEncoders().First(c => c.FormatID == ImageFormat.Jpeg.Guid), quality);
            }
            return name;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ExternalException)
        {
            Log.Write($"自定义图片存不进去: {e.Message}");
            return null;
        }
    }

    /// 换了图以后删掉旧的那份
    public static void Delete(string? name)
    {
        if (string.IsNullOrEmpty(name)) return;
        try { File.Delete(Path.Combine(Log.Dir, Path.GetFileName(name))); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { Log.Write($"旧的自定义图片删不掉: {e.Message}"); }
    }

    /// 下次画时重新读图：每次铺遮罩调一次，用户换了账户头像也能跟上（和 Mac 版一样）
    public static void Reload()
    {
        Forget();
        sourceKey = null;
    }

    static void Forget()
    {
        foreach (var b in rendered.Values) b.Dispose();
        rendered.Clear();
        source?.Dispose();
        source = null;
    }

    /// 自己选的图；没选或读不了就用账户头像，再读不到用系统通用的账户图标
    static Image? Load(string name) =>
        (name != "" ? LoadScaled(Path.Combine(Log.Dir, Path.GetFileName(name))) : null)
        ?? AccountPicturePaths().Select(LoadScaled).FirstOrDefault(i => i != null);

    /// 设置 → 账户 → 你的信息 里的头像（微软账户和本地账户都写在这里），然后是通用图标
    static IEnumerable<string> AccountPicturePaths()
    {
        using (var key = Registry.LocalMachine.OpenSubKey(
                   $@"SOFTWARE\Microsoft\Windows\CurrentVersion\AccountPicture\Users\{ControlServer.CurrentUser.Value}"))
        {
            foreach (var size in new[] { "Image448", "Image1080", "Image240", "Image208", "Image192" })
                if (key?.GetValue(size) is string p) yield return p;
        }
        var common = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
                                  "Microsoft", "User Account Pictures");
        yield return Path.Combine(common, "user.png");
        yield return Path.Combine(common, "user-192.png");
    }

    /// 读一张图，按 EXIF 方向转正，缩到 MaxPixels 以内；读不了返回 null。不占着原文件
    static Bitmap? LoadScaled(string path)
    {
        try
        {
            using var src = Image.FromStream(new MemoryStream(File.ReadAllBytes(path)));
            Orient(src);
            double k = Math.Min(1, MaxPixels / (double)Math.Max(src.Width, src.Height));
            int w = Math.Max(1, (int)Math.Round(src.Width * k)), h = Math.Max(1, (int)Math.Round(src.Height * k));
            var alpha = Image.IsAlphaPixelFormat(src.PixelFormat);
            var dst = new Bitmap(w, h, alpha ? PixelFormat.Format32bppArgb : PixelFormat.Format24bppRgb);
            using var g = Graphics.FromImage(dst);
            DrawSmooth(g, src, new RectangleF(0, 0, w, h));
            return dst;
        }
        // GDI+ 认不出的格式抛 ArgumentException（老版本是 OutOfMemoryException）
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException
                                       or OutOfMemoryException or ExternalException)
        {
            Log.Write($"读不了图片 {path}: {e.Message}");
            return null;
        }
    }

    /// EXIF Orientation（0x0112）1–8 → 转正
    static void Orient(Image img)
    {
        if (!img.PropertyIdList.Contains(0x0112) || img.GetPropertyItem(0x0112)?.Value is not [var o, ..]) return;
        var flip = o switch
        {
            2 => RotateFlipType.RotateNoneFlipX,
            3 => RotateFlipType.Rotate180FlipNone,
            4 => RotateFlipType.Rotate180FlipX,
            5 => RotateFlipType.Rotate90FlipX,
            6 => RotateFlipType.Rotate90FlipNone,
            7 => RotateFlipType.Rotate270FlipX,
            8 => RotateFlipType.Rotate270FlipNone,
            _ => RotateFlipType.RotateNoneFlipNone,
        };
        img.RotateFlip(flip);
    }

    /// 高质量缩放；边缘按镜像取样，不然缩小后四周会有一圈半透明的边
    static void DrawSmooth(Graphics g, Image img, RectangleF dst, ImageAttributes? attrs = null)
    {
        g.InterpolationMode = InterpolationMode.HighQualityBicubic;
        g.PixelOffsetMode = PixelOffsetMode.HighQuality;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        using var own = attrs == null ? new ImageAttributes() : null;
        var a = attrs ?? own!;
        a.SetWrapMode(WrapMode.TileFlipXY);
        g.DrawImage(img, Rectangle.Round(dst), 0, 0, img.Width, img.Height, GraphicsUnit.Pixel, a);
    }

    /// 边长 side 像素的成品：四周留出投影的位置，图案方框在正中
    static Bitmap Render(Image img, int side, bool round)
    {
        float s = side / Box;
        int pad = (int)Math.Ceiling((ShadowBlur * 2 + ShadowY) * s);
        int full = side + pad * 2;

        using var art = new Bitmap(full, full, PixelFormat.Format32bppPArgb);
        using (var g = Graphics.FromImage(art))
        {
            g.TranslateTransform(pad + side / 2f, pad + side / 2f);
            if (round)
            {
                // scaledToFill：短边铺满直径，长边居中裁掉
                float d = Diameter * s, k = d / Math.Min(img.Width, img.Height);
                using var circle = ArtKit.Circle(d / 2);
                var state = g.Save();
                g.SetClip(circle);
                DrawSmooth(g, img, new RectangleF(-img.Width * k / 2, -img.Height * k / 2, img.Width * k, img.Height * k));
                g.Restore(state);
                // strokeBorder：描边整个落在圆里面
                float b = 2 * s;
                using var pen = new Pen(Color.FromArgb(230, 255, 255, 255), b);
                g.SmoothingMode = SmoothingMode.AntiAlias;
                g.DrawEllipse(pen, -d / 2 + b / 2, -d / 2 + b / 2, d - b, d - b);
            }
            else
            {
                // scaledToFit：整张放进方框
                float k = Box * s / Math.Max(img.Width, img.Height);
                DrawSmooth(g, img, new RectangleF(-img.Width * k / 2, -img.Height * k / 2, img.Width * k, img.Height * k));
            }
        }

        // 投影：剪影涂黑缩小到 1/(半径/2)，再用双线性放大回来，边缘就糊开了
        float shrink = Math.Max(1, ShadowBlur * s / 2);
        int small = Math.Max(1, (int)Math.Round(full / shrink));
        using var blur = new Bitmap(small, small, PixelFormat.Format32bppPArgb);
        using (var g = Graphics.FromImage(blur))
        using (var black = new ImageAttributes())
        {
            black.SetColorMatrix(new ColorMatrix(new[]
            {
                new float[] { 0, 0, 0, 0, 0 },
                new float[] { 0, 0, 0, 0, 0 },
                new float[] { 0, 0, 0, 0, 0 },
                new float[] { 0, 0, 0, ShadowOpacity, 0 },
                new float[] { 0, 0, 0, 0, 1 },
            }));
            DrawSmooth(g, art, new RectangleF(0, 0, small, small), black);
        }

        var result = new Bitmap(full, full, PixelFormat.Format32bppPArgb);
        using (var g = Graphics.FromImage(result))
        {
            g.InterpolationMode = InterpolationMode.HighQualityBilinear;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            using var clamp = new ImageAttributes();
            clamp.SetWrapMode(WrapMode.TileFlipXY);
            g.DrawImage(blur, new Rectangle(0, (int)Math.Round(ShadowY * s), full, full), 0, 0, small, small, GraphicsUnit.Pixel, clamp);
            g.DrawImage(art, 0, 0, full, full);
        }
        return result;
    }
}
