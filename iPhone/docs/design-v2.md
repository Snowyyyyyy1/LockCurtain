# LockCurtain iPhone — 设计规格 v2.2（原生版，当前；v2.2 增量见文末）

2026-11-02 · Colo · 取代 v2.1、v2.0、v1
依据：Ato msg564 / Camo msg567 / Pluso msg563；Camo copy v5.3（字以 copy 为准）。
小样：artifact D997FBB3-06E0-400B-8FF8-18B43F491E02 v4

## 0. 总原则
- 全部系统组件与系统样式，不自定义背景、字体、卡片、按钮形状。不锁 colorScheme，不写硬编码色。
- tint = 系统默认蓝。唯一品牌色是状态眼的橙 #FF8A1F，只在「幕布 · 已盖上 / 正在盖上…」出现。
- 系统 Dynamic Type，支持到 AX5。状态永远有字，眼睛只是加强。

## 1. 结构
WindowGroup → RootView：未配对且非演示 → OnboardingView；否则 NavigationStack { HomeView }，右上 gearshape 打开 SettingsView sheet。主屏「自动」行点击 = 同一个 sheet。配对 sheet 从 Onboarding「去配对」或设置「配对」打开。

## 2. 主屏 HomeView
- List + Section（幕布 / 这台 Mac / 自动），.insetGrouped，大标题 LockCurtain，safeAreaInset(edge:.bottom, spacing:0) 放 BottomBar。
- 行：`LabeledContent { Text(值) } label: { Label { Text("幕布") } icon: { StatusEye(state) } }`；这台 Mac 用 laptopcomputer；自动行是 Button 外观 NavigationLink（trailing chevron，字不被 tint 染）。
- BottomBar（Ato msg564：贴底、系统材质、盖上后原位替换按钮）：
  ```swift
  VStack(spacing: 10) { content }
    .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 8)
    .frame(maxWidth: .infinity)
    .background(.bar)
  ```
  按钮：Label("盖上幕布", systemImage: "curtains.closed").frame(maxWidth:.infinity)，borderedProminent（iOS 26 可用 .glassProminent），controlSize(.large)。
  盖上后说明：`Text("回到 Mac 前按任意键解锁。")` subheadline.semibold + `Text("手机上不能撤下幕布。")` subheadline secondary，两行居中，padding 6/10。
  按钮 ↔ 说明：`.transition(.opacity)` + `.animation(.snappy(duration: 0.25))`，高度跟着变不跳位。
  没连上 / Mac 不在线 / 蓝牙关了：整个底栏不出现。
- 触觉：按下 .impact(weight:.medium)；回执 .success；超时 .warning。

### 2.1 状态表
| 情况 | 幕布值 | 眼睛 | 这台 Mac | 底栏 | footer |
|---|---|---|---|---|---|
| 没盖上 | 没盖上 | off | 已连接 | 按钮 盖上幕布 | 无 |
| 正在盖上 | 正在盖上… | pending | 已连接 | 按钮 disabled，label = ProgressView + 「正在盖上…」 | 无 |
| 5 秒没回执 | 没盖上（退回最后值） | off | 已连接 | 上方 footnote secondary「Mac 没有回应，状态没变。」，下方同一颗按钮 label 换「再试一次」 | 无 |
| 已盖上 | 已盖上 | on | 已连接 | 两行说明，无按钮 | 无 |
| 没连上 / Mac 不在线 / 蓝牙关了 | — secondary | off（0.4） | 对应值 | 无底栏 | copy §2 副句一句 |
| 没配对 | — | off | 没配对 | 按钮 去配对 | 「在 Mac 上打开 LockCurtain，点「配对手机」，把 6 位码输进来。」 |
- 自动值只放短词：开着 / 关。定位没给「始终」时值仍是「关」，footer：「定位没给"始终"，现在只能手动。」
- 不显示 RSSI / 米数。

