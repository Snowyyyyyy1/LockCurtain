// Updater.cs —— 自动更新：检查、提示、下载、验签交给 WinSparkle，安装交给 install.ps1
//
// 更新包是 Release 上的 LockCurtain-<版本>-win-<架构>.zip（windows/build.sh 打的包：LockCurtainApp.exe（uiAccess 主程序）、
// LockCurtain.exe（启动器）、WinSparkle.dll、install.ps1、LockCurtainCtl.exe（占位文件，为兼容 1.0.2 的更新器名字检查）），
// appcast-windows.xml 里每个架构一个 enclosure，带 Ed25519 签名（release.sh 签）。
// 用户点「安装更新」、WinSparkle 验签通过后：把整个 zip 解压到暂存目录，此刻不动正在用的文件、不杀进程（遮罩可能正升着）。
// 到了能退出的时候（遮罩没在显示）才起一个独立的 powershell 跑暂存目录里的 install.ps1，然后本进程退出：
// install.ps1 杀旧进程、复制文件、重新给 LockCurtainApp.exe 签名、重注册计划任务，由计划任务经启动器 LockCurtain.exe ShellExecute 起主程序。
// 不能像以前那样就地换文件：app.manifest 要求 uiAccess，exe 必须在 Program Files 里且被本机信任的证书签名，
// 未签名的新 exe 起不来，CreateProcess 起 uiAccess 的 exe 也会被拒（0x800702E4）。
//
// 以最高权限运行时，WinSparkle 0.9.4 有三处能被普通权限的程序拿来提权（看过它的源码）：
// 1. 下载、验签都在用户的 %TEMP% 里，验完不再验，装之前可以被换掉
//    → 进程的 TMP 指到安装目录下的 updates，只有管理员能写
// 2. 启动时删除 HKCU 里记的 UpdateTempDir，只比较字符串前缀，带 ..\ 就能删别的目录
//    → 它的配置由这里读写，不存也不给它这个值；updates 目录启动时自己清空
// 3. 下载的文件名取自 Content-Disposition，不过滤 ..\，验签之前就写盘
//    → appcast 地址编译时写死，运行时没有任何办法改
// 编译时没给公钥（build.sh 读 LOCKCURTAIN_EDDSA_PUBLIC_KEY）时整个不启用：WinSparkle 没公钥时会接受没签名的更新。

using System.Diagnostics;
using System.Drawing;
using System.IO.Compression;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using Microsoft.Win32;

namespace LockCurtain;

internal static unsafe class Updater
{
    const string Dll = "WinSparkle.dll", Exe = "LockCurtainApp.exe";
    const string RegistryPath = @"Software\LockCurtain\WinSparkle";
    const int CheckIntervalSeconds = 24 * 60 * 60;

    static readonly string Dir = AppContext.BaseDirectory.TrimEnd('\\');
    static readonly string UpdatesDir = Path.Combine(Dir, "updates");
    static readonly bool Elevated = ElevatedTask.IsElevated();
    /// 暂存目录：更新包整个解压到这里，退出时跑里面的 install.ps1。
    /// 以最高权限运行时 TMP 指到安装目录下的 updates（见 Start），这里也就是只有管理员能写的目录
    static string StageDir => Path.Combine(Path.GetTempPath(), "LockCurtainUpdate");
    /// 已解压、等着退出时安装的暂存目录；null 表示没有待安装的更新
    static string? stage;
    static Func<bool> idle = () => false;
    static Action exit = () => { };
    static System.Windows.Forms.Timer? timer;
    static Icon? smallIcon, bigIcon;
    static uint uiThread;

    /// 编进了公钥、旁边有 WinSparkle.dll、装的位置安全：菜单和设置里才出现检查更新
    public static bool Available { get; private set; }

