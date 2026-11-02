import Combine
import CoreLocation
import Foundation
import Observation
import UIKit

/// App-wide state and the only owner of the current `CurtainLink`. Views read
/// this model; they never construct or identify a link themselves.
@MainActor
@Observable
final class AppModel {
    enum DemoScenario: Hashable {
        case connected
        case closed
        case away
    }

    private enum Keys {
        static let paired = "lc.paired"
        static let macName = "lc.macName"
        /// Removed in v2.2: demo is session-only and must never survive launch.
        static let legacyDemo = "lc.demo"
    }

    private(set) var paired = false
    private(set) var demoMode = false
    private(set) var macName: String?
    private(set) var connection: CurtainConnection = .notPaired
    private(set) var phase: CurtainPhase = .open
    private(set) var auto: CurtainAuto = .off
    private(set) var isCovering = false
    private(set) var didTimeOut = false
    private(set) var isAway = false
    private(set) var locationStatus: CLAuthorizationStatus = .notDetermined
    private(set) var lastEventText = "没连上"
    private(set) var lastEventDate = Date()
    private(set) var isPreviewFixture = false

    var demoScenario: DemoScenario = .connected
    var showDemoExitNotice = false
    /// Bumped on every press so `.sensoryFeedback` can fire.
    var coverTapCount = 0

    @ObservationIgnored private var link: any CurtainLink
    @ObservationIgnored private var demoLink: DemoCurtainLink?
    @ObservationIgnored private let locationManager = CLLocationManager()
    @ObservationIgnored private var coverTask: Task<Void, Never>?
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    init() {
        let defaults = UserDefaults.standard
        // Clear any value written by earlier builds that persisted demo mode.
        defaults.removeObject(forKey: Keys.legacyDemo)
        #if DEBUG
        let previewConnected = ProcessInfo.processInfo.arguments.contains("-lcPreviewConnected")
        #else
        let previewConnected = false
        #endif
        isPreviewFixture = previewConnected

        if previewConnected {
            paired = true
            demoMode = false
            macName = "Studio 的 MacBook Pro"
            let link = DemoCurtainLink(phase: .open, auto: .off)
            self.link = link
            demoLink = link
        } else {
            let storedPaired = defaults.bool(forKey: Keys.paired)
            let storedName = defaults.string(forKey: Keys.macName)
            paired = storedPaired
            demoMode = false
            macName = storedName
            link = BLEPlaceholderCurtainLink(paired: storedPaired, macName: storedName)
        }

        observeCurrentLink()
        refreshLocationStatus()
        recordEvent(from: link.snapshot)
    }

    // MARK: - Derived UI state

    var needsOnboarding: Bool {
        !paired && !demoMode && !isPreviewFixture
    }

    var hasAlwaysLocation: Bool {
        locationStatus == .authorizedAlways
    }

    var locationValue: String {
        switch locationStatus {
        case .authorizedAlways: "始终"
        case .authorizedWhenInUse: "使用 App 期间"
        default: "从不"
        }
    }

    var autoEnabled: Bool {
        auto == .on
    }

    var canToggleAuto: Bool {
        demoMode || hasAlwaysLocation
    }

    var autoDisplayValue: String {
        auto == .on ? "开着" : "关"
    }

    var curtainDisplayValue: String {
        guard connection == .connected else { return "—" }
        switch phase {
        case .open: return "没盖上"
        case .closing: return isCovering || phase == .closing ? "正在盖上…" : "没盖上"
        case .closed: return "已盖上"
        }
    }

    var curtainVoiceValue: String {
        guard connection == .connected else {
            return connection == .notPaired ? "没配对" : "没连上"
        }
        switch phase {
        case .open: return "没盖上"
        case .closing: return "正在盖上"
        case .closed: return "已盖上"
        }
    }

    var macDisplayValue: String {
        switch connection {
        case .connected: "已连接"
        case .notConnected: "没连上"
        case .macOffline: "Mac 不在线"
        case .bluetoothOff: "蓝牙关了"
        case .notPaired: "没配对"
        }
    }

    var isPending: Bool {
        connection == .connected && (phase == .closing || isCovering)
    }

    var screenState: MacScreenState {
        guard connection == .connected else { return .empty }
        if phase == .closed { return .curtain }
        if isPending { return .closing }
        return .desktop
    }

    var bluetoothDiagnosticValue: String {
        connection == .bluetoothOff ? "关着" : "开着"
    }

    var signalDiagnosticValue: String {
        connection == .connected ? "一般" : "弱"
    }

