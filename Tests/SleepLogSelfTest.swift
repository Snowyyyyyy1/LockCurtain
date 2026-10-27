// SleepLogSelfTest.swift —— 验证 Sources/SleepLog.swift 的日志解析、Sources/IntervalSet.swift 的区间代数
// 和 Sources/SleepLedger.swift 的 24 小时统计
//
//   D=$TMPDIR/sleeplog; rm -rf $D && mkdir -p $D
//   cp Tests/SleepLogSelfTest.swift $D/main.swift
//   cp Sources/SleepLog.swift Sources/IntervalSet.swift Sources/SleepLedger.swift Sources/SleepBlockers.swift Sources/ProcessTable.swift $D/
//   xcrun swiftc -o $D/selftest $D/main.swift $D/SleepLog.swift $D/IntervalSet.swift $D/SleepLedger.swift $D/SleepBlockers.swift $D/ProcessTable.swift
//   $D/selftest

import Foundation

setvbuf(stdout, nil, _IONBF, 0)

var failures = 0
func check(_ cond: Bool, _ name: String) {
    print((cond ? "  OK   " : "  FAIL ") + name)
    if !cond { failures += 1 }
}

/// 用 UTC 构造绝对时间，便于和带偏移的日志时间比较
var utc = Calendar(identifier: .gregorian)
utc.timeZone = TimeZone(identifier: "UTC")!
func utcDate(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int) -> Date {
    utc.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
}

print("== IntervalSet: 归一化 ==")
do {
    let set = IntervalSet([(0, 10), (5, 15), (12, 20)])
    check(set.intervals == [Interval(0, 20)], "重叠区间合并为一段")
}
do {
    let set = IntervalSet([(0, 10), (10, 20)])
    check(set.intervals == [Interval(0, 20)], "首尾相接的区间合并")
}
do {
    let set = IntervalSet([(30, 40), (0, 10), (15, 20)])
    check(set.intervals == [Interval(0, 10), Interval(15, 20), Interval(30, 40)], "不相交区间保持分离并升序")
}
do {
    let set = IntervalSet([(10, 10), (5, 5)])
    check(set.isEmpty, "空区间和零长区间被丢弃")
    check(Interval(10, 5) == Interval(5, 10), "颠倒的区间被规范化，不产生负长度")
}
do {
    let set = IntervalSet([(0, 100), (20, 30)])
    check(set.intervals == [Interval(0, 100)], "被包含的区间不扩大并集")
    check(set.totalDuration == 100, "被包含的区间不增加总时长")
}

print("== IntervalSet: 时长 ==")
do {
    let set = IntervalSet([(0, 10), (5, 15), (100, 130)])
    check(set.totalDuration == 45, "总时长只累加不相交的段（45，不是 50）")
}

print("== IntervalSet: 交集 ==")
do {
    let a = IntervalSet([(0, 10), (20, 30)])
    let b = IntervalSet([(5, 25)])
    check(a.intersectionDuration(with: b) == 10, "交集时长只统计一次重叠（[5,10)+[20,25)=10）")
    check(a.intersecting(b).intervals == [Interval(5, 10), Interval(20, 25)], "交集返回重叠的各段")
}
do {
    let a = IntervalSet([(0, 10)])
    check(a.intersectionDuration(with: .empty) == 0, "与空集的交集为 0")
}

print("== IntervalSet: 差集 ==")
do {
    let a = IntervalSet([(0, 100)])
    let b = IntervalSet([(40, 60)])
    check(a.subtracting(b).intervals == [Interval(0, 40), Interval(60, 100)], "挖掉中间一段会切成两段")
    check(a.subtracting(b).totalDuration == 80, "挖洞后剩余 80")
}
do {
    let a = IntervalSet([(0, 100)])
    check(a.subtracting(IntervalSet([(0, 100)])).isEmpty, "减去整个区间后为空")
}
do {
    let a = IntervalSet([(0, 10)])
    let b = IntervalSet([(50, 60)])
    check(a.subtracting(b).intervals == [Interval(0, 10)], "减去不相交的集合不变")
}
do {
    let a = IntervalSet([(10, 20)])
    let b = IntervalSet([(0, 15)])
    check(a.subtracting(b).intervals == [Interval(15, 20)], "减去越界的集合会裁掉边缘")
}
check(IntervalSet.empty.subtracting(IntervalSet([(0, 10)])).isEmpty, "从空集相减仍为空")

