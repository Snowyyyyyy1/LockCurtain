// PairingAuthority.swift —— Mac 端的配对 / 验签规则（和蓝牙无关，自测直接在进程里跑它）
//
//   * 配对码：窗口打开时给一个码；一个窗口最多错 5 次，第 5 次错完这个码作废，
//     refresh（「换一个码」）换不出新的。PhonePairing 在作废之后按「换一个码」时走 openWindow，
//     等于关掉窗口重新打开（新码、重新给 5 次）。码只用一次：握手过了就作废。
//   * 握手是 CPace（见 PairingCrypto）：Mac 回 Yb/Tb 的那一刻就把这一轮记成一次错码，
//     只有手机的确认标签 Ta 验过才算成。Ta 不对、手机放弃、半路不来都算错，这一轮作废。
//     同一时间只有一轮在进行；sid 用过就不再收；换码 / 关窗口时进行中的那一轮也作废。
//   * 握手过了的手机先记在内存里（pending），等它用新密钥签的第一条命令验过，
//     才写进钥匙串、算真的配上 —— 这样 Mac 说「配上了」时，两边一定算出了同一把钥匙。
//   * 命令：签名对、手机认识、计数比上次大，才收；收之前先把新计数写进钥匙串。
//
// 日志只写步骤和结果，不写码、不写钥匙。

import CryptoKit
import Foundation
import Security

struct PairingRecord: Equatable {
    var key: SymmetricKey
    var lastCounter: UInt64

    /// 钥匙串里存的样子：32 字节钥匙 + 8 字节大端计数
    func encoded() -> Data {
        key.withUnsafeBytes { Data($0) } + PairingCrypto.bigEndian(lastCounter)
    }

    init(key: SymmetricKey, lastCounter: UInt64) {
        self.key = key
        self.lastCounter = lastCounter
    }

    init?(decoding data: Data) {
        let b = [UInt8](data)
        guard b.count == 40 else { return nil }
        key = SymmetricKey(data: Data(b[0..<32]))
        lastCounter = PairingCrypto.uint64(b[32..<40])
    }

    static func == (a: PairingRecord, b: PairingRecord) -> Bool {
        a.key == b.key && a.lastCounter == b.lastCounter
    }
}

protocol PairingRecordStore: AnyObject {
    func load(_ phoneID: UUID) -> PairingRecord?
    @discardableResult func save(_ record: PairingRecord, for phoneID: UUID) -> Bool
    func delete(_ phoneID: UUID)
    func allPhoneIDs() -> [UUID]
}

/// 自测用
final class MemoryPairingStore: PairingRecordStore {
    private var records: [UUID: PairingRecord] = [:]
    func load(_ phoneID: UUID) -> PairingRecord? { records[phoneID] }
    func save(_ record: PairingRecord, for phoneID: UUID) -> Bool { records[phoneID] = record; return true }
    func delete(_ phoneID: UUID) { records[phoneID] = nil }
    func allPhoneIDs() -> [UUID] { Array(records.keys) }
}

/// 钥匙串：通用密码，service = "<bundle id>.pairing"，account = phoneID
final class KeychainPairingStore: PairingRecordStore {
    let service: String

    init(service: String = (Bundle.main.bundleIdentifier ?? "dev.local.lockcurtain") + ".pairing") {
        self.service = service
    }

    private func query(_ phoneID: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: phoneID.uuidString]
    }

    func load(_ phoneID: UUID) -> PairingRecord? {
        var q = query(phoneID)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return PairingRecord(decoding: data)
    }

    func save(_ record: PairingRecord, for phoneID: UUID) -> Bool {
        let data = record.encoded()
        let status = SecItemUpdate(query(phoneID) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var add = query(phoneID)
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "LockCurtain 手机配对"
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    func delete(_ phoneID: UUID) {
        SecItemDelete(query(phoneID) as CFDictionary)
    }

    func allPhoneIDs() -> [UUID] {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecReturnAttributes as String: true,
                                kSecMatchLimit as String: kSecMatchLimitAll]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let items = out as? [[String: Any]] else { return [] }
        return items.compactMap { ($0[kSecAttrAccount as String] as? String).flatMap(UUID.init(uuidString:)) }
    }
}

final class PairingAuthority {
    let store: PairingRecordStore
    private let log: (String) -> Void

