// LockCurtain.exe —— 不带 uiAccess 的入口启动器 / 命令行工具（计划任务和双击都从这里起主程序）
//   LockCurtain.exe                     无参数：用 ShellExecute 起同目录的 uiAccess 主程序 LockCurtainApp.exe
//   LockCurtain.exe --launch            同上；计划任务用这个
//   LockCurtain.exe --relaunch-after <pid>   旧版（≤1.0.1）就地换文件更新后会这样叫：先等 pid 退出，
//                                       再看旁边有没有 LockCurtainApp.exe——有就正常起主程序；
//                                       没有（说明是旧更新器只换了半截）就跑更新包里的 install.ps1 自愈
//   LockCurtain.exe away|hide|preview|status|settings   发给正在运行的实例，输出一行 JSON
// 主程序是 uiAccess，普通进程 CreateProcess 它会被拒（0x800702E4），只能 ShellExecute，所以要有这个启动器。
using System.Diagnostics;
using System.IO.Compression;
using System.Text.Json;

namespace LockCurtain;

static class CtlProgram
{
    const string AppExe = "LockCurtainApp.exe";
    static string Dir => AppContext.BaseDirectory.TrimEnd('\\');

    static int Main(string[] args)
    {
        if (args.Length == 0 || args.Contains("--launch")) return Launch();

        var rel = Array.IndexOf(args, "--relaunch-after");
        if (rel >= 0)
        {
            if (rel + 1 < args.Length && int.TryParse(args[rel + 1], out var pid))
                try { using var p = Process.GetProcessById(pid); p.WaitForExit(15_000); } catch { }
            // 旧版（1.0.0/1.0.1）的就地换文件更新只换了 LockCurtain.exe（现在是本启动器）和 WinSparkle.dll，
            // 没有 LockCurtainApp.exe 和 install.ps1。没有主程序 = 这种半截状态，跑 install.ps1 自愈；否则正常起。
            return File.Exists(Path.Combine(Dir, AppExe)) ? Launch() : SelfHeal();
        }

        var cmd = args[0];
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

    static int Launch()
    {
        try { Process.Start(new ProcessStartInfo(Path.Combine(Dir, AppExe)) { UseShellExecute = true })?.Dispose(); return 0; }
        catch (Exception e) { Console.Error.WriteLine(e.Message); return 1; }
    }

    /// 旧版（1.0.0/1.0.1，非 uiAccess）点应用内更新后的自愈。
    /// 旧更新器已经把 LockCurtain.exe 换成了本启动器、把验签过的更新包留在了 <安装目录>\updates，
    /// 但它不认得 LockCurtainApp.exe / install.ps1，所以停在了半截。这里找出更新包、解压、跑里面的 install.ps1：
    /// 由 install.ps1 复制全部文件、给 LockCurtainApp.exe 签名、重注册计划任务并启动，补全成完整的 1.0.3+。
    /// 1.0.1 以最高权限运行，本进程继承管理员令牌 → install.ps1 走 admin 分支、不弹 UAC；万一没提权它自己会弹一次。
    static int SelfHeal()
    {
        try
        {
            // 1.0.1 以最高权限运行时 TMP 指到 <安装目录>\updates（只有管理员能写），验签过的更新包就在这里
            var updates = Path.Combine(Dir, "updates");
            var zip = (Directory.Exists(updates) ? Directory.GetFiles(updates, "*.zip") : Array.Empty<string>())
                .OrderByDescending(File.GetLastWriteTimeUtc)
                .FirstOrDefault();
            if (zip == null) { Console.Error.WriteLine($"自愈失败：{updates} 里找不到更新包"); return 1; }

            var stage = Path.Combine(updates, "selfheal");
            if (Directory.Exists(stage)) Directory.Delete(stage, recursive: true);
            ZipFile.ExtractToDirectory(zip, stage);
            var script = Path.Combine(stage, "install.ps1");
            if (!File.Exists(script)) { Console.Error.WriteLine($"自愈失败：更新包里没有 install.ps1（{zip}）"); return 1; }

            // 起独立的 powershell 跑 install.ps1，然后本进程退出。install.ps1 会 Kill 掉名为 LockCurtain 的本进程，
            // 所以必须是独立进程、不能等它（和 Updater.InstallPending 一样的理由）。
            Process.Start(new ProcessStartInfo("powershell.exe",
                $"-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"{script}\"")
            { UseShellExecute = false, CreateNoWindow = true })?.Dispose();
            return 0;
        }
        catch (Exception e)
        {
            Console.Error.WriteLine("自愈失败：" + e.Message);
            return 1;
        }
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
