import Foundation

/// How the phone currently relates to the Mac. The values are produced by the
/// link, never by the views.
enum CurtainConnection: Equatable, Sendable {
    case connected
    /// 配过对、没连上。手机是外设（只广播），没法知道 Mac 在不在：主屏只分「等这台 Mac 来连…」和「没连上」
    case notConnected
    case bluetoothOff
    case notPaired
}

/// Which road the verified conversation with the Mac is on right now.
/// Bluetooth always wins when both are up. Over `.network` the phone may only
/// cover, set keep-awake and read state; 现在撤下 stays Bluetooth-only.
enum LinkPath: Equatable, Sendable {
    case bluetooth
    case network
}

/// Where the network attempt stands (only meaningful when an address is saved
/// and the phone is paired). `trying` = first attempt in flight, `failed` = the
/// last attempt did not get a signed answer (stays `failed` while the client keeps retrying).
enum NetworkStatus: Equatable, Sendable {
    case none
    case trying
    case failed
}

/// What the Mac last reported about the curtain.
enum CurtainPhase: Equatable, Sendable {
    case open
    case closing
    case closed
}

/// The Mac-owned automatic-cover preference.
enum CurtainAuto: Equatable, Sendable {
    case on
    case off
}

/// Result of one cover request.
enum CoverOutcome: Equatable, Sendable {
    case covered
    case timedOut
    /// The computer answered (signed Ack status 4) that it is missing a permission and did not cover (N2)
    case missingPermission
    case unavailable
}

/// 保持唤醒：电脑报来的状态（protocol-v3 §3 KeepAwakeState）。手机只显示，不自己算。
enum KeepAwakeState: Equatable, Sendable {
    case off
    /// 定时，到 endsAt 结束（「还剩 1 小时 20 分」）
    case timed(endsAt: Date)
    case always
    /// 到电脑上定的时刻（「到 18:30」）
    case untilTime(Date)
    /// 某个 app 开着时（「Xcode 开着时」）
    case whileApp(String)

    /// 现在算不算开着（定时的已经过点了就算关）
    func isOn(at now: Date) -> Bool {
        switch self {
        case .off: false
        case .timed(let end), .untilTime(let end): end > now
        case .always, .whileApp: true
        }
    }

    /// 电脑报来的 mode / endsAt / appName → 状态；不认识的 mode 是 nil
    init?(mode: UInt8, endsAt: UInt64, appName: String) {
        let end = Date(timeIntervalSince1970: TimeInterval(endsAt))
        switch mode {
        case 0: self = .off
        case 1: self = .timed(endsAt: end)
        case 2: self = .always
        case 3: self = .untilTime(end)
        case 4: self = .whileApp(appName)
        default: return nil
        }
    }
}

/// 手机菜单里能选的（没有「到指定时间」和「某个 app」：那两种只在电脑上开，Ato 定）
enum KeepAwakeChoice: String, CaseIterable, Sendable {
    case off
    case oneHour = "1h"
    case twoHours = "2h"
    case fiveHours = "5h"
    case always

    /// 发给电脑的签名命令（protocol-v3 §1）
    var command: String { "awake:" + rawValue }

    /// 时长（演示里用）
    var duration: TimeInterval? {
        switch self {
        case .oneHour: 3600
        case .twoHours: 7200
        case .fiveHours: 18000
        case .off, .always: nil
        }
    }
}

/// Result of one 「现在撤下」 request, as reported (signed) by the Mac.
enum LiftOutcome: Equatable, Sendable {
    case lifted
    /// The Mac measured the phone as not near enough.
    case tooFar
    /// The Mac says the curtain is already not covered.
    case notCovered
    /// The Mac refused for another reason (stale / reused answer…).
    case refused
    case timedOut
    case unavailable
}

/// 「走近撤下」: stored on the phone in UserDefaults, default on. When off the
/// phone answers the Mac's polls with "off" (walking up no longer lifts), but
/// 现在撤下 stays on screen and still works — only the two lines above it change
/// (design v2.7 / copy §12).
enum LiftSetting {
    static let key = "lc.liftOnApproach"

    static var isOn: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

/// 「撤下前验证面容」：关掉后「现在撤下」不弹面容 / 密码（默认开）
enum LiftAuthSetting {
    static let key = "lc.liftNeedsFaceID"

