// Program.cs —— 入口
//
//   LockCurtain.exe                        运行（通知区域图标）
//   LockCurtain.exe --preview              运行并立即显示预览遮罩
//   LockCurtain.exe --no-stealth           遮罩不对屏幕捕获隐藏（希望录屏时对方能看到遮罩）
//   LockCurtain.exe --send away|preview|hide|status
//                                          发给正在运行的实例后退出，输出一行 JSON

using System.Diagnostics;
using System.Security.Principal;

namespace LockCurtain;

static class Program
{
    [STAThread]
    static int Main(string[] args)
    {
        var i = Array.IndexOf(args, "--send");
        if (i >= 0) return ControlClient.Send(i + 1 < args.Length ? args[i + 1] : "status");

        // 装了以最高权限运行的计划任务时，双击启动也走计划任务，免得跑起一个普通权限的实例
        if (args.Length == 0 && !ElevatedTask.IsElevated() && ElevatedTask.TryRun()) return 0;

        // 每个登录会话只跑一个实例；已在运行时再打开一次什么也不做
        using var mutex = new Mutex(true, @"Local\LockCurtain", out var first);
        if (!first) return args.Contains("--preview") ? ControlClient.Send("preview") : 0;

        ApplicationConfiguration.Initialize();
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
    public static bool TryRun()
    {
        try
        {
            // 输出要接住，不然会混进 --send 打印的 JSON 里
            using var p = Process.Start(new ProcessStartInfo("schtasks.exe", $"/run /tn {Name}")
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
