// NetworkAddress.swift —— 手机走网络连电脑时用的地址（电脑上显示的那一行），和「什么时候该走网络」的纯规则
//
// 地址存在 UserDefaults（lc.netAddress）：不是秘密，不进钥匙串。撤销配对 / 换电脑 / 被电脑撤销时清掉（见 AppModel）。
// 没存地址就永远不走网络。

import Foundation
import Network

/// "host:port" | "[v6]:port" | "name:port"
struct NetworkAddress: Equatable, Sendable {
    /// IPv4、主机名，或者不带方括号的 IPv6
    let host: String
    let port: UInt16

    static let defaultsKey = "lc.netAddress"

    var isIPv6: Bool { host.contains(":") }

    /// 规范写法：IPv6 带方括号
    var text: String { isIPv6 ? "[\(host)]:\(port)" : "\(host):\(port)" }

    /// 解析用户输入（去掉首尾空白）。空主机、端口 0 / 超过 65535 / 缺端口 / 不像地址的一律 nil
    static func parse(_ raw: String) -> NetworkAddress? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.allSatisfy({ $0.isASCII && !$0.isWhitespace && !$0.isNewline }) else { return nil }
        let hostPart: String
        let portPart: Substring
        if s.hasPrefix("[") {
            guard let close = s.firstIndex(of: "]") else { return nil }
            hostPart = String(s[s.index(after: s.startIndex)..<close])
            let rest = s[s.index(after: close)...]
            guard rest.hasPrefix(":") else { return nil }
            portPart = rest.dropFirst()
            guard !hostPart.isEmpty, IPv6Address(hostPart) != nil else { return nil }
        } else {
            guard let colon = s.lastIndex(of: ":") else { return nil }
            hostPart = String(s[..<colon])
            portPart = s[s.index(after: colon)...]
            // 没带方括号的 IPv6 分不清哪个冒号是端口：不收
            guard !hostPart.isEmpty, !hostPart.contains(":"), isValidHost(hostPart) else { return nil }
        }
        guard let port = parsePort(portPart) else { return nil }
        return NetworkAddress(host: hostPart, port: port)
    }

    private static func parsePort(_ s: Substring) -> UInt16? {
        guard !s.isEmpty, s.count <= 5, s.allSatisfy({ $0 >= "0" && $0 <= "9" }),
              let n = UInt32(s), n >= 1, n <= 65535 else { return nil }
        return UInt16(n)
    }

    /// IPv4（四段数字）或主机名（字母 / 数字 / - / _，用 . 分段，段不能空）
    private static func isValidHost(_ h: String) -> Bool {
        let labels = h.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty, labels.allSatisfy({ !$0.isEmpty }) else { return false }
        guard labels.allSatisfy({ $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } }) else { return false }
        // 全是数字和点的，必须是合法的 IPv4（999.1.1.1 不是主机名）
        if h.allSatisfy({ $0.isNumber || $0 == "." }) { return IPv4Address(h) != nil }
        return !h.hasPrefix("-") && !h.hasSuffix("-")
    }

    // MARK: - 存取

    static func load(_ defaults: UserDefaults = .standard) -> NetworkAddress? {
        defaults.string(forKey: defaultsKey).flatMap(parse)
    }

    static func save(_ address: NetworkAddress, _ defaults: UserDefaults = .standard) {
        defaults.set(address.text, forKey: defaultsKey)
    }

    static func clear(_ defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }
}

/// 蓝牙和网络谁说了算、网络什么时候该开：纯规则，BLECurtainLink 照这个办
enum NetworkLinkPlan {
    /// 打开 App / 蓝牙掉了以后，先等这么久（手机是蓝牙外设，要电脑来连），蓝牙没好才走网络
    static let bleGrace: TimeInterval = 5

    /// 这次启动里还没连上过（蓝牙网络都算）：不等蓝牙，蓝牙和网络一起赛，谁先通谁说了算（蓝牙通了就让网络走，见 BLECurtainLink.markReady）。
    /// 连上过以后（蓝牙掉了、回前台）照旧先等 bleGrace
    static func grace(connectedSinceLaunch: Bool) -> TimeInterval {
        connectedSinceLaunch ? bleGrace : 0
    }

    /// 现在走哪条路：蓝牙通了永远走蓝牙
    static func path(bleReady: Bool, networkReady: Bool) -> LinkPath? {
        if bleReady { return .bluetooth }
        if networkReady { return .network }
        return nil
    }

    enum Decision: Equatable {
        /// 网络客户端该开着
        case run
        /// 网络客户端该停
        case stop
        /// 蓝牙再等这么多秒，到时候再看
        case wait(TimeInterval)
    }

    /// - waited: 从「蓝牙开始等」（回前台 / 蓝牙掉了）过了多久
    /// - running: 网络客户端已经在跑（跑着就不用再等 5 秒）
    /// - grace: 蓝牙先等多久；默认 bleGrace，这次启动还没连上过时是 0（见 grace(connectedSinceLaunch:)）
    static func decide(paired: Bool, hasAddress: Bool, foreground: Bool, bleReady: Bool,
                       waited: TimeInterval, running: Bool, grace: TimeInterval = bleGrace) -> Decision {
        // 没存地址、没配对、不在前台、蓝牙通了：不走网络
        guard paired, hasAddress, foreground, !bleReady else { return .stop }
        if running || waited >= grace { return .run }
        return .wait(grace - waited)
    }

    /// 网络客户端的状态 → 界面上的网络状态。试过一次没成，就一直是 failed，直到连上
    static func status(client: PhoneNetClient.State, previous: NetworkStatus) -> NetworkStatus {
        switch client {
        case .stopped, .ready: .none
        case .waiting: .failed
        case .connecting, .connected: previous == .failed ? .failed : .trying
        }
    }

    /// 能不能撤下：只有蓝牙
    static func canLift(path: LinkPath?) -> Bool { path == .bluetooth }
}
