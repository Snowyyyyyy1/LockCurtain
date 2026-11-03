// PhonePairing.swift —— Mac 端的「配对手机」（Mac 是蓝牙中心，手机是外设）
//
// Mac 不再广播。手机广播 LockCurtain 的服务，Mac 扫描、连上去、订阅手机的「发件箱」，
// 往手机的「收件箱」写回复和幕布状态：
//   * 发件箱（…5A70，notify）：手机 → Mac，配对握手（请求 / 确认 / 放弃）、签名命令
//   * 收件箱（…5A71，write）：Mac → 手机，配对应答 / 拒绝、命令收据、幕布状态、撤销通知
// 每条消息都按 PairingFraming 切块。安全全在 PairingCrypto / PairingAuthority，不靠系统蓝牙加密。
//
// 只在「配对窗口开着」或「已经配过手机」时扫描 / 连接。配过的手机记住它的外设标识，
// 断了用 central.connect()（挂起式连接，不超时）等它回来，同时继续扫描兜底（手机的蓝牙地址会轮换）。
// 连上之后每 2 秒读一次 RSSI 写进日志 —— 这是实验的证据：配对稳不稳、手机锁屏放兜里 5 分钟断不断、
// 走远时 RSSI 怎么掉。还不按距离自动盖。
//
// 手机撤下幕布：幕布盖着、手机连着时，每 2 秒往手机收件箱写一条签名的问询（Poll，带新的随机 nonce；
// 写入会把后台的 App 叫醒），手机回签名的 Presence（此刻解锁着 / 锁着 / 关着）。签名和计数由
// PairingAuthority 验，撤不撤由 LiftGate 判（新鲜、边沿、近），撤就调 onLift（只撤 LockCurtain 的遮罩，
// 不碰系统锁屏），再回手机一条签名的 LiftResult。「现在撤下」是手机用下一次问询的 nonce 回的 LiftNow。
//
// 重连（见 ReconnectPolicy.swift 的不变式：配过对 + 蓝牙开着 + 没连上 ⇒ 一直在试，间隔翻倍、最多 5 分钟）：
//   * 早断（连上了却在订阅上发件箱之前就断）：没配过手机（只开着配对窗口）时连续 5 次就硬停，
//     写一行 "stopped after 5 early drops"，等配对窗口重新打开；配过手机时从第 5 次起只是退避
//     （30 s → 60 s → … → 5 min），到点自己接着连。认得的外设报「service not found」（手机 App 没在跑）不算早断，
//     只给这个标识退避一下。
//   * 订阅上了 30 秒还不用签名命令表明身份：断开，这个标识暂时不理（30 s → … → 5 min），到点自动放出来。
//   * 配过、蓝牙开着、没连上时扫描一直开着（允许重复上报）：退避只拉开挂起式连接的失败重试，
//     一扫到手机的服务（手机 App 刚重新打开 / 手机重启后打开 App）就马上连。App 一启动就扫、就连，不等。
//     退避中扫到：第一次马上连，之后同一个标识每 30 秒最多连一次（每个广播包都会报一次，连上就断时不能打转）；
//     早断计数只在订阅成功时清零（唤醒 / 蓝牙重新打开也清），扫到不清。
//   * 挂起的 connect() 系统不会超时：挂了 60 秒还没连上、或扫到它在广播却还卡在连 10 秒以上，取消重挂；
//     唤醒 / 蓝牙重新打开时挂着的全部取消重挂。
//   * 健康检查：每 30 秒，配过、蓝牙开着、没有认过身份的手机连着时，把记得的标识（退避中的除外）重新挂上连接、
//     确保在扫、放出到点的标识。系统唤醒（NSWorkspace.didWake / screensDidWake）也会重新挂。
//   * 记得的标识按手机记（每台最近 2 个）；一台手机认过身份，它别的没认身份的连接悄悄断掉（不拉黑）。
//   * 服务变了（didModifyServices）、发件箱退订、连续 3 次写失败：主动断开，交给正常重连。
//
// 日志：/tmp/lockcurtain-ble.log，每步一行；反复出现的（健康检查 / 退避 / RSSI / 问询）只在状态变了时写、或每分钟最多一行。
// 满 2 MB 轮转成 .log.1（只留一个）。不写码、不写钥匙。
// CBCentralManager 的回调都投递到 main 队列，所以这里的 @Published 永远在主线程上改。

import AppKit
import Combine
import CoreBluetooth
import Foundation

final class PhonePairing: NSObject, ObservableObject {
    enum Phase: Equatable {
        case idle                 // 没在配对
        case waiting              // 显示着码，等手机
        case paired               // 刚配上（握手验过、手机签的第一条命令也验过）
        case bluetoothOff         // 蓝牙没开
        case unauthorized         // 系统没给蓝牙权限
        case unsupported
        /// 刚撤销过配对
        case revoked
    }

    static let serviceUUID = CBUUID(string: "E9A1B2C3-D4E5-4F60-8A7B-1C2D3E4F5A6B")
    /// 手机 → Mac
    static let outboxUUID = CBUUID(string: "E9A1B2C3-D4E5-4F60-8A7B-1C2D3E4F5A70")
    /// Mac → 手机
    static let inboxUUID = CBUUID(string: "E9A1B2C3-D4E5-4F60-8A7B-1C2D3E4F5A71")

    /// 老版本用 UserDefaults 记的配对（明文配对，现在不认了）
    private static let legacyPairedKey = "phonePairing.pairedCentrals"
    /// 配过的手机的外设标识（不是秘密，只用来挂起式重连）。格式见 KnownPeripherals（ReconnectPolicy.swift）
    private static let knownPeripheralsKey = "phonePairing.knownPeripherals"
    /// 窗口关着时，订阅上发件箱的手机这么久还没用签名命令表明身份，就断开、这个标识暂时不理（限时，见 TimedIgnoreList）
    private static let identifyTimeout: TimeInterval = 30
    /// 连上了这么久还没订阅上发件箱（查服务 / 特征卡住了）：断开，交给正常重连
    private static let setupTimeout: TimeInterval = 30
    /// 健康检查的间隔
    private static let healthInterval: TimeInterval = 30
    /// 连续写失败这么多次：当链路死了，断开重连
    private static let maxWriteErrors = 3
    /// 认得的标识上没找到服务（手机 App 没在跑）：这个标识的退避
    private static let missingServiceBase: TimeInterval = 30
    private static let missingServiceCap: TimeInterval = 300

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var code = ""

