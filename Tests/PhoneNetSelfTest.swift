// PhoneNetSelfTest.swift —— 手机走网络（TCP）的自测：真的 NetworkGateway 听在 127.0.0.1 的随机端口，真的 PhoneNetClient 连上去
//
// 不碰蓝牙、不碰钥匙串（MemoryPairingStore）、不碰真实网卡；有一部分用原始 TCP 连接手写帧（模拟坏手机 / 假服务器）。
// 运行（verify.sh 里也有；要沙箱外跑，Network.framework 在沙箱里连本机会被拒）：
//   cp Tests/PhoneNetSelfTest.swift /tmp/pn/main.swift
//   xcrun swiftc -o /tmp/pn/t /tmp/pn/main.swift Sources/CPace.swift Sources/PairingCrypto.swift Sources/PairingAuthority.swift Sources/LiftGate.swift Sources/ReconnectPolicy.swift Sources/PhoneNetwork.swift Sources/PhoneNetClient.swift
//   /tmp/pn/t
// 网关和客户端都跑在主队列上，测试代码用 RunLoop 转着等。

import CryptoKit
import Foundation
import Network

var results: [String] = []
var failures = 0

func expect(_ ok: Bool, _ name: String) {
    results.append("\(ok ? "PASS" : "FAIL")  \(name)")
    if !ok { failures += 1; print("FAIL  \(name)") }
}

/// 转着 RunLoop 等条件成立
@discardableResult
func waitUntil(_ seconds: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() {
        if Date() > deadline { return false }
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    return true
}

/// 转着 RunLoop 睡一会儿
func pause(_ seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
}

// 看门狗：整个自测不该超过 2 分钟
DispatchQueue.global().asyncAfter(deadline: .now() + 120) {
    print("FAIL  自测超时")
    exit(2)
}

// MARK: - 原始 TCP 连接（手写帧）

final class RawLink {
    let nw: NWConnection
    var reader = NetFraming.Reader()
    var frames: [Data] = []
    var closed = false
    var connected = false

    init(port: UInt16) {
        nw = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        nw.stateUpdateHandler = { [weak self] s in
            switch s {
            case .ready: self?.connected = true
            case .failed, .cancelled, .waiting: self?.closed = true
            default: break
            }
        }
        nw.start(queue: .main)
        receive()
    }

    private func receive() {
        nw.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.frames += self.reader.feed(data) }
            if complete || error != nil { self.closed = true; return }
            self.receive()
        }
    }

    func sendRaw(_ bytes: Data) { nw.send(content: bytes, completion: .contentProcessed { _ in }) }
    func send(_ message: Data) { sendRaw(NetFraming.frame(message)!) }
    func close() { nw.cancel(); closed = true }

    var acks: [PairingCrypto.Ack] { frames.compactMap { try? PairingCrypto.Ack(decoding: $0) } }
    func ack(_ counter: UInt64) -> PairingCrypto.Ack? { acks.first { $0.counter == counter } }
    func count(_ kind: PairingCrypto.Kind) -> Int { frames.filter { PairingCrypto.kind(of: $0) == kind }.count }
}

/// 一台手机（自己的标识 + 钥匙 + 计数），已经在 store 里配好
final class TestPhone {
    let id = UUID()
    let key = SymmetricKey(size: .bits256)
    var counter: UInt64 = 0

    init(store: MemoryPairingStore) { _ = store.save(PairingRecord(key: key, lastCounter: 0), for: id) }

    func command(_ text: String, nonce: Data? = nil) -> Data {
        counter += 1
        let wire = nonce.map { NetworkCommand.wrap(text, nonce: $0) } ?? text
        return PairingCrypto.sealCommand(wire, phoneID: id, counter: counter, key: key)!
    }

    /// 这条连接上最近一条 Poll 里的 nonce
    func lastNonce(in link: RawLink) -> Data? {
        link.frames.reversed().lazy.compactMap { PairingCrypto.openPoll($0, phoneID: self.id, key: self.key) }.first
    }

    func verifies(_ ack: PairingCrypto.Ack?) -> Bool {
        ack.map { PairingCrypto.verifyAck($0, key: key) } ?? false
    }
}

// MARK: - 搭网关

let defaults = UserDefaults(suiteName: "dev.local.lockcurtain.phonenetselftest")!
defaults.removePersistentDomain(forName: "dev.local.lockcurtain.phonenetselftest")

