// CurtainCapture.swift —— 抓「遮罩底下」的真实桌面
//
// 默认 stealth 模式下遮罩对抓屏透明，直接抓整屏就是真实桌面，用不到这里。
// 关闭 stealth（--no-stealth）后，遮罩是一层不透明的全屏窗口
// （level = CGShieldingWindowLevel()+1），直接抓整屏只会得到遮罩本身。
// 要拿到真实内容，必须在 SCContentFilter 里用 excludingWindows 把遮罩窗口排除掉。
//
// 抓法对比（--no-stealth 时）：
//   不排除窗口      → 截到遮罩（壁纸 + 图案 + 文案）
//   显式排除遮罩窗口 → 截到真实桌面（前台窗口、菜单栏、Dock 全部正常）
//
// 遮罩会把自己的 windowID 写进 ~/Library/Application Support/LockCurtain/overlay.json，
// 任何外部工具都可以读它来构造排除列表。下面的函数编译在本 App 内，
// 外部工具调不到，作为参考实现照抄即可。

import Foundation
import CoreGraphics
import AppKit
import ScreenCaptureKit

struct CurtainInfo: Codable {
    let pid: Int32
    let windowIDs: [UInt32]
    let updatedAt: Date
}

/// 运行时文件放在当前用户的 ~/Library/Application Support/LockCurtain/ 下，不放 /tmp：
/// /tmp 所有用户共享，别的用户能往里写豁免 pid、伪造 overlay.json
enum AppPaths {
    static let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("LockCurtain", isDirectory: true)

    static func file(_ name: String) -> URL {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }
}

enum CurtainInfoFile {
    static var url: URL { AppPaths.file("overlay.json") }

    static func write(pid: Int32, windowIDs: [UInt32]) {
        let info = CurtainInfo(pid: pid, windowIDs: windowIDs, updatedAt: Date())
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        enc.dateEncodingStrategy = .iso8601
        if let d = try? enc.encode(info) { try? d.write(to: url) }
    }

    static func read() -> CurtainInfo? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(CurtainInfo.self, from: d)
    }

    static func clear() { try? FileManager.default.removeItem(at: url) }
}

enum CurtainCapture {
    /// 抓整屏，自动排除遮罩窗口。这是给 agent / cua-driver 用的正确入口。
    static func displayExcludingCurtain(displayID: CGDirectDisplayID? = nil,
                                        scale: CGFloat = 2.0) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let targetID = displayID ?? CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == targetID }) else {
            throw NSError(domain: "CurtainCapture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "no SCDisplay \(targetID)"])
        }

        // 从两个来源合并遮罩窗口：info 文件 + 按 bundle id 反查
        var excludeIDs = Set<UInt32>(CurtainInfoFile.read()?.windowIDs ?? [])
        for w in content.windows where (w.owningApplication?.bundleIdentifier ?? "") == "dev.local.lockcurtain" {
            excludeIDs.insert(w.windowID)
        }
        let exclude = content.windows.filter { excludeIDs.contains($0.windowID) }

        let filter = SCContentFilter(display: display, excludingWindows: exclude)

        let cfg = SCStreamConfiguration()
        cfg.showsCursor = false
        cfg.pixelFormat = 1111970369
        cfg.width = Int(display.frame.width * scale)
        cfg.height = Int(display.frame.height * scale)
        cfg.scalesToFit = false

        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
    }
}
