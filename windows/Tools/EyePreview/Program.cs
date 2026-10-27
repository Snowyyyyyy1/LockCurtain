// EyePreview —— 离线渲染机械眼，不用开遮罩就能检查（对应 Mac 版 Tools/EyePreview.swift）
//
//   cd windows && dotnet publish Tools/EyePreview -c Release -r win-arm64 --self-contained \
//     -p:PublishSingleFile=true -o dist/eyepreview
//   在 Windows 上：EyePreview.exe <输出目录> [秒数，默认 120]
//
// 1. 按遮罩的 30 帧/秒把前 N 秒逐帧画一遍。GDI+ 遇到退化的图形（零面积路径、重合的渐变端点）
//    会直接抛异常，而遮罩的 OnPaint 抛一次异常后整个窗口就不再绘制，所以每一帧都要能画出来。
//    有帧抛异常时打印 t 和调用栈，退出码 1。
// 2. 输出 <输出目录>\eye-sheet.png：4×2 拼图，每帧间隔 0.9 秒，起点和底色同 Mac 版，可以并排对照。

using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using LockCurtain;

var outDir = args.Length > 0 ? args[0] : ".";
var seconds = args.Length > 1 ? double.Parse(args[1]) : 120;
var background = Color.FromArgb(26, 28, 43);    // Mac 版的 (0.10, 0.11, 0.17)

const int frameSize = 160;
using var frame = new Bitmap(frameSize, frameSize, PixelFormat.Format32bppPArgb);
using var fg = Graphics.FromImage(frame);
fg.SmoothingMode = SmoothingMode.AntiAlias;
int frames = (int)(seconds * 30) + 1, failures = 0;
for (var i = 0; i < frames; i++)
{
    var t = i / 30.0;
    fg.Clear(background);
    var state = fg.Save();
    try { MechEye.Draw(fg, frameSize, t); }
    catch (Exception e) { if (failures++ < 3) Console.WriteLine($"t={t:F3}: {e}\n"); }
    finally { fg.Restore(state); }
}
Console.WriteLine($"{frames} 帧，{failures} 帧抛异常");

const double t0 = 1000;
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
        MechEye.Draw(g, cell, t0 + k * 0.9);
        g.Restore(state);
    }
}
var path = Path.Combine(outDir, "eye-sheet.png");
sheet.Save(path, ImageFormat.Png);
Console.WriteLine(path);
return failures == 0 ? 0 : 1;
