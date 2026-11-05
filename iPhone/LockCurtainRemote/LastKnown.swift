// LastKnown.swift —— 上一次的样子：打开 App 的第一帧就能说「上次连上是什么时候、幕布当时什么样」
//
// 只存两样（UserDefaults，不是秘密）：
//   * lc.lastConnectedAt —— 最后一次确认「连上」的时刻（断开那一刻也记一次，所以就是「上次连上」）
//   * lc.lastPhase / lc.lastPhaseAt —— 电脑最后一次签名报来的幕布状态（盖上 / 没盖上）和收到它的时刻；
//     手机自己猜的「正在盖上…」不记
// 它只用来回答「上次」，永远不当现在：没连上时界面把它淡着、标上「上次」，不说已连上，也不给任何要靠它决定的按钮。
// 写入有节流（连着的时候最多每 60 秒刷新一次时刻；幕布状态变了才立刻写）。撤销配对 / 换电脑 / 被电脑撤销时清掉。
// 这里全是纯规则（UserDefaults 可以注入），测试直接覆盖。

import Foundation

/// 上次的样子
struct LastKnownState: Equatable {
    enum Phase: String, Equatable {
        case open
        case closed
    }

    /// 最后一次连上（或断开）的时刻
    var connectedAt: Date
    /// 电脑最后一次报来的幕布状态；没收到过是 nil
    var phase: Phase?
    /// 那条状态是什么时候收到的
    var phaseAt: Date?
}

/// 读写 UserDefaults；无状态，节流靠比较已经存着的时刻
struct LastKnownStore: @unchecked Sendable {
    static let connectedAtKey = "lc.lastConnectedAt"
    static let phaseKey = "lc.lastPhase"
    static let phaseAtKey = "lc.lastPhaseAt"
    /// 连着的时候，时刻最多隔这么久才刷新一次
    static let refreshInterval: TimeInterval = 60

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    static let standard = LastKnownStore()

    func load() -> LastKnownState? {
        guard let seconds = defaults.object(forKey: Self.connectedAtKey) as? Double else { return nil }
        let phase = defaults.string(forKey: Self.phaseKey).flatMap(LastKnownState.Phase.init(rawValue:))
        let phaseAt = (defaults.object(forKey: Self.phaseAtKey) as? Double).map(Date.init(timeIntervalSince1970:))
        return LastKnownState(connectedAt: Date(timeIntervalSince1970: seconds),
                              phase: phase, phaseAt: phaseAt)
    }

    /// 刚连上：总是写
    func noteConnected(at now: Date) {
        defaults.set(now.timeIntervalSince1970, forKey: Self.connectedAtKey)
    }

    /// 连着的时候被调用（任何一次快照变化）：距上次写超过 refreshInterval 才写。返回写没写
    @discardableResult
    func touch(at now: Date) -> Bool {
        if let stored = defaults.object(forKey: Self.connectedAtKey) as? Double,
           now.timeIntervalSince1970 - stored < Self.refreshInterval, now.timeIntervalSince1970 >= stored {
            return false
        }
        noteConnected(at: now)
        return true
    }

    /// 刚断开：总是写（这一刻就是「上次连上」）
    func noteDisconnected(at now: Date) {
        noteConnected(at: now)
    }

    /// 电脑签名报来的幕布状态：变了立刻写；没变就按 refreshInterval 节流。返回写没写
    @discardableResult
    func notePhase(closed: Bool, at now: Date) -> Bool {
        let phase: LastKnownState.Phase = closed ? .closed : .open
        let stored = load()
        if stored?.phase == phase, let at = stored?.phaseAt,
           now.timeIntervalSince(at) >= 0, now.timeIntervalSince(at) < Self.refreshInterval {
            return false
        }
        defaults.set(phase.rawValue, forKey: Self.phaseKey)
        defaults.set(now.timeIntervalSince1970, forKey: Self.phaseAtKey)
        // 收到了电脑的状态，就一定是连着的
        touch(at: now)
        return true
    }

    func clear() {
        defaults.removeObject(forKey: Self.connectedAtKey)
        defaults.removeObject(forKey: Self.phaseKey)
        defaults.removeObject(forKey: Self.phaseAtKey)
    }
}

