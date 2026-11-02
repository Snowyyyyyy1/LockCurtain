// PairingCrypto.swift —— 配对握手和命令签名（Mac 和 iPhone 共用这一份文件，只依赖 CryptoKit）
//
// 不再依赖系统蓝牙的链路加密，安全全在这一层做；这里只有作用在 Data 上的纯函数，
// 不知道底下是 BLE（谁当中心都行）还是 Wi-Fi。
//
// 握手（6 位码认证 + X25519 密钥协商，旁听的人算不出密钥）：
//   手机 → Mac  PairRequest  = ver | 0x01 | phoneID(16) | phonePub(32) | tag(32)
//               tag  = HMAC-SHA256(key: SHA256(code), phonePub || phoneID)
//   Mac  → 手机 PairResponse = ver | 0x02 | macPub(32) | tag2(32)
//               tag2 = HMAC-SHA256(key: SHA256(code), macPub || phonePub)
//   Mac  → 手机 PairReject   = ver | 0x07 | reason(1)          1 = 码不对，2 = 没有可用的码
//   sharedKey = HKDF-SHA256(X25519(priv, peerPub), salt: phonePub || macPub,
//                           info: "LockCurtain pairing v1", 32 字节)
//
// 握手之后：
//   手机 → Mac  Command   = ver | 0x03 | phoneID(16) | counter(8, 大端) | len(1) | command(UTF-8) | mac(32)
//               mac = HMAC-SHA256(sharedKey, 前面所有字节)；counter 必须严格递增
//   Mac  → 手机 Ack       = ver | 0x06 | phoneID(16) | counter(8) | status(1) [| mac(32)，只有 status=0 才带]
//               status 0 = 收下了（签名，手机据此确认握手真的成了），1 = 不认识/签名错，2 = 旧计数，3 = 格式错
//   Mac  → 手机 State     = ver | 0x05 | phoneID(16) | seq(8) | state(1: 0 开着 / 1 盖着) | mac(32)
//   Mac  → 手机 Revoke    = ver | 0x04 | phoneID(16) | mac(32)   撤销通知，签名后 Mac 才删钥匙
//
// 分帧（PairingFraming）：任何一条消息按传输层的单包上限切块，每块前面 1 字节头：
//   bit7 = 最后一块，低 7 位 = 块序号（模 128）。

import CryptoKit
import Foundation

enum PairingCrypto {
    static let version: UInt8 = 1
    /// 一次打开的配对窗口里最多错几次码
    static let maxCodeAttempts = 5
    static let hkdfInfo = Data("LockCurtain pairing v1".utf8)
    static let maxCommandBytes = 200

    enum Kind: UInt8 {
        case pairRequest = 0x01
        case pairResponse = 0x02
        case command = 0x03
        case revoke = 0x04
        case state = 0x05
        case ack = 0x06
        case pairReject = 0x07
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
        guard b.count >= 2, b[0] == version else { return nil }
        return Kind(rawValue: b[1])
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

    static func header(_ kind: Kind) -> Data { Data([version, kind.rawValue]) }

    private static func check(_ b: [UInt8], _ kind: Kind) throws {
        guard b.count >= 2 else { throw WireError.wrongLength }
        guard b[0] == version else { throw WireError.wrongVersion }
        guard b[1] == kind.rawValue else { throw WireError.wrongKind }
    }

    static func codeKey(_ code: String) -> SymmetricKey {
        SymmetricKey(data: Data(SHA256.hash(data: Data(code.utf8))))
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
        static let length = 2 + 16 + 32 + 32
        var phoneID: UUID
        var phonePub: Data
        var tag: Data

        func encoded() -> Data {
            header(.pairRequest) + bytes(phoneID) + phonePub + tag
        }

        init(phoneID: UUID, phonePub: Data, tag: Data) {
            self.phoneID = phoneID
            self.phonePub = phonePub
            self.tag = tag
        }

        init(decoding data: Data) throws {
            let b = [UInt8](data)
            try check(b, .pairRequest)
            guard b.count == Self.length else { throw WireError.wrongLength }
            phoneID = uuid(b[2..<18])
            phonePub = Data(b[18..<50])
            tag = Data(b[50..<82])
        }
    }

    struct PairResponse: Equatable {
        static let length = 2 + 32 + 32
        var macPub: Data
        var tag2: Data

        func encoded() -> Data { header(.pairResponse) + macPub + tag2 }

        init(macPub: Data, tag2: Data) {
            self.macPub = macPub
            self.tag2 = tag2
        }

        init(decoding data: Data) throws {
            let b = [UInt8](data)
            try check(b, .pairResponse)
            guard b.count == Self.length else { throw WireError.wrongLength }
            macPub = Data(b[2..<34])
            tag2 = Data(b[34..<66])
        }
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

    /// 手机：生成一次性密钥，造配对请求。私钥只留在内存里，握手完就丢。
    static func makePairRequest(code: String, phoneID: UUID)
        -> (request: PairRequest, secret: Curve25519.KeyAgreement.PrivateKey) {
        let secret = Curve25519.KeyAgreement.PrivateKey()
        let pub = secret.publicKey.rawRepresentation
        let tag = hmac(pub + bytes(phoneID), key: codeKey(code))
        return (PairRequest(phoneID: phoneID, phonePub: pub, tag: tag), secret)
    }

    /// Mac：码对得上就回应答并算出共享密钥；对不上（或公钥不合法）返回 nil
    static func macAnswer(_ request: PairRequest, code: String) -> (response: PairResponse, sharedKey: SymmetricKey)? {
        let key = codeKey(code)
        guard hmacValid(request.tag, for: request.phonePub + bytes(request.phoneID), key: key),
              let phonePub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: request.phonePub) else {
            return nil
        }
        let secret = Curve25519.KeyAgreement.PrivateKey()
        guard let shared = try? secret.sharedSecretFromKeyAgreement(with: phonePub) else { return nil }
        let macPub = secret.publicKey.rawRepresentation
        let tag2 = hmac(macPub + request.phonePub, key: key)
        return (PairResponse(macPub: macPub, tag2: tag2),
                deriveKey(shared, phonePub: request.phonePub, macPub: macPub))
    }

    /// 手机：核对 Mac 的 tag2，对上了才得到共享密钥
    static func phoneFinish(_ response: PairResponse, request: PairRequest,
                            secret: Curve25519.KeyAgreement.PrivateKey, code: String) -> SymmetricKey? {
        guard hmacValid(response.tag2, for: response.macPub + request.phonePub, key: codeKey(code)),
              let macPub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: response.macPub),
              let shared = try? secret.sharedSecretFromKeyAgreement(with: macPub) else { return nil }
        return deriveKey(shared, phonePub: request.phonePub, macPub: response.macPub)
    }

    static func deriveKey(_ shared: SharedSecret, phonePub: Data, macPub: Data) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: phonePub + macPub,
                                       sharedInfo: hkdfInfo, outputByteCount: 32)
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
