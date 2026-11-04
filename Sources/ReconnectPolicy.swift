// ReconnectPolicy.swift —— 断线重连的退避规则（纯函数，不碰蓝牙；Mac 和 iPhone 共用同一份源文件）
//
// 不变式（三端一样）：配过对 + 蓝牙开着 + 没连上 ⇒ 总有东西在一直重试，只是间隔拉开、最长 5 分钟；
// 配过对时没有任何「永久停手」。只有「没配过、开着配对窗口」时，连续早断 5 次还是硬停（等重新打开窗口）。
// 退避只拉开「失败的连接尝试」之间的间隔：电脑这边扫描一直开着，一扫到手机（比如手机 App 刚重新打开）就马上连；
// 退避中扫到也是第一次马上连，之后同一个标识每 30 秒最多一次（DiscoveryConnectLimiter）。手机那边从不停广播。
//
// 「手机 App 刚打开要几秒内连上」（认得的、配过对的手机，Mac 端）：手机 App 没在跑时系统还替它留着蓝牙服务，
// 电脑照样连得上、订得上发件箱，只是没人回话。所以对认得的手机，「说不出身份」和「没有我们的服务」都只做短周期，
// 不做长拉黑（长拉黑 = App 在拉黑窗口里打开，要干等 30 s 甚至更久）：
//   * 说不出身份（NoIdentifyPolicy）：认得 + 配过对的手机，订阅上 8 s 还不表明身份（冷启动的 App ≤ 1 s 就回，
//     真机日志里正常重连的 ping 都在订阅后 0.2 s 内到）就断开，只静默 3 s → 5 s（封顶 5 s，不翻倍到更长），
//     到点就连、没人回再来一轮；这个周期里扫到手机仍连不上的最长空窗就是这几秒。认出身份清零。
//     不认得的外设（别人的手机 / 别的东西）照旧：30 s → … → 5 min 翻倍，不会拿它们的 GATT 打转。
//   * 没有我们的服务（认得的手机，App 在启动中或还没开）：这个标识 3 s → 6 s → 12 s → 24 s → … → 5 min，
//     第一次很快重试（App 刚重新发布服务，几秒内就好），一直没有才慢下来；退避中扫到手机连一次的间隔随之 3/6/12 s，
//     最长 15 s（DiscoveryConnectLimiter 的 interval 参数）。手机重新发布服务（didModifyServices）时这个标识的退避清零。
//
//   * ReconnectBackoff：第 k 次退避等 base·2^k，封顶 cap
//   * EarlyDropPolicy：连上了却在订阅好之前就断（早断）。没配过：第 5 次硬停；配过：从第 5 次起退避
//     30 s → 60 s → … → 5 min（Mac / Windows 一样）
//   * TimedIgnoreList：窗口关着时连上了却说不出自己是谁的外设，暂时不理（默认 30 s → … → 5 min；
//     认得的手机用 NoIdentifyPolicy 的短档 3 s → 5 s），到点自动放出来
//   * KnownPeripherals：Mac 记得的外设标识 → 是哪台手机（phoneID），每台手机只留最近 2 个
//
// 自测：Sources/PairingSelfTest.swift 的「重连退避」那一节（verify.sh 跑）。

import Foundation

/// 翻倍退避：base·2^step，封顶 cap
struct ReconnectBackoff: Equatable {
    let base: TimeInterval
    let cap: TimeInterval
    /// 连续退避了几次（下一次的 step）
    private(set) var step = 0
    /// 退避到什么时候；nil = 不在退避里
    private(set) var until: Date?

    init(base: TimeInterval, cap: TimeInterval) {
        self.base = base
        self.cap = cap
    }

    static func delay(step: Int, base: TimeInterval, cap: TimeInterval) -> TimeInterval {
        guard step > 0 else { return min(base, cap) }
        // 2^step 很快就超过 cap：step 大了直接取 cap，免得溢出
        if step >= 30 { return cap }
        return min(base * pow(2, Double(step)), cap)
    }

    /// 又失败了一次：返回这次要等多久
    @discardableResult
    mutating func fail(at now: Date) -> TimeInterval {
        let d = Self.delay(step: step, base: base, cap: cap)
        step += 1
        until = now.addingTimeInterval(d)
        return d
    }

    mutating func reset() {
        step = 0
        until = nil
    }

