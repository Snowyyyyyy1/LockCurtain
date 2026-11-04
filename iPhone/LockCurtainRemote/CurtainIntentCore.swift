// CurtainIntentCore.swift —— 快捷指令 / Siri / 聚焦 / 操作按钮 的四个动作背后的逻辑（不含 AppIntents，测试里原样跑）
//
//   IntentPlan           纯规则：走哪条路、什么时候放弃、撤下要满足什么、电脑的回答 → 结果
//   IntentCopy           结果 → 一句话。成功只在电脑签名回答之后；失败绝不会是成功那句
//   IntentCurtainRunner  真正去做：拿到和 App 同一个蓝牙连接，等一条能用的路，发命令，等电脑签名的回答，收拾干净
//
// App 被划掉时系统为快捷指令把进程拉起来（没有界面）：手机是蓝牙外设，只有电脑来连，所以这里先让连接广播，
// 最多等 pathWait 秒让电脑连回来；存了网络地址的，同时马上开网络（后台也开，不等 5 秒），谁先通用谁，蓝牙通了网络让位。
// 跑完把这次为了快捷指令开的网络关掉（App 在前台就照 App 自己的规矩留着）。
// 撤下幕布只认蓝牙；预览幕布也只认蓝牙（不在网络白名单里）。

import Foundation
import LocalAuthentication
import OSLog
import UIKit

// MARK: - 种类和结果

enum CurtainIntentKind: String, CaseIterable, Sendable {
    case cover
    case lift
    case preview
    case keepAwake

    /// 只能走蓝牙（撤下要电脑量近不近；预览不在网络白名单里）
    var needsBluetooth: Bool { self == .lift || self == .preview }
}

/// 「预览幕布」发出去之后电脑的回答
enum PreviewOutcome: Equatable, Sendable {
    /// 电脑签名收下了（电脑不为预览报状态，所以只能说到「收到」）
    case received
    case timedOut
    case refused
    case unavailable
}

/// 验证面容 / 密码的结果
enum IntentAuthResult: Equatable, Sendable {
    case passed
    case cancelled
    case failed
}

enum IntentFailure: Equatable, Sendable, CaseIterable {
    case notPaired
    case bluetoothOff
    /// 等了一阵，蓝牙和网络都没通
    case noReach
    /// 撤下：只有网络通着
    case liftOnNetwork
    /// 预览：只有网络通着
    case previewOnNetwork
    case phoneLocked
    case authCancelled
    case authFailed
    case tooFar
    case alreadyUncovered
    /// 命令发了，电脑没有（签名）回答
    case noAnswer
    /// 撤下：手机上没有新的幕布状态，不知道幕布现在是不是盖着
    case stateUnknown
    case missingPermission
    case refused
    /// 保持唤醒：5 秒没签收
    case notDelivered
}

enum IntentOutcome: Equatable, Sendable {
    case covered
    case lifted
    case previewed
    /// state = 电脑随后报来的保持唤醒状态（没等到就是 nil，那时只凭电脑签收）
    case keepAwakeSet(KeepAwakeChoice, state: KeepAwakeState?)
    case failed(IntentFailure)

    var isSuccess: Bool {
        if case .failed = self { return false }
        return true
    }
}

// MARK: - 纯规则

enum IntentPlan {
    /// 等一条能用的路，最多这么久（系统给一个快捷指令大约 30 秒，后面还要留给命令和电脑的回答）
    static let pathWait: TimeInterval = 20
    /// 只能走蓝牙的动作，网络通着了、蓝牙还没来：再等这么久就说「走网络不行」
    static let bleOnlyNetworkGrace: TimeInterval = 6
    /// 蓝牙刚起来时状态还没报：「蓝牙关了」要等这么久才算数
    static let bluetoothSettle: TimeInterval = 1.5
    /// 撤下前，电脑的幕布状态不是盖着：要一份新的，最多等这么久
    static let stateWait: TimeInterval = 3
    static let pollInterval: TimeInterval = 0.25

    /// 链接此刻的事实（从 snapshot 和存着的设置里来）
    struct Facts: Equatable, Sendable {
        var paired: Bool
        var hasNetworkAddress: Bool
        var connection: CurtainConnection
        /// 已连上时走哪条路；没连上是 nil
        var path: LinkPath?
    }

    enum Gate: Equatable, Sendable {
        case ready(LinkPath)
        case wait
        case fail(IntentFailure)
    }

