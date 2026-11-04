// PhonePairingSelfTest.swift —— Mac 端「手机走网络」的接线自测：真的 PhonePairing（内存钥匙、独立 UserDefaults、
// 网关只听 127.0.0.1 的随机端口）+ 真的 PhoneNetClient。不碰蓝牙（不调 prepare()，不会创建 CBCentralManager）、
// 不碰钥匙串、不写真的 ble.log。
//
// 测什么：
//   * 纯模型：PhonePath 的优先级（蓝牙和网络都连着算蓝牙）、几台手机的链路合成、「已连上 · 网络/蓝牙」的文字
//   * 默认关；开关存进 UserDefaults；开了才监听，关了监听停、连接断、端口不再接受、手机显示没连上
//   * 网络命令走和蓝牙一样的处理：away 过 canCover（缺权限回 Ack 4、不盖）、awake:* 进 onKeepAwake（不重复报）、
//     name: 存名字；撤下 / 解除配对 / 预览 / 设置一律 Ack 5、不进任何处理
//   * 幕布 / 保持唤醒状态变了，网络手机也收到；在电脑上撤销手机，网络手机收到签名的撤销通知并断开
// 运行（verify.sh 里也有；要沙箱外跑）：
//   cp Tests/PhonePairingSelfTest.swift /tmp/pp/main.swift
//   xcrun swiftc -o /tmp/pp/t /tmp/pp/main.swift Sources/CPace.swift Sources/PairingCrypto.swift Sources/PairingAuthority.swift Sources/LiftGate.swift Sources/ReconnectPolicy.swift Sources/PhoneNetwork.swift Sources/PhoneNetClient.swift Sources/PhonePairing.swift
//   /tmp/pp/t

import CryptoKit
import Foundation
import Network

var results: [String] = []
var failures = 0

func expect(_ ok: Bool, _ name: String) {
    results.append("\(ok ? "PASS" : "FAIL")  \(name)")
    if !ok { failures += 1; print("FAIL  \(name)") }
}

