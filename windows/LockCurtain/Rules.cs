// Rules.cs —— 自动进入离开模式的规则（纯数据 + 纯函数，不依赖 WinForms 和 Windows API，方便单测）
//
// 对应 Mac 版的 Sources/Rules.swift 和 RulesPane.swift 里的 summary。
//
// 一条规则 = 若干条件，全部满足才算命中；一个条件都没开的规则永远不命中。
// 命中后只做一件事：进入离开模式。条件结束时遮罩保持，等人回来碰一下再先锁屏后撤。
//
// 触发是「边沿」的：只在规则从不命中变成命中的那一刻触发一次。
// 如果按「命中就保持遮罩」做，「某进程在运行」这类持续成立的条件会在人撤掉遮罩后立刻再次触发，
// 人就被锁在外面了。所以条件必须先变回不成立，规则才能再次触发。

using System.Text.Json;
using System.Text.Json.Serialization;

namespace LockCurtain;

/// 每周的时间段。Start > End 表示跨午夜（如 23:00–07:00）
internal sealed class TimeWindow
{
    /// 当天第几分钟，0...1439
    public int Start { get; set; }
    public int End { get; set; }
    /// Mac 的 Calendar weekday 约定：1 = 周日 … 7 = 周六。跨午夜的后半段按开始那天算
    public List<int> Weekdays { get; set; } = new();

    /// 23:00–07:00，每天
    public static TimeWindow Default => new()
    {
        Start = 23 * 60,
        End = 7 * 60,
        Weekdays = new List<int> { 1, 2, 3, 4, 5, 6, 7 },
    };

    public bool Contains(DateTime local)
    {
        var minute = local.Hour * 60 + local.Minute;
        // DayOfWeek 的 Sunday = 0，换成 Mac 约定的 1 = 周日
        var today = (int)local.DayOfWeek + 1;
        var yesterday = today == 1 ? 7 : today - 1;
        if (Start == End) return Weekdays.Contains(today);                  // 全天
        if (Start < End) return minute >= Start && minute < End && Weekdays.Contains(today);
        if (minute >= Start) return Weekdays.Contains(today);               // 跨午夜的前半段
        if (minute < End) return Weekdays.Contains(yesterday);              // 跨午夜的后半段
        return false;
    }
}

internal sealed class CurtainRule
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Name { get; set; } = "";
    public bool Enabled { get; set; } = true;
    /// 空闲至少多少分钟；null = 不限
    public int? IdleMinutes { get; set; }
    /// 任一在运行即满足：进程名（如 claude.exe）；null = 不限，空列表 = 永远不满足
    public List<string>? Processes { get; set; }
    /// 有 app 在阻止睡眠：空列表 = 任意 app；否则列表里任一在阻止即满足；null = 不限
    public List<string>? SleepBlockers { get; set; }
    /// null = 不限
    public TimeWindow? TimeWindow { get; set; }
    public bool RequireACPower { get; set; }

    [JsonIgnore]
    public bool HasConditions =>
        IdleMinutes != null || Processes != null || SleepBlockers != null || TimeWindow != null || RequireACPower;

    public bool Matches(RuleFacts f)
    {
        if (!Enabled || !HasConditions) return false;
        if (IdleMinutes is { } m && f.IdleSeconds < (double)(m * 60)) return false;
        // 规则里的名字要先规范化，运行中的名字已经是规范化后的（见 RuleFacts.Normalize）
        if (Processes is { } p && !p.Any(n => f.Running.Contains(RuleFacts.Normalize(n)))) return false;
        if (SleepBlockers is { } b)
        {
            // 空列表 = 任意 app 在阻止即可；非空 = 列表里任一在阻止
            var ok = b.Count == 0
                ? f.SleepBlockers.Count > 0
                : b.Any(n => f.SleepBlockers.Contains(RuleFacts.Normalize(n)));
            if (!ok) return false;
        }
        if (TimeWindow is { } w && !w.Contains(f.Now)) return false;
        if (RequireACPower && !f.OnACPower) return false;
        return true;
    }

    /// 深拷贝：列表和时间段都复制一份，之后改原规则不影响副本
    public CurtainRule Clone() => new()
    {
        Id = Id,
        Name = Name,
        Enabled = Enabled,
        IdleMinutes = IdleMinutes,
        Processes = Processes is null ? null : new List<string>(Processes),
        SleepBlockers = SleepBlockers is null ? null : new List<string>(SleepBlockers),
        TimeWindow = CopyWindow(TimeWindow),
        RequireACPower = RequireACPower,
    };

    static TimeWindow? CopyWindow(TimeWindow? w) => w is null
        ? null
        : new TimeWindow { Start = w.Start, End = w.End, Weekdays = new List<int>(w.Weekdays) };

    /// 设置窗口里显示的一行摘要（对应 Mac 版 RulesPane.swift 的 summary）
    public string Summary()
    {
        var parts = new List<string>();
        if (IdleMinutes is { } m) parts.Add($"空闲 {m} 分钟");
        if (Processes is { } p) parts.Add(p.Count == 0 ? "进程（未填）" : string.Join(" / ", p) + " 在运行");
        if (SleepBlockers is { } b)
            parts.Add(b.Count == 0 ? "有程序在阻止睡眠" : string.Join(" / ", b) + " 在阻止睡眠");
        if (TimeWindow is { } w)
        {
            // 星期按周一到周日排列，和 Mac 版 weekdaysMondayFirst 一样
            var days = w.Weekdays.Distinct().Count() == 7
                ? "每天"
                : string.Join("、", MondayFirst.Where(w.Weekdays.Contains).Select(ShortWeekdayName));
            parts.Add($"{days} {Hm(w.Start)}–{Hm(w.End)}");
        }
        if (RequireACPower) parts.Add("接着电源");
        return parts.Count == 0 ? "没有条件，不会触发" : string.Join("，", parts);
    }

    /// Mac 的 Calendar weekday：2 3 4 5 6 7 1，即周一到周日
    static readonly int[] MondayFirst = { 2, 3, 4, 5, 6, 7, 1 };

    /// 按 Mac 的 weekday（1 = 周日 … 7 = 周六）取中文简称。InvariantGlobalization 下没有文化数据，所以写死
    static string ShortWeekdayName(int weekday) => weekday switch
    {
        1 => "周日",
        2 => "周一",
        3 => "周二",
        4 => "周三",
        5 => "周四",
        6 => "周五",
        7 => "周六",
        _ => "",
    };

    static string Hm(int minute) => $"{minute / 60:D2}:{minute % 60:D2}";
}

