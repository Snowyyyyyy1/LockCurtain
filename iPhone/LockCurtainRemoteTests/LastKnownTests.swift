import Foundation
import Testing
@testable import LockCurtain

/// 「上次的样子」：怎么存、怎么说、什么时候绝不能当现在；盖上幕布按钮的几种状态；冷启动不等 bleGrace；时间戳日志
struct LastKnownTests {
    private static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }

    /// 2026-11-04 15:30:00 UTC
    private static let now = Date(timeIntervalSince1970: 1_793_806_200)

    private static func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }

    private static func freshStore() -> LastKnownStore {
        let suite = "lc.test.lastknown.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return LastKnownStore(defaults: defaults)
    }

    // MARK: - 相对时间

    @Test
    func relativeBuckets() {
        let c = Self.calendar
        func b(_ s: TimeInterval) -> LastKnownPresentation.Bucket {
            LastKnownPresentation.bucket(from: Self.ago(s), now: Self.now, calendar: c)
        }
        #expect(b(0) == .justNow)
        #expect(b(59) == .justNow)
        #expect(b(60) == .minutes(1))
        #expect(b(59 * 60 + 59) == .minutes(59))
        #expect(b(3600) == .hours(1))
        #expect(b(2 * 3600 + 12 * 60) == .hours(2))   // 不写「2 小时 12 分钟前」
        #expect(b(23 * 3600 + 59 * 60) == .hours(23))
        // 15:30 的「昨天」：24 小时之前、00:00 之后的前一天
        #expect(b(24 * 3600) == .yesterday)
        #expect(b(30 * 3600) == .yesterday)          // 昨天 09:30
        // 前天 → M 月 D 日
        #expect(b(40 * 3600) == .date(month: 11, day: 2))
        #expect(b(10 * 24 * 3600) == .date(month: 10, day: 25))
    }

    @Test
    func clockGoingBackwardsNeverShowsNegative() {
        let future = Self.now.addingTimeInterval(3600)
        #expect(LastKnownPresentation.bucket(from: future, now: Self.now, calendar: Self.calendar) == .justNow)
    }

    @Test
    func relativeWords() {
        typealias P = LastKnownPresentation
        #expect(P.relativeText(.justNow) == "刚刚")
        #expect(P.relativeText(.minutes(5)) == "5 分钟前")
        #expect(P.relativeText(.hours(2)) == "2 小时前")
        #expect(P.relativeText(.yesterday) == "昨天")
        #expect(P.relativeText(.date(month: 11, day: 2)) == "11 月 2 日")
    }

    @Test
    func connectedLine() {
        let known = LastKnownState(connectedAt: Self.ago(2 * 3600 + 5), phase: .closed, phaseAt: Self.ago(2 * 3600 + 5))
        #expect(LastKnownPresentation.connectedLine(known, now: Self.now, calendar: Self.calendar) == "上次连上：2 小时前")
    }

    // MARK: - 存取与节流

    @Test
    func storeRoundTripAndClear() {
        let store = Self.freshStore()
        #expect(store.load() == nil)
        store.noteConnected(at: Self.ago(100))
        #expect(store.load()?.connectedAt == Self.ago(100))
        #expect(store.load()?.phase == nil)
        store.notePhase(closed: true, at: Self.ago(50))
        #expect(store.load()?.phase == .closed)
        #expect(store.load()?.phaseAt == Self.ago(50))
        store.clear()
        #expect(store.load() == nil)
    }

    @Test
    func touchIsThrottledButDisconnectAndConnectAlwaysWrite() {
        let store = Self.freshStore()
        store.noteConnected(at: Self.ago(1000))
        #expect(!store.touch(at: Self.ago(1000 - 30)))                       // 30 秒内：不写
        #expect(store.load()?.connectedAt == Self.ago(1000))
        #expect(store.touch(at: Self.ago(1000 - 61)))                        // 超过 60 秒：写
        #expect(store.load()?.connectedAt == Self.ago(1000 - 61))
        store.noteDisconnected(at: Self.ago(900))                            // 断开：总是写
        #expect(store.load()?.connectedAt == Self.ago(900))
        store.noteConnected(at: Self.ago(10))                                // 连上：总是写
        #expect(store.load()?.connectedAt == Self.ago(10))
        // 时钟往回拨：不被节流卡住
        #expect(store.touch(at: Self.ago(500)))
    }

    @Test
    func phaseWritesImmediatelyWhenChangedAndIsThrottledWhenSame() {
        let store = Self.freshStore()
        #expect(store.notePhase(closed: false, at: Self.ago(300)))
        #expect(!store.notePhase(closed: false, at: Self.ago(300 - 20)))     // 没变、20 秒内：不写
        #expect(store.notePhase(closed: true, at: Self.ago(300 - 21)))       // 变了：立刻写
        #expect(store.load()?.phase == .closed)
        #expect(store.notePhase(closed: true, at: Self.ago(300 - 21 - 61)))  // 没变但超过 60 秒：刷新时刻
        #expect(store.load()?.phaseAt == Self.ago(300 - 21 - 61))
    }

    @Test
    func phaseOnlyWithoutConnectedAtIsNotLoadable() {
        let store = Self.freshStore()
        store.defaults.set("closed", forKey: LastKnownStore.phaseKey)
        store.defaults.set(1.0, forKey: LastKnownStore.phaseAtKey)
        #expect(store.load() == nil)
    }

    // MARK: - 「这台电脑」那一行

    @Test
    func macRowWithLastKnownReplacesBareWaiting() {
        let known = LastKnownState(connectedAt: Self.ago(2 * 3600), phase: .closed, phaseAt: Self.ago(2 * 3600))
        let row = LastKnownPresentation.macRow(state: .waiting, lastKnown: known, now: Self.now, calendar: Self.calendar)
        #expect(row.value == "没连上")
        #expect(row.value != AppModel.UnlinkedMacState.waiting.value)
        #expect(row.lastConnectedLine == "上次连上：2 小时前")
        #expect(row.showsSpinner)   // 手机确实还在等
    }

    @Test
    func macRowWithoutLastKnownIsUnchanged() {
        for state in [AppModel.UnlinkedMacState.waiting, .reconnecting, .notYet, .stillTrying, .stillTryingLong, .bluetoothOff] {
            let row = LastKnownPresentation.macRow(state: state, lastKnown: nil, now: Self.now)
            #expect(row.value == state.value)
            #expect(row.showsSpinner == state.showsSpinner)
            #expect(row.lastConnectedLine == nil)
        }
    }

    @Test
    func macRowKeepsLastConnectedInEveryStageButBluetoothOff() {
        let known = LastKnownState(connectedAt: Self.ago(90), phase: nil, phaseAt: nil)
        for state in [AppModel.UnlinkedMacState.waiting, .reconnecting, .notYet, .stillTrying, .stillTryingLong] {
            let row = LastKnownPresentation.macRow(state: state, lastKnown: known, now: Self.now, calendar: Self.calendar)
            #expect(row.lastConnectedLine == "上次连上：1 分钟前")
            // 没连上就不能说已连上（已连接 是禁用词）
            #expect(!row.value.contains("已连上") && !row.value.contains("已连接"))
            #expect(!(row.lastConnectedLine ?? "").contains("已连接"))
        }
        let off = LastKnownPresentation.macRow(state: .bluetoothOff, lastKnown: known, now: Self.now)
        #expect(off.value == "蓝牙关了")
        #expect(off.lastConnectedLine == nil)
    }

    // MARK: - 「幕布」那一行：旧状态绝不当现在

    @Test
    func staleStateIsNeverShownAsLive() {
        let known = LastKnownState(connectedAt: Self.ago(3600), phase: .closed, phaseAt: Self.ago(3600))
        for connection in [CurtainConnection.notConnected, .bluetoothOff] {
            let row = LastKnownPresentation.curtainRow(
                connection: connection, paired: true, demo: false, lastKnown: known,
                liveText: "已盖上", liveVoice: "已盖上", disconnectedVoice: "没连上", now: Self.now, calendar: Self.calendar)
            #expect(row.isLastKnown)
            #expect(row.text.hasPrefix(LastKnownPresentation.lastKnownMarker))
            #expect(row.text != "已盖上")                    // 不能和现在的值一样
            #expect(row.voice.contains("没连上"))
            #expect(row.voice.contains("1 小时前"))
            #expect(!row.text.contains("已连上"))
        }
    }

    @Test
    func connectedCurtainRowIsLiveAndIgnoresLastKnown() {
        let known = LastKnownState(connectedAt: Self.ago(3600), phase: .closed, phaseAt: Self.ago(3600))
        let row = LastKnownPresentation.curtainRow(
            connection: .connected, paired: true, demo: false, lastKnown: known,
            liveText: "没盖上", liveVoice: "没盖上", disconnectedVoice: "没连上", now: Self.now)
        #expect(row == .init(text: "没盖上", isLastKnown: false, voice: "没盖上"))
    }

    @Test
    func curtainRowShowsDashWithoutAnythingToSay() {
        let known = LastKnownState(connectedAt: Self.ago(60), phase: nil, phaseAt: nil)
        let full = LastKnownState(connectedAt: Self.ago(60), phase: .open, phaseAt: Self.ago(60))
        func row(_ connection: CurtainConnection, paired: Bool = true, demo: Bool = false, _ k: LastKnownState?) -> LastKnownPresentation.CurtainRow {
            LastKnownPresentation.curtainRow(connection: connection, paired: paired, demo: demo, lastKnown: k,
                                             liveText: "x", liveVoice: "x", disconnectedVoice: "没连上", now: Self.now)
        }
        #expect(row(.notConnected, nil).text == "—")
        #expect(row(.notConnected, known).text == "—")             // 连上过但没收到过幕布状态
        #expect(row(.notPaired, paired: false, full).text == "—")   // 没配对：不展示别人的上次
        #expect(row(.notConnected, demo: true, full).text == "—")
        #expect(!row(.notConnected, nil).isLastKnown)
    }

    @Test
    func lastKnownOnlyShownWhilePairedAndNotLive() {
        typealias P = LastKnownPresentation
        #expect(P.isShown(paired: true, demo: false, connection: .notConnected))
        #expect(P.isShown(paired: true, demo: false, connection: .bluetoothOff))
        #expect(!P.isShown(paired: true, demo: false, connection: .connected))
        #expect(!P.isShown(paired: false, demo: false, connection: .notPaired))
        #expect(!P.isShown(paired: true, demo: true, connection: .notConnected))
    }

    // MARK: - 盖上幕布按钮

    @Test
    func coverButtonStates() {
        typealias C = CoverButtonPolicy
        func s(_ connection: CurtainConnection, paired: Bool = true, demo: Bool = false, pending: Bool = false,
               queued: Bool = false, address: Bool = false) -> C.State {
            C.state(paired: paired, demo: demo, connection: connection, isPending: pending, isQueued: queued,
                    hasNetworkAddress: address)
        }
        // t=0：配过对、还没连上 → 看得见、按得下
        #expect(s(.notConnected) == .coverWhenLinked)
        #expect(s(.notConnected, queued: true) == .waitingForLink)
        #expect(s(.connected) == .cover)
        #expect(s(.connected, pending: true) == .covering)
        // 没配对由「去配对」管
        #expect(s(.notPaired, paired: false) == .hidden)
        // 蓝牙关着：有网络地址才有指望
        #expect(s(.bluetoothOff) == .hidden)
        #expect(s(.bluetoothOff, address: true) == .coverWhenLinked)
        #expect(s(.bluetoothOff, queued: true, address: true) == .waitingForLink)
        // 演示里没有「等连上」
        #expect(s(.notConnected, demo: true) == .hidden)
        #expect(s(.connected, paired: false, demo: true) == .cover)
    }

    @Test
    func pressActions() {
        typealias C = CoverButtonPolicy
        #expect(C.pressAction(.cover) == .sendNow)
        #expect(C.pressAction(.coverWhenLinked) == .queue)
        #expect(C.pressAction(.waitingForLink) == .ignore)   // 已经在等：再按不叠加，取消另有按钮
        #expect(C.pressAction(.covering) == .ignore)
        #expect(C.pressAction(.hidden) == .ignore)
    }

    @Test
    func queuedCoverSendsOnlyWhenReallyConnected() {
        typealias C = CoverButtonPolicy
        #expect(C.shouldSendOnLinkUp(isQueued: true, connection: .connected))
        for connection in [CurtainConnection.notConnected, .bluetoothOff, .notPaired] {
            #expect(!C.shouldSendOnLinkUp(isQueued: true, connection: connection))
        }
        #expect(!C.shouldSendOnLinkUp(isQueued: false, connection: .connected))   // 没按过就不会自己发
    }

    @Test
    func queueExpiresAtTwentySeconds() {
        typealias C = CoverButtonPolicy
        #expect(C.queueTimeout == 20)
        let t0 = Self.now
        #expect(!C.hasExpired(queuedAt: t0, now: t0.addingTimeInterval(19.9)))
        #expect(C.hasExpired(queuedAt: t0, now: t0.addingTimeInterval(20)))
    }

    // MARK: - 冷启动：蓝牙和网络一起赛

    @Test
    func coldStartSkipsBleGrace() {
        typealias P = NetworkLinkPlan
        #expect(P.grace(connectedSinceLaunch: false) == 0)
        #expect(P.grace(connectedSinceLaunch: true) == P.bleGrace)
        // 存了地址、配着对、前台、蓝牙没通：冷启动第 0 秒就开网络
        #expect(P.decide(paired: true, hasAddress: true, foreground: true, bleReady: false, waited: 0, running: false,
                         grace: P.grace(connectedSinceLaunch: false)) == .run)
        // 连上过以后（蓝牙掉了）：照旧先等 5 秒
        #expect(P.decide(paired: true, hasAddress: true, foreground: true, bleReady: false, waited: 0, running: false,
                         grace: P.grace(connectedSinceLaunch: true)) == .wait(5))
        // 不给 grace（旧调用）= 原来的 5 秒
        #expect(P.decide(paired: true, hasAddress: true, foreground: true, bleReady: false, waited: 2, running: false) == .wait(3))
    }

    @Test
    func raceStillStopsNetworkOnceBluetoothIsUp() {
        typealias P = NetworkLinkPlan
        // 蓝牙通了：不管 grace 是几，网络都让位
        #expect(P.decide(paired: true, hasAddress: true, foreground: true, bleReady: true, waited: 0, running: true, grace: 0) == .stop)
        // 没地址、不在前台、没配对：冷启动也不开网络
        #expect(P.decide(paired: true, hasAddress: false, foreground: true, bleReady: false, waited: 0, running: false, grace: 0) == .stop)
        #expect(P.decide(paired: true, hasAddress: true, foreground: false, bleReady: false, waited: 0, running: false, grace: 0) == .stop)
        #expect(P.decide(paired: false, hasAddress: true, foreground: true, bleReady: false, waited: 0, running: false, grace: 0) == .stop)
        // 蓝牙赢了以后撤下只能蓝牙；网络赢了撤下仍然不行
        #expect(P.path(bleReady: false, networkReady: true) == .network)
        #expect(!P.canLift(path: .network))
        #expect(P.path(bleReady: true, networkReady: true) == .bluetooth)
        #expect(P.canLift(path: .bluetooth))
    }

    // MARK: - 时间戳日志

    @Test
    func timingMarksOncePerEventAndSummarisesFirstReady() {
        let origin = Self.now
        var log = LinkTimingLog(origin: origin)
        #expect(log.summary == nil)
        #expect(log.mark(.appInit, at: origin.addingTimeInterval(0.250)) == 250)
        #expect(log.mark(.activate, at: origin.addingTimeInterval(0.300)) == 300)
        #expect(log.mark(.activate, at: origin.addingTimeInterval(5)) == nil)         // 只记第一次
        #expect(log.mark(.poweredOn, at: origin.addingTimeInterval(0.412)) == 412)
        #expect(log.mark(.serviceAdded, at: origin.addingTimeInterval(0.500)) == 500)
        #expect(log.mark(.advertisingStarted, at: origin.addingTimeInterval(0.505)) == 505)
        #expect(log.mark(.firstSubscribe, at: origin.addingTimeInterval(1.200)) == 1200)
        #expect(log.summary == nil)
        #expect(log.mark(.linkReady, at: origin.addingTimeInterval(1.3)) == 1300)
        #expect(log.summary == "cold start → ready 1300 ms (bluetooth)")
        // 之后网络才好：汇总不变（第一个算）
        _ = log.mark(.networkReady, at: origin.addingTimeInterval(2))
        #expect(log.summary == "cold start → ready 1300 ms (bluetooth)")
        _ = log.mark(.coverButtonShown, at: origin.addingTimeInterval(0.4))
        #expect(log.detail.contains("coverButtonShown 400"))
        #expect(log.detail.hasPrefix("cold start → ready 1300 ms (bluetooth) | appInit 250"))
    }

    @Test
    func timingSummaryViaNetworkWhenNetworkWins() {
        var log = LinkTimingLog(origin: Self.now)
        _ = log.mark(.networkReady, at: Self.now.addingTimeInterval(0.9))
        _ = log.mark(.linkReady, at: Self.now.addingTimeInterval(1.5))
        #expect(log.summary == "cold start → ready 900 ms (network)")
    }

    @Test
    func timingNeverNegative() {
        #expect(LinkTimingLog.milliseconds(from: Self.now, to: Self.now.addingTimeInterval(-3)) == 0)
    }

    @Test
    func processStartIsInThePast() throws {
        let start = try #require(LinkTiming.processStart())
        #expect(start <= Date())
        #expect(Date().timeIntervalSince(start) < 3600)
    }
}