### 2.2 StatusEye（唯一自绘）
- `@ScaledMetric(relativeTo: .body) var d = 22`。
- off：strokeBorder(.tertiary, 2) + 中心 fill(.tertiary) frame(d*0.36)。
- pending：同 off，橙 0.75；opacity 0.45↔1.0 easeInOut(0.9).repeatForever；Reduce Motion 固定 0.75。
- on：fill(#FF8A1F) + 内圈 strokeBorder(0xE06A00, d*0.07) + 瞳孔 fill(0x1A0E00) frame(d*0.3) + shadow(橙 0.45, radius 6)。
- off→on：.snappy(0.25)，只动颜色与阴影。`.accessibilityHidden(true)`。

## 3. 设置 SettingsView（sheet）
```swift
NavigationStack {
  Form {
    Section("这台 Mac") { LabeledContent("已配对", value: macName); Button("撤销配对", role: .destructive) }
    Section("自动") { Toggle("走远自动盖上", isOn: $auto) } footer: { Text("只有走远会盖。回来不会自动撤。") }
    Section { LabeledContent("灵敏度", value: "标准"); LabeledContent("离开后等", value: "默认") }
      footer: { Text("这两项等实测出结果才能调，先按默认走。") }
    Section("演示") { Toggle("演示模式", isOn: $demo) } footer: { Text("不连 Mac，也能看到连上、盖上是什么样。") }
    Section("关于") { LabeledContent("版本", value: appVersion); NavigationLink("排查信息") { DiagnosticsView() } }
    Section { MadeWithAirBuild() }
  }
  .navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
}
```
- 只读两行：label 用 .secondary，无 chevron、不可点，不写「即将上线」。验完后换回 Picker（.menu）。
- 撤销：confirmationDialog，标题「撤销这台手机的配对？」，message「以后要重新配对才能控制这台 Mac。」，按钮 取消 / 撤销。
- 定位没给「始终」：自动分组 Toggle 置关且 disabled，下面加 `LabeledContent("定位", value: "使用 App 期间"/"从不")`（系统原词），footer 换 copy §3 那句 + `Button("前往“设置”")`。
- 没配对：「这台 Mac」组换成一行 Button("配对")。
- 排查信息页：Form，照 copy §3.7；探针组里 NavigationLink「蓝牙探针」到现有探针屏。不出现 RSSI 数字与米数。
- 深色：Form 在 sheet 里自动分层（底 #1C1C1E、行 #2C2C2E），不手写。

## 4. 第一次打开 Onboarding
- VStack 居中；`laptopcomputer.and.iphone` 64pt tint hierarchical；标题 largeTitle.bold「先和你的 Mac 连上」；说明 body secondary，水平 padding 32。
- 底部：Button("去配对") borderedProminent large 全宽；下方 Button("手上没有 Mac？先看看演示") .borderless，间距 16，底 padding 8。
- 进页不弹蓝牙；点「去配对」才初始化 CBCentralManager。
- 从演示退出回来：safeAreaInset(edge:.top) 提示「演示已退出，这里还是没连上 Mac」，regularMaterial capsule，3 秒淡出。

## 5. 配对 PairingSheet
- sheet + NavigationStack，标题「配对」inline，左上 close 按钮，presentationDetents([.large])。
- 三步同 sheet 切换（contentTransition(.opacity)，不 push）：
  1. ProgressView + title2.bold「找这台 Mac…」+ secondary 副句。
  2. title2.bold「输 6 位码」+ secondary「Mac 上显示的那 6 个数字」；6 格 46×58，间距 8，RoundedRectangle(12).fill(Color(.secondarySystemGroupedBackground))，数字 title.monospacedDigit().semibold，当前格 strokeBorder(.tint, 2)。隐藏 TextField（numberPad + oneTimeCode）驱动，满 6 位自动提交。背景 Color(.systemGroupedBackground)。
  3. checkmark.circle.fill 56pt .green + title2.bold「配对好了」+ 副句；Button("完成") borderedProminent large；.success。
- 码错：清空 + .error + 抖动 3 次（Reduce Motion 不抖）+ 红字「码不对，再看一眼 Mac 上那 6 位。」

## 6. 演示模式
- 同一个 HomeView，数据源换 DemoSource（不初始化 CoreBluetooth、不发命令）。
- 顶部常驻提示 safeAreaInset(edge:.top)：「演示」caption.bold 黑字 on .orange capsule + 「下面是模拟状态，没有连接任何 Mac」footnote，容器 .orange.opacity(0.14) rect(18)，水平 padding 16，无关闭按钮。
- 「幕布」行文字后加同款「演示」小标签。
- Section("演示里切换") 三项 inline picker：已连上这台 Mac / 幕布已盖上 / 走远自动盖上（第三项：值显示「已走远」约 3 秒后翻「已盖上」）。
- 底栏与真实一致；按「盖上幕布」：正在盖上…（0.8 秒）→ 已盖上。
- 退出：设置里关 Toggle。

## 7. 无障碍
- 全部 Dynamic Type；AX 下 LabeledContent 上下排列不截断。按钮最小高 50pt。
- VoiceOver：幕布行「幕布，已盖上」/「幕布，没盖上」/「幕布，正在盖上」；按钮「盖上幕布」+ hint「发给这台 Mac，盖上幕布」；底栏说明 combine 成一句。
- Reduce Motion：眼睛 pending 不闪、码错不抖。

## 8. SF Symbols
gearshape · laptopcomputer · figure.walk · curtains.closed · laptopcomputer.and.iphone · checkmark.circle.fill

## 9. 不做的
不自定义背景/星空/渐变/卡片阴影/字体；不出现「撤下」按钮；不显示信号数字与距离；不放 App 内 Tab。

# v2.2 增量（当前有效，覆盖上文冲突处）

改动来源：用户 msg570 要示意图；Ato msg573 定边界；Camo msg572 管字。

## A. 「幕布」行前的小眼睛去掉
- 旧 §2.2 StatusEye 作废。行图标改系统符号：没盖上 `curtains.open`，已盖上 / 正在盖上 `curtains.closed`。
- 「幕布」行仍读「幕布，没盖上 / 已盖上 / 正在盖上」。状态依旧有字。

## B. 新增 MacScreenIllustration（唯一自定义视图）
位置：List 的第一个 Section，单独一块，在三行列表之上：
`Section { MacScreenIllustration(state).frame(maxWidth:.infinity).listRowInsets(EdgeInsets(top:12, leading:0, bottom:8, trailing:0)) }`
不塞进列表行，不铺满整屏。

尺寸：绘制坐标系 300×190（屏幕 236×148，外框 7，底座在下）；`.aspectRatio(300/190, contentMode:.fit)`；
高度 `h = dynamicTypeSize >= .accessibility1 ? 120 : (dynamicTypeSize >= .xxLarge ? 150 : 190)`（字号越大它越小让位），`.frame(height: h)`。

画法（SwiftUI 形状 / Canvas，不用图片资源）：
- 机身：外框 `RoundedRectangle(cornerRadius: 11).fill(Color(hex: 0x0B0B0D))` + `.strokeBorder(al2, 1.2)`；屏幕区 `RoundedRectangle(cornerRadius: 3)` 裁切；底座宽 296 高 12 梯形（底角圆 4），`LinearGradient(al1→al2)`，中间凹口 44×3.5 胶囊 `al3`。
- 铝色：浅色 al1 #E3E4E8 / al2 #B5B7BD / al3 #9C9EA4；深色 al1 #6B6C71 / al2 #48494D / al3 #3A3B3F（`Color(UIColor { trait in … })`）。
- 桌面（没盖上）：抽象色块，不画窗口标题、红绿灯、文字、图标、截图。底 `LinearGradient(#9DB7E8 → #B9A9E0 → #E7B8C8, topLeading→bottomTrailing)`；两块圆角矩形 r7：(24,22,118×82) 白 0.88、(118,52,96×72) 白 0.6；顶部 7pt 白 0.55 条。
- 幕布：`LinearGradient(#05061A → #0D1030, top→bottom)` + `Canvas` 星点 70 颗（固定种子伪随机，半径 0.45/0.7/1.1，白 0.35–1.0）；下沿 1.2pt `#FFB06A` 0.55 光边。
- 眼睛（只在已盖上）：屏幕中心，光晕 r16 #FF8A1F 0.25；本体 r11 #FF8A1F + 1.4pt #E06A00 描边；瞳孔 r3.6 #1A0E00。全 App 唯一的品牌橙。

状态对应：
| 状态 | 屏幕里 |
|---|---|
| 没盖上 / Mac 没回应 | 桌面 |
| 正在盖上… | 桌面 + 幕布从顶落到 55%，`.easeInOut(0.6)` 落到 55% 停住不来回；回执后落满 → 已盖上 |
| 已盖上 | 幕布满屏 + 眼睛（眼睛 `.opacity` 0→1，0.25s） |
| 没连上 / Mac 不在线 / 蓝牙关了 / 没配对 | 填 `Color(.tertiarySystemFill)`，什么都不画 |
- Reduce Motion：直接切，不做下落动画。
- 演示模式：屏幕左上角（距屏幕边 8pt）「演示」角标：`.caption2.bold()`，padding 7/2，`.background(.orange, in: .rect(cornerRadius: 6))`，`.foregroundStyle(.black)`，任何演示状态都在。
- 无障碍：整块 `.accessibilityHidden(true)`。
- 颜色说明：这块里的渐变、星空、眼睛是「画」，不是界面色；界面其余全系统色。

## C. 状态表补充
5 秒没回执时示意图回桌面（幕布收回），其余同 §2.1。
