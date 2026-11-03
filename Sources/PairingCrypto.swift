// PairingCrypto.swift —— 配对握手和命令签名（Mac 和 iPhone 共用这一份文件，只依赖 CryptoKit）
//
// 不再依赖系统蓝牙的链路加密，安全全在这一层做；这里只有作用在 Data 上的纯函数，
// 不知道底下是 BLE（谁当中心都行）还是 Wi-Fi。
//
// 握手（CPace，draft-irtf-cfrg-cpace，X25519 + SHA-512；见 CPace.swift）：
//   握手消息的版本字节是 2（pairingVersion），握手之后的消息还是 1，格式不变。
//   双方都由码推出同一个生成元 g = Elligator2(SHA-512(generator_string("CPace255", 码, CI, sid)))，
//     CI  = lv_cat("LockCurtain pairing v2", "initiator:phone" ‖ phoneID, "responder:mac")，ADa = ADb = 空
//     sid = 手机随机给的 16 字节，Mac 记着用过的，同一个 sid 不收第二次
//   手机 → Mac  PairRequest  = ver2 | 0x01 | phoneID(16) | sid(16) | Ya(32)        Ya = ya·g
//   Mac  → 手机 PairResponse = ver2 | 0x02 | sid(16) | Yb(32) | Tb(64)             Yb = yb·g
//   手机 → Mac  PairConfirm  = ver2 | 0x08 | phoneID(16) | sid(16) | Ta(64)
//   Mac  → 手机 PairAccepted = ver2 | 0x09 | phoneID(16) | sid(16) | mac(32)       mac = HMAC-SHA256(sharedKey, 前面所有字节)
//   手机 → Mac  PairAbort    = ver2 | 0x0A | phoneID(16) | sid(16)                 手机验 Tb 没过（码不对），告诉 Mac 这一轮作废
//   Mac  → 手机 PairReject   = ver2 | 0x07 | reason(1)          1 = 码不对，2 = 没有可用的码
//   K = X25519(y_自己, Y_对方)，全零就中止；ISK = SHA-512(lv_cat("CPace255_ISK", sid, K) ‖ lv_cat(Ya, ADa) ‖ lv_cat(Yb, ADb))
//   mac_key = SHA-512("CPaceMac" ‖ sid ‖ ISK)；Tb = HMAC-SHA512(mac_key, lv_cat(Yb, ADb))，Ta = HMAC-SHA512(mac_key, lv_cat(Ya, ADa))
//   sharedKey = HKDF-SHA256(ISK, salt: sid, info: "LockCurtain pairing v2", 32 字节)
//   一轮握手里，攻击者（不管冒充哪一边）最多试一个码；拿到的东西里没有能离线核对别的码的值。
//   Mac 在回 PairResponse 时就把这一轮记成一次错码，只有 Ta 验过才算成；半路不来、Ta 不对、手机放弃都算错。
//
// 握手之后：
//   手机 → Mac  Command   = ver | 0x03 | phoneID(16) | counter(8, 大端) | len(1) | command(UTF-8) | mac(32)
//               mac = HMAC-SHA256(sharedKey, 前面所有字节)；counter 必须严格递增
//   Mac  → 手机 Ack       = ver | 0x06 | phoneID(16) | counter(8) | status(1) [| mac(32)，只有 status=0 才带]
//               status 0 = 收下了（签名，手机据此确认握手真的成了），1 = 不认识/签名错，2 = 旧计数，3 = 格式错
//   Mac  → 手机 State     = ver | 0x05 | phoneID(16) | seq(8) | state(1: 0 开着 / 1 盖着) | mac(32)
//   Mac  → 手机 Revoke    = ver | 0x04 | phoneID(16) | mac(32)   撤销通知，签名后 Mac 才删钥匙
//
// 手机撤下幕布（都是版本 1，新加的类型；老 Mac / 老手机见到不认识的类型就丢掉，不影响别的消息）：
//   Mac  → 手机 Poll       = ver | 0x0B | phoneID(16) | nonce(16) | mac(32)
//               幕布盖着、手机连着时 Mac 每 2 秒写一次（写进收件箱会把后台的 App 叫醒）；nonce 每次新随机
//   手机 → Mac  Presence   = ver | 0x0C | phoneID(16) | counter(8) | nonce(16) | status(1) | mac(32)
//               status 0 = 锁着，1 = 此刻解锁着（isProtectedDataAvailable），2 = 「走近撤下」关着
//               counter 和命令共用同一个严格递增的计数；nonce 必须是 Mac 最近 5 秒内发的、没用过的
//   手机 → Mac  LiftNow    = ver | 0x0D | phoneID(16) | counter(8) | nonce(16) | mac(32)
//               「现在撤下」（手机先过了面容 / 密码）：不看「先锁过」那条，但照样要近、要新鲜、要签名
//   Mac  → 手机 LiftResult = ver | 0x0E | phoneID(16) | counter(8) | status(1) | mac(32)
//               counter 是被回复的那条 Presence / LiftNow 的计数；status 0 = 撤下了，1 = 太远，2 = 没撤（别的原因），
//               3 = 幕布本来就没盖着（老手机不认识 3，验不过就当没收到，等超时）
//               Presence 只在撤下了的时候回；LiftNow 每次都回
//
// 分帧（PairingFraming）：任何一条消息按传输层的单包上限切块，每块前面 1 字节头：
//   bit7 = 最后一块，低 7 位 = 块序号（模 128）。

