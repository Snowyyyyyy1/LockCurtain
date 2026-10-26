// PowerGuard.swift —— 离开模式下防休眠、压低亮度
//
// 只在离开模式生效。真实锁屏时遮罩会一直盖着，那时防休眠会让锁屏过夜的 Mac 永远不睡。
//
// 两个用户设置（菜单「设置」，存 UserDefaults）：
//   awayKeepDisplayOn  屏幕常亮（默认开）。关掉则只防系统休眠、允许熄屏；
//                      熄屏后如果系统设置了「立即要求密码」，会话会被锁上
//   awayDimBrightness  亮度调到最低（默认关）。走 DisplayServices 私有 API，
//                      实测只有内置屏支持（外接屏返回 1000），不支持的屏跳过；
//                      撤遮罩时恢复原亮度。进程被 kill -9 时来不及恢复，需手动调回

import AppKit
import IOKit.pwr_mgt

enum AwaySettings {
    static var keepDisplayOn: Bool { UserDefaults.standard.object(forKey: PrefKey.awayKeepDisplayOn) as? Bool ?? true }
    static var dimBrightness: Bool { UserDefaults.standard.bool(forKey: PrefKey.awayDimBrightness) }
}

@MainActor
final class PowerGuard {
    private var engaged = false
    private var assertion: IOPMAssertionID = 0
    private var savedBrightness: [CGDirectDisplayID: Float] = [:]

    func engage() {
        guard !engaged else { return }
        engaged = true

        let type = AwaySettings.keepDisplayOn ? kIOPMAssertionTypePreventUserIdleDisplaySleep
                                              : kIOPMAssertionTypePreventUserIdleSystemSleep
        let r = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                            "LockCurtain 离开模式" as CFString, &assertion)
        if r != kIOReturnSuccess { assertion = 0 }
        NSLog("PowerGuard: %@ -> %d", type, r)

        if AwaySettings.dimBrightness { dim() }
    }

    func release() {
        guard engaged else { return }
        engaged = false
        if assertion != 0 { IOPMAssertionRelease(assertion); assertion = 0 }
        restoreBrightness()
    }

    // MARK: - 亮度
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static func symbol<T>(_ name: String, as: T.Type) -> T? {
        guard let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW),
              let s = dlsym(h, name) else { return nil }
        return unsafeBitCast(s, to: T.self)
    }

    private func dim() {
        guard let get = Self.symbol("DisplayServicesGetBrightness", as: GetFn.self),
              let set = Self.symbol("DisplayServicesSetBrightness", as: SetFn.self) else {
            NSLog("PowerGuard: DisplayServices 不可用，跳过调暗")
            return
        }
        for id in NSScreen.screens.map(\.displayID) {
            var b: Float = 0
            guard get(id, &b) == 0 else { continue }
            savedBrightness[id] = b
            NSLog("PowerGuard: display %u brightness %.2f -> 0, set=%d", id, b, set(id, 0))
        }
    }

    private func restoreBrightness() {
        defer { savedBrightness.removeAll() }
        guard !savedBrightness.isEmpty,
              let set = Self.symbol("DisplayServicesSetBrightness", as: SetFn.self) else { return }
        for (id, b) in savedBrightness {
            NSLog("PowerGuard: display %u brightness -> %.2f, set=%d", id, b, set(id, b))
        }
    }
}
