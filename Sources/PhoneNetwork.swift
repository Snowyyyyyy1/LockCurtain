// PhoneNetwork.swift —— 手机走网络（TCP）连这台电脑：Mac 端的监听和连接管理
//
// 只依赖 Foundation / Network / CryptoKit（没有 AppKit、没有 CoreBluetooth），自测直接在进程里起一个真的 NetworkGateway。
// 安全全在 PairingCrypto / PairingAuthority（通过 via: .network）：这里只是字节管道 + 加固：
//   * 帧：2 字节大端长度 + 一整条 PairingCrypto 消息（NetFraming），长度 0 或超过 1024 立刻断开
//   * 手机只能 ping / away / awake:* / name:，其余（撤下、解除配对、预览、设置、配对、Presence、LiftNow）
//     在权威端（NetworkPolicy）默认拒绝；Presence / LiftNow / 配对帧这里根本不交给权威端
//   * 连上后 5 秒内必须有一条验过的签名命令，否则断开；同时最多 4 条还没验过的连接
//   * 一条连接上 3 个坏帧：断开，这个 IP 60 秒内不再理；验过之后 120 秒没有验过的帧也断开；打开 TCP keepalive
//   * 端口：49200–49999 里挑一个存进 UserDefaults（phoneNet.port），以后一直用，占用了才换
//   * 每条网络连接上（认出手机后、以及每次回 Ack 之后）发一条签名的 Poll 当新鲜度挑战：
//     手机之后的命令要带这里面的 nonce（n1:<nonce>:<命令>），单次有效，不进 LiftGate
//
// 所有回调都在 queue（默认主队列）上；内部状态也只在 queue 上碰。

import CryptoKit
import Foundation
import Network

// MARK: - 本机地址

/// 给手机抄的地址：一个网卡上的一个 IP
struct NetworkAddressEntry: Equatable {
    enum Kind: Int, Equatable {
        case wifi = 0
        case ethernet = 1
        case tailscale = 2
        case other = 3

        // COPY-TODO: 标签文案来自方案（Wi-Fi / 以太网 / Tailscale / 其他），待文案定稿
        var label: String {
            switch self {
            case .wifi: return "Wi-Fi"
            case .ethernet: return "以太网"
            case .tailscale: return "Tailscale"
            case .other: return "其他"
            }
        }
    }

    var kind: Kind
    var interface: String
    var host: String
    var isIPv6: Bool

    /// 手机里填的样子：ip:port，IPv6 用 [::]:port
    func text(port: UInt16) -> String {
        isIPv6 ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    var label: String { kind.label }
}

enum NetworkAddresses {
    /// 枚举本机地址（getifaddrs）：IPv4 + 全局 / ULA 的 IPv6，不要 lo0、169.254、fe80。
    /// interfaceTypes：NWPathMonitor 报的网卡类型（en0 是 Wi-Fi 还是以太网只有它知道）
    static func current(interfaceTypes: [String: NWInterface.InterfaceType] = [:]) -> [NetworkAddressEntry] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var out: [NetworkAddressEntry] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            cursor = ifa.pointee.ifa_next
            let flags = Int32(ifa.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  let sa = ifa.pointee.ifa_addr else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            guard name != "lo0" else { continue }
            let family = Int32(sa.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let host = String(cString: buffer)
            guard let entry = classify(host: host, interface: name, isIPv6: family == AF_INET6,
                                       type: interfaceTypes[name]) else { continue }
            if !out.contains(entry) { out.append(entry) }
        }
        return out.sorted {
            ($0.kind.rawValue, $0.isIPv6 ? 1 : 0, $0.interface, $0.host) < ($1.kind.rawValue, $1.isIPv6 ? 1 : 0, $1.interface, $1.host)
        }
    }

