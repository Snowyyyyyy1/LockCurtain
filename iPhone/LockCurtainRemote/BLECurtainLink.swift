// BLECurtainLink.swift —— 真的蓝牙连接（手机是外设，Mac 是中心）
//
// 手机广播 LockCurtain 的服务，Mac 来连、订阅「发件箱」：
//   * 发件箱（…5A70，notify + read）：手机 → Mac，配对请求、签名命令
//   * 收件箱（…5A71，write）       ：Mac → 手机，配对应答 / 拒绝、命令收据、幕布状态、撤销通知
// 每条消息按 PairingFraming 切块（块大小看 Mac 的 maximumUpdateValueLength）。
// 安全全在 PairingCrypto：配对用 6 位码的 CPace 握手（双向确认），命令带 HMAC 和递增计数。
//
// 屏幕上说的话全部来自 Mac 的回报，没有一处是猜的：
//   * 「已连接」= Mac 订阅了发件箱，并且 Mac 用共享钥匙签了收据（握手 / 身份确认真的成了）；
//   * 配对只有在 Mac 的应答验过、Mac 又签收了第一条命令之后才返回 accepted；
//   * 幕布状态靠 Mac 签名的状态消息，没收到就是没收到。
//
// Mac 订阅上又在握手之前断开，连续 5 次就停止广播、停在「找到了，但连不上」，等用户点「再试一次」。
//
// 撤下幕布：幕布盖着时 Mac 每 2 秒往收件箱写一条签名的问询（Poll + nonce；写入会把后台的 App 叫醒），
// 这里当场看 UIApplication.isProtectedDataAvailable，回一条签名的 Presence（解锁着 / 锁着 / 「走近撤下」关着），
// 不记时间、不靠解锁通知。「现在撤下」等下一条问询，用它的 nonce 回 LiftNow（代替那一次的 Presence）。
// 撤不撤由 Mac 判断（签名、计数、nonce、先锁过、距离），手机只如实回答。
//
// 服务 / 特征 UUID 必须和 Mac 端 PhonePairing 一致。

import CoreBluetooth
import CryptoKit
import Foundation
import OSLog
import UIKit

/// 一次配对请求卡在哪一步，界面按这个说话（copy v6.2 §8.5 的六句）
enum PairResult: Equatable {
    case accepted
    /// 一直没有 Mac 来连
    case notFound
    /// Mac 来连过但断了（或者连续断太多次，已经停了）
    case connectFailed
    /// Mac 明确说码不对
    case wrongCode
    /// Mac 收到了但没接受（不是码不对，是别的原因）
    case macRefused
    /// 发过去之后一直没有回音
    case noResponse
    /// 中途断开了
    case disconnected
}

@MainActor
final class BLECurtainLink: NSObject, CurtainLink {
    private(set) var snapshot: CurtainSnapshot
    var onSnapshotChange: ((CurtainSnapshot) -> Void)?
    /// Mac 发来签名的撤销通知、手机已经删了钥匙之后调用
    var onRevoked: (() -> Void)?

    /// 服务与特征：改这里就要同步改 Mac 端（Sources/PhonePairing.swift）
    /// 计算属性：CBUUID 不是 Sendable，存成静态常量会被并发检查拦下
    enum Identity {
        static var service: CBUUID { CBUUID(string: "E9A1B2C3-D4E5-4F60-8A7B-1C2D3E4F5A6B") }
        static var outbox: CBUUID { CBUUID(string: "E9A1B2C3-D4E5-4F60-8A7B-1C2D3E4F5A70") }
        static var inbox: CBUUID { CBUUID(string: "E9A1B2C3-D4E5-4F60-8A7B-1C2D3E4F5A71") }
        static let restoreIdentifier = "lc.peripheral"
        static let localName = "LockCurtain"
    }

    private static let maxEarlyDrops = 5

    private var manager: CBPeripheralManager?
    private var outbox: CBMutableCharacteristic?
    private var inbox: CBMutableCharacteristic?
    private var serviceAdded = false
    /// 订阅着发件箱的 Mac
    private var mac: CBCentral?
    /// 这次等待里 Mac 来连过没有（区分「没找到」和「找到了连不上」）
    private var macEverSubscribed = false
    /// 这次订阅里握手 / 身份确认成了没有
    private var ready = false
    private var isPaired: Bool
    private var assembler = PairingFraming.Assembler()
    private var sendQueue: [Data] = []
    private var lastStateSeq: UInt64 = 0

