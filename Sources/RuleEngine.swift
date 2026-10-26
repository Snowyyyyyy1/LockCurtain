// RuleEngine.swift —— 规则的存储、系统状态采集、定时检查
//
// 规则存在 ~/Library/Application Support/LockCurtain/rules.json，设置窗口改动后立即保存。
// 每 5 秒采集一次系统状态，交给 RuleTrigger 做边沿检测，命中就进入离开模式。

import AppKit
import Darwin
import IOKit.ps
import Combine

@MainActor
final class RuleStore: ObservableObject {
    @Published var rules: [CurtainRule] = [] {
        didSet { if rules != oldValue { save() } }
    }

    private static var url: URL { AppPaths.file("rules.json") }

    init() {
        guard let d = try? Data(contentsOf: Self.url) else { return }
        do { rules = try JSONDecoder().decode([CurtainRule].self, from: d) }
        catch { NSLog("rules.json 解析失败，按无规则处理: %@", "\(error)") }
    }

    private func save() {
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(rules).write(to: Self.url, options: .atomic)
        } catch { NSLog("rules.json 保存失败: %@", "\(error)") }
    }
}

enum SystemFacts {
    /// 进程列表要遍历全部 pid，只在有规则用到进程条件时才收集
    static func collect(processes: Bool) -> RuleFacts {
        RuleFacts(idleSeconds: idleSeconds(), running: processes ? running() : [], now: Date(), onACPower: onACPower())
    }

    /// 距上一次键盘/鼠标输入的秒数（kCGAnyInputEventType）
    static func idleSeconds() -> Double {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
    }

    /// 运行中 app 的 bundle ID，加上所有进程名（命令行工具没有 bundle ID）
    static func running() -> Set<String> {
        var s = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return s }
        var pids = [pid_t](repeating: 0, count: Int(n) + 32)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var name = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
        for pid in pids.prefix(Int(max(got, 0))) where pid > 0 {
            if proc_name(pid, &name, UInt32(name.count)) > 0 { s.insert(String(cString: name)) }
        }
        return s
    }

    static func onACPower() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return true }
        return (type as String) == kIOPMACPowerKey
    }
}

@MainActor
final class RuleEngine {
    let store: RuleStore
    private var trigger = RuleTrigger()
    private var timer: Timer?
    private let fire: (CurtainRule) -> Void

    init(store: RuleStore, fire: @escaping (CurtainRule) -> Void) {
        self.store = store
        self.fire = fire
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
    }

    private func tick() {
        guard store.rules.contains(where: \.enabled) else { trigger = RuleTrigger(); return }
        let facts = SystemFacts.collect(processes: store.rules.contains { $0.processes != nil })
        let fired = trigger.step(store.rules, facts, frozen: sessionLocked())
        if let r = fired.first {
            NSLog("rule fired: %@", r.name)
            fire(r)
        }
    }
}
