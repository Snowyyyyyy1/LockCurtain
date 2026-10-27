// Updater.swift —— 自动更新（Sparkle 2）
//
// 只有发布版才打开：build.sh 拿到 EdDSA 公钥才写进 Info.plist（SUPublicEDKey），
// 自己从源码编的版本没有公钥，不检查更新。appcast 挂在 GitHub Release 上，release.sh 生成。
// 每天查一次；有新版本弹 Sparkle 的窗口，用户点了才下载安装（SUAllowsAutomaticUpdates = NO）。
//
// 遮罩盖着时不打扰：定时检查查到新版本先记下，遮罩撤掉再弹；
// 正在装的更新要重启时遮罩刚好盖着（离开模式），也等撤掉再重启，绝不为了更新撤遮罩。
//
// 没带 Sparkle 编译时（比如只跑 swiftc -typecheck Sources/*.swift）整个更新器是空的。

import AppKit
#if canImport(Sparkle)
import Sparkle
#endif

@MainActor
final class Updater: NSObject {
    static let shared = Updater()

    /// 遮罩是否盖着，AppDelegate 接上 OverlayController
    var curtainShowing: () -> Bool = { false }

    #if canImport(Sparkle)
    private var controller: SPUStandardUpdaterController?
    /// 定时检查查到了新版本，但当时遮罩盖着没弹窗
    private var pendingReminder = false
    /// 遮罩盖着时推迟的重启
    private var postponedRelaunch: (() -> Void)?

    /// 这个版本有没有自动更新（有公钥才有）
    var isAvailable: Bool { controller != nil }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    func start() {
        guard Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil else {
            NSLog("updater: 没有 EdDSA 公钥，不检查更新")
            return
        }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
    }

    func checkForUpdates() { controller?.checkForUpdates(nil) }

    /// 遮罩撤掉时调用：补上推迟的重启或弹窗
    func curtainHidden() {
        if let relaunch = postponedRelaunch {
            postponedRelaunch = nil
            NSLog("updater: 遮罩已撤，继续重启安装")
            relaunch()
        } else if pendingReminder {
            pendingReminder = false
            controller?.checkForUpdates(nil)
        }
    }
    #else
    var isAvailable: Bool { false }
    var automaticallyChecks: Bool { get { false } set {} }
    func start() {}
    func checkForUpdates() {}
    func curtainHidden() {}
    #endif
}

#if canImport(Sparkle)
extension Updater: SPUUpdaterDelegate {
    nonisolated func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                             untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        MainActor.assumeIsolated {
            guard curtainShowing() else { return false }
            NSLog("updater: 遮罩盖着，%@ 等撤掉再重启", item.displayVersionString)
            postponedRelaunch = installHandler
            return true
        }
    }
}

extension Updater: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                                          andInImmediateFocus immediateFocus: Bool) -> Bool {
        MainActor.assumeIsolated { !curtainShowing() }
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                               state: SPUUserUpdateState) {
        MainActor.assumeIsolated {
            guard !handleShowingUpdate else { return }
            NSLog("updater: 查到 %@，遮罩盖着，撤掉后再提示", update.displayVersionString)
            pendingReminder = true
        }
    }
}
#endif
