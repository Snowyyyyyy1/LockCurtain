// OverlayController.swift —— 遮罩、锁屏感知、退出路径
//
// 设计约束：
//  1. 遮罩窗口放进层级 400 的私有空间（SkyLightSpace），盖住一切；
//     私有 API 失效时退回 level = CGShieldingWindowLevel()+1（2147483629）+ guardLevel。
//     一旦它卡住，用户按什么都没用，只能 kill -9。所以必须有三条退出路径：
//       a) 全局按键监听 → 任意键关闭（对应界面上那句 "Press any key ..."）
//       b) 全局鼠标监听 → 任意点击关闭
//       c) 看门狗 → a/b 不可用连续超过 N 秒就强制关（防止监听失效时锁死）
//  2. 绝不在主线程上同步等待截图结果。SCScreenshotManager 的完成回调
//     需要主线程派发，主线程被阻塞就是永久死锁。全部 async/await。

import AppKit
import ApplicationServices
import CoreGraphics
import SwiftUI

/// CGSSessionScreenIsLocked 不在公开头文件里，只在锁屏时出现
func sessionLocked() -> Bool {
    (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
}

/// 位于 shielding level 之上的窗口。不允许成为 key/main，避免抢走焦点。
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func orderFrontRegardless() { super.orderFrontRegardless() }
}

/// 遮罩为什么显示：决定真人输入之后怎么撤
enum CurtainMode {
    case lock     // 系统真锁屏了，盖在锁屏上；真人输入 → 直接撤，露出系统锁屏
    case preview  // 看效果 / 测试；真人输入 → 直接撤
    case away     // 离开模式：盖在已解锁的桌面上让 agent 干活；真人输入 → 先锁屏再撤
}

@MainActor
final class OverlayController {
    private var windows: [NSWindow] = []
    private var wallpaperLayers: [CGDirectDisplayID: CALayer] = [:]
    /// stealth 模式下补右边缘那 1px 列的窗口图层
    private var edgeLayers: [CGDirectDisplayID: CALayer] = [:]
    /// 当前显示模式，nil = 没显示
    private var mode: CurtainMode? {
        didSet { if mode != oldValue { onModeChange?(mode) } }
    }
    /// 菜单栏图标跟着切换「拉上 / 拉开」
    var onModeChange: ((CurtainMode?) -> Void)?
    /// 刚显示的 1 秒内不认真人输入（点菜单那一下的余波、触控板惯性滚动），但照样吞掉
    private var armedAt = Date.distantPast
    private let power = PowerGuard()
    private let screenCoalescer = ScreenChangeCoalescer()
    private var locking = false
    private var pollTimer: Timer?
    private var lastState = false

    // 退出路径：只认真人输入
    private let inputFilter = CurtainInputFilter()
    private var watchdog: Task<Void, Never>?

    /// stealth：对任何抓屏工具隐形（sharingType=.none + 漏 1 个像素）
    private let stealthEnabled = !CommandLine.arguments.contains("--no-stealth")

    /// 遮罩层级（--level N 可覆盖）
    private var overlayLevel: NSWindow.Level {
        let o = CommandLine.arguments.firstIndex(of: "--level")
            .flatMap { $0 + 1 < CommandLine.arguments.count ? Int(CommandLine.arguments[$0 + 1]) : nil }
        return NSWindow.Level(rawValue: o ?? (Int(CGShieldingWindowLevel()) + 1))
    }
    /// 实际使用的层级。每次 show() 从 overlayLevel 开始，别的工具压上来时由 guardLevel() 抬高
    private var currentLevel = 0
    /// 层级 400 的私有空间，遮罩放进去后普通窗口和锁屏界面都盖不过它。
    /// nil = --no-space 或私有 API 失效，只靠窗口层级 + guardLevel
    private var space = CommandLine.arguments.contains("--no-space") ? nil : SkyLightSpace.shared

    /// 按键 / 点击退出路径不可用时，遮罩最多再保留多久（秒）。超时强制关闭，防止锁死。
    private let maxUnguardedTime: TimeInterval = 120
    /// 看门狗刚锁的屏：这次锁屏不再把遮罩盖回去（退出路径还是坏的），解锁后复位
    private var suppressLockShow = false
    /// 系统锁屏界面（时钟、密码框）已经显示：lockThenHide 锁屏前清零，收到 com.apple.screenLockUIIsShown 置位
    private var lockUIShown = false

