# LockCurtain iPhone — 设计规格 v2（原生版）

2026-11-02 · Colo · 取代 v1（星空深色版，不再使用）
依据：用户 msg555「我需要原生感的 app」；Ato msg557（只留一处记号）；Camo copy v5 §0.5（字一律以 copy v5 为准，本文引用的字如有出入，以 copy 为准）。
小样：artifact D997FBB3-06E0-400B-8FF8-18B43F491E02

## 0. 总原则
- 全部用系统组件和系统样式，不自定义背景、字体、卡片、按钮形状。iOS 26 起的 Liquid Glass 工具栏/按钮由系统自动给，不手绘。
- 跟随系统深浅色，不锁 colorScheme。不写任何硬编码的背景/文字色。
- 颜色：tint = 系统默认 `.accentColor`（不设 AccentColor 资源，即系统蓝）。唯一的品牌色是状态眼的橙 `#FF8A1F`（深浅色同值），只在“幕布 · 已盖上 / 正在盖上…”时出现。
- 字体：系统 Dynamic Type 文本样式，不指定字号；支持到 AX5。
- 状态永远有字。眼睛只是加强，不能单靠颜色表达状态。

## 1. 结构 / 导航
```
WindowGroup
 └ RootView
    ├ 未配对且非演示 → OnboardingView（§4）
    └ 其余 → NavigationStack { HomeView }
         toolbar 右上 Button(gearshape) → .sheet SettingsView（NavigationStack 包着，detents 默认 = large）
```
- 设置用 sheet（不是 push）。sheet 内导航栏左上 `Button(role: .close)`（iOS 26 系统 ✕；iOS 18 用 `Button("完成")` 放 `.confirmationAction`）。
- 主屏“自动”那一行点击 = 打开同一个设置 sheet。
- 配对用 `.sheet`（§5），从 Onboarding 的“去配对”或设置里“配对”打开。

## 2. 主屏 HomeView
```swift
List {
  Section {
    LabeledContent { Text(curtainValue) } label: { Label { Text("幕布") } icon: { StatusEye(state) } }
    LabeledContent { Text(macValue) }     label: { Label("这台 Mac", systemImage: "laptopcomputer") }
    Button { showSettings = true } label: {
      LabeledContent { Text(autoValue) } label: { Label("自动", systemImage: "figure.walk") }
    }
  } footer: { footerText }
}
.listStyle(.insetGrouped)
.navigationTitle("LockCurtain")
.navigationBarTitleDisplayMode(.large)
.toolbar { ToolbarItem(placement: .topBarTrailing) { Button("设置", systemImage: "gearshape") { … } } }
.safeAreaInset(edge: .bottom) { CoverButton }
```
- 行图标：系统 `Label` 默认样式（单色 tint 符号），不加彩色圆角底。
- CoverButton：
  ```swift
  Button { cover() } label: { Label("盖上幕布", systemImage: "curtains.closed").frame(maxWidth: .infinity) }
    .buttonStyle(.borderedProminent).controlSize(.large)
    .padding(.horizontal, 20).padding(.bottom, 8)
  ```
- 按下：`.sensoryFeedback(.impact(weight: .medium), trigger:)`；Mac 回执“已盖上”时 `.success`；超时 `.warning`。

### 2.1 状态表（值都来自 Mac 回报）
| 情况 | 幕布值 | 眼睛 | 这台 Mac 值 | 底部按钮 | 分组 footer |
|---|---|---|---|---|---|
| 没盖上 | 没盖上 | off | 已连接 | 盖上幕布（可用） | 无 |
| 正在盖上 | 正在盖上… | pending | 已连接 | 盖上幕布 disabled，label 换成 `ProgressView()` + 文字 | 无 |
| 5 秒没回执 | 没盖上（退回 Mac 最后报的值） | off | 已连接 | 盖上幕布（可用） | “Mac 没有回应，状态没变。” + 行内 `Button("再试一次")`（.borderless） |
| 已盖上 | 已盖上 | on | 已连接 | 不显示 | “回到 Mac 前按任意键解锁。手机上不能撤下幕布。” |
| 没连上 / Mac 不在线 / 蓝牙关了 | —（secondary） | off（0.4 透明） | 没连上 / Mac 不在线 / 蓝牙关了 | 不显示 | copy v5 §2 对应副句一句 |
| 没配对（撤销后） | — | off | 没配对 | `Button("去配对")` borderedProminent large | “在 Mac 上打开 LockCurtain，点「配对手机」，把 6 位码输进来。” |
- “自动”值：开着 / 关 / 关（只能手动）。阈值字等实测后 Camo 给，现在不写。
- 不显示任何 RSSI / 米数。

### 2.2 StatusEye（唯一自定义视图）
- 尺寸：`@ScaledMetric(relativeTo: .body) var d = 22`。
- off：`Circle().strokeBorder(.tertiary, lineWidth: 2)` + 中心 `Circle().fill(.tertiary).frame(d*0.36)`。
- pending：同 off 结构，颜色改 `#FF8A1F` 透明度 0.75；`.opacity` 在 0.45↔1.0 间 `.easeInOut(duration: 0.9).repeatForever()`；Reduce Motion 时不动，固定 0.75。
- on：`Circle().fill(#FF8A1F)` + 内圈 `Circle().strokeBorder(0xE06A00, lineWidth: d*0.07)` + 瞳孔 `Circle().fill(0x1A0E00).frame(d*0.3)` + `.shadow(color: #FF8A1F.opacity(0.45), radius: 6)`。
- off→on：`.animation(.snappy(duration: 0.25))`，只动颜色与阴影，不缩放。
- `.accessibilityHidden(true)`；整行由 LabeledContent 读“幕布，已盖上”。

