import Foundation

/// How the phone currently relates to the Mac. The values are produced by the
/// link, never by the views.
enum CurtainConnection: Equatable, Sendable {
    case connected
    case notConnected
    case macOffline
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
}