    /// 现在有效的码；空 = 没有码可配
    private(set) var code = ""
    private(set) var attemptsLeft = PairingCrypto.maxCodeAttempts
    /// 这个窗口里错满 5 次了：码作废，重开窗口才有新码
    private(set) var isLocked = false
    /// 握手过了、还没用新钥匙签过命令的手机
    private var pending: [UUID: SymmetricKey] = [:]
    /// 回过 Yb/Tb、还在等 Ta 的那一轮
    private var inFlight: PairingCrypto.MacSession?
    /// 收过的 sid（本次运行内），同一个 sid 不收第二次
    private var usedSessions: Set<Data> = []

    init(store: PairingRecordStore, log: @escaping (String) -> Void) {
        self.store = store
        self.log = log
    }

    var pairedPhoneIDs: [UUID] { store.allPhoneIDs() }
    var isPaired: Bool { !pairedPhoneIDs.isEmpty }

    // MARK: - 码

    /// 打开配对窗口：新码、错码次数清零
    func openWindow(code: String) {
        self.code = code
        attemptsLeft = PairingCrypto.maxCodeAttempts
        isLocked = false
        inFlight = nil
    }

    /// 「换一个码」：错码次数不清零；已经作废的窗口换不出新码
    @discardableResult
    func refresh(code: String) -> Bool {
        guard !isLocked else { return false }
        if inFlight != nil { log("code refreshed: run in progress burned") }
        inFlight = nil
        lockIfExhausted()
        guard !isLocked else { return false }
        self.code = code
        return true
    }

    func closeWindow() {
        code = ""
        pending = [:]
        inFlight = nil
    }

    // MARK: - 握手

    enum PairOutcome: Equatable {
        /// 回了 Yb/Tb（这一轮已经记成一次错码），等手机的 Ta
        case responded(reply: Data)
        /// Ta 验过：reply（签名的 PairAccepted）发回手机；phoneID 是谁
        case accepted(reply: Data, phoneID: UUID)
        case rejected(reply: Data, attemptsLeft: Int)
        /// 手机自己放弃了这一轮（它验 Tb 没过）：不回话
        case aborted(attemptsLeft: Int)
        case noCode(reply: Data)
        case malformed(reply: Data)
    }

    /// 握手消息（PairRequest / PairConfirm / PairAbort）都从这里进
    func handlePair(_ data: Data) -> PairOutcome {
        switch PairingCrypto.kind(of: data) {
        case .pairRequest: return handleRequest(data)
        case .pairConfirm: return handleConfirm(data)
        case .pairAbort: return handleAbort(data)
        default:
            log("pair message malformed")
            return .malformed(reply: PairingCrypto.pairReject(.noCode))
        }
    }

    /// 这一轮没成：错码次数已经在回 Yb/Tb 时扣过，扣完了就锁
    private func lockIfExhausted() {
        guard attemptsLeft <= 0, !isLocked else { return }
        code = ""
        isLocked = true
        inFlight = nil
        log("code invalidated after \(PairingCrypto.maxCodeAttempts) wrong attempts; reopen the window for a new one")
    }

    private func handleRequest(_ data: Data) -> PairOutcome {
        log("pair request received")
        guard let request = try? PairingCrypto.PairRequest(decoding: data) else {
            log("pair request malformed")
            return .malformed(reply: PairingCrypto.pairReject(.noCode))
        }
        let who = request.phoneID.uuidString
        guard !usedSessions.contains(request.sid) else {
            log("pair request from \(who) reuses a session id; refused")
            return .malformed(reply: PairingCrypto.pairReject(.noCode))
        }
        // 上一轮没等到 Ta 就来了新的：上一轮作废（它的次数已经扣了）
        if inFlight != nil {
            log("previous pairing run abandoned; it stays counted")
            inFlight = nil
        }
        lockIfExhausted()
        guard !code.isEmpty, !isLocked else {
            log("pair request from \(who) but no code open\(isLocked ? " (locked after \(PairingCrypto.maxCodeAttempts) wrong codes)" : "")")
            return .noCode(reply: PairingCrypto.pairReject(.noCode))
        }
        usedSessions.insert(request.sid)
        guard let (response, session) = PairingCrypto.macRespond(request, code: code) else {
            log("pair request from \(who) has an invalid point; refused")
            return .malformed(reply: PairingCrypto.pairReject(.noCode))
        }
        attemptsLeft -= 1
        inFlight = session
        log("pair run started with \(who); counted as an attempt until confirmed (attempts left \(attemptsLeft))")
        return .responded(reply: response.encoded())
    }