    /// 手机发来的命令（away / hide …），由 AppDelegate 接到原来的命令通道上
    var onCommand: ((String) async -> Void)?
    /// 手机撤下幕布（条件都满足了）：撤 LockCurtain 的遮罩，和离开模式里「验证」通过一样，不碰系统锁屏
    var onLift: (() -> Void)?

    private lazy var authority = PairingAuthority(store: KeychainPairingStore(), log: { Self.log($0) })
    private var central: CBCentralManager?
    private var wantsBluetooth = false
    private var windowOpen = false
    /// 只在没配过手机（配对窗口模式）时会变 true
    private var stoppedAfterEarlyDrops = false
    private var earlyDrops = EarlyDropPolicy()
    /// 早断退避到点时接着连
    private var earlyDropResume: DispatchWorkItem?
    /// 认得的标识各自的退避（手机 App 没在跑）
    private var identifierBackoff: [UUID: ReconnectBackoff] = [:]
    /// 退避中扫到手机：第一次马上连，之后同一个标识每 30 秒最多连一次（订阅 / 认出身份才清）
    private var discoveryLimiter = DiscoveryConnectLimiter<UUID>()
    /// 健康检查 / 退避 / RSSI / 问询这些反复出现的日志：只在状态变了时写，或者每分钟最多一行
    private var logThrottle = LogThrottle()
    private static let repeatLogEvery: TimeInterval = 60
    private var rssiTimer: Timer?
    private var healthTimer: Timer?
    /// 这次扫描里已经写过日志的标识（允许重复上报，不每包都写一行）
    private var seenThisScan: Set<UUID> = []
    private var wakeObservers: [NSObjectProtocol] = []
    /// 幕布现在是不是盖着
    private var curtainClosed = false
    /// 这次盖上的时刻 T（边沿规则从这里算）
    private var curtainClosedAt: Date?
    /// 每台手机的撤下判断（按 phoneID，断开重连也留着「盖上之后见过锁着」）
    private var gates: [UUID: LiftGate] = [:]

    /// 一台连上的手机
    private final class Peer {
        let peripheral: CBPeripheral
        var inbox: CBCharacteristic?
        var outbox: CBCharacteristic?
        var subscribed = false
        var assembler = PairingFraming.Assembler()
        /// 验过签名命令之后才知道它是哪台手机
        var phoneID: UUID?
        var connectedAt: Date?
        /// 待写的块，一块写完（有回执）再写下一块
        var writeQueue: [Data] = []
        var writing = false
        var disconnectAfterWrites = false
        /// 连续写失败几次
        var writeErrors = 0
        /// 这次连接上没找到我们的服务
        var serviceMissing = false
        /// 我们自己悄悄断的（重复连接 / 服务变了…）：断开时不算早断
        var quietCancel = false
        /// connect() 发出去、还没连上的时刻（系统不会让它超时，我们自己看）
        var pendingSince: Date?
        /// 卡住的挂起连接取消后马上重挂：被取消的那次如果再报一次断开 / 连不上，不理它（连上或用掉一次就清）
        var ignoreStaleDisconnect = false
        init(_ peripheral: CBPeripheral) { self.peripheral = peripheral }
    }
    private var peers: [UUID: Peer] = [:]
    /// 暂时不理的外设（窗口关着时订阅上了却说不出自己是谁）；到点自动放出来
    private var ignored = TimedIgnoreList<UUID>()

    override init() {
        super.init()
        UserDefaults.standard.removeObject(forKey: Self.legacyPairedKey)
    }

    var isPaired: Bool { authority.isPaired }

    // MARK: - 开始 / 结束

    /// App 启动时（已配过手机）调用：开始找手机。第一次创建 CBCentralManager 会弹系统蓝牙权限。
    func prepare() {
        wantsBluetooth = true
        startHealthTimer()
        observeWake()
        if central == nil {
            Self.log("central: create")
            central = CBCentralManager(delegate: self, queue: .main,
                                       options: [CBCentralManagerOptionShowPowerAlertKey: true])
        } else {
            resume()
        }
    }

    /// 打开配对窗口时调用：生成一个新码，开始找手机
    func start() {
        let fresh = Self.makeCode()
        authority.openWindow(code: fresh)
        code = fresh
        windowOpen = true
        phase = .waiting
        ignored.removeAll()
        identifierBackoff.removeAll()
        if stoppedAfterEarlyDrops {
            Self.log("pairing window reopened: resuming after early-drop stop")
            stoppedAfterEarlyDrops = false
        }
        resetEarlyDrops(reason: "pairing window opened")
        prepare()
    }

    /// 关窗口时调用：把码作废；没配过手机就不再找
    func stop() {
        authority.closeWindow()
        code = ""
        windowOpen = false
        if phase != .bluetoothOff && phase != .unauthorized && phase != .unsupported { phase = .idle }
        if !isPaired {
            Self.log("pairing window closed and nothing paired: stop scanning")
            central?.stopScan()
            for peer in peers.values { central?.cancelPeripheralConnection(peer.peripheral) }
        }
    }

    /// 撤销这台机器上记着的所有手机：连着的手机先收到签名的撤销通知（它会删掉自己的钥匙），再删 Mac 的钥匙
    func unpairAll() {
        let notices = authority.revokeAll()
        for peer in peers.values {
            guard let id = peer.phoneID else { continue }
            peer.phoneID = nil
            if let notice = notices[id] {
                Self.log("revoke: notifying connected phone \(id.uuidString)")
                send(notice, to: peer)
                peer.disconnectAfterWrites = true
            }
        }
        UserDefaults.standard.removeObject(forKey: Self.knownPeripheralsKey)
        identifierBackoff.removeAll()
        gates.removeAll()
        code = ""
        phase = .revoked
        if !windowOpen {
            central?.stopScan()
            for peer in peers.values where !peer.disconnectAfterWrites {
                central?.cancelPeripheralConnection(peer.peripheral)
            }
        }
    }

