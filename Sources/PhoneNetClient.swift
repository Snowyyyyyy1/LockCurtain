// PhoneNetClient.swift —— 手机走网络（TCP）连电脑的客户端（平台无关：Mac 的自测和 iPhone 共用同一份源文件）
//
// 只依赖 Foundation / Network / CryptoKit，不碰钥匙串：计数、钥匙、手机标识都通过闭包给进来。
// 电脑是服务端（NetworkGateway），手机是客户端；帧是 2 字节大端长度 + 一整条 PairingCrypto 消息（NetFraming）。
//
// 这里是手机走网络的「守门人」，只把验过、新鲜的东西交给上层（onMessage）：
//   * Ack：签名（或没签名的 1/2/3）且 counter 对得上一条还在等的命令才算；签名的 Ack 才把状态变成 ready。
//     录下来的旧 Ack 被假服务器重放，对不上 pending 计数，不会让界面显示「已连接」
//   * State / KeepAwakeState：签名对，seq（电脑的毫秒时钟）和手机时钟差不超过 ±5 分钟，且比这条连接上见过的新
//   * Poll：只是存起来当下一条命令的 nonce（不交给上层）；Revoke：签名对就交上去
//   * 除 ping 外，每条命令发出去时包成 n1:<nonce>:<命令>（nonce 单次有效），没有 nonce 就发不出去（.noNonce）
//   * 电脑回 Ack 2（nonce 过期 / 用过）时，自动补发一条 ping 拿新的 nonce
// 连上后立刻发一条 ping（电脑据此认出是哪台手机，回 Ack + State + KeepAwakeState + Poll）；之后每 45 秒一条 ping 当心跳。
// 断了按 ReconnectBackoff（1 秒 → 30 秒）一直重连，直到 stop()；一次验过的签名 Ack 把退避清零。
//
// 所有回调都在 queue（默认主队列）上。

import CryptoKit
import Foundation
import Network

// @unchecked Sendable：所有状态只在 queue 上碰（回调都投递到 queue）
final class PhoneNetClient: @unchecked Sendable {
    enum State: Equatable {
        case stopped
        /// 正在建 TCP 连接
        case connecting
        /// TCP 通了，ping 已发，还没等到签名的 Ack
        case connected
        /// 验过一条签名的 Ack（对得上我们发的命令）：电脑认得我们
        case ready
        /// 断了，这么多秒后重连
        case waiting(retryIn: TimeInterval)
    }

    enum SendResult: Equatable {
        case sent(counter: UInt64)
        /// 还没连上 / 还没 ready（除 ping 外的命令要等电脑认出我们）
        case notReady
        /// 没有电脑给的、可用的 nonce（等下一条 Poll，或先发 ping）
        case noNonce
        /// 计数 / 钥匙 / 手机标识拿不到，或命令太长
        case unavailable
    }

    // 接线
    /// 发命令前调用：计数加一并先存好，存成功才返回
    var reserveCounter: () -> UInt64? = { nil }
    /// 配对钥匙；没有就什么都不发
    var key: () -> SymmetricKey? = { nil }
    var phoneID: () -> UUID? = { nil }
    /// 验过、新鲜的消息（Ack / State / KeepAwakeState / Revoke），原始字节
    var onMessage: (Data) -> Void = { _ in }
    var onStateChange: ((State) -> Void)?
    var log: (String) -> Void = { _ in }

    // 参数（自测可以改）
    var heartbeatInterval: TimeInterval = 45
    var connectTimeout: TimeInterval = 10
    /// State / KeepAwakeState 的 seq（毫秒）和手机时钟最多差多少
    var maxClockSkew: TimeInterval = 300
    /// 手机这边留 nonce 的寿命（比电脑的 90 秒短一点）
    var nonceLifetime: TimeInterval = 80
    var pendingLifetime: TimeInterval = 30
    var now: () -> Date = Date.init