let store = MemoryPairingStore()
let authority = PairingAuthority(store: store, log: { _ in })
var clockOffset: TimeInterval = 0
authority.clock = { Date().addingTimeInterval(clockOffset) }

let gateway = NetworkGateway(authority: authority, port: .ephemeral, loopbackOnly: true, defaults: defaults)
var received: [(command: String, phone: UUID)] = []
var coverAllowed = true
var curtainIsClosed = false
var awakeMode = PairingCrypto.KeepAwakeMode.off
var peerChanges = 0
var identified: [UUID] = []
gateway.canCover = { coverAllowed }
gateway.onCommand = { cmd, id in
    received.append((cmd, id))
    if cmd.hasPrefix("awake:") { awakeMode = cmd == "awake:off" ? .off : .timed }
}
gateway.curtainClosed = { curtainIsClosed }
gateway.keepAwakeState = { (awakeMode, awakeMode == .timed ? UInt64(Date().timeIntervalSince1970) + 3600 : 0, "") }
gateway.onPeersChanged = { peerChanges += 1 }
gateway.onPeerIdentified = { identified.append($0) }
gateway.start()
expect(waitUntil { gateway.port != nil }, "网关：起来了，听在随机端口")
guard let port = gateway.port else {
    print(results.joined(separator: "\n"))
    print("结论：网关没起来，后面的测不了")
    exit(1)
}
expect(gateway.status == .listening(port: port), "网关：状态是 listening(port)")

// MARK: - 真的客户端

let phone = TestPhone(store: store)
let client = PhoneNetClient()
client.reserveCounter = { phone.counter += 1; return phone.counter }
client.key = { phone.key }
client.phoneID = { phone.id }
var clientMessages: [Data] = []
var clientStates: [PhoneNetClient.State] = []
client.onMessage = { clientMessages.append($0) }
client.onStateChange = { clientStates.append($0) }

func clientAcks() -> [PairingCrypto.Ack] { clientMessages.compactMap { try? PairingCrypto.Ack(decoding: $0) } }
func clientAck(_ counter: UInt64) -> PairingCrypto.Ack? { clientAcks().first { $0.counter == counter } }
func clientStates(_ closed: Bool) -> Int {
    clientMessages.filter { PairingCrypto.openState($0, phoneID: phone.id, key: phone.key)?.closed == closed }.count
}
func clientKeepAwakes() -> [(mode: UInt8, endsAt: UInt64)] {
    clientMessages.compactMap { PairingCrypto.openKeepAwakeState($0, phoneID: phone.id, key: phone.key) }.map { ($0.mode, $0.endsAt) }
}
/// 发一条命令，等它的 Ack
@discardableResult
func sendAndAwait(_ text: String) -> PairingCrypto.Ack? {
    var result: PhoneNetClient.SendResult?
    client.send(text) { result = $0 }
    guard waitUntil(3, { result != nil }), case .sent(let counter)? = result else { return nil }
    guard waitUntil(3, { clientAck(counter) != nil }) else { return nil }
    return clientAck(counter)
}
/// 等客户端攒到一条新的 nonce（发完一条命令后要等下一条 Poll）
func settle() { pause(0.15) }

client.start(host: "127.0.0.1", port: port)
expect(waitUntil { client.isReady }, "客户端：连上、发 ping、等到签名的 Ack，进入 ready")
expect(waitUntil { gateway.peers.map { $0.phoneID } == [phone.id] }, "网关：peers 里有这台手机")
expect(identified == [phone.id], "网关：onPeerIdentified 回调了一次")
expect(waitUntil { clientStates(false) >= 1 && clientKeepAwakes().count >= 1 }, "ping：Ack 0 + State + KeepAwakeState 都收到了")
expect(clientAck(1)?.status == .accepted && phone.verifies(clientAck(1)), "ping：Ack 0 带签名")
expect(received.isEmpty, "ping：不交给 onCommand")

// MARK: 放行的命令

var ack = sendAndAwait("away")
expect(ack?.status == .accepted && phone.verifies(ack) && received.last?.command == "away" && received.last?.phone == phone.id,
       "away：Ack 0，onCommand 收到 away")
settle()
coverAllowed = false
let beforeCount = received.count
ack = sendAndAwait("away")
expect(ack?.status == .missingPermission && phone.verifies(ack) && received.count == beforeCount,
       "away 缺辅助功能：签名的 Ack 4，onCommand 不触发")
coverAllowed = true
settle()