    /// 现在还在等
    func holding(at now: Date) -> Bool {
        guard let until else { return false }
        return now < until
    }

    func remaining(at now: Date) -> TimeInterval {
        guard let until else { return 0 }
        return max(0, until.timeIntervalSince(now))
    }
}

/// 连上了却在订阅好之前就断（早断）
struct EarlyDropPolicy: Equatable {
    static let maxEarlyDrops = 5
    /// 配过对时从第 maxEarlyDrops 次起的退避
    static let backoffBase: TimeInterval = 30
    static let backoffCap: TimeInterval = reconnectBackoffCap

    enum Outcome: Equatable {
        /// 还没到次数，照常重连
        case keepGoing
        /// 配过对：先等这么久再重连（不是停手）
        case backoff(TimeInterval)
        /// 没配过（配对窗口模式）：硬停，等重新打开窗口
        case stop
    }

    private(set) var drops = 0
    private(set) var holdUntil: Date?

    mutating func noteDrop(paired: Bool, at now: Date) -> Outcome {
        drops += 1
        guard drops >= Self.maxEarlyDrops else { return .keepGoing }
        guard paired else { return .stop }
        let d = ReconnectBackoff.delay(step: drops - Self.maxEarlyDrops, base: Self.backoffBase, cap: Self.backoffCap)
        holdUntil = now.addingTimeInterval(d)
        return .backoff(d)
    }

    /// 订阅成功 / 唤醒 / 蓝牙重新打开 / 重新打开配对窗口
    mutating func reset() {
        drops = 0
        holdUntil = nil
    }

    func holding(at now: Date) -> Bool {
        guard let holdUntil else { return false }
        return now < holdUntil
    }

    func remaining(at now: Date) -> TimeInterval {
        guard let holdUntil else { return 0 }
        return max(0, holdUntil.timeIntervalSince(now))
    }
}

/// 所有重连退避的上限（三端一样）
let reconnectBackoffCap: TimeInterval = 300

/// 暂时不理的外设：每次再被拉黑，时间翻倍（base → cap）；到点自动放出来。
/// permanent 只给「没配过、也不认得」的外设用（本次运行不再理），配过对 / 认得的永远是限时的。
struct TimedIgnoreList<Key: Hashable> {
    static var base: TimeInterval { 30 }
    static var cap: TimeInterval { reconnectBackoffCap }
    /// 这一份名单自己的起点 / 封顶（默认 30 s → 5 min；认得的手机用短档，见 NoIdentifyPolicy）
    let stepBase: TimeInterval
    let stepCap: TimeInterval

    private struct Entry {
        var until: Date?      // nil = 本次运行不再理
        var strikes: Int
    }
    private var entries: [Key: Entry] = [:]
    /// 放出来之后也记着拉黑过几次（下一次接着翻倍）；认出身份就清掉
    private var strikes: [Key: Int] = [:]

    init() {
        stepBase = Self.base
        stepCap = Self.cap
    }

    init(base: TimeInterval, cap: TimeInterval) {
        stepBase = base
        stepCap = cap
    }

    /// 拉黑一次：返回这次多久（nil = 本次运行不再理）
    @discardableResult
    mutating func ignore(_ key: Key, at now: Date, permanent: Bool = false) -> TimeInterval? {
        let n = strikes[key, default: 0]
        strikes[key] = n + 1
        if permanent {
            entries[key] = Entry(until: nil, strikes: n + 1)
            return nil
        }
        let d = ReconnectBackoff.delay(step: n, base: stepBase, cap: stepCap)
        entries[key] = Entry(until: now.addingTimeInterval(d), strikes: n + 1)
        return d
    }

    func contains(_ key: Key, at now: Date) -> Bool {
        guard let e = entries[key] else { return false }
        guard let until = e.until else { return true }
        return now < until
    }

    /// 到点的放出来：返回放出来的那些
    mutating func expire(at now: Date) -> [Key] {
        let done = entries.filter { if let u = $0.value.until { return now >= u } else { return false } }.map(\.key)
        for k in done { entries[k] = nil }
        return done
    }

    /// 认出身份了：拉黑记录全清
    mutating func forgive(_ key: Key) {
        entries[key] = nil
        strikes[key] = nil
    }

    mutating func removeAll() {
        entries.removeAll()
        strikes.removeAll()
    }