@discardableResult
func waitUntil(_ seconds: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() {
        if Date() > deadline { return false }
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    return true
}

func pause(_ seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
}

DispatchQueue.global().asyncAfter(deadline: .now() + 90) {
    print("FAIL  自测超时")
    exit(2)
}

PhonePairing.logOverride = { _ in }

// MARK: - 纯模型

expect(PhonePath.resolve(bluetooth: true, network: false) == .bluetooth, "path：只有蓝牙 → 蓝牙")
expect(PhonePath.resolve(bluetooth: false, network: true) == .network, "path：只有网络 → 网络")
expect(PhonePath.resolve(bluetooth: true, network: true) == .bluetooth, "path：两条都连着 → 蓝牙")
expect(PhonePath.resolve(bluetooth: false, network: false) == nil, "path：都没连 → nil")
expect(PhonePath.common([]) == nil, "path.common：没有连着的 → nil")
expect(PhonePath.common([.network, .network]) == .network, "path.common：都是网络 → 网络")
expect(PhonePath.common([.bluetooth, .network]) == nil, "path.common：混着 → nil（只写「已连上」）")
expect(PhonePath.connectedText(.network) == "已连上 · 网络" && PhonePath.connectedText(.bluetooth) == "已连上 · 蓝牙"
       && PhonePath.connectedText(nil) == "已连上", "path：状态文字")

// MARK: - 搭 PhonePairing

final class TestPhone {
    let id = UUID()
    let key = SymmetricKey(size: .bits256)
    var counter: UInt64 = 0
    init(store: MemoryPairingStore) { _ = store.save(PairingRecord(key: key, lastCounter: 0), for: id) }
    func verifies(_ ack: PairingCrypto.Ack?) -> Bool { ack.map { PairingCrypto.verifyAck($0, key: key) } ?? false }
}

let suite = "dev.local.lockcurtain.phonepairingselftest"
let defaults = UserDefaults(suiteName: suite)!
defaults.removePersistentDomain(forName: suite)
let store = MemoryPairingStore()
let pairing = PhonePairing(store: store, defaults: defaults, networkPort: .ephemeral, networkLoopbackOnly: true)
let phone = TestPhone(store: store)
pairing.refreshPhones()

var covered: [String] = []
var keepAwakeCommands: [String] = []
var coverAllowed = true
var awakeMode = PairingCrypto.KeepAwakeMode.off
pairing.canCover = { coverAllowed }
pairing.onCommand = { covered.append($0) }
pairing.onKeepAwake = { cmd in
    keepAwakeCommands.append(cmd)
    awakeMode = cmd == "awake:off" ? .off : .timed
    return true
}
pairing.keepAwakeState = { (awakeMode, awakeMode == .timed ? UInt64(Date().timeIntervalSince1970) + 3600 : 0, "") }

expect(defaults.object(forKey: PhonePairing.networkDefaultsKey) == nil && !defaults.bool(forKey: PhonePairing.networkDefaultsKey),
       "默认：「走网络」没存过 = 关")
expect(!pairing.networkEnabled && pairing.networkStatus == .stopped && pairing.networkPort == nil
       && pairing.networkAddresses.isEmpty && pairing.networkPeers.isEmpty, "默认：没开，没监听，没地址")
expect(pairing.phones.count == 1 && pairing.phones[0].path == nil && !pairing.phones[0].connected, "默认：手机没连着，path 是 nil")

// 开关关着时往幕布 / 保持唤醒状态推也不出事
pairing.reportCurtainState("open")
pairing.reportKeepAwake()

// MARK: - 打开

pairing.setNetworkEnabled(true)
expect(defaults.bool(forKey: PhonePairing.networkDefaultsKey), "打开：存进 UserDefaults")
expect(waitUntil { pairing.networkPort != nil }, "打开：监听起来了，networkPort 有值")
guard let port = pairing.networkPort else {
    print(results.joined(separator: "\n"))
    print("结论：监听没起来，后面的测不了")
    exit(1)
}
expect(pairing.networkEnabled && pairing.networkStatus == .listening(port: port), "打开：networkStatus 是 listening(port)")

// 真的客户端
let client = PhoneNetClient()
client.reserveCounter = { phone.counter += 1; return phone.counter }
client.key = { phone.key }
client.phoneID = { phone.id }
var messages: [Data] = []
client.onMessage = { messages.append($0) }

func acks() -> [PairingCrypto.Ack] { messages.compactMap { try? PairingCrypto.Ack(decoding: $0) } }
func ack(_ counter: UInt64) -> PairingCrypto.Ack? { acks().first { $0.counter == counter } }
func states(closed: Bool) -> Int {
    messages.filter { PairingCrypto.openState($0, phoneID: phone.id, key: phone.key)?.closed == closed }.count
}
func keepAwakes() -> Int {
    messages.filter { PairingCrypto.openKeepAwakeState($0, phoneID: phone.id, key: phone.key) != nil }.count
}
func revokes() -> Int { messages.filter { PairingCrypto.kind(of: $0) == .revoke }.count }
func sendAndAwait(_ text: String) -> PairingCrypto.Ack? {
    var result: PhoneNetClient.SendResult?
    client.send(text) { result = $0 }
    guard waitUntil(3, { result != nil }), case .sent(let counter)? = result else { return nil }
    guard waitUntil(3, { ack(counter) != nil }) else { return nil }
    return ack(counter)
}

client.start(host: "127.0.0.1", port: port)
expect(waitUntil { client.isReady }, "客户端：ping 之后 ready")
expect(waitUntil { pairing.networkPeers.map(\.phoneID) == [phone.id] }, "networkPeers：有这台手机")
expect(waitUntil { pairing.phones.first?.connected == true }, "手机页：显示连着")
expect(pairing.phones.first?.path == .network && pairing.connectedPath == .network, "手机页：path 是网络")
expect(pairing.anyPhoneConnected, "anyPhoneConnected：网络手机算连着")
expect(waitUntil { pairing.phones.first?.lastSeen != nil }, "网络手机认出身份：记了「最后连上」")
expect(waitUntil { states(closed: false) >= 1 && keepAwakes() >= 1 }, "ping：State + KeepAwakeState 都收到")

// MARK: - 命令走和蓝牙一样的处理

pause(0.15)
var a = sendAndAwait("away")
expect(a?.status == .accepted && phone.verifies(a) && covered == ["away"], "away：Ack 0，onCommand 收到一次 away")
pause(0.15)
coverAllowed = false
a = sendAndAwait("away")
expect(a?.status == .missingPermission && phone.verifies(a) && covered == ["away"],
       "away 缺辅助功能：签名的 Ack 4，不盖（和蓝牙一样过 canCover）")
coverAllowed = true
pause(0.15)

let awakesBefore = keepAwakes()
a = sendAndAwait("awake:2h")
expect(a?.status == .accepted && keepAwakeCommands == ["awake:2h"], "awake:2h：进 onKeepAwake")
expect(waitUntil { keepAwakes() > awakesBefore }, "awake:2h：网络手机收到新的保持唤醒状态")
pause(0.3)
expect(keepAwakes() == awakesBefore + 1, "awake:2h：只报了一次（网关自己推，PhonePairing 不重复报）")
expect(!pairing.handlingAwake, "awake:*：处理完 handlingAwake 复位")
pause(0.15)

let beforeReport = keepAwakes()
pairing.reportKeepAwake()
expect(waitUntil { keepAwakes() > beforeReport }, "reportKeepAwake()：网络手机也收到（电脑上改的）")
pause(0.15)

pairing.reportCurtainState("closed")
expect(waitUntil { states(closed: true) >= 1 }, "reportCurtainState(closed)：网络手机收到 State(closed)")
pairing.reportCurtainState("open")
expect(waitUntil { states(closed: false) >= 2 }, "reportCurtainState(open)：网络手机收到 State(open)")

a = sendAndAwait("name:Camo 的 iPhone")
expect(a?.status == .accepted, "name：Ack 0")
expect(waitUntil { pairing.phones.first?.name == "Camo 的 iPhone" }, "name：存下来，手机页显示这个名字")
pause(0.15)

let keepBefore = keepAwakeCommands.count
let coveredBefore = covered.count
for forbidden in ["hide", "unpair", "preview", "settings"] {
    let r = sendAndAwait(forbidden)
    expect(r?.status == .notAllowedOnNetwork && phone.verifies(r), "\(forbidden)：签名的 Ack 5")
    pause(0.15)
}
expect(covered.count == coveredBefore && keepAwakeCommands.count == keepBefore, "撤下 / 解除配对 / 预览 / 设置：没进任何处理")
expect(pairing.phones.count == 1 && pairing.phones[0].connected, "网络上发 unpair：手机还在配对列表里")

// MARK: - 关掉

client.stop()
pairing.setNetworkEnabled(false)
expect(!defaults.bool(forKey: PhonePairing.networkDefaultsKey) && !pairing.networkEnabled, "关掉：存进 UserDefaults，networkEnabled 为 false")
expect(pairing.networkStatus == .stopped && pairing.networkPort == nil && pairing.networkAddresses.isEmpty
       && pairing.networkPeers.isEmpty, "关掉：状态 stopped，没端口、没地址、没手机")
expect(pairing.phones.first?.connected == false && pairing.phones.first?.path == nil, "关掉：手机页显示没连上")

final class Probe {
    var state = "waiting"
    let nw: NWConnection
    init(port: UInt16) {
        nw = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        nw.stateUpdateHandler = { [self] s in
            switch s {
            case .ready: state = "open"
            case .failed, .waiting: state = "refused"
            default: break
            }
        }
        nw.start(queue: .main)
    }
}
var probe: Probe? = Probe(port: port)
expect(waitUntil { probe?.state != "waiting" } && probe?.state == "refused", "关掉：旧端口不再接受连接（监听停了）")
probe?.nw.cancel()
probe = nil

// MARK: - 再打开，在电脑上撤销

messages.removeAll()
pairing.setNetworkEnabled(true)
expect(waitUntil { pairing.networkPort != nil }, "再打开：又监听起来了")
guard let port2 = pairing.networkPort else { print("结论：第二次没起来"); exit(1) }
client.start(host: "127.0.0.1", port: port2)
expect(waitUntil { client.isReady && pairing.phones.first?.path == .network }, "再打开：手机又连上，走网络")

pairing.unpair(phone.id)
expect(waitUntil { revokes() >= 1 }, "在电脑上撤销：网络手机收到签名的撤销通知")
let notice = messages.first { PairingCrypto.kind(of: $0) == .revoke }
expect(notice.map { PairingCrypto.verifyRevoke($0, phoneID: phone.id, key: phone.key) } ?? false, "撤销通知：签名验得过")
expect(waitUntil { pairing.networkPeers.isEmpty }, "在电脑上撤销：网络连接断了")
expect(pairing.phones.isEmpty, "在电脑上撤销：配对列表里没有了")

client.stop()
pairing.setNetworkEnabled(false)
pause(0.2)
defaults.removePersistentDomain(forName: suite)

print(results.joined(separator: "\n"))
print("PhonePairingSelfTest: \(results.count - failures) / \(results.count) passed")
exit(failures == 0 ? 0 : 1)