    /// 幕布状态变了：告诉已连上的手机（签名的）
    func reportCurtainState(_ state: String) {
        let closed = state == "closed"
        guard curtainClosed != closed else { return }
        curtainClosed = closed
        let now = Date()
        curtainClosedAt = closed ? now : nil
        for id in gates.keys {
            if closed { gates[id]?.covered(at: now) } else { gates[id]?.uncovered() }
        }
        Self.log("lift: curtain \(closed ? "covered" : "uncovered")")
        for peer in peers.values {
            if let id = peer.phoneID, let message = authority.stateMessage(closed: closed, for: id) {
                send(message, to: peer)
            }
        }
    }

    /// 换一个码：老的立刻作废；错满 5 次的窗口换不出新码
    func refreshCode() {
        guard phase == .waiting else { return }
        let fresh = Self.makeCode()
        if authority.refresh(code: fresh) {
            code = fresh
            Self.log("code refreshed")
        } else {
            code = ""
            Self.log("refresh refused: code locked after \(PairingCrypto.maxCodeAttempts) wrong attempts, reopen the window")
        }
    }

    private static func makeCode() -> String {
        String(format: "%06d", Int.random(in: 0...999_999))
    }

    // MARK: - 扫描 / 连接

    private var shouldRun: Bool {
        wantsBluetooth && (windowOpen || isPaired) && !stoppedAfterEarlyDrops
    }

    /// 配过对、早断退避还没到点：先不连、不扫
    private var holdingAfterEarlyDrops: Bool {
        isPaired && earlyDrops.holding(at: Date())
    }

    /// 重新挂上记得的手机、开始扫描。
    /// fresh = 唤醒 / 蓝牙重新打开：之前的退避都不算了，认得的标识全都再试一次（暂时不理的也给一次机会）
    private func resume(fresh: Bool = false) {
        guard let central, central.state == .poweredOn, shouldRun else { return }
        if fresh {
            identifierBackoff.removeAll()
            discoveryLimiter.removeAll()
            resetEarlyDrops(reason: "fresh resume")
            // 唤醒 / 蓝牙重新打开：之前挂着的连接多半已经卡死了，全都取消重挂
            for peer in peers.values where peer.connectedAt == nil && peer.pendingSince != nil {
                reissuePending(peer, why: "fresh resume")
            }
        }
        if holdingAfterEarlyDrops {
            Self.log("backoff: early-drop hold, \(Int(earlyDrops.remaining(at: Date())))s left; scanning only, no pending reconnects yet")
        } else {
            pendKnown(reason: "pending reconnect to known phone", bypassIgnore: fresh)
        }
        startScan()
    }

    /// 记得的手机：挂起式连接，它一回来就连上。退避中的标识、已经有认过身份的连接的那台手机的标识跳过
    private func pendKnown(reason: String, bypassIgnore: Bool) {
        guard let central, isPaired else { return }
        let known = knownEntries()
        guard !known.isEmpty else { return }
        let now = Date()
        let identifiedPhones = Set(peers.values.compactMap(\.phoneID))
        var skipped: [String] = []
        for peripheral in central.retrievePeripherals(withIdentifiers: known.map(\.identifier))
        where peers[peripheral.identifier] == nil {
            let id = peripheral.identifier
            if let phone = KnownPeripherals.phoneID(of: id, in: known), identifiedPhones.contains(phone) { continue }
            if let backoff = identifierBackoff[id], backoff.holding(at: now) {
                skipped.append("\(id.uuidString) (no service, \(Int(backoff.remaining(at: now)))s left)")
                continue
            }
            if !bypassIgnore, ignored.contains(id, at: now) {
                skipped.append("\(id.uuidString) (ignored)")
                continue
            }
            connect(peripheral, reason: reason)
        }
        // 剩几秒每次都不一样：按「跳过了哪些」去重，变了才写
        let skippedKey = skipped.map { $0.components(separatedBy: " (").first ?? $0 }.joined(separator: ",")
        if logThrottle.changed("pendKnown.skipped", value: skippedKey), !skipped.isEmpty {
            Self.log("backoff: not re-pending \(skipped.joined(separator: ", "))")
        }
    }