    init() {
        // 接拔显示器、改分辨率、外接屏休眠都会改变屏幕布局，遮罩要跟着重建
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildIfShowing() }
        }
    }

    /// 系统会连发好几次通知：合并成一次，布局没变就跳过
    private func rebuildIfShowing() {
        guard mode != nil else { return }
        screenCoalescer.notify(
            layoutProvider: { Self.currentLayout() },
            perform: { [weak self] change in
                guard let self, self.mode != nil else { return }
                let kind: String
                if case .moved = change { kind = "moved" } else { kind = "rebuilt" }
                NSLog("screen layout %@, rebuild windows (%@)", kind, self.screenCoalescer.stats)
                self.rebuildWindows()
            })
    }

    private static func currentLayout() -> ScreenLayout {
        ScreenLayout(displays: NSScreen.screens.map {
            ScreenLayout.Display(id: $0.displayID,
                                 x: $0.frame.origin.x, y: $0.frame.origin.y,
                                 width: $0.frame.width, height: $0.frame.height)
        })
    }

    /// 先建新窗口、再撤旧窗口，中间不留空档：离开模式下不会露出桌面。
    /// 不经过 hide()，防休眠、亮度、事件监听、看门狗都保持原样
    private func rebuildWindows() {
        let old = windows
        windows.removeAll()
        wallpaperLayers.removeAll()
        edgeLayers.removeAll()
        buildWindows()
        for w in old { w.orderOut(nil) }
        publishWindowIDs()
    }

    // MARK: - 锁屏监听
    func watchLockState() {
        let nc = DistributedNotificationCenter.default()
        nc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                NSLog("screenIsLocked")
                self?.onLocked()
            }
        }
        nc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                NSLog("screenIsUnlocked")
                self?.onUnlocked()
            }
        }
        nc.addObserver(forName: .init("com.apple.screenLockUIIsShown"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                NSLog("screenLockUIIsShown")
                self?.lockUIShown = true
            }
        }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        lastState = sessionLocked()
        NSLog("watching, initial locked=%d", lastState ? 1 : 0)
    }

    private func poll() {
        let cur = sessionLocked()
        guard cur != lastState else { return }
        lastState = cur
        cur ? onLocked() : onUnlocked()
    }

    private func onLocked() {
        // 锁屏后 1.2s 再显示（等锁屏 UI 稳定）
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1200))
            guard Prefs.curtainOnLock, sessionLocked(), !self.suppressLockShow else { return }
            self.show(.lock)    // 离开模式下被锁屏时已经在显示，show 不会改模式
        }
    }

    private func onUnlocked() { suppressLockShow = false; hide() }

    // MARK: - 预览 / 离开模式
    func togglePreview() {
        if mode == .preview { hide() } else { show(.preview) }
    }

    func enterAway() { show(.away) }

    // MARK: - 显示
    func show(_ mode: CurtainMode) {
        guard windows.isEmpty else { return }
        self.mode = mode
        armedAt = Date().addingTimeInterval(1)
        if mode == .away { power.engage() }
        currentLevel = overlayLevel.rawValue
        buildWindows()
        NSLog("overlay shown (%@)", "\(mode)")
        installExitMonitors()
        startWatchdog()
    }

    /// 给当前每块屏建窗、上屏，壁纸异步补上；建完把当前布局记为基线
    private func buildWindows() {
        let screens = NSScreen.screens

        // 1) 立刻建窗、上屏。此时是黑底，绝不阻塞主线程。
        for screen in screens {
            let (win, layer) = buildWindow(for: screen)
            win.orderFrontRegardless()
            windows.append(win)
            wallpaperLayers[screen.displayID] = layer

            // stealth 时补一块 1px 宽的右边缘窗，让「未覆盖区域」从一整条底边
            // 缩成右上角 1x1 一个点（单块矩形没法只漏一个点）
            if stealthEnabled, let (edge, elayer) = buildEdgeWindow(for: screen) {
                edge.orderFrontRegardless()
                windows.append(edge)
                edgeLayers[screen.displayID] = elayer
            }
        }

        // 放进私有空间。失效时本次运行不再用，重建成普通窗口：
        // 移出了原空间却没进新空间的窗口可能根本不显示，不能留着
        if let space, !space.adopt(windows) {
            NSLog("SkyLightSpace 不可用，退回窗口层级")
            self.space = nil
            rebuildWindows()
            return
        }
        screenCoalescer.seed(Self.currentLayout())
        NSLog("overlay windows built, %d windows (screens=%d, space=%d)", windows.count, screens.count, space == nil ? 0 : 1)

        // 2) 壁纸异步补上：先用上次的缓存，再换成新抓的（壁纸可能已更换）；
        //    都没有就保持黑底，不影响退出
        Task { @MainActor in
            for s in screens {
                if let img = await WallpaperStore.shared.cached(s.displayID) { self.applyWallpaper(img, to: s.displayID) }
            }
            let images = await WallpaperCapture.prewarm(screens: screens)
            guard !self.windows.isEmpty else { return }
            for (id, img) in images { self.applyWallpaper(img, to: id) }
            NSLog("wallpaper applied %d/%d", images.count, screens.count)
        }
    }

    private func applyWallpaper(_ img: CGImage, to id: CGDirectDisplayID) {
        wallpaperLayers[id]?.contents = img
        if let el = edgeLayers[id], img.width > 1, img.height > 1 {
            // 只取最右 1 列、去掉顶部 1px，精确对齐主窗内容
            el.contents = img
            el.contentsGravity = .resize
            el.contentsRect = CGRect(
                x: CGFloat(img.width - 1) / CGFloat(img.width),
                y: 0,
                width: 1.0 / CGFloat(img.width),
                height: CGFloat(img.height - 1) / CGFloat(img.height))
        }
    }

    // MARK: - 隐藏
    func hide() {
        NSLog("overlay hide")
        removeExitMonitors()
        watchdog?.cancel(); watchdog = nil
        power.release()
        for w in windows { w.orderOut(nil) }
        windows.removeAll()
        wallpaperLayers.removeAll()
        edgeLayers.removeAll()
        mode = nil
        screenCoalescer.reset()     // 清基线，也让排着的回调失效
    }

    // MARK: - 退出路径
    private func handlePhysicalInput() {
        guard let mode, Date() >= armedAt else { return }
        NSLog("真人输入 -> 撤遮罩 (%@)", "\(mode)")
        Task { await safeHide() }
    }

    /// 撤遮罩，但绝不露出已解锁的桌面：离开模式下先锁屏再撤
    func safeHide() async {
        if mode == .away { await lockThenHide() } else { hide() }
    }

    // MARK: - 控制接口（ControlServer 调用）
    func handleCommand(_ cmd: String) async -> [String: Any] {
        switch cmd {
        case "away":    show(.away)        // 已在显示时不改模式，回复里的 mode 是实际状态
        case "preview": show(.preview)
        case "hide":    await safeHide()
        case "status":  break
        default:        return ["ok": false, "error": "未知命令 \(cmd)，可用：away / preview / hide / status"]
        }
        var s: [String: Any] = ["ok": true, "running": true,
                                "mode": mode.map { "\($0)" } ?? "none",
                                "locked": sessionLocked()]
        if mode != nil {
            s["exitPathsHealthy"] = inputFilter.isHealthy
            s["level"] = currentLevel
            s["space"] = space?.holds(windows) ?? false
        }
        return s
    }

    private func installExitMonitors() {
        guard !inputFilter.isRunning else { return }

        inputFilter.start(
            onPhysical: { [weak self] in
                Task { @MainActor in self?.handlePhysicalInput() }
            },
            onSynthetic: { srcPID, reason in
                // agent / cua-driver 的合成输入：放行，不关遮罩
                NSLog("合成输入 from pid=%d (%@) -> 放行", srcPID, reason)
            }
        )

        if !inputFilter.isRunning {
            NSLog("⚠️ 无法安装输入监听（缺辅助功能权限）。遮罩只能靠看门狗或菜单关闭。")
        }

        publishWindowIDs()
    }

    /// 发布遮罩 windowID，供外部抓屏工具排除；重建窗口后要重新发布
    private func publishWindowIDs() {
        let ids = windows.compactMap { w in UInt32(w.windowNumber) }
        CurtainInfoFile.write(pid: getpid(), windowIDs: ids)
        NSLog("published overlay windowIDs: %@", ids.description)
    }

    private func removeExitMonitors() {
        inputFilter.stop()
        CurtainInfoFile.clear()
    }

    /// 只在按键 / 点击退出路径不可用时计时。监听正常时遮罩可以一直保留，
    /// 真实锁屏下用户也总能盲输密码解锁，解锁通知会撤掉遮罩。
    private func startWatchdog() {
        watchdog?.cancel()
        let limit = maxUnguardedTime
        watchdog = Task { @MainActor in
            var unguarded: TimeInterval = 0
            while !Task.isCancelled, !self.windows.isEmpty {
                try? await Task.sleep(for: .seconds(1))
                self.guardLevel()
                unguarded = self.inputFilter.isHealthy ? 0 : unguarded + 1
                if unguarded >= limit {
                    NSLog("watchdog: 退出路径不可用已 %.0fs, 先锁屏再撤遮罩", limit)
                    await self.lockThenHide()
                    return
                }
            }
        }
    }

    /// 动态层级保护：别的工具（录屏/投屏的遮罩、镜像窗）压到我们上面时，抬到它之上。
    /// 层级超过 Int32.max 会溢出成负数沉到最底，所以封顶；到顶后平级的靠重新排到最前
    private func guardLevel() {
        guard let bottom = windows.first else { return }   // 建窗顺序决定它在我们的窗口里最靠后
        let me = Int(getpid())
        let above = (CGWindowListCopyWindowInfo(.optionOnScreenAboveWindow, CGWindowID(bottom.windowNumber))
            as? [[String: Any]] ?? []).filter {
            ($0[kCGWindowOwnerPID as String] as? Int) != me && ($0[kCGWindowAlpha as String] as? Double ?? 1) > 0
        }
        guard let top = above.compactMap({ $0[kCGWindowLayer as String] as? Int }).max() else { return }
        let level = min(max(currentLevel, top + 1), Int(Int32.max))
        if level != currentLevel {
            NSLog("guardLevel: %@ 在层级 %d 压住遮罩，抬到 %d",
                  above.first { ($0[kCGWindowLayer as String] as? Int) == top }?[kCGWindowOwnerName as String] as? String ?? "?",
                  top, level)
            currentLevel = level
        }
        for w in windows {
            w.level = NSWindow.Level(rawValue: level)
            w.orderFrontRegardless()
        }
    }

    /// 先锁屏，等系统锁屏界面真正显示出来（最多等 5 秒）再撤遮罩，撤掉后露出的是锁屏而不是桌面。
    /// 看门狗和离开模式用。锁屏失败也照样撤，首要任务是防止锁死。
    private func lockThenHide() async {
        guard !locking else { return }      // 滚轮等会连发，只处理第一次
        locking = true
        defer { locking = false }
        if !sessionLocked() {
            suppressLockShow = true
            lockUIShown = false
            if Self.lockScreen() {
                // 「已锁」标志在系统刚立起一层只有壁纸的底板时就变 true，时钟和密码框要 0.15～1.2 秒后才显示，
                // 收到通知时还在淡入（实测通知后 0.2～0.9 秒才淡入完）。只等标志就撤，最长约 2 秒看不到锁屏界面（2026-10-26）
                var waited = 0
                while !lockUIShown, waited < 50, !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    waited += 1
                }
                if lockUIShown {
                    try? await Task.sleep(for: .milliseconds(1500))     // 等淡入做完，留余量
                } else if sessionLocked() {
                    NSLog("lockThenHide: 5 秒内没等到锁屏界面显示，照样撤遮罩")
                }
            }
            if !sessionLocked() {
                NSLog("lockThenHide: 锁屏失败，直接撤遮罩")
                suppressLockShow = false
            }
        }
        hide()
    }

    /// 不依赖辅助功能权限的锁屏（login.framework 私有 API）。看门狗触发时
    /// 往往正缺辅助功能权限，合成 ⌃⌘Q 发不出去。
    static func lockScreen() -> Bool {
        guard let h = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_NOW),
              let sym = dlsym(h, "SACLockScreenImmediate") else {
            NSLog("lockScreen: SACLockScreenImmediate 不可用")
            return false
        }
        typealias Fn = @convention(c) () -> Int32
        let r = unsafeBitCast(sym, to: Fn.self)()
        NSLog("SACLockScreenImmediate -> %d", r)
        return true
    }

    /// 紧急退出（菜单/快捷键用）
    func forceHide() { hide() }

    // MARK: - 窗口构建
    /// 窗口整体不透明度略低于 1，系统就不会认为遮罩挡住了下面的窗口。
    /// 等于 1 时（实测 2026-10-26，macOS 26）：被遮罩完全盖住的窗口会从整屏截图里消失，
    /// 遮罩显示后才打开的窗口和内容变化都截不到；app 也认为自己不可见，可能停止重绘。
    /// 只设 isOpaque = false 不管用。0.999 透出的最多 0.255 个色阶，8 位颜色里取整为 0
    private static let curtainAlpha: CGFloat = 0.999

    private func buildWindow(for screen: NSScreen) -> (NSWindow, CALayer) {
        let w = OverlayWindow(contentRect: screen.frame, styleMask: [], backing: .buffered, defer: false)
        w.animationBehavior = .none
        w.backgroundColor = .black
        w.isOpaque = true
        w.alphaValue = Self.curtainAlpha
        w.hasShadow = false
        w.ignoresMouseEvents = true              // 鼠标穿透到下层，交给全局监听处理
        w.level = NSWindow.Level(rawValue: currentLevel)
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenNone]

        // ★ 关键：对人可见，但对屏幕捕获不可见。
        //   sharingType = .none 会让这个窗口从 CGWindowListCreateImage /
        //   ScreenCaptureKit / screencapture 的结果里消失，
        //   但 WindowServer 仍然合成它，人眼照样看得见。
        //   这样 agent / cua-driver 截到的还是真实桌面。
        //   设 LOCKCURTAIN_VISIBLE_TO_CAPTURE=1 可强制它被拍进去（调试用）。
        // sharingType = .none 实测会在截图里留下纯黑空洞（不是透出桌面），
        // 所以保持默认 .readOnly，改由抓屏侧用 SCContentFilter(display:excludingWindows:)
        // 显式排除遮罩窗口。
        // 可调（实验用）：--share none 让窗口对截图不可见
        // stealth 模式：对任何抓屏工具都隐形。
        // 做法 = sharingType.none + 高度少 1px。
        //
        // 为什么必须少 1px（实测 2026-10-25，macOS 26）：
        //   不可共享窗口覆盖 100% 屏幕时，SCK 直接返回整屏全黑（138 KB），
        //   不是「透出下层」。这是系统级的隐私保护：全屏私密层不能被透视。
        //   覆盖率 90% 或留 1px 缺口时，SCK 正常重新合成，透出真实桌面（1.67 MB）。
        //   实测：gap1 / gap4 / p90 都透出；halves(两窗拼满) / full 都全黑。
        // 默认开启 stealth（对抓屏隐形），--no-stealth 可关闭。
        let stealth = !CommandLine.arguments.contains("--no-stealth")
        w.sharingType = stealth ? .none : .readOnly
        if stealth {
            // 主窗让出最右 1 列（高度不减），配合边缘窗，未覆盖区域只剩右上角 1x1
            var f = w.frame
            f.size.width -= 1
            w.setFrame(f, display: false)
        }
        if CommandLine.arguments.contains("--transparent") {
            w.isOpaque = false
            w.backgroundColor = .clear
        }

        let content = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        content.wantsLayer = true
        let transparentMode2 = CommandLine.arguments.contains("--transparent")
        content.layer?.backgroundColor = transparentMode2
            ? NSColor.clear.cgColor
            : NSColor.black.cgColor

        let (wallpaperView, wallpaperLayer) = buildWallpaperView(for: screen)
        let dim = buildDim()
        let art = Prefs.curtainArt
        let artView = buildArt(art)
        let text = buildText()

        for v in [wallpaperView, dim, artView, text] { content.addSubview(v) }

        NSLayoutConstraint.activate([
            wallpaperView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            wallpaperView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            wallpaperView.topAnchor.constraint(equalTo: content.topAnchor),
            wallpaperView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            dim.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            dim.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            dim.topAnchor.constraint(equalTo: content.topAnchor),
            dim.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            artView.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            artView.centerYAnchor.constraint(equalTo: content.centerYAnchor, constant: art.offsetY),
            text.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            text.centerYAnchor.constraint(equalTo: content.centerYAnchor, constant: 33.5),
        ])
        w.contentView = content
        return (w, wallpaperLayer)
    }

    /// stealth 用的右边缘窗：宽 1px、高减 1px，内容是最右一列壁纸 + 同样的压暗
    private func buildEdgeWindow(for screen: NSScreen) -> (NSWindow, CALayer)? {
        let f = screen.frame
        guard f.width > 2, f.height > 2 else { return nil }
        let edgeFrame = NSRect(x: f.origin.x + f.size.width - 1,
                               y: f.origin.y,
                               width: 1,
                               height: f.size.height - 1)

        let w = OverlayWindow(contentRect: edgeFrame, styleMask: [], backing: .buffered, defer: false)
        w.animationBehavior = .none
        w.backgroundColor = .black
        w.isOpaque = true
        w.alphaValue = Self.curtainAlpha
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = NSWindow.Level(rawValue: currentLevel)
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenNone]
        w.sharingType = .none

        let content = NSView(frame: NSRect(origin: .zero, size: edgeFrame.size))
        content.wantsLayer = true
        let layer = content.layer!
        layer.backgroundColor = NSColor.black.cgColor
        layer.contentsGravity = .resize
        layer.masksToBounds = true

        // 同样的 0.28 压暗，让 1px 接缝和主窗一致
        let dim = CALayer()
        dim.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
        dim.frame = layer.bounds
        dim.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer.addSublayer(dim)

        w.contentView = content
        return (w, layer)
    }

    private func buildWallpaperView(for screen: NSScreen) -> (NSView, CALayer) {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.wantsLayer = true
        let l = v.layer!
        l.contentsGravity = .resizeAspectFill
        l.backgroundColor = NSColor.black.cgColor
        l.masksToBounds = true
        return (v, l)
    }

    private func buildDim() -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
        return v
    }

    /// 中间的图案（CurtainArt.swift），设置里可换
    private func buildArt(_ art: CurtainArt) -> NSView {
        let v = NSHostingView(rootView: CurtainArtView(art: art))
        v.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            v.widthAnchor.constraint(equalToConstant: art.size),
            v.heightAnchor.constraint(equalToConstant: art.size),
        ])
        return v
    }

    private func buildText() -> NSView {
        let t = NSTextField(labelWithString: "LockCurtain is Using Your Mac")
        t.font = NSFont.systemFont(ofSize: 15, weight: .medium)
        t.textColor = NSColor.white.withAlphaComponent(0.5)
        t.alignment = .center
        t.translatesAutoresizingMaskIntoConstraints = false

        let s = NSTextField(labelWithString: "Press any key or click to unlock")
        s.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        s.textColor = NSColor.white.withAlphaComponent(0.5)
        s.alignment = .center
        s.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [t, s])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 15
        stack.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            t.widthAnchor.constraint(equalToConstant: 194),
            t.heightAnchor.constraint(equalToConstant: 18),
            s.widthAnchor.constraint(equalToConstant: 186),
            s.heightAnchor.constraint(equalToConstant: 14),
        ])
        return stack
    }

    // MARK: - 壁纸采集（菜单用，异步）
    func grabWallpaperNow() {
        Task { @MainActor in
            await WallpaperCapture.invalidate()
            for (i, screen) in NSScreen.screens.enumerated() {
                let ok = await WallpaperCapture.captureOne(screen: screen)
                NSLog("grab screen[%d] display=%u -> %@", i, screen.displayID, ok ? "OK" : "FAIL")
            }
        }
    }
}
