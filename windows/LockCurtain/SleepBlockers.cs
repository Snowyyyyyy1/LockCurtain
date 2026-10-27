// SleepBlockers.cs —— 现在谁在阻止睡眠
//
// Mac 版读 IOPMCopyAssertionsByProcess；Windows 对应的是电源请求，只有 powercfg /requests 能列出来，
// 而且要管理员权限：普通权限运行时（没用 install.ps1 安装）读不到，返回 null。
// 输出按类型分节。下面三节的名字不随系统语言变，算阻止睡眠：
//   DISPLAY:           不让屏幕熄灭
//   SYSTEM:            不让系统睡眠
//   AWAYMODE:          离开模式（媒体中心那种，屏幕黑着、系统醒着）
// 其余几节（EXECUTION / PERFBOOST / ACTIVELOCKSCREEN）不算，而且有的会翻译：中文系统上 EXECUTION 是「执行:」。
// 六个英文节名直接认；别的冒号结尾、不带空格的行，不紧跟在请求后面（那是原因）、或者已经过了 AWAYMODE 节，也当节名。
// 请求不一定有原因那一行，下一行可能直接是下一节。
// 每个请求一行「[PROCESS] 路径」「[SERVICE] 名字」「[DRIVER] 名字」，下一行是程序自己写的原因。
// 服务和驱动算系统的，只计个数（Mac 版也不逐个列系统服务）；LockCurtain 自己不算。

using System.Diagnostics;
using System.Text;

namespace LockCurtain;

/// 一个在阻止睡眠的程序。Name 是规范化的进程名（见 RuleFacts.Normalize），Path 是 powercfg 给的设备路径
/// （ProcessInfo.DosPath 换成盘符路径），Display 表示挡的是屏幕。同一个程序可能有好几条
internal sealed record SleepBlocker(string Name, string Path, bool Display, string Reason);

/// 一次快照：逐个列出的程序，加上在阻止睡眠的服务和驱动有几个
internal sealed record SleepBlockerSnapshot(List<SleepBlocker> Programs, int SystemCount);

internal static class SleepBlockers
{
    static readonly string[] BlockingSections = { "DISPLAY:", "SYSTEM:", "AWAYMODE:" };
    static readonly string[] KnownSections = { "DISPLAY:", "SYSTEM:", "AWAYMODE:", "EXECUTION:", "PERFBOOST:", "ACTIVELOCKSCREEN:" };
    static readonly string Self = RuleFacts.Normalize(Path.GetFileName(Environment.ProcessPath ?? "LockCurtain"));

    /// 读不到（没有管理员权限、powercfg 出错）时返回 null
    public static SleepBlockerSnapshot? Snapshot()
    {
        string output;
        try
        {
            using var p = Process.Start(new ProcessStartInfo("powercfg.exe", "/requests")
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                // 输出走控制台的 OEM 代码页（中文系统是 936），路径和原因里的中文要按它解
                StandardOutputEncoding = OemEncoding(),
            })!;
            // 两路同时读：先读完一路再读另一路的话，另一路写满管道两边就互相等着，下面的 5 秒超时也管不到
            var stdout = p.StandardOutput.ReadToEndAsync();
            _ = p.StandardError.ReadToEndAsync();
            if (!p.WaitForExit(5000))
            {
                p.Kill();
                return null;
            }
            if (p.ExitCode != 0) return null;
            output = stdout.Result;
        }
        catch (System.ComponentModel.Win32Exception) { return null; }
        return Parse(output);
    }

    public static SleepBlockerSnapshot Parse(string output)
    {
        var result = new List<SleepBlocker>();
        var system = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        string? section = null;
        var lines = output.Split('\n').Select(l => l.TrimEnd('\r')).ToArray();
        bool IsSection(int i)
        {
            var line = lines[i].Trim();
            if (KnownSections.Contains(line)) return true;
            var afterEntry = i > 0 && lines[i - 1].TrimStart().StartsWith('[');
            return line.Length > 1 && line.EndsWith(':') && !line.StartsWith('[') && !line.Any(char.IsWhiteSpace)
                   && (!afterEntry || section == "AWAYMODE:");
        }
        for (var i = 0; i < lines.Length; i++)
        {
            var line = lines[i].Trim();
            if (IsSection(i))
            {
                section = line;
                continue;
            }
            if (section == null || !BlockingSections.Contains(section)) continue;
            if (line.StartsWith("[SERVICE]") || line.StartsWith("[DRIVER]"))
            {
                system.Add(line);
                continue;
            }
            if (!line.StartsWith("[PROCESS]")) continue;
            var path = line["[PROCESS]".Length..].Trim();
            var name = RuleFacts.Normalize(Path.GetFileName(path));
            if (name.Length == 0 || name == Self) continue;
            var reason = i + 1 < lines.Length && !lines[i + 1].TrimStart().StartsWith('[') && !IsSection(i + 1) ? lines[i + 1].Trim() : "";
            result.Add(new SleepBlocker(name, path, section == "DISPLAY:", reason));
        }
        return new SleepBlockerSnapshot(result, system.Count);
    }

    static Encoding OemEncoding()
    {
        Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
        try { return Encoding.GetEncoding((int)Native.GetOEMCP()); }
        catch (Exception e) when (e is ArgumentException or NotSupportedException) { return Encoding.UTF8; }
    }
}
