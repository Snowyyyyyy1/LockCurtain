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
// 重连不停手（见 Sources/ReconnectPolicy.swift 的不变式：配过对 + 蓝牙开着 + 没连上 ⇒ 一直在试，最长隔 5 分钟）：
//   * 一个 ensureAdvertising() 管「该广播就在广播」：activate、蓝牙打开、Mac 退订、回到前台、退出演示、状态恢复之后、
//     每 60 秒都调一次。服务加好（didAdd 成功）才开始广播；加失败了退避重加（2 s → … → 30 s）。
//   * 配着的那台电脑订阅上又在身份确认之前断开（早断），连续 5 次就暂停广播一会儿（30 s → 60 s → … → 5 min），
//     到点自己接着广播；连上、蓝牙重新打开、回到前台、点「现在再试一次」都清零。别的电脑的早断不算（没配过时都算）。
//   * 身份确认（签名的 ping）订阅着、没确认就每 2.5 秒再发一次；同一台电脑重新订阅就重新确认；
//     收到电脑任何一条验过签名的消息（收据 / 状态 / 问询）就算确认了。
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
    /// 早断 5 次以后暂停广播：30 s 起翻倍，最长 5 分钟（ReconnectPolicy.swift 的 reconnectBackoffCap）
    private static let pauseBase: TimeInterval = 30
    /// 加服务失败后重加：2 s 起翻倍，最长 30 s
    private static let addRetryBase: TimeInterval = 2
    private static let addRetryCap: TimeInterval = 30
    /// 身份确认没成，多久再发一次 ping（也是每次等收据的时间）
    private static let confirmRetry: Double = 2.5
    /// 兜底：每隔这么久确认一次「该广播就在广播」
    private static let ensureInterval: Double = 60
    private static let linkLog = Logger(subsystem: "LockCurtainRemote", category: "link")

    private var manager: CBPeripheralManager?
    private var outbox: CBMutableCharacteristic?
    private var inbox: CBMutableCharacteristic?
    /// 服务加好了没有（didAdd 成功才算；正在加的时候是 adding）
    private enum ServiceState { case none, adding, added }
    private var serviceState: ServiceState = .none
    private var addBackoff = ReconnectBackoff(base: BLECurtainLink.addRetryBase, cap: BLECurtainLink.addRetryCap)
    private var addRetryTask: Task<Void, Never>?
    /// 订阅着发件箱的 Mac
    private var mac: CBCentral?
    /// 这次等待里 Mac 来连过没有（区分「没找到」和「找到了连不上」）
    private var macEverSubscribed = false
    /// 这次订阅里握手 / 身份确认成了没有
    private var ready = false
    private var isPaired: Bool
    private var assembler = PairingFraming.Assembler()
    /// 待发的块，各自记着发给谁（换电脑时会同时跟两台说话）
    private var sendQueue: [(central: CBCentral, chunk: Data)] = []

    // 换电脑（copy v11 §13 / design v2.9 P2-6）：新配对在旁边配，原来那台的钥匙、连接、界面一概不碰；
    // 新的钥匙只放在内存里，Mac 签收了第一条命令才写进钥匙串、换掉原来那台。
    /// 正在换电脑
    private var replacing = false
    /// 用户关了配对页：这次换电脑作废
    private var replaceAborted = false
    /// 来配对的那台新电脑（不是原来那台）
    private var pairingCentral: CBCentral?
    private var pairingEverSubscribed = false
    private var pairingAssembler = PairingFraming.Assembler()
    /// 新电脑的钥匙，配成之前只在这里
    private var stagedRecord: PhoneLinkRecord?
    private var pendingStagedAck: (counter: UInt64, cont: CheckedContinuation<Bool, Never>)?
    private var stagedAckTimeout: Task<Void, Never>?
    private var lastStateSeq: UInt64 = 0

    private var consecutiveFailures = 0
    /// 早断 5 次以后暂停着广播（不是停手：到点自己接着广播）
    private(set) var gaveUp = false
    private var pauseBackoff = ReconnectBackoff(base: BLECurtainLink.pauseBase, cap: reconnectBackoffCap)
    private var pauseTask: Task<Void, Never>?
    private var confirmTask: Task<Void, Never>?
    private var ensureTimer: Task<Void, Never>?
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
        publishAdvertising()
        startEnsureTimer()
        if manager == nil {
            manager = CBPeripheralManager(delegate: self, queue: .main,
                                          options: [CBPeripheralManagerOptionShowPowerAlertKey: true,
                                                    CBPeripheralManagerOptionRestoreIdentifierKey: Identity.restoreIdentifier])
        } else {
            ensureAdvertising("activate")
        }
    }

    /// 重新打开配对 / App 打开或回到前台 / 退出演示：退避全清零，马上广播
    func resumeConnecting() {
        resetBackoff("resume")
        activate()
    }

    /// 「现在再试一次」：退避清零，广播重新开一次（让电脑马上能再看到）；订阅着没确认的就马上再确认
    func retryNow() {
        Self.linkLog.info("retry now (user)")
        resetBackoff("retry now")
        wantsAdvertising = true
        publishAdvertising()
        if let manager, manager.state == .poweredOn, serviceState == .added, manager.isAdvertising {
            manager.stopAdvertising()
        }
        activate()
        if isPaired, mac != nil, !ready { startConfirmLink(reason: "retry now") }
    }

    /// 早断计数和暂停都清零；暂停着就马上接着广播
    private func resetBackoff(_ why: String) {
        if consecutiveFailures > 0 || pauseBackoff.step > 0 || gaveUp {
            Self.linkLog.info("backoff reset (\(why, privacy: .public)): early drops \(self.consecutiveFailures), pause step \(self.pauseBackoff.step)")
        }
        consecutiveFailures = 0
        pauseBackoff.reset()
        pauseTask?.cancel()
        pauseTask = nil
        if gaveUp {
            gaveUp = false
            publish { $0.gaveUpConnecting = false }
            publishAdvertising()
        }
    }

    private func startEnsureTimer() {
        guard ensureTimer == nil else { return }
        ensureTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.ensureInterval))
                guard !Task.isCancelled, let self else { return }
                self.ensureAdvertising("timer")
            }
        }
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
    /// 不看「走近撤下」开关：开关只管「走近自己撤」，按「现在撤下」照样撤（电脑那边 LiftGate.liftNow 也不看开关）
    func liftNow() async -> LiftOutcome {
        guard mac != nil, ready, isPaired, snapshot.phase == .closed else { return .unavailable }
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

    // MARK: - 换电脑

    /// 已经配着一台、要换成另一台。原来那台在整个过程中照常用；
    /// 只有新电脑验过握手、又签收了第一条命令，才把钥匙换掉，并告诉原来那台「解除配对」。
    /// 取消、失败、中途断开：什么都不动。
    func pairReplacing(code: String) async -> PairResult {
        guard isPaired else { return await pair(code: code) }
        replacing = true
        replaceAborted = false
        defer { endReplacing() }
        activate()

        // 新电脑还没订阅就等它来（最多 15 秒）
        if pairingCentral == nil {
            pairingEverSubscribed = false
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline, pairingCentral == nil, !replaceAborted {
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        if replaceAborted { return .disconnected }
        guard let central = pairingCentral else { return pairingEverSubscribed ? .connectFailed : .notFound }

        let phoneID = PhoneKeychain.phoneID()
        guard let (request, session) = PairingCrypto.phoneStart(code: code, phoneID: phoneID) else { return .macRefused }

        let message: Data
        switch await requestReply(request.encoded(), to: central, seconds: 8) {
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
            send(PairingCrypto.pairAbort(phoneID: phoneID, sid: session.sid), to: central)
            return .wrongCode
        case .invalid:
            send(PairingCrypto.pairAbort(phoneID: phoneID, sid: session.sid), to: central)
            return .macRefused
        }
        if replaceAborted { return .disconnected }

        let accepted: Data
        switch await requestReply(confirm.encoded(), to: central, seconds: 8) {
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
        if replaceAborted { return .disconnected }

        // 钥匙确认：新电脑签收这条用新钥匙签的 ping，才算配上。钥匙这时还只在内存里。
        let record = PhoneLinkRecord(key: key.withUnsafeBytes { Data($0) },
                                     macIdentifier: central.identifier.uuidString, counter: 0)
        guard await confirmStaged(record, on: central) else {
            return pairingCentral == nil ? .disconnected : .macRefused
        }
        // 最后一刻用户关了页面：还是作废
        guard !replaceAborted, pairingCentral?.identifier == central.identifier,
              let confirmed = stagedRecord else { return .disconnected }
        guard adoptReplacement(confirmed, central: central) else { return .macRefused }
        return .accepted
    }

    /// 用户关了配对页：这次换电脑作废，原来那台不动
    func cancelReplacing() {
        guard replacing else { return }
        replaceAborted = true
        finishReply(.disconnected)
        finishStagedAck(false)
    }

    private func endReplacing() {
        replacing = false
        stagedRecord = nil
        finishStagedAck(false)
        if let central = pairingCentral {
            // 没换成：那台新电脑就晾着，不再理它
            dropQueued(for: central)
            pairingCentral = nil
        }
        pairingAssembler.reset()
    }

    /// 用新钥匙签一条 ping 发给新电脑，等它签收
    private func confirmStaged(_ record: PhoneLinkRecord, on central: CBCentral) async -> Bool {
        var next = record
        next.counter += 1
        stagedRecord = next
        guard let data = PairingCrypto.sealCommand("ping", phoneID: PhoneKeychain.phoneID(), counter: next.counter,
                                                   key: SymmetricKeyBox(next.key).key) else { return false }
        finishStagedAck(false)
        return await withCheckedContinuation { cont in
            pendingStagedAck = (next.counter, cont)
            send(data, to: central)
            stagedAckTimeout?.cancel()
            stagedAckTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled else { return }
                self?.finishStagedAck(false)
            }
        }
    }

    private func finishStagedAck(_ ok: Bool) {
        stagedAckTimeout?.cancel()
        stagedAckTimeout = nil
        let pending = pendingStagedAck
        pendingStagedAck = nil
        pending?.cont.resume(returning: ok)
    }

    /// 新电脑配成了：先用旧钥匙告诉原来那台「解除配对」，再把钥匙换掉，改跟新电脑说话
    private func adoptReplacement(_ record: PhoneLinkRecord, central: CBCentral) -> Bool {
        if let old = mac, ready, let reserved = PhoneKeychain.reserveNextCounter(),
           let data = PairingCrypto.sealCommand("unpair", phoneID: PhoneKeychain.phoneID(), counter: reserved.counter,
                                                key: SymmetricKeyBox(reserved.record.key).key) {
            send(data, to: old)
        }
        guard PhoneKeychain.saveLink(record) else { return false }
        // 原来那台的事全部收尾
        finishAck(.failed)
        finishCover(.unavailable)
        finishLift(.unavailable)
        awaitingLiftOpen = false
        lastStateSeq = 0
        // 改跟新电脑说话
        mac = central
        macEverSubscribed = true
        assembler = pairingAssembler
        pairingAssembler = PairingFraming.Assembler()
        pairingCentral = nil
        stagedRecord = nil
        publish { $0.phase = .open }
        markReady()
        // 让新电脑报一次幕布状态
        requestState()
        return true
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
        publishAdvertising()
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

    private func requestReply(_ message: Data, to target: CBCentral? = nil, seconds: Double) async -> Reply {
        await withCheckedContinuation { cont in
            pendingReply = cont
            if let target { send(message, to: target) } else { send(message) }
            replyTimeout?.cancel()
            replyTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { return }
                self?.finishReply(.timeout)
            }
        }
    }

    /// 发一条签名命令，等 Mac 的签名收据（最多 ackSeconds 秒）。计数先写进钥匙串再发。
    private func sendSigned(_ command: String, ackSeconds: Double = 6) async -> AckResult {
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
                try? await Task.sleep(for: .seconds(ackSeconds))
                guard !Task.isCancelled else { return }
                self?.finishAck(.failed)
            }
        }
    }

    /// 已经配过对的手机：Mac 订阅上来就用签名的 ping 表明身份，Mac 签收了才算已连接。
    /// 没签收（收据丢了 / 电脑忙 / App 刚被叫醒）：订阅着、还没确认，就每 confirmRetry 秒再发一次
    private func startConfirmLink(reason: String) {
        confirmTask?.cancel()
        guard let central = mac?.identifier else { return }
        confirmTask = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                guard let self, self.isPaired, !self.ready, self.mac?.identifier == central else { return }
                attempt += 1
                if attempt > 1 { Self.linkLog.info("confirm link: retry \(attempt) (\(reason, privacy: .public))") }
                let started = Date()
                let result = await self.sendSigned("ping", ackSeconds: Self.confirmRetry)
                // 这期间换了一台（或者断了）：这次的结果不算
                guard !Task.isCancelled, self.mac?.identifier == central else { return }
                if self.ready { return }
                switch result {
                case .ok:
                    self.markReady()
                    return
                case .rejected, .failed:
                    // 不认得我们（可能 Mac 那边撤销过）。没签名的拒绝谁都能伪造，所以不删钥匙，只是不说已连接，过一会儿再试。
                    self.publish { $0.connection = .notConnected }
                }
                let spent = Date().timeIntervalSince(started)
                if spent < Self.confirmRetry {
                    try? await Task.sleep(for: .seconds(Self.confirmRetry - spent))
                }
            }
        }
    }

    private func markReady() {
        let wasReady = ready
        ready = true
        confirmTask?.cancel()
        confirmTask = nil
        if !wasReady { Self.linkLog.info("link ready") }
        resetBackoff("ready")
        publish { $0.connection = .connected }
    }

    /// 收到 Mac 验过签名的消息（收据 / 状态 / 问询）：它一定认得我们，算已连接
    private func noteVerifiedFromMac(_ what: String) {
        guard isPaired, mac != nil, !ready else { return }
        Self.linkLog.info("verified \(what, privacy: .public) from the computer: marking ready")
        markReady()
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
        send(message, to: mac)
    }

    private func send(_ message: Data, to central: CBCentral) {
        let chunks = PairingFraming.chunks(message, maxChunk: central.maximumUpdateValueLength)
        sendQueue.append(contentsOf: chunks.map { (central, $0) })
        pump()
    }

    private func dropQueued(for central: CBCentral) {
        sendQueue.removeAll { $0.central.identifier == central.identifier }
    }

    private func pump() {
        guard let manager, let outbox else { sendQueue.removeAll(); return }
        while let item = sendQueue.first {
            guard manager.updateValue(item.chunk, for: outbox, onSubscribedCentrals: [item.central]) else { return }
            sendQueue.removeFirst()
        }
    }

    private func receive(_ message: Data) {
        switch PairingCrypto.kind(of: message) {
        case .pairResponse, .pairReject, .pairAccepted:
            // 换电脑时配对的回话只认新电脑那条线（见 receivePairing）
            guard !replacing else { return }
            finishReply(.message(message))
        case .ack:
            guard let ack = try? PairingCrypto.Ack(decoding: message),
                  ack.phoneID == PhoneKeychain.phoneID() else { return }
            let verified = ack.status == .accepted && PhoneKeychain.loadLink().map {
                PairingCrypto.verifyAck(ack, key: SymmetricKeyBox($0.key).key)
            } == true
            // 晚到的收据（前一次 ping 的）也证明电脑认得我们
            if verified { noteVerifiedFromMac("ack") }
            guard let pending = pendingAck, ack.counter == pending.counter else { return }
            if verified {
                finishAck(.ok)
            } else {
                finishAck(ack.status == .unknownOrBadSignature ? .rejected : .failed)
            }
        case .state:
            guard let record = PhoneKeychain.loadLink(),
                  let state = PairingCrypto.openState(message, phoneID: PhoneKeychain.phoneID(),
                                                      key: SymmetricKeyBox(record.key).key),
                  state.seq > lastStateSeq else { return }
            noteVerifiedFromMac("state")
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

    /// 换电脑时，新电脑发来的：只认配对回话和那条 ping 的收据（用内存里的新钥匙验）
    private func receivePairing(_ message: Data) {
        switch PairingCrypto.kind(of: message) {
        case .pairResponse, .pairReject, .pairAccepted:
            finishReply(.message(message))
        case .ack:
            guard let ack = try? PairingCrypto.Ack(decoding: message),
                  let pending = pendingStagedAck, ack.counter == pending.counter,
                  ack.phoneID == PhoneKeychain.phoneID(), let record = stagedRecord else { return }
            finishStagedAck(ack.status == .accepted
                            && PairingCrypto.verifyAck(ack, key: SymmetricKeyBox(record.key).key))
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
        noteVerifiedFromMac("poll")
        guard let reserved = PhoneKeychain.reserveNextCounter() else { return }
        let key = SymmetricKeyBox(reserved.record.key).key
        // 「现在撤下」不看「走近撤下」开关
        if let pending = pendingLift, pending.sentCounter == nil,
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

    /// 加服务；广播等 didAdd 成功再开（不然电脑连上来会找不到服务）
    private func publishService() {
        guard let manager, manager.state == .poweredOn, serviceState == .none else { return }
        let outbox = CBMutableCharacteristic(type: Identity.outbox, properties: [.notify, .read],
                                             value: nil, permissions: [.readable])
        let inbox = CBMutableCharacteristic(type: Identity.inbox, properties: [.write],
                                            value: nil, permissions: [.writeable])
        let service = CBMutableService(type: Identity.service, primary: true)
        service.characteristics = [outbox, inbox]
        self.outbox = outbox
        self.inbox = inbox
        serviceState = .adding
        Self.linkLog.info("adding service")
        manager.add(service)
    }

    /// 唯一的入口：该广播（想广播、没暂停、蓝牙开着）就确保服务加好了、在广播。连着电脑时也照样广播（Windows 靠广播量距离）
    private func ensureAdvertising(_ why: String) {
        guard wantsAdvertising, let manager, manager.state == .poweredOn else { return }
        if gaveUp {
            Self.linkLog.info("ensure advertising (\(why, privacy: .public)): paused, \(Int(self.pauseBackoff.remaining(at: Date())))s left")
            return
        }
        switch serviceState {
        case .none:
            Self.linkLog.info("ensure advertising (\(why, privacy: .public)): service not added yet")
            publishService()
        case .adding:
            break
        case .added:
            startAdvertising(why)
        }
    }

    private func startAdvertising(_ why: String) {
        guard wantsAdvertising, !gaveUp, let manager, manager.state == .poweredOn, serviceState == .added,
              !manager.isAdvertising else { return }
        Self.linkLog.info("start advertising (\(why, privacy: .public))")
        manager.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [Identity.service],
            CBAdvertisementDataLocalNameKey: Identity.localName,
        ])
        // 广播（重新）开始：主屏重新算「等这台 Mac 来连…」
        publish { $0.waitEpoch += 1 }
    }

    /// 「想广播、而且没暂停」告诉界面
    private func publishAdvertising() {
        let on = wantsAdvertising && !gaveUp
        publish { $0.isAdvertising = on }
    }

    /// Mac 订阅上又在握手 / 身份确认之前断了。配过对时只算配着的那台电脑（别的电脑来连又走不算）
    private func noteEarlyDrop(_ central: CBCentral) {
        if isPaired, let paired = PhoneKeychain.loadLink()?.macIdentifier, central.identifier.uuidString != paired {
            Self.linkLog.info("early drop from another computer; not counted")
            return
        }
        consecutiveFailures += 1
        Self.linkLog.info("early drop \(self.consecutiveFailures)/\(Self.maxEarlyDrops)")
        guard consecutiveFailures >= Self.maxEarlyDrops, !gaveUp else { return }
        // 暂停广播一会儿（不是停手）：到点自己接着广播；再早断就翻倍，最长 5 分钟
        let delay = pauseBackoff.fail(at: Date())
        Self.linkLog.info("pausing advertising for \(Int(delay))s after \(self.consecutiveFailures) early drops")
        gaveUp = true
        manager?.stopAdvertising()
        publish { $0.gaveUpConnecting = true }
        publishAdvertising()
        pauseTask?.cancel()
        pauseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.gaveUp else { return }
            Self.linkLog.info("advertising pause over; resuming")
            self.gaveUp = false
            self.publish { $0.gaveUpConnecting = false }
            self.publishAdvertising()
            self.ensureAdvertising("pause over")
        }
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
            resetBackoff("bluetooth on")
            ensureAdvertising("bluetooth on")
        case .poweredOff, .unauthorized, .unsupported:
            serviceState = .none
            addRetryTask?.cancel()
            addRetryTask = nil
            confirmTask?.cancel()
            mac = nil
            ready = false
            if pairingCentral != nil {
                pairingCentral = nil
                pairingAssembler.reset()
                finishStagedAck(false)
            }
            if replacing { finishReply(.disconnected) }
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
        serviceState = outbox != nil && inbox != nil ? .added : .none
        wantsAdvertising = true
        publishAdvertising()
        startEnsureTimer()
        if let central = outbox?.subscribedCentrals?.first {
            mac = central
            macEverSubscribed = true
            if isPaired { startConfirmLink(reason: "restored") }
        }
        Self.linkLog.info("state restored (service \(self.serviceState == .added ? "kept" : "missing"), subscribed \(self.mac != nil))")
        // 恢复完：该广播就广播（状态还没到 poweredOn 时，poweredOn 那里会再调一次）
        ensureAdvertising("restored")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard service.uuid == Identity.service else { return }
        if let error {
            serviceState = .none
            let delay = addBackoff.fail(at: Date())
            Self.linkLog.error("add service failed: \(error.localizedDescription, privacy: .public); retry in \(Int(delay))s")
            addRetryTask?.cancel()
            addRetryTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self else { return }
                self.ensureAdvertising("add retry")
            }
            return
        }
        serviceState = .added
        addBackoff.reset()
        Self.linkLog.info("service added")
        startAdvertising("service added")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                           didSubscribeTo characteristic: CBCharacteristic) {
        guard characteristic.uuid == Identity.outbox else { return }
        if central.identifier == pairingCentral?.identifier { return }
        if central.identifier == mac?.identifier {
            // 同一台电脑又订阅了一次（它那边是一条新连接，要重新表明身份）：重新确认，不能不理
            guard isPaired, !replacing else { return }
            Self.linkLog.info("same computer subscribed again: re-confirming link")
            ready = false
            assembler.reset()
            startConfirmLink(reason: "re-subscribe")
            return
        }
        if isPaired && replacing {
            // 换电脑：原来那台（认得它的标识、且现在没连着）照常接回来；别的电脑就是来配对的
            let isOldComputer = mac == nil && central.identifier.uuidString == PhoneKeychain.loadLink()?.macIdentifier
            if !isOldComputer {
                if pairingCentral == nil {
                    pairingCentral = central
                    pairingEverSubscribed = true
                    pairingAssembler.reset()
                }
                return
            }
        } else if isPaired && ready && mac != nil {
            // 已经和配着的那台连好了：别的电脑来连不理它，免得把好好的连接顶掉
            return
        }
        if let old = mac { dropQueued(for: old) }
        mac = central
        macEverSubscribed = true
        ready = false
        assembler.reset()
        if isPaired {
            startConfirmLink(reason: "subscribe")
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                           didUnsubscribeFrom characteristic: CBCharacteristic) {
        guard characteristic.uuid == Identity.outbox else { return }
        if central.identifier == pairingCentral?.identifier {
            // 来配对的新电脑走了：这次换电脑失败，原来那台不受影响
            dropQueued(for: central)
            pairingCentral = nil
            pairingAssembler.reset()
            finishReply(.disconnected)
            finishStagedAck(false)
            return
        }
        guard central.identifier == mac?.identifier else {
            dropQueued(for: central)
            return
        }
        let wasReady = ready
        mac = nil
        ready = false
        confirmTask?.cancel()
        confirmTask = nil
        dropQueued(for: central)
        assembler.reset()
        Self.linkLog.info("computer unsubscribed (ready \(wasReady))")
        if !wasReady { noteEarlyDrop(central) }
        ensureAdvertising("unsubscribed")
        // 断了：手机不知道 Mac 在不在，只说「没连上」；主屏从这一刻重新等 20 秒
        publish {
            $0.connection = self.isPaired ? .notConnected : .notPaired
            $0.waitEpoch += 1
        }
        // 换电脑时原来那台断了，不影响正在跟新电脑配的那一轮
        if !replacing { finishReply(.disconnected) }
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
            let from = request.central.identifier
            if from == pairingCentral?.identifier {
                if let message = pairingAssembler.feed(chunk) { receivePairing(message) }
            } else if mac == nil || from == mac?.identifier {
                if let message = assembler.feed(chunk) { receive(message) }
            }
            // 别的电脑写进来的：不理
        }
    }
}
