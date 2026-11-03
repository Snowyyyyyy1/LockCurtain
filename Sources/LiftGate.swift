// LiftGate.swift —— 「手机撤下幕布」的判断（纯逻辑，不碰蓝牙、不碰钥匙串，自测直接在进程里跑）
//
// 一台手机一个 LiftGate。签名和计数在 PairingAuthority.handleAnswer 里验过之后，才交给这里判断：
//   1. 幕布现在盖着（盖上的时刻 T）；
//   2. 回答绑的 nonce 是 Mac 在 T 之后发的、最近 challengeLifetime 秒内的、没用过的（每个 nonce 只用一次）；
//   3. 「走近撤下」开着（手机回 off 就不撤）；
//   4. 边沿：T 之后先见过这台手机回「锁着」，之后的「解锁着」才能撤 —— 在桌前按「盖上幕布」、
//      手机不锁、人不动，幕布不会马上被撤下（「现在撤下」不看这一条，手机那边已经过了面容 / 密码）；
//   5. 近：Mac 自己量的 RSSI，最近 rssiSamples 次的中位数 >= nearMedianDBm。
// 时间都从外面传进来，测试可以随便拨。

import Foundation

struct LiftGate {
    /// 近不近的门槛（dBm）：最近 3 次 RSSI 的中位数不低于它才算近。
    /// 实测桌前多在 -56…-66，偶尔 -39…-77；走路实测之前先取保守值 -65，宁可少撤。
    /// 只在这里用、只写进日志，界面上不出现这个数。
    static let nearMedianDBm = -65
    /// 取几次 RSSI 算中位数（Mac 每 2 秒读一次）
    static let rssiSamples = 3
    /// 超过这么久的 RSSI 不算（3 次 × 2 秒，留余量）
    static let rssiMaxAge: TimeInterval = 7
    /// Mac 发出的 nonce 多久之内的回答才算新鲜
    static let challengeLifetime: TimeInterval = 5
    /// 同时记着几个没回答的 nonce（每 2 秒一个，5 秒内最多 3 个）
    static let maxOpenChallenges = 4

    enum Refusal: Equatable {
        case notCovered
        /// 不是 Mac 发过的 nonce，或者已经用过
        case unknownNonce
        /// nonce 太旧（超过 challengeLifetime），或者是盖上之前发的
        case staleNonce
        case toggleOff
        case phoneLocked
        /// 盖上之后还没见过这台手机锁着
        case edgeNotArmed
        case notNear(median: Int)
        case noRSSI(samples: Int)
    }

    enum Decision: Equatable {
        case lift
        case refuse(Refusal)
    }

    private struct Challenge {
        let nonce: Data
        let issuedAt: Date
    }

    private(set) var coveredAt: Date?
    /// 盖上之后见过这台手机锁着
    private(set) var edgeArmed = false
    private var challenges: [Challenge] = []
    private var rssi: [(value: Int, at: Date)] = []

    // MARK: - 幕布

    mutating func covered(at time: Date) {
        coveredAt = time
        edgeArmed = false
        challenges.removeAll()      // 盖上之前发的 nonce 一律作废
    }

    mutating func uncovered() {
        coveredAt = nil
        edgeArmed = false
        challenges.removeAll()
    }

    // MARK: - 问询

    /// Mac 发出一次问询。幕布没盖着就不记（也不该发）。
    mutating func issue(_ nonce: Data, at time: Date) {
        guard coveredAt != nil else { return }
        challenges.removeAll { time.timeIntervalSince($0.issuedAt) > Self.challengeLifetime }
        challenges.append(Challenge(nonce: nonce, issuedAt: time))
        if challenges.count > Self.maxOpenChallenges { challenges.removeFirst(challenges.count - Self.maxOpenChallenges) }
    }

    /// 用掉一个 nonce：不认识 → unknownNonce；太旧或早于盖上 → staleNonce。不管哪种，这个 nonce 都作废。
    private mutating func consume(_ nonce: Data, at time: Date) -> Refusal? {
        guard let index = challenges.firstIndex(where: { $0.nonce == nonce }) else { return .unknownNonce }
        let challenge = challenges.remove(at: index)
        let age = time.timeIntervalSince(challenge.issuedAt)
        guard age >= 0, age <= Self.challengeLifetime,
              let coveredAt, challenge.issuedAt >= coveredAt else { return .staleNonce }
        return nil
    }

    // MARK: - RSSI

    /// 127 是 CoreBluetooth 的「读不到」
    mutating func recordRSSI(_ value: Int, at time: Date) {
        guard value < 0 else { return }
        rssi.append((value, time))
        if rssi.count > Self.rssiSamples { rssi.removeFirst(rssi.count - Self.rssiSamples) }
    }

    mutating func resetRSSI() { rssi.removeAll() }

    /// 最近 rssiSamples 次（都不旧）的中位数；不够数就是 nil
    func rssiMedian(at time: Date) -> (median: Int?, samples: [Int]) {
        let fresh = rssi.filter { time.timeIntervalSince($0.at) <= Self.rssiMaxAge }.map(\.value)
        guard fresh.count >= Self.rssiSamples else { return (nil, fresh) }
        let sorted = fresh.suffix(Self.rssiSamples).sorted()
        return (sorted[sorted.count / 2], fresh)
    }

    private func nearRefusal(at time: Date) -> Refusal? {
        let (median, samples) = rssiMedian(at: time)
        guard let median else { return .noRSSI(samples: samples.count) }
        return median >= Self.nearMedianDBm ? nil : .notNear(median: median)
    }

    /// 「现在撤下」没撤时回手机的结果：太远 / 本来就没盖着 / 别的原因
    static func resultStatus(for refusal: Refusal) -> PairingCrypto.LiftStatus {
        switch refusal {
        case .notNear, .noRSSI: return .tooFar
        case .notCovered: return .notCovered
        case .unknownNonce, .staleNonce, .toggleOff, .phoneLocked, .edgeNotArmed: return .refused
        }
    }

    // MARK: - 判断

    /// 手机对问询的回答（签名、计数已经验过）
    mutating func presence(_ status: PairingCrypto.PresenceStatus, nonce: Data, at time: Date) -> Decision {
        guard coveredAt != nil else { return .refuse(.notCovered) }
        if let stale = consume(nonce, at: time) { return .refuse(stale) }
        switch status {
        case .off:
            return .refuse(.toggleOff)
        case .locked:
            edgeArmed = true
            return .refuse(.phoneLocked)
        case .unlocked:
            guard edgeArmed else { return .refuse(.edgeNotArmed) }
            if let far = nearRefusal(at: time) { return .refuse(far) }
            return .lift
        }
    }

    /// 「现在撤下」（手机那边已经过了面容 / 密码）：不看边沿，照样要新鲜、要近
    mutating func liftNow(nonce: Data, at time: Date) -> Decision {
        guard coveredAt != nil else { return .refuse(.notCovered) }
        if let stale = consume(nonce, at: time) { return .refuse(stale) }
        if let far = nearRefusal(at: time) { return .refuse(far) }
        return .lift
    }
}
