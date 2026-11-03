import Combine
import Foundation
import LocalAuthentication
import Observation
import UIKit

/// App-wide state and the only owner of the current `CurtainLink`. Views read
/// this model; they never construct or identify a link themselves.
@MainActor
@Observable
final class AppModel {
    /// 「自动」（走远自动盖上）先不在界面上露面：设置、主屏、演示里都藏起来，也不碰定位。
    /// 代码都留着，改成 true 就回来。
    static let autoCoverVisible = false

    enum DemoScenario: Hashable {
        case connected
        case closed
        case lifted
    }

    /// The one-line result shown above the covered block after 现在撤下.
    enum LiftNotice: Equatable {
        case timedOut
        case tooFar
        case refused
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
    private(set) var lastEventText = "没连上"
    private(set) var lastEventDate = Date()
    private(set) var isPreviewFixture = false
    /// 连续 5 次连上又断，已经不再广播；界面走「找到了，但连不上」那条路，等用户点「再试一次」
    private(set) var connectionGaveUp = false
    /// 这次启动里刚配对成功：主屏在连接那一行下面提示一句「以后会自己连上」，下次启动就不再显示
    private(set) var justPaired = false

    /// 现在撤下 sent, waiting for the Mac to report the curtain uncovered
    private(set) var isLifting = false
    private(set) var liftNotice: LiftNotice?
    /// 「幕布撤下了。…」 under the cover button: the Mac reported uncovered after a lift this phone caused
    private(set) var showLiftedNote = false
    /// 「走近撤下」 (UserDefaults, default on)
    private(set) var liftOnApproach = LiftSetting.isOn
    /// Bumped when 现在撤下 passes the owner check (light impact haptic)
    private(set) var liftTapCount = 0
    /// Bumped on lift timeout / too far / refused (warning haptic)
    private(set) var liftWarningCount = 0

    var demoScenario: DemoScenario = .connected
    var showDemoExitNotice = false
    /// Bumped on every press so `.sensoryFeedback` can fire.
    var coverTapCount = 0

    @ObservationIgnored private var link: any CurtainLink
    @ObservationIgnored private var demoLink: DemoCurtainLink?
    /// 只有「自动」露面时才建：藏起来的时候一次都不碰定位
    @ObservationIgnored private var coverTask: Task<Void, Never>?
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var liftTask: Task<Void, Never>?
    @ObservationIgnored private var liftTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var demoLiftTask: Task<Void, Never>?
    @ObservationIgnored private var lastPhoneLiftCount = 0

    init() {
        // 删了重装 = 从没配过对：第一次启动先清掉钥匙串里残留的东西
        PhoneKeychain.wipeIfFreshInstall()
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
            // 配没配对只看钥匙串里有没有共享钥匙；老版本明文配对留下的标记不算数
            defaults.removeObject(forKey: Keys.paired)
            let storedPaired = PhoneKeychain.loadLink() != nil
            let storedName = storedPaired ? defaults.string(forKey: Keys.macName) : nil
            paired = storedPaired
            demoMode = false
            macName = storedName
            link = BLECurtainLink(paired: storedPaired, macName: storedName)
        }

        observeCurrentLink()
        recordEvent(from: link.snapshot)
        // 已经配过对的手机，一打开就该去找这台 Mac；不然主屏永远停在「没连上」
        if paired && !demoMode { link.activate() }
    }

    // MARK: - Derived UI state

    var needsOnboarding: Bool {
        !paired && !demoMode && !isPreviewFixture
    }

    var autoEnabled: Bool {
        auto == .on
    }

    var canToggleAuto: Bool {
        true  // 走没走远由 Mac 看信号判断，手机不需要定位
    }

    var autoDisplayValue: String {
        auto == .on ? "开着" : "关"
    }

    var curtainDisplayValue: String {
        guard connection == .connected else { return "—" }
        if isLifting { return "正在撤下…" }
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
        if isLifting { return "正在撤下" }
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
        if phase == .closed { return isLifting ? .lifting : .curtain }
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
        if let ble = link as? BLECurtainLink {
            ble.resumeConnecting()
        } else {
            link.activate()
        }
    }

    func cover() {
        guard connection == .connected, !isPending, phase != .closed else { return }
        coverTapCount += 1
        showLiftedNote = false
        liftNotice = nil
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

    // MARK: - 撤下

    func setLiftOnApproach(_ isOn: Bool) {
        LiftSetting.isOn = isOn
        liftOnApproach = isOn
    }

    var canLiftNow: Bool {
        connection == .connected && phase == .closed && liftOnApproach && !isLifting
    }

    /// 现在撤下: Face ID or passcode first (not in the demo), then the signed lift-now.
    /// Cancel / failure changes nothing and shows nothing.
    func liftNow() {
        guard canLiftNow else { return }
        liftNotice = nil
        if demoMode {
            startLift()
            return
        }
        let context = LAContext()
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "撤下这台 Mac 的幕布") { [weak self] ok, _ in
            guard ok else { return }
            Task { @MainActor in self?.startLift() }
        }
    }

