// StartGuide.swift —— 「开始用 LockCurtain」窗口（N1）+ 权限、系统设置跳转的小工具
//
// 第一次打开、以及升级后权限缺了的时候弹一次；之后从 设置 › 通用 › 关于 ›「再看一遍开始指南」找回来。
// 三行：权限（屏幕录制、辅助功能）/ 配对手机（可以以后再说）/ 图标在哪儿（只是说明，不打勾）。字照 Camo §16.4 / v15.1 §17.4。

import AppKit
import Combine
import ApplicationServices
import CoreBluetooth
import CoreGraphics
import SwiftUI

/// 系统权限和系统设置的跳转（权限页、开始指南、N2 提示共用）
enum SystemPermissions {
    static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }
    /// 启动时屏幕录制有没有授权（AppDelegate 一启动就读一次）。这次运行里从没有变成有，才提示要重开
    static let screenRecordingAtLaunch = CGPreflightScreenCaptureAccess()
    static var accessibility: Bool { AXIsProcessTrusted() }

    enum Bluetooth { case allowed, notDetermined, denied }
    static var bluetooth: Bluetooth {
        switch CBManager.authorization {
        case .allowedAlways: return .allowed
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    static func openPrivacy(_ anchor: String) {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(u)
        }
    }

    static func openBluetoothSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") { NSWorkspace.shared.open(u) }
    }

    private static let promptedKey = "permissions.prompted"

    /// 第一次点：系统自己的申请框（顺便把 LockCurtain 加进系统设置的列表）；之后每次点都直接打开系统设置那一页（D4）
    static func requestScreenRecording() {
        if firstTime("screen") { _ = CGRequestScreenCaptureAccess() } else { openPrivacy("Privacy_ScreenCapture") }
    }

    static func requestAccessibility() {
        if firstTime("ax") {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        } else {
            openPrivacy("Privacy_Accessibility")
        }
    }

    private static func firstTime(_ what: String) -> Bool {
        var done = UserDefaults.standard.stringArray(forKey: promptedKey) ?? []
        guard !done.contains(what) else { return false }
        done.append(what)
        UserDefaults.standard.set(done, forKey: promptedKey)
        return true
    }

    /// 「重新打开 LockCurtain」：退出后由 /usr/bin/open 再拉起同一个 App（屏幕录制授权要重开才生效）
    static func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }
}

@MainActor
final class StartGuideController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let pairing: PhonePairing
    private let openPairing: () -> Void
    /// 看过的版本；第一次打开、或升级后权限缺了，才自己弹
    private static let shownVersionKey = "startGuide.shownVersion"

    init(pairing: PhonePairing, openPairing: @escaping () -> Void) {
        self.pairing = pairing
        self.openPairing = openPairing
    }

    /// 启动时调：第一次打开，或者这个版本还没弹过而权限缺了
    func showIfNeeded() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let shown = UserDefaults.standard.string(forKey: Self.shownVersionKey)
        let missing = !SystemPermissions.screenRecording || !SystemPermissions.accessibility
        guard shown == nil || (shown != version && missing) else { return }
        show()
    }

    func show() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        UserDefaults.standard.set(version, forKey: Self.shownVersionKey)
        if window == nil {
            // 高度跟内容走：NSHostingController 按 SwiftUI 的理想尺寸定窗口大小（以前 SwiftUI 里写死了 420 高，
            // 窗口这边改成 360 也会被它撑回 420）。配没配上手机行高不一样，窗口跟着变
            let host = NSHostingController(rootView: StartGuideView(
                pairing: pairing,
                openPairing: { [weak self] in self?.openPairing() },
                done: { [weak self] in self?.window?.performClose(nil) }))
            host.sizingOptions = [.preferredContentSize]
            let w = NSWindow(contentViewController: host)
            w.styleMask = [.titled, .closable]
            w.title = "开始用 LockCurtain"
            w.isReleasedWhenClosed = false
            w.delegate = self
            let size = host.view.fittingSize
            w.setContentSize(size)
            if let v = (NSScreen.screens.first ?? NSScreen.main)?.visibleFrame {
                w.setFrameOrigin(NSPoint(x: v.midX - size.width / 2, y: v.midY - size.height / 2))
            }
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct StartGuideView: View {
    @ObservedObject var pairing: PhonePairing
    let openPairing: () -> Void
    let done: () -> Void
    @State private var screen = SystemPermissions.screenRecording
    @State private var ax = SystemPermissions.accessibility
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("开始用 LockCurtain").font(.title2.bold())
            step(done: screen && ax) {
                Text("权限").font(.headline)
                permission("屏幕录制", ok: screen, request: SystemPermissions.requestScreenRecording)
                permission("辅助功能", ok: ax, request: SystemPermissions.requestAccessibility)
            }
            if pairing.phones.isEmpty {
                step(done: false) {
                    Text("配对手机（可以以后再说）").font(.headline)
                    Button("配对手机…", action: openPairing)
                    Text("手机上先装 LockCurtain。").font(.callout).foregroundStyle(.secondary)
                }
            } else {
                // 配上了：打勾，一台一行「已配上 iPhone · 11 月 4 日配上」（和 设置 › 手机 一样的写法），没有按钮
                step(done: true) {
                    ForEach(pairing.phones) { phone in
                        PhonePane.title(phone, prefix: "已配上 ").font(.headline)
                    }
                }
            }
            // 只是告诉你在哪儿，不算一项要做完的事：不打勾，左边是图标
            row(icon: Image(systemName: "menubar.arrow.up.rectangle").foregroundStyle(.secondary)) {
                Text("图标在哪儿").font(.headline)
                Text("LockCurtain 住在右上角的菜单栏里。").font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("好了", action: done).keyboardShortcut(.defaultAction)
            }
            .padding(.top, 24 - 18)
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 20)
        .frame(width: 480, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .onReceive(timer) { _ in
            screen = SystemPermissions.screenRecording
            ax = SystemPermissions.accessibility
        }
    }

    private func step<Content: View>(done: Bool, @ViewBuilder _ content: () -> Content) -> some View {
        row(icon: Image(systemName: done ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(done ? Color(nsColor: .systemGreen) : Color.secondary), content)
    }

    private func row<Icon: View, Content: View>(icon: Icon, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            icon.font(.system(size: 20)).frame(width: 24)
            VStack(alignment: .leading, spacing: 6) { content() }
            Spacer(minLength: 0)
        }
    }

    private func permission(_ title: String, ok: Bool, request: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            if ok {
                Label("已授权", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("去授权", action: request)
            }
        }
        .frame(maxWidth: 300)
    }
}
