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
        /// The Mac said the curtain was already up; shown above 盖上幕布
        case alreadyUncovered
    }

    /// 配过对、不在演示、没连上时「这台 Mac」那一行只有这三种（design v2.8 / copy v8.8）。
    /// 手机是外设，没法知道 Mac 在不在：只说手机这边看得到的事。
    /// 时长和文字都只在这里。
    enum UnlinkedMacState: Equatable {
        /// 正在广播，而且广播（重新）开始 / 断开 / 回到前台还不到 waitWindow
        case waiting
        /// 过了 waitWindow 还没有 Mac 来订阅，或者已经不广播了
        case stopped
        case bluetoothOff

        /// 「等这台 Mac 来连…」最多显示多久
        static let waitWindow: Duration = .seconds(20)

        var value: String {
            switch self {
            case .waiting: "等这台 Mac 来连…"
            case .stopped: "没连上"
            case .bluetoothOff: "蓝牙关了"
            }
        }

        /// 「没连上」底部按钮：点了回到「等这台 Mac 来连…」、重新等 waitWindow
        static let retryButtonTitle = "再找一次"

        var footer: String {
            switch self {
            case .waiting: "Mac 上开着 LockCurtain、人也在附近就行。"
            case .stopped: "Mac 上开着 LockCurtain，两边蓝牙都开着，人也在附近。"
            case .bluetoothOff: "打开 iPhone 的蓝牙，这台 Mac 才找得到它。"
            }
        }
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
    /// 连接正在广播（想广播、没停下）
    private(set) var linkAdvertising = false
    /// 还在「等这台 Mac 来连…」的 20 秒里
    private(set) var withinWaitWindow = false

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
    /// Bumped on every 「再找一次」 tap (light impact haptic)
    private(set) var findAgainTapCount = 0
    @ObservationIgnored private var waitWindowTask: Task<Void, Never>?
    @ObservationIgnored private var lastWaitEpoch = 0

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
        #if DEBUG
        // 截图用：-lcForceLinkState waiting|stopped|btoff —— 假装配过对、没连上；unpaired —— 没配对的主屏（平时没配对只会看到引导页）
        let forcedLink = UserDefaults.standard.string(forKey: "lcForceLinkState")
            .flatMap { DebugForcedCurtainLink(argument: $0, macName: "Studio 的 MacBook Pro") }
        #else
        let forcedLink: (any CurtainLink)? = nil
        #endif

        if let forcedLink {
            let forcedPaired = forcedLink.snapshot.connection != .notPaired
            paired = forcedPaired
            demoMode = false
            macName = forcedPaired ? "Studio 的 MacBook Pro" : nil
            if !forcedPaired { isPreviewFixture = true }   // 不走引导页，直接看主屏
            link = forcedLink
        } else if previewConnected {
            paired = true
            demoMode = false
            macName = "Studio 的 MacBook Pro"
            // 截图用：-lcPreviewState closing|closed|lifted —— 已连上时幕布停在「正在盖上…」/「已盖上」，或刚撤下
            #if DEBUG
            let previewPhase: CurtainPhase = switch UserDefaults.standard.string(forKey: "lcPreviewState") {
            case "closing": .closing
            case "closed", "lifted": .closed
            default: .open
            }
            #else
            let previewPhase: CurtainPhase = .open
            #endif
            let link = DemoCurtainLink(phase: previewPhase, auto: .off)
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
        // （-lcForceLinkState 的假连接不在这里启动：「没连上」要停在没广播的样子，等「再找一次」）
        if paired && !demoMode && forcedLink == nil { link.activate() }
        // 一打开 App 就算一次「回到前台」：开始等 20 秒
        restartWaitWindow()
        #if DEBUG
        // 截图用：-lcDemoCovered 一启动就进演示、幕布已盖上
        if ProcessInfo.processInfo.arguments.contains("-lcDemoCovered") {
            setDemoMode(true)
            selectDemoScenario(.closed)
        }
        // 截图用：-lcPreviewConnected -lcPreviewState lifted —— 跳过面容，直接走一遍「现在撤下」，停在「幕布撤下了。…」
        if previewConnected, UserDefaults.standard.string(forKey: "lcPreviewState") == "lifted" {
            startLift()
        }
        #endif
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
        case .notConnected: unlinkedMacState?.value ?? "没连上"
        case .bluetoothOff: "蓝牙关了"
        case .notPaired: "没配对"
        }
    }

    /// 配过对、不在演示、没连上：三种里的哪一种；其他时候是 nil
    var unlinkedMacState: UnlinkedMacState? {
        guard paired, !demoMode, connection != .connected, connection != .notPaired else { return nil }
        if connection == .bluetoothOff { return .bluetoothOff }
        return linkAdvertising && withinWaitWindow ? .waiting : .stopped
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

    /// 「没连上」底部按钮：确保在广播，回到「等这台 Mac 来连…」，重新等 20 秒
    func findMacAgain() {
        guard unlinkedMacState == .stopped else { return }
        findAgainTapCount += 1
        prepareForPairing()
        restartWaitWindow()
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
            self.link.requestState()
        }
    }

    private func finishLift(_ outcome: LiftOutcome) {
        // notCovered: the link already published "open", which ended 正在撤下 in apply
        guard isLifting || outcome == .notCovered else { return }
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
        case .notCovered:
            // the link has already flipped the phase to open
            endLifting()
            liftNotice = .alreadyUncovered
        case .timedOut:
            endLifting()
            liftNotice = .timedOut
            liftWarningCount += 1
            recordEvent(text: "没有回应")
        case .unavailable:
            endLifting()
        }
        // didn't lift: ask the Mac for the real curtain state
        if outcome != .lifted { link.requestState() }
    }

    private func endLifting() {
        isLifting = false
        liftTimeoutTask?.cancel()
        liftTimeoutTask = nil
    }

    /// The success line goes away when the app goes to the background
    func appDidEnterBackground() {
        showLiftedNote = false
        waitWindowTask?.cancel()
        waitWindowTask = nil
        withinWaitWindow = false
    }

    /// 回到前台：重新等 20 秒
    func appDidBecomeActive() {
        restartWaitWindow()
    }

    /// 广播（重新）开始、断开、回到前台：「等这台 Mac 来连…」从现在起再显示 waitWindow，过了就是「没连上」
    private func restartWaitWindow() {
        waitWindowTask?.cancel()
        guard UIApplication.shared.applicationState != .background else {
            withinWaitWindow = false
            return
        }
        withinWaitWindow = true
        waitWindowTask = Task { [weak self] in
            try? await Task.sleep(for: UnlinkedMacState.waitWindow)
            guard let self, !Task.isCancelled else { return }
            self.withinWaitWindow = false
        }
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
        linkAdvertising = snapshot.isAdvertising
        if snapshot.waitEpoch != lastWaitEpoch {
            lastWaitEpoch = snapshot.waitEpoch
            restartWaitWindow()
        }
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
