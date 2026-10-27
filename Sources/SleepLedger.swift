// SleepLedger.swift —— 过去 24 小时：睡了多久，醒着的时候被哪些 app 拦着没睡
//
// 数据来自 `pmset -g log`（SleepLog.swift）。实测 2026-10-26（macOS 27.2，最近 25 小时的日志）：
//   - 九成以上的断言只有 Released 一行、没有 Created，区间只能按「释放时刻 − 行里的持续时长」倒推
//   - Summary 行定期列出还开着的断言，时长是到这一行为止已经开了多久
//   - Sleep 行的「N secs」就是这次睡了多久，和下一条 DarkWake / Wake 的时刻对得上
//
// 被阻止 = 有阻止睡眠的断言 − 睡着 − 用户在用（UserIsActive）。用户在用的时候系统本来就不会睡，算不上被谁拦着。
// 系统服务（coreaudiod、powerd 等）也会拦着不睡，计入被阻止的总时长，但不逐个列出。

import Foundation

struct SleepLedger: Sendable {
    struct Culprit: Identifiable, Sendable {
        /// pmset 日志里的进程名
        let id: String
        /// 它在「被阻止」时段里占的时长
        let seconds: Double
    }

    var window: Interval
    var asleep: IntervalSet
    var active: IntervalSet
    var blocked: IntervalSet
    /// 系统服务以外的，按时长降序，不足 1 分钟的不列
    var apps: [Culprit]
    /// 系统服务，排序和门槛同上
    var services: [Culprit]
    /// 系统服务合起来在「被阻止」时段里占的时长（并集，不重复计）
    var servicesTotal: Double
}

extension SleepLedger {
    /// - isAlive: 断言到最后都没关的，进程还活着就算开到现在，否则算到最后一次在日志里出现
    /// - isService: 进程名是不是系统服务
    static func compute(_ log: SleepLog, now: Date, hours: Double = 24,
                        isAlive: (pid_t) -> Bool, isService: (String) -> Bool) -> SleepLedger {
        let end = now.timeIntervalSince1970
        let window = Interval(end - hours * 3600, end)

        var blocking: [String: [Interval]] = [:]
        var userActive: [Interval] = []
        for (entry, iv) in intervals(log.assertions, now: end, isAlive: isAlive) {
            if entry.type == "UserIsActive" { userActive.append(iv) }
            else if SleepBlockKind.of(entry.type) != nil { blocking[entry.processName, default: []].append(iv) }
        }

        var sleeps: [Interval] = []
        let events = log.events
        for (i, e) in events.enumerated() where e.kind == .sleep {
            let start = e.timestamp.timeIntervalSince1970
            sleeps.append(Interval(start, i + 1 < events.count ? events[i + 1].timestamp.timeIntervalSince1970 : start + e.duration))
        }

        let asleep = IntervalSet(sleeps).clamped(to: window)
        let active = IntervalSet(userActive).clamped(to: window).subtracting(asleep)
        let perProcess = blocking.mapValues { IntervalSet($0).clamped(to: window) }
        let anyBlocking = IntervalSet(perProcess.values.flatMap(\.intervals))
        let blocked = anyBlocking.subtracting(asleep).subtracting(active)

        var apps: [Culprit] = [], services: [Culprit] = []
        var serviceTime: [Interval] = []
        for (name, set) in perProcess {
            let service = isService(name)
            if service { serviceTime += set.intervals }
            let c = Culprit(id: name, seconds: set.intersectionDuration(with: blocked))
            guard c.seconds >= 60 else { continue }
            if service { services.append(c) } else { apps.append(c) }
        }
        // 时长一样的按名字排，免得每次刷新顺序都变
        let longestFirst = { (a: Culprit, b: Culprit) in (a.seconds, b.id) > (b.seconds, a.id) }
        return SleepLedger(window: window, asleep: asleep, active: active, blocked: blocked,
                           apps: apps.sorted(by: longestFirst), services: services.sorted(by: longestFirst),
                           servicesTotal: IntervalSet(serviceTime).intersectionDuration(with: blocked))
    }

    /// 按断言串成区间：Created / TurnedOn 开，Released 等关；没看到开的，用关的那一行的持续时长倒推
    static func intervals(_ entries: [AssertionLogEntry], now: Double,
                          isAlive: (pid_t) -> Bool) -> [(AssertionLogEntry, Interval)] {
        var open: [String: (entry: AssertionLogEntry, start: Double, lastSeen: Double)] = [:]
        var out: [(AssertionLogEntry, Interval)] = []
        for e in entries {
            // id 重启后会复用，带上 pid 少撞一些
            let key = "\(e.pid)|\(e.assertionID)"
            let t = e.timestamp.timeIntervalSince1970
            if e.action.opensInterval {
                if open[key] == nil { open[key] = (e, t, t) }
            } else if e.action.closesInterval {
                out.append((e, Interval(open.removeValue(forKey: key)?.start ?? t - e.reportedDuration, t)))
            } else if open[key] != nil {
                open[key]?.lastSeen = t
            } else {
                open[key] = (e, t - e.reportedDuration, t)       // Summary：开得比日志窗口还早
            }
        }
        for o in open.values {
            out.append((o.entry, Interval(o.start, isAlive(o.entry.pid) ? now : o.lastSeen)))
        }
        return out
    }
}

/// 面板打开时读一次；pmset 要跑 3～4 秒，所以放到后台，5 分钟内不重读
@MainActor
final class SleepLedgerStore: ObservableObject {
    @Published private(set) var ledger: SleepLedger?
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    private var loadedAt: Date?

    func refreshIfStale() {
        guard !isLoading, loadedAt.map({ Date().timeIntervalSince($0) > 300 }) ?? true else { return }
        isLoading = true
        Task.detached(priority: .utility) {
            let result = Result { () throws -> SleepLedger in
                let now = Date()
                let log = SleepLogParser.parse(try SleepLogReader.readSystemLog(), since: now.addingTimeInterval(-25 * 3600))
                let services = SleepBlockers.runningServiceNames()
                return SleepLedger.compute(log, now: now, isAlive: { kill($0, 0) == 0 || errno == EPERM },
                                           isService: services.contains)
            }
            await self.finish(result)
        }
    }

    private func finish(_ result: Result<SleepLedger, Error>) {
        isLoading = false
        switch result {
        case .success(let l): ledger = l; error = nil; loadedAt = Date()
        case .failure(let e): error = "\(e)"
        }
    }
}
