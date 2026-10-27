// SleepBlockers.swift —— 谁在阻止睡眠：读系统的电源断言，分成「显示器」和「系统」两类
//
// IOPMCopyAssertionsByProcess 不需要任何权限，比 `pmset -g assertions` 多给 bundle 路径、
// 超时等字段（读法参考 mac-sleep-doctor 的 AssertionClient）。
//
// 列表规则（实测 2026-10-26，macOS 26）：
//   - 只看真正阻止睡眠的类型；「你在用电脑」（UserIsActive）、外接存储等不算
//   - 程序在 /System、/usr/sbin、/usr/libexec 等系统目录下的算系统服务（powerd、bluetoothd），
//     不逐个列出，只计数；/usr/bin 下的命令（caffeinate）是人自己跑的，照常列出
//   - 同一个程序同一类的多条断言合并成一行（同时跑 3 个 caffeinate 只显示一行）

import AppKit
import IOKit.pwr_mgt

enum SleepBlockKind: Int, Comparable {
    case display, system

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// 断言类型 → 阻止哪一类睡眠；nil = 不算阻止睡眠
    static func of(_ type: String) -> SleepBlockKind? {
        switch type {
        case "PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion", "InternalPreventDisplaySleep", "DisplayWake":
            .display
        case "PreventUserIdleSystemSleep", "PreventSystemSleep", "NoIdleSleepAssertion", "InternalPreventSleep",
             "CPUBoundAssertion":
            .system
        default:
            nil
        }
    }
}

struct SleepBlocker: Identifiable {
    let id: String
    let kind: SleepBlockKind
    /// 进程名；规则按它和 bundleID 匹配
    let processName: String
    let bundleID: String?
    /// app 用本地化名，命令行工具和后台进程用进程名
    let title: String
    /// 断言名，即程序报给系统的理由（如 "Electron"、"caffeinate command-line tool"）
    let reason: String
    let icon: NSImage
    let isSelf: Bool
}

struct SleepBlockersSnapshot {
    /// 系统服务以外的，显示器在前
    var rows: [SleepBlocker] = []
    /// 也在阻止睡眠的系统服务个数（按进程算）
    var systemServices = 0

    /// LockCurtain 自己以外的
    var others: [SleepBlocker] { rows.filter { !$0.isSelf } }

    /// 规则用：在阻止睡眠的 app 的 bundle ID 和进程名，不含系统服务和 LockCurtain 自己
    var identities: Set<String> {
        Set(others.flatMap { [$0.processName] + ($0.bundleID.map { [$0] } ?? []) })
    }
}

@MainActor
enum SleepBlockers {
    private nonisolated static let systemPrefixes = ["/System/", "/usr/sbin/", "/usr/libexec/", "/sbin/", "/Library/Apple/"]

    static func snapshot() -> SleepBlockersSnapshot {
        var unmanaged: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess,
              let byPID = unmanaged?.takeRetainedValue() as? [AnyHashable: Any] else { return SleepBlockersSnapshot() }

        var rows: [String: SleepBlocker] = [:]
        var services = Set<String>()
        let me = getpid()
        for (key, value) in byPID {
            for a in value as? [[String: Any]] ?? [] {
                guard (a["AssertLevel"] as? Int ?? 0) > 0,
                      let type = a["AssertType"] as? String, let kind = SleepBlockKind.of(type) else { continue }
                let pid = (a["AssertPID"] as? NSNumber)?.int32Value ?? (key as? NSNumber)?.int32Value ?? 0
                let name = a["Process Name"] as? String ?? "pid \(pid)"
                let path = ProcessTable.executablePath(pid)
                if let path, systemPrefixes.contains(where: path.hasPrefix) { services.insert(path); continue }

                let rowID = "\(kind.rawValue)|\(path ?? name)"
                guard rows[rowID] == nil else { continue }
                let app = NSRunningApplication(processIdentifier: pid)
                let bundle = appBundle(a["BundlePath"] as? String, path)
                rows[rowID] = SleepBlocker(
                    id: rowID, kind: kind, processName: name,
                    bundleID: app?.bundleIdentifier ?? bundle.flatMap { Bundle(path: $0)?.bundleIdentifier },
                    title: app?.localizedName ?? name,
                    reason: a["AssertName"] as? String ?? "",
                    icon: app?.icon ?? NSWorkspace.shared.icon(forFile: bundle ?? path ?? "/usr/bin/true"),
                    isSelf: pid == me)
            }
        }
        let sorted = rows.values.sorted {
            ($0.kind, $0.title.localizedLowercase) < ($1.kind, $1.title.localizedLowercase)
        }
        return SleepBlockersSnapshot(rows: sorted, systemServices: services.count)
    }

    /// 历史记录里的进程名 → 还在运行的 app 的名字和图标；找不到（命令行工具、已退出）就用进程名和通用图标
    static func display(processName name: String) -> (title: String, icon: NSImage) {
        let app = NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == name
                || $0.executableURL.map { pmsetName($0.lastPathComponent) } == name
        }
        return (app?.localizedName ?? name, app?.icon ?? NSWorkspace.shared.icon(forFile: "/usr/bin/true"))
    }

    /// 现在在跑的系统服务的进程名。历史记录只有进程名，靠它把系统服务和 app 分开；
    /// 已经退出的进程查不到路径，按 app 算
    nonisolated static func runningServiceNames() -> Set<String> {
        var names = Set<String>()
        for pid in ProcessTable.allPIDs() {
            // root 的进程 proc_name 读不到，路径读得到
            guard let path = ProcessTable.executablePath(pid), systemPrefixes.contains(where: path.hasPrefix) else { continue }
            let base = (path as NSString).lastPathComponent
            names.insert(base)
            names.insert(pmsetName(base))
        }
        return names
    }

    /// pmset 记的进程名最多 31 个字节
    private nonisolated static func pmsetName(_ s: String) -> String {
        String(decoding: s.utf8.prefix(31), as: UTF8.self)
    }

    /// 断言自带的 BundlePath 只认 .app（caffeinate 报的是 powerd.bundle）；没有就从可执行文件往上找 .app
    private static func appBundle(_ bundlePath: String?, _ path: String?) -> String? {
        if let b = bundlePath, b.hasSuffix(".app") { return b }
        guard let p = path, let r = p.range(of: ".app/") else { return nil }
        return String(p[..<r.lowerBound]) + ".app"
    }
}
