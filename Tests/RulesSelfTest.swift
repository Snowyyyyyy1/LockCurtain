// RulesSelfTest.swift —— 验证 Sources/Rules.swift 的条件判断和边沿触发
//
//   D=$TMPDIR/rt; rm -rf $D && mkdir -p $D
//   cp Tests/RulesSelfTest.swift $D/main.swift
//   cp Sources/Rules.swift $D/
//   xcrun swiftc -o $D/selftest $D/main.swift $D/Rules.swift
//   $D/selftest

import Foundation

setvbuf(stdout, nil, _IONBF, 0)

var failures = 0
func check(_ cond: Bool, _ name: String) {
    print((cond ? "  OK   " : "  FAIL ") + name)
    if !cond { failures += 1 }
}

var cal = Calendar(identifier: .gregorian)
cal.timeZone = TimeZone(identifier: "UTC")!    // 任意没有夏令时的时区都行，结果和本机时区无关
/// 2026-10-25 是周日（weekday 1）
func at(_ day: Int, _ h: Int, _ m: Int = 0) -> Date {
    cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: h, minute: m))!
}
func facts(idle: Double = 0, running: Set<String> = [], blockers: Set<String> = [], now: Date = at(25, 12),
           ac: Bool = true) -> RuleFacts {
    RuleFacts(idleSeconds: idle, running: running, sleepBlockers: blockers, now: now, onACPower: ac)
}

print("== 时间段 ==")
let night = TimeWindow(start: 23 * 60, end: 7 * 60, weekdays: [1])   // 周日夜里
check(night.contains(at(25, 23, 30), calendar: cal), "周日 23:30 在周日 23–07 内")
check(night.contains(at(26, 6, 59), calendar: cal), "周一 06:59 算周日那一段的后半夜")
check(!night.contains(at(26, 7, 0), calendar: cal), "周一 07:00 已结束")
check(!night.contains(at(25, 6, 0), calendar: cal), "周日 06:00 属于周六那一段，周六没选")
let day = TimeWindow(start: 9 * 60, end: 18 * 60, weekdays: Set(2...6))
check(day.contains(at(26, 9), calendar: cal), "周一 09:00 在工作日 9–18 内")
check(!day.contains(at(25, 10), calendar: cal), "周日不在工作日内")
check(!day.contains(at(26, 18), calendar: cal), "18:00 已结束（左闭右开）")

print("== 条件组合 ==")
var r = CurtainRule(name: "agent 跑着且离开 5 分钟")
check(!r.matches(facts(idle: 9999), calendar: cal), "一个条件都没开 -> 永不命中")
r.idleMinutes = 5
r.processes = ["claude", "com.example.agent"]
check(!r.matches(facts(idle: 299, running: ["claude"]), calendar: cal), "空闲不足 -> 不命中")
check(r.matches(facts(idle: 300, running: ["claude"]), calendar: cal), "空闲够 + 进程名命中")
check(r.matches(facts(idle: 300, running: ["com.example.agent"]), calendar: cal), "bundle ID 也能命中")
check(!r.matches(facts(idle: 300, running: ["Finder"]), calendar: cal), "进程不在 -> 不命中")
r.requireACPower = true
check(!r.matches(facts(idle: 300, running: ["claude"], ac: false), calendar: cal), "要求接电源但在用电池 -> 不命中")
r.enabled = false
check(!r.matches(facts(idle: 300, running: ["claude"]), calendar: cal), "禁用 -> 不命中")

print("== 阻止睡眠 ==")
var awake = CurtainRule(name: "有 app 不让睡且离开 10 分钟")
awake.idleMinutes = 10
awake.sleepBlockers = []
check(awake.hasConditions, "只开「阻止睡眠」也算有条件")
check(!awake.matches(facts(idle: 600), calendar: cal), "任意 app：没有 app 在阻止 -> 不命中")
check(awake.matches(facts(idle: 600, blockers: ["caffeinate"]), calendar: cal), "任意 app：有一个在阻止 -> 命中")
check(!awake.matches(facts(idle: 599, blockers: ["caffeinate"]), calendar: cal), "有 app 在阻止但空闲不足 -> 不命中")
awake.sleepBlockers = ["com.openai.codex", "caffeinate"]
check(awake.matches(facts(idle: 600, blockers: ["com.openai.codex", "ChatGPT"]), calendar: cal), "指定 app：bundle ID 命中")
check(awake.matches(facts(idle: 600, blockers: ["caffeinate"]), calendar: cal), "指定 app：进程名命中")
check(!awake.matches(facts(idle: 600, blockers: ["Claude"]), calendar: cal), "指定 app：在阻止的是别的 app -> 不命中")
check(!awake.matches(facts(idle: 600, running: ["caffeinate"]), calendar: cal), "只在运行、没在阻止 -> 不命中")

print("== 边沿触发 ==")
var app = CurtainRule(name: "app 在运行")
app.processes = ["claude"]
var t = RuleTrigger()
check(t.step([app], facts(running: ["claude"]), calendar: cal).isEmpty, "第一次检查就成立 -> 不触发（启动/新建时不盖人）")
check(t.step([app], facts(running: []), calendar: cal).isEmpty, "变为不成立 -> 不触发")
check(t.step([app], facts(running: ["claude"]), calendar: cal) == [app], "不成立 -> 成立 -> 触发")
check(t.step([app], facts(running: ["claude"]), calendar: cal).isEmpty, "持续成立 -> 不再触发（人撤掉遮罩后不会马上又盖上）")

print("== 改规则不触发 ==")
var u = RuleTrigger()
var edit = CurtainRule(name: "编辑中")
edit.processes = ["nothing-running"]
_ = u.step([edit], facts(running: ["Finder"]), calendar: cal)
_ = u.step([edit], facts(running: ["Finder"]), calendar: cal)
edit.processes = ["Finder"]                     // 在设置里改成一个正好成立的条件
check(u.step([edit], facts(running: ["Finder"]), calendar: cal).isEmpty, "刚改成成立 -> 不触发")

print("== 锁屏期间冻结 ==")
var v = RuleTrigger()
_ = v.step([app], facts(running: []), calendar: cal)
_ = v.step([app], facts(running: ["claude"]), calendar: cal)           // 已触发，人回来撤掉遮罩，然后锁屏
check(v.step([app], facts(running: ["claude"]), frozen: true, calendar: cal).isEmpty, "锁屏中 -> 不触发")
check(v.step([app], facts(running: ["claude"]), calendar: cal).isEmpty, "解锁后条件仍成立 -> 不触发（不绕死循环）")

if failures == 0 { print("全部通过") } else { print(String(failures) + " 项失败") }
exit(failures == 0 ? 0 : 1)