print("== IntervalSet: 账本链路 ==")
do {
    // 断言持续 0..100；机器睡眠 0..30；用户活跃 60..100
    let assertions = IntervalSet([(0, 100)])
    let sleep = IntervalSet([(0, 30)])
    let active = IntervalSet([(60, 100)])
    let net = assertions.subtracting(sleep).subtracting(active)
    check(net.intervals == [Interval(30, 60)], "断言 - 睡眠 - 活跃 = 30..60")
    check(net.totalDuration == 30, "真正阻止睡眠的时长为 30 秒")
}
do {
    // 两个进程同时阻止睡眠，不能重复计数
    let net = IntervalSet([(0, 100)])
    let processA = IntervalSet([(0, 60)])
    let processB = IntervalSet([(40, 100)])
    let aShare = processA.intersectionDuration(with: net)
    let bShare = processB.intersectionDuration(with: net)
    check(aShare == 60, "进程 A 的份额为 60")
    check(bShare == 60, "进程 B 的份额为 60")
    check(aShare <= net.totalDuration && bShare <= net.totalDuration, "每个份额都不超过总量（不会超过 120 > 100）")
}

print("== IntervalSet: 截取与覆盖率 ==")
do {
    let set = IntervalSet([(0, 100)])
    check(set.clamped(to: Interval(40, 60)).intervals == [Interval(40, 60)], "截取限制在窗口内")
}
do {
    let set = IntervalSet([(0, 10), (200, 300)])
    check(set.clamped(to: Interval(100, 150)).isEmpty, "截取丢弃窗口外的区间")
}
do {
    let set = IntervalSet([(0, 50)])
    check(set.coverage(of: Interval(0, 100)) == 0.5, "覆盖率为窗口的一半")
    check(set.coverage(of: Interval(0, 0)) == 0, "零长窗口的覆盖率为 0")
}

print("== IntervalSet: 合并近邻 ==")
do {
    let set = IntervalSet([(0, 10), (12, 20), (60, 70)])
    check(set.coalescing(gap: 5).intervals == [Interval(0, 20), Interval(60, 70)], "只合并间隔小于阈值的段")
}

print("== SleepLog: 断言 ==")
do {
    let line = #"2026-09-22 21:36:36 +0800 Assertions          PID 3527(nsurlsessiond) Created SystemIsActive "NSURLSessionTask 5A00F064-0DBB-47D9-986A-11DCB057B95F" 00:00:00  id:0x0xc0000856e [System: PrevIdle DeclUser SysAct kDisp]"#
    let log = SleepLogParser.parse(line)
    check(log.assertions.count == 1, "Created 断言行被解析")
    let e = log.assertions.first
    check(e?.pid == 3527, "pid 为 3527")
    check(e?.processName == "nsurlsessiond", "进程名为 nsurlsessiond")
    check(e?.action == .created, "动作为 Created")
    check(e?.type == "SystemIsActive", "类型为 SystemIsActive")
    check(e?.assertionID == "0x0xc0000856e", "断言 ID 正确")
    check(e?.reportedDuration == 0, "00:00:00 的时长为 0")
    check(e?.timestamp == utcDate(2026, 9, 22, 13, 36, 36), "时间戳使用行内 +0800 偏移（UTC 13:36:36）")
}
do {
    let line = #"2026-09-22 21:36:40 +0800 Assertions           PID 3527(nsurlsessiond) Released SystemIsActive "NSURLSessionTask 5A00F064" 00:00:04  id:0x0xc0000856e [System: PrevIdle]"#
    let log = SleepLogParser.parse(line)
    check(log.assertions.count == 1, "Released 断言行被解析")
    check(log.assertions.first?.action == .released, "动作为 Released")
    check(log.assertions.first?.reportedDuration == 4, "00:00:04 的时长为 4 秒")
}
do {
    let line = #"2026-09-22 21:36:23 +0800 Assertions           PID 377(powerd) Summary PreventUserIdleSystemSleep "Powerd - Prevent sleep while display is on" 00:42:29  id:0x0x10000a6f6 [System: PrevIdle DeclUser kDisp]"#
    let log = SleepLogParser.parse(line)
    check(log.assertions.count == 1, "Summary 行被解析")
    check(log.assertions.first?.action == .summary, "动作为 Summary")
    check(log.assertions.first?.reportedDuration == 42 * 60 + 29, "00:42:29 折算为 2549 秒")
}
do {
    // TurnedOn、TurnedOff、TimedOut、CapExpired、ClientDied 都在真实日志中出现，漏掉任何一个都会悄悄破坏账本
    let cases: [(String, AssertionLogEntry.Action)] = [
        ("TurnedOn", .turnedOn),
        ("TurnedOff", .turnedOff),
        ("TimedOut", .timedOut),
        ("CapExpired", .capExpired),
        ("ClientDied", .clientDied),
    ]
    var allOK = true
    for (word, expected) in cases {
        let line = #"2026-09-22 21:36:40 +0800 Assertions           PID 100(test) \#(word) PreventUserIdleSystemSleep "x" 00:00:05  id:0x0xabc"#
        let log = SleepLogParser.parse(line)
        if log.assertions.count != 1 || log.assertions.first?.action != expected {
            print("        (动作词 \(word) 解析失败)")
            allOK = false
        }
    }
    check(allOK, "所有真实出现过的动作词都能解析成对应的 Action")
    check(AssertionLogEntry.Action.turnedOn.opensInterval && AssertionLogEntry.Action.clientDied.closesInterval, "opensInterval / closesInterval 分类正确")
}
do {
    let line = #"2026-09-22 21:36:40 +0800 Assertions           PID 100(test) SomethingNew PreventUserIdleSystemSleep "x" 00:00:05  id:0x0xabc"#
    check(SleepLogParser.parse(line).assertions.count == 1, "未知动作词不丢弃整行（按 Created 处理）")
}