    private(set) var state: State = .stopped {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    var isReady: Bool { state == .ready }

    private let queue: DispatchQueue
    private var host = ""
    private var port: UInt16 = 0
    private var wanted = false
    private var generation = 0
    private var connection: NWConnection?
    private var reader = NetFraming.Reader()
    private var backoff = ReconnectBackoff(base: 1, cap: 30)
    private var heartbeat: DispatchSourceTimer?
    private var pending: [UInt64: Date] = [:]
    private var nonces: [(nonce: Data, at: Date)] = []
    private var lastSeq: UInt64 = 0
    private var lastRecoveryPing = Date.distantPast

    init(queue: DispatchQueue = .main) {
        self.queue = queue
    }

    // MARK: - 开关

    /// 连这个地址并一直保持（断了自动重连）。host 是 IPv4 / IPv6（不带方括号）/ 主机名
    func start(host: String, port: UInt16) {
        queue.async { [self] in
            var h = host.trimmingCharacters(in: .whitespaces)
            if h.hasPrefix("["), h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
            tearDown()
            self.host = h
            self.port = port
            wanted = true
            backoff.reset()
            connect()
        }
    }

    func stop() {
        queue.async { [self] in
            wanted = false
            tearDown()
            state = .stopped
        }
    }

    private func tearDown() {
        generation += 1
        heartbeat?.cancel()
        heartbeat = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        reader = NetFraming.Reader()
        pending = [:]
        nonces = []
        lastSeq = 0
    }

    private func connect() {
        guard wanted, let nwPort = NWEndpoint.Port(rawValue: port), !host.isEmpty else { return }
        tearDown()
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 30
        tcp.keepaliveInterval = 10
        tcp.keepaliveCount = 3
        tcp.noDelay = true
        // 连不上就是连不上：不要因为暂时没网络让系统挂起等
        let params = NWParameters(tls: nil, tcp: tcp)
        params.preferNoProxies = true
        let nw = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
        connection = nw
        let mine = generation
        state = .connecting
        nw.stateUpdateHandler = { [weak self] s in
            guard let self, self.generation == mine else { return }
            switch s {
            case .ready:
                self.didConnect()
            case .failed(let e):
                self.lost("connection failed: \(e)")
            case .waiting(let e):
                self.lost("connection waiting: \(e)")
            case .cancelled:
                break
            default:
                break
            }
        }
        nw.start(queue: queue)
        queue.asyncAfter(deadline: .now() + connectTimeout) { [weak self] in
            guard let self, self.generation == mine, self.state == .connecting else { return }
            self.lost("connect timed out")
        }
    }

    private func didConnect() {
        state = .connected
        log("network link: connected")
        receive(generation)
        sendPing(reason: "connect")
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + heartbeatInterval, repeating: heartbeatInterval)
        t.setEventHandler { [weak self] in self?.sendPing(reason: "heartbeat") }
        t.resume()
        heartbeat = t
    }

