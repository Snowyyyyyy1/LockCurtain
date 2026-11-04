// PairingCryptoSelfTest.swift —— 配对加密层自测（不碰蓝牙）
//
// 运行（verify.sh 里也有）：
//   cp Tests/PairingCryptoSelfTest.swift /tmp/pc/main.swift
//   xcrun swiftc -o /tmp/pc/t /tmp/pc/main.swift Sources/CPace.swift Sources/PairingCrypto.swift Sources/PairingAuthority.swift Sources/LiftGate.swift Sources/ReconnectPolicy.swift Sources/PairingSelfTest.swift
//   /tmp/pc/t
// 另外在登录钥匙串里用一个测试专用的 service 存一条、读回、删掉，验证 Mac 的钥匙串存取。

import CryptoKit
import Foundation

var (lines, passed) = PairingSelfTest.run()

// 钥匙串存取（测试专用 service，跑完删干净）
let keychain = KeychainPairingStore(service: "dev.local.lockcurtain.selftest.pairing")
let id = UUID()
let record = PairingRecord(key: SymmetricKey(size: .bits256), lastCounter: 7)
let saved = keychain.save(record, for: id)
let loaded = keychain.load(id)
let updated = keychain.save(PairingRecord(key: record.key, lastCounter: 8), for: id)
let listed = keychain.allPhoneIDs().contains(id)
let reloaded = keychain.load(id)
keychain.delete(id)
let gone = keychain.load(id) == nil
let ok = saved && loaded == record && updated && listed && reloaded?.lastCounter == 8 && gone
lines.insert("\(ok ? "PASS" : "FAIL")  钥匙串：存、读、改计数、列出、删除", at: lines.count - 1)
if !ok { passed = false }

// MARK: - 走网络：NetFraming、Ack 5、Transport / NetworkPolicy

func netExpect(_ ok: Bool, _ name: String) {
    lines.insert("\(ok ? "PASS" : "FAIL")  \(name)", at: lines.count - 1)
    if !ok { passed = false }
}

