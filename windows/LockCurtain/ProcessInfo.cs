// ProcessInfo.cs —— 进程的路径、显示名和图标（对应 Mac 版 NSRunningApplication 的 localizedName / icon）
//
// 托盘面板列「谁在阻止睡眠」、保持唤醒挑程序时用。powercfg 给的是设备路径（\Device\HarddiskVolume3\...），
// 要换成盘符路径才读得到文件说明和图标。显示名和图标按路径缓存，面板每 2 秒刷新不用重读。

using System.Diagnostics;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Text;

namespace LockCurtain;

internal static class ProcessInfo
{
    static readonly Dictionary<string, string> titles = new(StringComparer.OrdinalIgnoreCase);
    static readonly Dictionary<(string, int), Bitmap?> icons = new();

    /// exe 的完整路径；进程没了、权限不够时返回 null
    public static string? PathOf(int pid)
    {
        var h = Native.OpenProcess(Native.PROCESS_QUERY_LIMITED_INFORMATION, false, (uint)pid);
        if (h == 0) return null;
        try
        {
            var name = new StringBuilder(1024);
            var size = name.Capacity;
            return Native.QueryFullProcessImageNameW(h, 0, name, ref size) ? name.ToString(0, size) : null;
        }
        finally { Native.CloseHandle(h); }
    }

    /// 在任务栏、Alt+Tab 里有窗口的进程。挑窗口的规则和 Alt+Tab 一样：可见、没被 DWM 藏起来（挂在后台的 UWP、
    /// 输入法面板这类）、没有 owner、不是工具窗口、有标题。UWP 程序的外框属于 ApplicationFrameHost，换成里面
    /// CoreWindow 的进程；最小化的 UWP 程序 CoreWindow 不在外框里，就不列
    public static HashSet<int> WithWindows()
    {
        var pids = new HashSet<int>();
        var cls = new StringBuilder(64);
        Native.EnumWindows((h, _) =>
        {
            if (!Native.IsWindowVisible(h) || Native.GetWindow(h, Native.GW_OWNER) != 0 || Native.GetWindowTextLengthW(h) == 0) return true;
            var ex = Native.GetWindowLongPtrW(h, Native.GWL_EXSTYLE);
            if ((ex & Native.WS_EX_TOOLWINDOW) != 0 && (ex & Native.WS_EX_APPWINDOW) == 0) return true;
            if (Native.IsCloaked(h)) return true;
            Native.GetWindowThreadProcessId(h, out var pid);
            Native.GetClassNameW(h, cls, cls.Capacity);
            if (cls.ToString() == "ApplicationFrameWindow")
            {
                pid = 0;
                Native.EnumChildWindows(h, (child, _) =>
                {
                    Native.GetClassNameW(child, cls, cls.Capacity);
                    if (cls.ToString() != "Windows.UI.Core.CoreWindow") return true;
                    Native.GetWindowThreadProcessId(child, out pid);
                    return false;
                }, 0);
            }
            if (pid != 0) pids.Add((int)pid);
            return true;
        }, 0);
        return pids;
    }

    /// \Device\HarddiskVolume3\Windows\x.exe → C:\Windows\x.exe；换不了原样返回
    public static string DosPath(string path)
    {
        if (!path.StartsWith(@"\Device\", StringComparison.OrdinalIgnoreCase)) return path;
        var target = new StringBuilder(1024);
        foreach (var drive in Environment.GetLogicalDrives())
        {
            var letter = drive.TrimEnd('\\');
            if (Native.QueryDosDeviceW(letter, target, target.Capacity) == 0) continue;
            var device = target.ToString() + @"\";
            if (path.StartsWith(device, StringComparison.OrdinalIgnoreCase)) return letter + @"\" + path[device.Length..];
        }
        return path;
    }

    /// 显示名：exe 的「文件说明」（比如 Google Chrome），没有就用不带 .exe 的文件名
    public static string Title(string path)
    {
        if (titles.TryGetValue(path, out var title)) return title;
        try { title = FileVersionInfo.GetVersionInfo(path).FileDescription?.Trim(); }
        catch (FileNotFoundException) { }
        if (string.IsNullOrEmpty(title)) title = Path.GetFileNameWithoutExtension(path);
        return titles[path] = title;
    }

    /// 正在跑的进程的显示名：商店应用用「开始」菜单里的名字（Win11 记事本的文件说明只是 Notepad.exe），其余同 Title(path)
    public static string Title(int pid, string path) => PackagedTitle(pid) ?? Title(path);

    /// 打包应用的 AppUserModelID 拿去 shell:AppsFolder 里查名字；不是打包应用返回 null
    static string? PackagedTitle(int pid)
    {
        var h = Native.OpenProcess(Native.PROCESS_QUERY_LIMITED_INFORMATION, false, (uint)pid);
        if (h == 0) return null;
        try
        {
            var id = new StringBuilder(256);
            var length = (uint)id.Capacity;
            if (Native.GetApplicationUserModelId(h, ref length, id) != 0) return null;
            if (Native.SHParseDisplayName(@"shell:AppsFolder\" + id, 0, out var pidl, 0, out _) != 0) return null;
            try
            {
                var info = new Native.SHFILEINFO();
                var ok = Native.SHGetFileInfoW(pidl, 0, ref info, (uint)Marshal.SizeOf<Native.SHFILEINFO>(),
                                               Native.SHGFI_PIDL | Native.SHGFI_DISPLAYNAME) != 0;
                return ok && info.szDisplayName.Length > 0 ? info.szDisplayName : null;
            }
            finally { Marshal.FreeCoTaskMem(pidl); }
        }
        finally { Native.CloseHandle(h); }
    }

    /// 程序图标，缩到 size 像素见方；拿不到返回 null。缓存里的图不要释放
    public static Bitmap? Icon(string path, int size)
    {
        if (icons.TryGetValue((path, size), out var cached)) return cached;
        Bitmap? bmp = null;
        try
        {
            using var icon = System.Drawing.Icon.ExtractAssociatedIcon(path);
            if (icon != null)
            {
                using var big = icon.ToBitmap();
                bmp = new Bitmap(size, size);
                using var g = Graphics.FromImage(bmp);
                g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
                g.DrawImage(big, 0, 0, size, size);
            }
        }
        catch (Exception e) when (e is FileNotFoundException or ArgumentException or IOException or UnauthorizedAccessException) { }
        return icons[(path, size)] = bmp;
    }
}
