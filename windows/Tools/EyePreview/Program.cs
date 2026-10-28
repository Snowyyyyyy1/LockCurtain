// EyePreview —— 离线渲染遮罩动画图案，不用开遮罩就能检查（对应 Mac 版 Tools/EyePreview.swift）
//
//   cd windows && dotnet publish Tools/EyePreview -c Release -r win-arm64 --self-contained \
//     -p:PublishSingleFile=true -o dist/eyepreview
//   在 Windows 上：EyePreview.exe <输出目录> [图案名，默认全部] [秒数，默认 120] [逐帧检查的边长，默认 160]
//   图案名和 settings.json 里的一样：mechEye / demonEye / talisman / clock / vault / padlock
//
// 1. 按遮罩的 30 帧/秒把 N 秒逐帧画一遍，打印每帧平均耗时（遮罩可能挂几个小时，别太费 CPU）。GDI+ 遇到退化的图形（零面积路径、重合的渐变端点）
//    会直接抛异常，而遮罩的 OnPaint 抛一次异常后整个窗口就不再绘制，所以每一帧都要能画出来。
//    有帧抛异常时打印 t 和调用栈，退出码 1。
// 2. 每个图案输出 <输出目录>\<图案名>-sheet.png：4×2 拼图，每帧间隔 0.9 秒，起点和底色同 Mac 版，可以并排对照。
//
// EyePreview.exe <输出目录> backgrounds [要模糊的图]：遮罩背景（CurtainBackground.cs）。星空、远山、碳纤维按 1280×800 像素、
// 1 倍和 2 倍各画一张，打印耗时，存成 <背景名>-1x.png / -2x.png；给了图就再按「模糊壁纸」处理，存成 blurred.png。
// 同样的尺寸和图交给 Mac 版画，两边应该一样。
//
// EyePreview.exe <输出目录> glyphs：托盘图标（TrayGlyphs.cs）。锁开着、锁上、杯子按 100%～300% 缩放的托盘尺寸
// （16、20、24、32、40、48 像素）各画一行，左半是深色任务栏、右半是浅色，存成 tray-glyphs.png。

using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Text.Json;
using LockCurtain;

