// AppDelegate.swift —— 应用生命周期与菜单栏
// 权限申请必须放在 didFinishLaunching 里：只有 NSApp.run() 起来之后，
// 系统才能把 TCC 弹窗投到我们的进程上。

import AppKit
import CoreGraphics
import ScreenCaptureKit

enum RunMode2 {
    case status, requestPermissions, capture, preview, normal
}

final class RunMode {
    static var shared: RunMode2 = .normal
}

enum Blob { static let nl = String(Character(UnicodeScalar(10))) }

let statusPath = "/tmp/lockcurtain-status.txt"
let captureLog = "/tmp/lockcurtain-capture.txt"

func collectStatus(_ tag: String) -> String {
    """
    [\(tag)]
    bundleID        = \(Bundle.main.bundleIdentifier ?? "(nil)")
    screenRecording = \(CGPreflightScreenCaptureAccess())
    accessibility   = \(AXIsProcessTrusted())
    """
}
func writeStatus(_ s: String) { try? s.write(toFile: statusPath, atomically: true, encoding: .utf8) }

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    /// 右键弹的菜单；左键弹面板
    private var statusMenu = NSMenu()
    private lazy var panel = StatusPanelController(actions: StatusPanelActions(
        enterAway: { [overlay] in overlay.enterAway() },
        preview: { [overlay] in overlay.togglePreview() },
        openSettings: { [weak self] in self?.settings.show() }), keepAwake: keepAwake)
    private let overlay = OverlayController()
    private let keepAwake = KeepAwake()
    private lazy var control = ControlServer { [weak self] cmd in await self?.handleCommand(cmd) ?? [:] }
    private var permissionTimer: Timer?
    private var prefObservers: [NSKeyValueObservation] = []
    private let rules = RuleStore()
    private lazy var ruleEngine = RuleEngine(store: rules) { [overlay] _ in overlay.enterAway() }
    private lazy var settings = SettingsWindowController(store: rules, actions: AppActions(
        enterAway: { [overlay] in overlay.enterAway() },
        grabWallpaper: { [overlay] in overlay.grabWallpaperNow() }))

    func applicationDidFinishLaunching(_ note: Notification) {
        NSLog("LockCurtain launched")

        switch RunMode.shared {
        case .status:
            writeStatus(collectStatus("status"))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }

        case .requestPermissions:
            requestPermissions()

        case .capture:
            runCapture()

        case .preview:
            // 直接显示遮罩并常驻，不依赖菜单栏自动化（测试/脚本用）
            overlay.show(.preview)
            setupStatusItem()




        case .normal:
            Updater.shared.curtainShowing = { [overlay] in overlay.mode != nil }
            Updater.shared.start()
            setupMainMenu()
            setupStatusItem()
            overlay.onModeChange = { [weak self] mode in
                self?.updateStatusIcon()
                if mode == nil { Updater.shared.curtainHidden() }
            }
            keepAwake.onChange = { [weak self] in self?.updateStatusIcon() }
            keepAwake.restore()
            overlay.watchLockState()
            control.start()
            ruleEngine.start()
            // KVO 也能收到其他进程（defaults write）的修改，didChangeNotification 只管本进程
            prefObservers = [
                UserDefaults.standard.observe(\.showDockIcon) { [weak self] _, _ in
                    DispatchQueue.main.async { self?.applyAppearance() }
                },
                UserDefaults.standard.observe(\.showMenuBarIcon) { [weak self] _, _ in
                    DispatchQueue.main.async { self?.applyAppearance() }
                },
            ]
            applyAppearance()
            writeStatus(collectStatus("normal"))
        }
    }

    /// 菜单栏和 Dock 图标都隐藏时，在访达 / 启动台里再次打开 App 会走到这里（实测送到已运行的实例）
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if RunMode.shared == .normal { settings.show() }
        return false
    }

    private func handleCommand(_ cmd: String) async -> [String: Any] {
        guard cmd == "settings" else { return await overlay.handleCommand(cmd) }
        settings.show()
        return ["ok": true, "running": true]
    }

    // ---------- Dock / 菜单栏图标 ----------
    private func applyAppearance() {
        let policy: NSApplication.ActivationPolicy = Prefs.showDockIcon ? .regular : .accessory
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
            settings.bringToFrontIfVisible()
        }
        statusItem?.isVisible = Prefs.showMenuBarIcon
    }

    /// 遮罩盖着 > 保持唤醒中 > 平时。初代 Mac 和 App 图标同一个造型：平时屏幕上是笑脸，遮罩盖着时屏幕涂满、抠出一把锁
    private func updateStatusIcon() {
        let img = overlay.mode != nil ? MenuBarGlyph.locked
            : keepAwake.isOn ? NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: "保持唤醒中")
            : MenuBarGlyph.idle
        img?.isTemplate = true
        statusItem?.button?.image = img
        statusItem?.button?.title = img == nil ? "🌙" : ""
    }

    /// Dock 图标显示时才看得到这个菜单栏；隐藏时 ⌘, ⌘Q 和输入框里的 ⌘C ⌘V 也靠它
    private func setupMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 LockCurtain", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        if Updater.shared.isAvailable {
            appMenu.addItem(withTitle: "检查更新…", action: #selector(checkForUpdates), keyEquivalent: "").target = self
        }
        appMenu.addItem(.separator())
        let s = appMenu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        s.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 LockCurtain", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 LockCurtain", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let winItem = NSMenuItem()
        let win = NSMenu(title: "窗口")
        win.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        win.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winItem.submenu = win
        main.addItem(winItem)
        NSApp.windowsMenu = win

        NSApp.mainMenu = main
    }

    @objc private func openSettings() { settings.show() }
    @objc private func checkForUpdates() { Updater.shared.checkForUpdates() }

    // ---------- 权限申请 ----------
    private var permissionWindow: NSWindow?

    /// TCC 弹窗需要一个「有 UI 的」常驻进程。建一个可见窗口，
    /// 弹窗才有地方附着，进程也不会因为没窗口而退出。
    private func makePromptWindow() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 180),
                         styleMask: [.titled, .closable],
                         backing: .buffered,
                         defer: false)
        w.title = "LockCurtain 权限申请"
        w.isReleasedWhenClosed = false
        let label = NSTextField(wrappingLabelWithString:
            "请在弹出的系统对话框中点击「允许」。\n\n如果没有看到对话框，请到\n系统设置 → 隐私与安全性 → 屏幕录制 / 辅助功能\n手动勾选 LockCurtain。")
        label.frame = NSRect(x: 20, y: 20, width: 380, height: 140)
        w.contentView?.addSubview(label)
        w.center()
        w.level = .floating
        w.makeKeyAndOrderFront(nil)
        permissionWindow = w
        NSApp.activate(ignoringOtherApps: true)
    }

    private func requestPermissions() {
        writeStatus(collectStatus("before"))
        makePromptWindow()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            let sr = CGRequestScreenCaptureAccess()
            NSLog("CGRequestScreenCaptureAccess -> %d", sr)
            writeStatus(collectStatus("sr-requested") + "\nCGRequestScreenCaptureAccess=\(sr)")

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                let ax = AXIsProcessTrustedWithOptions(opts)
                NSLog("AXIsProcessTrustedWithOptions -> %d", ax)
                writeStatus(collectStatus("ax-requested") + "\nAXIsProcessTrustedWithOptions=\(ax)")

                self?.permissionTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { t in
                    let okSR = CGPreflightScreenCaptureAccess()
                    let okAX = AXIsProcessTrusted()
                    writeStatus(collectStatus("waiting"))
                    if okSR && okAX {
                        t.invalidate()
                        writeStatus(collectStatus("granted"))
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 300) { [weak self] in
                    self?.permissionTimer?.invalidate()
                    writeStatus(collectStatus("timeout"))
                    NSApp.terminate(nil)
                }
            }
        }
    }

    // ---------- 壁纸采集自测 ----------
    private func runCapture() {
        var log = collectStatus("capture-start") + Blob.nl
        let out = "/tmp/lockcurtain-capture.txt"
        func w(_ s: String) {
            log.append(s); log.append(Blob.nl)
            try? log.write(toFile: out, atomically: true, encoding: .utf8)
        }
        w(log)

        Task { @MainActor in
            w(await WallpaperCapture.diagnose())

            let screens = NSScreen.screens
            let images = await WallpaperCapture.prewarm(screens: screens)

            var saved = 0
            for (i, s) in screens.enumerated() {
                if let img = images[s.displayID] {
                    let path = "/tmp/lockcurtain-wallpaper-\(i).png"
                    if let d = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) {
                        try? d.write(to: URL(fileURLWithPath: path))
                    }
                    w("screen[\(i)] display=\(s.displayID) -> \(img.width)x\(img.height) \(path)")
                    saved += 1
                } else {
                    w("screen[\(i)] display=\(s.displayID) -> 失败（会退化成黑底）")
                }
            }
            w(saved == screens.count ? "全部 \(saved) 块屏成功" : "只有 \(saved)/\(screens.count) 成功")

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
        }
    }

    // ---------- 菜单栏 ----------
    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        updateStatusIcon()
        let menu = NSMenu()

        let away = NSMenuItem(title: "进入离开模式", action: #selector(enterAway), keyEquivalent: "")
        away.target = self; menu.addItem(away)

        let pv = NSMenuItem(title: "锁屏遮罩预览", action: #selector(toggleOverlay), keyEquivalent: "")
        pv.target = self; menu.addItem(pv)

        let fh = NSMenuItem(title: "紧急关闭遮罩", action: #selector(forceHideOverlay), keyEquivalent: "")
        fh.target = self; menu.addItem(fh)

        menu.addItem(.separator())
        let st = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        st.target = self; menu.addItem(st)
        if Updater.shared.isAvailable {
            let up = NSMenuItem(title: "检查更新…", action: #selector(checkForUpdates), keyEquivalent: "")
            up.target = self; menu.addItem(up)
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusMenu = menu
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    /// 左键弹面板；右键或按住 ⌃ 点按弹原来的菜单
    @objc private func statusItemClicked() {
        guard let item = statusItem, let button = item.button else { return }
        let e = NSApp.currentEvent
        if e?.type == .rightMouseUp || e?.modifierFlags.contains(.control) == true {
            item.menu = statusMenu      // 临时挂上弹出来，再摘掉，否则左键也会弹菜单
            button.performClick(nil)
            item.menu = nil
        } else {
            panel.toggle(from: button)
        }
    }

    @objc private func forceHideOverlay() { overlay.forceHide() }

    @objc private func toggleOverlay() { overlay.togglePreview() }
    @objc private func enterAway() { overlay.enterAway() }
}
