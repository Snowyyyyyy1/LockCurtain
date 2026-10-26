// ScreenChangeCoalescer.swift
//
// 屏幕参数变化的合并器（debounce + 差异比对）。
//
// 背景
// ----
// NSApplication.didChangeScreenParametersNotification 在插拔显示器、改分辨率、
// 合盖、外接屏休眠时会连续发多次（常见 3~6 次）。每收到一次就 hide() + show()
// 的代价是：
//   1. 屏幕连闪好几下
//   2. 每块屏重新跑一遍 SCScreenshotManager 抓壁纸（几百毫秒）
//   3. 窗口反复上屏/拆除，压在它上面的 UI 跟着抖
//
// 这个类只做三件事：
//   1. 排期锁：已有排期时直接丢弃后续通知（coalesce）
//   2. 差异比对：延迟到期后先比对布局，没变就不执行
//   3. 分级动作：布局变了但显示器集合没变 → 可原地改 frame；否则整体重建
//
// 刻意不依赖 NSScreen / OverlayController，方便单测：
//   ScreenLayout 由调用方用纯数据构造，diff 是纯函数。

import CoreGraphics
import Foundation

/// 一次屏幕布局快照。只用值类型，便于比较和单测。
struct ScreenLayout: Equatable {
    struct Display: Equatable {
        let id: CGDirectDisplayID
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    /// 按 id 排序，保证同一物理布局的比较结果稳定
    let displays: [Display]

    init(displays: [Display]) {
        self.displays = displays.sorted { $0.id < $1.id }
    }

    var displayIDs: [CGDirectDisplayID] { displays.map { $0.id } }

    /// 显示器集合是否一致（不一致就必须重建窗口，不能原地改 frame）
    func hasSameDisplays(as other: ScreenLayout) -> Bool {
        displayIDs == other.displayIDs
    }
}

/// 合并结果
enum ScreenLayoutChange: Equatable {
    /// 没有变化，不需要做任何事
    case unchanged
    /// 显示器集合没变，只是位置/尺寸变了 —— 可以原地改 frame
    case moved(ScreenLayout)
    /// 显示器增减 —— 必须销毁重建
    case rebuilt(ScreenLayout)

    var layout: ScreenLayout? {
        switch self {
        case .unchanged: return nil
        case .moved(let l), .rebuilt(let l): return l
        }
    }
}

/// 纯函数：比较两次布局，给出该做什么
func classifyScreenLayout(from old: ScreenLayout?, to new: ScreenLayout) -> ScreenLayoutChange {
    guard let old else { return .rebuilt(new) }
    if old == new { return .unchanged }
    return old.hasSameDisplays(as: new) ? .moved(new) : .rebuilt(new)
}

@MainActor
final class ScreenChangeCoalescer {
    /// 延迟窗口。取值依据：
    ///   系统突发通知之间的间隔在几十毫秒量级，150ms 足以把它们收成一次，
    ///   又不会让用户察觉到遮罩跟不上。需要更激进/更保守可改构造参数。
    private let delay: TimeInterval

    /// 排期锁：true 表示已经有一个待执行的延迟任务
    private(set) var isScheduled = false

    /// 上一次真正应用过的布局，用来跳过无变化的通知
    private var lastApplied: ScreenLayout?

    private var generation = 0

    /// 统计信息，方便在日志里观察合并效果
    private(set) var coalescedCount = 0
    private(set) var performedCount = 0
    private(set) var skippedCount = 0

    init(delay: TimeInterval = 0.15) {
        self.delay = delay
    }

    /// 收到一次屏幕变化通知。
    ///
    /// - layoutProvider: 延迟到期后才调用，拿到那时最新的布局
    /// - perform: 需要执行动作时回调（不会回调 .unchanged）
    ///
    /// 返回 true 表示这次通知被排期，false 表示被合并丢弃。
    @discardableResult
    func notify(
        layoutProvider: @escaping @MainActor () -> ScreenLayout,
        perform: @escaping @MainActor (ScreenLayoutChange) -> Void
    ) -> Bool {
        if isScheduled {
            coalescedCount += 1
            return false
        }

        isScheduled = true
        generation += 1
        let myGeneration = generation

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == myGeneration else { return }
                self.isScheduled = false

                let change = classifyScreenLayout(from: self.lastApplied, to: layoutProvider())
                guard change != .unchanged else {
                    self.skippedCount += 1
                    return
                }
                self.lastApplied = change.layout
                self.performedCount += 1
                perform(change)
            }
        }
        return true
    }

    /// 遮罩撤掉后调用，清空基线。
    /// 不清的话，下次显示时会把「和上次一样」误判成 unchanged 而不建窗口。
    func reset() {
        lastApplied = nil
        generation += 1
        isScheduled = false
    }

    /// 主动注入基线（比如 show() 成功后把当前布局记为已应用）
    func seed(_ layout: ScreenLayout) {
        lastApplied = layout
    }

    var stats: String {
        var s = "scheduled="
        s += String(isScheduled)
        s += " coalesced="
        s += String(coalescedCount)
        s += " performed="
        s += String(performedCount)
        s += " skipped="
        s += String(skippedCount)
        return s
    }
}