/// 「上次」怎么说：全是纯函数，界面只调这里
enum LastKnownPresentation {
    /// 时间说法（copy v15.9 §21.1）：刚刚 / N 分钟前 / N 小时前 / 昨天 / M 月 D 日 / 跨年 YYYY 年 M 月 D 日。不写「3 小时 12 分钟前」
    enum Bucket: Equatable {
        case justNow
        case minutes(Int)
        case hours(Int)
        case yesterday
        case date(month: Int, day: Int)
        /// 不是今年的
        case dateWithYear(year: Int, month: Int, day: Int)
    }

    static func bucket(from date: Date, now: Date, calendar: Calendar = .current) -> Bucket {
        let elapsed = now.timeIntervalSince(date)
        // 时钟往回拨了：当作刚刚，不说负数
        if elapsed < 60 { return .justNow }
        if elapsed < 3600 { return .minutes(Int(elapsed / 60)) }
        if elapsed < 24 * 3600 { return .hours(Int(elapsed / 3600)) }
        let startOfToday = calendar.startOfDay(for: now)
        if let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday), date >= startOfYesterday {
            return .yesterday
        }
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        if let year = parts.year, year != calendar.component(.year, from: now) {
            return .dateWithYear(year: year, month: parts.month ?? 1, day: parts.day ?? 1)
        }
        return .date(month: parts.month ?? 1, day: parts.day ?? 1)
    }

    static func relativeText(_ bucket: Bucket) -> String {
        switch bucket {
        case .justNow: "刚刚"
        case .minutes(let n): "\(n) 分钟前"
        case .hours(let n): "\(n) 小时前"
        case .yesterday: "昨天"
        case .date(let month, let day): "\(month) 月 \(day) 日"
        case .dateWithYear(let year, let month, let day): "\(year) 年 \(month) 月 \(day) 日"
        }
    }

    static func relativeText(from date: Date, now: Date, calendar: Calendar = .current) -> String {
        relativeText(bucket(from: date, now: now, calendar: calendar))
    }

    /// 「这台电脑」下面的小字（copy v15.9 §21.1）：上次连上：2 小时前
    static func connectedLine(_ lastKnown: LastKnownState, now: Date, calendar: Calendar = .current) -> String {
        "上次连上：" + relativeText(from: lastKnown.connectedAt, now: now, calendar: calendar)
    }

    /// 从来没连上过（§21.1）：只有这一句，不放时间，也不带「上次连上：」
    static let neverConnectedLine = "还没连上过"

    /// 什么情况下才把「上次」摆出来：配过对、不在演示、不是已连上（连上了就只说现在的）
    static func isShown(paired: Bool, demo: Bool, connection: CurtainConnection) -> Bool {
        guard paired, !demo else { return false }
        return connection == .notConnected || connection == .bluetoothOff
    }

    /// 「这台电脑」那一行：值（主句）+ 下面的小字（上次连上：…；从来没连上过是「还没连上过」）
    struct MacRow: Equatable {
        var value: String
        var showsSpinner: Bool
        /// 「上次连上：…」；nil = 不显示
        var lastConnectedLine: String?
    }

    /// 配过对、不在演示、没连上的那几段（UnlinkedMacState）。蓝牙关了不显示「上次」（那句话要说的是蓝牙关了）
    static func macRow(state: AppModel.UnlinkedMacState, lastKnown: LastKnownState?, now: Date,
                       calendar: Calendar = .current) -> MacRow {
        // 蓝牙关了不显示「上次」（那句话要说的是蓝牙关了）
        guard state != .bluetoothOff else {
            return MacRow(value: state.value, showsSpinner: state.showsSpinner, lastConnectedLine: nil)
        }
        guard let lastKnown else {
            return MacRow(value: state.value, showsSpinner: state.showsSpinner, lastConnectedLine: neverConnectedLine)
        }
        // 「等这台电脑来连…」+ 小转圈本身不是一屏内容：有「上次」可说时，主句是「没连上」，转圈照留（手机确实还在等）
        let value = state == .waiting ? AppModel.UnlinkedMacState.reconnecting.value : state.value
        return MacRow(value: value, showsSpinner: state.showsSpinner,
                      lastConnectedLine: connectedLine(lastKnown, now: now, calendar: calendar))
    }

    /// 「幕布」那一行
    struct CurtainRow: Equatable {
        var text: String
        /// true = 上次的样子（带「上次」，字用 .secondary，不用 opacity 调淡——浅色下对比度 <3:1）；false = 现在的（连着）或者没有可说的（「—」）
        var isLastKnown: Bool
        /// 念给 VoiceOver 的值：上次的写成「上次是已盖上」（label 仍是「幕布」），不能读成「已盖上」
        var voice: String
        /// 状态点亮不亮（Colo 定稿）：只有电脑真的报来了（连着、现在的值）才亮；上次的值、「—」都不亮
        var isLit: Bool
    }

    /// 连上后「上次」换成现在的值：交叉淡入淡出的时长（Colo 定稿 0.2 秒，不弹 toast / alert）
    static let liveCrossFadeDuration: TimeInterval = 0.2

    /// 状态点亮不亮的规则：只有连着（电脑真的报来了）才亮
    static func isStatusLit(connection: CurtainConnection) -> Bool {
        connection == .connected
    }

    /// 幕布那行的旧值前面加「上次：」（§21.2）：上次：已盖上 / 上次：已撤下
    static let lastKnownMarker = "上次"

    static func phaseText(_ phase: LastKnownState.Phase) -> String {
        phase == .closed ? "已盖上" : "已撤下"
    }

    /// - live: 连着时现成的值（curtainDisplayValue / curtainVoiceValue）；没连上时不用
    static func curtainRow(connection: CurtainConnection, paired: Bool, demo: Bool,
                           lastKnown: LastKnownState?, liveText: String, liveVoice: String,
                           disconnectedVoice: String, now: Date, calendar: Calendar = .current) -> CurtainRow {
        if connection == .connected {
            return CurtainRow(text: liveText, isLastKnown: false, voice: liveVoice,
                              isLit: isStatusLit(connection: connection))
        }
        guard isShown(paired: paired, demo: demo, connection: connection),
              let phase = lastKnown?.phase, lastKnown?.phaseAt != nil else {
            return CurtainRow(text: "—", isLastKnown: false, voice: disconnectedVoice,
                              isLit: isStatusLit(connection: connection))
        }
        let text = "\(lastKnownMarker)：\(phaseText(phase))"
        // VoiceOver 念「幕布，上次是已盖上」（label「幕布」+ value「上次是已盖上」），不读成「已盖上」（§21.2）
        let voice = "\(lastKnownMarker)是\(phaseText(phase))"
        return CurtainRow(text: text, isLastKnown: true, voice: voice,
                          isLit: isStatusLit(connection: connection))
    }
}

