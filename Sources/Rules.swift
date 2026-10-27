// Rules.swift —— 自动进入离开模式的规则（纯数据 + 纯函数，不依赖 AppKit，方便单测）
//
// 一条规则 = 若干条件，全部满足才算命中；一个条件都没开的规则永远不命中。
// 命中后只做一件事：进入离开模式。条件结束时遮罩保持，等人回来碰一下再先锁屏后撤。
//
// 触发是「边沿」的：只在规则从不命中变成命中的那一刻触发一次。
// 如果按「命中就保持遮罩」做，「某 app 在运行」这类持续成立的条件会在人撤掉遮罩后立刻再次触发，
// 人就被锁在外面了。所以条件必须先变回不成立，规则才能再次触发。

import Foundation

struct TimeWindow: Codable, Equatable {
    /// 当天第几分钟，0...1439。start > end 表示跨午夜（如 23:00–07:00）
    var start: Int
    var end: Int
    /// Calendar 的 weekday：1 = 周日 … 7 = 周六。跨午夜的后半段按开始那天算
    var weekdays: Set<Int>

    static let `default` = TimeWindow(start: 23 * 60, end: 7 * 60, weekdays: Set(1...7))

    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        let c = calendar.dateComponents([.hour, .minute, .weekday], from: date)
        let minute = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        let today = c.weekday ?? 1
        let yesterday = today == 1 ? 7 : today - 1
        if start == end { return weekdays.contains(today) }             // 全天
        if start < end { return minute >= start && minute < end && weekdays.contains(today) }
        if minute >= start { return weekdays.contains(today) }           // 跨午夜的前半段
        if minute < end { return weekdays.contains(yesterday) }          // 跨午夜的后半段
        return false
    }
}

struct CurtainRule: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var enabled = true
    /// 空闲至少多少分钟；nil = 不限
    var idleMinutes: Int?
    /// 任一在运行即满足：app 的 bundle ID 或进程名（如 claude）；nil = 不限
    var processes: [String]?
    /// 有 app 在阻止睡眠：空数组 = 任意 app；否则列表里任一在阻止即满足（bundle ID 或进程名）；nil = 不限
    var sleepBlockers: [String]?
    /// nil = 不限
    var timeWindow: TimeWindow?
    var requireACPower = false

    var hasConditions: Bool {
        idleMinutes != nil || processes != nil || sleepBlockers != nil || timeWindow != nil || requireACPower
    }
}

/// 一次检查时采集到的系统状态
struct RuleFacts {
    var idleSeconds: Double
    /// 运行中的 app bundle ID 和进程名
    var running: Set<String>
    /// 在阻止睡眠的 app 的 bundle ID 和进程名，不含系统服务和 LockCurtain 自己
    var sleepBlockers: Set<String>
    var now: Date
    var onACPower: Bool
}

extension CurtainRule {
    func matches(_ f: RuleFacts, calendar: Calendar = .current) -> Bool {
        guard enabled, hasConditions else { return false }
        if let m = idleMinutes, f.idleSeconds < Double(m * 60) { return false }
        if let p = processes, !p.contains(where: { f.running.contains($0) }) { return false }
        if let b = sleepBlockers, b.isEmpty ? f.sleepBlockers.isEmpty : !b.contains(where: f.sleepBlockers.contains) {
            return false
        }
        if let w = timeWindow, !w.contains(f.now, calendar: calendar) { return false }
        if requireACPower, !f.onACPower { return false }
        return true
    }
}

/// 边沿检测：记住每条规则上一次是否命中，只在不命中 → 命中时报告
struct RuleTrigger {
    private var last: [UUID: (rule: CurtainRule, matching: Bool)] = [:]

    /// - frozen: 真实锁屏期间传 true，此时不更新状态也不触发。
    ///   否则锁屏让条件「变假」、解锁又「变真」，解锁那一刻就会触发离开模式，
    ///   人一碰又锁屏，绕成死循环
    /// - 返回本次刚命中的规则
    mutating func step(_ rules: [CurtainRule], _ facts: RuleFacts, frozen: Bool = false,
                       calendar: Calendar = .current) -> [CurtainRule] {
        guard !frozen else { return [] }
        var fired: [CurtainRule] = []
        var next: [UUID: (rule: CurtainRule, matching: Bool)] = [:]
        for r in rules {
            let now = r.matches(facts, calendar: calendar)
            // 新加的、刚改过的规则（含启动后第一次检查）视为「之前已命中」：
            // 否则在设置里改出一条正好成立的规则，下一次检查就会把正在改设置的人盖住
            if now, let prev = last[r.id], prev.rule == r, !prev.matching { fired.append(r) }
            next[r.id] = (r, now)
        }
        last = next
        return fired
    }
}
