// DisplayBurstProbe.swift —— 实测屏幕参数变化通知的突发间隔
//
// 目的：给 ScreenChangeCoalescer 的 debounce 延迟找实测依据。
//
// 方法：
//   1. 同时挂三条来源，看它们各自发几次、什么顺序：
//      a) CGDisplayRegisterReconfigurationCallback  (begin/end 成对，信息最全)
//      b) NSApplication.didChangeScreenParametersNotification
//      c) NSScreen 布局快照（判断是不是真有变化）
//   2. 用程序切分辨率制造真实的系统重配事件，每轮切走再切回 = 两次突发
//   3. 记录每个事件的高精度时间戳，算间隔
//
// 全程不依赖外部操作，跑完自动恢复原分辨率。
//
// 编译运行：
//   xcrun swiftc -O -o /tmp/dbp DisplayBurstProbe.swift && /tmp/dbp

import AppKit
import CoreGraphics
import QuartzCore

setvbuf(stdout, nil, _IONBF, 0)

let t0 = CACurrentMediaTime()
func now() -> Double { CACurrentMediaTime() - t0 }
func ms(_ v: Double) -> String { String(format: "%.1f", v * 1000) }

struct Ev {
    let t: Double
    let src: String
    let detail: String
    let sig: String
}
var events: [Ev] = []
let lock = NSLock()

func layoutSig() -> String {
    NSScreen.screens
        .map { s -> String in
            let id = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            let f = s.frame
            return String(format: "%u:%d,%d,%dx%d", id,
                          Int(f.origin.x), Int(f.origin.y), Int(f.width), Int(f.height))
        }
        .sorted()
        .joined(separator: "|")
}

func record(_ src: String, _ detail: String) {
    let e = Ev(t: now(), src: src, detail: detail, sig: layoutSig())
    lock.lock(); events.append(e); lock.unlock()
    print(String(format: "[%8s ms] %-14s %-22s %s",
                 (ms(e.t) as NSString).utf8String!, (src as NSString).utf8String!,
                 (detail as NSString).utf8String!, (e.sig as NSString).utf8String!))
}

// ---- 来源 a: CGDisplay 重配回调 ----
let cgCb: CGDisplayReconfigurationCallBack = { _, flags, _ in
    let f = flags.rawValue
    let begin = (f & CGDisplayChangeSummaryFlags.beginConfigurationFlag.rawValue) != 0
    var names: [String] = []
    if begin { names.append("BEGIN") } else { names.append("END") }
    if (f & CGDisplayChangeSummaryFlags.addFlag.rawValue) != 0 { names.append("ADD") }
    if (f & CGDisplayChangeSummaryFlags.removeFlag.rawValue) != 0 { names.append("REMOVE") }
    if (f & CGDisplayChangeSummaryFlags.movedFlag.rawValue) != 0 { names.append("MOVED") }
    if (f & CGDisplayChangeSummaryFlags.setMainFlag.rawValue) != 0 { names.append("SETMAIN") }
    if (f & CGDisplayChangeSummaryFlags.setModeFlag.rawValue) != 0 { names.append("SETMODE") }
    if (f & CGDisplayChangeSummaryFlags.desktopShapeChangedFlag.rawValue) != 0 { names.append("SHAPE") }
    if (f & CGDisplayChangeSummaryFlags.mirrorFlag.rawValue) != 0 { names.append("MIRROR") }
    record("CGDisplay", names.isEmpty ? String(format: "flags=0x%x", f) : names.joined(separator: "+"))
}
CGDisplayRegisterReconfigurationCallback(cgCb, nil)

// ---- 来源 b: AppKit 通知 ----
// 必须先有 NSApplication 实例，否则 AppKit 不会向本进程投递这个通知。
// 用 shared 而不是 run，避免阻塞；我们只在主线程上 sleep，主队列照样能派发。
_ = NSApplication.shared
let center = NotificationCenter.default
let obs = center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                              object: nil, queue: nil) { _ in
    record("AppKit.notif", "didChangeScreenParameters")
}

// ---- 切分辨率 ----
func currentMode(_ d: CGDirectDisplayID) -> CGDisplayMode? { CGDisplayCopyDisplayMode(d) }

func pickAlternate(_ d: CGDirectDisplayID, _ cur: CGDisplayMode) -> CGDisplayMode? {
    let opts = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
    guard let all = CGDisplayCopyAllDisplayModes(d, opts) as? [CGDisplayMode] else { return nil }
    // 找一个尺寸明显不同、且像素数更小的模式
    let targetPixels = cur.pixelWidth * cur.pixelHeight
    return all.filter { m in
        let px = m.pixelWidth * m.pixelHeight
        return px < targetPixels && px > targetPixels / 3
    }.max(by: { $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight })
}

func setMode(_ d: CGDirectDisplayID, _ m: CGDisplayMode) -> Bool {
    var cfg: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&cfg) == .success, let cfg else { return false }
    CGConfigureDisplayWithDisplayMode(cfg, d, m, nil)
    return CGCompleteDisplayConfiguration(cfg, .forSession) == .success

}

let mainID = CGMainDisplayID()
guard let orig = currentMode(mainID) else { print("拿不到当前模式"); exit(1) }
print("当前: \(orig.pixelWidth)x\(orig.pixelHeight)")
guard let alt = pickAlternate(mainID, orig) else { print("找不到可切换的模式"); exit(1) }
print("备用: \(alt.pixelWidth)x\(alt.pixelHeight)")

func restore() {
    _ = setMode(mainID, orig)
}


print("");
print("=== 开始，共 3 轮（切走 + 切回 = 6 次突发）===")
print("")

for round in 1...3 {
    print("--- 第 \(round) 轮：切到 \(alt.pixelWidth)x\(alt.pixelHeight) ---")
    record("TEST", "switch-begin #\(round)")
    _ = setMode(mainID, alt)
    Thread.sleep(forTimeInterval: 1.5)

    print("--- 第 \(round) 轮：切回 \(orig.pixelWidth)x\(orig.pixelHeight) ---")
    record("TEST", "restore-begin #\(round)")
    _ = setMode(mainID, orig)
    Thread.sleep(forTimeInterval: 1.5)
    print("")
}

Thread.sleep(forTimeInterval: 1.0)
center.removeObserver(obs)
CGDisplayRemoveReconfigurationCallback(cgCb, nil)

// ---- 导出（分析交给外部脚本，避免在本进程里做复杂处理）----
let out = "/tmp/display-burst.csv"
var csv = "t_sec,source,detail,layout" + String(Character(UnicodeScalar(10)))
for e in events {
    csv += String(format: "%.6f", e.t)
    csv += ","
    csv += e.src
    csv += ","
    csv += e.detail
    csv += ","
    csv += e.sig
    csv += String(Character(UnicodeScalar(10)))
}
do {
    try csv.write(toFile: out, atomically: true, encoding: .utf8)
    print("原始数据: " + out + "  事件数=" + String(events.count))
} catch {
    print("写 CSV 失败: " + String(describing: error))
}

// 收尾：恢复原分辨率
restore()
print("已恢复原分辨率")
