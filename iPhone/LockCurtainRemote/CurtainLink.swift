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
    case unavailable
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
/// phone answers the Mac's polls with "off" and 现在撤下 is hidden.
enum LiftSetting {
    static let key = "lc.liftOnApproach"

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
    /// 连续 5 次连上又在握手前断开，已经停止广播；等用户点「再试一次」/ 重新打开配对
    var gaveUpConnecting: Bool = false
    /// 手机想广播、而且没停下（没撤销配对、没连续断 5 次）：「等这台 Mac 来连…」只在这时出现
    var isAdvertising: Bool = false
    /// 广播（重新）开始、或者 Mac 断开时加一：主屏从这一刻重新算「等这台 Mac 来连…」的 20 秒
    var waitEpoch: Int = 0
    /// Bumped each time the Mac reports the curtain uncovered right after a
    /// lift this phone caused (walk-up or 现在撤下).
    var phoneLiftCount: Int = 0
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
}
#endif
