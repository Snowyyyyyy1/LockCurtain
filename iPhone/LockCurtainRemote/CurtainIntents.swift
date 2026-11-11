// CurtainIntents.swift —— 快捷指令 / Siri / 聚焦 / 操作按钮 里的四个动作
//
// 名字和 App 里的说法一样；不出现「遮罩」。真正的活全在 CurtainIntentCore.swift（IntentCurtainRunner）：
// 成功只在电脑签名回答之后；没做成就抛错（快捷指令里显示成失败，后面的步骤不会当成功接着跑），错误那句就是 IntentCopy 里的话。
// 字全部来自 copy v15.9 §20（description / Siri 说法 / 参数名）和 v15.10 §20.2（参数名「保持唤醒」）；结果那几句在 CurtainIntentCore.swift 的 IntentCopy。

import AppIntents

/// 没做成：话来自 IntentCopy
struct CurtainIntentError: Error, CustomLocalizedStringResourceConvertible {
    let message: String
    var localizedStringResource: LocalizedStringResource { LocalizedStringResource(stringLiteral: message) }
}

@MainActor
private func finish(_ kind: CurtainIntentKind, _ outcome: IntentOutcome) throws -> some IntentResult & ProvidesDialog {
    let text = IntentCopy.text(kind: kind, outcome: outcome)
    guard outcome.isSuccess else { throw CurtainIntentError(message: text) }
    return .result(dialog: IntentDialog(LocalizedStringResource(stringLiteral: text)))
}

/// 盖上幕布：不弹任何东西，蓝牙或网络都行
struct CoverCurtainIntent: AppIntent {
    static let title: LocalizedStringResource = "盖上幕布"
    static let description = IntentDescription("把这台电脑的屏幕盖住。")
    static let supportedModes: IntentModes = .background
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try finish(.cover, await IntentCurtainRunner.live.run(.cover))
    }
}

/// 撤下幕布：每次都要面容 / 密码（不看 App 里「撤下前验证面容」的开关），手机解锁着、蓝牙连着、在电脑旁边才撤
struct LiftCurtainIntent: AppIntent {
    static let title: LocalizedStringResource = "撤下幕布"
    static let description = IntentDescription("把幕布撤下来。每次要先过面容或密码。")
    /// 验证面容 / 密码要界面（LAContext 在没有界面的后台进程里不让弹），所以这一个把 App 带到前台
    static let supportedModes: IntentModes = .foreground
    /// 系统先要求在这台手机上验证本人（锁屏时要解锁）；解锁着时系统不会再问，所以 perform 里每次另外验证一次
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = await IntentCurtainRunner.live.run(.lift) { await OwnerAuthenticator.authenticate() }
        return try finish(.lift, outcome)
    }
}

/// 预览幕布：已有的签名命令 preview，只走蓝牙
struct PreviewCurtainIntent: AppIntent {
    static let title: LocalizedStringResource = "预览幕布"
    static let description = IntentDescription("盖上看一眼，不用真的进离开模式。")
    static let supportedModes: IntentModes = .background
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try finish(.preview, await IntentCurtainRunner.live.run(.preview))
    }
}

/// 切换幕布：盖着就撤下，没盖就盖上。盖上那边和「盖上幕布」一样在后台；
/// 撤下那边要面容 / 密码，LAContext 在后台弹不出来，所以到那一步才把 App 带到前台（.foreground(.dynamic)）
struct ToggleCurtainIntent: AppIntent {
    static let title: LocalizedStringResource = "切换幕布"
    static let description = IntentDescription("盖着就撤下，没盖就盖上。撤下时要先过面容或密码。")
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]
    /// 盖上不用验证；撤下在 perform 里每次另外验证，和「撤下幕布」一样
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = await IntentCurtainRunner.live.toggle {
            do {
                try await continueInForeground(alwaysConfirm: false)
            } catch {
                return .cancelled
            }
            return await OwnerAuthenticator.authenticate()
        }
        return try finish(result.action, result.outcome)
    }
}

/// 保持唤醒的几项就是 App 里菜单的那几项（KeepAwakeChoice）
extension KeepAwakeChoice: AppEnum {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "保持唤醒"
    static let caseDisplayRepresentations: [KeepAwakeChoice: DisplayRepresentation] = [
        .off: "关掉",
        .oneHour: "1 小时",
        .twoHours: "2 小时",
        .fiveHours: "5 小时",
        .always: "一直",
    ]
}

/// 保持唤醒：蓝牙或网络都行，不弹任何东西
struct KeepAwakeIntent: AppIntent {
    static let title: LocalizedStringResource = "保持唤醒"
    static let description = IntentDescription("让电脑暂时不睡。")
    static let supportedModes: IntentModes = .background
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @Parameter(title: "保持唤醒", default: .always)
    var duration: KeepAwakeChoice

    init() {}
    init(duration: KeepAwakeChoice) { self.duration = duration }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try finish(.keepAwake, await IntentCurtainRunner.live.run(.keepAwake, choice: duration))
    }
}

/// Siri 说法（copy v15.9 §20.3）。代码里写的是开发语言（en）的说法，中文那几句（用 LockCurtain 盖上幕布 …）在 AppShortcuts.xcstrings 的 zh-Hans 里，
/// 键是这里的英文句子、App 名占位写成 ${applicationName}（苹果 App Shortcuts 本地化的写法）。英文句子是中文的直译，只作 en 的兜底。
/// 下面这段旧说明照旧：苹果要求每条短语都带 App 名（\(.applicationName)），所以屏幕上显示的是「用 LockCurtain 盖上幕布」；
/// 中文里 App 名两边各留一个空格，和 Camo 写的一致。幕布只配盖上 / 撤下，不加「打开 / 关闭幕布」这类说法
struct CurtainShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CoverCurtainIntent(),
            phrases: [
                "Cover the curtain with \(.applicationName)",
                "Cover the screen with \(.applicationName)",
            ],
            shortTitle: "盖上幕布",
            systemImageName: "curtains.closed"
        )
        AppShortcut(
            intent: LiftCurtainIntent(),
            phrases: [
                "Lift the curtain with \(.applicationName)",
            ],
            shortTitle: "撤下幕布",
            systemImageName: "curtains.open"
        )
        AppShortcut(
            intent: ToggleCurtainIntent(),
            phrases: [
                "Toggle the curtain with \(.applicationName)",
            ],
            shortTitle: "切换幕布",
            systemImageName: "switch.2"
        )
        AppShortcut(
            intent: PreviewCurtainIntent(),
            phrases: [
                "Preview the curtain with \(.applicationName)",
                "See what covering looks like with \(.applicationName)",
            ],
            shortTitle: "预览幕布",
            systemImageName: "eye"
        )
        AppShortcut(
            intent: KeepAwakeIntent(),
            phrases: [
                "Keep awake with \(.applicationName)",
                "Keep the computer from sleeping with \(.applicationName)",
            ],
            shortTitle: "保持唤醒",
            systemImageName: "cup.and.saucer"
        )
    }
}