    /// idle：遮罩没在显示（可以退出）；exit：退出 LockCurtain，WinSparkle 的线程调来，要自己转回界面线程
    public static void Start(Func<bool> idle, Action exit)
    {
        if (Metadata("EdDSAPublicKey") is not { } key || Metadata("AppcastUrl") is not { } url) return;
        if (Elevated && !Dir.StartsWith(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles) + @"\", StringComparison.OrdinalIgnoreCase))
        {
            // 普通权限能写的目录里以最高权限运行，旁边的 dll 和下载的更新包都可能被换掉
            Log.Write($"自动更新：以最高权限运行但不在 Program Files 里（{Dir}），不检查更新");
            return;
        }
        if (!File.Exists(Path.Combine(Dir, Dll)))
        {
            Log.Write($"自动更新：{Dir} 里没有 {Dll}，不检查更新");
            return;
        }
        Updater.idle = idle;
        Updater.exit = exit;
        DeleteLeftovers();
        if (Elevated)
        {
            Directory.CreateDirectory(UpdatesDir);
            Environment.SetEnvironmentVariable("TMP", UpdatesDir);
        }

        // 只从 exe 旁边加载，不走系统的 DLL 搜索顺序
        NativeLibrary.SetDllImportResolver(typeof(Updater).Assembly, (name, _, _) =>
            name == Dll ? NativeLibrary.Load(Path.Combine(Dir, Dll)) : 0);
        win_sparkle_set_appcast_url(url);
        if (win_sparkle_set_eddsa_public_key(key) == 0)
        {
            Log.Write("自动更新：编进来的公钥格式不对，不检查更新");
            return;
        }
        win_sparkle_set_app_details("LockCurtain", "LockCurtain", Version);
        // LockCurtain 只有中文界面。要写小写：wxWidgets 把 DLL 里的翻译名转成小写（zh_cn）后区分大小写地比，
        // 写 zh_CN（包括 WinSparkle 自己按系统语言挑的）匹配不上，显示英文
        win_sparkle_set_lang("zh_cn");
        var config = new ConfigMethods { Read = &ConfigRead, Write = &ConfigWrite, Delete = &ConfigDelete };
        win_sparkle_set_config_methods(&config);
        win_sparkle_set_can_shutdown_callback(&CanShutdown);
        win_sparkle_set_shutdown_request_callback(&ShutdownRequest);
        win_sparkle_set_user_run_installer_callback(&RunInstaller);
        UseAppIconForDialogs();
        win_sparkle_init();
        Available = true;
        Log.Write($"自动更新：{Version}，{url}");

        // 自动检查自己定时做：WinSparkle 只在启动时看一次开关，之后打开不生效。启动一分钟后第一次，之后每小时看一眼
        timer = new System.Windows.Forms.Timer { Interval = 60 * 1000 };
        timer.Tick += (_, _) =>
        {
            timer.Interval = 60 * 60 * 1000;
            // 遮罩显示中不查：发现更新弹的窗口会被遮罩挡住
            if (!Settings.Current.AutoCheckUpdates || !idle()) return;
            var last = win_sparkle_get_last_check_time();
            if (last > 0 && DateTimeOffset.UtcNow.ToUnixTimeSeconds() - last < CheckIntervalSeconds) return;
            win_sparkle_check_update_without_ui();
        };
        timer.Start();
    }

    /// 托盘菜单「检查更新…」：没有更新也会告诉用户
    public static void CheckNow() => win_sparkle_check_update_with_ui();

    public static void Stop()
    {
        if (!Available) return;
        timer!.Dispose();
        win_sparkle_cleanup();
    }

    /// 遮罩没在显示、可以退出了才调用（TrayApp.ExitAfterUpdate 的闸）：
    /// 起一个独立的 powershell 跑暂存目录里的 install.ps1，然后调用方退出。
    /// install.ps1 会 Kill 掉名为 LockCurtain 的进程，所以它必须是独立进程，不能等它；
    /// 本进程以计划任务的最高权限运行，子 powershell 继承管理员令牌，install.ps1 走 admin 分支、不弹 UAC
    /// （不能传 -Verb RunAs：会二次弹 UAC）。
    public static void InstallPending()
    {
        if (stage is not { } dir) return;
        stage = null;
        var script = Path.Combine(dir, "install.ps1");
        try
        {
            using var p = Process.Start(new ProcessStartInfo("powershell.exe",
                $"-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"{script}\"")
            {
                UseShellExecute = false,
                CreateNoWindow = true,
            }) ?? throw new InvalidOperationException("powershell.exe 没能启动");
            Log.Write($"自动更新：已启动安装程序 {script}（pid {p.Id}），退出");
        }
        catch (Exception e)
        {
            Log.Write($"自动更新：启动安装程序失败: {e}");
        }
    }

    internal static string Version => Application.ProductVersion.Split('+')[0];

    /// 编译时写进程序集的值（LockCurtain.csproj 的 AssemblyMetadata，build.sh 传进来）
    static string? Metadata(string key) => typeof(Updater).Assembly.GetCustomAttributes<AssemblyMetadataAttribute>()
        .FirstOrDefault(a => a.Key == key)?.Value is { Length: > 0 } value ? value : null;

    /// WinSparkle 窗口标题栏的图标是它 DLL 里写死的（ui.cpp），窗口一出现就换成 LockCurtain 的。
    /// 它的窗口都建在它自己的线程上：进程里不是界面线程建的顶层窗口就是它的
    static void UseAppIconForDialogs()
    {
        smallIcon = Icon.ExtractIcon(Environment.ProcessPath!, 0, SystemInformation.SmallIconSize.Width);
        bigIcon = Icon.ExtractIcon(Environment.ProcessPath!, 0, SystemInformation.IconSize.Width);
        uiThread = Native.GetCurrentThreadId();
        SetWinEventHook(EVENT_OBJECT_SHOW, EVENT_OBJECT_SHOW, 0, &OnWindowShown, (uint)Environment.ProcessId, 0, WINEVENT_OUTOFCONTEXT);
    }

    /// 旧版本就地换文件留下的 .old、.new，没装成的暂存目录，和 updates 里的下载
    /// （只有管理员能写，里面不会有别人放的链接）
    static void DeleteLeftovers()
    {
        try
        {
            foreach (var name in new[] { Exe, Dll })
            foreach (var suffix in new[] { ".old", ".new" })
                File.Delete(Path.Combine(Dir, name + suffix));
            if (Directory.Exists(StageDir)) Directory.Delete(StageDir, recursive: true);
            if (Elevated && Directory.Exists(UpdatesDir)) Directory.Delete(UpdatesDir, recursive: true);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            Log.Write($"自动更新：清理上次的文件失败: {e.Message}");
        }
    }

    /// WinSparkle 验签通过后调到这里：把更新包的全部条目解压到暂存目录，记下待安装。
    /// 此刻不动正在用的文件、不杀进程：遮罩可能正升着，真正安装要等退出时（InstallPending）
    static void Install(string package)
    {
        if (Elevated && !Path.GetFullPath(package).StartsWith(UpdatesDir + @"\", StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException($"更新包不在 {UpdatesDir} 里: {package}");
        // 缺文件的话 install.ps1 会在杀掉旧进程之后才失败，先在这里查一遍
        string[] names = [Exe, "LockCurtain.exe", Dll, "install.ps1", "LockCurtainCtl.exe"];
        using (var zip = ZipFile.OpenRead(package))
            foreach (var name in names)
                if (zip.GetEntry(name) is null) throw new InvalidDataException($"更新包里没有 {name}");
        if (Directory.Exists(StageDir)) Directory.Delete(StageDir, recursive: true);
        ZipFile.ExtractToDirectory(package, StageDir);
        stage = StageDir;
        Log.Write($"自动更新：已解压到 {stage}，退出时安装");
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvStdcall)])]
    static void OnWindowShown(nint hook, uint eventType, nint hwnd, int objectId, int childId, uint thread, uint time)
    {
        if (objectId != OBJID_WINDOW || thread == uiThread || GetAncestor(hwnd, GA_ROOT) != hwnd) return;
        if (smallIcon != null) Native.PostMessageW(hwnd, WM_SETICON, ICON_SMALL, smallIcon.Handle);
        if (bigIcon != null) Native.PostMessageW(hwnd, WM_SETICON, ICON_BIG, bigIcon.Handle);
    }

