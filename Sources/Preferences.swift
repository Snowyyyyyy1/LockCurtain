// Preferences.swift —— 外观和行为设置（UserDefaults）
//
// 设置窗口里用 @AppStorage 直接读写同一批 key；AppDelegate 监听 UserDefaults 变化，
// 把 Dock / 菜单栏图标的开关即时应用到运行中的 App。

import Foundation

enum PrefKey {
    static let showDockIcon = "showDockIcon"
    static let showMenuBarIcon = "showMenuBarIcon"
    static let curtainOnLock = "curtainOnLock"
    static let curtainArt = "curtainArt"
    static let awayKeepDisplayOn = "awayKeepDisplayOn"
    static let awayDimBrightness = "awayDimBrightness"
    /// 开着的保持唤醒会话，下次启动接着开（KeepAwake.swift）
    static let keepAwake = "keepAwake"
    /// 「自定义图片」图案用的图，缩到 512px 以内存成 PNG/JPEG；没有就用账户头像
    static let curtainImage = "curtainImage"
    /// 自定义图片裁成圆形（默认开）
    static let curtainImageRound = "curtainImageRound"
}

enum Prefs {
    /// 默认不在 Dock 显示，和原来的菜单栏小工具一致
    static var showDockIcon: Bool { UserDefaults.standard.showDockIcon }
    static var showMenuBarIcon: Bool { UserDefaults.standard.showMenuBarIcon }
    /// 真实锁屏时显示遮罩（默认开，原来是固定开着）
    static var curtainOnLock: Bool { UserDefaults.standard.object(forKey: PrefKey.curtainOnLock) as? Bool ?? true }
    /// 遮罩中间的图案（默认机械眼）
    static var curtainArt: CurtainArt {
        UserDefaults.standard.string(forKey: PrefKey.curtainArt).flatMap(CurtainArt.init(rawValue:)) ?? .mechEye
    }
}

/// KVO 用：属性名必须和 key 一致
extension UserDefaults {
    @objc dynamic var showDockIcon: Bool { bool(forKey: PrefKey.showDockIcon) }
    @objc dynamic var showMenuBarIcon: Bool { object(forKey: PrefKey.showMenuBarIcon) as? Bool ?? true }
}