import CryptoKit
import Foundation

enum PairingCrypto {
    /// 握手之后的消息（命令 / 收据 / 状态 / 撤销）的版本，格式没变
    static let version: UInt8 = 1
    /// 握手消息的版本（v1 是 HMAC(码) 认证，v2 是 CPace）
    static let pairingVersion: UInt8 = 2
    /// 一次打开的配对窗口里最多错几次码
    static let maxCodeAttempts = 5
    static let hkdfInfo = Data("LockCurtain pairing v2".utf8)
    static let sidLength = 16
    static let maxCommandBytes = 200

    enum Kind: UInt8 {
        case pairRequest = 0x01
        case pairResponse = 0x02
        case command = 0x03
        case revoke = 0x04
        case state = 0x05
        case ack = 0x06
        case pairReject = 0x07
        case pairConfirm = 0x08
        case pairAccepted = 0x09
        case pairAbort = 0x0A
        case poll = 0x0B
        case presence = 0x0C
        case liftNow = 0x0D
        case liftResult = 0x0E

        var isHandshake: Bool {
            switch self {
            case .pairRequest, .pairResponse, .pairReject, .pairConfirm, .pairAccepted, .pairAbort: return true
            case .command, .revoke, .state, .ack, .poll, .presence, .liftNow, .liftResult: return false
            }
        }

        /// 这一类消息该带的版本字节
        var wireVersion: UInt8 { isHandshake ? pairingVersion : version }
    }

    enum WireError: Error, Equatable {
        case wrongVersion
        case wrongKind
        case wrongLength
        case badText
    }

    /// 消息头：版本 + 类型，解码前先看这个
    static func kind(of data: Data) -> Kind? {
        let b = [UInt8](data)
        guard b.count >= 2, let kind = Kind(rawValue: b[1]), b[0] == kind.wireVersion else { return nil }
        return kind
    }

    // MARK: - 小工具

    static func bytes(_ uuid: UUID) -> Data {
        withUnsafeBytes(of: uuid.uuid) { Data($0) }
    }

