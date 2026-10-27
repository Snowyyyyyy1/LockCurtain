# 合入记录

合入位置：`Sources/ScreenChangeCoalescer.swift`、`Sources/OverlayController.swift`，
自测移到 `Tests/ScreenChangeCoalescerSelfTest.swift`。本目录保留的是提案原版，和主干已不一致。

## 和提案不同的地方

| # | 提案 | 合入版 | 原因 |
|---|---|---|---|
| 1 | 只在重建后 `seed` | `show()` 建完窗口就 `seed` 当前布局 | 否则每次显示后第一批通知都和 `nil` 比，必判 `rebuilt`，「布局没变就跳过」在最常见的场景下不生效 |
| 2 | 重建走 `hide()` + `show()` | 新增 `rebuildWindows()`：先建新窗口再撤旧窗口，不经过 `hide()` | `hide()` 会撤掉全部窗口，离开模式下露出已解锁的桌面；还会释放再重申防休眠、恢复再调暗亮度、停掉再重启事件 tap |
| 3 | 先到先排：已有排期就丢弃后续通知 | 顺延：每次通知都把执行推迟到「这次 + delay」，只执行最后一次 | 布局分两步变化（先报默认位置、再应用排列）时，先到先排会重建两次。自测「以最后一次通知为准」对提案原版失败（实际 2 次），对合入版通过 |
| 4 | 阶段 2：`moved` 原地改 frame | 不做，`moved` 和 `rebuilt` 都走 `rebuildWindows()` | 第 2 点之后重建不再撤遮罩，原地更新的收益很小，还要维护窗口映射表 |

## 文档里过时的地方

`INTEGRATION.md` 的冲突说明提到 `previewing = false` 和 `PowerGuard.disengage()`：
主干里 `previewing` 已删除，`PowerGuard` 的方法叫 `release()`。

## 仍未验证

- 延迟 0.15 秒没有实测依据。日志 `screen layout ... rebuild windows (scheduled=... coalesced=...)` 会打出合并次数，插拔一次外接屏看实际情况再调。
  `measurement/DisplayBurstProbe.swift` 也能测：用程序切分辨率制造重配事件，打出每条通知的时间戳和间隔，跑完自动切回原分辨率
- 验收标准 2～4（插拔外接屏只出现一次重建日志、无变化时不重建、撤掉后再显示正常建窗）需要真机插拔