    private func handleConfirm(_ data: Data) -> PairOutcome {
        guard let confirm = try? PairingCrypto.PairConfirm(decoding: data) else {
            log("pair confirmation malformed")
            return .malformed(reply: PairingCrypto.pairReject(.noCode))
        }
        let who = confirm.phoneID.uuidString
        guard let session = inFlight, session.phoneID == confirm.phoneID, session.sid == confirm.sid else {
            log("pair confirmation from \(who) for no running session; refused")
            return .rejected(reply: PairingCrypto.pairReject(.wrongCode), attemptsLeft: attemptsLeft)
        }
        // 不管成不成，这一轮都用完了
        inFlight = nil
        guard PairingCrypto.macCheckConfirm(confirm, session: session) else {
            log("pair confirmation bad from \(who), attempts left \(attemptsLeft)")
            lockIfExhausted()
            return .rejected(reply: PairingCrypto.pairReject(.wrongCode), attemptsLeft: attemptsLeft)
        }
        log("pair confirmation ok from \(who); code used up, waiting for first signed command")
        code = ""
        pending[confirm.phoneID] = session.sharedKey
        let reply = PairingCrypto.pairAccepted(phoneID: confirm.phoneID, sid: confirm.sid, key: session.sharedKey)
        return .accepted(reply: reply, phoneID: confirm.phoneID)
    }

    private func handleAbort(_ data: Data) -> PairOutcome {
        guard let (phoneID, sid) = PairingCrypto.decodePairAbort(data) else {
            log("pair abort malformed")
            return .malformed(reply: PairingCrypto.pairReject(.noCode))
        }
        if let session = inFlight, session.phoneID == phoneID, session.sid == sid {
            inFlight = nil
            log("phone \(phoneID.uuidString) gave up the run (code mismatch), attempts left \(attemptsLeft)")
            lockIfExhausted()
        }
        return .aborted(attemptsLeft: attemptsLeft)
    }

    // MARK: - 命令

    enum RejectReason: String, Equatable {
        case malformed = "malformed or unsigned"
        case unknownPhone = "unknown phone"
        case badSignature = "bad signature"
        case replay = "old counter (replay)"
        case storeFailed = "keychain write failed"
    }

    enum CommandOutcome: Equatable {
        /// confirmedPairing：这是刚握手那台手机的第一条命令，现在才算真的配上
        case accepted(command: String, phoneID: UUID, counter: UInt64, confirmedPairing: Bool, ack: Data)
        case rejected(RejectReason, phoneID: UUID?, ack: Data?)
    }

    func handleCommand(_ data: Data) -> CommandOutcome {
        guard let envelope = try? PairingCrypto.CommandEnvelope(decoding: data) else {
            log("command rejected: \(RejectReason.malformed.rawValue)")
            return .rejected(.malformed, phoneID: nil, ack: nil)
        }
        let id = envelope.phoneID
        func reject(_ reason: RejectReason, _ status: PairingCrypto.AckStatus) -> CommandOutcome {
            log("command rejected from \(id.uuidString): \(reason.rawValue) (counter \(envelope.counter))")
            return .rejected(reason, phoneID: id,
                             ack: PairingCrypto.makeAck(phoneID: id, counter: envelope.counter, status: status, key: nil))
        }

        let stored = store.load(id)
        let isPending = stored == nil && pending[id] != nil
        guard let record = stored ?? pending[id].map({ PairingRecord(key: $0, lastCounter: 0) }) else {
            return reject(.unknownPhone, .unknownOrBadSignature)
        }
        guard PairingCrypto.verifyCommand(envelope, key: record.key) else {
            return reject(.badSignature, .unknownOrBadSignature)
        }
        guard envelope.counter > record.lastCounter else {
            return reject(.replay, .replay)
        }
        guard store.save(PairingRecord(key: record.key, lastCounter: envelope.counter), for: id) else {
            return reject(.storeFailed, .malformed)
        }
        if isPending {
            pending[id] = nil
            log("pairing confirmed with \(id.uuidString) (first signed command verified, key stored)")
        }
        log("command accepted from \(id.uuidString): \"\(envelope.command)\" counter \(envelope.counter)")
        let ack = PairingCrypto.makeAck(phoneID: id, counter: envelope.counter, status: .accepted, key: record.key)
        return .accepted(command: envelope.command, phoneID: id, counter: envelope.counter,
                         confirmedPairing: isPending, ack: ack)
    }