    static func facts(from snapshot: CurtainSnapshot, paired: Bool, hasNetworkAddress: Bool) -> Facts {
        Facts(paired: paired, hasNetworkAddress: hasNetworkAddress, connection: snapshot.connection,
              path: snapshot.connection == .connected ? snapshot.path : nil)
    }

    /// 现在能不能发、该不该继续等、还是该放弃。elapsed = 从开始等路起过了多久
    static func gate(kind: CurtainIntentKind, facts: Facts, elapsed: TimeInterval) -> Gate {
        guard facts.paired else { return .fail(.notPaired) }
        switch facts.path {
        case .bluetooth?:
            return .ready(.bluetooth)
        case .network? where !kind.needsBluetooth:
            return .ready(.network)
        default:
            break
        }
        let onlyNetwork: IntentFailure = kind == .lift ? .liftOnNetwork : .previewOnNetwork
        if kind.needsBluetooth {
            // 蓝牙关着：不用等了（网络帮不上）
            if facts.connection == .bluetoothOff, elapsed >= bluetoothSettle { return .fail(.bluetoothOff) }
            // 只有网络通着，等够了蓝牙还没来：如实说走网络不行
            if facts.path == .network, elapsed >= bleOnlyNetworkGrace { return .fail(onlyNetwork) }
        } else if facts.connection == .bluetoothOff, !facts.hasNetworkAddress, elapsed >= bluetoothSettle {
            return .fail(.bluetoothOff)
        }
        if elapsed >= pathWait {
            if facts.path == .network { return .fail(onlyNetwork) }
            return .fail(.noReach)
        }
        return .wait
    }

    /// 撤下发出去之前手机这边要满足的（验证面容 / 密码另算）：解锁着；路是蓝牙
    static func liftPreconditionFailure(phoneUnlocked: Bool, path: LinkPath?) -> IntentFailure? {
        if !phoneUnlocked { return .phoneLocked }
        if path != .bluetooth { return .liftOnNetwork }
        return nil
    }

    // 电脑的回答 → 结果

    static func outcome(cover: CoverOutcome) -> IntentOutcome {
        switch cover {
        case .covered: .covered
        case .timedOut: .failed(.noAnswer)
        case .missingPermission: .failed(.missingPermission)
        case .unavailable: .failed(.noReach)
        }
    }

    static func outcome(lift: LiftOutcome) -> IntentOutcome {
        switch lift {
        case .lifted: .lifted
        case .tooFar: .failed(.tooFar)
        case .notCovered: .failed(.alreadyUncovered)
        case .refused: .failed(.refused)
        case .timedOut: .failed(.noAnswer)
        case .unavailable: .failed(.noReach)
        }
    }

    static func outcome(preview: PreviewOutcome) -> IntentOutcome {
        switch preview {
        case .received: .previewed
        case .timedOut: .failed(.noAnswer)
        case .refused: .failed(.refused)
        case .unavailable: .failed(.previewOnNetwork)
        }
    }

    static func outcome(keepAwakeAcked: Bool, choice: KeepAwakeChoice, reported: KeepAwakeState?, now: Date) -> IntentOutcome {
        guard keepAwakeAcked else { return .failed(.notDelivered) }
        let matching = reported.flatMap { reportMatches(choice, $0, now: now) ? $0 : nil }
        return .keepAwakeSet(choice, state: matching)
    }

    /// 电脑报来的保持唤醒状态，是不是刚才选的那一项的样子
    static func reportMatches(_ choice: KeepAwakeChoice, _ state: KeepAwakeState, now: Date) -> Bool {
        switch (choice, state) {
        case (.off, .off), (.always, .always): true
        case (.oneHour, .timed(let end)), (.twoHours, .timed(let end)), (.fiveHours, .timed(let end)): end > now
        default: false
        }
    }
}

// MARK: - 说的话

/// 每句都是电脑真的说过什么之后才说。// COPY-TODO = 新写的，等文案确认；「现有」= 一字不差取自 App 里已有的句子
enum IntentCopy {
    /// 保持唤醒那几项在 App 里的字（HomeView 的菜单一字不差）
    static func label(_ choice: KeepAwakeChoice) -> String {
        switch choice {
        case .off: "关掉"
        case .oneHour: "1 小时"
        case .twoHours: "2 小时"
        case .fiveHours: "5 小时"
        case .always: "一直"
        }
    }