print("== SleepLog: 睡眠/唤醒事件 ==")
do {
    let line = #"2026-09-22 21:54:44 +0800 Sleep                Entering Sleep state due to 'Clamshell Sleep':TCPKeepAlive=active Using Batt (Charge:79%) 123 secs"#
    let log = SleepLogParser.parse(line)
    check(log.events.count == 1, "Entering Sleep 行被解析")
    let e = log.events.first
    check(e?.kind == .sleep, "类别为 sleep")
    check(e?.reason == "Clamshell Sleep", "原因为 Clamshell Sleep（单引号内，可含空格）")
    check(e?.duration == 123, "持续时间为 123 秒")
}
do {
    let line = #"2026-09-22 21:56:47 +0800 DarkWake             DarkWake from Deep Idle [CDNP] : due to smc.sysState.Wake(0x70070000) wifibt SMC.OutboxNotEmpty bluetooth-pcie/ Using BATT (Charge:79%) 10 secs"#
    let log = SleepLogParser.parse(line)
    check(log.events.count == 1, "DarkWake 行被解析")
    let e = log.events.first
    check(e?.kind == .darkWake, "类别为 darkWake（不会被误判为 wake）")
    check(e?.powerSource == "BATT", "电源为 BATT")
    check(e?.batteryPercent == 79, "电量为 79%")
    check(e?.duration == 10, "持续时间为 10 秒")
    check(e?.reason.contains("wifibt") == true, "原因包含 wifibt")
    check(e?.reason.hasPrefix("smc.sysState.Wake(0x70070000) wifibt") == true, "原因保留末尾斜杠之前的内容")
}
do {
    // 回归：原因曾按 "/" 切分，在 `RTP.multi-touch/HID Activity` 处被截断
    let line = #"2026-09-23 13:57:14 +0800 Wake                 Wake from Deep Idle [CDNVA] : due to smc.sysState.Wake(0x70070000) lid SMC.OutboxNotEmpty RTP.multi-touch/HID Activity Using BATT (Charge:66%) 375 secs"#
    let log = SleepLogParser.parse(line)
    check(log.events.count == 1, "含斜杠原因的 Wake 行被解析")
    let e = log.events.first
    check(e?.kind == .wake, "类别为 wake")
    check(e?.reason.hasSuffix("RTP.multi-touch/HID Activity") == true, "原因完整保留斜杠部分")
    check(e?.duration == 375, "持续时间为 375 秒")
    check(e?.batteryPercent == 66, "电量为 66%")
}
do {
    // 回归：区间四舍五入为零时没有 `N secs`，曾因此丢行
    let line = #"2026-09-22 22:14:09 +0800 Wake                 Wake from Deep Idle [CDNVA] : due to smc.sysState.Wake(0x70070000) lid SMC.OutboxNotEmpty RTP.multi-touch/HID Activity Using BATT (Charge:79%)           "#
    let log = SleepLogParser.parse(line)
    check(log.events.count == 1 && log.events.first?.kind == .wake, "没有 secs 字段的 Wake 行仍被解析")
    check(log.events.first?.duration == 0, "没有 secs 字段时持续时间为 0")
}
do {
    let line = #"2026-09-23 14:30:31 +0800 Wake                 DarkWake to FullWake from Deep Idle [CDNVAP] : due to Notification Using AC (Charge:65%)           "#
    let log = SleepLogParser.parse(line)
    check(log.events.count == 1, "DarkWake to FullWake 行被解析")
    check(log.events.first?.kind == .wake, "DarkWake to FullWake 归类为完整唤醒")
    check(log.events.first?.reason == "Notification", "原因为 Notification")
    check(log.events.first?.powerSource == "AC", "电源为 AC")
}
do {
    let line = #"2026-09-22 21:56:57 +0800 Sleep                Entering Sleep state due to 'Maintenance Sleep':TCPKeepAlive=active Using Batt (Charge:79%) 136 secs"#
    check(SleepLogParser.parse(line).events.first?.isIdleSleep == true, "Maintenance Sleep 属于空闲睡眠")
}

