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
// 连上了却在服务就绪（订阅上发件箱）之前就断，连续 5 次就停手，写一行 "stopped after 5 early drops"，
// 等配对窗口重新打开再试。
//
// 日志：/tmp/lockcurtain-ble.log，每步一行。不写码、不写钥匙。
// CBCentralManager 的回调都投递到 main 队列，所以这里的 @Published 永远在主线程上改。

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
    /// 配过的手机的外设标识（不是秘密，只用来挂起式重连）
    private static let knownPeripheralsKey = "phonePairing.knownPeripherals"
    private static let maxEarlyDrops = 5
    /// 窗口关着时，连上的手机这么久还没用签名命令表明身份，就断开、本次运行不再连它
    private static let identifyTimeout: TimeInterval = 15

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
    private var stoppedAfterEarlyDrops = false
    private var earlyDrops = 0
    private var rssiTimer: Timer?
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
        init(_ peripheral: CBPeripheral) { self.peripheral = peripheral }
    }
    private var peers: [UUID: Peer] = [:]
    /// 本次运行不再理的外设（窗口关着时连上了却说不出自己是谁）
    private var ignored: Set<UUID> = []

    override init() {
        super.init()
        UserDefaults.standard.removeObject(forKey: Self.legacyPairedKey)
    }

    var isPaired: Bool { authority.isPaired }

    // MARK: - 开始 / 结束

    /// App 启动时（已配过手机）调用：开始找手机。第一次创建 CBCentralManager 会弹系统蓝牙权限。
    func prepare() {
        wantsBluetooth = true
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
        if stoppedAfterEarlyDrops {
            Self.log("pairing window reopened: resuming after early-drop stop")
            stoppedAfterEarlyDrops = false
            earlyDrops = 0
        }
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

    private func resume() {
        guard let central, central.state == .poweredOn, shouldRun else { return }
        // 记得的手机：挂起式连接，它一回来就连上
        let known = (UserDefaults.standard.stringArray(forKey: Self.knownPeripheralsKey) ?? []).compactMap(UUID.init(uuidString:))
        if isPaired, !known.isEmpty {
            for peripheral in central.retrievePeripherals(withIdentifiers: known) where peers[peripheral.identifier] == nil {
                connect(peripheral, reason: "pending reconnect to known phone")
            }
        }
        startScan()
    }

    private func startScan() {
        guard let central, central.state == .poweredOn, shouldRun, !central.isScanning else { return }
        // 已经有一台验明身份的手机连着、窗口也没开：不用再扫
        if !windowOpen, peers.values.contains(where: { $0.phoneID != nil }) { return }
        central.scanForPeripherals(withServices: [Self.serviceUUID],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        Self.log("scan start (window \(windowOpen ? "open" : "closed"), paired \(isPaired))")
    }

    private func connect(_ peripheral: CBPeripheral, reason: String) {
        guard let central else { return }
        let peer = peers[peripheral.identifier] ?? Peer(peripheral)
        peers[peripheral.identifier] = peer
        peripheral.delegate = self
        guard peripheral.state == .disconnected else { return }
        Self.log("connect requested \(peripheral.identifier.uuidString) (\(reason))")
        central.connect(peripheral, options: nil)
    }

    private func remember(_ peripheral: CBPeripheral) {
        var known = UserDefaults.standard.stringArray(forKey: Self.knownPeripheralsKey) ?? []
        guard !known.contains(peripheral.identifier.uuidString) else { return }
        known.append(peripheral.identifier.uuidString)
        UserDefaults.standard.set(known, forKey: Self.knownPeripheralsKey)
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
                peer.phoneID = phoneID
                remember(peer.peripheral)
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
            Self.log("lift: poll skipped for \(id.uuidString): previous write still pending")
            return
        }
        let nonce = PairingCrypto.makeNonce()
        guard let message = authority.pollMessage(nonce: nonce, for: id) else { return }
        var gate = gate(for: id)
        gate.issue(nonce, at: Date())
        gates[id] = gate
        Self.log("lift: poll sent to \(id.uuidString) nonce \(Self.short(nonce))")
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
            Self.log("lift: presence from \(id.uuidString): \(word), nonce \(Self.short(answer.nonce)), counter \(answer.counter), \(rssiText)")
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
            Self.log("lift: \(label): refused, \(Self.describe(why))")
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
            if !isPaired { UserDefaults.standard.removeObject(forKey: Self.knownPeripheralsKey) }
            peer.disconnectAfterWrites = true
            if let inbox = peer.inbox { pump(peer, inbox) }
            if !shouldRun { central?.stopScan() }
        case let other where !other.isEmpty:
            Task { @MainActor in await self.onCommand?(other) }
        default:
            break
        }
    }

    /// 窗口关着时连上一台说不出身份的手机：等一会儿，还不说就断开、本次运行不再连它
    private func scheduleIdentifyCheck(_ peer: Peer) {
        let id = peer.peripheral.identifier
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.identifyTimeout) { [weak self] in
            guard let self, let peer = self.peers[id], peer.phoneID == nil, !self.windowOpen,
                  peer.peripheral.state == .connected else { return }
            Self.log("peripheral \(id.uuidString) did not identify within \(Int(Self.identifyTimeout))s; ignoring it this session")
            self.ignored.insert(id)
            self.central?.cancelPeripheralConnection(peer.peripheral)
        }
    }

    /// 蓝牙这条链路上的每个事件都写一行，卡住时不用猜是物理连接、GATT，还是消息没过来
    static func log(_ text: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let line = "[\(formatter.string(from: Date()))] \(text)\n"
        let path = "/tmp/lockcurtain-ble.log"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
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
            resume()
        case .poweredOff:
            phase = .bluetoothOff
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
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "(no name)"
        Self.log("discovered \(peripheral.identifier.uuidString) name=\(name) rssi=\(RSSI)")
        guard shouldRun, !ignored.contains(peripheral.identifier) else { return }
        connect(peripheral, reason: "discovered by scan")
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Self.log("connected \(peripheral.identifier.uuidString)")
        let peer = peers[peripheral.identifier] ?? Peer(peripheral)
        peers[peripheral.identifier] = peer
        peer.connectedAt = Date()
        peripheral.delegate = self
        peripheral.discoverServices([Self.serviceUUID])
        updateRSSITimer()
        if !windowOpen { scheduleIdentifyCheck(peer) }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Self.log("failed to connect \(peripheral.identifier.uuidString): \(error?.localizedDescription ?? "no error")")
        peers[peripheral.identifier] = nil
        startScan()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let peer = peers[peripheral.identifier]
        let wasReady = peer?.subscribed ?? false
        let duration = peer?.connectedAt.map { String(format: "%.1fs", Date().timeIntervalSince($0)) } ?? "?"
        Self.log("disconnected \(peripheral.identifier.uuidString) after \(duration), ready=\(wasReady): \(error?.localizedDescription ?? "no error")")
        let wasIdentified = peer?.phoneID != nil
        if let id = peer?.phoneID { gates[id]?.resetRSSI() }
        peers[peripheral.identifier] = nil
        updateRSSITimer()

        if !wasReady && shouldRun && !ignored.contains(peripheral.identifier) {
            earlyDrops += 1
            Self.log("early drop \(earlyDrops)/\(Self.maxEarlyDrops)")
            if earlyDrops >= Self.maxEarlyDrops {
                stoppedAfterEarlyDrops = true
                central.stopScan()
                for p in peers.values { central.cancelPeripheralConnection(p.peripheral) }
                Self.log("stopped after \(Self.maxEarlyDrops) early drops; reopen the pairing window to retry")
                return
            }
        }
        guard shouldRun, !ignored.contains(peripheral.identifier) else { return }
        if wasIdentified && isPaired {
            connect(peripheral, reason: "pending reconnect after drop")
        }
        startScan()
    }
}

// MARK: - CBPeripheralDelegate

extension PhonePairing: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            Self.log("service not found on \(peripheral.identifier.uuidString): \(error?.localizedDescription ?? "-")")
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
        peer.subscribed = characteristic.isNotifying
        Self.log("\(characteristic.isNotifying ? "subscribed" : "unsubscribed") outbox on \(peripheral.identifier.uuidString)")
        if characteristic.isNotifying { earlyDrops = 0 }
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
            Self.log("write to inbox of \(peripheral.identifier.uuidString) failed: \(error.localizedDescription)")
            peer.writeQueue.removeAll()
        }
        pump(peer, inbox)
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        if let error {
            Self.log("rssi \(peripheral.identifier.uuidString) read failed: \(error.localizedDescription)")
        } else {
            Self.log("rssi \(peripheral.identifier.uuidString) \(RSSI)")
            if let id = peers[peripheral.identifier]?.phoneID {
                var gate = gate(for: id)
                gate.recordRSSI(RSSI.intValue, at: Date())
                gates[id] = gate
            }
        }
    }
}