    static func text(kind: CurtainIntentKind, outcome: IntentOutcome, now: Date = Date()) -> String {
        switch outcome {
        case .covered:
            return "幕布已盖上" // 现有：演示里的「幕布已盖上」
        case .lifted:
            return "幕布撤下了" // 现有：演示里的「幕布撤下了」
        case .previewed:
            return "电脑收到了预览。" // COPY-TODO 预览成功：电脑不为预览报状态，只能说「收到」
        case .keepAwakeSet(let choice, let state):
            let shown = state.map { AppModel.keepAwakeText($0, now: now) } ?? (choice == .off ? "关" : label(choice))
            return "保持唤醒：\(shown)" // COPY-TODO 句式；值取自电脑报来的状态（和 App 里那一行一样），没等到状态时用菜单里的字
        case .failed(let failure):
            return text(kind: kind, failure: failure)
        }
    }

    static func text(kind: CurtainIntentKind, failure: IntentFailure) -> String {
        switch failure {
        // 现有的句子：自己就说清了没做成，原样用
        case .liftOnNetwork: return "走网络时不能撤下。撤下要手机在电脑旁边。"
        case .alreadyUncovered: return "幕布已经是撤下的了。"
        case .missingPermission: return "没能盖上：电脑上还缺一个权限。"
        case .notDelivered: return "没送到，再试一次"
        case .tooFar where kind == .lift: return "离这台电脑太远，走近再试。"
        case .noAnswer: return kind == .lift ? "电脑没有回应，幕布还盖着。" : "电脑没有回应，状态没变。"
        case .refused where kind == .lift: return "这次没撤下来，再按一次。"
        default: break
        }
        // 新写的：前面加一个「没……」说明哪件事没成
        let reason: String
        switch failure {
        case .notPaired: reason = "还没和电脑配对。" // COPY-TODO
        case .bluetoothOff: reason = "蓝牙关了。打开 iPhone 的蓝牙再试。" // COPY-TODO（后半句取自「蓝牙关了」时主屏的说明）
        case .noReach: reason = "没连上这台电脑。电脑上开着 LockCurtain、人也在附近就行。" // COPY-TODO（后半句取自主屏「等这台电脑来连」的说明）
        case .previewOnNetwork: reason = "走网络时不能预览。预览要手机在电脑旁边。" // COPY-TODO（仿「走网络时不能撤下」）
        case .phoneLocked: reason = "手机锁着，解锁再试。" // COPY-TODO
        case .authCancelled: reason = "没有验证面容。" // COPY-TODO
        case .authFailed: reason = "面容或密码没验证通过。" // COPY-TODO
        case .tooFar: reason = "离这台电脑太远，走近再试。"
        case .refused: reason = "电脑没有接受，再试一次。" // COPY-TODO
        case .stateUnknown: reason = "电脑没有回应，状态没变。" // COPY-TODO（句子取自 App 里的「电脑没有回应，状态没变。」，前面加「没撤下：」）
        case .liftOnNetwork, .alreadyUncovered, .missingPermission, .notDelivered, .noAnswer: reason = ""
        }
        return prefix(kind) + reason
    }

    private static func prefix(_ kind: CurtainIntentKind) -> String {
        switch kind {
        case .cover: "没盖上：" // COPY-TODO（仿「没能盖上：」）
        case .lift: "没撤下：" // COPY-TODO
        case .preview: "没能预览：" // COPY-TODO
        case .keepAwake: "没改成：" // COPY-TODO
        }
    }
}

// MARK: - 跑起来

/// 快捷指令要用的那一份连接（BLECurtainLink 实现；测试里是假的）
@MainActor
protocol CurtainIntentLink: AnyObject {
    var snapshot: CurtainSnapshot { get }
    var lastStateAt: Date? { get }
    var lastAwakeAt: Date? { get }
    func activate()
    func beginIntentSession(allowNetwork: Bool) -> UUID
    func endIntentSession(_ token: UUID)
    func cover() async -> CoverOutcome
    func liftNow() async -> LiftOutcome
    func previewNow() async -> PreviewOutcome
    func setKeepAwake(_ choice: KeepAwakeChoice) async -> Bool
    func requestState()
}

extension BLECurtainLink: CurtainIntentLink {}

@MainActor
struct IntentEnvironment {
    var isPaired: () -> Bool
    var hasNetworkAddress: () -> Bool
    var makeLink: () -> any CurtainIntentLink
    var isPhoneUnlocked: () -> Bool
    var now: () -> Date
    var sleep: (TimeInterval) async -> Void
    var log: (String) -> Void

