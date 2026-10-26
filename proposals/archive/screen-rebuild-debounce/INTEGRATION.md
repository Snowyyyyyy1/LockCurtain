# 集成步骤

只动 `Sources/OverlayController.swift`，分两阶段。
阶段 1 是纯防御性改动，风险低；阶段 2 可选，进一步减少闪烁。

## 前置

把 `ScreenChangeCoalescer.swift` 复制到 `Sources/`，并在 `build.sh` 的 `swiftc` 文件列表里加一行：

```diff
   "$SRC/CurtainCapture.swift" \
+  "$SRC/ScreenChangeCoalescer.swift"
```

## 阶段 1：合并 + 跳过无变化（最小改动）

### 改动 1：加合并器实例

在 `OverlayController` 属性区（`private let inputFilter = CurtainInputFilter()` 附近）加：

```swift
private let screenCoalescer = ScreenChangeCoalescer()
```

### 改动 2：替换 `rebuildIfShowing()`

**现在：**

```swift
private func rebuildIfShowing() {
    guard let m = mode else { return }
    NSLog("screen parameters changed, rebuild overlay")
    hide()
    show(m)
}
```

**改为：**

```swift
private func rebuildIfShowing() {
    guard mode != nil else { return }

    screenCoalescer.notify(
        layoutProvider: { Self.currentLayout() },
        perform: { [weak self] change in
            guard let self, let m = self.mode else { return }
            switch change {
            case .unchanged:
                return
            case .moved(let layout):
                NSLog("screen layout moved, updating in place");
                self.updateFramesInPlace(to: layout)   // 阶段 2 才实现
            case .rebuilt(let layout):
                NSLog("screen layout rebuilt, rebuilding overlay");
                self.hide()
                self.show(m)
                self.screenCoalescer.seed(layout)
            }
        }
    )
}

/// 用纯数据构造当前布局，方便比对
private static func currentLayout() -> ScreenLayout {
    ScreenLayout(displays: NSScreen.screens.map {
        ScreenLayout.Display(id: $0.displayID,
                             x: $0.frame.origin.x,
                             y: $0.frame.origin.y,
                             width: $0.frame.width,
                             height: $0.frame.height)
    })
}
```

### 改动 3：`hide()` 里清空基线

在 `hide()` 末尾（`mode = nil` 或 `windows.removeAll()` 之后）加一行：

```swift
screenCoalescer.reset()
```

**必须加。** 否则撤掉遮罩再显示时，`lastApplied` 还留着上次的布局，
会被判成 `unchanged` 从而一个窗口都不建。

### 改动 4（阶段 1 简化版）

如果暂时不想做阶段 2，把 `case .moved` 也走重建分支即可：

```swift
case .moved, .rebuilt:
    NSLog("screen layout changed, rebuilding overlay")
    self.hide()
    self.show(m)
    self.screenCoalescer.seed(Self.currentLayout())
```

这样就只剩「合并突发通知 + 跳过无变化」两个收益，但已经能消掉绝大部分闪烁。

---

## 阶段 2：原地改 frame（可选）

要原地更新，得知道每个窗口对应哪块屏。现在的 `windows: [NSWindow]` 是平铺数组，
靠顺序无法可靠反查，需要补一张映射表。

### 改动 5：记录窗口与显示器的对应关系

加属性：

```swift
private struct ScreenWindows {
    let main: NSWindow
    let edge: NSWindow?
}
private var windowMap: [CGDirectDisplayID: ScreenWindows] = [:]
```

在 `show(_:)` 的建窗循环里填表：

```swift
for screen in screens {
    let (win, layer) = buildWindow(for: screen)
    win.orderFrontRegardless()
    windows.append(win)
    wallpaperLayers[screen.displayID] = layer

    var edge: NSWindow?
    if stealthEnabled, let (e, elayer) = buildEdgeWindow(for: screen) {
        e.orderFrontRegardless()
        windows.append(e)
        edgeLayers[screen.displayID] = elayer
        edge = e
    }
    windowMap[screen.displayID] = ScreenWindows(main: win, edge: edge)
}
```

`hide()` 里 `windowMap.removeAll()`。

### 改动 6：实现 `updateFramesInPlace(to:)`

```swift
private func updateFramesInPlace(to layout: ScreenLayout) {
    for screen in NSScreen.screens {
        guard let pair = windowMap[screen.displayID] else { continue }
        let f = screen.frame

        var mainFrame = f
        if stealthEnabled { mainFrame.size.width -= 1 }
        if pair.main.frame != mainFrame {
            pair.main.setFrame(mainFrame, display: true)
        }

        if let edge = pair.edge {
            let ef = NSRect(x: f.origin.x + f.size.width - 1,
                            y: f.origin.y,
                            width: 1,
                            height: f.size.height - 1)
            if edge.frame != ef { edge.setFrame(ef, display: true) }
        }
    }
}
```

原地更新时壁纸层不用重抓（`wallpaperLayers` / `edgeLayers` 都还在）。
只有 `rebuilt` 分支才重新抓。

---

## 与现有代码的冲突点

1. **`show(_:)` 的签名**：当前是 `show(_ mode: CurtainMode)`，
   提案里按这个签名写。如果实际改过，按实际调整。

2. **`hide()` 现有结尾**：`hide()` 里已经有 `mode = nil`、`windows.removeAll()`、
   `wallpaperLayers.removeAll()`、`edgeLayers.removeAll()`、`previewing = false` 等清理，
   `screenCoalescer.reset()` 加在最后即可。

3. **`PowerGuard`**：如果 `PowerGuard` 在 `show()` 里会 `engage()`、`hide()` 里 `disengage()`，
   那么 `rebuilt` 路径会走一遍 disengage/engage。这是现有行为，本提案不改。
   如果在意，可以在 `rebuildIfShowing` 里跳过 `hide()` 直接重建窗口，但那是更大的改动，不在本提案范围。

4. **`ControlServer`**：如果它有暴露 `mode` / `windows` 状态的命令，
   建议在 `stats` 里加一行 `screenCoalescer.stats` 方便观察，非必需。

## 回滚

删掉 `screenCoalescer` 属性和 `currentLayout()`，把 `rebuildIfShowing()` 还原成原来的三行即可。
`ScreenChangeCoalescer.swift` 不参与任何其他调用，可以直接移除。

