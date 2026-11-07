// Program.cs —— 入口
//
//   LockCurtainApp.exe                     运行（通知区域图标）；用户一般不直接跑它，而是经启动器 LockCurtain.exe
//   LockCurtainApp.exe --preview           运行并立即显示预览遮罩
//   LockCurtainApp.exe --no-stealth        遮罩不对屏幕捕获隐藏（希望录屏时对方能看到遮罩）
//   LockCurtainApp.exe --send away|preview|hide|status|settings
//                                          发给正在运行的实例后退出，输出一行 JSON
// 已在运行时再打开一次（不带参数）弹出设置窗口，和 Mac 版的 reopen 一样。

using System.Diagnostics;
using System.Security.Principal;
using Microsoft.Win32;

namespace LockCurtain;

static class Program
{
    [STAThread]
    static int Main(string[] args)
    {
        // 必须在任何 COM / WinRT / WinForms 调用之前：蓝牙通知要靠它才能回调进（提权的）本进程，见 ComSecurity.cs
        ComSecurity.Initialize();
        var i = Array.IndexOf(args, "--send");
        if (i >= 0) return ControlClient.Send(i + 1 < args.Length ? args[i + 1] : "status");

        if (args.Length == 0)
        {
            if (ControlClient.TrySend("settings", 300) != null) return 0;
            // 装了以最高权限运行的计划任务时，双击启动也走计划任务，免得跑起一个普通权限的实例
            if (!ElevatedTask.IsElevated() && ElevatedTask.TryRun()) return 0;
        }

        // 每个登录会话只跑一个实例；已在运行时再打开一次什么也不做
        using var mutex = new Mutex(true, @"Local\LockCurtain", out var first);
        if (!first) return args.Contains("--preview") ? ControlClient.Send("preview") : 0;

        // 每显示器 DPI（PerMonitorV2）由 app.manifest 声明、App.config 打开 WinForms 的支持（.NET Framework 没有 SetHighDpiMode）。
        // 深浅色：.NET Framework 没有 Application.SetColorMode，标准控件由 DarkMode.Apply 逐个换成深色（见 DarkMode.cs）
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        SynchronizationContext.SetSynchronizationContext(new WindowsFormsSynchronizationContext());
        Application.ThreadException += (_, e) => Log.Write($"未处理异常: {e.Exception}");
        AppDomain.CurrentDomain.UnhandledException += (_, e) => Log.Write($"未处理异常: {e.ExceptionObject}");
        Application.Run(new TrayApp(stealth: !args.Contains("--no-stealth"), preview: args.Contains("--preview")));
        return 0;
    }
}

/// install.ps1 注册的计划任务：当前用户登录时以最高权限启动 LockCurtain。
/// 以管理员身份运行时，钩子才看得到发给管理员窗口的按键（见 InputFilter.cs）
internal static class ElevatedTask
{
    const string Name = "LockCurtain";

    public static bool IsElevated() =>
        new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator);

    /// 通过计划任务启动；任务不存在（没装）时返回 false。任务已在运行时计划程序什么也不做
    public static bool TryRun() => Schtasks($"/run /tn {Name}");

    public static bool IsInstalled() => Schtasks($"/query /tn {Name}");

    /// 设置 › 权限「开启」：以管理员身份跑旁边的 install.ps1（弹 UAC），它装好计划任务、杀掉本进程、再从计划任务起来。
    /// 返回没开成的原因（给人看，不提脚本名）；null = 已经交给 install.ps1
    public static string? Enable()
    {
        var script = Path.Combine(AppContext.BaseDirectory, "install.ps1");
        if (!File.Exists(script))
        {
            Log.Write($"开启以管理员身份运行: 没有 {script}");
            // COPY-TODO: §16.8 只说「开不了就写原因」，没给字
            return "没开成：这份 LockCurtain 里少了安装要用的文件，重新下载安装包装一次。";
        }
        try
        {
            var sid = WindowsIdentity.GetCurrent().User?.Value;
            Process.Start(new ProcessStartInfo("powershell.exe",
                $"-NoProfile -ExecutionPolicy Bypass -File \"{script}\"" + (sid != null ? $" -ForUser {sid}" : ""))
            {
                UseShellExecute = true,
                Verb = "runas",
            })?.Dispose();
            Log.Write("开启以管理员身份运行: 已起 install.ps1");
            return null;
        }
        catch (System.ComponentModel.Win32Exception e) when (e.NativeErrorCode == 1223)     // ERROR_CANCELLED：UAC 点了否
        {
            Log.Write("开启以管理员身份运行: UAC 没同意");
            // COPY-TODO: 「没点同意」也算原因（§16.8），句子是我写的
            return "没开成：管理员那一步没点同意。";
        }
        catch (System.ComponentModel.Win32Exception e)
        {
            Log.Write($"开启以管理员身份运行失败: {e.Message}");
            return $"没开成：{e.Message}";
        }
    }

    static bool Schtasks(string arguments)
    {
        try
        {
            // 输出要接住，不然会混进 --send 打印的 JSON 里
            using var p = Process.Start(new ProcessStartInfo("schtasks.exe", arguments)
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            })!;
            p.StandardOutput.ReadToEnd();
            p.StandardError.ReadToEnd();
            return p.WaitForExit(5000) && p.ExitCode == 0;
        }
        catch (System.ComponentModel.Win32Exception) { return false; }
    }
}

/// 没装计划任务时的「登录时打开」：当前用户的 Run 键，不用管理员权限。
/// install.ps1 安装时会删掉它，免得登录时起两个实例
internal static class LoginItem
{
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run", Name = "LockCurtain";
    // 任务管理器「启动应用」里禁用时 Run 值还在，这里记一个首字节为奇数的值（03 禁用，02 启用）
    const string ApprovedKey = @"Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run";

    public static bool IsEnabled()
    {
        using var key = Registry.CurrentUser.OpenSubKey(RunKey);
        using var approved = Registry.CurrentUser.OpenSubKey(ApprovedKey);
        return key?.GetValue(Name) is string
            && !(approved?.GetValue(Name) is byte[] { Length: > 0 } b && (b[0] & 1) != 0);
    }

    public static void Set(bool on)
    {
        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(RunKey);
            if (on) key.SetValue(Name, $"\"{Environment.ProcessPath}\"");
            else key.DeleteValue(Name, throwOnMissingValue: false);
            // 在这里打开就是要它启动：顺带撤掉任务管理器里的禁用
            using (var approved = Registry.CurrentUser.OpenSubKey(ApprovedKey, writable: true))
                approved?.DeleteValue(Name, throwOnMissingValue: false);
            Log.Write($"登录时打开 -> {on}");
        }
        catch (Exception e) when (e is UnauthorizedAccessException or IOException or System.Security.SecurityException)
        {
            Log.Write($"登录时打开 -> {on} 失败: {e.Message}");
        }
    }
}
