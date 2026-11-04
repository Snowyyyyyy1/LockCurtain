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
    private lazy var panel = StatusPanelController(actions: StatusPanelActions(
        enterAway: { [overlay] in overlay.enterAway() },
        preview: { [overlay] in overlay.togglePreview() },
        openPairing: { [weak self] in self?.pairingWindow.show() },
        openPhonePage: { [weak self] in self?.settings.show(.phone) },
        openSettings: { [weak self] in self?.settings.show() }), keepAwake: keepAwake, pairing: pairing)
    private let overlay = OverlayController()
    private let pairing = PhonePairing()
    private lazy var pairingWindow = PairingWindowController(pairing: pairing)
    private let keepAwake = KeepAwake()
    private lazy var control = ControlServer { [weak self] cmd in await self?.handleCommand(cmd) ?? [:] }
    private var permissionTimer: Timer?
    private var prefObservers: [NSKeyValueObservation] = []
    private let rules = RuleStore()
    private lazy var ruleEngine = RuleEngine(store: rules) { [overlay] _ in overlay.enterAway() }
    private lazy var settings = SettingsWindowController(store: rules, actions: AppActions(
        enterAway: { [overlay] in overlay.enterAway() },
        grabWallpaper: { [overlay] done in overlay.grabWallpaperNow(done) },
        openPairing: { [weak self] in self?.pairingWindow.show() },
        openStartGuide: { [weak self] in self?.startGuide.show() },
        requestBluetooth: { [pairing] in pairing.prepare() }), pairing: pairing, keepAwake: keepAwake)
    private lazy var startGuide = StartGuideController(pairing: pairing) { [weak self] in self?.pairingWindow.show() }
    /// N2 的提示框正开着：手机连发几次 away 也只弹一个
    private var missingAXAlertShowing = false

    func applicationDidFinishLaunching(_ note: Notification) {
        NSLog("LockCurtain launched")
        // 记下启动时屏幕录制的授权状态（权限页「重新打开 LockCurtain」只在这次运行里刚授权时出现）
        _ = SystemPermissions.screenRecordingAtLaunch
        removeLegacyWallpaperDumps()
        LogFolder.removeLegacyTmpLog()

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
                // 幕布开关状态同步给已连上的手机
                self?.pairing.reportCurtainState(mode == nil ? "open" : "closed")
            }
            // 已经配过对的手机要能随时找回来，所以这时就开始找它（第一次配对才弹蓝牙权限）
            if pairing.isPaired { pairing.prepare() }
            // N2：没辅助功能不让盖（盖上以后键鼠撤不下来）；手机那头收到 Ack 4
            overlay.onMissingAccessibility = { [weak self] in self?.showMissingAccessibility() }
            pairing.canCover = { OverlayController.canCover }
            // 保持唤醒：手机能开关，Mac 上不管谁改了都报给连着的手机（手机命令处理中不报，处理完统一报一次）
            pairing.onKeepAwake = { [keepAwake] cmd in keepAwake.apply(phoneCommand: cmd) }
            pairing.keepAwakeState = { [keepAwake] in keepAwake.wireState }
            keepAwake.onChange = { [weak self] in
                guard let self else { return }
                self.updateStatusIcon()
                if !self.pairing.handlingAwake { self.pairing.reportKeepAwake() }
            }
            keepAwake.restore()
            overlay.watchLockState()
            pairing.onCommand = { [weak self] cmd in _ = await self?.handleCommand(cmd) }
            // 手机撤下幕布：只撤 LockCurtain 的遮罩（离开模式里「验证」通过的效果），系统锁屏不动
            pairing.onLift = { [overlay] in
                Task { @MainActor in overlay.liftFromPhone() }
            }
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
            startGuide.showIfNeeded()
        }
    }

    /// 菜单栏和 Dock 图标都隐藏时，在访达 / 启动台里再次打开 App 会走到这里（实测送到已运行的实例）
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if RunMode.shared == .normal { settings.show() }
        return false
    }

    private func handleCommand(_ cmd: String) async -> [String: Any] {
        switch cmd {
        case "settings":
            settings.show()
        case "pairing":
            pairingWindow.show()
        case "pairselftest":
            // 配对加密层自测：进程内跑，结果写到 /tmp/lockcurtain-pairtest.txt，不碰蓝牙、不退出
            PairingSelfTest.runAndWrite()
        default:
            return await overlay.handleCommand(cmd)
        }
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
    @objc private func openPairing() { pairingWindow.show() }

    /// 撤销配对（A1：按手机撤，别的手机不动）。菜单项的 representedObject 是那台手机的 ID
    @objc private func revokePairing(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        let alert = NSAlert()
        alert.messageText = "撤销这台手机的配对？"
        alert.informativeText = "撤销后，这台手机要重新输码才能再盖上幕布。其他手机的配对不受影响。"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "撤销配对")
        NSApp.activate(ignoringOtherApps: true)
        // 撤销完不弹「已撤销」：那一行消失就是答案（Camo §16.1）
        if alert.runModal() == .alertSecondButtonReturn { pairing.unpair(id) }
    }

    /// N2：没辅助功能权限，不盖（Camo §16.8）
    private func showMissingAccessibility() {
        guard !missingAXAlertShowing else { return }
        missingAXAlertShowing = true
        defer { missingAXAlertShowing = false }
        let alert = NSAlert()
        alert.messageText = CoverRefusal.message
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "打开设置")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn { SystemPermissions.requestAccessibility() }
    }
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

    /// 老版本把抓到的壁纸存成 /tmp/lockcurtain-wallpaper*.png，现在不写了；
    /// 启动时把之前留下的删掉，别让旧文件继续躺在公共临时目录里。
    private func removeLegacyWallpaperDumps() {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: tmp.path) else { return }
        for name in names where name.hasPrefix("lockcurtain-wallpaper") {
            let url = tmp.appendingPathComponent(name)
            if (try? FileManager.default.removeItem(at: url)) != nil {
                NSLog("removed legacy wallpaper dump %@", url.path)
            }
        }
    }

    // ---------- 壁纸采集自测 ----------
    private func runCapture() {
        var log = collectStatus("capture-start") + Blob.nl
        let out = AppPaths.file("capture.txt").path
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
                    // 只报尺寸，不写盘：自测也不该把屏幕画面留在磁盘上
                    w("screen[\(i)] display=\(s.displayID) -> \(img.width)x\(img.height)")
                    saved += 1
                } else {
                    w("screen[\(i)] display=\(s.displayID) -> 失败（会退化成黑底）")
                }
            }
            w(saved == screens.count ? "全部 \(saved) 块屏成功" : "只有 \(saved)/\(screens.count) 成功")

            // 设置页那个「抓取当前壁纸」按钮走的也是这条：只刷新内存，不写盘
            var refreshed = 0
            for s in screens where await WallpaperCapture.refreshOne(screen: s) {
                refreshed += 1
            }
            w("refreshOne 成功 \(refreshed)/\(screens.count)（不写文件）")

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
        }
    }

    // ---------- 菜单栏 ----------
    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        updateStatusIcon()
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    /// 右键菜单（Colo A3 的顺序，Camo v14.3 §14.1 / §16.10 的字）。每次弹之前现搭：勾、置灰、手机状态都是当下的
    private func buildStatusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ action: Selector?, key: String = "", enabled: Bool = true, to m: NSMenu? = nil) -> NSMenuItem {
            let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
            it.target = action == nil ? nil : self
            it.isEnabled = enabled && action != nil
            (m ?? menu).addItem(it)
            return it
        }

        _ = add("盖上幕布", #selector(enterAway))
        add("预览幕布", #selector(toggleOverlay)).state = overlay.mode == .preview ? .on : .off
        // 没盖时置灰（D1：盖着时幕布在菜单栏上面，这一项其实点不到；留着给预览之外的情形和一致性）
        _ = add("撤下幕布", #selector(forceHideOverlay), enabled: overlay.mode != nil)
        menu.addItem(.separator())

        let awakeItem = NSMenuItem(title: "保持唤醒", action: nil, keyEquivalent: "")
        let awake = NSMenu()
        awake.autoenablesItems = false
        if let until = keepAwake.until {
            _ = add(KeepAwakeText.menuStatus(until, clockTime: keepAwake.clockTime), nil, enabled: false, to: awake)
            _ = add("停止", #selector(stopKeepAwake), to: awake)
        } else {
            add("一直", #selector(startKeepAwake(_:)), to: awake).tag = 0
            for h in [1, 2, 5] { add("\(h) 小时", #selector(startKeepAwake(_:)), to: awake).tag = h }
            _ = add("到指定时间…", #selector(pickKeepAwakeTime), to: awake)
            awake.addItem(.separator())
            let appsItem = NSMenuItem(title: "某个 app 开着时", action: nil, keyEquivalent: "")
            let apps = NSMenu()
            apps.autoenablesItems = false
            let running = KeepAwakeText.runningApps()
            if running.isEmpty { _ = add("现在没有", nil, enabled: false, to: apps) }
            for app in running {
                let it = add(app.localizedName ?? "pid \(app.processIdentifier)", #selector(keepAwakeWhileApp(_:)), to: apps)
                it.representedObject = app
            }
            appsItem.submenu = apps
            awake.addItem(appsItem)
        }
        awakeItem.submenu = awake
        menu.addItem(awakeItem)
        menu.addItem(.separator())

        let phones = pairing.phones
        let phoneState = phones.isEmpty ? "未配对" : pairing.anyPhoneConnected ? "已连上" : "没连上"
        _ = add("手机 · \(phoneState)", nil, enabled: false)
        _ = add("配对手机…", #selector(openPairing))
        if phones.count == 1 {
            add("撤销配对…", #selector(revokePairing(_:))).representedObject = phones[0].id
        } else if phones.count > 1 {
            // 多台时变子菜单，列出每台（A3）
            let revokeItem = NSMenuItem(title: "撤销配对", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            sub.autoenablesItems = false
            for p in phones { add(p.name + "…", #selector(revokePairing(_:)), to: sub).representedObject = p.id }
            revokeItem.submenu = sub
            menu.addItem(revokeItem)
        }
        menu.addItem(.separator())

        _ = add("设置…", #selector(openSettings), key: ",")
        if Updater.shared.isAvailable { _ = add("检查更新…", #selector(checkForUpdates)) }
        _ = add("打开日志文件夹", #selector(openLogFolder))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 LockCurtain", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        return menu
    }

    /// 左键弹面板；右键或按住 ⌃ 点按弹菜单
    @objc private func statusItemClicked() {
        guard let item = statusItem, let button = item.button else { return }
        let e = NSApp.currentEvent
        if e?.type == .rightMouseUp || e?.modifierFlags.contains(.control) == true {
            item.menu = buildStatusMenu()   // 临时挂上弹出来，再摘掉，否则左键也会弹菜单
            button.performClick(nil)
            item.menu = nil
        } else {
            panel.toggle(from: button)
        }
    }

    @objc private func forceHideOverlay() { overlay.forceHide() }

    @objc private func toggleOverlay() { overlay.togglePreview() }
    @objc private func enterAway() { overlay.enterAway() }
    @objc private func openLogFolder() { LogFolder.open() }

    @objc private func stopKeepAwake() { keepAwake.stop() }
    /// tag 0 = 一直；1 / 2 / 5 = 小时
    @objc private func startKeepAwake(_ sender: NSMenuItem) {
        keepAwake.start(sender.tag == 0 ? .forever : .date(Date().addingTimeInterval(Double(sender.tag) * 3600)))
    }
    @objc private func keepAwakeWhileApp(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? NSRunningApplication else { return }
        keepAwake.start(.appQuits(app.processIdentifier, name: app.localizedName ?? "pid \(app.processIdentifier)"))
    }
    /// 「到指定时间…」：打开 设置 › 保持唤醒，直接露出选钟点那一行
    @objc private func pickKeepAwakeTime() {
        settings.nav.pickTime = true
        settings.show(.keepAwake)
    }
}
