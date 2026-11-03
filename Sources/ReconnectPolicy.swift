// ReconnectPolicy.swift —— 断线重连的退避规则（纯函数，不碰蓝牙；Mac 和 iPhone 共用同一份源文件）
//
// 不变式（三端一样）：配过对 + 蓝牙开着 + 没连上 ⇒ 总有东西在一直重试，只是间隔翻倍、最长 5 分钟；
// 配过对时没有任何「永久停手」。只有「没配过、开着配对窗口」时，连续早断 5 次还是硬停（等重新打开窗口）。
// 退避只拉开「失败的连接尝试」之间的间隔：电脑这边扫描一直开着，一扫到手机（比如手机 App 刚重新打开）就马上连、退避清零。
//
//   * ReconnectBackoff：第 k 次退避等 base·2^k，封顶 cap
//   * EarlyDropPolicy：连上了却在订阅好之前就断（早断）。没配过：第 5 次硬停；配过：从第 5 次起退避
//     30 s → 60 s → … → 5 min（Mac / Windows 一样）
//   * TimedIgnoreList：窗口关着时连上了却说不出自己是谁的外设，暂时不理（30 s → … → 5 min），到点自动放出来
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

    private struct Entry {
        var until: Date?      // nil = 本次运行不再理
        var strikes: Int
    }
    private var entries: [Key: Entry] = [:]
    /// 放出来之后也记着拉黑过几次（下一次接着翻倍）；认出身份就清掉
    private var strikes: [Key: Int] = [:]

    init() {}

    /// 拉黑一次：返回这次多久（nil = 本次运行不再理）
    @discardableResult
    mutating func ignore(_ key: Key, at now: Date, permanent: Bool = false) -> TimeInterval? {
        let n = strikes[key, default: 0]
        strikes[key] = n + 1
        if permanent {
            entries[key] = Entry(until: nil, strikes: n + 1)
            return nil
        }
        let d = ReconnectBackoff.delay(step: n, base: Self.base, cap: Self.cap)
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
