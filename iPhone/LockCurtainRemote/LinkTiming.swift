// LinkTiming.swift —— 冷启动到连上用了多久：一条一条的时间戳（距进程启动多少毫秒）
//
// 日志：Logger(subsystem: "LockCurtainRemote", category: "link")，每条形如
//     link-timing: poweredOn t+312 ms
// 最后一条汇总：
//     link-timing: cold start → ready 1480 ms (bluetooth)
// 没有任何密钥 / 标识 / 地址，只有事件名和毫秒数。每个事件每个进程只记第一次。
// 「进程启动」取系统记的进程开始时刻（sysctl），包含 main 之前的时间；取不到就用第一次被碰到的时刻。
// 排查信息页（DiagnosticsView）里显示最近一次的汇总（跨启动存在 UserDefaults lc.lastColdStartSummary）。

import Foundation
import OSLog

/// 纯数据：起点 + 已经记过的事件。测试直接用它
struct LinkTimingLog {
    enum Event: String, CaseIterable, Equatable {
        /// AppModel.init 第一行
        case appInit
        /// 第一次 activate()（开始找电脑）
        case activate
        /// CBPeripheralManager 第一次 poweredOn
        case poweredOn
        /// 服务加好（didAdd 成功）
        case serviceAdded
        /// 开始广播
        case advertisingStarted
        /// 电脑第一次订阅发件箱
        case firstSubscribe
        /// 蓝牙路：第一次签名 ping 被电脑签收 / 电脑任何一条验过签名的消息到了 = 已连上
        case linkReady
        /// 网络路：第一次连上
        case networkReady
        /// 主屏上「盖上幕布」第一次出现（= 能按）
        case coverButtonShown
    }

    var origin: Date
    private(set) var marks: [(event: Event, ms: Int)] = []
    /// 第一个「连上」走的是哪条路
    private(set) var readyVia: LinkPath?

    init(origin: Date) { self.origin = origin }

    static func milliseconds(from origin: Date, to now: Date) -> Int {
        max(0, Int((now.timeIntervalSince(origin) * 1000).rounded()))
    }

    func ms(of event: Event) -> Int? { marks.first { $0.event == event }?.ms }

    /// 记一次；已经记过这个事件返回 nil（不重复），否则返回毫秒数
    @discardableResult
    mutating func mark(_ event: Event, at now: Date) -> Int? {
        guard ms(of: event) == nil else { return nil }
        let ms = Self.milliseconds(from: origin, to: now)
        marks.append((event, ms))
        if event == .linkReady, readyVia == nil { readyVia = .bluetooth }
        if event == .networkReady, readyVia == nil { readyVia = .network }
        return ms
    }

    /// 汇总行：第一个「连上」（蓝牙或网络，谁先算谁）出现之后才有
    var summary: String? {
        guard let via = readyVia,
              let readyMs = via == .bluetooth ? ms(of: .linkReady) : ms(of: .networkReady) else { return nil }
        return "cold start → ready \(readyMs) ms (\(via == .bluetooth ? "bluetooth" : "network"))"
    }

    /// 带每一步的长版本（排查信息页用）
    var detail: String {
        let steps = marks.map { "\($0.event.rawValue) \($0.ms)" }.joined(separator: " · ")
        return [summary, steps].compactMap { $0 }.joined(separator: " | ")
    }
}

/// 进程里唯一的一份。可以从任何线程调（加锁）
final class LinkTiming: @unchecked Sendable {
    static let shared = LinkTiming()
    static let summaryKey = "lc.lastColdStartSummary"
    private static let log = Logger(subsystem: "LockCurtainRemote", category: "link")

    private let lock = NSLock()
    private var timing: LinkTimingLog

    init(origin: Date = LinkTiming.processStart() ?? Date()) {
        timing = LinkTimingLog(origin: origin)
    }

    static func mark(_ event: LinkTimingLog.Event) { shared.mark(event) }

    func mark(_ event: LinkTimingLog.Event, at now: Date = Date()) {
        lock.lock()
        let hadSummary = timing.summary != nil
        let ms = timing.mark(event, at: now)
        let summary = timing.summary
        let detail = timing.detail
        lock.unlock()
        guard let ms else { return }
        Self.log.info("link-timing: \(event.rawValue, privacy: .public) t+\(ms) ms")
        if let summary, !hadSummary {
            Self.log.info("link-timing: \(summary, privacy: .public)")
        }
        // 汇总出来以后，之后每多一步（比如按钮出现）都刷新存的那一行
        if summary != nil {
            UserDefaults.standard.set(detail, forKey: Self.summaryKey)
        }
    }

    /// 这一次启动的情况；还没连上就是 nil
    var currentDetail: String? {
        lock.lock(); defer { lock.unlock() }
        return timing.summary == nil ? nil : timing.detail
    }

    /// 排查信息页要显示的：这一次的，没有就用上一次存的
    var displayText: String? {
        currentDetail ?? UserDefaults.standard.string(forKey: Self.summaryKey)
    }

    /// 系统记的进程开始时刻（包含 main 之前）
    static func processStart() -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let t = info.kp_proc.p_un.__p_starttime
        guard t.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(t.tv_sec) + TimeInterval(t.tv_usec) / 1_000_000)
    }
}