/// 「盖上幕布」那颗按钮：什么时候出现、按下去做什么。纯规则，AppModel 和主屏都照这里
enum CoverButtonPolicy {
    /// 没连上时按下去最多等多久
    static let queueTimeout: TimeInterval = 20

    enum State: Equatable {
        /// 不显示（没配对由「去配对」管；蓝牙关了又没有网络地址）
        case hidden
        /// 连着、可以按：发出去
        case cover
        /// 命令发出去了，等电脑签收：「正在盖上…」，点不动
        case covering
        /// 配过对、还没连上：照样显示、可以按。按下去是「等连上，连上了再发」
        case coverWhenLinked
        /// 按过了，在等连上：转圈 +「正在连上…」+ 能取消
        case waitingForLink
    }

    enum PressAction: Equatable {
        /// 现在就发
        case sendNow
        /// 记下来，等连上
        case queue
        /// 没反应（正在盖上 / 已经在等了 / 不显示）
        case ignore
    }

    static func state(paired: Bool, demo: Bool, connection: CurtainConnection, isPending: Bool,
                      isQueued: Bool, hasNetworkAddress: Bool) -> State {
        guard paired || demo else { return .hidden }
        switch connection {
        case .connected:
            return isPending ? .covering : .cover
        case .notConnected:
            guard !demo else { return .hidden }
            return isQueued ? .waitingForLink : .coverWhenLinked
        case .bluetoothOff:
            // 蓝牙关着只有网络还有指望
            guard !demo, hasNetworkAddress else { return .hidden }
            return isQueued ? .waitingForLink : .coverWhenLinked
        case .notPaired:
            return .hidden
        }
    }

    static func pressAction(_ state: State) -> PressAction {
        switch state {
        case .cover: .sendNow
        case .coverWhenLinked: .queue
        case .hidden, .covering, .waitingForLink: .ignore
        }
    }

    /// 等着的时候，连上了该不该发：只有「还在等」且连上了才发；撤下永远不排队，这里只管盖上
    static func shouldSendOnLinkUp(isQueued: Bool, connection: CurtainConnection) -> Bool {
        isQueued && connection == .connected
    }

    /// 等着的时候，什么时候该放弃：到了 queueTimeout
    static func hasExpired(queuedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(queuedAt) >= queueTimeout
    }
}