print("== SleepLog: 健壮性 ==")
do {
    let noise = """
    =======
    Domain: 1
    boot:353
    2026-09-22 21:32:00 +0800 Assertion status system-wide:
       BackgroundTask                 0
    Kernel Assertions: 0x104=USB,MAGICWAKE
    """
    let log = SleepLogParser.parse(noise)
    check(log.assertions.isEmpty && log.events.isEmpty, "无关行被忽略且不崩溃")
}
do {
    let malformed = """
    2026-09-22 21:36:36 +0800 Assertions           PID notanumber(x) Created Bad "y" 00:00:00 id:z
    short
    2026-09-22 21:36:36 +0800 Assertions           PID 1(a) Created Bad "y" 00:00:00 id:z

    """
    let log = SleepLogParser.parse(malformed)
    check(log.assertions.allSatisfy { $0.pid > 0 }, "格式错误或过短的行安全跳过")
}
do {
    let text = """
    2026-09-22 21:36:36 +0800 Assertions           PID 1(a) Created PreventUserIdleSystemSleep "x" 00:00:01  id:0x0x1
    2026-09-22 21:36:37 +0800 Assertions           PID 1(a) Released PreventUserIdleSystemSleep "x" 00:00:02  id:0x0x1
    """
    check(SleepLogParser.parse(text).sourceLineCount == 2, "sourceLineCount 统计源文本行数")
}
do {
    // 时间戳本身损坏：不崩溃，直接跳过；同一段文本中的好行仍被解析
    let text = """
    XXXX-XX-XX XX:XX:XX +0800 Assertions           PID 100(test) Created PreventUserIdleSystemSleep "x" 00:00:01  id:0x0x1
    2026-09-22 21:36:36 +0800 Assertions           PID 100(test) Created PreventUserIdleSystemSleep "x" 00:00:01  id:0x0x2
    """
    let log = SleepLogParser.parse(text)
    check(log.assertions.count == 1, "时间戳损坏的行被跳过，好行照常解析")
    check(log.assertions.first?.assertionID == "0x0x2", "保留的是正确那一行")
}

print("== 时区偏移 ==")
do {
    let east = #"2026-10-25 02:30:00 +0200 Assertions           PID 100(test) Created PreventUserIdleSystemSleep "x" 00:00:01  id:0x0x1"#
    let west = #"2026-10-25 02:30:00 +0100 Assertions           PID 100(test) Created PreventUserIdleSystemSleep "x" 00:00:01  id:0x0x1"#
    let a = SleepLogParser.parse(east).assertions.first?.timestamp
    let b = SleepLogParser.parse(west).assertions.first?.timestamp
    check(a != nil && b != nil, "两条 DST 附近的行都能解析")
    check(a != nil && b != nil && abs(abs(a!.timeIntervalSince(b!)) - 3600) < 0.001, "+0200 与 +0100 的同一墙上时间相差恰好 3600 秒")
}

