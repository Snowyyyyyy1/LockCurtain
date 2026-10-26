// ScreenChangeCoalescerSelfTest.swift —— 验证 Sources/ScreenChangeCoalescer.swift 的行为
//
// 单文件多文件混合编译时，顶层代码必须放在 main.swift 里。运行方式：
//
//   D=$TMPDIR/st; rm -rf $D && mkdir -p $D
//   cp Tests/ScreenChangeCoalescerSelfTest.swift $D/main.swift
//   cp Sources/ScreenChangeCoalescer.swift $D/
//   xcrun swiftc -o $D/selftest $D/main.swift $D/ScreenChangeCoalescer.swift
//   $D/selftest

import Foundation
import CoreGraphics

setvbuf(stdout, nil, _IONBF, 0)

var failures = 0
func check(_ cond: Bool, _ name: String) {
    print((cond ? "  OK   " : "  FAIL ") + name)
    if !cond { failures += 1 }
}

func layout(_ items: [(UInt32, Double, Double, Double, Double)]) -> ScreenLayout {
    ScreenLayout(displays: items.map {
        ScreenLayout.Display(id: $0.0, x: $0.1, y: $0.2, width: $0.3, height: $0.4)
    })
}

let one = layout([(1, 0, 0, 1728, 1117)])
let oneMoved = layout([(1, 100, 0, 1728, 1117)])
let oneResized = layout([(1, 0, 0, 1920, 1080)])
let two = layout([(1, 0, 0, 1728, 1117), (3, 1728, -570, 1920, 1080)])

print("== 纯函数 classifyScreenLayout ==")
check(classifyScreenLayout(from: nil, to: one) == .rebuilt(one), "首次 -> rebuilt")
check(classifyScreenLayout(from: one, to: one) == .unchanged, "完全相同 -> unchanged")
check(classifyScreenLayout(from: one, to: oneMoved) == .moved(oneMoved), "只移动 -> moved")
check(classifyScreenLayout(from: one, to: oneResized) == .moved(oneResized), "改分辨率 -> moved")
check(classifyScreenLayout(from: one, to: two) == .rebuilt(two), "增加显示器 -> rebuilt")
check(classifyScreenLayout(from: two, to: one) == .rebuilt(one), "移除显示器 -> rebuilt")

print("== 排序稳定性 ==")
let a = layout([(3, 1728, -570, 1920, 1080), (1, 0, 0, 1728, 1117)])
let b = layout([(1, 0, 0, 1728, 1117), (3, 1728, -570, 1920, 1080)])
check(a == b, "输入顺序不同但内容相同 -> 相等（按 id 排序）")

print("== 合并行为（异步）==")
let c = await MainActor.run { ScreenChangeCoalescer(delay: 0.08) }
var calls: [ScreenLayoutChange] = []

// 模拟一次插屏被系统连发 5 次
await MainActor.run {
    for _ in 0..<5 {
        c.notify(layoutProvider: { one }, perform: { calls.append($0) })
    }
}
let schedAfterBurst = await MainActor.run { c.isScheduled }
let coalesced = await MainActor.run { c.coalescedCount }
check(schedAfterBurst, "第一次就排期，锁已置位")
check(coalesced == 4, "后 4 次被合并（实际 " + String(coalesced) + "）")

try? await Task.sleep(nanoseconds: 250_000_000)
check(calls.count == 1, "5 次通知只执行 1 次（实际 " + String(calls.count) + "）")
check(calls.first == .rebuilt(one), "动作是 rebuilt")

// 再来一次相同布局 -> unchanged，不执行
calls.removeAll()
await MainActor.run { _ = c.notify(layoutProvider: { one }, perform: { calls.append($0) }) }
try? await Task.sleep(nanoseconds: 250_000_000)
check(calls.isEmpty, "布局没变 -> 不执行")
let skipped = await MainActor.run { c.skippedCount }
check(skipped == 1, "记为 skipped")

// reset 后同布局应重新触发
await MainActor.run { c.reset() }
calls.removeAll()
await MainActor.run { _ = c.notify(layoutProvider: { one }, perform: { calls.append($0) }) }
try? await Task.sleep(nanoseconds: 250_000_000)
check(calls.count == 1, "reset 后同布局会重新执行")

print("")
print(await MainActor.run { c.stats })

print("== 以最后一次通知为准 ==")
// 模拟插屏：系统先报新屏的默认位置（two），稍后再应用用户的排列（twoArranged）。
// 3 次通知间隔 50ms，各自都小于 delay（80ms），但总跨度 100ms 超过 delay。
// 先到先排的做法在 80ms 按中间状态 two 重建一次，100ms 布局又变，再重建一次，共 2 次；
// 顺延只在最后一次通知之后执行 1 次，直接用最终布局
let twoArranged = layout([(1, 0, 0, 1728, 1117), (3, -1920, 0, 1920, 1080)])
let d = await MainActor.run { ScreenChangeCoalescer(delay: 0.08) }
var current = one
calls.removeAll()
await MainActor.run { _ = d.notify(layoutProvider: { current }, perform: { calls.append($0) }) }
try? await Task.sleep(nanoseconds: 50_000_000)
current = two
await MainActor.run { _ = d.notify(layoutProvider: { current }, perform: { calls.append($0) }) }
try? await Task.sleep(nanoseconds: 50_000_000)
current = twoArranged
await MainActor.run { _ = d.notify(layoutProvider: { current }, perform: { calls.append($0) }) }
try? await Task.sleep(nanoseconds: 250_000_000)
check(calls.count == 1, "布局分两步变化的一串通知只执行 1 次（实际 " + String(calls.count) + "）")
check(calls.first == .rebuilt(twoArranged), "用的是最终布局")

print("== seed 基线 ==")
// show() 建完窗口会 seed 当前布局，之后同布局的通知应直接跳过
let e = await MainActor.run { ScreenChangeCoalescer(delay: 0.05) }
calls.removeAll()
await MainActor.run { e.seed(one); _ = e.notify(layoutProvider: { one }, perform: { calls.append($0) }) }
try? await Task.sleep(nanoseconds: 200_000_000)
check(calls.isEmpty, "seed 后同布局 -> 不执行")
await MainActor.run { _ = e.notify(layoutProvider: { oneMoved }, perform: { calls.append($0) }) }
try? await Task.sleep(nanoseconds: 200_000_000)
check(calls == [.moved(oneMoved)], "seed 后只移动 -> moved")

if failures == 0 { print("全部通过") } else { print(String(failures) + " 项失败") }
exit(failures == 0 ? 0 : 1)
