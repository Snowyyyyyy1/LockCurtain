// PairingAuthority.swift —— Mac 端的配对 / 验签规则（和蓝牙无关，自测直接在进程里跑它）
//
//   * 配对码：窗口打开时给一个码；一个窗口最多错 5 次，第 5 次错完这个码作废，
//     「换一个码」也换不出新的，要关掉窗口重新打开。码只用一次：握手过了就作废。
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
    }

    /// 「换一个码」：错码次数不清零；已经作废的窗口换不出新码
    @discardableResult
    func refresh(code: String) -> Bool {
        guard !isLocked else { return false }
        self.code = code
        return true
    }

    func closeWindow() {
        code = ""
        pending = [:]
    }

    // MARK: - 握手

    enum PairOutcome: Equatable {
        /// reply 发回手机；phoneID 是谁
        case accepted(reply: Data, phoneID: UUID)
        case rejected(reply: Data, attemptsLeft: Int)
        case noCode(reply: Data)
        case malformed(reply: Data)
    }

    func handlePair(_ data: Data) -> PairOutcome {
        log("pair request received")
        guard let request = try? PairingCrypto.PairRequest(decoding: data) else {
            log("pair request malformed")
            return .malformed(reply: PairingCrypto.pairReject(.noCode))
        }
        guard !code.isEmpty, !isLocked else {
            log("pair request from \(request.phoneID.uuidString) but no code open\(isLocked ? " (locked after \(PairingCrypto.maxCodeAttempts) wrong codes)" : "")")
            return .noCode(reply: PairingCrypto.pairReject(.noCode))
        }
        guard let (response, key) = PairingCrypto.macAnswer(request, code: code) else {
            attemptsLeft -= 1
            log("pair tag bad from \(request.phoneID.uuidString), attempts left \(attemptsLeft)")
            if attemptsLeft <= 0 {
                code = ""
                isLocked = true
                log("code invalidated after \(PairingCrypto.maxCodeAttempts) wrong attempts; reopen the window for a new one")
            }
            return .rejected(reply: PairingCrypto.pairReject(.wrongCode), attemptsLeft: attemptsLeft)
        }
        log("pair tag ok from \(request.phoneID.uuidString); code used up, waiting for first signed command")
        code = ""
        pending[request.phoneID] = key
        return .accepted(reply: response.encoded(), phoneID: request.phoneID)
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

    // MARK: - 发给手机的东西

    func stateMessage(closed: Bool, for phoneID: UUID) -> Data? {
        guard let record = store.load(phoneID) else { return nil }
        // seq 用毫秒时间：只要单调，手机拿它挡重放的旧状态
        let seq = UInt64(Date().timeIntervalSince1970 * 1000)
        return PairingCrypto.makeState(closed: closed, seq: seq, phoneID: phoneID, key: record.key)
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