let awakesBefore = clientKeepAwakes().count
ack = sendAndAwait("awake:1h")
expect(ack?.status == .accepted && received.last?.command == "awake:1h", "awake:1h：Ack 0，onCommand 收到 awake:1h")
expect(waitUntil { clientKeepAwakes().count > awakesBefore } && clientKeepAwakes().last?.mode == PairingCrypto.KeepAwakeMode.timed.rawValue,
       "awake:1h：之后推一条 KeepAwakeState（定时）")
settle()
ack = sendAndAwait("awake:off")
expect(ack?.status == .accepted && waitUntil { clientKeepAwakes().last?.mode == 0 }, "awake:off：Ack 0，KeepAwakeState 变成关")
settle()
ack = sendAndAwait("name:小明的 iPhone")
expect(ack?.status == .accepted && received.last?.command == "name:小明的 iPhone", "name:：Ack 0，onCommand 收到原样的名字")
expect(waitUntil { gateway.peers.first?.name == "小明的 iPhone" }, "name:：peers 里的名字更新")
settle()

// 幕布状态推送
curtainIsClosed = true
gateway.reportCurtain(closed: true)
expect(waitUntil { clientStates(true) >= 1 }, "reportCurtain：盖上的 State 推给网络手机")
settle()

// MARK: 禁止的命令：签名的 Ack 5，onCommand 不触发，计数照记

let forbiddenStart = received.count
for cmd in ["hide", "unpair", "preview", "settings", "pairselftest", "awake:9h"] {
    let a = sendAndAwait(cmd)
    expect(a?.status == .notAllowedOnNetwork && phone.verifies(a), "禁止：签了名的 \(cmd) → 签名的 Ack 5")
    settle()
}
expect(received.count == forbiddenStart, "禁止：这些命令 onCommand 一次都没触发")
expect(client.isReady, "禁止：Ack 5 之后连接还在，仍然 ready")
ack = sendAndAwait("away")
expect(ack?.status == .accepted, "禁止之后：后面的 away 照常（Ack 5 没耗掉 nonce、计数接得上）")
settle()

// MARK: 原始连接：LiftNow / Presence / 配对帧

do {
    let p = TestPhone(store: store)
    let link = RawLink(port: port)
    expect(waitUntil { link.connected }, "原始连接：连上了")
    link.send(p.command("ping"))
    expect(waitUntil { link.ack(1) != nil && p.lastNonce(in: link) != nil }, "原始连接：ping → Ack + 一条签名的 Poll")
    expect(link.count(.state) == 1 && link.count(.keepAwakeState) == 1 && link.count(.poll) == 1, "原始连接：ping 的回复是 Ack、State、KeepAwakeState、Poll")
    let nonce = p.lastNonce(in: link)!

    p.counter += 1
    let lift = PairingCrypto.sealLiftNow(nonce: nonce, phoneID: p.id, counter: p.counter, key: p.key)!
    p.counter += 1
    let presence = PairingCrypto.sealPresence(.unlocked, nonce: nonce, phoneID: p.id, counter: p.counter, key: p.key)!
    let framesBefore = link.frames.count
    let cmdsBefore = received.count
    link.send(lift)
    link.send(presence)
    pause(0.4)
    expect(link.frames.count == framesBefore && !link.closed, "LiftNow / Presence：什么都不回、不断开（2 个坏帧）")
    expect(store.load(p.id)?.lastCounter == 1, "LiftNow / Presence：计数没被耗掉")
    expect(received.count == cmdsBefore, "LiftNow / Presence：onCommand 没触发")
    // 计数没耗：接着用 2 号发 ping 能成
    p.counter = 1
    link.send(p.command("ping"))
    expect(waitUntil { link.ack(2)?.status == .accepted }, "LiftNow / Presence 之后：同样的计数号还能用（没耗）")

    // 配对帧：不回话、不动码
    authority.openWindow(code: "135790")
    let q = PairingCrypto.phoneStart(code: "135790", phoneID: UUID())!.request.encoded()
    let link2 = RawLink(port: port)
    expect(waitUntil { link2.connected }, "配对帧：连上了")
    link2.send(q)
    pause(0.3)
    expect(link2.frames.isEmpty && authority.attemptsLeft == PairingCrypto.maxCodeAttempts && authority.code == "135790" && !link2.closed,
           "配对帧：不回话、不动码和错码次数")
    link2.send(q)
    link2.send(q)
    expect(waitUntil { link2.closed }, "配对帧：第 3 个坏帧断开连接")
    expect(waitUntil { gateway.isBanned("127.0.0.1") }, "配对帧：3 个坏帧后这个 IP 被封")
    authority.closeWindow()
    let banned = RawLink(port: port)
    expect(waitUntil { banned.closed }, "封禁：封着的 IP 新连接立刻被断")
    gateway.clearBans()
    link.close()
}

