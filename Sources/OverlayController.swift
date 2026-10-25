// OverlayController.swift —— 遮罩、锁屏感知、退出路径
//
// 设计约束：
//  1. 遮罩窗口 level = CGShieldingWindowLevel()+1（2147483629），盖住一切。
//     一旦它卡住，用户按什么都没用，只能 kill -9。所以必须有三条退出路径：
//       a) 全局按键监听 → 任意键关闭（对应界面上那句 "Press any key ..."）
//       b) 全局鼠标监听 → 任意点击关闭
//       c) 看门狗 → 超过 N 秒强制关（防止监听失效时锁死）
//  2. 绝不在主线程上同步等待截图结果。SCScreenshotManager 的完成回调
//     需要主线程派发，主线程被阻塞就是永久死锁。全部 async/await。

import AppKit
import ApplicationServices
import CoreGraphics

@_silgen_name("CGSessionCopyCurrentDictionary")
func CGSessionCopyCurrentDictionary() -> CFDictionary?

func sessionLocked() -> Bool {
    let d = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
    if let b = d["CGSSessionScreenIsLocked"] as? Bool { return b }
    if let n = d["CGSSessionScreenIsLocked"] as? NSNumber { return n.boolValue }
    return false
}

/// 位于 shielding level 之上的窗口。不允许成为 key/main，避免抢走焦点。
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func orderFrontRegardless() { super.orderFrontRegardless() }
}

@MainActor
final class OverlayController {
    private var windows: [NSWindow] = []
    private var wallpaperLayers: [CGDirectDisplayID: CALayer] = [:]
    /// stealth 模式下补右边缘那 1px 列的窗口图层
    private var edgeLayers: [CGDirectDisplayID: CALayer] = [:]
    private var previewing = false
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

