// LockCurtainCtl.exe —— 不带 uiAccess 的命令行工具
//   LockCurtainCtl.exe --launch         用 ShellExecute 启动同目录的 LockCurtain.exe（uiAccess 版只能这样起）；计划任务用它
//   LockCurtainCtl.exe away|hide|preview|status|settings   发给正在运行的实例，输出一行 JSON
// 主程序是 uiAccess，普通进程 CreateProcess 它会被拒，所以 agent 改用这个工具发命令。
using System.Diagnostics;
using System.Text.Json;

namespace LockCurtain;

static class CtlProgram
{
    static int Main(string[] args)
    {
        if (args.Contains("--launch"))
        {
            var exe = Path.Combine(AppContext.BaseDirectory, "LockCurtain.exe");
            try { Process.Start(new ProcessStartInfo(exe) { UseShellExecute = true })?.Dispose(); return 0; }
            catch (Exception e) { Console.Error.WriteLine(e.Message); return 1; }
        }

        var cmd = args.Length > 0 ? args[0] : "status";
        var reply = ControlProtocol.TrySend(cmd, 300);
        if (reply == null)
        {
            if (cmd is "away" or "preview" or "settings")
            {
                RunSchtasks("/run /tn LockCurtain");   // 没运行时通过计划任务拉起（任务会 --launch 主程序）
                reply = ControlProtocol.TrySend(cmd, 10_000);
            }
            if (reply == null)
            {
                var r = cmd is "status" or "hide"
                    ? "{\"ok\":true,\"running\":false}"
                    : "{\"ok\":false,\"running\":false,\"error\":\"LockCurtain is not running\"}";
                Console.WriteLine(r);
                return cmd is "status" or "hide" ? 0 : 1;
            }
        }
        Console.WriteLine(reply);
        try { return JsonDocument.Parse(reply).RootElement.GetProperty("ok").GetBoolean() ? 0 : 1; }
        catch (Exception e) when (e is JsonException or KeyNotFoundException or InvalidOperationException) { return 1; }
    }

    static void RunSchtasks(string a)
    {
        try
        {
            using var p = Process.Start(new ProcessStartInfo("schtasks.exe", a) { UseShellExecute = false, CreateNoWindow = true });
            p?.WaitForExit(3000);
        }
        catch { }
    }
}