    // MARK: - 撤下幕布：手机的回答（Presence / LiftNow）

    enum AnswerOutcome: Equatable {
        /// 签名对、手机认识、计数比上次大（新计数已写进存储）。nonce 新不新由 LiftGate 判断
        case accepted(PairingCrypto.PhoneAnswer)
        case rejected(RejectReason, phoneID: UUID?)
    }

    /// 只认已经确认配上的手机（钥匙在存储里）；和命令共用同一个计数
    func handleAnswer(_ data: Data) -> AnswerOutcome {
        guard let answer = try? PairingCrypto.PhoneAnswer(decoding: data) else {
            log("answer rejected: \(RejectReason.malformed.rawValue)")
            return .rejected(.malformed, phoneID: nil)
        }
        let id = answer.phoneID
        func reject(_ reason: RejectReason) -> AnswerOutcome {
            log("answer rejected from \(id.uuidString): \(reason.rawValue) (counter \(answer.counter))")
            return .rejected(reason, phoneID: id)
        }
        guard let record = store.load(id) else { return reject(.unknownPhone) }
        guard PairingCrypto.verifyAnswer(answer, key: record.key) else { return reject(.badSignature) }
        guard answer.counter > record.lastCounter else { return reject(.replay) }
        guard store.save(PairingRecord(key: record.key, lastCounter: answer.counter), for: id) else {
            return reject(.storeFailed)
        }
        return .accepted(answer)
    }

    func pollMessage(nonce: Data, for phoneID: UUID) -> Data? {
        guard let record = store.load(phoneID) else { return nil }
        return PairingCrypto.makePoll(nonce: nonce, phoneID: phoneID, key: record.key)
    }

    func liftResultMessage(_ status: PairingCrypto.LiftStatus, counter: UInt64, for phoneID: UUID) -> Data? {
        guard let record = store.load(phoneID) else { return nil }
        return PairingCrypto.makeLiftResult(status, counter: counter, phoneID: phoneID, key: record.key)
    }

    // MARK: - 发给手机的东西

    /// 发给手机的 State / KeepAwakeState 共用的 seq：毫秒时间，同一毫秒里连发两条也严格递增
    private var lastSeq: UInt64 = 0
    private func nextSeq() -> UInt64 {
        lastSeq = max(UInt64(Date().timeIntervalSince1970 * 1000), lastSeq + 1)
        return lastSeq
    }

    func stateMessage(closed: Bool, for phoneID: UUID) -> Data? {
        guard let record = store.load(phoneID) else { return nil }
        // seq 用毫秒时间：只要单调，手机拿它挡重放的旧状态
        return PairingCrypto.makeState(closed: closed, seq: nextSeq(), phoneID: phoneID, key: record.key)
    }

    /// 保持唤醒状态（协议 v3），seq 和 State 共用
    func keepAwakeStateMessage(mode: PairingCrypto.KeepAwakeMode, endsAt: UInt64, appName: String, for phoneID: UUID) -> Data? {
        guard let record = store.load(phoneID) else { return nil }
        return PairingCrypto.makeKeepAwakeState(phoneID: phoneID, seq: nextSeq(), mode: mode.rawValue, endsAt: endsAt,
                                                appName: appName, key: record.key)
    }

    /// 已经收下（计数已记）的命令，改回一条签名的「缺权限没做」（Ack status 4）
    func missingPermissionAck(counter: UInt64, for phoneID: UUID) -> Data? {
        guard let record = store.load(phoneID) else { return nil }
        return PairingCrypto.makeAck(phoneID: phoneID, counter: counter, status: .missingPermission, key: record.key)
    }

    /// 撤销一台：先签好撤销通知再删钥匙
    func revoke(_ phoneID: UUID) -> Data? {
        let notice = store.load(phoneID).map { PairingCrypto.makeRevoke(phoneID: phoneID, key: $0.key) }
        store.delete(phoneID)
        pending[phoneID] = nil
        log("pairing deleted for \(phoneID.uuidString)")
        return notice
    }

    /// 撤销全部，返回每台手机的撤销通知
    func revokeAll() -> [UUID: Data] {
        var notices: [UUID: Data] = [:]
        for id in pairedPhoneIDs {
            if let n = revoke(id) { notices[id] = n }
        }
        pending = [:]
        return notices
    }
}