// MARK: 签名 / 陌生手机 / 坏帧

do {
    // 还没确认的 pending 钥匙：网络不认
    let hsCode = "246810"
    authority.openWindow(code: hsCode)
    let pendingID = UUID()
    let hs = PairingSelfTest.handshake(authority, code: hsCode, phoneID: pendingID)
    let pendingLink = RawLink(port: port)
    _ = waitUntil { pendingLink.connected }
    if let k = hs.phoneKey {
        pendingLink.send(PairingCrypto.sealCommand("ping", phoneID: pendingID, counter: 1, key: k)!)
        expect(waitUntil { pendingLink.ack(1)?.status == .unknownOrBadSignature }, "pending 钥匙：网络上 ping → Ack 1")
        expect(store.load(pendingID) == nil, "pending 钥匙：没有因此配上")
    } else {
        expect(false, "pending 钥匙：握手没成")
    }
    authority.closeWindow()
    pendingLink.close()
    // 同一条连接：陌生手机 / 乱码 / 签名错 → 第 3 个坏帧断开
    let link = RawLink(port: port)
    _ = waitUntil { link.connected }
    let stranger = PairingCrypto.sealCommand("ping", phoneID: UUID(), counter: 1, key: SymmetricKey(size: .bits256))!
    link.send(stranger)
    expect(waitUntil { link.acks.count >= 1 }, "陌生手机：Ack 1")
    link.send(Data("ping".utf8))
    pause(0.2)
    expect(!link.closed, "坏帧：2 个之后还没断")
    let known = TestPhone(store: store)
    var forged = [UInt8](known.command("ping"))
    forged[forged.count - 1] ^= 1
    link.send(Data(forged))
    expect(waitUntil { link.closed }, "坏帧：第 3 个（签名错）断开")
    expect(link.acks.allSatisfy { $0.status == .unknownOrBadSignature }, "坏帧：回的都是没签名的 Ack 1")
    expect(waitUntil { gateway.isBanned("127.0.0.1") }, "坏帧：IP 被封")
    gateway.clearBans()
}

// MARK: 重放 / nonce

do {
    let p = TestPhone(store: store)
    let link = RawLink(port: port)
    _ = waitUntil { link.connected }
    let first = p.command("ping")
    link.send(first)
    _ = waitUntil { p.lastNonce(in: link) != nil }
    link.send(first)
    expect(waitUntil { link.ack(1)?.status == .accepted && link.acks.contains { $0.counter == 1 && $0.status == .replay } }, "重放：同一帧再来一次 → Ack 2")

    // nonce：正确用一次 → 0，再用 → 2；没发过的 → 2；不带 → 2；过期 → 2
    let n = p.lastNonce(in: link)!
    link.send(p.command("away", nonce: n))
    expect(waitUntil { link.ack(2)?.status == .accepted && phoneHas("away", p.id) }, "nonce：n1:<nonce>:away → Ack 0，交出去的是 away")
    link.send(p.command("away", nonce: n))
    expect(waitUntil { link.ack(3)?.status == .replay }, "nonce：同一个 nonce 用第二次 → Ack 2")
    link.send(p.command("away", nonce: PairingCrypto.makeNonce()))
    expect(waitUntil { link.ack(4)?.status == .replay }, "nonce：电脑没发过的 nonce → Ack 2")
    link.send(p.command("away"))
    expect(waitUntil { link.ack(5)?.status == .replay }, "nonce：away 不带 nonce → Ack 2")
    let n2 = p.lastNonce(in: link)!
    clockOffset = PairingAuthority.networkNonceLifetime + 5
    link.send(p.command("away", nonce: n2))
    expect(waitUntil { link.ack(6)?.status == .replay }, "nonce：过期的 nonce → Ack 2")
    clockOffset = 0
    expect(link.acks.filter { $0.status == .replay }.count == 5 && !link.closed, "nonce / 重放：这些都不算坏帧，连接还在")
    expect(waitUntil { link.count(.poll) >= 5 }, "nonce：被拒之后电脑又给了新的 Poll")
    link.close()
}

func phoneHas(_ command: String, _ id: UUID) -> Bool { received.contains { $0.command == command && $0.phone == id } }

