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
    private let overlay = OverlayController()
    private var permissionTimer: Timer?

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
            overlay.show(autoHide: false)
            setupStatusItem()




        case .normal:
            setupStatusItem()
            overlay.watchLockState()
            writeStatus(collectStatus("normal"))
        }
    }

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
        item.button?.title = "🌙"
        let menu = NSMenu()

        let pv = NSMenuItem(title: "锁屏遮罩预览", action: #selector(toggleOverlay), keyEquivalent: "")
        pv.target = self; menu.addItem(pv)

        let fh = NSMenuItem(title: "紧急关闭遮罩", action: #selector(forceHideOverlay), keyEquivalent: "")
        fh.target = self; menu.addItem(fh)

        let sim = NSMenuItem(title: "模拟解锁 → 3 秒后 ⌃⌘Q", action: #selector(simulateUnlock), keyEquivalent: "")
        sim.target = self; menu.addItem(sim)

        menu.addItem(.separator())

        let sr = NSMenuItem(title: "申请屏幕录制权限", action: #selector(askSR), keyEquivalent: "")
        sr.target = self; menu.addItem(sr)
        let ax = NSMenuItem(title: "申请辅助功能权限", action: #selector(askAX), keyEquivalent: "")
        ax.target = self; menu.addItem(ax)
        let cap = NSMenuItem(title: "抓取当前壁纸", action: #selector(grabWallpaper), keyEquivalent: "")
        cap.target = self; menu.addItem(cap)

        menu.addItem(.separator())
        let st = NSMenuItem(title: "打印 TCC 状态", action: #selector(printStatus), keyEquivalent: "")
        st.target = self; menu.addItem(st)

        menu.addItem(.separator())
        let q = NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(q)

        item.menu = menu
        statusItem = item
    }

    @objc private func forceHideOverlay() { overlay.forceHide() }

    @objc private func toggleOverlay() { overlay.togglePreview() }
    @objc private func simulateUnlock() {
        overlay.show(autoHide: false)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            OverlayController.relock()
        }
    }

    @objc private func askSR() {
        NSApp.activate(ignoringOtherApps: true)
        let ok = CGRequestScreenCaptureAccess()
        alert("屏幕录制", ok ? "已授权 ✅" : "请在「系统设置 → 隐私与安全性 → 屏幕录制」勾选 LockCurtain，然后重启本 App。")
    }
    @objc private func askAX() {
        NSApp.activate(ignoringOtherApps: true)
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        alert("辅助功能", "请在「系统设置 → 隐私与安全性 → 辅助功能」勾选 LockCurtain。")
    }
    @objc private func grabWallpaper() { overlay.grabWallpaperNow() }
    @objc private func printStatus() { alert("TCC 状态", collectStatus("menu")) }

    private func alert(_ t: String, _ m: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = t
        a.informativeText = m
        a.addButton(withTitle: "好")
        a.runModal()
    }
}