## 3. 设置 SettingsView（sheet）
```swift
NavigationStack {
  Form {
    Section("这台 Mac") {
      LabeledContent("已配对", value: macName)
      Button("撤销配对", role: .destructive) { confirm = true }
    }
    Section {
      Toggle("走远自动盖上", isOn: $auto)
      Picker("灵敏度", selection: $sens) { 近一点 / 标准 / 远一点 }
      Picker("离开后等", selection: $delay) { 立刻 / 15 秒 / 30 秒 / 1 分钟 }
    } header: { Text("自动") } footer: { Text("只有走远会盖。回来不会自动撤。") }
    Section {
      Toggle("演示模式", isOn: $demo)
    } header: { Text("演示") } footer: { Text("不连 Mac，也能看到连上、盖上是什么样。") }
    Section("关于") { LabeledContent("版本", value: appVersion) }
    Section { MadeWithAirBuild() }
  }
  .navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
}
```
- 撤销确认：`.confirmationDialog("撤销这台手机的配对？", isPresented:, titleVisibility: .visible)`，message “以后要重新配对才能控制这台 Mac。”，按钮 `Button("撤销", role: .destructive)`。
- 定位没给“始终”时：自动分组里 Toggle 置关且 disabled，下面加 `LabeledContent("定位", value: "使用期间"/"不允许")`，footer 换 copy v5 §3 那句 + `Button("前往“设置”")`。
- 灵敏度/离开后等：自动关时 disabled。
- 没配对时，“这台 Mac”分组换成一行 `Button("配对")`。
- 高级排查：本版不放；实现上保留“关于”下的 `NavigationLink("排查信息")` → 现有蓝牙探针屏（开发验证用，蓝牙验过即收）。

## 4. 第一次打开 OnboardingView
- `VStack` 居中；`Image(systemName: "laptopcomputer.and.iphone")` `.font(.system(size: 64))` `.foregroundStyle(.tint)` `.symbolRenderingMode(.hierarchical)`；标题 `.largeTitle.bold()` 居中“先和你的 Mac 连上”；说明 `.body` `.secondary` 居中，水平 padding 32。
- 底部 `.safeAreaInset(edge: .bottom)`：`Button("去配对")` borderedProminent large 全宽；下方 `Button("手上没有 Mac？先看看演示")` `.borderless`，间距 16，底 padding 8。
- 进入此页不弹蓝牙；点“去配对”才初始化 CBCentralManager。
- 从演示退出回到此页：`.safeAreaInset(edge: .top)` 提示 `Text("演示已退出，这里还是没连上 Mac")` `.subheadline` `.regularMaterial` capsule，3 秒后淡出。

## 5. 配对 PairingSheet
- `.sheet` + `NavigationStack`，标题“配对” inline，左上 `Button(role: .close)`。`.presentationDetents([.large])`。
- 三步同一 sheet（`.contentTransition(.opacity)`，不 push）：
  1. 找这台 Mac…：`ProgressView()` + `.title2.bold` + secondary 副句。
  2. 输 6 位码：`.title2.bold` + secondary “Mac 上显示的那 6 个数字”；6 格 `RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemGroupedBackground))` 46×58pt，间距 8，数字 `.title.monospacedDigit().weight(.semibold)`；当前格 `strokeBorder(.tint, 2)`。隐藏 `TextField` `.keyboardType(.numberPad)` `.textContentType(.oneTimeCode)`，输满 6 位自动提交。背景 `Color(.systemGroupedBackground)`。
  3. 配对好了：`checkmark.circle.fill` 56pt `.green` + `.title2.bold` + 副句；底部 `Button("完成")` borderedProminent large；`.success`。
- 码错：格子清空，`.error` + 水平抖动 3 次（Reduce Motion 不抖），下面红字“码不对，再看一眼 Mac 上那 6 位。”

## 6. 演示模式
- 主屏与真实主屏同一个 HomeView，数据源换成 DemoSource（不初始化 CoreBluetooth、不发命令）。
- 顶部固定提示：`.safeAreaInset(edge: .top)`，`HStack { Text("演示").caption.bold() … .background(.orange, in: .capsule); Text("下面是模拟状态，没有连接任何 Mac").footnote }`，容器 `.background(.orange.opacity(0.14), in: .rect(cornerRadius: 18))`。无关闭按钮。（用系统 `.orange`，不是品牌橙。）
- “幕布”行文字后加同款“演示”小标签。
- 多一个分组 `Section("演示里切换") { Picker(...) .pickerStyle(.inline).labelsHidden() }`：已连上这台 Mac / 幕布已盖上 / 走远自动盖上（选第三项：值显示“已走远”约 3 秒后翻“已盖上”）。
- 演示里按“盖上幕布”：走一遍正在盖上…（0.8 秒）→ 已盖上。
- 退出：设置里关“演示模式”。

## 7. 无障碍
- 全部 Dynamic Type；AX 尺寸下 LabeledContent 自动上下排列，不截断。
- 底部按钮最小高 50pt。
- VoiceOver：幕布行读“幕布，已盖上”/“幕布，没盖上”/“幕布，正在盖上”；按钮 hint：“发给这台 Mac，盖上幕布”。
- 对比度：系统色自带；品牌橙只做装饰（accessibilityHidden）。
- Reduce Motion：眼睛 pending 不闪；码错不抖。
- Increase Contrast：无需特殊处理。

## 8. SF Symbols 清单
gearshape · laptopcomputer · figure.walk · curtains.closed · laptopcomputer.and.iphone · checkmark.circle.fill

## 9. 不做的
- 不自定义背景图、星空、渐变、卡片阴影、字体。
- 不出现“撤下”按钮；不显示信号数字和距离。
- 不放 App 内 Tab；只有主屏 + 设置 sheet + 配对 sheet + 首次打开。
