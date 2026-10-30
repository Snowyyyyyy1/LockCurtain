// CurtainInputFilter.swift —— 区分「真人输入」与「程序合成输入」
//
// 判据：kCGEventSourceUnixProcessID (field 41)
//   程序 post 的 CGEvent → field41 = 发起进程 pid
//   硬件 HID 事件         → field41 = 0
//
// 规则（默认「宽松模式」，最大化兼容各类自动化工具）：
//   field41 == 0  → 硬件（真人）→ 关闭遮罩
//   field41 != 0  → 任何进程合成的输入 → 放行，不关遮罩
//
// 宽松模式的好处：pyautogui、cliclick、osascript、Playwright、
// 以及任何第三方自动化工具，只要是通过 CGEvent/AX 发事件，
// 都会被识别为合成输入而放行，不需要为每个工具维护白名单。
//
// 严格模式（设 LOCKCURTAIN_STRICT=1 开启）：
//   field41 != 0 且不在豁免名单 → 视为真人
//   适合「想检测除自己之外的任何程序动了键鼠」的场景。
//
// 豁免名单（严格模式下才生效）：
//   * 可执行文件路径含 agentPathHints 里的片段（常见自动化工具）
//   * 额外 pid：~/Library/Application Support/LockCurtain/exempt-pids.txt（每行一个 pid）
//   * 环境变量 LOCKCURTAIN_EXEMPT_PIDS="123,456"
//
// 用可拦截的 CGEvent tap：判为真人的输入被吞掉，不会落到 agent 正在操作的窗口上；
// 合成输入照常放行。鼠标移动、拖动和触控板手势也吞掉，光标照样会动（那是系统画的），
// 只是下层 app 收不到；只有按键、点击、滚轮触发退出。tap 只在遮罩显示期间存在，撤遮罩即停。

import Foundation
import CoreGraphics
import AppKit

final class CurtainInputFilter {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var onPhysical: (() -> Void)?
    private var onSynthetic: ((pid_t, String) -> Void)?
    /// 解锁面板开着时由 OverlayController 设置：返回 true 的真人输入放行（落到面板上），既不吞也不触发 onPhysical
    var passHuman: ((CGEventType, CGEvent) -> Bool)?

    /// 触控板手势（旋转、缩放、轻扫、智能缩放、用力按压）。CGEventType 里没有，用 NSEvent.EventType 的原始值
    static let gestureTypes: [UInt32] = [18, 19, 20, 29, 30, 31, 32, 34]

    /// 只有这些真输入触发 onPhysical；其余（抬起、移动、拖动、手势、数位板）只吞
    static let triggerTypes: Set<UInt32> = Set([CGEventType.keyDown, .flagsChanged, .leftMouseDown,
                                                .rightMouseDown, .otherMouseDown, .scrollWheel].map(\.rawValue))

    /// 路径里出现这些片段的进程视为 agent，输入放行
    static let agentPathHints = ["CuaDriver", "Cua Spaces", "cua-driver", "cua-spacesd"]

    /// 严格模式：非豁免的合成输入也视为真人
    private let strictMode = ProcessInfo.processInfo.environment["LOCKCURTAIN_STRICT"] == "1"

    private var cachedExempt: Set<pid_t> = []
    private var cacheTime = Date.distantPast

    // MARK: - 豁免判定

    private func isExempt(_ pid: pid_t) -> Bool {
        if Date().timeIntervalSince(cacheTime) > 3 {
            cachedExempt = Self.loadExemptPIDs()
            cacheTime = Date()
        }
        if cachedExempt.contains(pid) { return true }
        return Self.isAgentPid(pid)
    }

    static func isAgentPid(_ pid: pid_t) -> Bool {
        if pid == 0 { return false }
        guard let p = ProcessTable.executablePath(pid) else { return false }
        return agentPathHints.contains { p.contains($0) }
    }

    static func loadExemptPIDs() -> Set<pid_t> {
        var s = Set<pid_t>()
        if let env = ProcessInfo.processInfo.environment["LOCKCURTAIN_EXEMPT_PIDS"] {
            for part in env.split(separator: ",") {
                if let v = pid_t(part.trimmingCharacters(in: .whitespaces)) { s.insert(v) }
            }
        }
        if let txt = try? String(contentsOf: AppPaths.file("exempt-pids.txt"), encoding: .utf8) {
            for line in txt.split(separator: "\n") {
                if let v = pid_t(line.trimmingCharacters(in: .whitespaces)) { s.insert(v) }
            }
        }
        return s
    }

    // MARK: - 生命周期
    func start(onPhysical: @escaping () -> Void,
               onSynthetic: ((pid_t, String) -> Void)? = nil) {
        guard tap == nil else { return }
        self.onPhysical = onPhysical
        self.onSynthetic = onSynthetic
        cachedExempt = Self.loadExemptPIDs()
        cacheTime = Date()

        // 按下类事件 + 滚轮触发 onPhysical；抬起、移动、拖动、手势、数位板只拦截
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged,
                                    .leftMouseDown, .leftMouseUp,
                                    .rightMouseDown, .rightMouseUp,
                                    .otherMouseDown, .otherMouseUp,
                                    .scrollWheel,
                                    .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                                    .tabletPointer, .tabletProximity]
        let mask = (types.map(\.rawValue) + Self.gestureTypes).reduce(CGEventMask(0)) { $0 | (1 << $1) }

        let cb: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<CurtainInputFilter>.fromOpaque(refcon).takeUnretainedValue()

            // 回调超时或用户输入过多时系统会停用 tap，不重新启用的话退出路径就没了
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                NSLog("CurtainInputFilter: tap 被系统停用，重新启用")
                if let t = me.tap { CGEvent.tapEnable(tap: t, enable: true) }
                return Unmanaged.passUnretained(event)
            }

            let srcPID = pid_t(event.getIntegerValueField(.eventSourceUnixProcessID))

            // 硬件输入算真人；严格模式下非豁免进程的合成输入也算
            let human = srcPID == 0 || (me.strictMode && !me.isExempt(srcPID))
            guard human else {
                me.onSynthetic?(srcPID, me.strictMode ? "exempt" : "synthetic")
                return Unmanaged.passUnretained(event)  // 合成输入：放行
            }

            if let pass = me.passHuman, pass(type, event) { return Unmanaged.passUnretained(event) }
            if CurtainInputFilter.triggerTypes.contains(type.rawValue) { me.onPhysical?() }
            return nil                                  // 真人输入：吞掉
        }

        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                        place: .headInsertEventTap,
                                        options: .defaultTap,
                                        eventsOfInterest: mask,
                                        callback: cb,
                                        userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            NSLog("CurtainInputFilter: tapCreate 失败（需要辅助功能权限）")
            return
        }
        tap = t
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        NSLog("CurtainInputFilter started")
    }

    func stop() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil; source = nil
        onPhysical = nil; onSynthetic = nil
        passHuman = nil
    }

    var isRunning: Bool { tap != nil }

    /// tap 已安装且当前处于启用状态，即按键 / 点击退出路径可用
    var isHealthy: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }
}
