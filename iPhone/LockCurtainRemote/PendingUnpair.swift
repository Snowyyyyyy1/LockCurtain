// PendingUnpair.swift —— 撤销了、但旧电脑还不知道（protocol-v3.md §5，Ato msg 969）
//
// 撤销配对 / 配另一台电脑 配成的那一刻，界面马上回到没配对（或者换成新电脑），手机对旧电脑什么命令都不再发。
// 旧的那份记录（钥匙 + 计数 + 当时那台电脑的标识）从钥匙串的「link」挪到「pendingUnpair」（一个列表，可以有好几份），
// 唯一的用处：等旧电脑下次连上来，用它签一条 unpair（照常的递增计数，照常防重放）。
// 删掉它的只有三种回答：用这把旧钥匙签名的 Ack 0、用旧钥匙签名的 Revoke、或者 Ack 1（不认识 / 签名错）且确实来自旧电脑。没有时限。
//
// 怎么认出「这是旧电脑」（手机是外设，电脑是中心；电脑连上来以后不会先说话，Poll 也只发给认过身份的手机）：
//   * 现在配着的那台：照旧用现在的钥匙发 ping。它签名收下了 = 就是现在这台，旧的那份绝不往它身上试。
//   * 现在的钥匙被拒（Ack 1），或者手机根本没配着：这台中心「可能」是旧电脑，就直接发一条用旧钥匙签的 unpair。
//     - 回来的 Ack 0 用旧钥匙验得过 → 密码学上证明就是旧电脑，而且它已经删了我们 → 删掉那份。
//     - 回来 Ack 1：可能是旧电脑早就忘了我们，也可能只是旁边另一台电脑（它也不认识这把钥匙）。两者分不出来，
//       所以只有这台中心的标识（CBCentral.identifier）和那份记录里存的旧电脑标识一样时才删；不一样就留着，下次再说。
//       标识对不上的代价只是那份记录多留一阵（电脑换了蓝牙地址时可能永远留着——只是安静地多广播，不碍事）；
//       反过来，要是凭一个谁都能伪造、谁都会回的 Ack 1 就删，旧电脑可能永远不知道被撤销了。
//   * 用旧钥匙签的 unpair 发到别的电脑那里：它验不过签名，什么都不做（不认身份、不动计数），只回一条不签名的 Ack 1。
//     发到现在这台电脑：不会发生（见上，被现在的钥匙认过的中心不试）。
//   * 同一台电脑撤了又重新配上（电脑那边同一个 phoneID 换了新钥匙）：旧钥匙的 unpair 会被拒（Ack 1，标识一样）→ 删掉。
//     新配对配成时，标识和新电脑一样的旧记录也直接删掉：那台电脑已经把旧钥匙换成新的了。

import CryptoKit
import Foundation

/// 撤销了、还没告诉旧电脑的那一份
struct PendingUnpairRecord: Codable, Equatable, Identifiable {
    /// 本地编号（只用来在列表里找它）
    var id: UUID
    var key: Data
    /// 配对时那台电脑的 CBCentral 标识（只用来判断 Ack 1 是不是旧电脑回的）
    var macIdentifier: String
    /// 用这把钥匙最后发出去的计数
    var counter: UInt64

    init(id: UUID = UUID(), key: Data, macIdentifier: String, counter: UInt64) {
        self.id = id
        self.key = key
        self.macIdentifier = macIdentifier
        self.counter = counter
    }

    init(from link: PhoneLinkRecord) {
        self.init(key: link.key, macIdentifier: link.macIdentifier, counter: link.counter)
    }
}

/// 发出去的那条 unpair 得到了什么回答
enum PendingUnpairOutcome: Equatable, Sendable {
    /// Ack 0，用这把旧钥匙验得过：就是旧电脑，它已经删了我们
    case signedAck
    /// 用这把旧钥匙签名的 Revoke
    case revoked
    /// 不签名的 Ack 1：这台中心不认识这把钥匙（可能是旧电脑忘了我们，也可能是别的电脑）
    case unknownPhone
    /// 别的回答（旧计数 / 格式错 / 签名不对的 0）：不算数
    case other
    /// 没回音 / 断了
    case noAnswer
}

/// 待撤销列表的纯逻辑（不碰钥匙串、不碰蓝牙；单元测试测的就是这里）
struct PendingUnpairBook: Equatable {
    var records: [PendingUnpairRecord] = []

    var isEmpty: Bool { records.isEmpty }

    /// 现在配着的那份挪进来
    @discardableResult
    mutating func add(_ link: PhoneLinkRecord) -> PendingUnpairRecord {
        let record = PendingUnpairRecord(from: link)
        records.append(record)
        return record
    }

    /// 发 unpair 前：计数加一（调用方先存下来再发）
    mutating func reserveCounter(for id: UUID) -> (record: PendingUnpairRecord, counter: UInt64)? {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return nil }
        records[index].counter += 1
        return (records[index], records[index].counter)
    }

    /// 这台中心上还要试哪几份：标识对得上的排前面（最可能就是它），这次连接里试过的不再试
    func candidates(forCentral central: String, alreadyTried: Set<UUID>) -> [PendingUnpairRecord] {
        let open = records.filter { !alreadyTried.contains($0.id) }
        return open.filter { $0.macIdentifier == central } + open.filter { $0.macIdentifier != central }
    }

    /// 这个回答够不够把这份删掉
    static func shouldDelete(_ outcome: PendingUnpairOutcome, record: PendingUnpairRecord, central: String) -> Bool {
        switch outcome {
        case .signedAck, .revoked: return true
        case .unknownPhone: return record.macIdentifier == central
        case .other, .noAnswer: return false
        }
    }

    /// 回答之后这台中心上还要不要接着试别的：旧电脑收下了 unpair 就会断开，不用再试
    static func continuesAfter(_ outcome: PendingUnpairOutcome) -> Bool {
        switch outcome {
        case .signedAck, .revoked, .noAnswer: return false
        case .unknownPhone, .other: return true
        }
    }

    mutating func remove(_ id: UUID) {
        records.removeAll { $0.id == id }
    }

    /// 和这台电脑重新配上了：它那边同一个 phoneID 已经换成新钥匙，旧的那份不用再告诉它
    mutating func removeAll(macIdentifier: String) {
        records.removeAll { $0.macIdentifier == macIdentifier }
    }

    /// 电脑发来的 Ack 是不是在回这条 unpair、算哪一种（counter 不对就是 nil）
    static func classify(_ ack: PairingCrypto.Ack, counter: UInt64, phoneID: UUID, key: Data) -> PendingUnpairOutcome? {
        guard ack.counter == counter, ack.phoneID == phoneID else { return nil }
        switch ack.status {
        case .accepted:
            return PairingCrypto.verifyAck(ack, key: SymmetricKey(data: key)) ? .signedAck : .other
        case .unknownOrBadSignature:
            return .unknownPhone
        case .replay, .malformed, .missingPermission:
            return .other
        }
    }

    /// 用哪一份旧钥匙验得过这条 Revoke
    func recordVerifying(revoke message: Data, phoneID: UUID) -> PendingUnpairRecord? {
        records.first { PairingCrypto.verifyRevoke(message, phoneID: phoneID, key: SymmetricKey(data: $0.key)) }
    }
}
