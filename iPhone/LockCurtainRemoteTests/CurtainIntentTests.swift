import Foundation
import Testing
@testable import LockCurtain

/// 快捷指令的纯规则（走哪条路、撤下的前提、电脑的回答 → 结果 → 一句话），和用假连接跑一遍 IntentCurtainRunner
@MainActor
struct CurtainIntentTests {
    // MARK: - 假的连接和环境

    @MainActor
    final class FakeLink: CurtainIntentLink {
        var snapshot = CurtainSnapshot(connection: .notConnected, phase: .open, auto: .off, macName: "电脑")
        var lastStateAt: Date?
        var lastAwakeAt: Date?
        var coverResult: CoverOutcome = .covered
        var liftResult: LiftOutcome = .lifted
        var previewResult: PreviewOutcome = .received
        var keepAwakeAcked = true
        var keepAwakeReport: KeepAwakeState?
        private(set) var calls: [String] = []
        private(set) var sessions: [UUID: Bool] = [:]
        private(set) var endedSessions = 0
        /// requestState 之后电脑报来的幕布状态
        var stateAfterRequest: CurtainPhase?
        let clock: Clock

        init(clock: Clock) { self.clock = clock }

        func connect(_ path: LinkPath, phase: CurtainPhase = .open) {
            snapshot.connection = .connected
            snapshot.path = path
            snapshot.phase = phase
        }

        func activate() { calls.append("activate") }
        func beginIntentSession(allowNetwork: Bool) -> UUID {
            let token = UUID()
            sessions[token] = allowNetwork
            return token
        }
        func endIntentSession(_ token: UUID) {
            if sessions[token] != nil { endedSessions += 1 }
        }
        func cover() async -> CoverOutcome { calls.append("cover"); return coverResult }
        func liftNow() async -> LiftOutcome { calls.append("lift"); return liftResult }
        func previewNow() async -> PreviewOutcome { calls.append("preview"); return previewResult }
        func setKeepAwake(_ choice: KeepAwakeChoice) async -> Bool {
            calls.append("awake:" + choice.rawValue)
            if keepAwakeAcked, let report = keepAwakeReport {
                snapshot.keepAwake = report
                lastAwakeAt = clock.now
            }
            return keepAwakeAcked
        }
        func requestState() {
            calls.append("requestState")
            if let phase = stateAfterRequest {
                snapshot.phase = phase
                lastStateAt = clock.now
            }
        }
    }

    final class Clock {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        /// 到了这个时间点就执行一次
        var events: [(at: TimeInterval, run: () -> Void)] = []
        var start: Date
        init() { start = now }
        func advance(_ seconds: TimeInterval) {
            now = now.addingTimeInterval(seconds)
            let elapsed = now.timeIntervalSince(start)
            for event in events where event.at <= elapsed { event.run() }
            events.removeAll { $0.at <= elapsed }
        }
    }

    final class LogBox { var lines: [String] = [] }

    static func rig(paired: Bool = true, address: Bool = false, unlocked: Bool = true,
                    configure: (FakeLink, Clock) -> Void = { _, _ in }) -> (IntentCurtainRunner, FakeLink, Clock, LogBox) {
        let clock = Clock()
        let link = FakeLink(clock: clock)
        let logs = LogBox()
        configure(link, clock)
        let env = IntentEnvironment(
            isPaired: { paired },
            hasNetworkAddress: { address },
            makeLink: { link },
            isPhoneUnlocked: { unlocked },
            now: { clock.now },
            sleep: { clock.advance($0) },
            log: { logs.lines.append($0) })
        return (IntentCurtainRunner(environment: env), link, clock, logs)
    }

    // MARK: - 走哪条路

    private func facts(_ connection: CurtainConnection = .notConnected, path: LinkPath? = nil,
                       paired: Bool = true, address: Bool = false) -> IntentPlan.Facts {
        .init(paired: paired, hasNetworkAddress: address, connection: connection, path: path)
    }

    @Test
    func coverAndKeepAwakeTakeEitherPath() {
        for kind in [CurtainIntentKind.cover, .keepAwake] {
            #expect(IntentPlan.gate(kind: kind, facts: facts(.connected, path: .bluetooth), elapsed: 0) == .ready(.bluetooth))
            #expect(IntentPlan.gate(kind: kind, facts: facts(.connected, path: .network), elapsed: 0) == .ready(.network))
        }
    }

