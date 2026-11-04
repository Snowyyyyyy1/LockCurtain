// CurtainIntents.swift —— 快捷指令 / Siri / 聚焦 / 操作按钮 里的四个动作
//
// 名字和 App 里的说法一样；不出现「遮罩」。真正的活全在 CurtainIntentCore.swift（IntentCurtainRunner）：
// 成功只在电脑签名回答之后；没做成就抛错（快捷指令里显示成失败，后面的步骤不会当成功接着跑），错误那句就是 IntentCopy 里的话。
// 标 COPY-TODO 的是还没经文案确认的字。

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
    // COPY-TODO 描述（文案还没写，先不放）：static let description = IntentDescription("…")
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

/// 保持唤醒的几项就是 App 里菜单的那几项（KeepAwakeChoice）
extension KeepAwakeChoice: AppEnum {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "时长" // COPY-TODO 参数名还没定
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

    @Parameter(title: "时长", default: .always) // COPY-TODO 参数名还没定
    var duration: KeepAwakeChoice

    init() {}
    init(duration: KeepAwakeChoice) { self.duration = duration }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try finish(.keepAwake, await IntentCurtainRunner.live.run(.keepAwake, choice: duration))
    }
}

struct CurtainShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CoverCurtainIntent(),
            phrases: [
                "用 \(.applicationName) 盖上幕布", // COPY-TODO
                "\(.applicationName) 盖上幕布", // COPY-TODO
            ],
            shortTitle: "盖上幕布",
            systemImageName: "curtains.closed"
        )
        AppShortcut(
            intent: LiftCurtainIntent(),
            phrases: [
                "用 \(.applicationName) 撤下幕布", // COPY-TODO
                "\(.applicationName) 撤下幕布", // COPY-TODO
            ],
            shortTitle: "撤下幕布",
            systemImageName: "curtains.open"
        )
        AppShortcut(
            intent: PreviewCurtainIntent(),
            phrases: [
                "用 \(.applicationName) 预览幕布", // COPY-TODO
            ],
            shortTitle: "预览幕布",
            systemImageName: "eye"
        )
        AppShortcut(
            intent: KeepAwakeIntent(),
            phrases: [
                "用 \(.applicationName) 保持唤醒", // COPY-TODO
            ],
            shortTitle: "保持唤醒",
            systemImageName: "cup.and.saucer"
        )
    }
}