func runNetworkTests() {
    // NetFraming
    let msg = Data((0..<300).map { UInt8($0 & 0xFF) })
    let framed = NetFraming.frame(msg)!
    netExpect(framed.count == 302 && framed[0] == 0x01 && framed[1] == 0x2C, "网络分帧：2 字节大端长度 + 消息")
    netExpect(NetFraming.frame(Data()) == nil && NetFraming.frame(Data(count: 1025)) == nil
              && NetFraming.frame(Data(count: 1024))?.count == 1026, "网络分帧：空消息 / 超过 1024 不能封帧，1024 可以")
    var r1 = NetFraming.Reader()
    var got: [Data] = []
    for byte in framed + NetFraming.frame(Data([7]))! { got += r1.feed(Data([byte])) }
    netExpect(got == [msg, Data([7])] && !r1.isBroken, "网络分帧：一个字节一个字节喂也能拼出来")
    var r2 = NetFraming.Reader()
    let both = r2.feed(framed + NetFraming.frame(Data([1, 2]))! + NetFraming.frame(Data([3]))!)
    netExpect(both == [msg, Data([1, 2]), Data([3])], "网络分帧：几帧粘在一起一次喂进去")
    var r3 = NetFraming.Reader()
    netExpect(r3.feed(framed.prefix(100)).isEmpty && r3.feed(framed.dropFirst(100)) == [msg], "网络分帧：半帧等后半帧")
    var r4 = NetFraming.Reader()
    _ = r4.feed(Data([0, 0, 9]))
    netExpect(r4.isBroken && r4.feed(NetFraming.frame(Data([1]))!).isEmpty, "网络分帧：长度 0 坏掉，之后什么都不交出")
    var r5 = NetFraming.Reader()
    let beforeBad = r5.feed(NetFraming.frame(Data([5]))! + Data([0x04, 0x01, 1]))
    netExpect(r5.isBroken && beforeBad == [Data([5])], "网络分帧：长度 1025 坏掉，坏之前的整帧照样交出")

    // Ack 5
    let key = SymmetricKey(size: .bits256)
    let id = UUID()
    let a5 = PairingCrypto.makeAck(phoneID: id, counter: 9, status: .notAllowedOnNetwork, key: key)
    let ack5 = try? PairingCrypto.Ack(decoding: a5)
    netExpect(a5.count == 59 && ack5?.status == .notAllowedOnNetwork && ack5.map { PairingCrypto.verifyAck($0, key: key) } == true,
              "Ack 5：带签名、验得过")
    netExpect(!PairingCrypto.verifyAck(PairingCrypto.Ack(phoneID: id, counter: 9, status: .notAllowedOnNetwork, mac: nil), key: key)
              && !PairingCrypto.verifyAck(PairingCrypto.Ack(phoneID: id, counter: 9, status: .accepted, mac: ack5?.mac), key: key),
              "Ack 5：去掉签名 / 把状态改成 0 验不过")

    // NetworkPolicy
    for c in ["ping", "PING", "away", "awake:off", "awake:1h", "awake:2h", "awake:5h", "awake:always", "AWAKE:1H", "name:小明", "name:"] {
        netExpect(NetworkPolicy.allows(command: c), "白名单：\(c) 允许")
    }
    for c in ["hide", "preview", "unpair", "settings", "pairselftest", "awake:3h", "awake:", "awake", "", "Hide", "ping ", "n1:", "lift", "unlock", "away "] {
        netExpect(!NetworkPolicy.allows(command: c), "白名单：「\(c)」拒绝（默认拒绝）")
    }
    let nonce = PairingCrypto.makeNonce()
    let wrapped = NetworkCommand.wrap("away", nonce: nonce)
    netExpect(wrapped.count == 3 + 32 + 1 + 4 && NetworkCommand.unwrap(wrapped)?.nonce == nonce
              && NetworkCommand.unwrap(wrapped)?.command == "away", "n1: 包装：nonce 和命令拆得回来")
    netExpect(NetworkCommand.unwrap("away")?.nonce == nil && NetworkCommand.unwrap("n1:zz:away") == nil
              && NetworkCommand.unwrap("n1:" + String(repeating: "a", count: 31) + ":away") == nil
              && NetworkCommand.unwrap("n1:" + String(repeating: "a", count: 32) + "away") == nil, "n1: 包装：格式不对返回 nil")
    netExpect(NetworkCommand.unwrap("n1:" + NetworkCommand.hex(nonce) + ":name:a:b")?.command == "name:a:b", "n1: 包装：命令里再有冒号没关系")

    // 权威端：via: .network
    var authLog: [String] = []
    let store = MemoryPairingStore()
    let phone = UUID()
    let pkey = SymmetricKey(size: .bits256)
    _ = store.save(PairingRecord(key: pkey, lastCounter: 0), for: phone)
    var now = Date()
    let mac = PairingAuthority(store: store, log: { authLog.append($0) })
    mac.clock = { now }
    var counter: UInt64 = 0
    func seal(_ cmd: String) -> Data { counter += 1; return PairingCrypto.sealCommand(cmd, phoneID: phone, counter: counter, key: pkey)! }
    func pollNonce() -> Data? { mac.networkPollMessage(for: phone).flatMap { PairingCrypto.openPoll($0, phoneID: phone, key: pkey) } }
    func ackStatus(_ o: PairingAuthority.CommandOutcome) -> PairingCrypto.AckStatus? {
        switch o {
        case .accepted(_, _, _, _, let a): return (try? PairingCrypto.Ack(decoding: a))?.status
        case .rejected(_, _, let a): return a.flatMap { try? PairingCrypto.Ack(decoding: $0) }?.status
        }
    }
    func ackOf(_ o: PairingAuthority.CommandOutcome) -> PairingCrypto.Ack? {
        switch o {
        case .accepted(_, _, _, _, let a): return try? PairingCrypto.Ack(decoding: a)
        case .rejected(_, _, let a): return a.flatMap { try? PairingCrypto.Ack(decoding: $0) }
        }
    }
    func reason(_ o: PairingAuthority.CommandOutcome) -> PairingAuthority.RejectReason? {
        if case .rejected(let r, _, _) = o { return r }
        return nil
    }

    // ping 不要 nonce
    let p1 = mac.handleCommand(seal("ping"), via: .network)
    var pingOK = false
    if case .accepted(let c, _, _, let confirmed, _) = p1 { pingOK = c == "ping" && !confirmed }
    netExpect(pingOK, "网络命令：签名的 ping 收下，不要 nonce")
    // away 用 nonce
    let n1 = pollNonce()!
    let away = mac.handleCommand(seal(NetworkCommand.wrap("away", nonce: n1)), via: .network)
    var awayOK = false
    if case .accepted(let c, _, _, _, _) = away { awayOK = c == "away" }
    netExpect(awayOK && ackStatus(away) == .accepted, "网络命令：n1:<nonce>:away 收下，交出去的是 away")
    // 同一个 nonce 再用：Ack 2
    let reuse = mac.handleCommand(seal(NetworkCommand.wrap("away", nonce: n1)), via: .network)
    netExpect(reason(reuse) == .badNonce && ackStatus(reuse) == .replay, "网络命令：nonce 用第二次 → Ack 2")
    // 没带 nonce
    let bare = mac.handleCommand(seal("away"), via: .network)
    netExpect(reason(bare) == .badNonce && ackStatus(bare) == .replay, "网络命令：away 不带 nonce → Ack 2")
    // 没发过的 nonce
    let fake = mac.handleCommand(seal(NetworkCommand.wrap("away", nonce: PairingCrypto.makeNonce())), via: .network)
    netExpect(reason(fake) == .badNonce, "网络命令：Mac 没发过的 nonce → Ack 2")
    // 过期
    let n2 = pollNonce()!
    now = now.addingTimeInterval(PairingAuthority.networkNonceLifetime + 1)
    let stale = mac.handleCommand(seal(NetworkCommand.wrap("awake:1h", nonce: n2)), via: .network)
    netExpect(reason(stale) == .badNonce && ackStatus(stale) == .replay, "网络命令：过期的 nonce → Ack 2")
    // 同时留几个，超过上限最旧的作废
    let many = (0..<(PairingAuthority.networkNonceLimit + 1)).map { _ in pollNonce()! }
    let oldest = mac.handleCommand(seal(NetworkCommand.wrap("away", nonce: many[0])), via: .network)
    let newest = mac.handleCommand(seal(NetworkCommand.wrap("away", nonce: many.last!)), via: .network)
    netExpect(reason(oldest) == .badNonce && ackStatus(newest) == .accepted, "网络命令：每台手机只留最近 \(PairingAuthority.networkNonceLimit) 个 nonce")
    // name / awake
    let n3 = pollNonce()!
    var nameOK = false
    if case .accepted(let c, _, _, _, _) = mac.handleCommand(seal(NetworkCommand.wrap("name:小明的 iPhone", nonce: n3)), via: .network) {
        nameOK = c == "name:小明的 iPhone"
    }
    netExpect(nameOK, "网络命令：name: 收下，大小写不动")

    // 禁止的命令：签名对、计数照记，但 Ack 5，不要 nonce 也不耗 nonce
    for cmd in ["hide", "unpair", "preview", "settings", "pairselftest", "awake:9h"] {
        let n = pollNonce()!
        let before = store.load(phone)!.lastCounter
        for wrapIt in [false, true] {
            let o = mac.handleCommand(seal(wrapIt ? NetworkCommand.wrap(cmd, nonce: n) : cmd), via: .network)
            netExpect(reason(o) == .networkForbidden && ackStatus(o) == .notAllowedOnNetwork
                      && (ackOf(o).map { PairingCrypto.verifyAck($0, key: pkey) } == true),
                      "网络命令：签了名的 \(cmd)\(wrapIt ? "（带 nonce）" : "") → 签名的 Ack 5")
        }
        netExpect(store.load(phone)!.lastCounter == before + 2, "网络命令：\(cmd) 的计数照记（重放不了）")
        // 没被禁止的 nonce 没被耗掉
        let ok = mac.handleCommand(seal(NetworkCommand.wrap("away", nonce: n)), via: .network)
        netExpect(ackStatus(ok) == .accepted, "网络命令：被拒的 \(cmd) 没耗掉 nonce")
    }
    // 同一条蓝牙上签的 hide 拿到网络上也拒绝，在蓝牙上则照旧收下
    let btHide = seal("hide")
    var btOK = false
    if case .accepted(let c, _, _, _, _) = mac.handleCommand(btHide, via: .bluetooth) { btOK = c == "hide" }
    netExpect(btOK, "蓝牙：hide 照旧收下（行为没变）")
    netExpect(reason(mac.handleCommand(btHide, via: .network)) == .replay, "网络：蓝牙上用过的帧重放 → Ack 2")
    let replayNet = mac.handleCommand(seal("hide"), via: .network)
    netExpect(ackStatus(replayNet) == .notAllowedOnNetwork, "网络：新签的 hide → Ack 5")
    // 蓝牙的 away 不要 nonce
    var btAway = false
    if case .accepted(let c, _, _, _, _) = mac.handleCommand(seal("away"), via: .bluetooth) { btAway = c == "away" }
    netExpect(btAway, "蓝牙：away 不要 nonce（行为没变）")
    // 默认参数就是蓝牙
    var defaultBT = false
    if case .accepted(let c, _, _, _, _) = mac.handleCommand(seal("unpair")) { defaultBT = c == "unpair" }
    netExpect(defaultBT, "默认参数 = 蓝牙")

    // 计数：网络上重放
    let c1 = seal("ping")
    _ = mac.handleCommand(c1, via: .network)
    netExpect(reason(mac.handleCommand(c1, via: .network)) == .replay, "网络命令：计数重放 → Ack 2")
    // 签名不对 / 陌生手机
    let forged = PairingCrypto.sealCommand("ping", phoneID: phone, counter: 9_999, key: SymmetricKey(size: .bits256))!
    netExpect(reason(mac.handleCommand(forged, via: .network)) == .badSignature && ackStatus(mac.handleCommand(forged, via: .network)) == .unknownOrBadSignature
              && store.load(phone)!.lastCounter < 9_999, "网络命令：别的钥匙签的 → Ack 1，计数不动")
    let stranger = PairingCrypto.sealCommand("ping", phoneID: UUID(), counter: 1, key: pkey)!
    netExpect(reason(mac.handleCommand(stranger, via: .network)) == .unknownPhone, "网络命令：陌生手机 → Ack 1")

    // pending（握手过了还没确认）的钥匙网络上不认
    let mac2 = PairingAuthority(store: MemoryPairingStore(), log: { _ in })
    mac2.openWindow(code: "123456")
    let pendingPhone = UUID()
    if let hk = PairingSelfTest.handshake(mac2, code: "123456", phoneID: pendingPhone).phoneKey {
        let pingPending = PairingCrypto.sealCommand("ping", phoneID: pendingPhone, counter: 1, key: hk)!
        netExpect(reason(mac2.handleCommand(pingPending, via: .network)) == .unknownPhone && !mac2.isPaired,
                  "网络命令：还没确认的 pending 钥匙不认，也不会因此配上")
        var btConfirm = false
        if case .accepted(_, _, _, let confirmed, _) = mac2.handleCommand(pingPending, via: .bluetooth) { btConfirm = confirmed }
        netExpect(btConfirm && mac2.isPaired, "蓝牙：同一把 pending 钥匙的第一条命令照旧确认配对")
    } else {
        netExpect(false, "网络命令：pending 测试的握手没成")
    }

    // 配对消息走网络 → malformed，不动码、不耗次数
    let mac3 = PairingAuthority(store: MemoryPairingStore(), log: { _ in })
    mac3.openWindow(code: "654321")
    let req = PairingCrypto.phoneStart(code: "654321", phoneID: UUID())!.request.encoded()
    var pairRefused = false
    if case .malformed = mac3.handlePair(req, via: .network) { pairRefused = true }
    netExpect(pairRefused && mac3.attemptsLeft == PairingCrypto.maxCodeAttempts && mac3.code == "654321",
              "配对走网络：拒绝，码和错码次数不动")
    var pairBT = false
    if case .responded = mac3.handlePair(req) { pairBT = true }
    netExpect(pairBT, "配对走蓝牙：照旧")

    // Presence / LiftNow 走网络 → 拒绝，计数不耗
    let before = store.load(phone)!.lastCounter
    counter = before + 1
    let liftNow = PairingCrypto.sealLiftNow(nonce: PairingCrypto.makeNonce(), phoneID: phone, counter: counter, key: pkey)!
    let presence = PairingCrypto.sealPresence(.unlocked, nonce: pollNonce()!, phoneID: phone, counter: counter + 1, key: pkey)!
    for (name, m) in [("LiftNow", liftNow), ("Presence", presence)] {
        var refused = false
        if case .rejected(.networkForbidden, _) = mac.handleAnswer(m, via: .network) { refused = true }
        netExpect(refused && store.load(phone)!.lastCounter == before, "\(name) 走网络：拒绝，计数不耗")
    }
    var liftBT = false
    if case .accepted = mac.handleAnswer(liftNow, via: .bluetooth) { liftBT = true }
    netExpect(liftBT, "LiftNow 走蓝牙：照旧收下")

    // 撤销之后 nonce 作废
    let nr = pollNonce()!
    _ = mac.revoke(phone)
    netExpect(reason(mac.handleCommand(seal(NetworkCommand.wrap("away", nonce: nr)), via: .network)) == .unknownPhone, "撤销之后：这台手机的网络命令被拒")
}
runNetworkTests()

print(lines.joined(separator: "\n"))
exit(passed ? 0 : 1)