    @Test
    func liftAndPreviewNeverTakeTheNetwork() {
        for kind in [CurtainIntentKind.lift, .preview] {
            let onlyNetwork = facts(.connected, path: .network, address: true)
            #expect(IntentPlan.gate(kind: kind, facts: onlyNetwork, elapsed: 0) == .wait)
            #expect(IntentPlan.gate(kind: kind, facts: onlyNetwork, elapsed: IntentPlan.bleOnlyNetworkGrace)
                    == .fail(kind == .lift ? .liftOnNetwork : .previewOnNetwork))
            // 蓝牙在最后一刻来了：照样走蓝牙
            #expect(IntentPlan.gate(kind: kind, facts: facts(.connected, path: .bluetooth, address: true), elapsed: 5) == .ready(.bluetooth))
        }
    }

    @Test
    func notPairedFailsAtOnce() {
        for kind in CurtainIntentKind.allCases {
            #expect(IntentPlan.gate(kind: kind, facts: facts(.notPaired, paired: false), elapsed: 0) == .fail(.notPaired))
        }
    }

    @Test
    func bluetoothOffAndNoWayToReach() {
        // 蓝牙关着、没存网络地址：等一下状态稳了就说蓝牙关了
        for kind in CurtainIntentKind.allCases {
            #expect(IntentPlan.gate(kind: kind, facts: facts(.bluetoothOff), elapsed: 0) == .wait)
            #expect(IntentPlan.gate(kind: kind, facts: facts(.bluetoothOff), elapsed: IntentPlan.bluetoothSettle) == .fail(.bluetoothOff))
        }
        // 蓝牙关着、存了网络地址：盖上 / 保持唤醒继续等网络；撤下 / 预览网络帮不上，直接说蓝牙关了
        let withAddress = facts(.bluetoothOff, address: true)
        #expect(IntentPlan.gate(kind: .cover, facts: withAddress, elapsed: 5) == .wait)
        #expect(IntentPlan.gate(kind: .keepAwake, facts: withAddress, elapsed: 5) == .wait)
        #expect(IntentPlan.gate(kind: .lift, facts: withAddress, elapsed: 5) == .fail(.bluetoothOff))
        #expect(IntentPlan.gate(kind: .preview, facts: withAddress, elapsed: 5) == .fail(.bluetoothOff))
        // 蓝牙开着但电脑一直不来连：等满才放弃
        for kind in CurtainIntentKind.allCases {
            let waiting = facts(.notConnected, address: true)
            #expect(IntentPlan.gate(kind: kind, facts: waiting, elapsed: IntentPlan.pathWait - 0.5) == .wait)
            #expect(IntentPlan.gate(kind: kind, facts: waiting, elapsed: IntentPlan.pathWait) == .fail(.noReach))
        }
    }

    @Test
    func factsOnlyTrustAPathWhenConnected() {
        var snap = CurtainSnapshot(connection: .notConnected, phase: .open, auto: .off, macName: nil)
        snap.path = .network   // 不该出现，但出现了也不能当成通着
        #expect(IntentPlan.facts(from: snap, paired: true, hasNetworkAddress: true).path == nil)
        snap.connection = .connected
        #expect(IntentPlan.facts(from: snap, paired: true, hasNetworkAddress: true).path == .network)
    }

    // MARK: - 撤下的前提

    @Test
    func liftPreconditions() {
        #expect(IntentPlan.liftPreconditionFailure(phoneUnlocked: true, path: .bluetooth) == nil)
        #expect(IntentPlan.liftPreconditionFailure(phoneUnlocked: false, path: .bluetooth) == .phoneLocked)
        #expect(IntentPlan.liftPreconditionFailure(phoneUnlocked: true, path: .network) == .liftOnNetwork)
        #expect(IntentPlan.liftPreconditionFailure(phoneUnlocked: true, path: nil) == .liftOnNetwork)
        #expect(IntentPlan.liftPreconditionFailure(phoneUnlocked: false, path: .network) == .phoneLocked)
    }

    // MARK: - 电脑的回答 → 结果

    @Test
    func onlyTheRightAnswerIsSuccess() {
        #expect(IntentPlan.outcome(cover: .covered) == .covered)
        for bad in [CoverOutcome.timedOut, .missingPermission, .unavailable] {
            #expect(!IntentPlan.outcome(cover: bad).isSuccess)
        }
        #expect(IntentPlan.outcome(lift: .lifted) == .lifted)
        for bad in [LiftOutcome.tooFar, .notCovered, .refused, .timedOut, .unavailable] {
            #expect(!IntentPlan.outcome(lift: bad).isSuccess)
        }
        #expect(IntentPlan.outcome(preview: .received) == .previewed)
        for bad in [PreviewOutcome.timedOut, .refused, .unavailable] {
            #expect(!IntentPlan.outcome(preview: bad).isSuccess)
        }
        #expect(!IntentPlan.outcome(keepAwakeAcked: false, choice: .always, reported: .always, now: Date()).isSuccess)
        #expect(IntentPlan.outcome(keepAwakeAcked: true, choice: .always, reported: nil, now: Date()).isSuccess)
    }

    @Test
    func keepAwakeReportMustMatchTheChoice() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let later = now.addingTimeInterval(3000)
        #expect(IntentPlan.reportMatches(.off, .off, now: now))
        #expect(IntentPlan.reportMatches(.always, .always, now: now))
        #expect(IntentPlan.reportMatches(.oneHour, .timed(endsAt: later), now: now))
        #expect(!IntentPlan.reportMatches(.oneHour, .timed(endsAt: now.addingTimeInterval(-1)), now: now))
        #expect(!IntentPlan.reportMatches(.always, .off, now: now))
        #expect(!IntentPlan.reportMatches(.off, .always, now: now))
        #expect(!IntentPlan.reportMatches(.twoHours, .whileApp("Xcode"), now: now))
    }

    // MARK: - 说的话

    private static let successLines: Set<String> = ["盖上了。", "撤下了。", "开始预览了。", "保持唤醒关了。"]

    private static func prefix(_ kind: CurtainIntentKind) -> String {
        switch kind {
        case .cover: "没盖上："
        case .lift: "没撤下："
        case .preview: "没能预览："
        case .keepAwake: "没能保持唤醒："
        case .toggle: "幕布没动："
        }
    }

    @Test
    func everyFailureHasAnHonestNonEmptyLineWithItsPrefix() {
        for kind in CurtainIntentKind.allCases {
            for failure in IntentFailure.allCases {
                let line = IntentCopy.text(kind: kind, outcome: .failed(failure))
                #expect(!line.isEmpty, "\(kind) \(failure)")
                // §20.5：每条都带前缀，后面还有原因
                #expect(line.hasPrefix(Self.prefix(kind)), "\(kind) \(failure): \(line)")
                #expect(line.count > Self.prefix(kind).count, "\(kind) \(failure): \(line)")
                #expect(!Self.successLines.contains(line), "\(kind) \(failure)")
                #expect(!line.hasPrefix("保持唤醒中"), "\(kind) \(failure)")
                for banned in ["失败", "错误", "未知问题", "操作超时", "超时", "已发送", "遮罩", "成功", "已连接"] {
                    #expect(!line.contains(banned), "\(kind) \(failure): \(line)")
                }
            }
        }
    }

    @Test
    func failureReasonsAreCamosOwnSentences() {
        let allowed: Set<String> = [
            "还没和这台电脑配对。", "手机的蓝牙关着，打开再试。", "手机没连上这台电脑。", "离这台电脑太远，走近再试。",
            "走网络时不能预览。", "走网络时不能撤下。", "电脑没有接受这条命令。", "电脑没有回应。",
            "手机锁着。", "要先解锁手机。", "要先过面容。", "面容或密码没通过。",
            // App 里已有、Camo 的列表里没有对应的几句（意思不变，放在前缀后面）
            "电脑上还缺一个权限。", "幕布已经是撤下的了。", "这次没撤下来，再按一次。",
            // §20.7 v15.15：切换还没分出盖或撤、电脑没报状态
            "电脑没说现在盖着没盖。",
        ]
        for kind in CurtainIntentKind.allCases {
            for failure in IntentFailure.allCases {
                let line = IntentCopy.text(kind: kind, outcome: .failed(failure))
                #expect(allowed.contains(String(line.dropFirst(Self.prefix(kind).count))), "\(kind) \(failure): \(line)")
            }
        }
    }

    @Test
    func failuresOfLiftSayNothingWasLifted() {
        for failure in IntentFailure.allCases {
            let line = IntentCopy.text(kind: .lift, outcome: .failed(failure))
            #expect(!line.contains("撤下了"), "\(failure): \(line)")
        }
    }

    @Test
    func everySuccessLineIsNonEmptyAndOnlyForSuccess() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let successes: [(CurtainIntentKind, IntentOutcome)] = [
            (.cover, .covered), (.lift, .lifted), (.preview, .previewed),
            (.keepAwake, .keepAwakeSet(.off, state: nil)),
            (.keepAwake, .keepAwakeSet(.always, state: .always)),
            (.keepAwake, .keepAwakeSet(.oneHour, state: .timed(endsAt: now.addingTimeInterval(3600)))),
        ]
        for (kind, outcome) in successes {
            #expect(outcome.isSuccess)
            let line = IntentCopy.text(kind: kind, outcome: outcome, now: now)
            #expect(!line.isEmpty)
            for failurePrefix in ["没盖上：", "没撤下：", "没能预览：", "没能保持唤醒："] {
                #expect(!line.hasPrefix(failurePrefix))
            }
        }
        #expect(IntentCopy.text(kind: .cover, outcome: .covered) == "盖上了。")
        #expect(IntentCopy.text(kind: .lift, outcome: .lifted) == "撤下了。")
        // 预览：电脑在预览开始时就回执，所以说「开始预览了。」，不说「预览完了」
        #expect(IntentCopy.text(kind: .preview, outcome: .previewed) == "开始预览了。")
        for choice in KeepAwakeChoice.allCases {
            #expect(!IntentCopy.label(choice).isEmpty)
        }
    }

    @Test
    func keepAwakeSuccessLines() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func line(_ choice: KeepAwakeChoice, _ state: KeepAwakeState?) -> String {
            IntentCopy.text(kind: .keepAwake, outcome: .keepAwakeSet(choice, state: state), now: now)
        }
        #expect(line(.oneHour, .timed(endsAt: now.addingTimeInterval(3600))) == "保持唤醒中，还剩 1 小时。")
        #expect(line(.twoHours, .timed(endsAt: now.addingTimeInterval(7200))) == "保持唤醒中，还剩 2 小时。")
        #expect(line(.fiveHours, .timed(endsAt: now.addingTimeInterval(5 * 3600))) == "保持唤醒中，还剩 5 小时。")
        // 没等到电脑报状态：用选的那一项
        #expect(line(.oneHour, nil) == "保持唤醒中，还剩 1 小时。")
        #expect(line(.twoHours, nil) == "保持唤醒中，还剩 2 小时。")
        #expect(line(.fiveHours, nil) == "保持唤醒中，还剩 5 小时。")
        // 不带时长
        #expect(line(.always, .always) == "保持唤醒中。")
        #expect(line(.always, nil) == "保持唤醒中。")
        // 关掉
        #expect(line(.off, .off) == "保持唤醒关了。")
        #expect(line(.off, nil) == "保持唤醒关了。")
    }

    @Test
    func keepAwakeChoicesAreTheAppsOwnFive() {
        #expect(KeepAwakeChoice.allCases.map { IntentCopy.label($0) } == ["关掉", "1 小时", "2 小时", "5 小时", "一直"])
        let words = KeepAwakeChoice.caseDisplayRepresentations.values.map { String(localized: $0.title) }
        #expect(!words.contains("30 分钟") && !words.contains("4 小时"))
    }

    @Test
    func mappedFailuresUseTheRightReasonPerAction() {
        #expect(IntentCopy.text(kind: .cover, failure: .noAnswer) == "没盖上：电脑没有回应。")
        #expect(IntentCopy.text(kind: .cover, failure: .missingPermission) == "没盖上：电脑上还缺一个权限。")
        #expect(IntentCopy.text(kind: .lift, failure: .tooFar) == "没撤下：离这台电脑太远，走近再试。")
        #expect(IntentCopy.text(kind: .lift, failure: .alreadyUncovered) == "没撤下：幕布已经是撤下的了。")
        #expect(IntentCopy.text(kind: .lift, failure: .refused) == "没撤下：这次没撤下来，再按一次。")
        #expect(IntentCopy.text(kind: .preview, failure: .refused) == "没能预览：电脑没有接受这条命令。")
        #expect(IntentCopy.text(kind: .keepAwake, failure: .notDelivered) == "没能保持唤醒：电脑没有回应。")
        #expect(IntentCopy.text(kind: .lift, failure: .liftOnNetwork) == "没撤下：走网络时不能撤下。")
        #expect(IntentCopy.text(kind: .preview, failure: .previewOnNetwork) == "没能预览：走网络时不能预览。")
        #expect(IntentCopy.text(kind: .lift, failure: .phoneLocked) == "没撤下：要先解锁手机。")
        for kind in [CurtainIntentKind.cover, .preview, .keepAwake] {
            #expect(IntentCopy.text(kind: kind, failure: .phoneLocked).hasSuffix("手机锁着。"))
        }
        #expect(IntentCopy.text(kind: .lift, failure: .authCancelled) == "没撤下：要先过面容。")
        #expect(IntentCopy.text(kind: .lift, failure: .authFailed) == "没撤下：面容或密码没通过。")
        #expect(IntentCopy.text(kind: .cover, failure: .notPaired) == "没盖上：还没和这台电脑配对。")
        #expect(IntentCopy.text(kind: .cover, failure: .bluetoothOff) == "没盖上：手机的蓝牙关着，打开再试。")
        #expect(IntentCopy.text(kind: .keepAwake, failure: .noReach) == "没能保持唤醒：手机没连上这台电脑。")
    }

    // MARK: - 跑起来（假连接）

    @Test
    func coverOverBluetoothSucceedsOnlyAfterTheComputerAnswers() async {
        let (runner, link, _, logs) = Self.rig { link, _ in link.connect(.bluetooth) }
        let outcome = await runner.run(.cover)
        #expect(outcome == .covered)
        #expect(link.calls == ["activate", "cover"])
        #expect(link.sessions.count == 1 && link.endedSessions == 1)
        #expect(logs.lines.contains { $0.contains("path: bluetooth") })
        #expect(logs.lines.contains { $0.contains("done: covered") && $0.contains(" s") })
    }

    @Test
    func coverFailuresAreNeverSuccess() async {
        for result in [CoverOutcome.timedOut, .missingPermission, .unavailable] {
            let (runner, _, _, _) = Self.rig { link, _ in link.connect(.bluetooth); link.coverResult = result }
            let outcome = await runner.run(.cover)
            #expect(!outcome.isSuccess, "\(result)")
            #expect(!IntentCopy.text(kind: .cover, outcome: outcome).isEmpty)
        }
    }

    @Test
    func coverWaitsForTheComputerToReconnect() async {
        // App 被划掉：先没有路，5 秒后电脑连回来
        let (runner, _, clock, _) = Self.rig { link, clock in
            clock.events.append((5, { [unowned link] in link.connect(.bluetooth) }))
        }
        let outcome = await runner.run(.cover)
        #expect(outcome == .covered)
        #expect(clock.now.timeIntervalSince(clock.start) >= 5)
        #expect(clock.now.timeIntervalSince(clock.start) < IntentPlan.pathWait)
    }

    @Test
    func coverGivesUpAfterTheWait() async {
        let (runner, link, clock, logs) = Self.rig(address: true)
        let outcome = await runner.run(.cover)
        #expect(outcome == .failed(.noReach))
        #expect(link.calls == ["activate"])
        #expect(clock.now.timeIntervalSince(clock.start) >= IntentPlan.pathWait)
        #expect(link.endedSessions == 1)
        #expect(logs.lines.contains { $0.contains("failed (noReach)") })
    }

    @Test
    func networkIsOnlyRequestedWhenAnAddressIsSaved() async {
        let (a, linkA, _, _) = Self.rig(address: true) { link, _ in link.connect(.network) }
        #expect(await a.run(.cover) == .covered)
        #expect(Array(linkA.sessions.values) == [true])
        let (b, linkB, _, _) = Self.rig(address: false) { link, _ in link.connect(.bluetooth) }
        #expect(await b.run(.cover) == .covered)
        #expect(Array(linkB.sessions.values) == [false])
    }

    @Test
    func notPairedDoesNotTouchTheLink() async {
        let (runner, link, _, _) = Self.rig(paired: false)
        let outcome = await runner.run(.cover)
        #expect(outcome == .failed(.notPaired))
        #expect(link.calls.isEmpty && link.sessions.isEmpty)
    }

    @Test
    func previewOverNetworkIsRefusedHonestly() async {
        let (runner, link, _, _) = Self.rig(address: true) { link, _ in link.connect(.network) }
        let outcome = await runner.run(.preview)
        #expect(outcome == .failed(.previewOnNetwork))
        #expect(!link.calls.contains("preview"))
    }

    @Test
    func previewOverBluetooth() async {
        let (runner, link, _, _) = Self.rig { link, _ in link.connect(.bluetooth) }
        #expect(await runner.run(.preview) == .previewed)
        #expect(link.calls.contains("preview"))
        link.previewResult = .timedOut
        #expect(await runner.run(.preview) == .failed(.noAnswer))
        link.previewResult = .refused
        #expect(await runner.run(.preview) == .failed(.refused))
    }

    @Test
    func keepAwakeUsesTheComputersReport() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let (runner, link, _, _) = Self.rig { link, _ in
            link.connect(.network)
            link.keepAwakeReport = .timed(endsAt: Date(timeIntervalSince1970: 1_800_000_000 + 3600))
        }
        let outcome = await runner.run(.keepAwake, choice: .oneHour)
        guard case .keepAwakeSet(.oneHour, let state?) = outcome else { Issue.record("\(outcome)"); return }
        #expect(state == .timed(endsAt: now.addingTimeInterval(3600)))
        #expect(link.calls.contains("awake:1h"))
    }

    @Test
    func keepAwakeIgnoresAnOldReportAndFailsWithoutAnAck() async {
        // 手机上留着上一次的「还剩……」：不能当成这次的结果
        let (runner, link, _, _) = Self.rig { link, clock in
            link.connect(.bluetooth)
            link.snapshot.keepAwake = .timed(endsAt: clock.now.addingTimeInterval(1200))
            link.lastAwakeAt = clock.now.addingTimeInterval(-60)
        }
        let outcome = await runner.run(.keepAwake, choice: .oneHour)
        #expect(outcome == .keepAwakeSet(.oneHour, state: nil))
        #expect(IntentCopy.text(kind: .keepAwake, outcome: outcome) == "保持唤醒中，还剩 1 小时。")

        link.keepAwakeAcked = false
        #expect(await runner.run(.keepAwake, choice: .always) == .failed(.notDelivered))
    }

    // MARK: 撤下

    @Test
    func liftNeedsAuthenticationEveryTimeAndNothingHappensWithoutIt() async {
        for (auth, expected) in [(IntentAuthResult.cancelled, IntentFailure.authCancelled), (.failed, .authFailed)] {
            let (runner, link, _, _) = Self.rig { link, _ in link.connect(.bluetooth, phase: .closed) }
            let outcome = await runner.run(.lift) { auth }
            #expect(outcome == .failed(expected))
            #expect(!link.calls.contains("lift"))
        }
        // 没给验证的办法 = 没验证
        let (runner, link, _, _) = Self.rig { link, _ in link.connect(.bluetooth, phase: .closed) }
        #expect(await runner.run(.lift) == .failed(.authFailed))
        #expect(!link.calls.contains("lift"))
    }

    @Test
    func liftAsksAgainOnEveryRun() async {
        let (runner, link, _, _) = Self.rig { link, _ in link.connect(.bluetooth, phase: .closed) }
        var asked = 0
        for _ in 0..<3 {
            let outcome = await runner.run(.lift) { asked += 1; return .passed }
            #expect(outcome == .lifted)
        }
        #expect(asked == 3)
        #expect(link.calls.filter { $0 == "lift" }.count == 3)
    }

    @Test
    func liftRefusesWhenPhoneIsLockedOrOnNetwork() async {
        let (locked, lockedLink, _, _) = Self.rig(unlocked: false) { link, _ in link.connect(.bluetooth, phase: .closed) }
        #expect(await locked.run(.lift) { .passed } == .failed(.phoneLocked))
        #expect(!lockedLink.calls.contains("lift"))

        let (net, netLink, clock, _) = Self.rig(address: true) { link, _ in link.connect(.network, phase: .closed) }
        #expect(await net.run(.lift) { .passed } == .failed(.liftOnNetwork))
        #expect(!netLink.calls.contains("lift"))
        #expect(clock.now.timeIntervalSince(clock.start) >= IntentPlan.bleOnlyNetworkGrace)

        let (off, offLink, _, _) = Self.rig { link, _ in link.snapshot.connection = .bluetoothOff }
        #expect(await off.run(.lift) { .passed } == .failed(.bluetoothOff))
        #expect(!offLink.calls.contains("lift"))
    }

    @Test
    func liftSwitchesToBluetoothIfItComesBackWhileWaiting() async {
        let (runner, link, _, _) = Self.rig(address: true) { link, clock in
            link.connect(.network, phase: .closed)
            clock.events.append((2, { [unowned link] in link.connect(.bluetooth, phase: .closed) }))
        }
        #expect(await runner.run(.lift) { .passed } == .lifted)
        #expect(link.calls.contains("lift"))
    }

    @Test
    func liftMapsTheComputersAnswers() async {
        let cases: [(LiftOutcome, IntentFailure)] = [
            (.tooFar, .tooFar), (.notCovered, .alreadyUncovered), (.refused, .refused),
            (.timedOut, .noAnswer), (.unavailable, .noReach),
        ]
        for (answer, failure) in cases {
            let (runner, link, _, _) = Self.rig { link, _ in link.connect(.bluetooth, phase: .closed); link.liftResult = answer }
            let outcome = await runner.run(.lift) { .passed }
            #expect(outcome == .failed(failure))
            #expect(link.calls.filter { $0 == "lift" }.count == 1)
        }
    }

    @Test
    func liftDoesNotClaimAlreadyUncoveredWithoutAFreshState() async {
        // 手机上是「开着」，但那是旧的、电脑也没回应：不知道，不能说「已经撤下的了」
        let (silent, silentLink, _, _) = Self.rig { link, _ in link.connect(.bluetooth, phase: .open) }
        #expect(await silent.run(.lift) { .passed } == .failed(.stateUnknown))
        #expect(!silentLink.calls.contains("lift"))
        // 电脑新报来「开着」：才说已经撤下
        let (fresh, freshLink, _, _) = Self.rig { link, _ in
            link.connect(.bluetooth, phase: .open)
            link.stateAfterRequest = .open
        }
        #expect(await fresh.run(.lift) { .passed } == .failed(.alreadyUncovered))
        #expect(!freshLink.calls.contains("lift"))
        // 电脑新报来「盖着」：接着撤
        let (covered, coveredLink, _, _) = Self.rig { link, _ in
            link.connect(.bluetooth, phase: .open)
            link.stateAfterRequest = .closed
        }
        #expect(await covered.run(.lift) { .passed } == .lifted)
        #expect(coveredLink.calls.contains("lift"))
    }

    // MARK: 切换

    @Test
    func toggleCoversWhenOpenWithoutAskingForFaceID() async {
        let (runner, link, _, _) = Self.rig { link, clock in
            link.connect(.network, phase: .open)
            link.lastStateAt = clock.now
        }
        var asked = 0
        let result = await runner.toggle { asked += 1; return .passed }
        #expect(result.action == .cover)
        #expect(result.outcome == .covered)
        #expect(asked == 0)
        #expect(link.calls.contains("cover") && !link.calls.contains("lift"))
        #expect(IntentCopy.text(kind: result.action, outcome: result.outcome) == "盖上了。")
    }

    @Test
    func toggleLiftsWhenCoveredAndAuthenticatesFirst() async {
        let (runner, link, _, _) = Self.rig { link, clock in
            link.connect(.bluetooth, phase: .closed)
            link.lastStateAt = clock.now
        }
        var asked = 0
        let result = await runner.toggle { asked += 1; return .passed }
        #expect(result == (.lift, .lifted))
        #expect(asked == 1)
        #expect(link.calls.contains("lift") && !link.calls.contains("cover"))

        for (auth, expected) in [(IntentAuthResult.cancelled, IntentFailure.authCancelled), (.failed, .authFailed)] {
            let (runner, link, _, _) = Self.rig { link, clock in
                link.connect(.bluetooth, phase: .closed)
                link.lastStateAt = clock.now
            }
            let result = await runner.toggle { auth }
            #expect(result == (.lift, .failed(expected)))
            #expect(!link.calls.contains("lift"))
            #expect(IntentCopy.text(kind: result.action, outcome: result.outcome).hasPrefix("没撤下："))
        }
    }

    @Test
    func toggleDoesNotTrustAStaleStateFromBeforeItConnected() async {
        // 没连着时手机上那份是上次记下的：要电脑这次新报的
        let (silent, silentLink, _, _) = Self.rig { link, clock in
            link.snapshot.phase = .closed
            link.lastStateAt = clock.now.addingTimeInterval(-600)
            clock.events.append((1, { [unowned link] in link.connect(.bluetooth, phase: .closed) }))
        }
        let unknown = await silent.toggle { .passed }
        #expect(unknown == (.toggle, .failed(.stateUnknown)))
        #expect(silentLink.calls.contains("requestState"))
        #expect(!silentLink.calls.contains("lift") && !silentLink.calls.contains("cover"))
        #expect(IntentCopy.text(kind: unknown.action, outcome: unknown.outcome) == "幕布没动：电脑没说现在盖着没盖。")

        // 电脑新报来「开着」：盖上
        let (fresh, freshLink, _, _) = Self.rig { link, clock in
            link.snapshot.phase = .closed
            link.lastStateAt = clock.now.addingTimeInterval(-600)
            link.stateAfterRequest = .open
            clock.events.append((1, { [unowned link] in link.connect(.bluetooth, phase: .closed) }))
        }
        #expect(await fresh.toggle { .passed } == (.cover, .covered))
        #expect(freshLink.calls.contains("cover"))
    }

    @Test
    func toggleOnNetworkOnlyCoversButWillNotLift() async {
        var asked = 0
        let (runner, link, _, _) = Self.rig(address: true) { link, clock in
            link.connect(.network, phase: .closed)
            link.lastStateAt = clock.now
        }
        let result = await runner.toggle { asked += 1; return .passed }
        #expect(result == (.lift, .failed(.liftOnNetwork)))
        #expect(asked == 0) // 撤不了就不弹面容
        #expect(!link.calls.contains("lift"))
    }

    @Test
    func toggleFailsHonestlyBeforeKnowingWhatToDo() async {
        let (unpaired, _, _, _) = Self.rig(paired: false)
        #expect(await unpaired.toggle { .passed } == (.toggle, .failed(.notPaired)))
        let (off, _, _, _) = Self.rig { link, _ in link.snapshot.connection = .bluetoothOff }
        let result = await off.toggle { .passed }
        #expect(result == (.toggle, .failed(.bluetoothOff)))
        #expect(IntentCopy.text(kind: result.action, outcome: result.outcome) == "幕布没动：手机的蓝牙关着，打开再试。")
    }

    @Test
    func sessionIsAlwaysEnded() async {
        for kind in CurtainIntentKind.allCases {
            let (runner, link, _, _) = Self.rig(address: true)
            _ = await runner.run(kind) { .failed }
            #expect(link.sessions.count == link.endedSessions, "\(kind)")
        }
    }

    @Test
    func everyRunLogsOneStartAndOneDoneLineWithoutSecrets() async {
        let (runner, _, _, logs) = Self.rig { link, _ in link.connect(.bluetooth) }
        _ = await runner.run(.cover)
        #expect(logs.lines.filter { $0.contains("start") }.count == 1)
        #expect(logs.lines.filter { $0.contains("done") }.count == 1)
        #expect(!logs.lines.contains { $0.contains("lc.") || $0.contains("key") })
    }
}