    private func startScan() {
        // 早断退避中也照样扫：退避只拉开挂起式连接，扫到手机就马上连
        guard let central, central.state == .poweredOn, shouldRun, !central.isScanning else { return }
        // 已经有一台验明身份的手机连着、窗口也没开：不用再扫
        if !windowOpen, peers.values.contains(where: { $0.phoneID != nil }) { return }
        // 允许重复上报：手机走开再回来、App 重新打开，同一个标识也会再报一次（只扫我们的服务，报的只有 LockCurtain 手机）
        seenThisScan.removeAll()
        central.scanForPeripherals(withServices: [Self.serviceUUID],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        Self.log("scan start (window \(windowOpen ? "open" : "closed"), paired \(isPaired))")
    }

    private func connect(_ peripheral: CBPeripheral, reason: String) {
        guard let central else { return }
        let peer = peers[peripheral.identifier] ?? Peer(peripheral)
        peers[peripheral.identifier] = peer
        peripheral.delegate = self
        guard peripheral.state == .disconnected else { return }
        Self.log("connect requested \(peripheral.identifier.uuidString) (\(reason))")
        peer.pendingSince = Date()
        central.connect(peripheral, options: nil)
    }

    /// 挂起的连接卡住了：取消、马上重挂（换一个新的 Peer；被取消的那次再报断开就不理）
    private func reissuePending(_ peer: Peer, why: String) {
        guard let central else { return }
        let peripheral = peer.peripheral
        let id = peripheral.identifier
        let age = peer.pendingSince.map { Int(Date().timeIntervalSince($0)) } ?? 0
        // 手机不在附近时每分钟都会重挂一次：同样的原因每 10 分钟最多写一行
        if logThrottle.shouldLog("reissue.\(id)", value: why, at: Date(), every: Self.repeatLogEvery * 10) {
            Self.log("re-issuing pending connect \(id.uuidString) (pending \(age)s): \(why)")
        }
        central.cancelPeripheralConnection(peripheral)
        let fresh = Peer(peripheral)
        fresh.ignoreStaleDisconnect = true
        fresh.pendingSince = Date()
        peers[id] = fresh
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
        // 标记一直留到连上或者用掉为止（系统取消挂起的连接时不一定回调）；
        // 万一吃掉的是新这次的失败，ignoreStaleCallback 看到没在连会再挂一次，不会漏
    }

    /// 挂着太久的连接（健康检查 / 扫到它在广播时看）
    private func reissueStalePending(onlyFor id: UUID? = nil, discovered: Bool) {
        let now = Date()
        for peer in Array(peers.values) where peer.connectedAt == nil {
            guard let since = peer.pendingSince else { continue }
            if let id, peer.peripheral.identifier != id { continue }
            guard PendingConnectPolicy.isStale(pendingSince: since, discovered: discovered, at: now) else { continue }
            reissuePending(peer, why: discovered ? "advertising, but connect still pending" : "connect pending too long")
        }
    }

    private func knownEntries() -> [KnownPeripherals.Entry] {
        KnownPeripherals.parse(UserDefaults.standard.stringArray(forKey: Self.knownPeripheralsKey) ?? [])
    }

    private func remember(_ peripheral: CBPeripheral, as phoneID: UUID) {
        let old = knownEntries()
        let new = KnownPeripherals.remember(old, identifier: peripheral.identifier, phoneID: phoneID)
        guard new != old else { return }
        let dropped = Set(old.map(\.identifier)).subtracting(new.map(\.identifier))
        if !dropped.isEmpty {
            Self.log("known peripherals: forgetting older identifier(s) \(dropped.map(\.uuidString).joined(separator: ", ")) (keep last \(KnownPeripherals.keepPerPhone) per phone)")
        }
        UserDefaults.standard.set(KnownPeripherals.encode(new), forKey: Self.knownPeripheralsKey)
    }

    // MARK: - 退避 / 健康检查

    private func resetEarlyDrops(reason: String) {
        if earlyDrops.drops > 0 || earlyDrops.holdUntil != nil {
            Self.log("backoff: early-drop count reset (\(reason))")
        }
        earlyDrops.reset()
        earlyDropResume?.cancel()
        earlyDropResume = nil
    }

    /// 早断退避到点：接着连
    private func scheduleEarlyDropResume(after delay: TimeInterval) {
        earlyDropResume?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.earlyDropResume = nil
            Self.log("backoff: early-drop hold over; reconnecting")
            self.resume()
        }
        earlyDropResume = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.1, execute: work)
    }

    private func startHealthTimer() {
        guard healthTimer == nil else { return }
        healthTimer = Timer.scheduledTimer(withTimeInterval: Self.healthInterval, repeats: true) { [weak self] _ in
            self?.healthCheck()
        }
    }

    /// 每 30 秒：配过、蓝牙开着、没有认过身份的手机连着 ⇒ 放出到点的标识、重新挂记得的标识（退避中的除外）、确保在扫
    private func healthCheck() {
        let now = Date()
        let released = ignored.expire(at: now)
        if !released.isEmpty {
            Self.log("health: ignore expired for \(released.map(\.uuidString).joined(separator: ", "))")
        }
        if let central, central.state == .poweredOn { reissueStalePending(discovered: false) }
        guard let central, central.state == .poweredOn, wantsBluetooth, isPaired, !stoppedAfterEarlyDrops,
              !peers.values.contains(where: { $0.phoneID != nil }) else {
            _ = logThrottle.changed("health", value: "idle")
            return
        }
        // 每 30 秒都跑，但日志只在状态变了时写一行
        if holdingAfterEarlyDrops {
            if logThrottle.changed("health", value: "hold") {
                Self.log("health: early-drop hold, \(Int(earlyDrops.remaining(at: now)))s left; scanning only")
            }
            startScan()
            return
        }
        if !released.isEmpty { seenThisScan.subtract(released) }
        let scanner = central.isScanning ? "on" : "restarting"
        if logThrottle.changed("health", value: "repend.\(scanner)") {
            Self.log("health: paired, no identified phone; re-pending known identifiers, scanner \(scanner)")
        }
        pendKnown(reason: "pending reconnect to known phone (health check)", bypassIgnore: false)
        startScan()
    }

    /// 系统唤醒：有时候蓝牙状态不会变一次，单靠 centralManagerDidUpdateState 接不回来
    private func observeWake() {
        guard wakeObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            wakeObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self else { return }
                Self.log("system \(note.name == NSWorkspace.didWakeNotification ? "wake" : "screens wake"): resuming")
                self.resume(fresh: true)
            })
        }
    }

    /// 我们自己断开一条连接（不拉黑、不算早断），交给正常重连
    private func cancelQuietly(_ peer: Peer, why: String) {
        Self.log("cancelling \(peer.peripheral.identifier.uuidString): \(why)")
        peer.quietCancel = true
        central?.cancelPeripheralConnection(peer.peripheral)
    }

    private func updateRSSITimer() {
        let anyConnected = peers.values.contains { $0.peripheral.state == .connected }
        if anyConnected, rssiTimer == nil {
            rssiTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                guard let self else { return }
                for peer in self.peers.values where peer.peripheral.state == .connected {
                    peer.peripheral.readRSSI()
                    self.poll(peer)
                }
            }
        } else if !anyConnected {
            rssiTimer?.invalidate()
            rssiTimer = nil
        }
    }

    // MARK: - 收发

    private func send(_ message: Data, to peer: Peer) {
        guard let inbox = peer.inbox else {
            Self.log("send skipped: inbox of \(peer.peripheral.identifier.uuidString) not ready")
            return
        }
        // 不走长写：按单包上限切块，每块都要回执
        let limit = peer.peripheral.maximumWriteValueLength(for: .withoutResponse)
        peer.writeQueue.append(contentsOf: PairingFraming.chunks(message, maxChunk: limit))
        pump(peer, inbox)
    }

    private func pump(_ peer: Peer, _ inbox: CBCharacteristic) {
        guard !peer.writing else { return }
        guard !peer.writeQueue.isEmpty else {
            if peer.disconnectAfterWrites {
                peer.disconnectAfterWrites = false
                Self.log("disconnecting \(peer.peripheral.identifier.uuidString) after final message")
                central?.cancelPeripheralConnection(peer.peripheral)
            }
            return
        }
        peer.writing = true
        peer.peripheral.writeValue(peer.writeQueue.removeFirst(), for: inbox, type: .withResponse)
    }

    private func receive(_ message: Data, from peer: Peer) {
        let who = peer.peripheral.identifier.uuidString
        switch PairingCrypto.kind(of: message) {
        case .pairRequest, .pairConfirm, .pairAbort:
            Self.log("pair message received from peripheral \(who)")
            switch authority.handlePair(message) {
            case .responded(let reply):
                send(reply, to: peer)
            case .accepted(let reply, _):
                send(reply, to: peer)
                code = ""
            case .rejected(let reply, _):
                send(reply, to: peer)
            case .aborted:
                break
            case .noCode(let reply), .malformed(let reply):
                send(reply, to: peer)
            }
            if authority.isLocked { code = "" }
        case .presence, .liftNow:
            handleAnswer(message, from: peer)
        case .command:
            switch authority.handleCommand(message) {
            case .accepted(let command, let phoneID, _, let confirmed, let ack):
                let firstTime = peer.phoneID == nil
                peer.phoneID = phoneID
                remember(peer.peripheral, as: phoneID)
                if firstTime { identified(peer, as: phoneID) }
                send(ack, to: peer)
                if confirmed {
                    phase = .paired
                    NSLog("LockCurtain paired with a phone (%@)", phoneID.uuidString)
                }
                handle(command, phoneID: phoneID, peer: peer)
            case .rejected(_, _, let ack):
                if let ack { send(ack, to: peer) }
            }
        default:
            Self.log("message of unknown kind (\(message.count) bytes) from \(who) ignored")
        }
    }

    // MARK: - 撤下

    private func gate(for phoneID: UUID) -> LiftGate {
        if let gate = gates[phoneID] { return gate }
        var gate = LiftGate()
        if curtainClosed, let at = curtainClosedAt { gate.covered(at: at) }
        return gate
    }

    /// 幕布盖着、手机认过身份：发一条签名的问询（新 nonce）
    private func poll(_ peer: Peer) {
        guard curtainClosed, let id = peer.phoneID, peer.subscribed, peer.inbox != nil else { return }
        // 上一条还没写完（手机没回执）就不再堆
        guard peer.writeQueue.isEmpty, !peer.writing else {
            if logThrottle.shouldLog("poll.\(id)", value: "skipped", at: Date(), every: Self.repeatLogEvery) {
                Self.log("lift: poll skipped for \(id.uuidString): previous write still pending")
            }
            return
        }
        let nonce = PairingCrypto.makeNonce()
        guard let message = authority.pollMessage(nonce: nonce, for: id) else { return }
        var gate = gate(for: id)
        gate.issue(nonce, at: Date())
        gates[id] = gate
        if logThrottle.shouldLog("poll.\(id)", value: "sent", at: Date(), every: Self.repeatLogEvery) {
            Self.log("lift: poll sent to \(id.uuidString) nonce \(Self.short(nonce)) (logged at most once a minute)")
        }
        send(message, to: peer)
    }

    private func handleAnswer(_ message: Data, from peer: Peer) {
        guard case .accepted(let answer) = authority.handleAnswer(message) else { return }
        let id = answer.phoneID
        // 签名对，但不是这条连接上认过的那台手机：不理
        guard peer.phoneID == id else {
            Self.log("lift: answer from \(id.uuidString) on a connection identified as \(peer.phoneID?.uuidString ?? "nobody"); ignored")
            return
        }
        let now = Date()
        var gate = gate(for: id)
        let wasArmed = gate.edgeArmed
        let (median, samples) = gate.rssiMedian(at: now)
        let rssiText = "rssi median \(median.map(String.init) ?? "-") of [\(samples.map(String.init).joined(separator: ","))], need >= \(LiftGate.nearMedianDBm)"
        let decision: LiftGate.Decision
        switch answer.kind {
        case .presence(let status):
            let word: String
            switch status {
            case .unlocked: word = "unlocked"
            case .locked: word = "locked"
            case .off: word = "off"
            }
            // 每 2 秒一条：手机的状态变了才写，没变每分钟最多一行
            if logThrottle.shouldLog("presence.\(id)", value: word, at: now, every: Self.repeatLogEvery) {
                Self.log("lift: presence from \(id.uuidString): \(word), nonce \(Self.short(answer.nonce)), counter \(answer.counter), \(rssiText)")
            }
            decision = gate.presence(status, nonce: answer.nonce, at: now)
            if !wasArmed && gate.edgeArmed {
                Self.log("lift: edge armed for \(id.uuidString) (locked seen after cover)")
            }
        case .liftNow:
            Self.log("lift: lift-now request from \(id.uuidString), nonce \(Self.short(answer.nonce)), counter \(answer.counter), \(rssiText)")
            decision = gate.liftNow(nonce: answer.nonce, at: now)
        }
        gates[id] = gate

        let isLiftNow = answer.kind == .liftNow
        let label = isLiftNow ? "lift-now result" : "lift decision"
        switch decision {
        case .lift:
            Self.log("lift: \(label): lifted (\(rssiText))")
            if let reply = authority.liftResultMessage(.lifted, counter: answer.counter, for: id) { send(reply, to: peer) }
            onLift?()
        case .refuse(let why):
            let reason = Self.describe(why)
            if isLiftNow || logThrottle.shouldLog("refuse.\(id)", value: reason, at: now, every: Self.repeatLogEvery) {
                Self.log("lift: \(label): refused, \(reason)")
            }
            if isLiftNow {
                let status = LiftGate.resultStatus(for: why)
                if let reply = authority.liftResultMessage(status, counter: answer.counter, for: id) { send(reply, to: peer) }
            }
        }
    }

    private static func describe(_ refusal: LiftGate.Refusal) -> String {
        switch refusal {
        case .notCovered: return "curtain not covered"
        case .unknownNonce: return "nonce unknown or already used"
        case .staleNonce: return "nonce stale (older than \(Int(LiftGate.challengeLifetime))s or from before cover)"
        case .toggleOff: return "phone setting off"
        case .phoneLocked: return "phone locked"
        case .edgeNotArmed: return "edge rule: no locked report from this phone since cover"
        case .notNear(let median): return "not near (median \(median) < \(LiftGate.nearMedianDBm))"
        case .noRSSI(let samples): return "not near (only \(samples) fresh rssi samples, need \(LiftGate.rssiSamples))"
        }
    }

    private static func short(_ nonce: Data) -> String {
        nonce.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    private func handle(_ command: String, phoneID: UUID, peer: Peer) {
        switch command.lowercased() {
        case "ping":
            // 握手确认 / 重连时表明身份：把现在的幕布状态告诉它
            if let state = authority.stateMessage(closed: curtainClosed, for: phoneID) { send(state, to: peer) }
            if !windowOpen { central?.stopScan() }
        case "unpair":
            Self.log("phone \(phoneID.uuidString) asked to unpair")
            _ = authority.revoke(phoneID)
            gates[phoneID] = nil
            peer.phoneID = nil
            if !isPaired {
                UserDefaults.standard.removeObject(forKey: Self.knownPeripheralsKey)
            } else {
                let known = knownEntries()
                UserDefaults.standard.set(KnownPeripherals.encode(KnownPeripherals.forget(known, phoneID: phoneID)),
                                          forKey: Self.knownPeripheralsKey)
            }
            peer.disconnectAfterWrites = true
            if let inbox = peer.inbox { pump(peer, inbox) }
            if !shouldRun { central?.stopScan() }
        case let other where !other.isEmpty:
            Task { @MainActor in await self.onCommand?(other) }
        default:
            break
        }
    }

    /// 一条连接第一次认出是哪台手机：这个标识的退避 / 拉黑记录都清掉；
    /// 同一台手机别的还没认身份的连接（iPhone 会用好几个标识出现）悄悄断掉，不拉黑
    private func identified(_ peer: Peer, as phoneID: UUID) {
        let id = peer.peripheral.identifier
        ignored.forgive(id)
        identifierBackoff[id] = nil
        discoveryLimiter.succeeded(id)
        let known = knownEntries()
        for other in peers.values where other !== peer && other.phoneID == nil && !other.quietCancel {
            guard KnownPeripherals.phoneID(of: other.peripheral.identifier, in: known) == phoneID else { continue }
            cancelQuietly(other, why: "duplicate link to phone \(phoneID.uuidString), already identified on \(id.uuidString)")
        }
    }

    /// 连上了：这么久还没订阅上发件箱就断开（不拉黑），交给正常重连。只认这一次连接（同一个标识重连了不算）
    private func scheduleSetupCheck(_ peer: Peer) {
        let id = peer.peripheral.identifier
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.setupTimeout) { [weak self, weak peer] in
            guard let self, let peer, self.peers[id] === peer, !peer.subscribed,
                  peer.peripheral.state == .connected else { return }
            Self.log("peripheral \(id.uuidString) not subscribed within \(Int(Self.setupTimeout))s of connecting; disconnecting")
            self.central?.cancelPeripheralConnection(peer.peripheral)
        }
    }

    /// 窗口关着时订阅上了却说不出身份：等 identifyTimeout，还不说就断开、这个标识暂时不理（限时、翻倍，最多 5 分钟）。
    /// 计时绑在这一次连接上：同一个标识断了又连上，老的计时不会算到新连接头上。
    private func scheduleIdentifyCheck(_ peer: Peer) {
        let id = peer.peripheral.identifier
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.identifyTimeout) { [weak self, weak peer] in
            guard let self, let peer, self.peers[id] === peer, peer.phoneID == nil, !self.windowOpen,
                  peer.peripheral.state == .connected else { return }
            // 配过对、或者是认得的标识：只是限时不理；都不是才本次运行不再理
            let known = self.knownEntries().contains { $0.identifier == id }
            let permanent = !self.isPaired && !known
            if let d = self.ignored.ignore(id, at: Date(), permanent: permanent) {
                Self.log("peripheral \(id.uuidString) did not identify within \(Int(Self.identifyTimeout))s of subscribing; ignoring it for \(Int(d))s")
            } else {
                Self.log("peripheral \(id.uuidString) did not identify within \(Int(Self.identifyTimeout))s of subscribing; ignoring it this session")
            }
            self.central?.cancelPeripheralConnection(peer.peripheral)
        }
    }

    /// 蓝牙这条链路上的每个事件都写一行，卡住时不用猜是物理连接、GATT，还是消息没过来
    static func log(_ text: String) {
        BLELogFile.shared.write(text)
        NSLog("LockCurtain BLE: %@", text)
    }
}