// 客户端自己从 Ack 2 里恢复：电脑把 nonce 当过期，客户端补一条 ping 再发
do {
    let pingsBefore = clientAcks().filter { $0.status == .accepted }.count
    clockOffset = PairingAuthority.networkNonceLifetime + 5
    var result: PhoneNetClient.SendResult?
    client.send("away") { result = $0 }
    _ = waitUntil { result != nil }
    expect(waitUntil { clientAcks().contains { $0.status == .replay } }, "客户端：电脑说 nonce 过期 → Ack 2")
    clockOffset = 0
    expect(waitUntil { clientAcks().filter { $0.status == .accepted }.count > pingsBefore }, "客户端：收到 Ack 2 自动补一条 ping")
    settle()
    ack = sendAndAwait("away")
    expect(ack?.status == .accepted, "客户端：恢复之后命令照常")
    settle()
}

// MARK: 帧大小、拼帧

do {
    for (name, header) in [("长度 0", Data([0, 0])), ("长度 1025", Data([0x04, 0x01])), ("长度 65535", Data([0xFF, 0xFF]))] {
        let link = RawLink(port: port)
        _ = waitUntil { link.connected }
        link.sendRaw(header)
        expect(waitUntil { link.closed }, "帧大小：\(name) → 断开")
    }
    // 1024 正好可以（内容不是合法消息，算坏帧但不断开）
    let link = RawLink(port: port)
    _ = waitUntil { link.connected }
    link.sendRaw(Data([0x04, 0x00]) + Data(count: 1024))
    pause(0.3)
    expect(!link.closed, "帧大小：1024 字节的帧是允许的长度（内容不对只算一个坏帧）")
    link.close()
    gateway.clearBans()

    // 一个字节一个字节地写
    let p = TestPhone(store: store)
    let slow = RawLink(port: port)
    _ = waitUntil { slow.connected }
    for byte in NetFraming.frame(p.command("ping"))! {
        slow.sendRaw(Data([byte]))
        pause(0.005)
    }
    expect(waitUntil { slow.ack(1)?.status == .accepted }, "拼帧：一个字节一个字节写，照样认")
    // 两条粘在一起 + 第三条只来一半
    let a = NetFraming.frame(p.command("ping"))!
    let b = NetFraming.frame(p.command("ping"))!
    let c = NetFraming.frame(p.command("ping"))!
    slow.sendRaw(a + b + c.prefix(10))
    expect(waitUntil { slow.ack(2) != nil && slow.ack(3) != nil }, "拼帧：粘在一起的两条都认")
    pause(0.15)
    expect(slow.ack(4) == nil, "拼帧：半条帧等着，不提前处理")
    slow.sendRaw(c.dropFirst(10))
    expect(waitUntil { slow.ack(4)?.status == .accepted }, "拼帧：后半条来了才处理")
    slow.close()
}

// MARK: 旧 Ack / 过期 State 由假服务器重放：客户端不能当成已连接

final class FakeServer {
    let listener: NWListener
    var conns: [NWConnection] = []
    var readers: [ObjectIdentifier: NetFraming.Reader] = [:]
    var onFrame: (NWConnection, Data) -> Void = { _, _ in }
    var port: UInt16 { listener.port!.rawValue }

    init() {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try! NWListener(using: params)
        listener.newConnectionHandler = { [unowned self] c in
            conns.append(c)
            c.start(queue: .main)
            pump(c)
        }
        listener.start(queue: .main)
    }

    func pump(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [unowned self] data, _, done, error in
            if let data {
                var r = readers[ObjectIdentifier(c)] ?? NetFraming.Reader()
                for f in r.feed(data) { onFrame(c, f) }
                readers[ObjectIdentifier(c)] = r
            }
            if !done && error == nil { pump(c) }
        }
    }

    func reply(_ c: NWConnection, _ message: Data) { c.send(content: NetFraming.frame(message)!, completion: .contentProcessed { _ in }) }
    func stop() { listener.cancel(); conns.forEach { $0.cancel() } }
}

