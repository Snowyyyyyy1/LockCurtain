// main.swift —— 入口
//
// LockCurtain 只做一件事：锁屏时在每块屏幕上画一层壁纸遮罩。
// 纯视觉层，不改变系统锁屏状态，也不干预任何输入目标。

import AppKit

let args = CommandLine.arguments

// 控制套接字的对端提前断开时，写入会触发 SIGPIPE 直接杀掉进程（实测退出码 141）
signal(SIGPIPE, SIG_IGN)

// 命令行客户端：LockCurtain --send away|preview|hide|status，发给正在运行的实例后退出
if let i = args.firstIndex(of: "--send") {
    exit(ControlClient.send(i + 1 < args.count ? args[i + 1] : "status"))
}

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
    app.setActivationPolicy(Prefs.showDockIcon && RunMode.shared == .normal ? .regular : .accessory)
    app.run()
}
