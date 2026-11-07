// Updater.cs —— 自动更新：检查、提示、下载、验签交给 WinSparkle，安装交给 install.ps1
//
// 更新包是 Release 上的 LockCurtain-<版本>-win-<架构>.zip（windows/build.sh 打的包，两种架构内容一样：LockCurtainApp.exe（uiAccess 主程序）、
// LockCurtain.exe（启动器）、依赖的 dll、x64\ 和 arm64\ 里的 WinSparkle.dll、install.ps1，
// 加上给旧版更新器查名字的占位文件 WinSparkle.dll、LockCurtainCtl.exe），
// appcast-windows.xml 里每个架构一个 enclosure，带 Ed25519 签名（release.sh 签）。
// 测试版（版本号带 beta）编译时换成测试通道 beta-channel 上的 appcast-beta-windows.xml（windows/build.sh 决定，release-beta.sh 发），
// WinSparkle 比版本时 1.0.4-beta.2 < 1.0.4-beta.3 < 1.0.4（windows/Tests/VersionOrderSelfTest）。
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
    /// 主程序是 AnyCPU：ARM64 上是 x64 仿真（用 x64 那份）；以后编原生 ARM64 版时用 arm64 那份。
    /// 发布包里两种 WinSparkle.dll 都有（x64\、arm64\），按本进程的架构挑；根目录那个 WinSparkle.dll 只是给旧版更新器查名字的占位
    static readonly string? ArchDir = RuntimeInformation.ProcessArchitecture switch
    {
        Architecture.X64 => "x64",
        Architecture.Arm64 => "arm64",
        _ => null,
    };
    static string? DllPath => ArchDir is { } a ? Path.Combine(Dir, a, Dll) : null;
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
        if (DllPath is not { } dllPath || !File.Exists(dllPath))
        {
            Log.Write($"自动更新：没有 {RuntimeInformation.ProcessArchitecture} 的 {Dll}（{Dir}\\{ArchDir}），不检查更新");
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

        // 按完整路径加载，它依赖的 DLL 只从它自己的目录和 System32 找，不走系统的 DLL 搜索顺序
        if (!WinSparkle.Load(dllPath))
        {
            Log.Write($"自动更新：加载 {dllPath} 失败（{Marshal.GetLastWin32Error()}），不检查更新");
            return;
        }
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
        var config = new ConfigMethods
        {
            Read = Marshal.GetFunctionPointerForDelegate(Keep.ConfigRead),
            Write = Marshal.GetFunctionPointerForDelegate(Keep.ConfigWrite),
            Delete = Marshal.GetFunctionPointerForDelegate(Keep.ConfigDelete),
        };
        win_sparkle_set_config_methods(&config);
        win_sparkle_set_can_shutdown_callback(Keep.CanShutdown);
        win_sparkle_set_shutdown_request_callback(Keep.ShutdownRequest);
        win_sparkle_set_user_run_installer_callback(Keep.RunInstaller);
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
        SetWinEventHook(EVENT_OBJECT_SHOW, EVENT_OBJECT_SHOW, 0, Keep.OnWindowShown, (uint)Environment.ProcessId, 0, WINEVENT_OUTOFCONTEXT);
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
        string[] names = [Exe, "LockCurtain.exe", "install.ps1", "x64/" + Dll, "arm64/" + Dll];
        using (var zip = ZipFile.OpenRead(package))
            foreach (var name in names)
                if (zip.GetEntry(name) is null) throw new InvalidDataException($"更新包里没有 {name}");
        if (Directory.Exists(StageDir)) Directory.Delete(StageDir, recursive: true);
        ZipFile.ExtractToDirectory(package, StageDir);
        stage = StageDir;
        Log.Write($"自动更新：已解压到 {stage}，退出时安装");
    }

    static void OnWindowShown(nint hook, uint eventType, nint hwnd, int objectId, int childId, uint thread, uint time)
    {
        if (objectId != OBJID_WINDOW || thread == uiThread || GetAncestor(hwnd, GA_ROOT) != hwnd) return;
        if (smallIcon != null) Native.PostMessageW(hwnd, WM_SETICON, ICON_SMALL, smallIcon.Handle);
        if (bigIcon != null) Native.PostMessageW(hwnd, WM_SETICON, ICON_BIG, bigIcon.Handle);
    }

    // MARK: - WinSparkle 的回调（在它自己的线程上）

    static int CanShutdown()
    {
        try { return idle() ? 1 : 0; }
        catch { return 0; }
    }

    static void ShutdownRequest()
    {
        try { exit(); }
        catch (Exception e) { Log.Write($"自动更新：退出失败: {e}"); }
    }

    /// 返回 1 表示已解压好、可以装（WinSparkle 接着请求退出，真正安装见 InstallPending），
    /// -1 时它提示「无法启动安装程序」
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
    delegate void WinEventProc(nint hook, uint eventType, nint hwnd, int objectId, int childId, uint thread, uint time);
    [DllImport("user32.dll")]
    static extern nint SetWinEventHook(uint eventMin, uint eventMax, nint module, WinEventProc callback, uint pid, uint thread, uint flags);
    [DllImport("user32.dll")] static extern nint GetAncestor(nint hwnd, uint flags);

    /// 交给原生代码的回调：委托必须一直有人引用，不然被回收后原生代码再调就崩
    static class Keep
    {
        public static readonly WinEventProc OnWindowShown = Updater.OnWindowShown;
        public static readonly ReadFn ConfigRead = Updater.ConfigRead;
        public static readonly WriteFn ConfigWrite = Updater.ConfigWrite;
        public static readonly DeleteFn ConfigDelete = Updater.ConfigDelete;
        public static readonly IntCallback CanShutdown = Updater.CanShutdown;
        public static readonly VoidCallback ShutdownRequest = Updater.ShutdownRequest;
        public static readonly InstallerCallback RunInstaller = Updater.RunInstaller;
    }

    // MARK: - WinSparkle.dll（include/winsparkle.h）
    // 不用 DllImport：按完整路径 LoadLibraryEx，再 GetProcAddress 取函数（.NET Framework 没有 NativeLibrary）

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int ReadFn(byte* name, char* buffer, nuint length, void* userData);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate void WriteFn(byte* name, char* value, void* userData);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate void DeleteFn(byte* name, void* userData);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int IntCallback();
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate void VoidCallback();
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int InstallerCallback(char* path);

    struct ConfigMethods
    {
        public nint Read, Write, Delete;
        public void* UserData;
    }

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate void VoidFn();
    [UnmanagedFunctionPointer(CallingConvention.Cdecl, CharSet = CharSet.Ansi)] delegate void AnsiFn(string value);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl, CharSet = CharSet.Ansi)] delegate int AnsiIntFn(string value);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl, CharSet = CharSet.Unicode)] delegate void DetailsFn(string company, string app, string version);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate void ConfigFn(ConfigMethods* methods);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate void SetCallbackFn(nint callback);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate long LongFn();

    static class WinSparkle
    {
        public static VoidFn Init = null!, Cleanup = null!, CheckWithUi = null!, CheckWithoutUi = null!;
        public static AnsiFn SetAppcastUrl = null!, SetLang = null!;
        public static AnsiIntFn SetEdDSAPublicKey = null!;
        public static DetailsFn SetAppDetails = null!;
        public static ConfigFn SetConfigMethods = null!;
        public static SetCallbackFn SetCanShutdown = null!, SetShutdownRequest = null!, SetUserRunInstaller = null!;
        public static LongFn GetLastCheckTime = null!;

        public static bool Load(string path)
        {
            const uint LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR = 0x100, LOAD_LIBRARY_SEARCH_SYSTEM32 = 0x800;
            var module = LoadLibraryExW(path, 0, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32);
            if (module == 0) return false;
            try { Bind(module); return true; }
            catch (EntryPointNotFoundException e) { Log.Write($"自动更新：{e.Message}"); return false; }
        }

        static void Bind(nint module)
        {
            T Get<T>(string name) where T : Delegate => Marshal.GetDelegateForFunctionPointer<T>(
                GetProcAddress(module, name) is var p and not 0 ? p : throw new EntryPointNotFoundException($"{Dll}: {name}"));
            Init = Get<VoidFn>("win_sparkle_init");
            Cleanup = Get<VoidFn>("win_sparkle_cleanup");
            SetAppcastUrl = Get<AnsiFn>("win_sparkle_set_appcast_url");
            SetEdDSAPublicKey = Get<AnsiIntFn>("win_sparkle_set_eddsa_public_key");
            SetLang = Get<AnsiFn>("win_sparkle_set_lang");
            SetAppDetails = Get<DetailsFn>("win_sparkle_set_app_details");
            SetConfigMethods = Get<ConfigFn>("win_sparkle_set_config_methods");
            SetCanShutdown = Get<SetCallbackFn>("win_sparkle_set_can_shutdown_callback");
            SetShutdownRequest = Get<SetCallbackFn>("win_sparkle_set_shutdown_request_callback");
            SetUserRunInstaller = Get<SetCallbackFn>("win_sparkle_set_user_run_installer_callback");
            CheckWithUi = Get<VoidFn>("win_sparkle_check_update_with_ui");
            CheckWithoutUi = Get<VoidFn>("win_sparkle_check_update_without_ui");
            GetLastCheckTime = Get<LongFn>("win_sparkle_get_last_check_time");
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern nint LoadLibraryExW(string path, nint file, uint flags);
        [DllImport("kernel32.dll", CharSet = CharSet.Ansi, ExactSpelling = true)]
        static extern nint GetProcAddress(nint module, string name);
    }

    static void win_sparkle_init() => WinSparkle.Init();
    static void win_sparkle_cleanup() => WinSparkle.Cleanup();
    static void win_sparkle_set_appcast_url(string url) => WinSparkle.SetAppcastUrl(url);
    static int win_sparkle_set_eddsa_public_key(string key) => WinSparkle.SetEdDSAPublicKey(key);
    static void win_sparkle_set_lang(string lang) => WinSparkle.SetLang(lang);
    static void win_sparkle_set_app_details(string company, string app, string version) => WinSparkle.SetAppDetails(company, app, version);
    static void win_sparkle_set_config_methods(ConfigMethods* methods) => WinSparkle.SetConfigMethods(methods);
    static void win_sparkle_set_can_shutdown_callback(IntCallback callback) => WinSparkle.SetCanShutdown(Marshal.GetFunctionPointerForDelegate(callback));
    static void win_sparkle_set_shutdown_request_callback(VoidCallback callback) => WinSparkle.SetShutdownRequest(Marshal.GetFunctionPointerForDelegate(callback));
    static void win_sparkle_set_user_run_installer_callback(InstallerCallback callback) => WinSparkle.SetUserRunInstaller(Marshal.GetFunctionPointerForDelegate(callback));
    static void win_sparkle_check_update_with_ui() => WinSparkle.CheckWithUi();
    static void win_sparkle_check_update_without_ui() => WinSparkle.CheckWithoutUi();
    static long win_sparkle_get_last_check_time() => WinSparkle.GetLastCheckTime();
}
