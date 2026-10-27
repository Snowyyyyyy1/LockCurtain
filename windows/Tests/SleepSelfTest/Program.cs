// SleepSelfTest —— 验证 windows/LockCurtain 里和睡眠有关的两个解析：
//   SleepBlockers.Parse   powercfg /requests 的输出 → 谁在阻止睡眠
//   SleepHistory.Sleeps   系统日志的睡眠 / 唤醒事件 → 过去 24 小时睡着的时段
//
// 运行（在 Mac 上也能跑，不需要 Windows）：
//   cd windows/Tests/SleepSelfTest && dotnet run
//
// 对应 Tests/SleepLogSelfTest.swift。全部通过返回 0，有失败返回 1。

using LockCurtain;

var failures = 0;
var total = 0;

void Check(bool cond, string name)
{
    total++;
    Console.WriteLine((cond ? "  OK   " : "  FAIL ") + name);
    if (!cond) failures++;
}

var now = new DateTime(2026, 10, 27, 12, 0, 0, DateTimeKind.Utc);
var from = now - SleepHistory.Window;
DateTime H(double hoursAgo) => now.AddHours(-hoursAgo);
SleepEvent Woke(double sleptHoursAgo, double wokeHoursAgo) => new(H(wokeHoursAgo), SleepEventKind.Woke, H(sleptHoursAgo));
SleepEvent Enter(double hoursAgo) => new(H(hoursAgo), SleepEventKind.StandbyEnter);
SleepEvent Exit(double hoursAgo) => new(H(hoursAgo), SleepEventKind.StandbyExit);
List<Span> Sleeps(params SleepEvent[] events) => SleepHistory.Sleeps(events, from, now);

Console.WriteLine("== powercfg /requests ==");
// 中文 Windows 11 上实际的输出（2026-10-27，Parallels 虚拟机），加一个 vlc 和一个驱动。
// 前三节的节名是英文，EXECUTION 翻成了「执行:」；没有原因的请求下一行直接是下一节
string Requests(params string[] lines) => string.Join("\r\n", lines);
var parsed = SleepBlockers.Parse(Requests(
    "DISPLAY:", @"[PROCESS] \Device\HarddiskVolume4\Program Files\Parallels\Parallels Tools\Services\prl_tools.exe",
    "SYSTEM:", @"[SERVICE] \Device\HarddiskVolume4\Program Files\Parallels\Parallels Tools\Services\prl_tools_service.exe (Parallels Tools Service)",
    @"[DRIVER] Realtek High Definition Audio (HDAUDIO\FUNC_01)", "An audio stream is currently in use.",
    @"[PROCESS] \Device\HarddiskVolume3\Program Files\VideoLAN\VLC\vlc.exe", "Playing video:",
    "AWAYMODE:", "无。",
    "执行:", @"[PROCESS] \Device\HarddiskVolume3\Windows\System32\svchost.exe", "Windows Update",
    "PERFBOOST:", "无。", "ACTIVELOCKSCREEN:", "无。", ""));
Check(parsed.Programs.Count == 2, "两个程序：Parallels Tools 和 vlc（「执行」节的 svchost 不算）");
// 在 Mac 上跑时 Path.GetFileName 不认反斜杠，Name 是整条路径，只比结尾
var tools = parsed.Programs.FirstOrDefault(p => p.Name.EndsWith("prl_tools"));
Check(tools is { Display: true, Reason: "" }, "没有原因的请求：挡屏幕，原因为空（下一行是节名，不是原因）");
var vlc = parsed.Programs.FirstOrDefault(p => p.Name.EndsWith("vlc"));
Check(vlc is { Display: false, Reason: "Playing video:" }, "节名之后的请求归到 SYSTEM；冒号结尾的原因不当节名");
Check(parsed.SystemCount == 2, "一个服务 + 一个驱动 = 2 个系统的");
Check(SleepBlockers.Parse("DISPLAY:\r\n无。\r\nSYSTEM:\r\n无。\r\n").Programs.Count == 0, "全是「无。」-> 没有");

Console.WriteLine("== 睡眠唤醒（Power-Troubleshooter 1）==");
var one = Sleeps(Woke(10, 8));
Check(one.Count == 1 && one[0] == new Span(H(10), H(8)), "睡 2 小时 -> 一段");
Check(SleepHistory.Total(one) == TimeSpan.FromHours(2), "总时长 2 小时");
var edge = Sleeps(Woke(30, 20));
Check(edge.Count == 1 && edge[0].Start == from && edge[0].End == H(20), "窗口开头之前睡下 -> 从窗口开头算");
Check(Sleeps(Woke(30, 26)).Count == 0, "整段在窗口之前 -> 不算");
Check(Sleeps(new SleepEvent(H(5), SleepEventKind.Woke, new DateTime(1601, 1, 1, 0, 0, 0, DateTimeKind.Utc))).Count == 0,
      "睡下时间是空值（1601 年）-> 扔掉");
Check(Sleeps(new SleepEvent(H(5), SleepEventKind.Woke, H(4))).Count == 0, "睡下比醒来还晚 -> 扔掉");
Check(Sleeps(new SleepEvent(H(5), SleepEventKind.Woke)).Count == 0, "没有睡下时间 -> 扔掉");

Console.WriteLine("== 现代待机（Kernel-Power 506 / 507）==");
var standby = Sleeps(Enter(6), Exit(5));
Check(standby.Count == 1 && standby[0] == new Span(H(6), H(5)), "进 / 出待机 -> 一段");
var orphan = Sleeps(Exit(23));
Check(orphan.Count == 1 && orphan[0] == new Span(from, H(23)), "只有退出（进入在窗口之前）-> 从窗口开头算");
Check(Sleeps(Enter(1)).Count == 0, "只有进入、还没退出 -> 不算（我们正醒着在跑）");
var twice = Sleeps(Enter(9), Exit(8), Enter(4), Exit(3.5));
Check(twice.Count == 2 && SleepHistory.Total(twice) == TimeSpan.FromHours(1.5), "两次待机 -> 两段，共 1.5 小时");

Console.WriteLine("== 合并和排序 ==");
var merged = Sleeps(Woke(6, 4), Enter(5), Exit(3));
Check(merged.Count == 1 && merged[0] == new Span(H(6), H(3)), "重叠的两段合成一段");
var touching = Sleeps(Woke(6, 5), Woke(5, 4));
Check(touching.Count == 1 && touching[0] == new Span(H(6), H(4)), "首尾相接的两段合成一段");
var unordered = Sleeps(Woke(2, 1), Woke(12, 11));
Check(unordered.Count == 2 && unordered[0].Start < unordered[1].Start, "事件乱序 -> 结果按时间排");
Check(Sleeps().Count == 0 && SleepHistory.Total(Sleeps()) == TimeSpan.Zero, "没有事件 -> 没有睡眠");

Console.WriteLine(failures == 0
    ? $"全部通过（共 {total} 项）"
    : $"{failures} 项失败（共 {total} 项）");
return failures == 0 ? 0 : 1;