    /// 一个地址要不要列、算哪一类（纯函数，自测用）
    static func classify(host rawHost: String, interface: String, isIPv6: Bool,
                         type: NWInterface.InterfaceType?) -> NetworkAddressEntry? {
        let host = rawHost.split(separator: "%", maxSplits: 1).first.map(String.init) ?? rawHost
        let lower = host.lowercased()
        if isIPv6 {
            // 只要全局（2000::/3）和 ULA（fc00::/7）；fe80（链路本地）、::1、:: 都不要
            let firstGroup = lower.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            guard let word = UInt16(firstGroup.isEmpty ? "0" : firstGroup, radix: 16) else { return nil }
            let isGlobal = word & 0xE000 == 0x2000
            let isULA = word & 0xFE00 == 0xFC00
            guard isGlobal || isULA else { return nil }
        } else {
            let parts = host.split(separator: ".").compactMap { Int($0) }
            guard parts.count == 4, parts[0] != 127, parts[0] != 0, !(parts[0] == 169 && parts[1] == 254) else { return nil }
        }
        let isUtun = interface.hasPrefix("utun")
        let kind: NetworkAddressEntry.Kind
        if isUtun, isTailscale(host: lower, isIPv6: isIPv6) {
            kind = .tailscale
        } else if isUtun {
            kind = .other
        } else {
            switch type {
            case .wifi?: kind = .wifi
            case .wiredEthernet?: kind = .ethernet
            default: kind = .other
            }
        }
        return NetworkAddressEntry(kind: kind, interface: interface, host: host, isIPv6: isIPv6)
    }

    /// Tailscale：IPv4 在 100.64.0.0/10（CGNAT），IPv6 在 fd7a:115c:a1e0::/48
    static func isTailscale(host: String, isIPv6: Bool) -> Bool {
        if isIPv6 { return host.hasPrefix("fd7a:115c:a1e0:") }
        let p = host.split(separator: ".").compactMap { Int($0) }
        return p.count == 4 && p[0] == 100 && (64...127).contains(p[1])
    }
}

// MARK: - 网关

// @unchecked Sendable：所有状态只在 queue 上碰
final class NetworkGateway: @unchecked Sendable {
    /// 认出来的网络手机
    struct Peer: Equatable {
        var phoneID: UUID
        /// 手机报的名字（name: 命令），没报过是 nil
        var name: String?
        /// 对端 IP（不带端口）
        var remote: String
    }

    enum Status: Equatable {
        case stopped
        case starting
        case listening(port: UInt16)
        /// 监听没起来（端口占用换了几次还不行、防火墙 / 没有网络等）
        case failed(String)
    }

    enum PortChoice: Equatable {
        /// 49200–49999 里挑一个存进 UserDefaults，以后一直用
        case persisted
        /// 系统分配（自测用）
        case ephemeral
    }

    static let portRange: ClosedRange<UInt16> = 49200...49999
    static let portDefaultsKey = "phoneNet.port"

    // 加固参数（自测可以改短）
    var pingDeadline: TimeInterval = 5
    var idleTimeout: TimeInterval = 120
    var maxUnauthenticated = 4
    var maxBadFrames = 3
    var banDuration: TimeInterval = 60
    /// 手机名最多存多少字节（和蓝牙一样）
    var maxNameBytes = 64

    // 接线（回调都在 queue 上）
    /// Mac 有没有辅助功能：没有就不盖，回签名的 Ack 4
    var canCover: () -> Bool = { true }
    /// 放行的命令（ping 除外）：away、awake:off|1h|2h|5h|always（小写）、name:<名字>（原样）。
    /// 收据已经先发了；awake: 之后网关自己会把保持唤醒状态报给所有网络手机
    var onCommand: (_ command: String, _ phoneID: UUID) -> Void = { _, _ in }
    var curtainClosed: () -> Bool = { false }
    var keepAwakeState: () -> (mode: PairingCrypto.KeepAwakeMode, endsAt: UInt64, appName: String) = { (.off, 0, "") }
    /// 认出一台手机 / 一台断了 / 名字变了
    var onPeersChanged: (() -> Void)?
    var onStatusChanged: (() -> Void)?
    var onAddressesChanged: (() -> Void)?
    /// 一条连接第一次验过（认出是哪台手机）：给 UI 记「最后连上」
    var onPeerIdentified: ((UUID) -> Void)?
    /// 日志：不写钥匙、不写 nonce
    var log: (String) -> Void = { NSLog("LockCurtain net: %@", $0) }

