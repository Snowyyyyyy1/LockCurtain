// KeepAwake.swift —— 保持唤醒：不盖遮罩，只拦着系统不睡，相当于 Amphetamine 的会话
//
// 和离开模式（PowerGuard）是两回事：离开模式盖遮罩、你解锁回来就结束；这里不管锁屏解锁，
// 一直开到你点停止、时间到了或者跟着的那个 app 退出。
// 只用 PreventUserIdleSystemSleep：屏幕照样按系统设置熄灭，合盖照样睡。
//
// 开着的会话存进 UserDefaults，LockCurtain 下次启动时接着开（对应 Amphetamine 的「启动时开始会话」）：
// 一直的照开；定时的没到点才开；跟着 app 的按 bundle ID 找，那个 app 还开着才开。

import AppKit
import IOKit.pwr_mgt

@MainActor
final class KeepAwake: ObservableObject {
    enum Until: Equatable {
        case forever
        case date(Date)
        /// 这个 app 退出就结束
        case appQuits(pid_t, name: String)
    }

    /// nil = 没开
    @Published private(set) var until: Until? { didSet { save(); onChange?() } }
    var onChange: (() -> Void)?
    var isOn: Bool { until != nil }

    private var assertion: IOPMAssertionID = 0
    private var endTask: Task<Void, Never>?
    /// KVO 不会留住被观察的对象，app 要自己存着
    private var watchedApp: NSRunningApplication?
    private var quitObservation: NSKeyValueObservation?

    func start(_ u: Until) {
        stop()
        var app: NSRunningApplication?
        if case .appQuits(let pid, _) = u {
            app = NSRunningApplication(processIdentifier: pid)
            if app?.isTerminated ?? true { return }
        }
        let r = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                            IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                            "LockCurtain 保持唤醒" as CFString, &assertion)
        NSLog("KeepAwake: %@ -> %d", String(describing: u), r)
        guard r == kIOReturnSuccess else { assertion = 0; return }

        switch u {
        case .forever:
            break
        case .date(let end):
            // Task.sleep 默认按 ContinuousClock 计时，合盖睡着的时间也算；醒来已经过点就马上结束
            endTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(end.timeIntervalSinceNow, 0)))
                if !Task.isCancelled { self?.stop() }
            }
        case .appQuits:
            // 不用 NSWorkspace 的退出通知：实测后台 app（不在 Dock 里的）退出时不发，isTerminated 照样会变
            watchedApp = app
            quitObservation = app?.observe(\.isTerminated) { [weak self] app, _ in
                guard app.isTerminated else { return }
                DispatchQueue.main.async { self?.stop() }
            }
        }
        until = u
    }

    func stop() {
        endTask?.cancel(); endTask = nil
        quitObservation?.invalidate(); quitObservation = nil; watchedApp = nil
        if assertion != 0 { IOPMAssertionRelease(assertion); assertion = 0 }
        if until != nil { until = nil }
    }

    // MARK: - 下次启动时接着开

    /// LockCurtain 退出时不会调 stop，存的会话留到下次启动
    private func save() {
        let d = UserDefaults.standard
        switch until {
        case .forever:
            d.set(["kind": "forever"], forKey: PrefKey.keepAwake)
        case .date(let end):
            d.set(["kind": "date", "end": end], forKey: PrefKey.keepAwake)
        case .appQuits(_, let name):
            // 下次启动 pid 就变了，只能按 bundle ID 找；没有 bundle ID 的不存
            if let b = watchedApp?.bundleIdentifier { d.set(["kind": "app", "bundleID": b, "name": name], forKey: PrefKey.keepAwake) }
            else { d.removeObject(forKey: PrefKey.keepAwake) }
        case nil:
            d.removeObject(forKey: PrefKey.keepAwake)
        }
    }

    func restore() {
        guard let s = UserDefaults.standard.dictionary(forKey: PrefKey.keepAwake) else { return }
        // 先删掉；接得上的话 start 会重新存
        UserDefaults.standard.removeObject(forKey: PrefKey.keepAwake)
        switch s["kind"] as? String {
        case "forever":
            start(.forever)
        case "date":
            if let end = s["end"] as? Date, end > Date() { start(.date(end)) }
        case "app":
            if let b = s["bundleID"] as? String,
               let app = NSRunningApplication.runningApplications(withBundleIdentifier: b).first {
                start(.appQuits(app.processIdentifier, name: s["name"] as? String ?? app.localizedName ?? b))
            }
        default:
            break
        }
        NSLog("KeepAwake: restore %@ -> %@", s as NSDictionary, String(describing: until))
    }
}