    static func uuid(_ bytes: ArraySlice<UInt8>) -> UUID {
        let b = Array(bytes)
        precondition(b.count == 16)
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    static func bigEndian(_ value: UInt64) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    static func uint64(_ bytes: ArraySlice<UInt8>) -> UInt64 {
        bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    static func header(_ kind: Kind) -> Data { Data([kind.wireVersion, kind.rawValue]) }

    private static func check(_ b: [UInt8], _ kind: Kind) throws {
        guard b.count >= 2 else { throw WireError.wrongLength }
        guard b[0] == kind.wireVersion else { throw WireError.wrongVersion }
        guard b[1] == kind.rawValue else { throw WireError.wrongKind }
    }

    static func hmac(_ message: Data, key: SymmetricKey) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: message, using: key))
    }

    /// 常数时间比较（CryptoKit 的 isValidAuthenticationCode）
    static func hmacValid(_ mac: Data, for message: Data, key: SymmetricKey) -> Bool {
        mac.count == 32 && HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: message, using: key)
    }

    // MARK: - 消息

    struct PairRequest: Equatable {
        static let length = 2 + 16 + 16 + 32
        var phoneID: UUID
        var sid: Data
        var ya: Data

        func encoded() -> Data {
            header(.pairRequest) + bytes(phoneID) + sid + ya
        }

        init(phoneID: UUID, sid: Data, ya: Data) {
            self.phoneID = phoneID
            self.sid = sid
            self.ya = ya
        }

        init(decoding data: Data) throws {
            let b = [UInt8](data)
            try check(b, .pairRequest)
            guard b.count == Self.length else { throw WireError.wrongLength }
            phoneID = uuid(b[2..<18])
            sid = Data(b[18..<34])
            ya = Data(b[34..<66])
        }
    }

    struct PairResponse: Equatable {
        static let length = 2 + 16 + 32 + 64
        var sid: Data
        var yb: Data
        /// Mac 的确认标签 Tb
        var tag: Data

        func encoded() -> Data { header(.pairResponse) + sid + yb + tag }

        init(sid: Data, yb: Data, tag: Data) {
            self.sid = sid
            self.yb = yb
            self.tag = tag
        }

        init(decoding data: Data) throws {
            let b = [UInt8](data)
            try check(b, .pairResponse)
            guard b.count == Self.length else { throw WireError.wrongLength }
            sid = Data(b[2..<18])
            yb = Data(b[18..<50])
            tag = Data(b[50..<114])
        }
    }

    struct PairConfirm: Equatable {
        static let length = 2 + 16 + 16 + 64
        var phoneID: UUID
        var sid: Data
        /// 手机的确认标签 Ta
        var tag: Data

        func encoded() -> Data { header(.pairConfirm) + bytes(phoneID) + sid + tag }

        init(phoneID: UUID, sid: Data, tag: Data) {
            self.phoneID = phoneID
            self.sid = sid
            self.tag = tag
        }

        init(decoding data: Data) throws {
            let b = [UInt8](data)
            try check(b, .pairConfirm)
            guard b.count == Self.length else { throw WireError.wrongLength }
            phoneID = uuid(b[2..<18])
            sid = Data(b[18..<34])
            tag = Data(b[34..<98])
        }
    }

    /// 手机放弃这一轮（Mac 的 Tb 没验过）：ver2 | 0x0A | phoneID | sid
    static func pairAbort(phoneID: UUID, sid: Data) -> Data {
        header(.pairAbort) + bytes(phoneID) + sid
    }

    static func decodePairAbort(_ data: Data) -> (phoneID: UUID, sid: Data)? {
        let b = [UInt8](data)
        guard (try? check(b, .pairAbort)) != nil, b.count == 2 + 16 + 16 else { return nil }
        return (uuid(b[2..<18]), Data(b[18..<34]))
    }

    /// Mac 验过 Ta 之后的回执，用新钥匙签：手机见到它才存钥匙
    static func pairAccepted(phoneID: UUID, sid: Data, key: SymmetricKey) -> Data {
        let signed = header(.pairAccepted) + bytes(phoneID) + sid
        return signed + hmac(signed, key: key)
    }

    static func verifyPairAccepted(_ data: Data, phoneID: UUID, sid: Data, key: SymmetricKey) -> Bool {
        let b = [UInt8](data)
        guard (try? check(b, .pairAccepted)) != nil, b.count == 2 + 16 + 16 + 32,
              uuid(b[2..<18]) == phoneID, Data(b[18..<34]) == sid else { return false }
        return hmacValid(Data(b[34...]), for: Data(b[0..<34]), key: key)
    }

    enum PairRejectReason: UInt8 {
        case wrongCode = 1
        case noCode = 2
    }

    static func pairReject(_ reason: PairRejectReason) -> Data {
        header(.pairReject) + Data([reason.rawValue])
    }

    static func decodePairReject(_ data: Data) -> PairRejectReason? {
        let b = [UInt8](data)
        guard (try? check(b, .pairReject)) != nil, b.count == 3 else { return nil }
        return PairRejectReason(rawValue: b[2])
    }

    struct CommandEnvelope: Equatable {
        var phoneID: UUID
        var counter: UInt64
        var command: String
        var mac: Data

        /// 被签名的部分：ver | kind | phoneID | counter | len | command
        static func signedPart(phoneID: UUID, counter: UInt64, command: String) -> Data {
            let text = Data(command.utf8)
            return header(.command) + bytes(phoneID) + bigEndian(counter) + Data([UInt8(text.count)]) + text
        }

        var signedPart: Data { Self.signedPart(phoneID: phoneID, counter: counter, command: command) }

        func encoded() -> Data { signedPart + mac }

        init(phoneID: UUID, counter: UInt64, command: String, mac: Data) {
            self.phoneID = phoneID
            self.counter = counter
            self.command = command
            self.mac = mac
        }

        init(decoding data: Data) throws {
            let b = [UInt8](data)
            try check(b, .command)
            guard b.count >= 2 + 16 + 8 + 1 + 32 else { throw WireError.wrongLength }
            let len = Int(b[26])
            guard b.count == 27 + len + 32 else { throw WireError.wrongLength }
            guard let text = String(bytes: b[27..<(27 + len)], encoding: .utf8) else { throw WireError.badText }
            phoneID = uuid(b[2..<18])
            counter = uint64(b[18..<26])
            command = text
            mac = Data(b[(27 + len)...])
        }
    }

    enum AckStatus: UInt8 {
        case accepted = 0
        case unknownOrBadSignature = 1
        case replay = 2
        case malformed = 3
    }

    struct Ack: Equatable {
        var phoneID: UUID
        var counter: UInt64
        var status: AckStatus
        /// 只有 accepted 才签名
        var mac: Data?

        static func signedPart(phoneID: UUID, counter: UInt64, status: AckStatus) -> Data {
            header(.ack) + bytes(phoneID) + bigEndian(counter) + Data([status.rawValue])
        }

        func encoded() -> Data {
            Self.signedPart(phoneID: phoneID, counter: counter, status: status) + (mac ?? Data())
        }

        init(phoneID: UUID, counter: UInt64, status: AckStatus, mac: Data?) {
            self.phoneID = phoneID
            self.counter = counter
            self.status = status
            self.mac = mac
        }

        init(decoding data: Data) throws {
            let b = [UInt8](data)
            try check(b, .ack)
            guard b.count == 27 || b.count == 27 + 32 else { throw WireError.wrongLength }
            guard let status = AckStatus(rawValue: b[26]) else { throw WireError.wrongLength }
            phoneID = uuid(b[2..<18])
            counter = uint64(b[18..<26])
            self.status = status
            mac = b.count == 59 ? Data(b[27...]) : nil
        }
    }

    // MARK: - 握手

    /// CPace 的通道标识：两边的身份和角色（手机永远是发起方，Mac 永远是应答方）
    static func channelID(phoneID: UUID) -> Data {
        CPace.lvCat(Data("LockCurtain pairing v2".utf8),
                    Data("initiator:phone".utf8) + bytes(phoneID),
                    Data("responder:mac".utf8))
    }

    static func generator(code: String, phoneID: UUID, sid: Data) -> Data {
        CPace.calculateGenerator(prs: Data(code.utf8), ci: channelID(phoneID: phoneID), sid: sid)
    }

    /// ADa、ADb 都是空：身份已经在 CI 里
    static let associatedData = Data()

    /// 握手的结果：确认标签用的 mac_key 和最终的共享钥匙
    struct HandshakeKeys {
        let macKey: SymmetricKey
        let sharedKey: SymmetricKey
    }

    static func handshakeKeys(sid: Data, k: Data, ya: Data, yb: Data) -> HandshakeKeys {
        let isk = CPace.isk(sid: sid, k: k, ya: ya, ada: associatedData, yb: yb, adb: associatedData)
        let shared = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: isk), salt: sid,
                                            info: hkdfInfo, outputByteCount: 32)
        return HandshakeKeys(macKey: CPace.macKey(sid: sid, isk: isk), sharedKey: shared)
    }

    /// 手机这一轮的状态：只在内存里，握手完就丢
    struct PhoneSession {
        let phoneID: UUID
        let sid: Data
        let secret: Curve25519.KeyAgreement.PrivateKey
        let ya: Data
    }

    /// 手机：随机 sid 和标量，Ya = ya·g。生成元退化（概率可忽略）时返回 nil。
    static func phoneStart(code: String, phoneID: UUID,
                           sid: Data = Data((0..<sidLength).map { _ in UInt8.random(in: 0...255) }))
        -> (request: PairRequest, session: PhoneSession)? {
        let g = generator(code: code, phoneID: phoneID, sid: sid)
        let secret = CPace.sampleScalar()
        guard let ya = CPace.scalarMult(secret, g) else { return nil }
        return (PairRequest(phoneID: phoneID, sid: sid, ya: ya),
                PhoneSession(phoneID: phoneID, sid: sid, secret: secret, ya: ya))
    }

    enum PhoneStep {
        /// Mac 的 Tb 验过：把 Ta 发过去，等 PairAccepted
        case confirm(PairConfirm, sharedKey: SymmetricKey)
        /// Tb 不对：两边的码不一样（或者对面不是知道码的 Mac）
        case wrongCode
        /// sid 对不上或 Yb 是低阶点 / 非法
        case invalid
    }

    /// 手机：收到 Mac 的 Yb 和 Tb
    static func phoneFinish(_ response: PairResponse, session: PhoneSession) -> PhoneStep {
        guard response.sid == session.sid,
              let k = CPace.scalarMult(session.secret, response.yb) else { return .invalid }
        let keys = handshakeKeys(sid: session.sid, k: k, ya: session.ya, yb: response.yb)
        guard CPace.tagValid(response.tag, key: keys.macKey, y: response.yb, ad: associatedData) else {
            return .wrongCode
        }
        let ta = CPace.tag(keys.macKey, y: session.ya, ad: associatedData)
        return .confirm(PairConfirm(phoneID: session.phoneID, sid: session.sid, tag: ta), sharedKey: keys.sharedKey)
    }

    /// Mac 这一轮的状态：等手机的 Ta
    struct MacSession {
        let phoneID: UUID
        let sid: Data
        let ya: Data
        let macKey: SymmetricKey
        let sharedKey: SymmetricKey
    }

    /// Mac：用自己的码算 g、Yb、K，回 Yb 和 Tb。Ya 不合法（低阶点等）返回 nil。
    static func macRespond(_ request: PairRequest, code: String) -> (response: PairResponse, session: MacSession)? {
        let g = generator(code: code, phoneID: request.phoneID, sid: request.sid)
        let secret = CPace.sampleScalar()
        guard let yb = CPace.scalarMult(secret, g),
              let k = CPace.scalarMult(secret, request.ya) else { return nil }
        let keys = handshakeKeys(sid: request.sid, k: k, ya: request.ya, yb: yb)
        let tb = CPace.tag(keys.macKey, y: yb, ad: associatedData)
        return (PairResponse(sid: request.sid, yb: yb, tag: tb),
                MacSession(phoneID: request.phoneID, sid: request.sid, ya: request.ya,
                           macKey: keys.macKey, sharedKey: keys.sharedKey))
    }

    /// Mac：核对手机的 Ta（常数时间）
    static func macCheckConfirm(_ confirm: PairConfirm, session: MacSession) -> Bool {
        confirm.phoneID == session.phoneID && confirm.sid == session.sid
            && CPace.tagValid(confirm.tag, key: session.macKey, y: session.ya, ad: associatedData)
    }

    // MARK: - 命令

    static func sealCommand(_ command: String, phoneID: UUID, counter: UInt64, key: SymmetricKey) -> Data? {
        guard Data(command.utf8).count <= maxCommandBytes else { return nil }
        let signed = CommandEnvelope.signedPart(phoneID: phoneID, counter: counter, command: command)
        return signed + hmac(signed, key: key)
    }

    static func verifyCommand(_ envelope: CommandEnvelope, key: SymmetricKey) -> Bool {
        hmacValid(envelope.mac, for: envelope.signedPart, key: key)
    }

    static func makeAck(phoneID: UUID, counter: UInt64, status: AckStatus, key: SymmetricKey?) -> Data {
        let signed = Ack.signedPart(phoneID: phoneID, counter: counter, status: status)
        guard status == .accepted, let key else { return signed }
        return signed + hmac(signed, key: key)
    }

    /// 手机：只有带对签名的 accepted 才算真收下
    static func verifyAck(_ ack: Ack, key: SymmetricKey) -> Bool {
        guard ack.status == .accepted, let mac = ack.mac else { return false }
        return hmacValid(mac, for: Ack.signedPart(phoneID: ack.phoneID, counter: ack.counter, status: ack.status), key: key)
    }

    // MARK: - 幕布状态 / 撤销

    static func makeState(closed: Bool, seq: UInt64, phoneID: UUID, key: SymmetricKey) -> Data {
        let signed = header(.state) + bytes(phoneID) + bigEndian(seq) + Data([closed ? 1 : 0])
        return signed + hmac(signed, key: key)
    }

    /// 返回 (seq, closed)；签名不对或不是给这台手机的就是 nil
    static func openState(_ data: Data, phoneID: UUID, key: SymmetricKey) -> (seq: UInt64, closed: Bool)? {
        let b = [UInt8](data)
        guard (try? check(b, .state)) != nil, b.count == 2 + 16 + 8 + 1 + 32,
              uuid(b[2..<18]) == phoneID,
              hmacValid(Data(b[27...]), for: Data(b[0..<27]), key: key) else { return nil }
        return (uint64(b[18..<26]), b[26] == 1)
    }

    static func makeRevoke(phoneID: UUID, key: SymmetricKey) -> Data {
        let signed = header(.revoke) + bytes(phoneID)
        return signed + hmac(signed, key: key)
    }

    static func verifyRevoke(_ data: Data, phoneID: UUID, key: SymmetricKey) -> Bool {
        let b = [UInt8](data)
        guard (try? check(b, .revoke)) != nil, b.count == 2 + 16 + 32,
              uuid(b[2..<18]) == phoneID else { return false }
        return hmacValid(Data(b[18...]), for: Data(b[0..<18]), key: key)
    }

    // MARK: - 手机撤下幕布

    static let nonceLength = 16

    static func makeNonce() -> Data {
        var bytes = [UInt8](repeating: 0, count: nonceLength)
        var rng = SystemRandomNumberGenerator()
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255, using: &rng) }
        return Data(bytes)
    }

    /// Mac 的问询：签名的，手机只回它认得的 Mac
    static func makePoll(nonce: Data, phoneID: UUID, key: SymmetricKey) -> Data? {
        guard nonce.count == nonceLength else { return nil }
        let signed = header(.poll) + bytes(phoneID) + nonce
        return signed + hmac(signed, key: key)
    }

    /// 手机：验 Mac 的问询，返回 nonce
    static func openPoll(_ data: Data, phoneID: UUID, key: SymmetricKey) -> Data? {
        let b = [UInt8](data)
        guard (try? check(b, .poll)) != nil, b.count == 2 + 16 + 16 + 32,
              uuid(b[2..<18]) == phoneID,
              hmacValid(Data(b[34...]), for: Data(b[0..<34]), key: key) else { return nil }
        return Data(b[18..<34])
    }

    enum PresenceStatus: UInt8 {
        case locked = 0
        case unlocked = 1
        /// 「走近撤下」关着：当成从来没解锁
        case off = 2
    }

    /// 手机 → Mac 的签名回答（Presence 或 LiftNow）。签名验过之前里面的东西都不可信
    struct PhoneAnswer: Equatable {
        enum Kind: Equatable {
            case presence(PresenceStatus)
            case liftNow
        }
        var kind: Kind
        var phoneID: UUID
        var counter: UInt64
        var nonce: Data
        var mac: Data

        static func signedPart(_ kind: Kind, phoneID: UUID, counter: UInt64, nonce: Data) -> Data {
            switch kind {
            case .presence(let status):
                return header(.presence) + bytes(phoneID) + bigEndian(counter) + nonce + Data([status.rawValue])
            case .liftNow:
                return header(.liftNow) + bytes(phoneID) + bigEndian(counter) + nonce
            }
        }

        var signedPart: Data { Self.signedPart(kind, phoneID: phoneID, counter: counter, nonce: nonce) }

        func encoded() -> Data { signedPart + mac }

        init(kind: Kind, phoneID: UUID, counter: UInt64, nonce: Data, mac: Data) {
            self.kind = kind
            self.phoneID = phoneID
            self.counter = counter
            self.nonce = nonce
            self.mac = mac
        }

        init(decoding data: Data) throws {
            let b = [UInt8](data)
            guard b.count >= 2 else { throw WireError.wrongLength }
            guard b[0] == version else { throw WireError.wrongVersion }
            let head = 2 + 16 + 8 + 16
            switch b[1] {
            case PairingCrypto.Kind.presence.rawValue:
                guard b.count == head + 1 + 32 else { throw WireError.wrongLength }
                guard let status = PresenceStatus(rawValue: b[head]) else { throw WireError.wrongLength }
                kind = .presence(status)
                mac = Data(b[(head + 1)...])
            case PairingCrypto.Kind.liftNow.rawValue:
                guard b.count == head + 32 else { throw WireError.wrongLength }
                kind = .liftNow
                mac = Data(b[head...])
            default:
                throw WireError.wrongKind
            }
            phoneID = uuid(b[2..<18])
            counter = uint64(b[18..<26])
            nonce = Data(b[26..<42])
        }
    }

    static func sealPresence(_ status: PresenceStatus, nonce: Data, phoneID: UUID, counter: UInt64, key: SymmetricKey) -> Data? {
        guard nonce.count == nonceLength else { return nil }
        let signed = PhoneAnswer.signedPart(.presence(status), phoneID: phoneID, counter: counter, nonce: nonce)
        return signed + hmac(signed, key: key)
    }

    static func sealLiftNow(nonce: Data, phoneID: UUID, counter: UInt64, key: SymmetricKey) -> Data? {
        guard nonce.count == nonceLength else { return nil }
        let signed = PhoneAnswer.signedPart(.liftNow, phoneID: phoneID, counter: counter, nonce: nonce)
        return signed + hmac(signed, key: key)
    }

    static func verifyAnswer(_ answer: PhoneAnswer, key: SymmetricKey) -> Bool {
        hmacValid(answer.mac, for: answer.signedPart, key: key)
    }

    enum LiftStatus: UInt8 {
        case lifted = 0
        case tooFar = 1
        case refused = 2
        /// 幕布本来就没盖着（手机据此把界面改成「没盖上」）
        case notCovered = 3
    }

    static func makeLiftResult(_ status: LiftStatus, counter: UInt64, phoneID: UUID, key: SymmetricKey) -> Data {
        let signed = header(.liftResult) + bytes(phoneID) + bigEndian(counter) + Data([status.rawValue])
        return signed + hmac(signed, key: key)
    }

    /// 手机：验 Mac 的撤下结果，返回 (counter, status)
    static func openLiftResult(_ data: Data, phoneID: UUID, key: SymmetricKey) -> (counter: UInt64, status: LiftStatus)? {
        let b = [UInt8](data)
        guard (try? check(b, .liftResult)) != nil, b.count == 2 + 16 + 8 + 1 + 32,
              uuid(b[2..<18]) == phoneID,
              let status = LiftStatus(rawValue: b[26]),
              hmacValid(Data(b[27...]), for: Data(b[0..<27]), key: key) else { return nil }
        return (uint64(b[18..<26]), status)
    }
}