    var isEmpty: Bool { entries.isEmpty }
}

/// Mac 记得的外设标识（不是秘密）。存成字符串数组，最近的在后面：
///   "<外设标识>"              老版本记的，不知道是哪台手机
///   "<外设标识> <phoneID>"    认过身份的
/// 同一台手机只留最近 keepPerPhone 个（iPhone 会用好几个标识出现，轮换的旧标识不再去连）。
enum KnownPeripherals {
    static let keepPerPhone = 2

    struct Entry: Equatable {
        let identifier: UUID
        let phoneID: UUID?
    }

    static func parse(_ raw: [String]) -> [Entry] {
        raw.compactMap { line in
            let parts = line.split(separator: " ")
            guard let first = parts.first, let id = UUID(uuidString: String(first)) else { return nil }
            let phone = parts.count > 1 ? UUID(uuidString: String(parts[1])) : nil
            return Entry(identifier: id, phoneID: phone)
        }
    }

    static func encode(_ entries: [Entry]) -> [String] {
        entries.map { e in
            e.phoneID.map { "\(e.identifier.uuidString) \($0.uuidString)" } ?? e.identifier.uuidString
        }
    }

    /// 这个标识刚认出是 phoneID：挪到最后，同一台手机超过 keepPerPhone 个就丢最老的
    static func remember(_ entries: [Entry], identifier: UUID, phoneID: UUID) -> [Entry] {
        var list = entries.filter { $0.identifier != identifier }
        list.append(Entry(identifier: identifier, phoneID: phoneID))
        var mine = list.filter { $0.phoneID == phoneID }
        while mine.count > keepPerPhone {
            let oldest = mine.removeFirst()
            list.removeAll { $0.identifier == oldest.identifier }
        }
        // 老版本记的（不知道是哪台手机）也只留最近 keepPerPhone 个
        var legacy = list.filter { $0.phoneID == nil }
        while legacy.count > keepPerPhone {
            let oldest = legacy.removeFirst()
            list.removeAll { $0.identifier == oldest.identifier }
        }
        return list
    }

    /// 这台手机撤销了：它的标识都不记了
    static func forget(_ entries: [Entry], phoneID: UUID) -> [Entry] {
        entries.filter { $0.phoneID != phoneID }
    }

    static func phoneID(of identifier: UUID, in entries: [Entry]) -> UUID? {
        entries.first { $0.identifier == identifier }?.phoneID
    }
}

/// 扫描允许重复上报：同一台手机每个广播包都会报一次。退避中（早断退避 / 这个标识的退避）扫到它：
/// 第一次马上连（手机 App 刚打开就是这样），之后同一个标识每 interval 最多连一次，免得「连上就断、断了马上又连」打转。
/// 只有订阅 / 认出身份成功才清掉（新的退避开始不清，不然每次早断都能马上再连）。
/// interval 默认 30 s；认得的手机「没有服务」的退避用更短的（3/6/12 s，最长 15 s），见 NoIdentifyPolicy.missingServiceDiscoverInterval。
struct DiscoveryConnectLimiter<Key: Hashable> {
    static var interval: TimeInterval { 30 }
    private var lastConnect: [Key: Date] = [:]

    init() {}

    /// 扫到了 key：现在能不能连。holding = 正在退避里
    mutating func allow(_ key: Key, holding: Bool, interval: TimeInterval? = nil, at now: Date) -> Bool {
        guard holding else { return true }
        if let last = lastConnect[key], now.timeIntervalSince(last) < (interval ?? Self.interval) { return false }
        lastConnect[key] = now
        return true
    }

    /// 刚刚连过 / 试过一次（比如刚收到「没有服务」）：从现在起算一个间隔，退避中扫到也要等够再连
    mutating func noteAttempt(_ key: Key, at now: Date) { lastConnect[key] = now }

    func remaining(_ key: Key, interval: TimeInterval? = nil, at now: Date) -> TimeInterval {
        guard let last = lastConnect[key] else { return 0 }
        return max(0, (interval ?? Self.interval) - now.timeIntervalSince(last))
    }

    /// 订阅 / 认出身份成功
    mutating func succeeded(_ key: Key) { lastConnect[key] = nil }
    mutating func removeAll() { lastConnect.removeAll() }
}