    private var consecutiveFailures = 0
    private(set) var gaveUp = false
    private var wantsAdvertising = false

    private enum Reply {
        case message(Data)
        case timeout
        case disconnected
    }
    private enum AckResult {
        case ok
        case rejected
        case failed
    }

    private var pendingReply: CheckedContinuation<Reply, Never>?
    private var replyTimeout: Task<Void, Never>?
    private var pendingAck: (counter: UInt64, cont: CheckedContinuation<AckResult, Never>)?
    private var ackTimeout: Task<Void, Never>?
    private var pendingCover: CheckedContinuation<CoverOutcome, Never>?
    private var coverTimeout: Task<Void, Never>?
    /// 「现在撤下」：等下一条问询；sentCounter = 已经发出去的 LiftNow 的计数，等 Mac 的结果
    private var pendingLift: (sentCounter: UInt64?, cont: CheckedContinuation<LiftOutcome, Never>)?
    private var liftTimeout: Task<Void, Never>?
    /// Mac 说「撤下了」，等它的「开着」状态到了再告诉界面
    private var awaitingLiftOpen = false
    private static let liftLog = Logger(subsystem: "LockCurtainRemote", category: "lift")
    /// 「现在撤下」最多等多久（Mac 每 2 秒问一次）
    private static let liftTimeoutSeconds: Double = 5

    init(paired: Bool, macName: String?) {
        isPaired = paired
        snapshot = CurtainSnapshot(
            connection: paired ? .notConnected : .notPaired,
            phase: .open,
            auto: .off,
            macName: paired ? macName : nil,
            isAway: false
        )
    }

    // MARK: - CurtainLink

    func activate() {
        wantsAdvertising = true
        if manager == nil {
            manager = CBPeripheralManager(delegate: self, queue: .main,
                                          options: [CBPeripheralManagerOptionShowPowerAlertKey: true,
                                                    CBPeripheralManagerOptionRestoreIdentifierKey: Identity.restoreIdentifier])
        } else {
            startAdvertising()
        }
    }

    /// 用户点了「再试一次」/ 重新打开配对：清掉连续失败计数，重新广播
    func resumeConnecting() {
        consecutiveFailures = 0
        if gaveUp {
            gaveUp = false
            publish { $0.gaveUpConnecting = false }
        }
        activate()
    }

