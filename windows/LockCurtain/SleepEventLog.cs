// SleepEventLog.cs —— 从系统事件日志读睡眠和唤醒（算法在 SleepHistory.cs）
//
// 读 System 日志不用管理员权限。只取最近 26 小时：窗口是 24 小时，多两小时接住窗口开头之前进的待机。
// 托盘面板每次打开时读，5 分钟内再开用上次的结果；读失败不缓存，下次打开重试（和 Mac 版一样）。

using System.Diagnostics.Eventing.Reader;
using System.Xml.Linq;

namespace LockCurtain;

internal static class SleepEventLog
{
    const string Query =
        "*[System[((Provider[@Name='Microsoft-Windows-Power-Troubleshooter'] and EventID=1)"
        + " or (Provider[@Name='Microsoft-Windows-Kernel-Power'] and (EventID=506 or EventID=507)))"
        + " and TimeCreated[timediff(@SystemTime) <= 93600000]]]";
    static readonly TimeSpan CacheFor = TimeSpan.FromMinutes(5);

    static (DateTime At, List<Span> Sleeps)? cached;

    /// 过去 24 小时睡着的时段；读不到返回 null 和原因
    public static (List<Span>? Sleeps, string? Error) Load()
    {
        var now = DateTime.UtcNow;
        if (cached is { } c && now - c.At < CacheFor) return (c.Sleeps, null);
        try
        {
            var events = new List<SleepEvent>();
            using var reader = new EventLogReader(new EventLogQuery("System", PathType.LogName, Query));
            for (var record = reader.ReadEvent(); record != null; record = reader.ReadEvent())
                using (record)
                    if (Convert(record) is { } e) events.Add(e);
            var sleeps = SleepHistory.Sleeps(events, now - SleepHistory.Window, now);
            cached = (now, sleeps);
            return (sleeps, null);
        }
        catch (Exception e) when (e is EventLogException or UnauthorizedAccessException)
        {
            Log.Write($"读系统日志出错: {e.Message}");
            return (null, e.Message);
        }
    }

    static SleepEvent? Convert(EventRecord r)
    {
        if (r.TimeCreated is not { } local) return null;
        var time = local.ToUniversalTime();
        return r.Id switch
        {
            1 => new SleepEvent(time, SleepEventKind.Woke, Data(r, "SleepTime")),
            506 => new SleepEvent(time, SleepEventKind.StandbyEnter),
            507 => new SleepEvent(time, SleepEventKind.StandbyExit),
            _ => null,
        };
    }

    /// EventData 里按名字取一个时间（ISO 8601，UTC）
    static DateTime? Data(EventRecord r, string name)
    {
        XNamespace ns = "http://schemas.microsoft.com/win/2004/08/events/event";
        var value = XDocument.Parse(r.ToXml()).Descendants(ns + "Data").FirstOrDefault(d => (string?)d.Attribute("Name") == name)?.Value;
        return DateTime.TryParse(value, null, System.Globalization.DateTimeStyles.AdjustToUniversal | System.Globalization.DateTimeStyles.AssumeUniversal,
                                 out var t) ? t : null;
    }
}