    static var isOn: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

/// Everything HomeView needs to draw itself. All values originate at the Mac;
/// the demo link is the only implementation that produces them locally.
struct CurtainSnapshot: Equatable, Sendable {
    var connection: CurtainConnection = .notPaired
    var phase: CurtainPhase = .open
    var auto: CurtainAuto = .off
    var macName: String?
    /// Demo-only: the user has "walked away" and the demo is counting down
    /// before it covers the curtain.
    var isAway: Bool = false
    /// 连续 5 次连上又在握手前断开（手机照旧广播，退避在电脑那边）。
    /// 主屏不看它（按经过时间分段）；配对页用它换掉一般的失败提示
    var gaveUpConnecting: Bool = false
    /// 手机想广播（没撤销配对）
    var isAdvertising: Bool = false
    /// 广播（重新）开始、或者 Mac 断开时加一：主屏从这一刻重新算「等这台 Mac 来连…」的 20 秒
    var waitEpoch: Int = 0
    /// Bumped each time the Mac reports the curtain uncovered right after a
    /// lift this phone caused (walk-up or 现在撤下).
    var phoneLiftCount: Int = 0
    /// 电脑报来的保持唤醒状态；nil = 这次还没报过（老电脑不报：手机那一行就是「—」、点不动）
    var keepAwake: KeepAwakeState?
    /// Which road `connection == .connected` is on; nil when not connected
    var path: LinkPath?
    var networkStatus: NetworkStatus = .none
}

/// The only door between the UI and a curtain. HomeView, SettingsView and
/// OnboardingView never learn which implementation is behind it.
@MainActor
protocol CurtainLink: AnyObject {
    var snapshot: CurtainSnapshot { get }
    /// Called on the main actor after every snapshot mutation.
    var onSnapshotChange: ((CurtainSnapshot) -> Void)? { get set }

    /// Start whatever the link needs (real BLE wiring would happen here). The
    /// onboarding screen deliberately does not call this until the user asks
    /// to pair.
    func activate()

    /// Send "cover" and wait for the Mac's receipt. Implementations are
    /// responsible for publishing `.closing` and then `.closed`/`.open`.
    func cover() async -> CoverOutcome

    /// Set the Mac's automatic-cover preference.
    func setAutoEnabled(_ isOn: Bool)

    /// 现在撤下: ask the Mac to lift the curtain now. The caller has already
    /// done any owner check (Face ID / passcode) that applies.
    func liftNow() async -> LiftOutcome

    /// Ask the Mac to report the curtain state again (after a lift that
    /// didn't happen), so the screen never sticks on a stale state.
    func requestState()

    /// 保持唤醒：发签名命令 awake:…，等电脑签收（不要面容）。true = 电脑签名收下了；
    /// 新的状态随后由电脑的 KeepAwakeState 报回来，界面只照那个显示。
    func setKeepAwake(_ choice: KeepAwakeChoice) async -> Bool
}

#if DEBUG
/// 截图用：-lcForceLinkState waiting|stopped|btoff —— 假装配过对、没连上，停在指定的那一种状态。
/// 不碰蓝牙、不发任何东西。
@MainActor
final class DebugForcedCurtainLink: CurtainLink {
    private(set) var snapshot: CurtainSnapshot
    var onSnapshotChange: ((CurtainSnapshot) -> Void)?

    init?(argument: String, macName: String) {
        var snap = CurtainSnapshot(connection: .notConnected, phase: .open, auto: .off, macName: macName)
        switch argument {
        case "network":
            // 假装走网络连上、幕布盖着：看「走网络时不能撤下」那一行
            snap.connection = .connected
            snap.phase = .closed
            snap.path = .network
        case "networkfailed":
            snap.networkStatus = .failed
        case "waiting":
            snap.isAdvertising = true
            snap.waitEpoch = 1
        case "stopped":
            snap.isAdvertising = false
        case "btoff":
            snap.connection = .bluetoothOff
        case "unpaired":
            snap.connection = .notPaired
            snap.macName = nil
        default:
            return nil
        }
        snapshot = snap
    }

    /// 「再找一次」：假装重新开始广播
    func activate() {
        guard snapshot.connection == .notConnected else { return }
        snapshot.isAdvertising = true
        snapshot.waitEpoch += 1
        onSnapshotChange?(snapshot)
    }
    func cover() async -> CoverOutcome { .unavailable }
    func setAutoEnabled(_ isOn: Bool) {}
    func liftNow() async -> LiftOutcome { .unavailable }
    func requestState() {}
    func setKeepAwake(_ choice: KeepAwakeChoice) async -> Bool { false }
}
#endif
