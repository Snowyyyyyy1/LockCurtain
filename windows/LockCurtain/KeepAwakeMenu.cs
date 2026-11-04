// KeepAwakeMenu.cs —— 「保持唤醒」的选择菜单：托盘面板、设置 › 保持唤醒、右键菜单「保持唤醒 ▸」共用同一份（Colo A3）
//
// 一直 / 1 小时 / 2 小时 / 5 小时 / 到指定时间… / ─ / 某个程序开着时 ▸
// 「到指定时间…」要一个选时刻的框：面板和设置页各自在页里展开（RuleEditor.TimePicker），右键菜单里点了打开设置 › 保持唤醒 再展开。

using System.Diagnostics;

namespace LockCurtain;

internal static class KeepAwakeMenu
{
    public static List<TrayCommand> Choices(KeepAwake keepAwake, Action pickTime)
    {
        TrayCommand For(string label, TimeSpan span) =>
            new(label, () => keepAwake.Start(new KeepAwakeMode.Until(DateTime.UtcNow + span)));
        return
        [
            new("一直", () => keepAwake.Start(new KeepAwakeMode.Forever())),
            For("1 小时", TimeSpan.FromHours(1)),
            For("2 小时", TimeSpan.FromHours(2)),
            For("5 小时", TimeSpan.FromHours(5)),
            new("到指定时间…", pickTime),
            new("某个程序开着时", () => { }, SeparatorBefore: true, Submenu: RunningApps(keepAwake)),
        ];
    }

    /// 任务栏上有窗口的程序（不含自己），按显示名排；它退出就结束保持唤醒
    public static List<TrayCommand> RunningApps(KeepAwake keepAwake)
    {
        var apps = new SortedDictionary<string, TrayCommand>(StringComparer.CurrentCultureIgnoreCase);
        foreach (var pid in ProcessInfo.WithWindows())
        {
            if (pid == Environment.ProcessId || ProcessInfo.PathOf(pid) is not { } path) continue;
            var title = ProcessInfo.Title(pid, path);
            if (apps.ContainsKey(title)) continue;
            Process p;
            try { p = Process.GetProcessById(pid); }
            catch (ArgumentException) { continue; }     // 刚退出
            using (p)
                if (KeepAwake.Bind(p, title) is { } bound) apps[title] = new TrayCommand(title, () => keepAwake.Start(bound));
        }
        return apps.Count > 0 ? apps.Values.ToList() : new() { new("现在没有", () => { }, Enabled: false) };
    }

    /// 选时刻的框默认停在至少一小时后的整点（当天零点起的分钟）
    public static int DefaultPickMinute()
    {
        var at = DateTime.Now.AddHours(1);
        return (at.Minute == 0 && at.Second == 0 ? at.Hour : at.Hour + 1) % 24 * 60;
    }

    /// 选的时刻下一次到来的时候；已经过了就是明天
    public static void StartAt(KeepAwake keepAwake, int minute)
    {
        var end = DateTime.Today.AddMinutes(minute);
        if (end <= DateTime.Now) end = end.AddDays(1);
        keepAwake.Start(new KeepAwakeMode.Until(end.ToUniversalTime(), Clock: true));
    }
}
