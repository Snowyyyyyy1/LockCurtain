// IntervalSet.swift —— 时间区间代数（并、交、差、截取、合并近邻），睡眠统计的基础
//
// 移植自 mac-sleep-doctor 的 Sources/Core/Intervals.swift，行为与公开 API 保持一致。
//
// 为什么需要它：pmset 的断言记录是「快照」，每约 15 分钟报告一次且 duration 只增不减，
// 直接累加会严重重复计数。所以所有数字都要先取区间并集，再和统计窗口求交或截取。

import Foundation

/// 半开区间 `[start, end)`，单位是 Unix 时间戳（秒）。
struct Interval: Sendable, Hashable, Comparable {
    var start: Double
    var end: Double

    /// 起止颠倒时自动交换，不会产生负长度。
    init(_ start: Double, _ end: Double) {
        if start <= end {
            self.start = start
            self.end = end
        } else {
            self.start = end
            self.end = start
        }
    }

    init(from: Date, to: Date) {
        self.init(from.timeIntervalSince1970, to.timeIntervalSince1970)
    }

    var duration: Double { end - start }
    var isEmpty: Bool { end <= start }

    static func < (lhs: Interval, rhs: Interval) -> Bool {
        lhs.start == rhs.start ? lhs.end < rhs.end : lhs.start < rhs.start
    }

    /// 与 range 的交集；无交集返回 nil。
    func clamped(to range: Interval) -> Interval? {
        let s = Swift.max(start, range.start)
        let e = Swift.min(end, range.end)
        return e > s ? Interval(s, e) : nil
    }

    func shifted(by seconds: Double) -> Interval {
        Interval(start + seconds, end + seconds)
    }
}

/// 归一化的集合：互不重叠、按起点升序的区间列表。
struct IntervalSet: Sendable, Equatable {
    private(set) var intervals: [Interval]

    static let empty = IntervalSet([Interval]())

    init(_ raw: [Interval]) {
        intervals = Self.normalize(raw)
    }

    init(_ ranges: [(Double, Double)]) {
        self.init(ranges.map { Interval($0.0, $0.1) })
    }

    /// 丢弃空区间，排序后合并重叠和首尾相接的区间。
    private static func normalize(_ raw: [Interval]) -> [Interval] {
        let sorted = raw.filter { !$0.isEmpty }.sorted()
        guard var current = sorted.first else { return [] }
        var out: [Interval] = []
        for next in sorted.dropFirst() {
            if next.start <= current.end {
                if next.end > current.end { current.end = next.end }
            } else {
                out.append(current)
                current = next
            }
        }
        out.append(current)
        return out
    }

    var totalDuration: Double {
        intervals.reduce(0) { $0 + $1.duration }
    }

    var isEmpty: Bool { intervals.isEmpty }

    /// 与 other 的交集总长（同一段重叠只算一次）。
    func intersectionDuration(with other: IntervalSet) -> Double {
        var i = 0, j = 0, total = 0.0
        while i < intervals.count && j < other.intervals.count {
            let a = intervals[i], b = other.intervals[j]
            let lo = Swift.max(a.start, b.start)
            let hi = Swift.min(a.end, b.end)
            if hi > lo { total += hi - lo }
            if a.end < b.end { i += 1 } else { j += 1 }
        }
        return total
    }

    func union(with other: IntervalSet) -> IntervalSet {
        IntervalSet(intervals + other.intervals)
    }

    /// 差集 `self - other`（两边都已归一化）。
    func subtracting(_ other: IntervalSet) -> IntervalSet {
        guard !other.isEmpty else { return self }
        var out: [Interval] = []
        for a in intervals {
            var cursor = a.start
            for b in other.intervals {
                if b.end <= cursor { continue }
                if b.start >= a.end { break }
                if b.start > cursor {
                    out.append(Interval(cursor, Swift.min(b.start, a.end)))
                }
                cursor = Swift.max(cursor, b.end)
                if cursor >= a.end { break }
            }
            if cursor < a.end { out.append(Interval(cursor, a.end)) }
        }
        return IntervalSet(out)
    }

    /// 交集（返回重叠的各段）。
    func intersecting(_ other: IntervalSet) -> IntervalSet {
        var out: [Interval] = []
        var i = 0, j = 0
        while i < intervals.count && j < other.intervals.count {
            let a = intervals[i], b = other.intervals[j]
            let lo = Swift.max(a.start, b.start)
            let hi = Swift.min(a.end, b.end)
            if hi > lo { out.append(Interval(lo, hi)) }
            if a.end < b.end { i += 1 } else { j += 1 }
        }
        return IntervalSet(out)
    }

    func clamped(to range: Interval) -> IntervalSet {
        IntervalSet(intervals.compactMap { $0.clamped(to: range) })
    }

    /// 集合占 range 的比例，范围 0...1。
    func coverage(of range: Interval) -> Double {
        guard range.duration > 0 else { return 0 }
        return clamped(to: range).totalDuration / range.duration
    }

    /// 合并间隔小于 gap 秒的相邻区间，避免时间线上出现细碎的线段。
    func coalescing(gap: Double) -> IntervalSet {
        guard gap > 0 else { return self }
        var out: [Interval] = []
        for iv in intervals {
            if let last = out.last, iv.start - last.end <= gap {
                out[out.count - 1].end = Swift.max(last.end, iv.end)
            } else {
                out.append(iv)
            }
        }
        return IntervalSet(out)
    }
}

extension Interval {
    /// 截至 now 的最近 days 天。
    static func trailing(days: Int, endingAt now: Date) -> Interval {
        Interval(
            now.addingTimeInterval(-Double(days) * 86_400).timeIntervalSince1970,
            now.timeIntervalSince1970
        )
    }
}