    func cover() async -> CoverOutcome {
        guard mac != nil, ready, isPaired else { return .unavailable }
        publish { $0.phase = .closing }
        let ack = await sendSigned("away")
        guard ack == .ok else { return .timedOut }
        // 状态消息可能比这里先到
        if snapshot.phase == .closed { return .covered }
        return await withCheckedContinuation { cont in
            pendingCover = cont
            coverTimeout?.cancel()
            coverTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled else { return }
                self?.finishCover(.timedOut)
            }
        }
    }

    func setAutoEnabled(_ isOn: Bool) {
        // 自动盖幕布的判断在 Mac 上，手机只显示；还没有对应的命令
    }

    /// 「现在撤下」（调用方已经过了面容 / 密码）：等 Mac 的下一条问询，用它的 nonce 发签名的 LiftNow，
    /// 等 Mac 签名的结果。老版本的 Mac 不问询，就是超时。
    func liftNow() async -> LiftOutcome {
        guard mac != nil, ready, isPaired, LiftSetting.isOn, snapshot.phase == .closed else { return .unavailable }
        finishLift(.unavailable)
        Self.liftLog.info("lift-now requested; waiting for the next poll")
        return await withCheckedContinuation { cont in
            pendingLift = (nil, cont)
            liftTimeout?.cancel()
            liftTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.liftTimeoutSeconds))
                guard !Task.isCancelled else { return }
                Self.liftLog.info("lift-now timed out")
                self?.finishLift(.timedOut)
            }
        }
    }

    // MARK: - 配对

    /// 等 Mac 来连，走 CPace 握手：Mac 的 Tb 验过、Mac 验过我们的 Ta 并签了 PairAccepted，才存钥匙；
    /// Mac 又签收了第一条命令，才算配上。
    func pair(code: String) async -> PairResult {
        activate()
        if gaveUp { return .connectFailed }

        // Mac 还没订阅就等它来（最多 15 秒）
        if mac == nil {
            macEverSubscribed = false
            if let failure = await waitForMac(seconds: 15) { return failure }
        }
        guard mac != nil, let macID = mac?.identifier else { return .connectFailed }

        let phoneID = PhoneKeychain.phoneID()
        guard let (request, session) = PairingCrypto.phoneStart(code: code, phoneID: phoneID) else { return .macRefused }

        // 第一步：Ya → Mac，等 Yb 和 Mac 的确认标签 Tb
        let message: Data
        switch await requestReply(request.encoded(), seconds: 8) {
        case .timeout: return .noResponse
        case .disconnected: return .disconnected
        case .message(let data): message = data
        }
        if let reason = PairingCrypto.decodePairReject(message) {
            return reason == .wrongCode ? .wrongCode : .macRefused
        }
        guard let response = try? PairingCrypto.PairResponse(decoding: message) else { return .macRefused }
        let confirm: PairingCrypto.PairConfirm
        let key: SymmetricKey
        switch PairingCrypto.phoneFinish(response, session: session) {
        case .confirm(let c, let k):
            confirm = c
            key = k
        case .wrongCode:
            // Tb 不对：两边的码不一样。告诉 Mac 这一轮作废，什么都不存
            send(PairingCrypto.pairAbort(phoneID: phoneID, sid: session.sid))
            return .wrongCode
        case .invalid:
            send(PairingCrypto.pairAbort(phoneID: phoneID, sid: session.sid))
            return .macRefused
        }

        // 第二步：Ta → Mac，等 Mac 用新钥匙签的 PairAccepted，见到了才存钥匙
        let accepted: Data
        switch await requestReply(confirm.encoded(), seconds: 8) {
        case .timeout: return .noResponse
        case .disconnected: return .disconnected
        case .message(let data): accepted = data
        }
        if let reason = PairingCrypto.decodePairReject(accepted) {
            return reason == .wrongCode ? .wrongCode : .macRefused
        }
        guard PairingCrypto.verifyPairAccepted(accepted, phoneID: phoneID, sid: session.sid, key: key) else {
            return .macRefused
        }
        let record = PhoneLinkRecord(key: key.withUnsafeBytes { Data($0) },
                                     macIdentifier: macID.uuidString, counter: 0)
        guard PhoneKeychain.saveLink(record) else { return .macRefused }

        // 钥匙确认：Mac 收下这条签名的 ping、回一张签名收据，才说配上了
        switch await sendSigned("ping") {
        case .ok:
            isPaired = true
            markReady()
            return .accepted
        case .rejected, .failed:
            PhoneKeychain.deleteLink()
            return mac == nil ? .disconnected : .macRefused
        }
    }

    /// 手机这边解除配对：连着就先发一条签名的 unpair（Mac 收到会删它的钥匙），再删自己的钥匙
    func unpair() {
        if mac != nil, ready, let reserved = PhoneKeychain.reserveNextCounter(),
           let data = PairingCrypto.sealCommand("unpair", phoneID: PhoneKeychain.phoneID(), counter: reserved.counter,
                                                key: SymmetricKeyBox(reserved.record.key).key) {
            send(data)
        }
        PhoneKeychain.deleteLink()
        forgetLocally()
        // 没配对就不用一直广播：给那条 unpair 一点时间发出去再停
        wantsAdvertising = false
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !self.wantsAdvertising else { return }
            self.manager?.stopAdvertising()
        }
    }

    /// 等 Mac 订阅：返回 nil 表示到了，否则是卡在哪
    private func waitForMac(seconds: Double) async -> PairResult? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if gaveUp { return .connectFailed }
            if mac != nil { return nil }
            try? await Task.sleep(for: .milliseconds(200))
        }
        if mac != nil { return nil }
        return macEverSubscribed ? .connectFailed : .notFound
    }

    private func requestReply(_ message: Data, seconds: Double) async -> Reply {
        await withCheckedContinuation { cont in
            pendingReply = cont
            send(message)
            replyTimeout?.cancel()
            replyTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { return }
                self?.finishReply(.timeout)
            }
        }
    }

    /// 发一条签名命令，等 Mac 的签名收据。计数先写进钥匙串再发。
    private func sendSigned(_ command: String) async -> AckResult {
        guard mac != nil,
              let reserved = PhoneKeychain.reserveNextCounter() else { return .failed }
        let counter = reserved.counter
        let phoneID = PhoneKeychain.phoneID()
        let key = SymmetricKeyBox(reserved.record.key)
        guard let data = PairingCrypto.sealCommand(command, phoneID: phoneID, counter: counter, key: key.key) else {
            return .failed
        }
        finishAck(.failed)
        return await withCheckedContinuation { cont in
            pendingAck = (counter, cont)
            send(data)
            ackTimeout?.cancel()
            ackTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled else { return }
                self?.finishAck(.failed)
            }
        }
    }

    /// 已经配过对的手机：Mac 订阅上来就用签名的 ping 表明身份，Mac 签收了才算已连接
    private func confirmLink() async {
        let result = await sendSigned("ping")
        guard mac != nil else { return }
        switch result {
        case .ok:
            markReady()
        case .rejected, .failed:
            // 不认得我们（可能 Mac 那边撤销过）。没签名的拒绝谁都能伪造，所以不删钥匙，只是不说已连接。
            publish { $0.connection = .notConnected }
        }
    }

    private func markReady() {
        ready = true
        consecutiveFailures = 0
        publish { $0.connection = .connected }
    }

    private func forgetLocally() {
        isPaired = false
        ready = false
        lastStateSeq = 0
        finishCover(.unavailable)
        finishLift(.unavailable)
        awaitingLiftOpen = false
        publish {
            $0.connection = .notPaired
            $0.macName = nil
        }
    }

    // MARK: - 收尾

    private func finishReply(_ reply: Reply) {
        replyTimeout?.cancel()
        replyTimeout = nil
        let cont = pendingReply
        pendingReply = nil
        cont?.resume(returning: reply)
    }

    private func finishAck(_ result: AckResult) {
        ackTimeout?.cancel()
        ackTimeout = nil
        let pending = pendingAck
        pendingAck = nil
        pending?.cont.resume(returning: result)
    }

    private func finishLift(_ outcome: LiftOutcome) {
        liftTimeout?.cancel()
        liftTimeout = nil
        let pending = pendingLift
        pendingLift = nil
        pending?.cont.resume(returning: outcome)
    }

    private func finishCover(_ outcome: CoverOutcome) {
        coverTimeout?.cancel()
        coverTimeout = nil
        let cont = pendingCover
        pendingCover = nil
        cont?.resume(returning: outcome)
    }

    // MARK: - 收发

    private func send(_ message: Data) {
        guard let mac else { return }
        sendQueue.append(contentsOf: PairingFraming.chunks(message, maxChunk: mac.maximumUpdateValueLength))
        pump()
    }

    private func pump() {
        guard let manager, let outbox, let mac else { sendQueue.removeAll(); return }
        while let chunk = sendQueue.first {
            guard manager.updateValue(chunk, for: outbox, onSubscribedCentrals: [mac]) else { return }
            sendQueue.removeFirst()
        }
    }

    private func receive(_ message: Data) {
        switch PairingCrypto.kind(of: message) {
        case .pairResponse, .pairReject, .pairAccepted:
            finishReply(.message(message))
        case .ack:
            guard let ack = try? PairingCrypto.Ack(decoding: message),
                  let pending = pendingAck, ack.counter == pending.counter,
                  ack.phoneID == PhoneKeychain.phoneID() else { return }
            if ack.status == .accepted, let record = PhoneKeychain.loadLink(),
               PairingCrypto.verifyAck(ack, key: SymmetricKeyBox(record.key).key) {
                finishAck(.ok)
            } else {
                finishAck(ack.status == .unknownOrBadSignature ? .rejected : .failed)
            }
        case .state:
            guard let record = PhoneKeychain.loadLink(),
                  let state = PairingCrypto.openState(message, phoneID: PhoneKeychain.phoneID(),
                                                      key: SymmetricKeyBox(record.key).key),
                  state.seq > lastStateSeq else { return }
            lastStateSeq = state.seq
            let liftedByUs = !state.closed && awaitingLiftOpen
            if state.closed || liftedByUs { awaitingLiftOpen = false }
            publish {
                $0.phase = state.closed ? .closed : .open
                if liftedByUs { $0.phoneLiftCount += 1 }
            }
            if state.closed { finishCover(.covered) } else { finishLift(.lifted) }
        case .poll:
            answerPoll(message)
        case .liftResult:
            guard let record = PhoneKeychain.loadLink(),
                  let result = PairingCrypto.openLiftResult(message, phoneID: PhoneKeychain.phoneID(),
                                                            key: SymmetricKeyBox(record.key).key) else { return }
            Self.liftLog.info("lift result from Mac: status \(result.status.rawValue), counter \(result.counter)")
            if result.status == .lifted {
                if snapshot.phase == .closed {
                    awaitingLiftOpen = true
                } else {
                    publish { $0.phoneLiftCount += 1 }
                }
            }
            if let pending = pendingLift, pending.sentCounter == result.counter {
                switch result.status {
                case .lifted:
                    // 等 Mac 的「开着」状态到了再算撤下（界面要跟着 Mac 的回报走）
                    if snapshot.phase != .closed { finishLift(.lifted) }
                case .tooFar: finishLift(.tooFar)
                case .refused: finishLift(.refused)
                case .notCovered:
                    // Mac 签名说幕布本来就没盖着：界面跟着改成「没盖上」
                    publish { $0.phase = .open }
                    finishLift(.notCovered)
                }
            }
        case .revoke:
            guard let record = PhoneKeychain.loadLink(),
                  PairingCrypto.verifyRevoke(message, phoneID: PhoneKeychain.phoneID(),
                                             key: SymmetricKeyBox(record.key).key) else { return }
            PhoneKeychain.deleteLink()
            forgetLocally()
            onRevoked?()
        default:
            break
        }
    }

    /// 「现在撤下」没撤下来：用签名的 ping 让 Mac 再报一次幕布状态（老 Mac 也这样回）
    func requestState() {
        guard mac != nil, ready, isPaired else { return }
        Self.liftLog.info("asking the Mac for the curtain state")
        Task { [weak self] in _ = await self?.sendSigned("ping") }
    }

    /// Mac 的问询：签名验过才回。此刻解锁着没有，当场看系统的 isProtectedDataAvailable
    private func answerPoll(_ message: Data) {
        let phoneID = PhoneKeychain.phoneID()
        guard isPaired, let record = PhoneKeychain.loadLink(),
              let nonce = PairingCrypto.openPoll(message, phoneID: phoneID, key: SymmetricKeyBox(record.key).key) else {
            Self.liftLog.info("poll ignored: not paired or bad signature")
            return
        }
        guard let reserved = PhoneKeychain.reserveNextCounter() else { return }
        let key = SymmetricKeyBox(reserved.record.key).key
        if let pending = pendingLift, pending.sentCounter == nil, LiftSetting.isOn,
           let data = PairingCrypto.sealLiftNow(nonce: nonce, phoneID: phoneID, counter: reserved.counter, key: key) {
            pendingLift = (reserved.counter, pending.cont)
            Self.liftLog.info("poll answered with lift-now, counter \(reserved.counter)")
            send(data)
            return
        }
        let status: PairingCrypto.PresenceStatus
        if !LiftSetting.isOn {
            status = .off
        } else {
            status = UIApplication.shared.isProtectedDataAvailable ? .unlocked : .locked
        }
        guard let data = PairingCrypto.sealPresence(status, nonce: nonce, phoneID: phoneID,
                                                    counter: reserved.counter, key: key) else { return }
        Self.liftLog.info("poll answered: status \(status.rawValue), counter \(reserved.counter)")
        send(data)
    }

    // MARK: - 内部

    private func publish(_ change: (inout CurtainSnapshot) -> Void) {
        var next = snapshot
        change(&next)
        guard next != snapshot else { return }
        snapshot = next
        onSnapshotChange?(next)
    }

    private func publishService() {
        guard let manager, manager.state == .poweredOn, !serviceAdded else { return }
        let outbox = CBMutableCharacteristic(type: Identity.outbox, properties: [.notify, .read],
                                             value: nil, permissions: [.readable])
        let inbox = CBMutableCharacteristic(type: Identity.inbox, properties: [.write],
                                            value: nil, permissions: [.writeable])
        let service = CBMutableService(type: Identity.service, primary: true)
        service.characteristics = [outbox, inbox]
        self.outbox = outbox
        self.inbox = inbox
        serviceAdded = true
        manager.add(service)
    }

    private func startAdvertising() {
        guard wantsAdvertising, !gaveUp, let manager, manager.state == .poweredOn else { return }
        publishService()
        guard !manager.isAdvertising else { return }
        manager.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [Identity.service],
            CBAdvertisementDataLocalNameKey: Identity.localName,
        ])
    }

    /// Mac 订阅上又在握手 / 身份确认之前断了
    private func noteEarlyDrop() {
        consecutiveFailures += 1
        guard consecutiveFailures >= Self.maxEarlyDrops, !gaveUp else { return }
        gaveUp = true
        manager?.stopAdvertising()
        publish { $0.gaveUpConnecting = true }
    }
}