    /// 遮罩最长存活时间（秒）。超时强制关闭，防止锁死。
    private let maxLifetime: TimeInterval = 120

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
            guard sessionLocked() else { return }
            self.show()
        }
    }

    private func onUnlocked() { hide() }

    // MARK: - 预览
    func togglePreview() {
        if previewing { hide(); previewing = false }
        else { show(autoHide: false); previewing = true }
    }

    // MARK: - 显示
    func show(autoHide: Bool = true) {
        guard windows.isEmpty else { return }
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
        NSLog("overlay shown, %d windows (screens=%d)", windows.count, screens.count)

        installExitMonitors()
        startWatchdog()

        // 2) 壁纸异步补上；失败就保持黑底，不影响退出
        Task { @MainActor in
            let images = await WallpaperCapture.prewarm(screens: screens)
            guard !self.windows.isEmpty else { return }
            for (id, img) in images {
                self.wallpaperLayers[id]?.contents = img
                if let el = self.edgeLayers[id], img.width > 1, img.height > 1 {
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
            NSLog("wallpaper applied %d/%d", images.count, screens.count)
        }
    }

    // MARK: - 隐藏
    func hide() {
        NSLog("overlay hide")
        removeExitMonitors()
        watchdog?.cancel(); watchdog = nil
        for w in windows { w.orderOut(nil) }
        windows.removeAll()
        wallpaperLayers.removeAll()
        edgeLayers.removeAll()
        previewing = false
    }

    // MARK: - 退出路径
    private func installExitMonitors() {
        guard !inputFilter.isRunning else { return }

        inputFilter.start(
            onPhysical: { [weak self] in
                NSLog("真人输入 -> 关闭遮罩")
                Task { @MainActor in self?.hide() }
            },
            onSynthetic: { srcPID, reason in
                // agent / cua-driver 的合成输入：放行，不关遮罩
                NSLog("合成输入 from pid=%d (%@) -> 放行", srcPID, reason)
            }
        )

        if !inputFilter.isRunning {
            NSLog("⚠️ 无法安装输入监听（缺辅助功能权限）。遮罩只能靠看门狗或菜单关闭。")
        }

        // 发布遮罩 windowID，供外部抓屏工具排除
        let ids = windows.compactMap { w in UInt32(w.windowNumber) }
        CurtainInfoFile.write(pid: getpid(), windowIDs: ids)
        NSLog("published overlay windowIDs: %@", ids.description)
    }

    private func removeExitMonitors() {
        inputFilter.stop()
        CurtainInfoFile.clear()
    }

    private func startWatchdog() {
        watchdog?.cancel()
        let limit = maxLifetime
        watchdog = Task { @MainActor in
            try? await Task.sleep(for: .seconds(limit))
            guard !Task.isCancelled else { return }
            if !self.windows.isEmpty {
                NSLog("watchdog: overlay exceeded %.0fs, force hide", limit)
                self.hide()
            }
        }
    }

    /// 紧急退出（菜单/快捷键用）
    func forceHide() { hide() }

    // MARK: - 窗口构建
    private func buildWindow(for screen: NSScreen) -> (NSWindow, CALayer) {
        let w = OverlayWindow(contentRect: screen.frame, styleMask: [], backing: .buffered, defer: false)
        w.animationBehavior = .none
        w.backgroundColor = .black
        w.isOpaque = true
        w.hasShadow = false
        w.ignoresMouseEvents = true              // 鼠标穿透到下层，交给全局监听处理
        // 层级可调（实验用）：--level N 覆盖；默认 shielding+1
        let levelOverride = CommandLine.arguments.firstIndex(of: "--level")
            .flatMap { $0 + 1 < CommandLine.arguments.count ? Int(CommandLine.arguments[$0 + 1]) : nil }
        w.level = NSWindow.Level(rawValue: levelOverride ?? (Int(CGShieldingWindowLevel()) + 1))
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
        let avatar = buildAvatar()
        let text = buildText()

        for v in [wallpaperView, dim, avatar, text] { content.addSubview(v) }

        NSLayoutConstraint.activate([
            wallpaperView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            wallpaperView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            wallpaperView.topAnchor.constraint(equalTo: content.topAnchor),
            wallpaperView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            dim.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            dim.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            dim.topAnchor.constraint(equalTo: content.topAnchor),
            dim.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            avatar.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            avatar.centerYAnchor.constraint(equalTo: content.centerYAnchor, constant: -60),
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
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = overlayLevel
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

    private func buildAvatar() -> NSView {
        let outer = NSView()
        outer.translatesAutoresizingMaskIntoConstraints = false
        outer.wantsLayer = true
        outer.layer?.cornerRadius = 39
        outer.layer?.borderWidth = 2
        outer.layer?.borderColor = NSColor.white.withAlphaComponent(0.92).cgColor
        outer.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.001).cgColor
        outer.layer?.masksToBounds = true

        let iv = NSImageView()
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.image = NSImage(named: NSImage.userAccountsName)
        outer.addSubview(iv)

        NSLayoutConstraint.activate([
            outer.widthAnchor.constraint(equalToConstant: 85),
            outer.heightAnchor.constraint(equalToConstant: 85),
            iv.widthAnchor.constraint(equalToConstant: 44),
            iv.heightAnchor.constraint(equalToConstant: 44),
            iv.centerXAnchor.constraint(equalTo: outer.centerXAnchor),
            iv.centerYAnchor.constraint(equalTo: outer.centerYAnchor),
        ])
        return outer
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

    // MARK: - 重新锁屏 ⌃⌘Q
    static func relock() {
        guard let src = CGEventSource(stateID: .hidSystemState) else { return }
        struct Step { let key: CGKeyCode; let down: Bool; let flags: CGEventFlags }
        // ⌃⌘Q = 55(⌘) 59(⌃) 12(Q)，最后锁屏前先松修饰键
        let steps: [Step] = [
            Step(key: 55, down: true,  flags: .maskCommand),
            Step(key: 59, down: true,  flags: [.maskCommand, .maskControl]),
            Step(key: 12, down: true,  flags: [.maskCommand, .maskControl]),
            Step(key: 12, down: false, flags: [.maskCommand, .maskControl]),
            Step(key: 59, down: false, flags: .maskCommand),
            Step(key: 55, down: false, flags: []),
        ]
        for s in steps {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: s.key, keyDown: s.down) else { continue }
            e.flags = s.flags
            e.post(tap: .cghidEventTap)
            usleep(20_000)
        }
    }
}