    // MARK: - WinSparkle 的回调（在它自己的线程上）

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    static int CanShutdown()
    {
        try { return idle() ? 1 : 0; }
        catch { return 0; }
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    static void ShutdownRequest()
    {
        try { exit(); }
        catch (Exception e) { Log.Write($"自动更新：退出失败: {e}"); }
    }

    /// 返回 1 表示已解压好、可以装（WinSparkle 接着请求退出，真正安装见 InstallPending），
    /// -1 时它提示「无法启动安装程序」
    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    static int RunInstaller(char* path)
    {
        try
        {
            Install(new string(path));
            return 1;
        }
        catch (Exception e)
        {
            Log.Write($"自动更新：安装失败: {e}");
            return -1;
        }
    }

    /// UpdateTempDir 以最高权限运行时不存也不读，见文件头第 2 条
    static bool Skipped(string name) => Elevated && name == "UpdateTempDir";

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    static int ConfigRead(byte* name, char* buffer, nuint length, void* userData)
    {
        try
        {
            var key = Marshal.PtrToStringAnsi((nint)name)!;
            using var reg = Registry.CurrentUser.OpenSubKey(RegistryPath);
            // CheckForUpdates 一直是 0：WinSparkle 不自己定时查，也不问用户要不要自动检查（由 Start 里的计时器按设置查）
            var value = key == "CheckForUpdates" ? "0" : Skipped(key) ? null : reg?.GetValue(key) as string;
            if (value == null || (nuint)value.Length >= length) return 0;
            value.CopyTo(new Span<char>(buffer, value.Length));
            buffer[value.Length] = '\0';
            return 1;
        }
        catch { return 0; }
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    static void ConfigWrite(byte* name, char* value, void* userData)
    {
        try
        {
            var key = Marshal.PtrToStringAnsi((nint)name)!;
            if (Skipped(key)) return;
            using var reg = Registry.CurrentUser.CreateSubKey(RegistryPath);
            reg.SetValue(key, new string(value));
        }
        catch (Exception e) { Log.Write($"自动更新：写配置失败: {e.Message}"); }
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    static void ConfigDelete(byte* name, void* userData)
    {
        try
        {
            using var reg = Registry.CurrentUser.OpenSubKey(RegistryPath, writable: true);
            reg?.DeleteValue(Marshal.PtrToStringAnsi((nint)name)!, throwOnMissingValue: false);
        }
        catch (Exception e) { Log.Write($"自动更新：删配置失败: {e.Message}"); }
    }

    const uint EVENT_OBJECT_SHOW = 0x8002, WINEVENT_OUTOFCONTEXT = 0, WM_SETICON = 0x0080, GA_ROOT = 2;
    const int OBJID_WINDOW = 0;
    const nint ICON_SMALL = 0, ICON_BIG = 1;
    [DllImport("user32.dll")]
    static extern nint SetWinEventHook(uint eventMin, uint eventMax, nint module,
        delegate* unmanaged[Stdcall]<nint, uint, nint, int, int, uint, uint, void> callback, uint pid, uint thread, uint flags);
    [DllImport("user32.dll")] static extern nint GetAncestor(nint hwnd, uint flags);

    // MARK: - WinSparkle.dll（include/winsparkle.h）

    struct ConfigMethods
    {
        public delegate* unmanaged[Cdecl]<byte*, char*, nuint, void*, int> Read;
        public delegate* unmanaged[Cdecl]<byte*, char*, void*, void> Write;
        public delegate* unmanaged[Cdecl]<byte*, void*, void> Delete;
        public void* UserData;
    }

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] static extern void win_sparkle_init();
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] static extern void win_sparkle_cleanup();
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Ansi)]
    static extern void win_sparkle_set_appcast_url(string url);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Ansi)]
    static extern int win_sparkle_set_eddsa_public_key(string key);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Ansi)]
    static extern void win_sparkle_set_lang(string lang);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Unicode)]
    static extern void win_sparkle_set_app_details(string company, string app, string version);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    static extern void win_sparkle_set_config_methods(ConfigMethods* methods);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    static extern void win_sparkle_set_can_shutdown_callback(delegate* unmanaged[Cdecl]<int> callback);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    static extern void win_sparkle_set_shutdown_request_callback(delegate* unmanaged[Cdecl]<void> callback);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    static extern void win_sparkle_set_user_run_installer_callback(delegate* unmanaged[Cdecl]<char*, int> callback);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] static extern void win_sparkle_check_update_with_ui();
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] static extern void win_sparkle_check_update_without_ui();
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] static extern long win_sparkle_get_last_check_time();
}
