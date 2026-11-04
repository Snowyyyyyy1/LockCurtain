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

    /// 配过对、不在演示、没连上时「这台电脑」那一行（design v2.10 A / copy v13 §8.6）。
    /// 手机永不停手：只按「离上次连上过了多久」分段（App 刚打开还没连上过，就从打开那一刻算），不看内部重试间隔。
    /// 时长和文字都只在这里。
    enum UnlinkedMacState: Equatable {
        /// App 刚打开、还没连上过，前 30 秒：「等这台电脑来连…」
        case waiting
        /// ① 断开后 30 秒内，或者刚按了「现在再试一次」：「正在重新连上…」
        case reconnecting
        /// ② 30 秒–2 分钟
        case notYet
        /// ③ 2–10 分钟
        case stillTrying
        /// ④ 10 分钟以上：③那句 + 排查那句
        case stillTryingLong
        case bluetoothOff

        /// ①（以及刚打开的「等这台电脑来连…」）多久；之后出「现在再试一次」
        static let firstStage: TimeInterval = 30
        /// ③ 从什么时候起
        static let longerStage: TimeInterval = 120
        /// ④ 从什么时候起
        static let longestStage: TimeInterval = 600
        /// 按了「现在再试一次」以后「正在重新连上…」最多显示多久
        static let retryShowsFor: TimeInterval = 30

        static func at(elapsed: TimeInterval, everConnected: Bool, retrying: Bool) -> UnlinkedMacState {
            if retrying { return .reconnecting }
            if elapsed < firstStage { return everConnected ? .reconnecting : .waiting }
            if elapsed < longerStage { return .notYet }
            if elapsed < longestStage { return .stillTrying }
            return .stillTryingLong
        }

        var value: String {
            switch self {
            case .waiting: "等这台电脑来连…"
            case .reconnecting, .notYet, .stillTrying, .stillTryingLong: "没连上"
            case .bluetoothOff: "蓝牙关了"
            }
        }

        /// 值左边带小转圈
        var showsSpinner: Bool { self == .waiting || self == .reconnecting }

        /// 「现在再试一次」（出现了就留到连上为止；按了也不消失）
        static let retryButtonTitle = "现在再试一次"
        static let retryButtonHint = "马上再连一次这台电脑"

        var footer: String {
            switch self {
            case .waiting: "电脑上开着 LockCurtain、人也在附近就行。"
            case .reconnecting: "正在重新连上…"
            case .notYet: "还没连上，我隔一会儿再试。"
            case .stillTrying, .stillTryingLong: "我还在试，最长隔 5 分钟一次，点下面那颗就不用等。"
            case .bluetoothOff: "打开 iPhone 的蓝牙，这台电脑才找得到它。"
            }
        }

        /// ④ 另起的一行
        var secondFooter: String? {
            self == .stillTryingLong ? "电脑上开着 LockCurtain 吗？在附近吗？两边蓝牙都开着吗？" : nil
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
    /// 已连接时走哪条路（蓝牙优先）；没连上是 nil
    private(set) var path: LinkPath?
    /// 网络那一路试得怎么样（设置里「网络地址」那一页用）
    private(set) var networkStatus: NetworkStatus = .none
    /// 存着的网络地址（UserDefaults lc.netAddress）；没填是 nil。没有地址永远不走网络
    private(set) var networkAddress: NetworkAddress? = NetworkAddress.load()
    private(set) var phase: CurtainPhase = .open
    private(set) var auto: CurtainAuto = .off
    private(set) var isCovering = false
    private(set) var didTimeOut = false
    /// 电脑签名回答「缺权限，没盖」（N2）：底栏那一行换成「没能盖上：电脑上还缺一个权限。」
    private(set) var coverMissingPermission = false

    /// 保持唤醒：电脑报来的状态（nil = 没报过）
    private(set) var keepAwake: KeepAwakeState?
    /// 保持唤醒命令发出去、还没签收：值的位置换成小转圈
    private(set) var isSendingKeepAwake = false
    /// 5 秒没签收：行下面一行「没送到，再试一次」
    private(set) var keepAwakeDidFail = false
    /// 签收了就加一（.sensoryFeedback(.selection)）
    private(set) var keepAwakeSuccessCount = 0
    private(set) var isAway = false
    private(set) var lastEventText = "没连上"
    private(set) var lastEventDate = Date()
    private(set) var isPreviewFixture = false
    /// 连续 5 次连上又断（手机照旧广播）。主屏不再看它（只按经过时间分段）；配对页还在用
    private(set) var connectionGaveUp = false
    /// 这次启动里刚配对成功：主屏在连接那一行下面提示一句「以后会自己连上」，下次启动就不再显示
    private(set) var justPaired = false
    /// 上次连上（或者 App 打开）以后，从什么时候起没连上；分段按这个算，不因回前台 / 按重试清零
    private(set) var disconnectedSince = Date()
    /// 这次启动里连上过没有（没连上过的前 30 秒说「等这台电脑来连…」）
    private(set) var everConnected = false
    /// 按了「现在再试一次」：到这个时候之前说「正在重新连上…」
    private(set) var retryingUntil: Date?
    /// 回到前台时加一：主屏立刻重算分段
    private(set) var foregroundCount = 0

    /// 现在撤下 sent, waiting for the Mac to report the curtain uncovered
    private(set) var isLifting = false
    private(set) var liftNotice: LiftNotice?
    /// 「幕布撤下了。…」 under the cover button: the Mac reported uncovered after a lift this phone caused
    private(set) var showLiftedNote = false
    /// 「走近撤下」 (UserDefaults, default on)
    private(set) var liftOnApproach = LiftSetting.isOn
    /// 「撤下前验证面容」 (UserDefaults, default on)
    private(set) var liftNeedsFaceID = LiftAuthSetting.isOn
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
    /// 进演示时暂存的真连接：演示只是不发真命令，蓝牙连接照旧留着，退出演示原样接回来
    @ObservationIgnored private var parkedLink: BLECurtainLink?
    /// 只有「自动」露面时才建：藏起来的时候一次都不碰定位
    @ObservationIgnored private var coverTask: Task<Void, Never>?
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var liftTask: Task<Void, Never>?
    @ObservationIgnored private var liftTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var demoLiftTask: Task<Void, Never>?
    @ObservationIgnored private var keepAwakeTask: Task<Void, Never>?
    @ObservationIgnored private var keepAwakeTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var lastPhoneLiftCount = 0
    /// Bumped on every 「再找一次」 tap (light impact haptic)
    private(set) var findAgainTapCount = 0

    /// 正在用的那个（App 委托在 applicationWillTerminate 里要看配没配对）
    nonisolated(unsafe) static weak var current: AppModel?

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
            .flatMap { DebugForcedCurtainLink(argument: $0, macName: "Studio 的电脑") }
        #else
        let forcedLink: (any CurtainLink)? = nil
        #endif

        if let forcedLink {
            let forcedPaired = forcedLink.snapshot.connection != .notPaired
            paired = forcedPaired
            demoMode = false
            macName = forcedPaired ? "Studio 的电脑" : nil
            if !forcedPaired { isPreviewFixture = true }   // 不走引导页，直接看主屏
            link = forcedLink
        } else if previewConnected {
            paired = true
            demoMode = false
            macName = "Studio 的电脑"
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
        // 没配着、但还有撤销了没告诉旧电脑的：安静地广播，等旧电脑来连（protocol-v3 §5，界面上什么都不说）
        if !paired, forcedLink == nil, let ble = link as? BLECurtainLink { ble.activateForPendingUnpair() }
        Self.current = self
        #if DEBUG
        // 截图用：-lcDisconnectedFor <秒> —— 假装已经断开这么久（看 ②③④ 段）；带上 -lcEverConnected 就当连上过
        let fakeElapsed = UserDefaults.standard.double(forKey: "lcDisconnectedFor")
        if fakeElapsed > 0 { disconnectedSince = Date().addingTimeInterval(-fakeElapsed) }
        if ProcessInfo.processInfo.arguments.contains("-lcEverConnected") { everConnected = true }
        #endif

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
        case .connected:
            switch path {
            case .network: "已连接 · 网络"
            case .bluetooth: "已连接 · 蓝牙"
            case nil: "已连接"
            }
        case .notConnected: unlinkedMacState?.value ?? "没连上"
        case .bluetoothOff: "蓝牙关了"
        case .notPaired: "没配对"
        }
    }

    // MARK: - 保持唤醒（ux-audit A4 / copy §16.3）

    /// 那一行能不能点：连上了、电脑报过保持唤醒状态（老电脑不报就点不动）；演示里总能点
    var canSetKeepAwake: Bool {
        connection == .connected && keepAwake != nil
    }

    func keepAwakeIsOn(at now: Date) -> Bool {
        keepAwake?.isOn(at: now) ?? false
    }

    /// 值：关 / 一直 / 到 18:30 / 还剩 1 小时 20 分 / Xcode 开着时；点不动时「—」
    func keepAwakeDisplayValue(at now: Date) -> String {
        guard canSetKeepAwake, let keepAwake else { return "—" }
        return Self.keepAwakeText(keepAwake, now: now)
    }

    /// VoiceOver 的值：点不动时说为什么（没连上 / 没配对），不念「—」
    func keepAwakeVoiceValue(at now: Date) -> String {
        guard canSetKeepAwake else {
            return connection == .notPaired ? "没配对" : "没连上"
        }
        return keepAwakeDisplayValue(at: now)
    }

    static func keepAwakeText(_ state: KeepAwakeState, now: Date) -> String {
        switch state {
        case .off:
            return "关"
        case .always:
            return "一直"
        case .whileApp(let name):
            return "\(name) 开着时"
        case .untilTime(let end):
            guard end > now else { return "关" }
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            return "到 \(formatter.string(from: end))"
        case .timed(let end):
            guard end > now else { return "关" }
            return remainingText(end.timeIntervalSince(now))
        }
    }

    /// 「还剩 1 小时 20 分」：分钟往上取整（刚开 1 小时就是「还剩 1 小时」）
    static func remainingText(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "不到 1 分钟" }  // copy v15 §17.3：别出现「还剩 0 分」
        let minutes = Int((seconds / 60).rounded(.up))
        let h = minutes / 60
        let m = minutes % 60
        if h == 0 { return "还剩 \(m) 分" }
        if m == 0 { return "还剩 \(h) 小时" }
        return "还剩 \(h) 小时 \(m) 分"
    }

    /// 选了一项：发签名命令（不要面容）。5 秒没签收：值回到原来（本来就没先改），行下面说「没送到，再试一次」
    func setKeepAwake(_ choice: KeepAwakeChoice) {
        guard canSetKeepAwake, !isSendingKeepAwake else { return }
        isSendingKeepAwake = true
        keepAwakeDidFail = false
        keepAwakeTask?.cancel()
        keepAwakeTimeoutTask?.cancel()
        keepAwakeTask = Task { [weak self] in
            guard let self else { return }
            let ok = await self.link.setKeepAwake(choice)
            guard !Task.isCancelled, self.isSendingKeepAwake else { return }
            self.finishKeepAwake(ok)
        }
        keepAwakeTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, !Task.isCancelled, self.isSendingKeepAwake else { return }
            self.keepAwakeTask?.cancel()
            self.finishKeepAwake(false)
        }
    }

    private func finishKeepAwake(_ ok: Bool) {
        keepAwakeTimeoutTask?.cancel()
        keepAwakeTimeoutTask = nil
        isSendingKeepAwake = false
        if ok {
            keepAwakeDidFail = false
            keepAwakeSuccessCount += 1
        } else {
            keepAwakeDidFail = true
        }
    }

    private func resetKeepAwakeSending() {
        keepAwakeTask?.cancel()
        keepAwakeTimeoutTask?.cancel()
        isSendingKeepAwake = false
        keepAwakeDidFail = false
    }

    /// 配过对、不在演示、没连上：现在是哪一段；其他时候是 nil
    var unlinkedMacState: UnlinkedMacState? { unlinkedMacState(at: Date()) }

    func unlinkedMacState(at now: Date) -> UnlinkedMacState? {
        guard paired, !demoMode, connection != .connected, connection != .notPaired else { return nil }
        if connection == .bluetoothOff { return .bluetoothOff }
        let retrying = retryingUntil.map { now < $0 } ?? false
        return .at(elapsed: now.timeIntervalSince(disconnectedSince), everConnected: everConnected, retrying: retrying)
    }

    /// 「现在再试一次」该不该在：没连上过了 30 秒就出现，留到连上为止（按了也不消失）
    func showsRetryNow(at now: Date) -> Bool {
        guard let state = unlinkedMacState(at: now), state != .bluetoothOff else { return false }
        return now.timeIntervalSince(disconnectedSince) >= UnlinkedMacState.firstStage
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

    /// 「现在再试一次」：立刻试一次，「正在重新连上…」到有结果或 30 秒；经过时间不清零。不拦连点
    func retryNow() {
        guard let state = unlinkedMacState, state != .bluetoothOff else { return }
        findAgainTapCount += 1
        retryingUntil = Date().addingTimeInterval(UnlinkedMacState.retryShowsFor)
        if let ble = link as? BLECurtainLink {
            ble.retryNow()
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
        coverMissingPermission = false
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

    func setLiftNeedsFaceID(_ isOn: Bool) {
        LiftAuthSetting.isOn = isOn
        liftNeedsFaceID = isOn
    }

    /// 不看「走近撤下」开关：已连上、幕布盖着就能按
    var canLiftNow: Bool {
        connection == .connected && phase == .closed && !isLifting && NetworkLinkPlan.canLift(path: path)
    }

    /// 走网络连着、幕布盖着：撤下只能在蓝牙上，主屏不显示「现在撤下」，换一行说明
    var liftHiddenOnNetwork: Bool {
        connection == .connected && path == .network && phase == .closed
    }

    /// 现在撤下: Face ID or passcode first (not in the demo, not with 撤下前验证面容 off), then the signed lift-now.
    /// Cancel / failure changes nothing and shows nothing.
    func liftNow() {
        guard canLiftNow else { return }
        liftNotice = nil
        if demoMode || !liftNeedsFaceID {
            startLift()
            return
        }
        let context = LAContext()
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "撤下这台电脑的幕布") { [weak self] ok, _ in
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
        // 网络只在前台走（iOS 会挂起后台的 TCP）
        ((link as? BLECurtainLink) ?? parkedLink)?.setForeground(false)
    }

    /// 回到前台：退避清零、马上广播（不等任何计时）；主屏立刻重算分段（经过时间不清零）
    func appDidBecomeActive() {
        foregroundCount += 1
        TerminationNotice.refresh()
        ((link as? BLECurtainLink) ?? parkedLink)?.setForeground(true)
        if paired, !demoMode, let ble = link as? BLECurtainLink {
            ble.resumeConnecting()
        } else if !paired, let ble = (link as? BLECurtainLink) ?? parkedLink {
            ble.activateForPendingUnpair()
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
        coverMissingPermission = false
        resetKeepAwakeSending()

        demoLiftTask?.cancel()
        liftTask?.cancel()
        endLifting()
        liftNotice = nil
        showLiftedNote = false

        if isOn {
            showDemoExitNotice = false
            demoScenario = .connected
            if let ble = link as? BLECurtainLink { parkedLink = ble }
            let link = DemoCurtainLink()
            demoLink = link
            adopt(link)
        } else {
            demoLink = nil
            demoScenario = .connected
            if let ble = parkedLink {
                parkedLink = nil
                adopt(ble)
            } else {
                adopt(BLECurtainLink(paired: paired, macName: macName))
            }
            if paired {
                if let ble = link as? BLECurtainLink { ble.resumeConnecting() } else { link.activate() }
            } else if let ble = link as? BLECurtainLink {
                ble.activateForPendingUnpair()
            }
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
            completePairing(macName: ble.snapshot.macName ?? "这台电脑")
        }
        return result
    }

    /// 换电脑（copy v11 §13）：已经配着一台，在旁边配另一台；配成了才换掉，没配成原来那台一概不动
    func pairReplacing(code: String) async -> PairResult {
        guard paired, !demoMode, let ble = link as? BLECurtainLink else { return await pair(code: code) }
        let result = await ble.pairReplacing(code: code)
        if result == .accepted {
            let name = "这台电脑"
            macName = name
            UserDefaults.standard.set(name, forKey: Keys.macName)
            // 换了电脑：旧电脑的网络地址作废
            forgetNetworkAddress()
        }
        return result
    }

    /// 换电脑中途关掉配对页：作废，不弹任何提示
    func cancelReplacing() {
        (link as? BLECurtainLink)?.cancelReplacing()
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
            // 被划掉时那条通知：先要临时授权（不弹框）
            TerminationNotice.requestProvisional()
        }
        UserDefaults.standard.set(macName, forKey: Keys.macName)
        if !demoMode, !(link is BLECurtainLink) {
            adopt(BLECurtainLink(paired: true, macName: macName))
        }
    }

    /// 撤销配对（protocol-v3 §5）：界面马上回到没配对，对那台电脑什么都不再发；
    /// 钥匙挪进待撤销，连着就当场、没连着就等它下次来时，用它签一条 unpair（见 BLECurtainLink.unpair）
    func unpair() {
        paired = false
        justPaired = false
        macName = nil
        resetKeepAwakeSending()
        UserDefaults.standard.removeObject(forKey: Keys.macName)
        forgetNetworkAddress()
        if let ble = (link as? BLECurtainLink) ?? parkedLink {
            ble.unpair()
        } else {
            PhoneKeychain.moveLinkToPendingUnpair()
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
        forgetNetworkAddress()
    }

    // MARK: - 网络地址

    /// 存下用户填的地址并马上试连一次（第一次也会触发 iOS 的「本地网络」询问）。解析不过返回 false，什么都不存
    @discardableResult
    func saveNetworkAddress(_ text: String) -> Bool {
        guard paired, !demoMode, let address = NetworkAddress.parse(text) else { return false }
        NetworkAddress.save(address)
        networkAddress = address
        ((link as? BLECurtainLink) ?? parkedLink)?.networkAddressChanged(connectNow: true)
        return true
    }

    /// 「清除」：忘掉地址，网络停掉
    func clearNetworkAddress() {
        forgetNetworkAddress()
    }

    /// 撤销配对 / 换电脑 / 被电脑撤销：地址跟着配对走，一起清
    private func forgetNetworkAddress() {
        NetworkAddress.clear()
        networkAddress = nil
        networkStatus = .none
        ((link as? BLECurtainLink) ?? parkedLink)?.networkAddressChanged(connectNow: false)
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
        if snapshot.connection != connection {
            coverMissingPermission = false
            if snapshot.connection != .connected { resetKeepAwakeSending() }
        }
        keepAwake = snapshot.keepAwake
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
        if snapshot.connection == .connected {
            everConnected = true
            retryingUntil = nil
        } else if connection == .connected {
            // 刚断开：从这一刻算经过时间
            disconnectedSince = Date()
            retryingUntil = nil
        }
        connection = snapshot.connection
        path = snapshot.connection == .connected ? snapshot.path : nil
        networkStatus = snapshot.networkStatus
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
        case .missingPermission:
            didTimeOut = false
            coverMissingPermission = true
            if phase == .closing { phase = .open }
            recordEvent(text: "没盖上")
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
