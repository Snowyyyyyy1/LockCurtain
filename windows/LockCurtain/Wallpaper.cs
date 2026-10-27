// Wallpaper.cs —— 读取每块屏当前的桌面壁纸和铺法
//
// Mac 版直接抓系统画壁纸的那个窗口；Windows 上壁纸就是文件，按屏问 IDesktopWallpaper（Win8 起）：
//   GetWallpaper(显示器)    这块屏的壁纸路径（每块屏可以不一样）
//   GetPosition()           铺法：填充、适应、拉伸、居中、平铺、跨屏，所有屏共用一个
//   GetBackgroundColor()    适应、居中没铺满时露出的底色；纯色桌面也是它
// 路径是空的或文件已经删掉（幻灯片放映、Windows 聚焦时会这样）退回
// %APPDATA%\Microsoft\Windows\Themes\TranscodedWallpaper（系统转码后的副本，只有一份）。
// 图片读成内存里的副本，不占着文件；按路径和修改时间缓存，壁纸没换就不重复解码。

using System.Drawing;
using System.Runtime.InteropServices;

namespace LockCurtain;

/// 和 DESKTOP_WALLPAPER_POSITION 的取值一一对应
internal enum WallpaperFit { Center, Tile, Stretch, Fit, Fill, Span }

/// 一块屏的壁纸。Image 为 null 表示纯色桌面，只画 Background
internal sealed record WallpaperInfo(Image? Image, WallpaperFit Fit, Color Background);

internal static class Wallpaper
{
    static readonly Dictionary<string, (long Ticks, Image Image)> Cache = new();
    static readonly object Gate = new();

    static readonly string Transcoded = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Microsoft", "Windows", "Themes", "TranscodedWallpaper");

    /// 每块屏的壁纸，按屏幕的 DeviceName 索引。在后台线程上调用
    public static Dictionary<string, WallpaperInfo> Load(IReadOnlyList<Screen> screens)
    {
        var result = new Dictionary<string, WallpaperInfo>();
        IDesktopWallpaper? desktop = null;
        try
        {
            desktop = (IDesktopWallpaper)new DesktopWallpaperClass();
            var fit = (WallpaperFit)desktop.GetPosition();
            var background = FromColorRef(desktop.GetBackgroundColor());
            var paths = MonitorWallpapers(desktop);
            foreach (var screen in screens)
            {
                // 按显示器的矩形对上屏幕；对不上（显示器刚插拔）用第一张
                var path = paths.FirstOrDefault(p => p.Bounds == screen.Bounds).Path ?? paths.FirstOrDefault().Path;
                result[screen.DeviceName] = new WallpaperInfo(LoadImage(path), fit, background);
            }
        }
        catch (Exception e) when (e is COMException or InvalidCastException)
        {
            Log.Write($"IDesktopWallpaper 不可用，所有屏用同一张壁纸、按填充铺: {e.Message}");
            var info = new WallpaperInfo(LoadImage(null), WallpaperFit.Fill, DesktopColor());
            foreach (var screen in screens) result[screen.DeviceName] = info;
        }
        finally
        {
            if (desktop != null) Marshal.ReleaseComObject(desktop);
        }
        // 这次没用上的图从缓存里拿掉（幻灯片放映会一直换图）。不 Dispose：可能还有遮罩窗口在用，交给 GC
        var live = result.Values.Select(v => v.Image).ToHashSet();
        lock (Gate)
            foreach (var key in Cache.Where(p => !live.Contains(p.Value.Image)).Select(p => p.Key).ToList())
                Cache.Remove(key);
        return result;
    }

    static List<(Rectangle Bounds, string Path)> MonitorWallpapers(IDesktopWallpaper desktop)
    {
        var list = new List<(Rectangle, string)>();
        var count = desktop.GetMonitorDevicePathCount();
        for (uint i = 0; i < count; i++)
        {
            try
            {
                var id = desktop.GetMonitorDevicePathAt(i);
                var r = desktop.GetMonitorRECT(id);    // 没接上的显示器在这里报错，跳过
                list.Add((Rectangle.FromLTRB(r.Left, r.Top, r.Right, r.Bottom), desktop.GetWallpaper(id)));
            }
            catch (COMException) { }
        }
        return list;
    }

    /// 先读给定的路径，读不到退回系统转码的副本；都没有返回 null（纯色桌面）
    static Image? LoadImage(string? path)
    {
        foreach (var candidate in new[] { path, Transcoded })
        {
            if (string.IsNullOrEmpty(candidate)) continue;
            try
            {
                var info = new FileInfo(candidate);
                if (!info.Exists || info.Length == 0) continue;
                var ticks = info.LastWriteTimeUtc.Ticks;
                lock (Gate)
                {
                    if (Cache.TryGetValue(candidate, out var hit) && hit.Ticks == ticks) return hit.Image;
                    var image = Image.FromStream(new MemoryStream(File.ReadAllBytes(candidate)));
                    Cache[candidate] = (ticks, image);
                    Log.Write($"wallpaper loaded {candidate} {image.Width}x{image.Height}");
                    return image;
                }
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException or OutOfMemoryException)
            {
                Log.Write($"wallpaper {candidate} 读取失败: {e.Message}");
            }
        }
        return null;
    }

    /// IDesktopWallpaper 不可用时的纯色背景
    static Color DesktopColor() => FromColorRef(Native.GetSysColor(Native.COLOR_DESKTOP));

    static Color FromColorRef(uint c) => Color.FromArgb((int)(c & 0xFF), (int)((c >> 8) & 0xFF), (int)((c >> 16) & 0xFF));

    [ComImport, Guid("C2CF3110-460E-4FC1-B9D0-8A1C0C9CC4BD")]
    class DesktopWallpaperClass { }

    /// ShObjIdl_core.h 里的 IDesktopWallpaper，只声明到 GetPosition（vtable 顺序不能改）
    [ComImport, Guid("B92B56A9-8B55-4E14-9A89-0199BBB6F93B"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IDesktopWallpaper
    {
        void SetWallpaper([MarshalAs(UnmanagedType.LPWStr)] string? monitorId, [MarshalAs(UnmanagedType.LPWStr)] string wallpaper);
        [return: MarshalAs(UnmanagedType.LPWStr)]
        string GetWallpaper([MarshalAs(UnmanagedType.LPWStr)] string? monitorId);
        [return: MarshalAs(UnmanagedType.LPWStr)]
        string GetMonitorDevicePathAt(uint monitorIndex);
        uint GetMonitorDevicePathCount();
        Native.RECT GetMonitorRECT([MarshalAs(UnmanagedType.LPWStr)] string monitorId);
        void SetBackgroundColor(uint color);
        uint GetBackgroundColor();
        void SetPosition(int position);
        int GetPosition();
    }
}
