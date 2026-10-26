# 提案：屏幕参数变化的合并处理（debounce + 差异比对）

状态：**待评审**。本目录是独立提案，不改动 `Sources/` 下任何现有文件。

## 问题

`Sources/OverlayController.swift` 现在收到屏幕变化就立刻重建：

```swift
private func rebuildIfShowing() {
    guard let m = mode else { return }
    NSLog("screen parameters changed, rebuild overlay")
    hide()
    show(m)
}
```

`NSApplication.didChangeScreenParametersNotification` 在插拔显示器、改分辨率、
合盖、外接屏休眠时会**连续发多次**。每收到一次就 `hide() + show()` 的代价：

1. 屏幕连闪好几下（窗口反复销毁重建）
2. 每块屏重新跑一遍 `SCScreenshotManager` 抓壁纸，几百毫秒
3. 压在遮罩上面的 UI 跟着抖

## 参考实现

同机安装的 UU远程 4.43.0 在 `UURemoteServer` 里解决了同一个问题，
日志字符串按执行流排列：

```
screen parameters notification received, isMainThread=
screen parameters change already scheduled, coalescing   ← 已有排期，丢弃本次
screen parameters change scheduled                       ← 第一次，排延迟任务

（延迟到期后）
screen parameters unchanged, skip rebuilding overlay     ← 比对后跳过
screen parameters changed, rebuilding overlay            ← 需要重建
screen parameters changed, updated overlay in place      ← 只改 frame
```

对应一个布尔排期锁（`strb w8, [x0, #0x19]` 置位 / `strb wzr` 清除）。

我们的方案沿用同一套结构，但拆成可单测的纯函数 + 一个合并器。

## 交付物

| 文件 | 说明 |
|---|---|
| `ScreenChangeCoalescer.swift` | 合并器本体，不依赖 `NSScreen` / `OverlayController` |
| `SelfTest.swift` | 15 项行为验证，可独立运行 |
| `INTEGRATION.md` | 精确改动点，分两阶段 |

## 设计要点

**1. 排期锁**

```swift
if isScheduled { coalescedCount += 1; return false }
isScheduled = true
DispatchQueue.main.asyncAfter(deadline: .now() + delay) { ... }
```

突发通知只留第一次，其余丢弃。

**2. 延迟后取最新布局**

`layoutProvider` 在延迟**到期后**才调用，拿到的是那一刻的真实布局。
这样中间又插了一块屏也能被包含进来，不会用过期快照。

**3. 差异比对**

```swift
enum ScreenLayoutChange { case unchanged, moved(ScreenLayout), rebuilt(ScreenLayout) }
```

- `unchanged` → 什么都不做（系统有时会在布局没变时也发通知）
- `moved` → 显示器集合没变，只改了位置/尺寸，可以原地改 frame
- `rebuilt` → 显示器增减，必须销毁重建

**4. generation 防陈旧回调**

`reset()` 会递增 `generation`，让已经排期的旧回调自动失效，
避免遮罩撤掉后又被一个迟到的回调重建出来。

## 验证

```bash
rm -rf /tmp/st && mkdir -p /tmp/st
cp SelfTest.swift /tmp/st/main.swift
cp ScreenChangeCoalescer.swift /tmp/st/
cd /tmp/st && xcrun swiftc -o /tmp/selftest main.swift ScreenChangeCoalescer.swift
/tmp/selftest
```

实测输出：

```
== 纯函数 classifyScreenLayout ==
  OK   首次 -> rebuilt
  OK   完全相同 -> unchanged
  OK   只移动 -> moved
  OK   改分辨率 -> moved
  OK   增加显示器 -> rebuilt
  OK   移除显示器 -> rebuilt
== 排序稳定性 ==
  OK   输入顺序不同但内容相同 -> 相等（按 id 排序）
== 合并行为（异步）==
  OK   第一次就排期，锁已置位
  OK   后 4 次被合并（实际 4）
  OK   5 次通知只执行 1 次（实际 1）
  OK   动作是 rebuilt
  OK   布局没变 -> 不执行
  OK   记为 skipped
  OK   reset 后同布局会重新执行

scheduled=false coalesced=4 performed=2 skipped=1
全部通过
```

## 延迟取值

默认 `0.15` 秒。依据是系统突发通知的间隔在几十毫秒量级，150ms 足够收成一次，
又不至于让用户觉得遮罩跟不上。

**这个数值没有实测支撑**，是估值。UU远程用的具体毫秒数也没从反汇编里定出来
（`DispatchTime` 值通过寄存器传入，常量在别处计算）。
建议上线前实测一次：把 `NSLog` 打上时间戳，插拔一次显示器看实际间隔，按需调整。

## 验收标准

1. `SelfTest` 全部通过
2. 遮罩显示时插拔一次外接屏，控制台只出现**一条** `screen layout changed` 日志
3. 屏幕没变化时收到通知，不产生任何 `hide/show` 调用
4. 撤掉遮罩后再显示，窗口正常建出来（验证 `reset()` 生效）