do {
    let fp = TestPhone(store: MemoryPairingStore())
    let fake = FakeServer()
    _ = waitUntil { fake.listener.state == .ready }
    let oldAck = PairingCrypto.makeAck(phoneID: fp.id, counter: 1, status: .accepted, key: fp.key)      // 以前录下的：计数 1
    let staleState = PairingCrypto.makeState(closed: true, seq: UInt64((Date().timeIntervalSince1970 - 600) * 1000), phoneID: fp.id, key: fp.key)
    let oldPoll = PairingCrypto.makePoll(nonce: PairingCrypto.makeNonce(), phoneID: fp.id, key: fp.key)!
    var pingCounter: UInt64 = 0
    var sendRealAck = false
    fake.onFrame = { c, frame in
        guard let env = try? PairingCrypto.CommandEnvelope(decoding: frame) else { return }
        pingCounter = env.counter
        fake.reply(c, oldAck)
        fake.reply(c, oldPoll)
        fake.reply(c, staleState)
        if sendRealAck {
            fake.reply(c, PairingCrypto.makeAck(phoneID: fp.id, counter: env.counter, status: .accepted, key: fp.key))
            fake.reply(c, PairingCrypto.makeState(closed: true, seq: UInt64(Date().timeIntervalSince1970 * 1000), phoneID: fp.id, key: fp.key))
        }
    }
    let fc = PhoneNetClient()
    var fcounter: UInt64 = 10        // 以前的 Ack 的计数 1 对不上现在的 ping（11）
    fc.reserveCounter = { fcounter += 1; return fcounter }
    fc.key = { fp.key }
    fc.phoneID = { fp.id }
    var fmsgs: [Data] = []
    fc.onMessage = { fmsgs.append($0) }
    fc.start(host: "127.0.0.1", port: fake.port)
    expect(waitUntil { pingCounter == 11 }, "假服务器：客户端连上并发了 ping")
    pause(0.5)
    expect(!fc.isReady && fmsgs.isEmpty, "旧 Ack 重放：计数对不上，客户端不标 ready，也不交给上层")
    // 过期 State（10 分钟前）也不收；它上面的 Poll（没 ready）也不收
    expect(fmsgs.isEmpty, "过期 State（10 分钟前）重放：不交给上层")
    fc.stop()

    // 对照：同样的假服务器，这回回对得上的 Ack 和新鲜的 State → ready
    sendRealAck = true
    let fc2 = PhoneNetClient()
    var c2: UInt64 = 20
    fc2.reserveCounter = { c2 += 1; return c2 }
    fc2.key = { fp.key }
    fc2.phoneID = { fp.id }
    var f2msgs: [Data] = []
    fc2.onMessage = { f2msgs.append($0) }
    fc2.start(host: "127.0.0.1", port: fake.port)
    expect(waitUntil { fc2.isReady }, "对照：计数对得上的签名 Ack → ready")
    expect(waitUntil { f2msgs.contains { PairingCrypto.openState($0, phoneID: fp.id, key: fp.key) != nil } }, "对照：新鲜的 State 交给上层")
    expect(!f2msgs.contains { PairingCrypto.openState($0, phoneID: fp.id, key: fp.key)?.seq ?? .max < UInt64((Date().timeIntervalSince1970 - 100) * 1000) },
           "对照：过期的 State 仍然没交上去")
    fc2.stop()
    fake.stop()
}

// MARK: 5 秒内没有 ping、最多 4 条没验过的连接

do {
    let silent = (0..<4).map { _ in RawLink(port: port) }
    expect(waitUntil { silent.allSatisfy { $0.connected } }, "未验过的连接：4 条都连上")
    pause(0.1)
    let fifth = RawLink(port: port)
    expect(waitUntil { fifth.closed }, "未验过的连接：第 5 条被拒")
    expect(waitUntil { gateway.connectionCount >= 5 }, "未验过的连接：已验过的 + 4 条未验过的")
    let started = Date()
    expect(waitUntil(8) { silent.allSatisfy { $0.closed } }, "5 秒内没有验过的 ping → 断开")
    let took = Date().timeIntervalSince(started)
    expect(took > 3 && took < 7, "5 秒的计时：大约 5 秒（\(String(format: "%.1f", took)) 秒）")
}

// MARK: 撤销通知、断开后重连

do {
    clientMessages = []
    let before = gateway.peers.count
    expect(before == 1 || client.isReady, "（前置）客户端还连着")
    let notice = authority.revoke(phone.id)
    gateway.notifyRevoked(phone.id, notice: notice)
    expect(waitUntil { clientMessages.contains { PairingCrypto.verifyRevoke($0, phoneID: phone.id, key: phone.key) } }, "撤销：签名的撤销通知到了客户端")
    expect(waitUntil { gateway.peers.isEmpty }, "撤销：网络连接断开，peers 清空")
    client.stop()
    expect(waitUntil { client.state == .stopped }, "客户端：stop() 之后是 stopped")
}