// MARK: - CBCentralManagerDelegate

extension PhonePairing: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Self.log("central state \(central.state.rawValue)")
        switch central.state {
        case .poweredOn:
            if phase == .bluetoothOff || phase == .unauthorized { phase = windowOpen ? .waiting : .idle }
            resume(fresh: true)
        case .poweredOff, .resetting:
            // 蓝牙关掉时系统不会逐个回调断开，连接全都作废：清掉旧连接，否则重新开蓝牙后以为手机还连着，不再扫也不再连
            if !peers.isEmpty {
                Self.log("bluetooth off: dropping \(peers.count) stale peer(s)")
                for peer in peers.values { if let id = peer.phoneID { gates[id]?.resetRSSI() } }
                peers.removeAll()
                updateRSSITimer()
            }
            if central.state == .poweredOff { phase = .bluetoothOff }
        case .unauthorized:
            phase = .unauthorized
        case .unsupported:
            phase = .unsupported
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let id = peripheral.identifier
        // 允许重复上报：已经连着的不再管；还挂着没连上的，它都在广播了还卡着就重挂
        if peers[id] != nil {
            if shouldRun { reissueStalePending(onlyFor: id, discovered: true) }
            return
        }
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "(no name)"
        let firstThisScan = seenThisScan.insert(id).inserted
        guard shouldRun else { return }
        let now = Date()
        if ignored.contains(id, at: now) {
            if firstThisScan { Self.log("discovered \(id.uuidString) name=\(name) rssi=\(RSSI) (ignored for now)") }
            return
        }
        // 手机在广播我们的服务（App 在跑）：马上连。退避中（早断 / 这个标识没服务）也是第一次扫到马上连，
        // 之后同一个标识每 30 秒最多一次——每个广播包都报一次，连上就断的话不能每包都连。
        // 早断计数只在订阅 / 认出身份成功时才清零
        let holding = holdingAfterEarlyDrops || (identifierBackoff[id]?.holding(at: now) ?? false)
        guard discoveryLimiter.allow(id, holding: holding, at: now) else {
            if logThrottle.shouldLog("discover.hold.\(id)", value: "held", at: now, every: Self.repeatLogEvery) {
                Self.log("backoff: \(id.uuidString) discovered during backoff; next connect in \(Int(discoveryLimiter.remaining(id, at: now)))s")
            }
            return
        }
        Self.log("discovered \(id.uuidString) name=\(name) rssi=\(RSSI)\(holding ? " (during backoff: at most one connect per \(Int(DiscoveryConnectLimiter<UUID>.interval))s)" : "")")
        connect(peripheral, reason: holding ? "discovered by scan during backoff" : "discovered by scan")
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Self.log("connected \(peripheral.identifier.uuidString)")
        let peer = peers[peripheral.identifier] ?? Peer(peripheral)
        peers[peripheral.identifier] = peer
        peer.connectedAt = Date()
        peer.pendingSince = nil
        peer.ignoreStaleDisconnect = false
        peripheral.delegate = self
        // 同一台手机已经在别的标识上认过身份：这条是重复的，悄悄断掉（不拉黑）
        if let phone = KnownPeripherals.phoneID(of: peripheral.identifier, in: knownEntries()),
           peers.values.contains(where: { $0 !== peer && $0.phoneID == phone }) {
            cancelQuietly(peer, why: "duplicate link to phone \(phone.uuidString), already identified on another identifier")
            return
        }
        peripheral.discoverServices([Self.serviceUUID])
        updateRSSITimer()
        scheduleSetupCheck(peer)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        if ignoreStaleCallback(for: peripheral, what: "connect failure") { return }
        Self.log("failed to connect \(peripheral.identifier.uuidString): \(error?.localizedDescription ?? "no error")")
        peers[peripheral.identifier] = nil
        startScan()
    }

    /// 重挂的那次之前被取消的连接又报了一次：不理；要是重挂被它吃掉了（又成了没在连），再挂一次
    private func ignoreStaleCallback(for peripheral: CBPeripheral, what: String) -> Bool {
        guard let peer = peers[peripheral.identifier], peer.ignoreStaleDisconnect, peer.connectedAt == nil else { return false }
        peer.ignoreStaleDisconnect = false
        Self.log("ignoring \(what) for \(peripheral.identifier.uuidString) from the cancelled pending connect")
        if peripheral.state == .disconnected, let central {
            peer.pendingSince = Date()
            central.connect(peripheral, options: nil)
        }
        return true
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if ignoreStaleCallback(for: peripheral, what: "disconnect") { return }
        let id = peripheral.identifier
        let peer = peers[id]
        let wasReady = peer?.subscribed ?? false
        let duration = peer?.connectedAt.map { String(format: "%.1fs", Date().timeIntervalSince($0)) } ?? "?"
        Self.log("disconnected \(id.uuidString) after \(duration), ready=\(wasReady): \(error?.localizedDescription ?? "no error")")
        let wasIdentified = peer?.phoneID != nil
        let quiet = peer?.quietCancel ?? false
        let serviceMissing = peer?.serviceMissing ?? false
        if let phone = peer?.phoneID { gates[phone]?.resetRSSI() }
        peers[id] = nil
        updateRSSITimer()
        let now = Date()
        let known = knownEntries().contains { $0.identifier == id }

        if quiet {
            // 我们自己断的（重复连接 / 服务变了 / 链路死了）：不算早断
        } else if serviceMissing && known && isPaired {
            // 认得的手机、但上面没有我们的服务：手机 App 没在跑（被划掉 / 手机重启过），不算早断。
            // 这个标识退避一下再挂；扫描一直开着，App 一打开就扫到、马上连
            var backoff = identifierBackoff[id] ?? ReconnectBackoff(base: Self.missingServiceBase, cap: Self.missingServiceCap)
            let d = backoff.fail(at: now)
            identifierBackoff[id] = backoff
            Self.log("backoff: \(id.uuidString) has no LockCurtain service (phone app not running); not an early drop, re-pending in \(Int(d))s")
            DispatchQueue.main.asyncAfter(deadline: .now() + d + 0.1) { [weak self] in
                guard let self, self.shouldRun, self.peers[id] == nil,
                      self.identifierBackoff[id].map({ !$0.holding(at: Date()) }) ?? false else { return }
                if self.peers.values.contains(where: { $0.phoneID != nil }) { return }
                self.pendKnown(reason: "pending reconnect after missing service backoff", bypassIgnore: false)
            }
        } else if !wasReady && shouldRun && !ignored.contains(id, at: now) {
            switch earlyDrops.noteDrop(paired: isPaired, at: now) {
            case .keepGoing:
                Self.log("early drop \(earlyDrops.drops)/\(EarlyDropPolicy.maxEarlyDrops)")
            case .backoff(let d):
                Self.log("early drop \(earlyDrops.drops) (paired): backoff \(Int(d))s before pending reconnects; scanning stays on")
                scheduleEarlyDropResume(after: d)
            case .stop:
                // 没配过手机（只开着配对窗口）：硬停，等重新打开窗口
                stoppedAfterEarlyDrops = true
                central.stopScan()
                for p in peers.values { central.cancelPeripheralConnection(p.peripheral) }
                Self.log("stopped after \(EarlyDropPolicy.maxEarlyDrops) early drops (not paired); reopen the pairing window to retry")
                return
            }
        }
        guard shouldRun, !ignored.contains(id, at: now) else { startScan(); return }
        if wasIdentified && isPaired {
            if holdingAfterEarlyDrops {
                Self.log("backoff: early-drop hold; not re-pending \(id.uuidString) yet")
            } else {
                connect(peripheral, reason: "pending reconnect after drop")
            }
        }
        startScan()
    }
}