var outDir = args.Length > 0 ? args[0] : ".";
if (args.Length > 1 && args[1] == "backgrounds")
{
    foreach (var scale in new[] { 1f, 2f })
        foreach (var b in new[] { CurtainBackground.Starfield, CurtainBackground.Hills, CurtainBackground.Carbon })
        {
            var clock = System.Diagnostics.Stopwatch.StartNew();
            using var image = b.Render(1280, 800, scale)!;
            Console.WriteLine($"{b} {scale}x {clock.ElapsedMilliseconds} ms");
            image.Save(Path.Combine(outDir, $"{JsonNamingPolicy.CamelCase.ConvertName(b.ToString())}-{scale}x.png"), ImageFormat.Png);
        }
    if (args.Length > 2)
    {
        using var input = Image.FromFile(args[2]);
        using var blurred = CurtainBackgrounds.Blur(input);
        blurred.Save(Path.Combine(outDir, "blurred.png"), ImageFormat.Png);
    }
    return 0;
}
if (args.Length > 1 && args[1] == "glyphs")
{
    int[] sizes = [16, 20, 24, 32, 40, 48];
    Action<Graphics, Brush, float>[] glyphs =
        [(g, b, s) => TrayApp.DrawMac(g, b, s, locked: false), (g, b, s) => TrayApp.DrawMac(g, b, s, locked: true), TrayApp.DrawCup];
    (Color Back, Color Fore)[] taskbars = [(Color.FromArgb(0x20, 0x20, 0x20), Color.White), (Color.FromArgb(0xF3, 0xF3, 0xF3), Color.Black)];
    const int cell = 56;
    using var sheet = new Bitmap(cell * glyphs.Length * taskbars.Length, cell * sizes.Length);
    using (var g = Graphics.FromImage(sheet))
    {
        g.InterpolationMode = InterpolationMode.NearestNeighbor;
        for (var t = 0; t < taskbars.Length; t++)
        {
            using var back = new SolidBrush(taskbars[t].Back);
            g.FillRectangle(back, t * cell * glyphs.Length, 0, cell * glyphs.Length, sheet.Height);
            for (var r = 0; r < sizes.Length; r++)
                for (var c = 0; c < glyphs.Length; c++)
                {
                    var size = sizes[r];
                    using var glyph = TrayApp.GlyphImage(size, taskbars[t].Fore, glyphs[c]);
                    g.DrawImage(glyph, new Rectangle((t * glyphs.Length + c) * cell + (cell - size) / 2, r * cell + (cell - size) / 2, size, size));
                }
        }
    }
    sheet.Save(Path.Combine(outDir, "tray-glyphs.png"), ImageFormat.Png);
    return 0;
}
var arts = Enum.GetValues<CurtainArt>().Where(a => a.Draw() != null).ToList();
if (args.Length > 1 && args[1] != "all")
{
    arts = arts.Where(a => Name(a) == args[1]).ToList();
    if (arts.Count == 0)
    {
        Console.WriteLine("只能预览动画图案：" + string.Join(" / ", Enum.GetValues<CurtainArt>().Where(a => a.Draw() != null).Select(Name)));
        return 2;
    }
}
var seconds = args.Length > 2 ? double.Parse(args[2]) : 120;
var frameSize = args.Length > 3 ? int.Parse(args[3]) : 160;   // 200% 缩放的屏上遮罩里是 320
var background = Color.FromArgb(26, 28, 43);    // Mac 版的 (0.10, 0.11, 0.17)
const double t0 = 1000;                          // 任取一个起点；整个图案只由 t 决定

var failed = false;
foreach (var art in arts)
{
    var draw = art.Draw()!;
    using var frame = new Bitmap(frameSize, frameSize, PixelFormat.Format32bppPArgb);
    using var fg = Graphics.FromImage(frame);
    fg.SmoothingMode = SmoothingMode.AntiAlias;
    int frames = (int)(seconds * 30) + 1, failures = 0;
    var clock = System.Diagnostics.Stopwatch.StartNew();
    for (var i = 0; i < frames; i++)
    {
        var t = t0 + i / 30.0;
        fg.Clear(background);
        var state = fg.Save();
        try { draw(fg, frameSize, t); }
        catch (Exception e) { if (failures++ < 3) Console.WriteLine($"{Name(art)} t={t:F3}: {e}\n"); }
        finally { fg.Restore(state); }
    }
    Console.WriteLine($"{Name(art)}：{frames} 帧，{failures} 帧抛异常，{frameSize}px 每帧平均 {clock.Elapsed.TotalMilliseconds / frames:F2} ms");
    failed |= failures > 0;

    const int cell = 300, cols = 4, rows = 2;
    using var sheet = new Bitmap(cell * cols, cell * rows, PixelFormat.Format32bppPArgb);
    using (var g = Graphics.FromImage(sheet))
    {
        g.Clear(background);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        for (var k = 0; k < cols * rows; k++)
        {
            var state = g.Save();
            g.TranslateTransform(k % cols * cell, k / cols * cell);
            try { draw(g, cell, t0 + k * 0.9); }
            catch (Exception e) { Console.WriteLine($"{Name(art)} 拼图 t={t0 + k * 0.9:F3}: {e.Message}"); }
            g.Restore(state);
        }
    }
    var path = Path.Combine(outDir, $"{Name(art)}-sheet.png");
    sheet.Save(path, ImageFormat.Png);
    Console.WriteLine(path);
}
return failed ? 1 : 0;

static string Name(CurtainArt art) => JsonNamingPolicy.CamelCase.ConvertName(art.ToString());