/// 钥匙串里存的是原始字节，用的时候包成 SymmetricKey
private struct SymmetricKeyBox {
    let key: SymmetricKey
    init(_ data: Data) { key = SymmetricKey(data: data) }
}

// MARK: - CBPeripheralManagerDelegate

extension BLECurtainLink: @preconcurrency CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            if snapshot.connection == .bluetoothOff {
                publish { $0.connection = self.isPaired ? .notConnected : .notPaired }
            }
            startAdvertising()
        case .poweredOff, .unauthorized, .unsupported:
            serviceAdded = false
            mac = nil
            ready = false
            publish { $0.connection = .bluetoothOff }
        default:
            break
        }
    }

    /// 系统把 App 叫回来时（状态恢复），把之前加过的服务和订阅着的 Mac 接回来
    func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String: Any]) {
        guard let services = dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService],
              let service = services.first(where: { $0.uuid == Identity.service }) else { return }
        for characteristic in service.characteristics ?? [] {
            guard let c = characteristic as? CBMutableCharacteristic else { continue }
            if c.uuid == Identity.outbox { outbox = c }
            if c.uuid == Identity.inbox { inbox = c }
        }
        serviceAdded = outbox != nil && inbox != nil
        wantsAdvertising = true
        if let central = outbox?.subscribedCentrals?.first {
            mac = central
            macEverSubscribed = true
            if isPaired { Task { await self.confirmLink() } }
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if error != nil { serviceAdded = false }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                           didSubscribeTo characteristic: CBCharacteristic) {
        guard characteristic.uuid == Identity.outbox else { return }
        mac = central
        macEverSubscribed = true
        ready = false
        assembler.reset()
        sendQueue.removeAll()
        if isPaired {
            Task { await self.confirmLink() }
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                           didUnsubscribeFrom characteristic: CBCharacteristic) {
        guard characteristic.uuid == Identity.outbox, central.identifier == mac?.identifier else { return }
        let wasReady = ready
        mac = nil
        ready = false
        sendQueue.removeAll()
        assembler.reset()
        if !wasReady { noteEarlyDrop() }
        publish { $0.connection = self.isPaired ? .macOffline : .notPaired }
        finishReply(.disconnected)
        finishAck(.failed)
        finishCover(.unavailable)
        finishLift(.unavailable)
        awaitingLiftOpen = false
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        pump()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        // 发件箱只走通知；直接读给空值
        guard request.characteristic.uuid == Identity.outbox else {
            peripheral.respond(to: request, withResult: .readNotPermitted)
            return
        }
        request.value = Data()
        peripheral.respond(to: request, withResult: .success)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard let first = requests.first else { return }
        guard requests.allSatisfy({ $0.characteristic.uuid == Identity.inbox }) else {
            peripheral.respond(to: first, withResult: .requestNotSupported)
            return
        }
        // 一组请求要一起回一次（回第一条）
        peripheral.respond(to: first, withResult: .success)
        for request in requests {
            guard let chunk = request.value else { continue }
            if let message = assembler.feed(chunk) {
                receive(message)
            }
        }
    }
}
