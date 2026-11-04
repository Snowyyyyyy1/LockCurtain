import Foundation

/// A fully local curtain. It never imports CoreBluetooth and never sends a
/// command anywhere; every state change is produced by the demo itself.
@MainActor
final class DemoCurtainLink: CurtainLink {
    private(set) var snapshot: CurtainSnapshot
    var onSnapshotChange: ((CurtainSnapshot) -> Void)?

    private var awayTask: Task<Void, Never>?

    init(
        macName: String = "Studio 的电脑",
        phase: CurtainPhase = .open,
        auto: CurtainAuto = .on
    ) {
        snapshot = CurtainSnapshot(
            connection: .connected,
            phase: phase,
            auto: auto,
            macName: macName,
            isAway: false,
            keepAwake: .off
        )
    }

    func activate() {
        // Nothing to start: the demo does not touch the radios.
    }

    func cover() async -> CoverOutcome {
        guard snapshot.connection == .connected, snapshot.phase != .closing else {
            return .unavailable
        }
        awayTask?.cancel()
        snapshot.isAway = false
        snapshot.phase = .closing
        publish()

        try? await Task.sleep(for: .milliseconds(800))
        guard !Task.isCancelled else { return .unavailable }

        snapshot.phase = .closed
        publish()
        return .covered
    }

    func setAutoEnabled(_ isOn: Bool) {
        snapshot.auto = isOn ? .on : .off
        publish()
    }

    func requestState() {
        // The demo is its own source of truth.
    }

    /// 现在撤下 in the demo: no Face ID, no command — 0.8 s later the
    /// curtain is simply up again (still marked demo).
    func liftNow() async -> LiftOutcome {
        guard snapshot.connection == .connected, snapshot.phase == .closed else {
            return .unavailable
        }
        awayTask?.cancel()
        try? await Task.sleep(for: .milliseconds(800))
        guard !Task.isCancelled, snapshot.phase == .closed else { return .unavailable }
        snapshot.phase = .open
        snapshot.phoneLiftCount += 1
        publish()
        return .lifted
    }

    /// 保持唤醒（演示）：不发任何东西，0.6 秒后假装电脑报回来了
    func setKeepAwake(_ choice: KeepAwakeChoice) async -> Bool {
        guard snapshot.connection == .connected else { return false }
        try? await Task.sleep(for: .milliseconds(600))
        guard !Task.isCancelled else { return false }
        switch choice {
        case .off: snapshot.keepAwake = .off
        case .always: snapshot.keepAwake = .always
        case .oneHour, .twoHours, .fiveHours:
            snapshot.keepAwake = .timed(endsAt: Date().addingTimeInterval(choice.duration ?? 0))
        }
        publish()
        return true
    }

    // MARK: - Demo switcher

    /// 已连上这台 Mac
    func showConnected() {
        awayTask?.cancel()
        snapshot.connection = .connected
        snapshot.phase = .open
        snapshot.auto = .on
        snapshot.isAway = false
        publish()
    }

    /// 幕布已盖上
    func showCovered() {
        awayTask?.cancel()
        snapshot.connection = .connected
        snapshot.phase = .closed
        snapshot.isAway = false
        publish()
    }

    /// 走远自动盖上: show "已走远" for three seconds, then cover.
    func showAway() {
        awayTask?.cancel()
        snapshot.connection = .connected
        snapshot.phase = .open
        snapshot.auto = .on
        snapshot.isAway = true
        publish()

        awayTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled else { return }
            self.snapshot.phase = .closed
            self.snapshot.isAway = false
            self.publish()
        }
    }

    private func publish() {
        onSnapshotChange?(snapshot)
    }
}
