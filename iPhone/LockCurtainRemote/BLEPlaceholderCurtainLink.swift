import Foundation

/// The real CoreBluetooth link is not wired yet. This stub deliberately has no
/// CBCentralManager and no way to become `.connected`: it reports exactly what
/// it knows, which is "也没连上" or "没配对", and cover always fails as
/// unavailable. It must never pretend a Mac answered.
@MainActor
final class BLEPlaceholderCurtainLink: CurtainLink {
    private(set) var snapshot: CurtainSnapshot
    var onSnapshotChange: ((CurtainSnapshot) -> Void)?

    init(paired: Bool, macName: String?) {
        snapshot = CurtainSnapshot(
            connection: paired ? .notConnected : .notPaired,
            phase: .open,
            auto: .off,
            macName: paired ? macName : nil,
            isAway: false
        )
    }

    func activate() {
        // Reserved for the future CBCentralManager. Intentionally empty now.
    }

    func cover() async -> CoverOutcome {
        .unavailable
    }

    func setAutoEnabled(_ isOn: Bool) {
        // The Mac owns this value; without a link there is nothing to change.
    }

    func liftNow() async -> LiftOutcome {
        .unavailable
    }

    func requestState() {}
}