do {
    // 断线重连：网关主动断开，客户端按退避重连
    let p = TestPhone(store: store)
    let rc = PhoneNetClient()
    rc.reserveCounter = { p.counter += 1; return p.counter }
    rc.key = { p.key }
    rc.phoneID = { p.id }
    var rstates: [PhoneNetClient.State] = []
    rc.onStateChange = { rstates.append($0) }
    rc.start(host: "127.0.0.1", port: port)
    expect(waitUntil { rc.isReady }, "重连：先连上")
    gateway.disconnect(p.id)
    expect(waitUntil { rstates.contains { if case .waiting(let d) = $0 { return d == 1 } else { return false } } }, "重连：断了 → 等 1 秒")
    let readyCount = rstates.filter { $0 == .ready }.count
    expect(waitUntil(5) { rstates.filter { $0 == .ready }.count > readyCount }, "重连：自动重连回来，再次 ready")
    rc.stop()
    // 地址连不上：退避 1 → 2 → 4
    let dead = PhoneNetClient()
    dead.reserveCounter = { 1 }
    dead.key = { p.key }
    dead.phoneID = { p.id }
    var dstates: [PhoneNetClient.State] = []
    dead.onStateChange = { dstates.append($0) }
    let freePort: UInt16 = {
        let l = try! NWListener(using: .tcp)
        l.start(queue: .main)
        _ = waitUntil { l.state == .ready }
        let p = l.port!.rawValue
        l.cancel()
        pause(0.2)
        return p
    }()
    dead.start(host: "127.0.0.1", port: freePort)
    let delays: () -> [TimeInterval] = { dstates.compactMap { if case .waiting(let d) = $0 { return d } else { return nil } } }
    expect(waitUntil(6) { delays().count >= 2 } && delays().prefix(2) == [1, 2], "重连：连不上时退避 1 秒 → 2 秒（\(delays())）")
    dead.stop()
}

// MARK: 空闲

do {
    gateway.idleTimeout = 1
    let p = TestPhone(store: store)
    let link = RawLink(port: port)
    _ = waitUntil { link.connected }
    link.send(p.command("ping"))
    _ = waitUntil { link.ack(1) != nil }
    expect(waitUntil(4) { link.closed }, "空闲：验过之后一直没有验过的帧 → 断开")
    gateway.idleTimeout = 120
}

// MARK: 重新配上的手机 / 同一台手机换连接

do {
    let p = TestPhone(store: store)
    let l1 = RawLink(port: port)
    _ = waitUntil { l1.connected }
    l1.send(p.command("ping"))
    _ = waitUntil { l1.ack(1) != nil }
    let l2 = RawLink(port: port)
    _ = waitUntil { l2.connected }
    l2.send(p.command("ping"))
    _ = waitUntil { l2.ack(2) != nil }
    expect(waitUntil { l1.closed } && !l2.closed && gateway.peers.filter { $0.phoneID == p.id }.count == 1, "同一台手机再连一条：旧连接让位")
    l2.close()
    _ = waitUntil { gateway.peers.isEmpty }
}

// MARK: stop()：连接断开、端口不再接受

do {
    let p = TestPhone(store: store)
    let l1 = RawLink(port: port)
    _ = waitUntil { l1.connected }
    l1.send(p.command("ping"))
    _ = waitUntil { l1.ack(1) != nil }
    let silent = RawLink(port: port)
    _ = waitUntil { silent.connected }
    expect(gateway.connectionCount >= 2, "stop（前置）：两条连接开着")
    gateway.stop()
    expect(waitUntil { gateway.status == .stopped }, "stop：状态 stopped")
    expect(waitUntil { l1.closed && silent.closed }, "stop：所有连接都被关了")
    expect(gateway.peers.isEmpty && gateway.connectionCount == 0, "stop：peers 清空")
    pause(0.3)
    let after = RawLink(port: port)
    expect(waitUntil { after.closed && !after.connected }, "stop：端口不再接受新连接")
    // 再开
    gateway.start()
    expect(waitUntil { gateway.port != nil }, "stop 之后可以再 start")
    gateway.stop()
    _ = waitUntil { gateway.status == .stopped }
}

// MARK: 端口持久化、地址枚举