    /// 连接断了 / 没连上：退避后重连
    private func lost(_ why: String) {
        guard wanted else { return }
        log("network link: \(why)")
        tearDown()
        let delay = backoff.fail(at: now())
        state = .waiting(retryIn: delay)
        let mine = generation
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.generation == mine, self.wanted else { return }
            self.connect()
        }
    }

    // MARK: - 收

    private func receive(_ mine: Int) {
        guard generation == mine, let nw = connection else { return }
        nw.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self, self.generation == mine else { return }
            if let data, !data.isEmpty {
                for frame in self.reader.feed(data) {
                    guard self.generation == mine else { return }
                    self.process(frame)
                }
                if self.generation == mine, self.reader.isBroken {
                    self.lost("bad frame length from computer")
                    return
                }
            }
            if error != nil || isComplete {
                self.lost(error == nil ? "computer closed the connection" : "receive error")
                return
            }
            self.receive(mine)
        }
    }

    private func process(_ message: Data) {
        guard let key = key(), let id = phoneID() else { return }
        let t = now()
        switch PairingCrypto.kind(of: message) {
        case .ack?:
            guard let ack = try? PairingCrypto.Ack(decoding: message), ack.phoneID == id else { return }
            prunePending(t)
            // 对不上一条还在等的命令：晚到的、重放的，一律不理
            guard pending[ack.counter] != nil else { return }
            if ack.status.isSigned {
                guard PairingCrypto.verifyAck(ack, key: key) else { return }
                pending[ack.counter] = nil
                if state != .ready {
                    state = .ready
                    backoff.reset()
                    log("network link: ready")
                }
            } else {
                pending[ack.counter] = nil
                // 没签名的 2：电脑说 nonce 不对 / 计数旧。nonce 作废，补一条 ping 拿新的
                if ack.status == .replay {
                    nonces = []
                    if t.timeIntervalSince(lastRecoveryPing) > 1 {
                        lastRecoveryPing = t
                        sendPing(reason: "recover")
                    }
                }
            }
            onMessage(message)
        case .state?:
            guard let s = PairingCrypto.openState(message, phoneID: id, key: key), accept(seq: s.seq, at: t) else { return }
            onMessage(message)
        case .keepAwakeState?:
            guard let s = PairingCrypto.openKeepAwakeState(message, phoneID: id, key: key), accept(seq: s.seq, at: t) else { return }
            onMessage(message)
        case .poll?:
            // 只在电脑已经用签名的 Ack 认过我们之后才收（录下来的旧 Poll 最多换来一次 Ack 2）
            guard state == .ready, let nonce = PairingCrypto.openPoll(message, phoneID: id, key: key) else { return }
            nonces.append((nonce, t))
            if nonces.count > 4 { nonces.removeFirst(nonces.count - 4) }
        case .revoke?:
            guard PairingCrypto.verifyRevoke(message, phoneID: id, key: key) else { return }
            onMessage(message)
        default:
            break
        }
    }

    /// seq 是电脑的毫秒时钟：和手机时钟差太多、或不比见过的新，都不收
    private func accept(seq: UInt64, at t: Date) -> Bool {
        let skew = abs(Double(seq) / 1000 - t.timeIntervalSince1970)
        guard skew <= maxClockSkew, seq > lastSeq else { return false }
        lastSeq = seq
        return true
    }

    private func prunePending(_ t: Date) {
        pending = pending.filter { t.timeIntervalSince($0.value) < pendingLifetime }
    }

    // MARK: - 发

    /// 发一条命令。ping 直接发；其余（away、awake:*、name:…）包上 nonce。
    /// 放行与否由电脑决定（撤下等会收到签名的 Ack 5）；这里不替它挡
    func send(_ command: String, completion: ((SendResult) -> Void)? = nil) {
        nonisolated(unsafe) let done = completion
        queue.async { [self] in done?(sendNow(command)) }
    }

    private func sendNow(_ command: String) -> SendResult {
        let isPing = command.lowercased() == "ping"
        guard connection != nil, state == .connected || state == .ready else { return .notReady }
        if !isPing, state != .ready { return .notReady }
        let t = now()
        var text = command
        if !isPing {
            nonces.removeAll { t.timeIntervalSince($0.at) >= nonceLifetime }
            guard let n = nonces.popLast() else { return .noNonce }
            text = NetworkCommand.wrap(command, nonce: n.nonce)
        }
        guard let key = key(), let id = phoneID(), let counter = reserveCounter(),
              let sealed = PairingCrypto.sealCommand(text, phoneID: id, counter: counter, key: key),
              let framed = NetFraming.frame(sealed), let nw = connection else { return .unavailable }
        prunePending(t)
        pending[counter] = t
        let mine = generation
        nw.send(content: framed, completion: .contentProcessed { [weak self] error in
            guard let self, self.generation == mine, error != nil else { return }
            self.lost("send failed")
        })
        return .sent(counter: counter)
    }

    /// 发一条 ping（不用 nonce；电脑据此认出我们，并回 Ack / State / KeepAwakeState / 新的 Poll）
    func ping() {
        queue.async { [self] in sendPing(reason: "requested") }
    }

    private func sendPing(reason: String) {
        _ = sendNow("ping")
    }
}
