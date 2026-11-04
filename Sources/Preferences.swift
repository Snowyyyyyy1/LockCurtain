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
    /// 让手机走网络连这台电脑（PhonePairing 的 TCP 监听）。默认关
    static let phoneOverNetwork = PhonePairing.networkDefaultsKey
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
    /// 手机能不能走网络连这台电脑（默认关，用户在「设置 › 手机」里打开）。起 / 停监听走 PhonePairing.setNetworkEnabled
    static var phoneOverNetwork: Bool { UserDefaults.standard.bool(forKey: PrefKey.phoneOverNetwork) }
    static let defaultCurtainTitle = "LockCurtain 正在使用这台电脑"
    /// 老版本的英文默认值：存着的还是它，就当没改过（跟着新的默认走）
    static let legacyDefaultTitle = "LockCurtain is Using Your Mac"
    static let legacyDefaultSubtitle = "Press any key or click to unlock"
    /// 没设置过用默认文案；设成空（或只有空白）就不显示
    static var curtainTitle: String {
        let s = UserDefaults.standard.string(forKey: PrefKey.curtainTitle)
        return s == nil || s == legacyDefaultTitle ? defaultCurtainTitle : s!
    }
    /// 用户自己写过的提示；nil = 没写过，跟着「回来时」变（D6）
    static var customCurtainSubtitle: String? {
        let s = UserDefaults.standard.string(forKey: PrefKey.curtainSubtitle)
        return s == legacyDefaultSubtitle ? nil : s
    }
    /// 幕布上那行提示的默认值，跟着这次怎么撤变（Camo §16.6）
    static func defaultCurtainSubtitle(for mode: CurtainMode, unlock: AwayUnlock) -> String {
        switch mode {
        case .preview: return "按任意键关掉预览"
        case .away: return unlock == .systemAuth ? "按任意键，验证后回来" : "按任意键，先锁屏"
        // COPY-TODO: 系统锁屏上那层幕布没有给定的提示（按键露出的是系统锁屏），先不显示
        case .lock: return ""
        }
    }
    static func curtainSubtitle(for mode: CurtainMode, unlock: AwayUnlock) -> String {
        customCurtainSubtitle ?? defaultCurtainSubtitle(for: mode, unlock: unlock)
    }
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
