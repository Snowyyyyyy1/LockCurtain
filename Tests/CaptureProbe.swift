// CaptureProbe.swift —— 遮罩下面的窗口，抓屏能不能拍到、拍到的是不是实时的（会在屏幕上真的盖一层遮罩）
//
//   D=$TMPDIR/cp; rm -rf $D && mkdir -p $D
//   xcrun swiftc -O -o $D/probe Tests/CaptureProbe.swift
//   $D/probe            逐档试遮罩的 alphaValue（1、0.999 … Float(1).nextDown、0.9999999999）
//   $D/probe real       用正在运行的 LockCurtain 的预览遮罩（--send preview / hide）；不通过时退出码 1
//   $D/probe gap        alpha 1、右边留 1px 缺口（早期的做法），作对照
//   加数字是每档跑几次，比如 probe real 3。要在终端里跑（终端有屏幕录制权限），在仓库根目录跑 real
//
// 每一档：子进程在主屏中间开一块绿色窗口，3 秒后变洋红；盖上遮罩，变色前后各抓一次：
// ScreenCaptureKit 整屏（只在内存里取点，不存盘）、screencapture 只截目标窗口那一块（读完就删）、单窗口截图；
// 再看子进程的窗口是否认为自己可见（occlusionState）。都拍到绿 → 洋红、窗口认为可见，才算透过去。
// 2026-10-28 macOS 26 的结果记在 docs/guide.md「抓屏：对捕获透明」。系统大版本升级后重跑一遍。

import AppKit
import ScreenCaptureKit

setvbuf(stdout, nil, _IONBF, 0)
let args = CommandLine.arguments

/// 测试窗口和遮罩都放在主屏（菜单栏所在的屏），两个进程的 NSScreen.main 可能不是同一块
func primaryFrame() -> NSRect { NSScreen.screens[0].frame }

if args.dropFirst().first == "target" {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let f = primaryFrame()
    let w = NSWindow(contentRect: NSRect(x: f.midX - 300, y: f.midY - 200, width: 600, height: 400),
                     styleMask: [.borderless], backing: .buffered, defer: false)
    w.backgroundColor = NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
    w.orderFrontRegardless()
    print("ready \(w.windowNumber)")
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
        w.backgroundColor = NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)
        print("magenta")
    }
    Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in print("visible \(w.occlusionState.contains(.visible))") }
    app.run()
}

let mode = args.dropFirst().first(where: { Int($0) == nil }) ?? "sweep"
let runs = args.dropFirst().compactMap { Int($0) }.first ?? 1
let lockCurtain = ProcessInfo.processInfo.environment["LOCKCURTAIN_BIN"] ?? "LockCurtain.app/Contents/MacOS/LockCurtain"

final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [String] = []
    func add(_ s: String) { lock.lock(); all += s.split(separator: "\n").map(String.init); lock.unlock() }
    var snapshot: [String] { lock.lock(); defer { lock.unlock() }; return all }
}

func send(_ cmd: String) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: lockCurtain)
    p.arguments = ["--send", cmd]
    let out = Pipe()
    p.standardOutput = out
    try! p.run(); p.waitUntilExit()
    return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

func classify(_ r: Int, _ g: Int, _ b: Int) -> String {
    if g > 180 && r < 90 && b < 90 { return "绿" }
    if r > 180 && b > 180 && g < 90 { return "洋红" }
    if r < 20 && g < 20 && b < 20 { return "黑" }
    return "其他(\(r),\(g),\(b))"
}

/// (x, y) 处的颜色，和整张图的黑像素比例（隔 16 像素取一个点）
func sample(_ img: CGImage, x: Int, y: Int) -> (color: String, black: Double) {
    let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
    func px(_ x: Int, _ y: Int) -> (Int, Int, Int) { let o = y * img.width * 4 + x * 4; return (Int(p[o]), Int(p[o + 1]), Int(p[o + 2])) }
    var black = 0, total = 0
    for yy in stride(from: 0, to: img.height, by: 16) {
        for xx in stride(from: 0, to: img.width, by: 16) {
            let (r, g, b) = px(xx, yy)
            total += 1
            if r < 8 && g < 8 && b < 8 { black += 1 }
        }
    }
    let (r, g, b) = px(min(max(x, 0), img.width - 1), min(max(y, 0), img.height - 1))
    return (classify(r, g, b), Double(black) / Double(total))
}

struct Shot { let sck: String, black: Double, cli: String, window: String }

@MainActor
func capture(_ targetID: CGWindowID) async throws -> Shot {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
    guard let tw = content.windows.first(where: { $0.windowID == targetID }),
          let d = content.displays.first(where: { $0.frame.contains(CGPoint(x: tw.frame.midX, y: tw.frame.midY)) })
    else { throw NSError(domain: "probe", code: 1, userInfo: [NSLocalizedDescriptionKey: "找不到目标窗口或它所在的屏"]) }
    let cfg = SCStreamConfiguration()
    cfg.width = d.width; cfg.height = d.height; cfg.showsCursor = false
    let full = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: d, excludingWindows: []), configuration: cfg)
    let sx = Double(full.width) / d.frame.width, sy = Double(full.height) / d.frame.height
    let s = sample(full, x: Int((tw.frame.midX - d.frame.minX) * sx), y: Int((tw.frame.midY - d.frame.minY) * sy))

    let wcfg = SCStreamConfiguration()
    wcfg.width = Int(tw.frame.width); wcfg.height = Int(tw.frame.height)
    let win = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: tw), configuration: wcfg)

    // screencapture 只截目标窗口那一块，拍不到别的内容；读完马上删
    let file = NSTemporaryDirectory() + "capture-probe-\(UUID().uuidString).png"
    let f = tw.frame
    let sc = Process()
    sc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    sc.arguments = ["-x", "-R\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width)),\(Int(f.height))", file]
    try sc.run(); sc.waitUntilExit()
    var cli = "失败"
    if let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: file) as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
        cli = sample(img, x: img.width / 2, y: img.height / 2).color
    }
    try? FileManager.default.removeItem(atPath: file)
    return Shot(sck: s.color, black: s.black, cli: cli, window: sample(win, x: win.width / 2, y: win.height / 2).color)
}