    private(set) var status: Status = .stopped {
        didSet { if status != oldValue { onStatusChanged?() } }
    }
    /// 现在监听的端口；没在监听是 nil
    var port: UInt16? {
        if case .listening(let p) = status { return p }
        return nil
    }
    private(set) var addresses: [NetworkAddressEntry] = []

    /// 认出身份的网络手机
    var peers: [Peer] {
        conns.values.compactMap { c in
            guard c.authenticated, let id = c.phoneID else { return nil }
            return Peer(phoneID: id, name: c.name, remote: c.ip)
        }.sorted { $0.phoneID.uuidString < $1.phoneID.uuidString }
    }

    /// 现在开着的连接数（含还没验过的）
    var connectionCount: Int { conns.count }

    private let authority: PairingAuthority
    private let defaults: UserDefaults
    private let queue: DispatchQueue
    private let choice: PortChoice
    private let loopbackOnly: Bool

    private var listener: NWListener?
    private var monitor: NWPathMonitor?
    private var timer: DispatchSourceTimer?
    private var conns: [UUID: Conn] = [:]
    private var bans: [String: Date] = [:]
    private var interfaceTypes: [String: NWInterface.InterfaceType] = [:]
    private var generation = 0
    private var portRetries = 0

    private final class Conn {
        let id = UUID()
        let nw: NWConnection
        let ip: String
        let acceptedAt = Date()
        var lastVerified = Date()
        var reader = NetFraming.Reader()
        var phoneID: UUID?
        var name: String?
        var authenticated = false
        var badFrames = 0
        var closed = false

        init(nw: NWConnection, ip: String) {
            self.nw = nw
            self.ip = ip
        }
    }

    /// loopbackOnly：只绑 127.0.0.1（自测）
    init(authority: PairingAuthority, port: PortChoice = .persisted, loopbackOnly: Bool = false,
         defaults: UserDefaults = .standard, queue: DispatchQueue = .main) {
        self.authority = authority
        self.choice = port
        self.loopbackOnly = loopbackOnly
        self.defaults = defaults
        self.queue = queue
    }

    // MARK: - 端口

    /// 存着的端口；没有（或不在范围内）就挑一个存起来
    static func persistedPort(defaults: UserDefaults = .standard) -> UInt16 {
        if let v = defaults.object(forKey: portDefaultsKey) as? Int, let p = UInt16(exactly: v), portRange.contains(p) { return p }
        return choosePort(defaults: defaults)
    }

    @discardableResult
    static func choosePort(defaults: UserDefaults = .standard) -> UInt16 {
        let p = UInt16.random(in: portRange)
        defaults.set(Int(p), forKey: portDefaultsKey)
        return p
    }

    // MARK: - 开关

    /// 开始监听（异步，状态变化走 onStatusChanged / status）
    func start() {
        queue.async { [self] in
            guard listener == nil, status != .starting else { return }
            portRetries = 0
            beginListening(port: choice == .persisted ? Self.persistedPort(defaults: defaults) : nil)
        }
    }

    /// 停止监听并关掉所有连接（异步）
    func stop() {
        queue.async { [self] in stopNow() }
    }

    /// 必须在 queue 上调
    func stopNow() {
        generation += 1
        listener?.cancel()
        listener = nil
        monitor?.cancel()
        monitor = nil
        timer?.cancel()
        timer = nil
        let open = Array(conns.values)
        let hadPeers = open.contains { $0.authenticated }
        for c in open { close(c, "gateway stopped", notify: false) }
        if hadPeers { onPeersChanged?() }
        if status != .stopped { log("phone network stopped") }
        status = .stopped
        if !addresses.isEmpty {
            addresses = []
            onAddressesChanged?()
        }
    }

