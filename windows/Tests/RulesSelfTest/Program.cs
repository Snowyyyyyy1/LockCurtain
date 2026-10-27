// RulesSelfTest —— 验证 windows/LockCurtain/Rules.cs 的条件判断、摘要和边沿触发
//
// 运行（在 Mac 上也能跑，不需要 Windows）：
//   cd windows/Tests/RulesSelfTest && dotnet run
//
// 对应 Tests/RulesSelfTest.swift，检查项一一对应。全部通过返回 0，有失败返回 1。

using LockCurtain;

var failures = 0;
var total = 0;

void Check(bool cond, string name)
{
    total++;
    Console.WriteLine((cond ? "  OK   " : "  FAIL ") + name);
    if (!cond) failures++;
}

/// 2026-10-25 是周日（Mac weekday 1）
DateTime At(int day, int h, int m = 0) => new(2026, 10, day, h, m, 0);

/// 进程名在调用方规范化（RuleFacts 约定里面存的已经是规范化后的名字）
IReadOnlySet<string> Norm(IEnumerable<string>? names) =>
    (names ?? Array.Empty<string>()).Select(RuleFacts.Normalize).ToHashSet();

RuleFacts Facts(double idle = 0, IEnumerable<string>? running = null, IEnumerable<string>? blockers = null,
                DateTime? now = null, bool ac = true) =>
    new(idle, Norm(running), Norm(blockers), now ?? At(25, 12), ac);

Console.WriteLine("== 时间段 ==");
var night = new TimeWindow { Start = 23 * 60, End = 7 * 60, Weekdays = new List<int> { 1 } };   // 周日夜里
Check(night.Contains(At(25, 23, 30)), "周日 23:30 在周日 23–07 内");
Check(night.Contains(At(26, 6, 59)), "周一 06:59 算周日那一段的后半夜");
Check(!night.Contains(At(26, 7, 0)), "周一 07:00 已结束");
Check(!night.Contains(At(25, 6, 0)), "周日 06:00 属于周六那一段，周六没选");
var day = new TimeWindow { Start = 9 * 60, End = 18 * 60, Weekdays = new List<int> { 2, 3, 4, 5, 6 } };
Check(day.Contains(At(26, 9)), "周一 09:00 在工作日 9–18 内");
Check(!day.Contains(At(25, 10)), "周日不在工作日内");
Check(!day.Contains(At(26, 18)), "18:00 已结束（左闭右开）");

Console.WriteLine("== 条件组合 ==");
var r = new CurtainRule { Name = "agent 跑着且离开 5 分钟" };
Check(!r.Matches(Facts(idle: 9999)), "一个条件都没开 -> 永不命中");
r.IdleMinutes = 5;
r.Processes = new List<string> { "claude", "com.example.agent" };
Check(!r.Matches(Facts(idle: 299, running: new[] { "claude" })), "空闲不足 -> 不命中");
Check(r.Matches(Facts(idle: 300, running: new[] { "claude" })), "空闲够 + 进程名命中");
Check(r.Matches(Facts(idle: 300, running: new[] { "com.example.agent" })), "bundle ID 也能命中");
Check(!r.Matches(Facts(idle: 300, running: new[] { "Finder" })), "进程不在 -> 不命中");
r.RequireACPower = true;
Check(!r.Matches(Facts(idle: 300, running: new[] { "claude" }, ac: false)), "要求接电源但在用电池 -> 不命中");
r.Enabled = false;
Check(!r.Matches(Facts(idle: 300, running: new[] { "claude" })), "禁用 -> 不命中");

Console.WriteLine("== 阻止睡眠 ==");
var awake = new CurtainRule { Name = "有 app 不让睡且离开 10 分钟" };
awake.IdleMinutes = 10;
awake.SleepBlockers = new List<string>();
Check(awake.HasConditions, "只开「阻止睡眠」也算有条件");
Check(!awake.Matches(Facts(idle: 600)), "任意 app：没有 app 在阻止 -> 不命中");
Check(awake.Matches(Facts(idle: 600, blockers: new[] { "caffeinate" })), "任意 app：有一个在阻止 -> 命中");
Check(!awake.Matches(Facts(idle: 599, blockers: new[] { "caffeinate" })), "有 app 在阻止但空闲不足 -> 不命中");
awake.SleepBlockers = new List<string> { "com.openai.codex", "caffeinate" };
Check(awake.Matches(Facts(idle: 600, blockers: new[] { "com.openai.codex", "ChatGPT" })), "指定 app：bundle ID 命中");
Check(awake.Matches(Facts(idle: 600, blockers: new[] { "caffeinate" })), "指定 app：进程名命中");
Check(!awake.Matches(Facts(idle: 600, blockers: new[] { "Claude" })), "指定 app：在阻止的是别的 app -> 不命中");
Check(!awake.Matches(Facts(idle: 600, running: new[] { "caffeinate" })), "只在运行、没在阻止 -> 不命中");

Console.WriteLine("== 边沿触发 ==");
var app = new CurtainRule { Name = "app 在运行", Processes = new List<string> { "claude" } };
var t = new RuleTrigger();
Check(t.Step(new[] { app }, Facts(running: new[] { "claude" })).Count == 0, "第一次检查就成立 -> 不触发（启动/新建时不盖人）");
Check(t.Step(new[] { app }, Facts(running: Array.Empty<string>())).Count == 0, "变为不成立 -> 不触发");
var fired = t.Step(new[] { app }, Facts(running: new[] { "claude" }));
Check(fired.Count == 1 && ReferenceEquals(fired[0], app), "不成立 -> 成立 -> 触发");
Check(t.Step(new[] { app }, Facts(running: new[] { "claude" })).Count == 0, "持续成立 -> 不再触发（人撤掉遮罩后不会马上又盖上）");

Console.WriteLine("== 改规则不触发 ==");
var u = new RuleTrigger();
var edit = new CurtainRule { Name = "编辑中", Processes = new List<string> { "nothing-running" } };
_ = u.Step(new[] { edit }, Facts(running: new[] { "Finder" }));
_ = u.Step(new[] { edit }, Facts(running: new[] { "Finder" }));
edit.Processes = new List<string> { "Finder" };                 // 在设置里改成一个正好成立的条件
Check(u.Step(new[] { edit }, Facts(running: new[] { "Finder" })).Count == 0, "刚改成成立 -> 不触发");

Console.WriteLine("== 锁屏期间冻结 ==");
var v = new RuleTrigger();
_ = v.Step(new[] { app }, Facts(running: Array.Empty<string>()));
_ = v.Step(new[] { app }, Facts(running: new[] { "claude" }));          // 已触发，人回来撤掉遮罩，然后锁屏
Check(v.Step(new[] { app }, Facts(running: new[] { "claude" }), frozen: true).Count == 0, "锁屏中 -> 不触发");
Check(v.Step(new[] { app }, Facts(running: new[] { "claude" })).Count == 0, "解锁后条件仍成立 -> 不触发（不绕死循环）");

Console.WriteLine(failures == 0
    ? $"全部通过（共 {total} 项）"
    : $"{failures} 项失败（共 {total} 项）");
return failures == 0 ? 0 : 1;