print("== SleepLog: since 过滤 ==")
do {
    let text = """
    2026-09-22 21:00:00 +0800 Assertions           PID 1(a) Created PreventUserIdleSystemSleep "x" 00:00:01  id:0x0x1
    2026-09-22 22:00:00 +0800 Assertions           PID 1(a) Created PreventUserIdleSystemSleep "x" 00:00:01  id:0x0x2
    2026-09-22 22:30:00 +0800 Sleep                Entering Sleep state due to 'Idle Sleep':TCPKeepAlive=active Using Batt (Charge:50%) 60 secs
    2026-09-22 21:30:00 +0800 Sleep                Entering Sleep state due to 'Idle Sleep':TCPKeepAlive=active Using Batt (Charge:50%) 60 secs
    """
    let since = utcDate(2026, 9, 22, 14, 0, 0)  // 即 +0800 的 22:00:00
    let log = SleepLogParser.parse(text, since: since)
    check(log.assertions.count == 1, "since 之前的断言行被丢弃，等于 since 的行保留")
    check(log.assertions.first?.assertionID == "0x0x2", "保留的是 22:00:00 那一行（边界包含）")
    check(log.events.count == 1, "since 之前的睡眠事件被丢弃")
    check(log.events.first?.timestamp == utcDate(2026, 9, 22, 14, 30, 0), "保留的事件时间正确")
    check(SleepLogParser.parse(text).assertions.count == 2, "不传 since 时全部保留")
}

print("== SleepLedger: 24 小时统计 ==")
do {
    /// 拼一行 pmset 日志：类别列从第 26 个字节开始，占 20 个字节
    func pm(_ time: String, _ category: String, _ body: String) -> String {
        "2026-10-26 \(time) +0000 " + category.padding(toLength: 20, withPad: " ", startingAt: 0) + "\t" + body
    }
    func assertion(_ time: String, _ proc: String, _ action: String, _ type: String, _ dur: String, _ id: String) -> String {
        pm(time, "Assertions", "PID \(proc) \(action) \(type) \"test\" \(dur)  id:0x0x\(id) [System: PrevIdle]")
    }
    let text = [
        pm("00:00:00", "Sleep", "Entering Sleep state due to 'Idle Sleep':TCPKeepAlive=active Using AC (Charge:100%) 3600 secs"),
        pm("01:00:00", "Wake", "Wake from Normal Sleep [CDNVA] : due to UserActivity Using AC (Charge:100%)"),
        // 只有 Released：按持续时长倒推到前一天 23:00，中间睡着的一小时不算被阻止
        assertion("02:00:00", "100(caffeinate)", "Released", "PreventUserIdleSystemSleep", "03:00:00", "1"),
        // 只出现在 Summary、进程已经没了：算到这一行为止
        assertion("03:00:00", "999(ghost)", "Summary", "PreventUserIdleSystemSleep", "00:30:00", "2"),
        // 不足 1 分钟：计入总时长，但不列出
        assertion("05:00:00", "101(blip)", "Released", "NoIdleSleepAssertion", "00:00:30", "3"),
        // 不阻止睡眠的类型
        assertion("06:00:00", "102(nsurlsessiond)", "Released", "SystemIsActive", "01:00:00", "4"),
        assertion("08:00:00", "139(powerd)", "Created", "UserIsActive", "00:00:00", "5"),
        assertion("09:00:00", "139(powerd)", "Released", "UserIsActive", "01:00:00", "5"),
        // 只出现在 Summary、进程还活着：开到现在；用户在用的 08:00–09:00 不算
        assertion("10:00:00", "200(Amphetamine)", "Summary", "PreventUserIdleSystemSleep", "02:00:00", "6"),
        assertion("11:00:00", "88(coreaudiod)", "Released", "PreventUserIdleSystemSleep", "01:00:00", "7"),
    ].joined(separator: "\n")
    let l = SleepLedger.compute(SleepLogParser.parse(text), now: utcDate(2026, 10, 26, 12, 0, 0),
                                isAlive: { $0 != 999 }, isService: { $0 == "coreaudiod" })
    check(l.window.duration == 24 * 3600, "窗口是 24 小时")
    check(l.asleep.totalDuration == 3600, "睡眠从 Sleep 行算到下一条唤醒")
    check(l.active.totalDuration == 3600, "UserIsActive 算作在用")
    check(l.blocked.totalDuration == 3600 + 3600 + 1800 + 30 + 3 * 3600, "被阻止 = 断言 − 睡眠 − 在用")
    check(l.apps.map(\.id) == ["Amphetamine", "caffeinate", "ghost"], "app 按时长降序，不足 1 分钟的和系统服务不列")
    check(l.apps.map(\.seconds) == [3 * 3600, 2 * 3600, 1800], "每个 app 只算被阻止时段里的部分")
    check(l.services.map(\.id) == ["coreaudiod"] && l.servicesTotal == 3600, "系统服务单独统计")
}

if failures == 0 { print("全部通过") } else { print(String(failures) + " 项失败") }
exit(failures == 0 ? 0 : 1)