    private func beginListening(port: UInt16?) {
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 30
        tcp.keepaliveInterval = 10
        tcp.keepaliveCount = 3
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.allowLocalEndpointReuse = true
        let nwPort = port.flatMap(NWEndpoint.Port.init(rawValue:))
        if loopbackOnly {
            params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: nwPort ?? .any)
        }
        let made: NWListener
        do {
            if !loopbackOnly, let nwPort {
                made = try NWListener(using: params, on: nwPort)
            } else {
                made = try NWListener(using: params)
            }
        } catch {
            fail(error, port: port)
            return
        }
        generation += 1
        let mine = generation
        listener = made
        status = .starting
        made.newConnectionLimit = 64
        made.newConnectionHandler = { [weak self] nw in
            guard let self, self.generation == mine else { nw.cancel(); return }
            self.accept(nw)
        }
        made.stateUpdateHandler = { [weak self] state in
            guard let self, self.generation == mine else { return }
            switch state {
            case .ready:
                guard let p = made.port?.rawValue else { return }
                self.status = .listening(port: p)
                self.log("phone network listening on port \(p)")
                self.startMonitoring()
            case .failed(let error):
                made.cancel()
                self.listener = nil
                self.fail(error, port: port)
            case .waiting(let error):
                self.status = .failed("\(error)")
            default:
                break
            }
        }
        made.start(queue: queue)
        startTimer()
    }

    /// 监听没起来：端口被占了就换一个（存起来），最多 5 次
    private func fail(_ error: Error, port: UInt16?) {
        log("phone network: listen failed: \(error)")
        var inUse = false
        if let e = error as? NWError, case .posix(let code) = e, code == .EADDRINUSE { inUse = true }
        if choice == .persisted, inUse, portRetries < 5 {
            portRetries += 1
            let next = Self.choosePort(defaults: defaults)
            log("phone network: port \(port.map(String.init) ?? "?") busy, trying \(next)")
            beginListening(port: next)
            return
        }
        status = .failed("\(error)")
    }

    private func startMonitoring() {
        guard monitor == nil else { return refreshAddresses() }
        let m = NWPathMonitor()
        let mine = generation
        m.pathUpdateHandler = { [weak self] path in
            guard let self, self.generation == mine else { return }
            var types: [String: NWInterface.InterfaceType] = [:]
            for i in path.availableInterfaces { types[i.name] = i.type }
            self.interfaceTypes = types
            self.refreshAddresses()
        }
        monitor = m
        m.start(queue: queue)
        refreshAddresses()
    }

    func refreshAddresses() {
        let fresh = NetworkAddresses.current(interfaceTypes: interfaceTypes)
        guard fresh != addresses else { return }
        addresses = fresh
        onAddressesChanged?()
    }