/// 和 OverlayController.buildWindow 一样的配置，只是没进 SkyLight 私有空间
func makeCurtain(_ frame: NSRect, alpha: CGFloat) -> NSWindow {
    let c = NSWindow(contentRect: frame, styleMask: [], backing: .buffered, defer: false)
    c.animationBehavior = .none
    c.backgroundColor = .black
    c.isOpaque = true
    c.alphaValue = alpha
    c.hasShadow = false
    c.ignoresMouseEvents = true
    c.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
    c.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenNone]
    c.sharingType = .none
    c.orderFrontRegardless()
    return c
}

/// WindowServer 记下的透明度（单精度），按窗口号或按进程名找
func windowServerAlphas(_ match: ([String: Any]) -> Bool) -> [String] {
    let all = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
    return all.filter(match).compactMap { ($0[kCGWindowAlpha as String] as? NSNumber)?.doubleValue }.map { String(format: "%.10f", $0) }
}

/// 一次试验：返回说明和是否透过去
@MainActor
func trial(alpha: CGFloat) async -> (String, Bool) {
    let lines = Lines()
    let child = Process()
    child.executableURL = URL(fileURLWithPath: args[0])
    child.arguments = ["target"]
    let pipe = Pipe()
    child.standardOutput = pipe
    pipe.fileHandleForReading.readabilityHandler = { h in
        if let s = String(data: h.availableData, encoding: .utf8) { lines.add(s) }
    }
    try! child.run()
    defer { child.terminate(); pipe.fileHandleForReading.readabilityHandler = nil }

    var targetID: CGWindowID = 0
    for _ in 0..<60 {
        if let r = lines.snapshot.first(where: { $0.hasPrefix("ready ") }) { targetID = CGWindowID(r.dropFirst(6))!; break }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    guard targetID != 0 else { return ("测试窗口没起来", false) }
    try? await Task.sleep(nanoseconds: 700_000_000)

    var curtain: NSWindow?
    let label: String
    if mode == "real" {
        _ = send("preview")
        try? await Task.sleep(nanoseconds: 400_000_000)
        let alphas = windowServerAlphas {
            ($0[kCGWindowOwnerName as String] as? String) == "LockCurtain" && (($0[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0) > 100
        }
        label = "真 App 预览遮罩，WindowServer 透明度 \(alphas)"
    } else {
        var frame = primaryFrame()
        if mode == "gap" { frame.size.width -= 1 }
        let c = makeCurtain(frame, alpha: alpha)
        curtain = c
        try? await Task.sleep(nanoseconds: 100_000_000)
        let ws = windowServerAlphas { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == c.windowNumber }.first ?? "?"
        label = String(format: "%@设 %.10f → WindowServer %@", mode == "gap" ? "[右边留 1px] " : "", Double(alpha), ws)
    }
    defer { curtain?.orderOut(nil) }
    let shownAt = lines.snapshot.count
    try? await Task.sleep(nanoseconds: 900_000_000)

    do {
        let before = try await capture(targetID)
        for _ in 0..<80 where !lines.snapshot.contains("magenta") { try? await Task.sleep(nanoseconds: 50_000_000) }
        try? await Task.sleep(nanoseconds: 800_000_000)
        let after = try await capture(targetID)
        var status = ""
        if mode == "real" {
            status = "\n    抓完时 status: " + send("status")   // 应该还是 preview：期间有人碰键鼠，遮罩会撤，这次作废
            _ = send("hide")
        }
        let visible = lines.snapshot.dropFirst(shownAt).last(where: { $0.hasPrefix("visible ") }).map { String($0.dropFirst(8)) } ?? "?"
        let ok = [before.sck, before.cli].allSatisfy { $0 == "绿" } && [after.sck, after.cli].allSatisfy { $0 == "洋红" } && visible == "true"
        func row(_ s: Shot) -> String { "SCK 整屏=\(s.sck)（黑 \(Int(s.black * 100))%）  screencapture=\(s.cli)  单窗口=\(s.window)" }
        return ("\(ok ? "✅" : "❌") \(label)  被盖住的窗口认为可见=\(visible)\n    变色前: \(row(before))\n    变色后: \(row(after))\(status)", ok)
    } catch {
        if mode == "real" { _ = send("hide") }
        return ("❌ \(label)  抓屏出错: \(error.localizedDescription)", false)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let candidates: [CGFloat] = mode == "sweep" ? [1.0, 0.999, 0.9999, 0.99999, 0.999999, CGFloat(Float(1).nextDown), 0.9999999999] : [1.0]
Task { @MainActor in
    var allOK = true
    for a in candidates {
        for _ in 0..<runs {
            let (text, ok) = await trial(alpha: a)
            print(text)
            allOK = allOK && ok
            try? await Task.sleep(nanoseconds: 600_000_000)
        }
    }
    // 只有 real 模式要求全部透过去；sweep 和 gap 本来就有预期不通过的档
    exit(mode == "real" && !allOK ? 1 : 0)
}
app.run()