    var lastEventDiagnosticValue: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return "\(formatter.string(from: lastEventDate)) · \(lastEventText)"
    }

    // MARK: - User actions

    func prepareForPairing() {
        link.activate()
    }

    func cover() {
        guard connection == .connected, !isPending, phase != .closed else { return }
        coverTapCount += 1
        didTimeOut = false
        isCovering = true
        timeoutTask?.cancel()
        coverTask?.cancel()

        coverTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.link.cover()
            guard !Task.isCancelled else { return }
            self.finishCover(outcome)
        }

        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, !Task.isCancelled, self.isCovering else { return }
            self.coverTask?.cancel()
            self.isCovering = false
            self.didTimeOut = true
            if self.phase == .closing { self.phase = .open }
            self.recordEvent(text: "没有回应")
        }
    }

    func setAutoEnabled(_ isOn: Bool) {
        guard canToggleAuto else { return }
        link.setAutoEnabled(isOn)
    }

    func selectDemoScenario(_ scenario: DemoScenario) {
        demoScenario = scenario
        guard demoMode, let demoLink else { return }
        switch scenario {
        case .connected:
            demoLink.showConnected()
        case .closed:
            demoLink.showCovered()
        case .away:
            demoLink.showAway()
        }
    }

    func setDemoMode(_ isOn: Bool) {
        guard isOn != demoMode else { return }
        demoMode = isOn
        coverTask?.cancel()
        timeoutTask?.cancel()
        isCovering = false
        didTimeOut = false

        if isOn {
            showDemoExitNotice = false
            demoScenario = .connected
            let link = DemoCurtainLink()
            demoLink = link
            adopt(link)
        } else {
            demoLink = nil
            demoScenario = .connected
            adopt(BLEPlaceholderCurtainLink(paired: paired, macName: macName))
            if !paired {
                showDemoExitNotice = true
                scheduleNoticeClear()
            }
        }
    }

    func completePairing(macName: String) {
        paired = true
        self.macName = macName
        UserDefaults.standard.set(true, forKey: Keys.paired)
        UserDefaults.standard.set(macName, forKey: Keys.macName)
        if !demoMode {
            adopt(BLEPlaceholderCurtainLink(paired: true, macName: macName))
        }
    }

    func unpair() {
        paired = false
        macName = nil
        UserDefaults.standard.removeObject(forKey: Keys.paired)
        UserDefaults.standard.removeObject(forKey: Keys.macName)
        if !demoMode {
            adopt(BLEPlaceholderCurtainLink(paired: false, macName: nil))
        }
    }

    func refreshLocationStatus() {
        locationStatus = locationManager.authorizationStatus
    }

    // MARK: - Link plumbing

    private func adopt(_ newLink: any CurtainLink) {
        link.onSnapshotChange = nil
        link = newLink
        observeCurrentLink()
        apply(newLink.snapshot)
    }

    private func observeCurrentLink() {
        link.onSnapshotChange = { [weak self] snapshot in
            self?.apply(snapshot)
        }
        apply(link.snapshot)
    }

    private func apply(_ snapshot: CurtainSnapshot) {
        connection = snapshot.connection
        phase = snapshot.phase
        auto = snapshot.auto
        if let name = snapshot.macName {
            macName = name
        }
        isAway = snapshot.isAway
        if snapshot.phase == .closed || snapshot.connection != .connected {
            isCovering = false
        }
        recordEvent(from: snapshot)
    }

    private func finishCover(_ outcome: CoverOutcome) {
        timeoutTask?.cancel()
        timeoutTask = nil
        isCovering = false
        switch outcome {
        case .covered:
            didTimeOut = false
            if demoMode, demoScenario != .away {
                demoScenario = .closed
            }
        case .timedOut:
            didTimeOut = true
            if phase == .closing { phase = .open }
            recordEvent(text: "没有回应")
        case .unavailable:
            didTimeOut = false
        }
    }

    private func recordEvent(from snapshot: CurtainSnapshot) {
        let text: String
        if snapshot.isAway {
            text = "已走远"
        } else if snapshot.connection != .connected {
            text = snapshot.connection == .notPaired ? "没配对" : "没连上"
        } else {
            switch snapshot.phase {
            case .open: text = "没盖上"
            case .closing: text = "正在盖上"
            case .closed: text = "已盖上"
            }
        }
        if text != lastEventText {
            recordEvent(text: text)
        }
    }

    private func recordEvent(text: String) {
        lastEventText = text
        lastEventDate = Date()
    }

    private func scheduleNoticeClear() {
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled else { return }
            self.showDemoExitNotice = false
        }
    }
}