    static let live = IntentEnvironment(
        isPaired: {
            // 删了重装：钥匙串里残留的东西要先清（AppModel.init 也会做；这里可能比它先到）
            PhoneKeychain.wipeIfFreshInstall()
            return PhoneKeychain.loadLink() != nil
        },
        hasNetworkAddress: { NetworkAddress.load() != nil },
        makeLink: {
            let paired = PhoneKeychain.loadLink() != nil
            return CurtainLinkHub.obtain(paired: paired, macName: paired ? UserDefaults.standard.string(forKey: "lc.macName") : nil)
        },
        isPhoneUnlocked: { UIApplication.shared.isProtectedDataAvailable },
        now: { Date() },
        sleep: { try? await Task.sleep(for: .seconds($0)) },
        log: { Logger(subsystem: "LockCurtainRemote", category: "link").info("\($0, privacy: .public)") }
    )
}

@MainActor
final class IntentCurtainRunner {
    static let live = IntentCurtainRunner(environment: .live)

    private let env: IntentEnvironment

    init(environment: IntentEnvironment) {
        env = environment
    }

    private enum PathResult {
        case ready(LinkPath)
        case failed(IntentFailure)
    }

    /// 做一件事，返回电脑真的回答了什么。`authenticate` 只有撤下用（每次都要，和 App 里的开关无关）
    func run(_ kind: CurtainIntentKind, choice: KeepAwakeChoice = .always,
             authenticate: (() async -> IntentAuthResult)? = nil) async -> IntentOutcome {
        let started = env.now()
        env.log("intent \(kind.rawValue) start, address saved \(env.hasNetworkAddress())")
        let outcome = await perform(kind, choice: choice, authenticate: authenticate)
        let seconds = env.now().timeIntervalSince(started)
        env.log("intent \(kind.rawValue) done: \(Self.describe(outcome)) after \(String(format: "%.1f", seconds)) s")
        return outcome
    }

    private func perform(_ kind: CurtainIntentKind, choice: KeepAwakeChoice,
                         authenticate: (() async -> IntentAuthResult)?) async -> IntentOutcome {
        guard env.isPaired() else { return .failed(.notPaired) }

        let link = env.makeLink()
        // 撤下 / 预览也让网络开着（只为了知道「只有网络」好如实回答，不会走网络发）
        let token = link.beginIntentSession(allowNetwork: env.hasNetworkAddress())
        defer { link.endIntentSession(token) }
        link.activate()

        if kind == .lift {
            // 面容 / 密码先过（连接在这段时间里照常往回连），没过什么都不做
            switch await (authenticate?() ?? .failed) {
            case .passed: break
            case .cancelled: return .failed(.authCancelled)
            case .failed: return .failed(.authFailed)
            }
            if !env.isPhoneUnlocked() { return .failed(.phoneLocked) }
        }

        let path: LinkPath
        switch await waitForPath(kind, link: link) {
        case .failed(let failure): return .failed(failure)
        case .ready(let ready): path = ready
        }
        env.log("intent \(kind.rawValue) path: \(path == .bluetooth ? "bluetooth" : "network")")

        switch kind {
        case .cover:
            return await retryOnPathSwitch(link: link, first: path) { IntentPlan.outcome(cover: await link.cover()) }
        case .keepAwake:
            return await retryOnPathSwitch(link: link, first: path) {
                let sentAt = self.env.now()
                let acked = await link.setKeepAwake(choice)
                let reported = acked ? await self.awaitKeepAwakeReport(link, for: choice, after: sentAt) : nil
                return IntentPlan.outcome(keepAwakeAcked: acked, choice: choice, reported: reported, now: self.env.now())
            }
        case .preview:
            return await retryOnPathSwitch(link: link, first: path) {
                let result = await link.previewNow()
                // 「用不了」：只有网络通着才是「走网络不行」，一条路都没有就是没连上
                if result == .unavailable, link.snapshot.path != .network { return .failed(.noReach) }
                return IntentPlan.outcome(preview: result)
            }
        case .lift:
            return await lift(link)
        }
    }