do {
    let d = UserDefaults(suiteName: "dev.local.lockcurtain.phonenetselftest.port")!
    d.removePersistentDomain(forName: "dev.local.lockcurtain.phonenetselftest.port")
    let p1 = NetworkGateway.persistedPort(defaults: d)
    expect(NetworkGateway.portRange.contains(p1) && d.integer(forKey: "phoneNet.port") == Int(p1), "端口：第一次挑一个 49200–49999 的存进 phoneNet.port")
    expect((0..<20).allSatisfy { _ in NetworkGateway.persistedPort(defaults: d) == p1 }, "端口：以后一直用同一个")
    d.set(80, forKey: "phoneNet.port")
    let p2 = NetworkGateway.persistedPort(defaults: d)
    expect(NetworkGateway.portRange.contains(p2), "端口：存着的不在范围里就重挑")

    let g = NetworkGateway(authority: authority, port: .persisted, loopbackOnly: true, defaults: d)
    g.start()
    expect(waitUntil { g.port != nil } && g.port == UInt16(d.integer(forKey: "phoneNet.port")) && NetworkGateway.portRange.contains(g.port!),
           "端口：网关用存着的端口监听")
    let first = g.port
    g.stop()
    _ = waitUntil { g.status == .stopped }
    g.start()
    expect(waitUntil { g.port != nil } && g.port == first, "端口：关了再开还是同一个")
    g.stop()
    _ = waitUntil { g.status == .stopped }
    d.removePersistentDomain(forName: "dev.local.lockcurtain.phonenetselftest.port")
}

do {
    typealias E = NetworkAddressEntry
    func c(_ host: String, _ ifname: String, v6: Bool = false, type: NWInterface.InterfaceType? = nil) -> E? {
        NetworkAddresses.classify(host: host, interface: ifname, isIPv6: v6, type: type)
    }
    expect(c("192.168.1.20", "en0", type: .wifi)?.kind == .wifi, "地址：en0 + wifi → Wi-Fi")
    expect(c("10.0.0.5", "en5", type: .wiredEthernet)?.kind == .ethernet, "地址：有线 → 以太网")
    expect(c("100.101.102.103", "utun4")?.kind == .tailscale, "地址：utun 上 100.64/10 → Tailscale")
    expect(c("100.63.0.1", "utun4")?.kind == .other && c("100.128.0.1", "utun4")?.kind == .other, "地址：100.64/10 之外的 utun → 其他")
    expect(c("fd7a:115c:a1e0::1234", "utun4", v6: true)?.kind == .tailscale, "地址：Tailscale 的 IPv6 → Tailscale")
    expect(c("10.8.0.2", "utun2")?.kind == .other, "地址：别的 utun（VPN / Ponte）→ 其他")
    expect(c("172.16.0.9", "bridge0")?.kind == .other, "地址：没类型信息 → 其他")
    expect(c("127.0.0.1", "lo0") == nil && c("169.254.10.10", "en0") == nil && c("0.0.0.0", "en0") == nil, "地址：不要 127、169.254、0.0.0.0")
    expect(c("fe80::1", "en0", v6: true) == nil && c("::1", "lo0", v6: true) == nil && c("fe80::1%en0", "en0", v6: true) == nil, "地址：不要 fe80 和 ::1")
    expect(c("2409:8a00::1", "en0", v6: true, type: .wifi) != nil && c("fd12:3456::1", "en0", v6: true, type: .wifi) != nil, "地址：全局 IPv6 和 ULA 要")
    expect(c("2409:8a00::1%en0", "en0", v6: true, type: .wifi)?.host == "2409:8a00::1", "地址：IPv6 的 %网卡 后缀去掉")
    expect(c("2409:8a00::1", "en0", v6: true, type: .wifi)?.text(port: 49300) == "[2409:8a00::1]:49300"
           && c("192.168.1.20", "en0", type: .wifi)?.text(port: 49300) == "192.168.1.20:49300", "地址：IPv6 包方括号，IPv4 不包")
    expect(E.Kind.wifi.label == "Wi-Fi" && E.Kind.ethernet.label == "以太网" && E.Kind.tailscale.label == "Tailscale" && E.Kind.other.label == "其他", "地址：四个标签")
    let live = NetworkAddresses.current()
    expect(live.allSatisfy { !$0.host.hasPrefix("127.") && !$0.host.hasPrefix("169.254.") && !$0.host.lowercased().hasPrefix("fe80") && $0.interface != "lo0" },
           "地址：getifaddrs 枚举结果里没有 lo0 / 169.254 / fe80（\(live.count) 个）")
}

defaults.removePersistentDomain(forName: "dev.local.lockcurtain.phonenetselftest")
print(results.joined(separator: "\n"))
print(failures == 0 ? "结论：全通（\(results.count) 项）" : "结论：\(failures) 项没过")
exit(failures == 0 ? 0 : 1)
