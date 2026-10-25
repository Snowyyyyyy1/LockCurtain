// main.swift —— 入口
//
// LockCurtain 只做一件事：锁屏时在每块屏幕上画一层壁纸遮罩。
// 纯视觉层，不改变系统锁屏状态，也不干预任何输入目标。

import AppKit

let args = CommandLine.arguments

if args.contains("--request-permissions") { RunMode.shared = .requestPermissions }
else if args.contains("--status")         { RunMode.shared = .status }
else if args.contains("--capture")        { RunMode.shared = .capture }
else if args.contains("--preview")        { RunMode.shared = .preview }
else                                      { RunMode.shared = .normal }

// Swift 6 里顶层代码不是 @MainActor，显式进入主 actor
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