    private func waitForPath(_ kind: CurtainIntentKind, link: any CurtainIntentLink) async -> PathResult {
        let start = env.now()
        while true {
            let facts = IntentPlan.facts(from: link.snapshot, paired: env.isPaired(), hasNetworkAddress: env.hasNetworkAddress())
            switch IntentPlan.gate(kind: kind, facts: facts, elapsed: env.now().timeIntervalSince(start)) {
            case .ready(let path): return .ready(path)
            case .fail(let failure): return .failed(failure)
            case .wait:
                if Task.isCancelled { return .failed(.noReach) }
                await env.sleep(IntentPlan.pollInterval)
            }
        }
    }

    /// 蓝牙和网络一起在等时，发出去之后蓝牙才通，网络被让位关掉，等着的收据就没了：
    /// 失败而且路换了，在新的路上再发一次（盖上 / 保持唤醒 / 预览发两次结果一样）
    private func retryOnPathSwitch(link: any CurtainIntentLink, first: LinkPath,
                                   _ attempt: () async -> IntentOutcome) async -> IntentOutcome {
        let outcome = await attempt()
        guard case .failed(let failure) = outcome,
              [.noAnswer, .notDelivered, .noReach, .previewOnNetwork].contains(failure) else { return outcome }
        let facts = IntentPlan.facts(from: link.snapshot, paired: true, hasNetworkAddress: false)
        guard let now = facts.path, now != first else { return outcome }
        env.log("intent path changed to \(now == .bluetooth ? "bluetooth" : "network"); sending again")
        return await attempt()
    }

    /// 签收之后，电脑马上还会报一条保持唤醒状态；等一小会儿，有就按它说
    /// 只认发命令之后新到的（手机上留着的旧状态不算：那会把上一次的「还剩 20 分」当成这次的结果）
    private func awaitKeepAwakeReport(_ link: any CurtainIntentLink, for choice: KeepAwakeChoice, after sentAt: Date) async -> KeepAwakeState? {
        var waited: TimeInterval = 0
        while waited < 1.5 {
            if let state = link.snapshot.keepAwake, (link.lastAwakeAt ?? .distantPast) >= sentAt,
               IntentPlan.reportMatches(choice, state, now: env.now()) { return state }
            await env.sleep(0.1)
            waited += 0.1
        }
        return nil
    }

    private func lift(_ link: any CurtainIntentLink) async -> IntentOutcome {
        // 幕布不是盖着：要电脑新报一份状态再说「已经撤下了」，不凭手机上旧的
        if link.snapshot.phase != .closed {
            let asked = env.now()
            link.requestState()
            var waited: TimeInterval = 0
            while waited < IntentPlan.stateWait, link.snapshot.phase != .closed {
                await env.sleep(IntentPlan.pollInterval)
                waited += IntentPlan.pollInterval
            }
            if link.snapshot.phase != .closed {
                let fresh = (link.lastStateAt ?? .distantPast) >= asked
                return .failed(fresh ? .alreadyUncovered : .stateUnknown)
            }
        }
        // 等路的这段时间里蓝牙可能又掉了：发之前再看一次
        let facts = IntentPlan.facts(from: link.snapshot, paired: true, hasNetworkAddress: false)
        if let failure = IntentPlan.liftPreconditionFailure(phoneUnlocked: env.isPhoneUnlocked(), path: facts.path) {
            return .failed(failure)
        }
        return IntentPlan.outcome(lift: await link.liftNow())
    }

    private static func describe(_ outcome: IntentOutcome) -> String {
        switch outcome {
        case .failed(let failure): "failed (\(failure))"
        case .keepAwakeSet(let choice, let state): "keep-awake \(choice.rawValue), computer reported \(state == nil ? "nothing yet" : "state")"
        default: "\(outcome)"
        }
    }
}

// MARK: - 验证面容 / 密码

/// 每次都弹：新的 LAContext，不复用上一次的结果，手机已经解锁着也一样
enum OwnerAuthenticator {
    @MainActor
    static func authenticate(reason: String = "撤下这台电脑的幕布") async -> IntentAuthResult {
        // 快捷指令把 App 带到前台的过程中还不是 active，那时弹面容会被系统取消：等一等（最多 3 秒）
        var waited = 0.0
        while UIApplication.shared.applicationState != .active, waited < 3 {
            try? await Task.sleep(for: .milliseconds(100))
            waited += 0.1
        }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return .failed }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) ? .passed : .failed
        } catch let error as LAError {
            switch error.code {
            case .userCancel, .systemCancel, .appCancel: return .cancelled
            default: return .failed
            }
        } catch {
            return .failed
        }
    }
}
