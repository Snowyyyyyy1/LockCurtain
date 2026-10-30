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
    /// 离开模式回来时怎么撤遮罩（AwayUnlock）
    static let awayUnlock = "awayUnlock"
    /// 开着的保持唤醒会话，下次启动接着开（KeepAwake.swift）
    static let keepAwake = "keepAwake"
    /// 「自定义图片」图案用的图，缩到 512px 以内存成 PNG/JPEG；没有就用账户头像
    static let curtainImage = "curtainImage"
    /// 自定义图片裁成圆形（默认开）
    static let curtainImageRound = "curtainImageRound"
    /// 遮罩背景（CurtainBackground.swift），默认当前壁纸
    static let curtainBackground = "curtainBackground"
    /// 遮罩文字：图案下面的标题和提示，空字符串 = 不显示这一行
    static let curtainTitle = "curtainTitle"
    static let curtainSubtitle = "curtainSubtitle"
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
    /// 遮罩背景（默认当前壁纸）
    static var curtainBackground: CurtainBackground {
        UserDefaults.standard.string(forKey: PrefKey.curtainBackground).flatMap(CurtainBackground.init(rawValue:)) ?? .wallpaper
    }
    /// 离开模式回来时怎么撤（默认先锁屏）
    static var awayUnlock: AwayUnlock {
        UserDefaults.standard.string(forKey: PrefKey.awayUnlock).flatMap(AwayUnlock.init(rawValue:)) ?? .lockScreen
    }
    static let defaultCurtainTitle = "LockCurtain is Using Your Mac"
    static let defaultCurtainSubtitle = "Press any key or click to unlock"
    /// 没设置过用默认文案；设成空（或只有空白）就不显示
    static var curtainTitle: String { UserDefaults.standard.string(forKey: PrefKey.curtainTitle) ?? defaultCurtainTitle }
    static var curtainSubtitle: String { UserDefaults.standard.string(forKey: PrefKey.curtainSubtitle) ?? defaultCurtainSubtitle }
}

/// 离开模式下真人碰了键鼠之后怎么撤遮罩
enum AwayUnlock: String {
    case lockScreen     // 先锁屏，等锁屏界面出来再撤（默认）
    case systemAuth     // 遮罩下方弹出解锁面板（Mac 密码或触控 ID），通过就直接撤，不锁屏
}

/// KVO 用：属性名必须和 key 一致
extension UserDefaults {
    @objc dynamic var showDockIcon: Bool { bool(forKey: PrefKey.showDockIcon) }
    @objc dynamic var showMenuBarIcon: Bool { object(forKey: PrefKey.showMenuBarIcon) as? Bool ?? true }
}