/// 一次检查时采集到的系统状态
internal sealed record RuleFacts(
    double IdleSeconds,
    IReadOnlySet<string> Running,
    IReadOnlySet<string> SleepBlockers,
    DateTime Now,
    bool OnACPower)
{
    /// Windows 没有 bundle ID，名字就是进程名。规范化 = 去首尾空白、转小写、去掉结尾的 ".exe"
    /// 所以规则里写 "Claude.exe" 能匹配到运行中的 "claude"
    public static string Normalize(string name)
    {
        var s = name.Trim().ToLowerInvariant();
        return s.EndsWith(".exe", StringComparison.Ordinal) ? s[..^4] : s;
    }
}

/// 边沿检测：记住每条规则上一次是否命中，只在不命中 → 命中时报告
internal sealed class RuleTrigger
{
    /// 上一次检查时每条规则的指纹和是否命中。用指纹而不是对象引用，
    /// 因为调用方会原地修改规则
    Dictionary<Guid, (string Fingerprint, bool Matching)> last = new();

    /// frozen: 真实锁屏期间传 true，此时不更新状态也不触发。
    /// 否则锁屏让条件「变假」、解锁又「变真」，解锁那一刻就会触发离开模式，
    /// 人一碰又锁屏，绕成死循环
    /// 返回本次刚命中的规则
    public List<CurtainRule> Step(IReadOnlyList<CurtainRule> rules, RuleFacts facts, bool frozen = false)
    {
        if (frozen) return new List<CurtainRule>();
        var fired = new List<CurtainRule>();
        var next = new Dictionary<Guid, (string Fingerprint, bool Matching)>();
        foreach (var r in rules)
        {
            var now = r.Matches(facts);
            var fp = Fingerprint(r);
            // 新加的、刚改过的规则（含启动后第一次检查）视为「之前已命中」：
            // 否则在设置里改出一条正好成立的规则，下一次检查就会把正在改设置的人盖住
            if (now && last.TryGetValue(r.Id, out var prev) && prev.Fingerprint == fp && !prev.Matching)
                fired.Add(r);
            next[r.Id] = (fp, now);
        }
        last = next;
        return fired;
    }

    /// 单条规则的 JSON 指纹，用来判断「是不是同一条规则」（对应 Swift 的 prev.rule == r）。
    /// 时间段的星期按 Swift Set 的语义处理：去重、忽略顺序
    static string Fingerprint(CurtainRule r)
    {
        var copy = r.Clone();
        if (copy.TimeWindow is { } w) w.Weekdays = w.Weekdays.Distinct().OrderBy(x => x).ToList();
        return RuleJson.Write(new List<CurtainRule> { copy });
    }
}

/// 规则和 rules.json 之间的转换，格式和 Mac 版 Swift Codable 一致
internal static class RuleJson
{
    static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    /// 格式不对时抛 JsonException
    public static List<CurtainRule> Parse(string json) =>
        JsonSerializer.Deserialize<List<CurtainRule>>(json, Options) ?? new List<CurtainRule>();

    public static string Write(IReadOnlyList<CurtainRule> rules) =>
        JsonSerializer.Serialize(rules, Options);
}