// MARK: - CBPeripheralDelegate

extension PhonePairing: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            Self.log("service not found on \(peripheral.identifier.uuidString): \(error?.localizedDescription ?? "-")")
            peers[peripheral.identifier]?.serviceMissing = true
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.discoverCharacteristics([Self.outboxUUID, Self.inboxUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let peer = peers[peripheral.identifier] else { return }
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == Self.outboxUUID { peer.outbox = characteristic }
            if characteristic.uuid == Self.inboxUUID { peer.inbox = characteristic }
        }
        guard let outbox = peer.outbox, peer.inbox != nil else {
            Self.log("characteristics missing on \(peripheral.identifier.uuidString): \(error?.localizedDescription ?? "-")")
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        Self.log("services ready on \(peripheral.identifier.uuidString) (max write \(peripheral.maximumWriteValueLength(for: .withoutResponse)))")
        peripheral.setNotifyValue(true, for: outbox)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.outboxUUID, let peer = peers[peripheral.identifier] else { return }
        if let error {
            Self.log("subscribe failed on \(peripheral.identifier.uuidString): \(error.localizedDescription)")
            return
        }
        let wasSubscribed = peer.subscribed
        peer.subscribed = characteristic.isNotifying
        Self.log("\(characteristic.isNotifying ? "subscribed" : "unsubscribed") outbox on \(peripheral.identifier.uuidString)")
        if characteristic.isNotifying {
            resetEarlyDrops(reason: "subscribed")
            discoveryLimiter.succeeded(peripheral.identifier)
            // 计时从订阅上开始（不是从连上开始）：手机后台时表明身份要好几秒
            if !wasSubscribed, !windowOpen { scheduleIdentifyCheck(peer) }
        } else if peripheral.state == .connected {
            // 连着却退订了（手机那边服务重建过）：这条连接没用了，断开交给正常重连
            cancelQuietly(peer, why: "outbox no longer notifying")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard invalidatedServices.contains(where: { $0.uuid == Self.serviceUUID }),
              let peer = peers[peripheral.identifier] else { return }
        // 手机的服务重建了（App 重启而连接没断）：旧的特征都作废了，断开交给正常重连
        cancelQuietly(peer, why: "LockCurtain service invalidated (didModifyServices)")
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.outboxUUID, let peer = peers[peripheral.identifier],
              let chunk = characteristic.value, error == nil else { return }
        if let message = peer.assembler.feed(chunk) {
            receive(message, from: peer)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let peer = peers[peripheral.identifier], let inbox = peer.inbox else { return }
        peer.writing = false
        if let error {
            peer.writeErrors += 1
            Self.log("write to inbox of \(peripheral.identifier.uuidString) failed (\(peer.writeErrors)/\(Self.maxWriteErrors)): \(error.localizedDescription)")
            peer.writeQueue.removeAll()
            if peer.writeErrors >= Self.maxWriteErrors {
                cancelQuietly(peer, why: "\(peer.writeErrors) consecutive write errors")
                return
            }
        } else {
            peer.writeErrors = 0
        }
        pump(peer, inbox)
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        let rid = peripheral.identifier.uuidString
        if let error {
            if logThrottle.shouldLog("rssi.\(rid)", value: "failed", at: Date(), every: Self.repeatLogEvery) {
                Self.log("rssi \(rid) read failed: \(error.localizedDescription)")
            }
        } else {
            // 每 2 秒读一次：每分钟最多写一行
            if logThrottle.shouldLog("rssi.\(rid)", value: "ok", at: Date(), every: Self.repeatLogEvery) {
                Self.log("rssi \(rid) \(RSSI) (logged at most once a minute)")
            }
            if let id = peers[peripheral.identifier]?.phoneID {
                var gate = gate(for: id)
                gate.recordRSSI(RSSI.intValue, at: Date())
                gates[id] = gate
            }
        }
    }
}

/// /tmp/lockcurtain-ble.log：一个 DateFormatter、一个一直开着的 FileHandle；满 2 MB 改名成 .1（只留一个）重新开
final class BLELogFile: @unchecked Sendable {
    static let shared = BLELogFile(path: "/tmp/lockcurtain-ble.log")

    private let path: String
    private let lock = NSLock()
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()
    private var handle: FileHandle?
    private var size: UInt64 = 0

    init(path: String) { self.path = path }

    func write(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        let line = Data("[\(formatter.string(from: Date()))] \(text)\n".utf8)
        // 有人把日志删了（想从头看）：重新开一个，别往删掉的文件里写
        if handle == nil || !FileManager.default.fileExists(atPath: path) {
            try? handle?.close()
            open()
        }
        if LogRotation.needsRotation(size: size) {
            try? handle?.close()
            handle = nil
            let old = path + ".1"
            try? FileManager.default.removeItem(atPath: old)
            try? FileManager.default.moveItem(atPath: path, toPath: old)
            open()
        }
        guard let handle else { return }
        handle.write(line)
        size += UInt64(line.count)
    }

    private func open() {
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        handle = FileHandle(forWritingAtPath: path)
        size = (try? handle?.seekToEnd()) ?? 0
    }
}
