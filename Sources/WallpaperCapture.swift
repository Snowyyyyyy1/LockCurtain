// WallpaperCapture.swift
// 抓取每块屏幕当前的壁纸，供遮罩层做背景。
//
// 思路：macOS 的壁纸由系统进程用一个独立窗口绘制。直接截整屏会带上
// 所有前台窗口，所以这里只抓那个壁纸窗口本身，得到一张干净的原图。
//
// 三个要点：
//   1. 用 SCContentFilter(desktopIndependentWindow:) 只框住壁纸窗口
//   2. 坐标必须用 SCDisplay.frame 和 SCWindow.frame 比较，两者都是
//      CoreGraphics 坐标；NSScreen.frame 是 AppKit 坐标，副屏会差一个
//      主屏高度，永远匹配不上
//   3. 全程 async/await，绝不在主线程上阻塞等截图结果

import AppKit
import ScreenCaptureKit

actor WallpaperStore {
    static let shared = WallpaperStore()
    private var cache: [CGDirectDisplayID: CGImage] = [:]
    private var inflight: [CGDirectDisplayID: Task<CGImage?, Never>] = [:]

    func cached(_ id: CGDirectDisplayID) -> CGImage? { cache[id] }
    func store(_ id: CGDirectDisplayID, _ img: CGImage) { cache[id] = img }
    func invalidate() { cache.removeAll(); inflight.removeAll() }

    /// 每次都重新抓（壁纸可能已更换），不重复并发；
    /// 失败时退回上次的缓存，都没有返回 nil（调用方退回黑底）
    func image(for screen: NSScreen, content: SCShareableContent?, scale: CGFloat) async -> CGImage? {
        let id = screen.displayID
        if let t = inflight[id] { return await t.value ?? cache[id] }

        let task = Task<CGImage?, Never> { [weak self] in
            do {
                let c: SCShareableContent
                if let content { c = content }
                else { c = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
                let img = try await WallpaperCapture.shoot(content: c, displayID: id, scale: scale)
                await self?.store(id, img)
                return img
            } catch {
                NSLog("wallpaper fail display=%u: %@", id, String(describing: error))
                return nil
            }
        }
        inflight[id] = task
        let img = await task.value
        inflight[id] = nil
        return img ?? cache[id]
    }
}

enum WallpaperCapture {
    /// 核心：SCDisplay.frame ↔ SCWindow.frame（都是 CG 坐标）
    static func shoot(content: SCShareableContent,
                      displayID: CGDirectDisplayID,
                      scale: CGFloat) async throws -> CGImage {
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw NSError(domain: "LockCurtain", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "no SCDisplay \(displayID)"])
        }

        let wmBundles: Set<String> = ["com.apple.dock", "com.apple.WindowManager"]
        let hit = content.windows.first { w in
            guard let bid = w.owningApplication?.bundleIdentifier, wmBundles.contains(bid) else { return false }
            guard (w.title ?? "").hasPrefix("Wallpaper") else { return false }
            return w.frame.equalTo(display.frame)          // CG ↔ CG
        }
        guard let wp = hit else {
            throw NSError(domain: "LockCurtain", code: 2,
                          userInfo: [NSLocalizedDescriptionKey:
                            "no wallpaper window for display \(displayID) frame=\(display.frame)"])
        }

        let filter = SCContentFilter(desktopIndependentWindow: wp)

        let cfg = SCStreamConfiguration()
        cfg.showsCursor = false
        cfg.pixelFormat = 1111970369
        cfg.width = Int(display.frame.width * scale)
        cfg.height = Int(display.frame.height * scale)
        cfg.scalesToFit = false

        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
    }

    /// 抓单屏并写盘到 /tmp/lockcurtain-wallpaper-<idx>.png（供菜单用）
    @discardableResult
    static func captureOne(screen: NSScreen) async -> Bool {
        guard let img = await WallpaperStore.shared.image(for: screen, content: nil,
                                                          scale: screen.backingScaleFactor) else { return false }
        let idx = NSScreen.screens.firstIndex(of: screen) ?? 0
        let path = "/tmp/lockcurtain-wallpaper-menu-\(idx).png"
        if let d = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) {
            try? d.write(to: URL(fileURLWithPath: path))
            NSLog("saved %@ %dx%d", path, img.width, img.height)
            return true
        }
        return false
    }

    /// 异步抓所有屏幕，返回 [displayID: CGImage]
    static func prewarm(screens: [NSScreen]) async -> [CGDirectDisplayID: CGImage] {
        var out: [CGDirectDisplayID: CGImage] = [:]
        guard !screens.isEmpty else { return out }

        var content: SCShareableContent?
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            NSLog("prewarm: SCShareableContent failed %@", String(describing: error))
            return out
        }

        for s in screens {
            if let img = await WallpaperStore.shared.image(for: s, content: content, scale: s.backingScaleFactor) {
                out[s.displayID] = img
                NSLog("prewarm ok display=%u %dx%d", s.displayID, img.width, img.height)
            }
        }
        return out
    }

    /// 调试：三套坐标 + 匹配结果
    static func diagnose() async -> String {
        var s = ""
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            s += "SCDisplays:\n"
            for d in content.displays { s += "  id=\(d.displayID) frame=\(d.frame)\n" }
            s += "NSScreens:\n"
            for sc in NSScreen.screens { s += "  id=\(sc.displayID) frame=\(sc.frame)\n" }
            s += "Wallpaper windows:\n"
            for w in content.windows where (w.title ?? "").hasPrefix("Wallpaper") {
                s += "  winID=\(w.windowID) frame=\(w.frame)\n"
            }
            s += "匹配（SCDisplay ↔ SCWindow）:\n"
            for sc in NSScreen.screens {
                guard let d = content.displays.first(where: { $0.displayID == sc.displayID }) else {
                    s += "  id=\(sc.displayID) 无 SCDisplay\n"; continue
                }
                let m = content.windows.first { (($0.title ?? "").hasPrefix("Wallpaper")) && $0.frame.equalTo(d.frame) }
                s += "  id=\(sc.displayID) display=\(d.frame) -> \(m.map { "winID=\($0.windowID)" } ?? "无")\n"
            }
        } catch { s += "ERR \(error)" }
        return s
    }

    static func invalidate() async { await WallpaperStore.shared.invalidate() }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }
}
