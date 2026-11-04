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
    @Published private(set) var until: Until? { didSet { save(); if !quiet { onChange?() } } }
    /// 换时长时先停再开：中间那次「关了」不往外报
    private var quiet = false
    /// 这次是手机开的（设置页详情后面加「· 手机开的」）
    @Published private(set) var fromPhone = false
    /// .date 是「到指定时间…」选的钟点（手机显示「到 18:30」），不是 1/2/5 小时
    @Published private(set) var clockTime = false
    var onChange: (() -> Void)?
    var isOn: Bool { until != nil }

    private var assertion: IOPMAssertionID = 0
    private var endTask: Task<Void, Never>?
    /// KVO 不会留住被观察的对象，app 要自己存着
    private var watchedApp: NSRunningApplication?
    private var quitObservation: NSKeyValueObservation?

    func start(_ u: Until, clockTime: Bool = false, fromPhone: Bool = false) {
        quiet = true
        stop()
        quiet = false
        var app: NSRunningApplication?
        if case .appQuits(let pid, _) = u {
            app = NSRunningApplication(processIdentifier: pid)
            if app?.isTerminated ?? true { onChange?(); return }
        }
        let r = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                            IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                            "LockCurtain 保持唤醒" as CFString, &assertion)
        NSLog("KeepAwake: %@ -> %d", String(describing: u), r)
        guard r == kIOReturnSuccess else {
            assertion = 0
            onChange?()     // 停掉了旧的、新的没开成：照样报一次
            return
        }

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
        self.clockTime = clockTime
        self.fromPhone = fromPhone
        until = u
    }

    /// 手机发来的 awake:off / awake:1h / awake:2h / awake:5h / awake:always；不认识的返回 false
    @discardableResult
    func apply(phoneCommand: String) -> Bool {
        switch phoneCommand {
        case "awake:off": stop()
        case "awake:always": start(.forever, fromPhone: true)
        case "awake:1h", "awake:2h", "awake:5h":
            let h = Double(phoneCommand.dropFirst(6).dropLast()) ?? 1
            start(.date(Date().addingTimeInterval(h * 3600)), fromPhone: true)
        default: return false
        }
        return true
    }

    /// 报给手机的样子（协议 v3 KeepAwakeState）
    var wireState: (mode: PairingCrypto.KeepAwakeMode, endsAt: UInt64, appName: String) {
        switch until {
        case nil: return (.off, 0, "")
        case .forever: return (.always, 0, "")
        case .date(let end): return (clockTime ? .untilTime : .timed, UInt64(max(end.timeIntervalSince1970, 0)), "")
        case .appQuits(_, let name): return (.whileApp, 0, name)
        }
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
            d.set(["kind": "date", "end": end, "clock": clockTime], forKey: PrefKey.keepAwake)
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
            if let end = s["end"] as? Date, end > Date() { start(.date(end), clockTime: s["clock"] as? Bool ?? false) }
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