    private func startLift() {
        guard canLiftNow else { return }
        liftTapCount += 1
        liftNotice = nil
        isLifting = true
        liftTask?.cancel()
        liftTimeoutTask?.cancel()
        liftTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.link.liftNow()
            self.finishLift(outcome)
        }
        liftTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, !Task.isCancelled, self.isLifting else { return }
            self.isLifting = false
            self.liftNotice = .timedOut
            self.liftWarningCount += 1
            self.recordEvent(text: "没有回应")
        }
    }

    private func finishLift(_ outcome: LiftOutcome) {
        guard isLifting else { return }
        switch outcome {
        case .lifted:
            // The Mac's own "uncovered" report ends 正在撤下 (see apply)
            if phase != .closed { endLifting() }
        case .tooFar:
            endLifting()
            liftNotice = .tooFar
            liftWarningCount += 1
        case .refused:
            endLifting()
            liftNotice = .refused
            liftWarningCount += 1
        case .timedOut:
            endLifting()
            liftNotice = .timedOut
            liftWarningCount += 1
            recordEvent(text: "没有回应")
        case .unavailable:
            endLifting()
        }
    }

    private func endLifting() {
        isLifting = false
        liftTimeoutTask?.cancel()
        liftTimeoutTask = nil
    }

    /// The success line goes away when the app goes to the background
    func appDidEnterBackground() {
        showLiftedNote = false
    }

    func selectDemoScenario(_ scenario: DemoScenario) {
        demoScenario = scenario
        guard demoMode, let demoLink else { return }
        demoLiftTask?.cancel()
        liftTask?.cancel()
        endLifting()
        liftNotice = nil
        switch scenario {
        case .connected:
            showLiftedNote = false
            demoLink.showConnected()
        case .closed:
            showLiftedNote = false
            demoLink.showCovered()
        case .lifted:
            // Not covered yet: cover first, then after 0.6 s run 正在撤下… (0.8 s) → uncovered
            demoLiftTask = Task { [weak self] in
                guard let self else { return }
                if self.phase != .closed {
                    demoLink.showCovered()
                    try? await Task.sleep(for: .milliseconds(600))
                }
                guard !Task.isCancelled, self.demoMode, self.demoScenario == .lifted else { return }
                self.startLift()
            }
        }
    }

    func setDemoMode(_ isOn: Bool) {
        guard isOn != demoMode else { return }
        demoMode = isOn
        coverTask?.cancel()
        timeoutTask?.cancel()
        isCovering = false
        didTimeOut = false

        demoLiftTask?.cancel()
        liftTask?.cancel()
        endLifting()
        liftNotice = nil
        showLiftedNote = false

        if isOn {
            showDemoExitNotice = false
            demoScenario = .connected
            let link = DemoCurtainLink()
            demoLink = link
            adopt(link)
        } else {
            demoLink = nil
            demoScenario = .connected
            adopt(BLECurtainLink(paired: paired, macName: macName))
            if !paired {
                showDemoExitNotice = true
                scheduleNoticeClear()
            }
        }
    }

    /// 把 6 位码真的交给 Mac；只有 Mac 认可才记成已配对
    func pair(code: String) async -> PairResult {
        if demoMode { setDemoMode(false) }
        let ble = link as? BLECurtainLink ?? BLECurtainLink(paired: false, macName: nil)
        if link as? BLECurtainLink == nil { adopt(ble) }
        let result = await ble.pair(code: code)
        if result == .accepted {
            completePairing(macName: ble.snapshot.macName ?? "这台 Mac")
        }
        return result
    }

    func completePairing(macName: String) {
        // 只有 Mac 真的接受了握手（钥匙串里有共享钥匙）才记成已配对
        guard demoMode || PhoneKeychain.loadLink() != nil else { return }
        // 已经配上过就别再改名字、别换连接（配对页「完成」会再调一次，带的是占位名）
        if paired, self.macName != nil { return }
        paired = true
        self.macName = macName
        if !demoMode {
            justPaired = true
            // 「走近撤下」 starts on after pairing
            setLiftOnApproach(true)
        }
        UserDefaults.standard.set(macName, forKey: Keys.macName)
        if !demoMode, !(link is BLECurtainLink) {
            adopt(BLECurtainLink(paired: true, macName: macName))
        }
    }

    /// 撤销配对：连着 Mac 就先发一条签名的 unpair 让 Mac 也删钥匙，再删手机自己的钥匙
    func unpair() {
        paired = false
        justPaired = false
        macName = nil
        UserDefaults.standard.removeObject(forKey: Keys.macName)
        if let ble = link as? BLECurtainLink {
            ble.unpair()
        } else {
            PhoneKeychain.deleteLink()
            if !demoMode {
                adopt(BLECurtainLink(paired: false, macName: nil))
            }
        }
    }

    /// Mac 发来签名的撤销通知：手机的钥匙已经在连接里删掉了，这里只改界面状态
    private func handleRevokedByMac() {
        paired = false
        justPaired = false
        macName = nil
        UserDefaults.standard.removeObject(forKey: Keys.macName)
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
        if let ble = link as? BLECurtainLink {
            ble.onRevoked = { [weak self] in self?.handleRevokedByMac() }
        }
        apply(link.snapshot)
    }

    private func apply(_ snapshot: CurtainSnapshot) {
        if snapshot.phase != phase || snapshot.connection != connection {
            liftNotice = nil      // the too-far / no-answer line lasts until the state changes
        }
        if snapshot.phoneLiftCount != lastPhoneLiftCount {
            if snapshot.phoneLiftCount > lastPhoneLiftCount, snapshot.phase == .open,
               snapshot.connection == .connected,
               UIApplication.shared.applicationState != .background {
                showLiftedNote = true
                if demoMode { demoScenario = .lifted }
            }
            lastPhoneLiftCount = snapshot.phoneLiftCount
        }
        if snapshot.phase != .closed || snapshot.connection != .connected {
            endLifting()
        }
        if snapshot.phase == .closed || snapshot.connection != .connected {
            showLiftedNote = false
        }
        connection = snapshot.connection
        phase = snapshot.phase
        auto = snapshot.auto
        if let name = snapshot.macName {
            macName = name
        }
        isAway = snapshot.isAway
        connectionGaveUp = snapshot.gaveUpConnecting
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
            if demoMode {
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
