// SkyLightSpace.swift —— 把遮罩窗口放进一个层级 400 的私有空间（Space）
//
// macOS 先按空间的绝对层级叠放：桌面 0、锁屏 300、锁屏上的通知 400；同一个空间里才比窗口层级。
// 遮罩只靠窗口层级时，别的工具抬到 Int32.max 就能压住它，锁屏界面本身也在 shielding level
// 之上，只能靠 guardLevel 每秒往上抬。放进 400 的空间后，下面空间里的窗口层级再高也盖不过遮罩
// （实测 2026-10-26，macOS 26：主屏、外接屏都一样，锁屏上也在最上面）。
//
// 做法同 Lakr233/SkyLightWindow（MIT）。私有 API，系统升级可能失效，而且失效时不报错
// （Show / Add 没有返回值）。所以每次放进去后用 SLSCopySpacesForWindows 查一遍，
// 查不到就返回 false，由调用方退回原来的 shielding level + guardLevel。

import AppKit

@MainActor
final class SkyLightSpace {
    /// 锁屏上的通知中心那一层（kSLSSpaceAbsoluteLevelNotificationCenterAtScreenLock）
    static let absoluteLevel: Int32 = 400
    /// SkyLight 符号不全时为 nil
    static let shared = SkyLightSpace()

    private typealias FMain = @convention(c) () -> Int32
    private typealias FCreate = @convention(c) (Int32, Int32, UnsafeRawPointer?) -> UInt64
    private typealias FSetLevel = @convention(c) (Int32, UInt64, Int32) -> Void
    private typealias FShow = @convention(c) (Int32, CFArray) -> Void
    private typealias FAdd = @convention(c) (Int32, UInt64, CFArray, Int32) -> Void
    private typealias FCopySpaces = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

    /// 加窗口时从哪些空间移出：当前 + 其他 + 用户空间（同 SkyLightWindow）
    private static let allSpaces: Int32 = 7
    /// 查窗口在哪些空间。实测掩码 7 和单独任何一位都查不到自建的空间，0xFFFF 才查得到
    private static let lookupMask: Int32 = 0xFFFF

    private let cid: Int32
    private let create: FCreate
    private let setLevel: FSetLevel
    private let show: FShow
    private let add: FAdd
    private let copySpaces: FCopySpaces
    /// 第一次用到时才建；0 = 还没建
    private var sid: UInt64 = 0

    private init?() {
        guard let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW)
        else { NSLog("SkyLightSpace: 加载 SkyLight 失败"); return nil }
        func sym<T>(_ name: String, _: T.Type) -> T? { dlsym(h, name).map { unsafeBitCast($0, to: T.self) } }
        guard let main = sym("SLSMainConnectionID", FMain.self),
              let create = sym("SLSSpaceCreate", FCreate.self),
              let setLevel = sym("SLSSpaceSetAbsoluteLevel", FSetLevel.self),
              let show = sym("SLSShowSpaces", FShow.self),
              let add = sym("SLSSpaceAddWindowsAndRemoveFromSpaces", FAdd.self),
              let copySpaces = sym("SLSCopySpacesForWindows", FCopySpaces.self)
        else { NSLog("SkyLightSpace: SkyLight 符号不全"); return nil }
        cid = main()
        self.create = create
        self.setLevel = setLevel
        self.show = show
        self.add = add
        self.copySpaces = copySpaces
    }

    /// 把窗口移进空间。全部确认进去了才返回 true
    func adopt(_ windows: [NSWindow]) -> Bool {
        guard !windows.isEmpty else { return false }
        if sid == 0 {
            sid = create(cid, 1, nil)
            guard sid != 0 else { NSLog("SkyLightSpace: SLSSpaceCreate 返回 0"); return false }
            setLevel(cid, sid, Self.absoluteLevel)
            show(cid, [NSNumber(value: sid)] as CFArray)
            NSLog("SkyLightSpace: 建好空间 %llu（层级 %d）", sid, Self.absoluteLevel)
        }
        add(cid, sid, windows.map { NSNumber(value: $0.windowNumber) } as CFArray, Self.allSpaces)
        let ok = holds(windows)
        if !ok { NSLog("SkyLightSpace: 窗口没进空间 %llu", sid) }
        return ok
    }

    /// 这些窗口是不是都在空间里
    func holds(_ windows: [NSWindow]) -> Bool {
        guard sid != 0, !windows.isEmpty else { return false }
        return windows.allSatisfy { w in
            let ids = copySpaces(cid, Self.lookupMask, [NSNumber(value: w.windowNumber)] as CFArray)?
                .takeRetainedValue() as? [NSNumber] ?? []
            return ids.contains { $0.uint64Value == sid }
        }
    }
}
