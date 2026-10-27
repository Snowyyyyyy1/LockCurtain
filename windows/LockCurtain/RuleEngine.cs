// RuleEngine.cs —— 规则的存储、系统状态采集、定时检查（对应 Mac 版 RuleEngine.swift）
//
// 规则存在 %LOCALAPPDATA%\LockCurtain\rules.json，格式和 Mac 版一样，设置窗口改完立即保存。
// 每 5 秒采集一次系统状态，交给 RuleTrigger 做边沿检测，命中就进入离开模式。
// 采集在后台线程做（powercfg 要起一个进程），判断和触发回到 UI 线程。
// 锁屏期间冻结：不更新状态也不触发，见 Rules.cs。

using System.Diagnostics;
using System.Text.Json;

namespace LockCurtain;

internal sealed class RuleStore
{
    static readonly string FilePath = Path.Combine(Log.Dir, "rules.json");

    public List<CurtainRule> Rules { get; }

    public RuleStore()
    {
        try { Rules = RuleJson.Parse(File.ReadAllText(FilePath)); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { Rules = new(); }
        catch (JsonException e)
        {
            Log.Write($"rules.json 解析失败，按无规则处理: {e.Message}");
            Rules = new();
        }
    }

    /// 改完 Rules 调一次：写盘
    public void Save()
    {
        try
        {
            Directory.CreateDirectory(Log.Dir);
            File.WriteAllText(FilePath, RuleJson.Write(Rules));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            Log.Write($"rules.json 保存失败: {e.Message}");
        }
    }
}

internal static class SystemFacts
{
    static readonly HashSet<string> None = new();

    /// 进程列表、阻止睡眠都要多花点时间，只在有规则用到时才收集
    public static RuleFacts Collect(bool processes, bool sleepBlockers) => new(
        IdleSeconds(),
        processes ? Running() : None,
        sleepBlockers ? SleepBlockers.Snapshot()?.Programs.Select(b => b.Name).ToHashSet() ?? None : None,
        DateTime.Now,
        OnACPower());

    /// 距上一次键盘 / 鼠标输入的秒数。GetLastInputInfo 也算合成输入，和 Mac 版 hidSystemState 一样
    public static double IdleSeconds() => unchecked(Native.GetTickCount() - Native.LastInputTick()) / 1000.0;

    /// 所有进程名（规范化后，见 RuleFacts.Normalize）
    public static HashSet<string> Running()
    {
        var names = new HashSet<string>();
        foreach (var p in Process.GetProcesses())
            using (p) names.Add(RuleFacts.Normalize(p.ProcessName));
        return names;
    }

    /// 查不到（台式机报 255 未知）按接着电源算，和 Mac 版一样
    static bool OnACPower() => !Native.GetSystemPowerStatus(out var s) || s.ACLineStatus != 0;
}

internal sealed class RuleEngine
{
    readonly RuleStore store;
    readonly Action<CurtainRule> fire;
    readonly System.Windows.Forms.Timer timer = new() { Interval = 5000 };
    RuleTrigger trigger = new();
    bool checking;

    public RuleEngine(RuleStore store, Action<CurtainRule> fire)
    {
        this.store = store;
        this.fire = fire;
        timer.Tick += async (_, _) => await Check();
    }

    public void Start()
    {
        timer.Start();
        _ = Check();
    }

    async Task Check()
    {
        if (checking) return;
        var enabled = store.Rules.Where(r => r.Enabled).ToList();
        if (enabled.Count == 0)
        {
            trigger = new();
            return;
        }
        checking = true;
        try
        {
            // 只为开着的规则收集：枚举进程、跑 powercfg 都不便宜
            bool processes = enabled.Any(r => r.Processes != null), blockers = enabled.Any(r => r.SleepBlockers != null);
            var facts = await Task.Run(() => SystemFacts.Collect(processes, blockers));
            var fired = trigger.Step(store.Rules, facts, frozen: Session.IsLocked());
            if (fired.Count == 0) return;
            Log.Write($"rule fired: {fired[0].Name}");
            fire(fired[0]);
        }
        finally { checking = false; }
    }
}
