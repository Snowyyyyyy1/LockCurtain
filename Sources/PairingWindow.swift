// PairingWindow.swift —— 「配对手机」窗口
//
// 菜单里点开：一个 6 位码，一句告诉人在手机上做什么，下面是状态和两个按钮。
// 关闭窗口就把码作废（没配过手机的话也不再找手机）；配对成功时窗口自己留着，让人看清「配对好了」再关。

import AppKit
import SwiftUI

@MainActor
final class PairingWindowController: NSObject {
    private var window: NSWindow?
    private let pairing: PhonePairing

    init(pairing: PhonePairing) {
        self.pairing = pairing
        super.init()
    }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 330),
                             styleMask: [.titled, .closable],
                             backing: .buffered, defer: false)
            w.title = "配对手机"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            let host = NSHostingController(rootView: PairingView(pairing: pairing))
            w.contentViewController = host
            w.delegate = self
            // SwiftUI 内容的理想尺寸会把这个窗口撑成竖长条，先定死大小再居中，不然会跑到屏幕外面
            w.setContentSize(NSSize(width: 420, height: 330))
            // NSScreen.main 跟着键盘焦点走，接外接屏时会算到另一块屏上，窗口就跑到屏幕外面去了；
            // screens.first 是有菜单栏那块，永远在主屏上弹
            if let v = (NSScreen.screens.first ?? NSScreen.main)?.visibleFrame {
                let size = w.frame.size
                w.setFrameOrigin(NSPoint(x: v.midX - size.width / 2, y: v.midY - size.height / 2))
            }
            window = w
        }
        pairing.start()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

}

extension PairingWindowController: NSWindowDelegate {
    /// 用户点关闭时把码作废：码只在窗口开着的时候有效
    func windowWillClose(_ notification: Notification) {
        pairing.stop()
    }
}

private struct PairingView: View {
    @ObservedObject var pairing: PhonePairing

    var body: some View {
        VStack(spacing: 16) {
            switch pairing.phase {
            case .waiting, .idle:
                if pairing.codeInvalidated {
                    // D3a：错满 5 次，码作废；「换一个码」照常能按
                    Text("这 6 位作废了。")
                        .font(.title3.bold())
                        .frame(height: 60)
                        .padding(.top, 4)
                } else {
                    codeBlock
                }
                Text("输入后两台就认上了，以后同一台手机再来不用输码。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text("在手机上打开 LockCurtain 点「去配对」，把这 6 位数字输进去。")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

            case .paired:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.green)
                Text("已和这台手机配上。")
                    .font(.title3.bold())
                Text("手机那边等一下就是已连接。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("这台手机走近、并且此刻是解锁着的，就能撤下幕布。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

            case .bluetoothOff:
                Image(systemName: "bolt.horizontal.circle")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text("蓝牙没开")
                    .font(.title3.bold())
                Text("配对要用蓝牙。在菜单栏的蓝牙图标里打开蓝牙，再点一次「配对手机」。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

            case .unauthorized:
                Image(systemName: "hand.raised.circle")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text("没拿到蓝牙权限")
                    .font(.title3.bold())
                Text("到系统设置 → 隐私与安全性 → 蓝牙，给 LockCurtain 打开权限，再点一次「配对手机」。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

            case .unsupported:
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 44))
                    .foregroundStyle(.orange)
                Text("这台 Mac 的蓝牙用不了")
                    .font(.title3.bold())
            }

            Spacer(minLength: 4)

            HStack {
                if pairing.phase == .waiting || pairing.phase == .idle {
                    Button("换一个码") { pairing.refreshCode() }
                }
                Spacer()
                Button("关闭") { NSApp.keyWindow?.performClose(nil) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 420, height: 330)
    }

    private var codeBlock: some View {
        HStack(spacing: 10) {
            ForEach(Array(pairing.code.enumerated()), id: \.offset) { _, digit in
                Text(String(digit))
                    .font(.system(size: 34, weight: .semibold, design: .monospaced))
                    .frame(width: 44, height: 56)
                    .background(Color(nsColor: .quaternaryLabelColor).opacity(0.25),
                                in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("配对码")
        .accessibilityValue(pairing.code.map(String.init).joined(separator: " "))
        .padding(.top, 4)
    }
}