// MARK: - 分帧

enum PairingFraming {
    static let maxMessage = 1024

    /// 按单包上限切块（上限至少 2：1 字节头 + 1 字节内容）
    static func chunks(_ message: Data, maxChunk: Int) -> [Data] {
        let room = max(1, maxChunk - 1)
        let b = [UInt8](message)
        var out: [Data] = []
        var index = 0
        var start = 0
        repeat {
            let end = min(b.count, start + room)
            let last = end == b.count
            out.append(Data([UInt8(index & 0x7F) | (last ? 0x80 : 0)]) + Data(b[start..<end]))
            index += 1
            start = end
        } while start < b.count
        return out
    }

    /// 收块拼消息：顺序错了就整条丢掉重来
    struct Assembler {
        private var buffer = Data()
        private var expected: UInt8 = 0

        init() {}

        mutating func reset() {
            buffer = Data()
            expected = 0
        }

        /// 拼完一条就返回它
        mutating func feed(_ chunk: Data) -> Data? {
            let b = [UInt8](chunk)
            guard let head = b.first else { return nil }
            let index = head & 0x7F
            if index == 0 { buffer = Data(); expected = 0 }
            guard index == expected else { reset(); return nil }
            buffer.append(contentsOf: b.dropFirst())
            guard buffer.count <= PairingFraming.maxMessage else { reset(); return nil }
            expected = (expected + 1) & 0x7F
            if head & 0x80 != 0 {
                let message = buffer
                reset()
                return message
            }
            return nil
        }
    }
}
