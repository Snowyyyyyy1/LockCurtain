// SleepHistory.cs —— 过去 24 小时什么时候睡着了（对应 Mac 版 SleepLedger 里「睡眠」那部分）
//
// Mac 版从 pmset -g log 还原出睡眠、在用、被谁阻止。Windows 没有按程序记录的电源请求历史，
// 这里只做睡眠和唤醒（2026-10-27 和用户定的）。事件由 SleepEventLog 从系统日志读出来：
//   Power-Troubleshooter 1   从睡眠或休眠醒来，事件里带这次的 SleepTime 和 WakeTime
//   Kernel-Power 506 / 507   进入 / 退出现代待机（Modern Standby 的机器不走 S3，没有上面那条）
// 这个文件只做纯计算，不碰系统，Tests/SleepHistorySelfTest 直接链接它。时间一律 UTC，时段是 [开始, 结束)。

namespace LockCurtain;

/// 日志里的一条。Sleep 只有 Woke 才有：这次是什么时候睡下的
internal sealed record SleepEvent(DateTime Time, SleepEventKind Kind, DateTime? Sleep = null);

internal enum SleepEventKind { Woke, StandbyEnter, StandbyExit }

internal readonly record struct Span(DateTime Start, DateTime End)
{
    public TimeSpan Length => End - Start;
}

internal static class SleepHistory
{
    public static readonly TimeSpan Window = TimeSpan.FromHours(24);

    /// 事件 → 落在 [from, now) 里睡着的时段，合并重叠的，按时间排
    public static List<Span> Sleeps(IEnumerable<SleepEvent> events, DateTime from, DateTime now)
    {
        var spans = new List<Span>();
        DateTime? standby = null;
        foreach (var e in events.OrderBy(e => e.Time))
        {
            switch (e.Kind)
            {
                // 睡下的时间读不到时是 1601 年这类空值，比醒来还晚的也不对，都扔掉
                case SleepEventKind.Woke when e.Sleep is { } s && s.Year >= 2000 && s < e.Time:
                    spans.Add(new Span(s, e.Time));
                    break;
                case SleepEventKind.StandbyEnter:
                    standby = e.Time;
                    break;
                // 进待机那条在窗口之前（或者日志被清过）就从窗口开头算
                case SleepEventKind.StandbyExit:
                    spans.Add(new Span(standby ?? from, e.Time));
                    standby = null;
                    break;
            }
        }
        return Merge(spans.Select(s => new Span(Max(s.Start, from), Min(s.End, now))).Where(s => s.End > s.Start));
    }

    public static TimeSpan Total(IEnumerable<Span> spans) => TimeSpan.FromTicks(spans.Sum(s => s.Length.Ticks));

    static List<Span> Merge(IEnumerable<Span> spans)
    {
        var result = new List<Span>();
        foreach (var s in spans.OrderBy(s => s.Start))
        {
            if (result.Count > 0 && s.Start <= result[^1].End)
                result[^1] = new Span(result[^1].Start, Max(result[^1].End, s.End));
            else
                result.Add(s);
        }
        return result;
    }

    static DateTime Max(DateTime a, DateTime b) => a > b ? a : b;
    static DateTime Min(DateTime a, DateTime b) => a < b ? a : b;
}
