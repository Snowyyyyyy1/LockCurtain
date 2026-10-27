// Wallpaper.cs —— 读取当前桌面壁纸
//
// Mac 版直接抓系统画壁纸的那个窗口；Windows 上壁纸就是一个文件，直接读：
//   1. SPI_GETDESKWALLPAPER 返回的路径（用户选的那张图）
//   2. %APPDATA%\Microsoft\Windows\Themes\TranscodedWallpaper（系统转码后的副本，
//      幻灯片放映、Windows 聚焦时第 1 条可能是空的或已经删掉）
// 都没有（纯色背景）时返回 null，遮罩用桌面背景色。
// 读成内存里的副本，不占着文件；按路径和修改时间缓存，壁纸没换就不重复解码。

using System.Drawing;
using System.Text;

namespace LockCurtain;

internal static class Wallpaper
{
    static string? cachedKey;
    static Image? cachedImage;
    static readonly object Gate = new();

    public static Image? Load()
    {
        foreach (var path in Candidates())
        {
            try
            {
                var info = new FileInfo(path);
                if (!info.Exists || info.Length == 0) continue;
                var key = $"{path}|{info.LastWriteTimeUtc.Ticks}";
                lock (Gate)
                {
                    if (key == cachedKey && cachedImage != null) return cachedImage;
                    var image = Image.FromStream(new MemoryStream(File.ReadAllBytes(path)));
                    cachedImage?.Dispose();
                    (cachedKey, cachedImage) = (key, image);
                    Log.Write($"wallpaper loaded {path} {image.Width}x{image.Height}");
                    return image;
                }
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException or OutOfMemoryException)
            {
                Log.Write($"wallpaper {path} 读取失败: {e.Message}");
            }
        }
        return null;
    }

    /// 纯色桌面时用的背景色
    public static Color DesktopColor()
    {
        var c = Native.GetSysColor(Native.COLOR_DESKTOP);
        return Color.FromArgb((int)(c & 0xFF), (int)((c >> 8) & 0xFF), (int)((c >> 16) & 0xFF));
    }

    static IEnumerable<string> Candidates()
    {
        var buf = new StringBuilder(1024);
        if (Native.SystemParametersInfoW(Native.SPI_GETDESKWALLPAPER, (uint)buf.Capacity, buf, 0) && buf.Length > 0)
            yield return buf.ToString();
        yield return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                                  "Microsoft", "Windows", "Themes", "TranscodedWallpaper");
    }
}
