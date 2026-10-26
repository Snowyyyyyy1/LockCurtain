// SelfTest.swift —— 验证 ScreenChangeCoalescer 的行为
//
// 单文件多文件混合编译时，顶层代码必须放在 main.swift 里。运行方式：
//
//   rm -rf /tmp/st && mkdir -p /tmp/st
//   cp SelfTest.swift /tmp/st/main.swift
//   cp ScreenChangeCoalescer.swift /tmp/st/
//   cd /tmp/st && xcrun swiftc -o /tmp/selftest main.swift ScreenChangeCoalescer.swift
//   /tmp/selftest

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
await MainActor.run { c.notify(layoutProvider: { one }, perform: { calls.append($0) }) }
try? await Task.sleep(nanoseconds: 250_000_000)
check(calls.isEmpty, "布局没变 -> 不执行")
let skipped = await MainActor.run { c.skippedCount }
check(skipped == 1, "记为 skipped")

// reset 后同布局应重新触发
await MainActor.run { c.reset() }
calls.removeAll()
await MainActor.run { c.notify(layoutProvider: { one }, perform: { calls.append($0) }) }
try? await Task.sleep(nanoseconds: 250_000_000)
check(calls.count == 1, "reset 后同布局会重新执行")

print("")
print(await MainActor.run { c.stats })

if failures == 0 { print("全部通过") } else { print(String(failures) + " 项失败") }
exit(failures == 0 ? 0 : 1)
