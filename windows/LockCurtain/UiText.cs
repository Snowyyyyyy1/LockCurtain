// UiText.cs —— 界面上按时间拼出来的几种字（纯函数，PhoneSelfTest 里直接测）
//
//   * 「上次连上：3 小时前」的时间：只用五种说法（copy v14.3 §16.1）：刚刚 / N 分钟前 / N 小时前 / 昨天 / M 月 D 日
//   * 「iPhone · 11 月 4 日配上」
//   * 时长：不到 1 分 / N 分 / N 小时 / N 小时 M 分（和 Mac 版一样）

namespace LockCurtain;

internal static class UiText
{
    /// then、now 都是 UTC；按本地日期判断今天 / 昨天。local 只给测试指定时区
    public static string Ago(DateTime thenUtc, DateTime nowUtc, TimeZoneInfo? local = null)
    {
        local ??= TimeZoneInfo.Local;
        var span = nowUtc - thenUtc;
        if (span < TimeSpan.FromMinutes(1)) return "刚刚";     // 也包括钟被往回拨过、then 在将来
        if (span < TimeSpan.FromHours(1)) return $"{(int)span.TotalMinutes} 分钟前";
        var then = TimeZoneInfo.ConvertTimeFromUtc(DateTime.SpecifyKind(thenUtc, DateTimeKind.Utc), local);
        var now = TimeZoneInfo.ConvertTimeFromUtc(DateTime.SpecifyKind(nowUtc, DateTimeKind.Utc), local);
        if (then.Date == now.Date) return $"{(int)span.TotalHours} 小时前";
        if (then.Date == now.Date.AddDays(-1)) return "昨天";
        return MonthDay(then);
    }

    public static string MonthDay(DateTime local) => $"{local.Month} 月 {local.Day} 日";

    /// 已配对那一行的标题：「iPhone · 11 月 4 日配上」；老记录没有配对日期就只有名字
    public static string PhoneTitle(string name, DateTime? pairedAtUtc, TimeZoneInfo? local = null) =>
        pairedAtUtc is { } at
            ? $"{name} · {MonthDay(TimeZoneInfo.ConvertTimeFromUtc(DateTime.SpecifyKind(at, DateTimeKind.Utc), local ?? TimeZoneInfo.Local))}配上"
            : name;

    /// 已配对那一行的第二行：「已连上」/「没连上 · 上次连上：3 小时前」（没记过就只有「没连上」）
    public static string PhoneStatus(bool connected, DateTime? lastSeenUtc, DateTime nowUtc, TimeZoneInfo? local = null) =>
        connected ? "已连上"
        : lastSeenUtc is { } seen ? $"没连上 · 上次连上：{Ago(seen, nowUtc, local)}"
        : "没连上";

    /// 不到 1 分 / N 分 / N 小时 / N 小时 M 分
    public static string Duration(TimeSpan span)
    {
        var minutes = (int)Math.Floor(span.TotalMinutes);
        if (minutes < 1) return "不到 1 分";
        if (minutes < 60) return $"{minutes} 分";
        return minutes % 60 == 0 ? $"{minutes / 60} 小时" : $"{minutes / 60} 小时 {minutes % 60} 分";
    }
}
