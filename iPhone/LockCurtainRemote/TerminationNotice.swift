import Foundation
import OSLog
import UIKit
import UserNotifications

/// 用户在多任务里把 App 划掉：手机就不再广播，电脑那边连不上、幕布也撤不了。
/// 退出前留一条本地通知，告诉用户要在电脑上撤、点开就能接回。
///
/// 权限：配对成功后先要一个「临时」授权（不弹框，通知静静进通知中心）；
/// 真被划掉过一次以后，下次打开再正式问一次提醒 + 声音（只问一次）。
///
/// 只有被划掉 / 系统正常结束 App 时 `applicationWillTerminate` 才会来；
/// 在后台被系统回收、崩溃都不会走到这里。要真机试。
enum TerminationNotice {
    private static let log = Logger(subsystem: "LockCurtainRemote", category: "link")

    private enum Keys {
        /// 上次是被划掉的：下次打开时正式要一次通知权限
        static let didGetSwipedAway = "lc.didGetSwipedAway"
        /// 正式要过一次了，不再问
        static let didAskFullAuthorization = "lc.didAskFullNotificationAuth"
    }

    private static let identifier = "lc.terminated"

    /// 最近一次读到的授权状态（退出时来不及异步去问，所以平时先存着）
    nonisolated(unsafe) private static var cachedStatus: UNAuthorizationStatus = .notDetermined

    /// 启动 / 回前台：刷新授权状态；撤掉上次留下的那条通知（已经打开了，不用再提醒）
    static func refresh() {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.getNotificationSettings { settings in
            let status = settings.authorizationStatus
            DispatchQueue.main.async { cachedStatus = status }
        }
    }

    /// 配对成功：先要临时授权（不弹框）
    static func requestProvisional() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .provisional]) { granted, error in
            if let error {
                log.error("term: provisional request failed: \(error.localizedDescription, privacy: .public)")
            } else {
                log.info("term: provisional \(granted ? "granted" : "denied", privacy: .public)")
            }
            refresh()
        }
    }

    /// 正式那次请求还没回来（回前台好几次也只发一次）
    @MainActor private static var fullRequestInFlight = false

    /// 场景变成前台（App 打开 / 回前台）时：上次被划掉过、还没正式问过 → 正式问一次提醒 + 声音。
    /// 不在 AppModel.init 里问：那时还没有窗口，弹框可能出不来、却已经记成问过了。
    /// 「问过了」等请求回来才记（没出来 / 出错就下次再问）
    @MainActor
    static func askAfterSwipeIfNeeded(paired: Bool) {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Keys.didGetSwipedAway) else { return }
        guard paired, !defaults.bool(forKey: Keys.didAskFullAuthorization) else {
            defaults.removeObject(forKey: Keys.didGetSwipedAway)
            return
        }
        guard !fullRequestInFlight else { return }
        fullRequestInFlight = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                log.error("term: full request failed: \(error.localizedDescription, privacy: .public)")
            } else {
                log.info("term: full authorization \(granted ? "granted" : "denied", privacy: .public)")
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    fullRequestInFlight = false
                    if error == nil {
                        UserDefaults.standard.set(true, forKey: Keys.didAskFullAuthorization)
                        UserDefaults.standard.removeObject(forKey: Keys.didGetSwipedAway)
                    }
                }
            }
            refresh()
        }
    }

    /// `applicationWillTerminate`：配过对、不在演示才发。最多等 0.5 秒让系统收下这条通知。
    @MainActor
    static func applicationWillTerminate(paired: Bool, demo: Bool) {
        guard paired, !demo else { return }
        UserDefaults.standard.set(true, forKey: Keys.didGetSwipedAway)

        switch cachedStatus {
        case .authorized, .provisional, .ephemeral:
            break
        default:
            log.info("term: no-permission")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "LockCurtain 已退出"
        content.body = "手机现在管不了幕布，要在电脑上撤。点开这里，几秒就能接回。"
        content.sound = .default
        // 立刻送达（trigger 为 nil）
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)

        let done = DispatchSemaphore(value: 0)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                log.error("term: notify failed: \(error.localizedDescription, privacy: .public)")
            } else {
                log.info("term: notify scheduled")
            }
            done.signal()
        }
        if done.wait(timeout: .now() + 0.5) == .timedOut {
            log.error("term: notify failed: timed out after 0.5 s")
        }
    }
}

/// 拿 `applicationWillTerminate`；App 变成前台（包括刚打开）时看要不要正式问通知权限
final class LockCurtainAppDelegate: NSObject, UIApplicationDelegate {
    private var activeObserver: NSObjectProtocol?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        TerminationNotice.refresh()
        activeObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                guard let model = AppModel.current, !model.isPreviewFixture else { return }
                TerminationNotice.askAfterSwipeIfNeeded(paired: model.paired && !model.demoMode)
            }
        }
        return true
    }

    func applicationWillTerminate(_ application: UIApplication) {
        MainActor.assumeIsolated {
            guard let model = AppModel.current else { return }
            TerminationNotice.applicationWillTerminate(paired: model.paired, demo: model.demoMode)
        }
    }
}