/// 认得的、配过对的手机：订阅上了却不表明身份 / 连上了却没有我们的服务（手机 App 没在跑或刚在启动）。
/// 目标：App 一打开几秒内就连上并认出身份，同时 App 真的没开时不去打转蓝牙。
/// 不认得的外设不走这里（照旧 TimedIgnoreList 默认的 30 s → 5 min 翻倍拉黑）。
enum NoIdentifyPolicy {
    /// 认得 + 配过对：订阅上这么久还没表明身份就断开
    static let knownIdentifyTimeout: TimeInterval = 8
    /// 其他（不认得的外设 / 没配过）：订阅上这么久还没表明身份就断开
    static let otherIdentifyTimeout: TimeInterval = 30
    /// 认得的手机断开之后的静默：3 s → 5 s，封顶 5 s（不再往上翻倍）
    static let knownHoldBase: TimeInterval = 3
    static let knownHoldCap: TimeInterval = 5
    /// 认得的手机「没有我们的服务」的退避：3 s 起翻倍，封顶 5 分钟（reconnectBackoffCap）
    static let missingServiceBase: TimeInterval = 3
    static let missingServiceCap: TimeInterval = reconnectBackoffCap
    /// 「没有服务」退避中，扫到手机最多隔这么久连一次：跟着退避走（3/6/12 s），封顶 15 s
    static let missingServiceDiscoverCap: TimeInterval = 15

    /// 说不出身份时怎么处理这个外设
    enum Kind: Equatable {
        /// 认得 + 配过对：短周期（knownIdentifyTimeout + 短静默），不翻倍成长拉黑
        case knownPaired
        /// 不认得的外设，或没配过但认得：30 s → … → 5 min 翻倍拉黑
        case timed
        /// 没配过也不认得：本次运行不再理
        case permanent
    }

    static func kind(paired: Bool, known: Bool) -> Kind {
        if paired && known { return .knownPaired }
        return (!paired && !known) ? .permanent : .timed
    }

    static func identifyTimeout(_ kind: Kind) -> TimeInterval {
        kind == .knownPaired ? knownIdentifyTimeout : otherIdentifyTimeout
    }

    /// 认得的手机用的静默名单
    static func makeKnownHoldList<Key: Hashable>() -> TimedIgnoreList<Key> {
        TimedIgnoreList<Key>(base: knownHoldBase, cap: knownHoldCap)
    }

    /// 「没有服务」退避中，扫到手机的连接间隔
    static func missingServiceDiscoverInterval(backoff: TimeInterval) -> TimeInterval {
        min(backoff, missingServiceDiscoverCap)
    }
}

/// 挂起的 connect() 系统不会让它超时：卡住了（蓝牙栈的毛病）就一直卡着，而 pendKnown / 健康检查 / 扫描都跳过已经在连的标识。
/// 挂了太久，或者扫到它正在广播、却还卡在「在连」：取消、重新连。
enum PendingConnectPolicy {
    /// 挂起这么久还没连上：重挂一次
    static let maxPending: TimeInterval = 60
    /// 扫到它在广播（就在附近、App 在跑），却还在连超过这么久：重挂
    static let maxPendingWhileAdvertising: TimeInterval = 10

    static func isStale(pendingSince: Date, discovered: Bool, at now: Date) -> Bool {
        let age = now.timeIntervalSince(pendingSince)
        return age > (discovered ? maxPendingWhileAdvertising : maxPending)
    }
}

/// 日志去重：同一个 key 的内容没变就每 every 秒最多写一次；变了马上写
struct LogThrottle {
    private var last: [String: (value: String, at: Date)] = [:]

    init() {}

    mutating func shouldLog(_ key: String, value: String, at now: Date, every: TimeInterval) -> Bool {
        if let prev = last[key], prev.value == value, now.timeIntervalSince(prev.at) < every { return false }
        last[key] = (value, now)
        return true
    }

    /// 只在内容变了时写（不按时间补写）
    mutating func changed(_ key: String, value: String) -> Bool {
        if let prev = last[key], prev.value == value { return false }
        last[key] = (value, Date())
        return true
    }
}

/// 日志文件太大就轮转：超过 maxBytes 改名成 .1（覆盖旧的 .1），重新开一个
enum LogRotation {
    static let maxBytes: UInt64 = 2 * 1024 * 1024

    static func needsRotation(size: UInt64) -> Bool { size >= maxBytes }
}