    private func startTimer() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.25, repeating: 0.25)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        let now = Date()
        bans = bans.filter { $0.value > now }
        for c in Array(conns.values) where !c.closed {
            if !c.authenticated {
                if now.timeIntervalSince(c.acceptedAt) > pingDeadline { close(c, "no verified command within \(Int(pingDeadline))s") }
            } else if now.timeIntervalSince(c.lastVerified) > idleTimeout {
                close(c, "idle for \(Int(idleTimeout))s")
            }
        }
    }

    /// 清掉 IP 封禁（自测用）
    func clearBans() { bans = [:] }

    func isBanned(_ ip: String) -> Bool { (bans[ip] ?? .distantPast) > Date() }

    // MARK: - 连接

    private static func ip(of endpoint: NWEndpoint) -> String {
        guard case .hostPort(let host, _) = endpoint else { return "?" }
        var text: String
        switch host {
        case .ipv4(let a): text = "\(a)"
        case .ipv6(let a): text = "\(a)"
        case .name(let n, _): text = n
        @unknown default: text = "\(host)"
        }
        if let i = text.firstIndex(of: "%") { text = String(text[..<i]) }
        if text.lowercased().hasPrefix("::ffff:"), text.contains(".") { text = String(text.dropFirst(7)) }
        return text
    }

    private func accept(_ nw: NWConnection) {
        let ip = Self.ip(of: nw.endpoint)
        if isBanned(ip) {
            log("connection from \(ip) refused: banned")
            nw.cancel()
            return
        }
        let unauthenticated = conns.values.filter { !$0.authenticated }.count
        if unauthenticated >= maxUnauthenticated {
            log("connection from \(ip) refused: \(unauthenticated) unauthenticated connections already open")
            nw.cancel()
            return
        }
        let c = Conn(nw: nw, ip: ip)
        conns[c.id] = c
        nw.stateUpdateHandler = { [weak self, weak c] state in
            guard let self, let c else { return }
            switch state {
            case .failed, .cancelled:
                self.close(c, "connection ended")
            case .waiting:
                self.close(c, "connection waiting")
            default:
                break
            }
        }
        nw.start(queue: queue)
        receive(c)
    }

    private func receive(_ c: Conn) {
        c.nw.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self, weak c] data, _, isComplete, error in
            guard let self, let c, !c.closed else { return }
            if let data, !data.isEmpty {
                for frame in c.reader.feed(data) {
                    guard !c.closed else { return }
                    self.handle(frame, from: c)
                }
                if !c.closed, c.reader.isBroken {
                    self.close(c, "bad frame length")
                    return
                }
            }
            if error != nil || isComplete {
                self.close(c, error == nil ? "peer closed" : "receive error")
                return
            }
            if !c.closed { self.receive(c) }
        }
    }

    private func close(_ c: Conn, _ why: String, notify: Bool = true) {
        guard !c.closed else { return }
        c.closed = true
        conns[c.id] = nil
        c.nw.stateUpdateHandler = nil
        c.nw.cancel()
        log("connection from \(c.ip) closed: \(why)")
        if c.authenticated, notify { onPeersChanged?() }
    }

    /// thenClose：写完这一条再断开（不再收这条连接上的东西）
    private func send(_ message: Data, to c: Conn, thenClose: String? = nil) {
        guard !c.closed, let framed = NetFraming.frame(message) else { return }
        c.nw.send(content: framed, completion: .contentProcessed { [weak self, weak c] _ in
            guard let self, let c, let why = thenClose else { return }
            self.queue.async { self.close(c, why) }
        })
    }

    /// 坏帧：满 maxBadFrames 个就断开并封这个 IP
    private func badFrame(_ c: Conn, _ why: String, reply: Data? = nil) {
        c.badFrames += 1
        log("bad frame from \(c.ip): \(why) (\(c.badFrames)/\(maxBadFrames))")
        let ban = c.badFrames >= maxBadFrames
        if ban {
            bans[c.ip] = Date().addingTimeInterval(banDuration)
            log("\(c.ip) banned for \(Int(banDuration))s")
        }
        if let reply {
            send(reply, to: c, thenClose: ban ? "too many bad frames" : nil)
        } else if ban {
            close(c, "too many bad frames")
        }
    }

    // MARK: - 处理一帧

    private func handle(_ message: Data, from c: Conn) {
        switch PairingCrypto.kind(of: message) {
        case .command?:
            handleCommand(message, from: c)
        case .pairRequest?, .pairConfirm?, .pairAbort?:
            // 配对只走蓝牙：不交给权威端，不回话
            badFrame(c, "pairing message over network")
        case .presence?, .liftNow?:
            // 撤下只走蓝牙：不交给权威端（不耗计数、够不到 LiftGate）
            badFrame(c, "lift message over network")
        default:
            badFrame(c, "unexpected message kind")
        }
    }

    private func handleCommand(_ message: Data, from c: Conn) {
        switch authority.handleCommand(message, via: .network) {
        case .accepted(let command, let phoneID, let counter, _, let ack):
            if let known = c.phoneID, known != phoneID {
                badFrame(c, "connection switched phone")
                return
            }
            c.lastVerified = Date()
            // 没给辅助功能就不盖，回签名的「缺权限」
            if command.lowercased() == "away", !canCover() {
                log("network command \"away\" from \(phoneID.uuidString) refused: accessibility permission missing (ack 4)")
                send(authority.missingPermissionAck(counter: counter, for: phoneID) ?? ack, to: c)
                identify(c, as: phoneID)
                sendPoll(to: c, phoneID: phoneID)
                return
            }
            send(ack, to: c)
            identify(c, as: phoneID)
            dispatch(command, phoneID: phoneID, to: c)
            sendPoll(to: c, phoneID: phoneID)
        case .rejected(let reason, let phoneID, let ack):
            switch reason {
            case .networkForbidden:
                // 签名对、计数已记，只是不许：回签名的 Ack 5。不算认过身份，也不算坏帧
                if let ack { send(ack, to: c) }
                if let phoneID, c.authenticated { c.lastVerified = Date(); sendPoll(to: c, phoneID: phoneID) }
            case .badNonce:
                // nonce 缺 / 过期 / 用过：Ack 2，再给一个新的
                if let ack { send(ack, to: c) }
                if let phoneID { sendPoll(to: c, phoneID: phoneID) }
            case .replay, .storeFailed:
                if let ack { send(ack, to: c) }
            case .malformed, .unknownPhone, .badSignature:
                badFrame(c, reason.rawValue, reply: ack)
            }
        }
    }

    private func identify(_ c: Conn, as phoneID: UUID) {
        guard !c.authenticated else { return }
        c.authenticated = true
        c.phoneID = phoneID
        // 同一台手机的旧连接（网络换了、手机重连）让位
        for other in Array(conns.values) where other !== c && other.phoneID == phoneID {
            close(other, "replaced by a newer connection from the same phone", notify: false)
        }
        log("network phone \(phoneID.uuidString) identified from \(c.ip)")
        onPeerIdentified?(phoneID)
        onPeersChanged?()
    }

    private func dispatch(_ command: String, phoneID: UUID, to c: Conn) {
        if command.hasPrefix("name:") {
            let trimmed = String(command.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
            let name = String(decoding: PairingCrypto.utf8Prefix(trimmed, maxBytes: maxNameBytes), as: UTF8.self)
            c.name = name
            onPeersChanged?()
            onCommand("name:" + name, phoneID)
            return
        }
        let lower = command.lowercased()
        if lower == "ping" {
            // 握手确认 / 重连时表明身份：把现在的幕布状态、保持唤醒状态告诉它
            if let state = authority.stateMessage(closed: curtainClosed(), for: phoneID) { send(state, to: c) }
            sendKeepAwake(to: c, phoneID: phoneID)
            return
        }
        onCommand(lower, phoneID)
        if lower.hasPrefix("awake:") { pushKeepAwake() }
    }

    private func sendPoll(to c: Conn, phoneID: UUID) {
        guard let poll = authority.networkPollMessage(for: phoneID) else { return }
        send(poll, to: c)
    }

    private func sendKeepAwake(to c: Conn, phoneID: UUID) {
        let s = keepAwakeState()
        if let m = authority.keepAwakeStateMessage(mode: s.mode, endsAt: s.endsAt, appName: s.appName, for: phoneID) {
            send(m, to: c)
        }
    }

    private func pushKeepAwake() {
        for c in conns.values where c.authenticated {
            if let id = c.phoneID { sendKeepAwake(to: c, phoneID: id) }
        }
    }

    // MARK: - 往手机推

    /// 幕布盖上 / 撤下了：报给所有认过身份的网络手机
    func reportCurtain(closed: Bool) {
        queue.async { [self] in
            for c in conns.values where c.authenticated {
                if let id = c.phoneID, let m = authority.stateMessage(closed: closed, for: id) { send(m, to: c) }
            }
        }
    }

    /// 保持唤醒状态变了：报给所有认过身份的网络手机
    func reportKeepAwake() {
        queue.async { [self] in pushKeepAwake() }
    }

    /// 在电脑上撤销了这台手机：把签名的撤销通知发给它的网络连接，发完断开
    func notifyRevoked(_ phoneID: UUID, notice: Data?) {
        queue.async { [self] in
            authority.dropNetworkNonces(for: phoneID)
            for c in Array(conns.values) where c.phoneID == phoneID {
                if let notice { send(notice, to: c, thenClose: "phone revoked") } else { close(c, "phone revoked") }
            }
        }
    }

    /// 断开这台手机的网络连接（不发通知）
    func disconnect(_ phoneID: UUID) {
        queue.async { [self] in
            for c in Array(conns.values) where c.phoneID == phoneID { close(c, "disconnected by the computer") }
        }
    }
}
