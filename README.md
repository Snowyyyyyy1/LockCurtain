# LockCurtain

macOS 锁屏壁纸遮罩。锁屏时在每块屏幕上覆盖一层「当前壁纸 + 压暗 + 机械眼 + 提示文案」，
并把遮罩做成对屏幕捕获透明，让后台自动化任务照常工作。

遮罩显示期间只拦截真人的键鼠输入，程序合成的输入照常放行；不处理任何账号信息。
离开模式和看门狗会调用系统锁屏，除此之外不改变锁屏状态。

## 快速开始

```bash
cd ~/Code/LockCurtain
./build.sh
open LockCurtain.app
```

不要用 `open -n`，它会另起一个实例。菜单栏出现幕布图标：拉开表示没有遮罩，合上表示遮罩显示中。
左键点开是面板，见「菜单栏面板」；右键（或按住 ⌃ 点）是菜单：

| 菜单项 | 作用 |
|---|---|
| 进入离开模式 | 不锁屏，遮罩盖在桌面上让 agent 干活；真人一碰就先锁屏再撤遮罩，见下文 |
| 锁屏遮罩预览 | 立即显示遮罩，不用真的锁屏 |
| 紧急关闭遮罩 | 任何时候强制撤掉遮罩 |
| 设置…（⌘,） | 打开设置窗口 |

## 菜单栏面板

左键点菜单栏图标弹出，从上到下：

- **常用操作**：进入离开模式、预览遮罩、设置。
- **阻止睡眠**：现在有哪些 app 不让 Mac 睡。「显示器」是不让屏幕变暗（看视频、演示），「系统」是不让机器睡（屏幕可以黑）。
  - 数据来自 `IOPMCopyAssertionsByProcess`，不需要权限；面板开着时每 2 秒刷新。
  - powerd、coreaudiod 这类系统服务（程序在 `/System`、`/usr/sbin`、`/usr/libexec` 等目录下）不逐个列出，只在底下计数。
    `/usr/bin` 下的 `caffeinate` 是人自己跑的，照常列出。
  - 右上角「保持唤醒」：不盖遮罩，只让 Mac 不睡，相当于 Amphetamine 的会话。可选一直、1 / 2 / 5 小时、到指定时间、某个 app 开着时。
    - 只拦系统睡眠（`PreventUserIdleSystemSleep`），屏幕照样按系统设置熄灭，合盖照样睡。
    - 和离开模式互不影响：锁屏、解锁都不会结束它，只有点「停止」、时间到了或那个 app 退出才结束。
    - 开着时菜单栏图标变成咖啡杯，卡片里多一行显示还剩多久。
    - LockCurtain 退出时还开着的会话，下次启动接着开：一直的照开，定时的没到点才开，跟着 app 的那个 app 还开着才开（按 bundle ID 找）。
      配合设置里的「登录时打开 LockCurtain」，开机就自动保持唤醒，相当于 Amphetamine 的「启动时开始会话」。
- **过去 24 小时**：一条时间条，加上睡眠、在用、被阻止三个总时长，以及被阻止期间各 app 各占多久。
  - 被阻止 = 有程序不让睡的时间，去掉睡着的和你在用的。系统认为你在用（`UserIsActive`）的时候本来就不会睡，算不上被谁拦着。
  - 几个 app 同时在拦时，每个 app 都算满这段时间，所以各 app 的时长加起来可以超过总数。
  - 系统服务计入被阻止的总时长，但合成一行显示。已经退出的系统服务认不出来，会当成 app 列出。
  - 数据来自 `pmset -g log`，读一次要 3～4 秒，所以每次打开面板时在后台读，5 分钟内不重读。
    日志的读法（大部分断言只有 Released 一行，要按时长倒推）写在 `Sources/SleepLedger.swift` 文件头。

## 设置窗口

| 页 | 内容 |
|---|---|
| 通用 | 登录时打开 LockCurtain（默认关，用系统登录项 `SMAppService`）、在 Dock 中显示（默认关）、在菜单栏中显示（默认开）、锁屏时显示遮罩（默认开）、遮罩图案 |
| 离开模式 | 屏幕常亮、亮度调到最低，见「离开模式」；立即进入离开模式 |
| 规则 | 满足条件时自动进入离开模式，见「规则」 |
| 远程控制 | 命令行路径和命令、快捷指令的配置步骤 |
| 权限 | 屏幕录制、辅助功能的授权状态和申请按钮；抓取当前壁纸（每块屏存到 `/tmp/lockcurtain-wallpaper-menu-<i>.png`） |

**两个图标都隐藏后怎么回到设置：** 在访达或启动台里再打开一次 LockCurtain，
或者运行 `--send settings`。再次打开时，系统会把 reopen 事件送给已经在运行的实例，不会另起一个（实测）。

图标开关存在 UserDefaults 里，运行中的 App 用 KVO 监听，所以从外面改也会立即生效：

```bash
defaults write dev.local.lockcurtain showDockIcon -bool true
defaults write dev.local.lockcurtain showMenuBarIcon -bool false
```

**遮罩图案**：机械眼（默认）、魔瞳、镇宅符、机械表、保险库、挂锁、自定义图片、不显示。镇宅符照《太上秘法镇宅灵符》（正统道藏洞真部神符类）第三十道描的，原注「盗贼不侵，万事称意」。自定义图片默认是账户头像，在通用页可以换成任意图片（缩到 512px 以内存进设置的 `curtainImage`），可以选裁成圆形（`curtainImageRound`）。
通用页里点缩略图切换，下次显示遮罩时生效；也可以 `defaults write dev.local.lockcurtain curtainArt mechEye`
（取值 `mechEye` / `demonEye` / `talisman` / `clock` / `vault` / `padlock` / `custom` / `none`）。动画图案都按时间实时画，每秒 30 帧，
加新图案见 `Sources/CurtainArt.swift` 文件头。

## 规则

一条规则由若干条件组成，**开着的条件全部满足**时进入离开模式。一个条件都没开的规则不会触发。

| 条件 | 说明 |
|---|---|
| 空闲 N 分钟 | 键盘、鼠标 N 分钟没动（`CGEventSource.secondsSinceLastEventType`） |
| 某个 app 或进程在运行 | 列表里任意一个在运行即可。可以填 app 的 bundle ID，也可以填进程名：命令行工具没有 bundle ID，比如 `claude` 就要填进程名 |
| 有 app 在阻止睡眠 | 列表留空时，任意 app 在阻止睡眠即可；也可以只列几个 app（bundle ID 或进程名）。认法和面板的「阻止睡眠」一样，系统服务和 LockCurtain 自己不算 |
| 时间段 | 起止时间加星期几。允许跨午夜，跨过去的后半夜算开始那天 |
| 接着电源 | 用电池时不触发 |

触发方式：

- **只在条件刚满足的那一刻触发一次。** 你回来撤掉遮罩后，条件要先变成不满足、再重新满足，才会再次触发。
  否则「某 app 在运行」这类会一直成立的条件，在你撤掉遮罩后会马上又把遮罩盖上。
- **新建或修改规则后的第一次检查不触发**，App 启动后的第一次检查也不触发。
  所以改出一条正好满足的规则时，不会把正在改设置的人盖住。
- **锁屏期间暂停检查，状态保持不变。** 否则解锁的那一刻条件会从「不满足」变成「满足」而触发，
  人一碰又锁屏，形成死循环。
- 条件结束后（比如 agent 退出了），遮罩保持，等人回来。

规则每 5 秒检查一次，存在 `~/Library/Application Support/LockCurtain/rules.json`。
判断逻辑是纯函数（`Sources/Rules.swift`），自测在 `Tests/RulesSelfTest.swift`。

## 怎么退出遮罩

遮罩放在层级 400 的私有空间里（不可用时退回 `CGShieldingWindowLevel() + 1`），覆盖一切。三条退出路径：

1. **按任意键** —— 全局按键监听
2. **点任意鼠标键** —— 全局鼠标监听
3. **看门狗** —— 前两条不可用（缺辅助功能权限、监听被系统停用）连续超过 120 秒时，先锁屏再撤遮罩，防止锁死；锁屏失败也照样撤

前两条依赖辅助功能权限。监听正常时遮罩不限时长，被系统停用会自动重新启用；
真实锁屏下盲输密码解锁，遮罩也会随解锁通知撤掉。都失效时用菜单「紧急关闭遮罩」，或 `pkill -9 -f LockCurtain`。

真人的按键、点击、滚轮会被吞掉，不会落到遮罩下面 agent 正在操作的窗口上。
遮罩刚显示的 1 秒内不认真人输入（避免点菜单那一下的余波、触控板惯性直接把它撤掉），但照样吞掉。

真人输入之后怎么撤，取决于遮罩是怎么出现的：

| 模式 | 怎么出现 | 真人输入之后 |
|---|---|---|
| 锁屏 | 系统锁屏后自动盖上 | 直接撤，露出系统锁屏 |
| 预览 | 菜单「锁屏遮罩预览」或 `--preview` | 直接撤，回到桌面 |
| 离开 | 菜单「进入离开模式」、规则触发或 `--send away` | 先锁屏，等锁屏界面出来再撤 |

## 离开模式

真实锁屏下自动化工具能不能照常工作没有保证，离开模式换了个思路：**不锁屏**，
遮罩盖在已解锁的桌面上，agent 在正常会话里干活；安全由 LockCurtain 负责——
真人一碰键鼠，输入被吞掉，同时调 `SACLockScreenImmediate` 锁屏，等系统锁屏界面（时钟、密码框）显示出来、淡入做完才撤遮罩
（`com.apple.screenLockUIIsShown` 之后再等 1.5 秒，通知最多等 5 秒）。系统的「已锁」标志在锁屏界面出来前约 2 秒就变了，不能只看它。
路过的人看不到桌面、碰不到任何窗口，按一下只会进入系统锁屏。

防休眠（设置窗口「离开模式」页，只在离开模式生效，真实锁屏时不防，免得锁屏过夜的 Mac 永远不睡）：

| 设置 | 默认 | 作用 |
|---|---|---|
| 屏幕常亮 | 开 | 开：`PreventUserIdleDisplaySleep`，屏幕不熄。关：只 `PreventUserIdleSystemSleep`，允许熄屏；但熄屏后如果系统设置了「立即要求密码」，会话会被锁上 |
| 亮度调到最低 | 关 | 进入时把屏幕亮度调到 0，撤遮罩时恢复。走 DisplayServices 私有 API，实测只有内置屏支持，外接屏跳过。进程被 `kill -9` 时来不及恢复，需手动调回 |

合盖仍会让 MacBook 休眠，防休眠断言管不了这一条。

## 控制接口

给 agent、脚本和远程控制用。App 内只有一套命令处理逻辑，本机走 Unix 域套接字，
App 自己不监听任何网络端口；远程控制都是在外面调用这条命令行。

```bash
LC=~/Code/LockCurtain/LockCurtain.app/Contents/MacOS/LockCurtain
$LC --send away      # 进入离开模式（App 没运行时会先拉起）
$LC --send preview   # 显示预览遮罩（同上）
$LC --send hide      # 撤遮罩；离开模式下先锁屏再撤
$LC --send status    # 查询状态
$LC --send settings  # 打开设置窗口（App 没运行时会先拉起）
```

一行命令进，一行 JSON 出；回复里 `ok` 为 true 时退出码 0，否则 1：

```json
{"locked":false,"mode":"away","ok":true,"running":true,"exitPathsHealthy":true,"level":2147483629,"space":true}
```

`mode` 取值 `none` / `lock` / `preview` / `away`；`exitPathsHealthy`、`level`（遮罩当前层级）和 `space`（遮罩是否在私有空间里）只在遮罩显示时出现。
App 没运行时 `status` / `hide` 不会拉起它，直接返回 `{"ok":true,"running":false}`。

**安全约束：任何命令都不会露出已解锁的桌面。** 离开模式下的 `hide` 和真人输入一样先锁屏；
没有远程解锁。控制通道就算被人拿到，最多只能把遮罩拉起来或者锁屏。

套接字在 `~/Library/Application Support/LockCurtain/control.sock`，权限 0600，
服务端还用 `getpeereid` 校验对方 uid，只接受当前用户。多个实例同时运行时，
靠 `control.lock` 文件锁决定由谁提供服务。在沙箱里运行的 agent 可能连不上这个套接字，
需要把路径加进沙箱白名单，或者在沙箱外调用。

### 远程控制：快捷指令 + SSH

```
iPhone 快捷指令「通过 SSH 运行脚本」 → 组网（如 Surge Ponte） → Mac 的 sshd → $LC --send away
```

1. Mac 打开「系统设置 → 通用 → 共享 → 远程登录」，建议只允许密钥登录
2. 快捷指令里添加「通过 SSH 运行脚本」，脚本填上面那条完整路径的命令，认证方式选 SSH 密钥
3. 远程开启要求 Mac 是醒着的：组网唤醒不了休眠的 Mac；进入离开模式之后才会防休眠

## 界面构成

```
NSWindow  styleMask = 0
          level     = 2147483629（动态，见下）
          space     = SkyLight 私有空间，绝对层级 400（见下）
          ignoresMouseEvents = true
          canBecomeKey = false
└── contentView
    ├── wallpaperView   layer.contents = CGImage, contentsGravity = resizeAspectFill
    ├── dimView         black alpha 0.28
    ├── artView         NSHostingView(CurtainArtView)：眼睛 160x160 centerY -88，30 帧/秒，
    │                   自定义图片 140x140 centerY -78；系统开了「减弱动态效果」时停在一帧
    └── textStack       15pt medium / 12pt semibold，宽 194 / 186，
                        vertical + centerX，spacing 15，centerY +33.5
```

### 私有空间（层级 400）

macOS 先按空间（Space）的绝对层级叠放窗口：普通桌面 0、锁屏 300、锁屏上的通知 400；
同一个空间里，才按窗口层级排。遮罩显示时会新建一个绝对层级 400 的空间，把所有遮罩窗口放进去
（`SkyLightSpace.swift`，做法同 [Lakr233/SkyLightWindow](https://github.com/Lakr233/SkyLightWindow)）。
这样普通空间里的窗口，层级再高也盖不过遮罩。

实测（2026-10-26，macOS 26，主屏和外接屏）：

| | 普通空间，层级 `shield+1` | 私有空间 400 |
|---|---|---|
| 别的窗口在普通空间、层级 `Int32.max` | 被盖住 | 在上面；遮罩的窗口层级设成 0 也一样 |
| 锁屏 | 锁屏界面的窗口更高（日志里见过 2147483630、2147483646），要靠下面的动态层级保护抬上去 | 直接在锁屏界面上面 |
| `excludingWindows` 抓屏 | 正常 | 正常 |

这是私有 API，系统升级可能失效，而且失效时不报错。所以每次放进去之后都用 `SLSCopySpacesForWindows`
查一遍（掩码要用 `0xFFFF`，实测 7 查不到自建的空间）。查不到就把遮罩窗口重建成普通窗口，
本次运行不再用私有空间，只靠窗口层级和下面的动态层级保护。加 `--no-space` 可以直接关闭。

### 动态层级保护

固定层级会被别的工具盖住：录屏、投屏工具的遮罩或镜像窗可以把层级设到 `Int32.max`。
镜像窗显示的是屏幕的真实内容，所以一旦盖在遮罩上面，就会把下层桌面露出来。

遮罩显示期间，每秒查一次 `CGWindowListCopyWindowInfo(.optionOnScreenAboveWindow, 我们最靠后的窗口)`。
只要发现别的进程的不透明窗口压在我们上面，就把全部遮罩窗口抬到「对方层级 + 1」，并重新排到最前。

- 层级封顶 `Int32.max`。超过之后会溢出成负数，窗口沉到最底层（实测）。
- 到顶之后如果还有平级的窗口，靠重新排到最前压住对方：层级相同时，后排到前面的窗口在上（实测）。
- 抬高之后不会降回来，每次 `show()` 都从 2147483629 重新开始。
- 最坏情况下，别的窗口会在遮罩上露出不到 1 秒。
- 遮罩在私有空间里时照样运行，作为私有空间失效时的后备。

## 壁纸层怎么来的

不读取壁纸文件，而是直接抓系统绘制壁纸的那个窗口：

```swift
let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
let display = content.displays.first { $0.displayID == screen.displayID }!
let wallpaperWindow = content.windows.first {
    ["com.apple.dock", "com.apple.WindowManager"].contains($0.owningApplication?.bundleIdentifier ?? "")
        && ($0.title ?? "").hasPrefix("Wallpaper")
        && $0.frame.equalTo(display.frame)
}!

let filter = SCContentFilter(desktopIndependentWindow: wallpaperWindow)
let cfg = SCStreamConfiguration()
cfg.showsCursor = false
cfg.pixelFormat = 1111970369                              // BGRA
cfg.width  = Int(display.frame.width  * scale)
cfg.height = Int(display.frame.height * scale)
let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
```

只框住壁纸窗口，拿到的图不含 Dock、菜单栏和任何前台窗口。

实测对照（主屏 1728×1117 @2x）：

| 抓法 | 结果 | 大小 |
|---|---|---|
| `desktopIndependentWindow` | 纯净壁纸 | 15,644,387 B |
| `including: [壁纸窗口]` | 同上（逐字节一致） | 15,644,387 B |
| `display:` 整屏 | 含桌面内容 | 864,991 B |

## 和自动化工具共存

这是本项目的核心目标：遮罩挡人眼，不挡自动化。

### 输入：任何工具都放行

用 `kCGEventSourceUnixProcessID`（field 41）区分输入来源：

```
field41 == 0  → 硬件（真人）      → 吞掉，撤掉遮罩
field41 != 0  → 程序合成的事件    → 放行
```

所以不需要为每个工具维护白名单。已验证的来源：

| 来源 | 结果 |
|---|---|
| CGEvent 原生事件 | 遮罩保持 |
| `osascript` System Events 按键 | 遮罩保持 |
| cua-driver（移动 / 按键 / 点击） | 遮罩保持 |

想改成「除自己之外谁动键鼠都算真人」，设 `LOCKCURTAIN_STRICT=1`。严格模式的豁免名单：
可执行文件路径含 cua-driver 等关键词的进程、`LOCKCURTAIN_EXEMPT_PIDS="123,456"`，
以及 `~/Library/Application Support/LockCurtain/exempt-pids.txt`（每行一个 pid）。

运行时文件都放在 `~/Library/Application Support/LockCurtain/`，不放 `/tmp`：
`/tmp` 所有用户共享，别的用户能往里写豁免 pid、伪造 `overlay.json`。

### 抓屏：对捕获透明

遮罩窗口设 `sharingType = .none`，并对每块屏额外拼一块 1px 宽的边缘窗，
让未覆盖区域收敛到**右上角 1 个像素**。

为什么必须留缺口：不可共享窗口覆盖 100% 屏幕时，ScreenCaptureKit 会直接返回整屏全黑，
而不是重新合成下层 —— 这是系统级的隐私保护，避免全屏遮盖被直接透视。

实测（不可共享窗口的不同覆盖范围）：

| 覆盖范围 | 整屏截图结果 |
|---|---|
| 局部 300×300 | 透出下层 ✅ |
| 90% 屏幕 | 透出下层 ✅ |
| 铺满减 1px | 透出下层 ✅ |
| **铺满 100%（单窗或双窗拼接）** | **整屏全黑** ❌ |

判据是**覆盖率**，与窗口数量无关。所以只要留 1 个像素不覆盖即可。
（这张表是窗口 `alphaValue = 1` 时测的。现在遮罩用 0.999，实测铺满 100% 也能透出，见下。）

单块矩形没法只漏一个点（少 1px 只能让出一整条边），所以用两块窗口拼接：

```swift
// 主窗：让出最右 1 列，高度不变
var f = screen.frame
f.size.width -= 1
mainWindow.setFrame(f, display: false)

// 边缘窗：宽 1px，高度减 1px
let edge = NSRect(x: f.origin.x + f.size.width, y: f.origin.y,
                  width: 1, height: f.size.height - 1)
// 未覆盖区域 = 右上角那 1 个像素
```

边缘窗的壁纸用 `contentsRect` 精确截取最右一列，和主窗像素对齐，接缝不可见：

```swift
layer.contents = wallpaper
layer.contentsGravity = .resize
layer.contentsRect = CGRect(x: CGFloat(w - 1) / CGFloat(w), y: 0,
                            width: 1.0 / CGFloat(w),
                            height: CGFloat(h - 1) / CGFloat(h))
```

实测窗口尺寸（主屏 1728×1117 + 外接屏 1920×1080）：

```
主屏   主窗 1727×1117 @ (0,0)        边缘窗 1×1116 @ (1727,0)
外接屏 主窗 1919×1080 @ (1728,-570)   边缘窗 1×1079 @ (3647,-570)
```

结果：`screencapture`、ScreenCaptureKit 整屏、以及 cua-driver 的整屏截图，
拍到的都是真实桌面，画面里没有遮罩的机械眼和文案。

**遮罩窗口的 `alphaValue` 必须略低于 1（现在是 0.999）。** 等于 1 时，系统认为遮罩挡住了下面的窗口：
被完全盖住的窗口会从整屏截图里整个消失，只有碰到那 1 个像素缺口的窗口拍得到；
被盖住的 app 也认为自己不可见，可能停止重绘。只设 `isOpaque = false` 不管用。

实测（2026-10-26，macOS 26，另一个进程的窗口压在遮罩下面，用 cua-driver 截整屏）：

| 遮罩窗口 | 遮罩显示前就开着、显示后变色的窗口 | 遮罩显示后才打开的窗口 | 被盖住的 app 认为自己可见 |
|---|---|---|---|
| `alphaValue = 1` | 截不到 | 截不到 | 否 |
| `alphaValue = 1`、`isOpaque = false` | 截不到 | 截不到 | 否 |
| `alphaValue = 0.999` | 截得到，是变色后的颜色 | 截得到 | 是 |

0.999 透出的最多 0.255 个色阶，8 位颜色里取整为 0，人眼看不出来。
`--no-stealth` 时同样设 0.999：app 以为自己被挡住而停止重绘的问题，和抓屏透不透明无关。

想关闭这个行为（例如希望录屏时对方能看到遮罩），加 `--no-stealth`。

### 如果确实需要显式排除

遮罩会把 windowID 写到 `~/Library/Application Support/LockCurtain/overlay.json`：

```json
{ "pid": 8398, "windowIDs": [51622, 51623], "updatedAt": "2026-10-25T07:20:32Z" }
```

外部工具读这个文件，用 `SCContentFilter(display:excludingWindows:)` 把这些窗口排除掉。
`Sources/CurtainCapture.swift` 里的 `CurtainCapture.displayExcludingCurtain()` 是参考实现，
它编译在本 App 内，外部工具调不到，照抄到自己的工具里即可：

```swift
let image = try await CurtainCapture.displayExcludingCurtain()
```

## 三个实现要点

### 1. 主线程不能同步等截图

`SCScreenshotManager.captureImage` 的完成回调需要主线程派发。
在主线程上用信号量等待结果 = 永久死锁，表现为整个 App 冻住、遮罩盖在屏幕上、按什么都没反应。

```swift
// 错误：主线程阻塞，回调永远回不来
let sem = DispatchSemaphore(value: 0)
Task.detached { image = try? await shoot(); sem.signal() }
sem.wait()

// 正确：先上屏，壁纸异步补
func show() {
    for screen in screens { /* 建窗、orderFrontRegardless，先黑底 */ }
    Task { @MainActor in
        let images = await WallpaperCapture.prewarm(screens: screens)
        for (id, img) in images { self.wallpaperLayers[id]?.contents = img }
    }
}
```

### 2. 两套坐标系不能混用

双屏时副屏壁纸永远匹配不到，退化成黑底。原因是拿 AppKit 坐标去比 CoreGraphics 坐标：

| 来源 | 副屏 frame | 坐标系 |
|---|---|---|
| `NSScreen.frame` | `(1728, 607, 1920, 1080)` | AppKit，原点主屏左下，y 向上 |
| `SCDisplay.frame` | `(1728, -570, 1920, 1080)` | CoreGraphics，原点左上，y 向下 |
| `SCWindow.frame` | `(1728, -570, 1920, 1080)` | CoreGraphics |

必须用 `SCDisplay.frame` 去比 `SCWindow.frame`。

### 3. 签名方式决定权限会不会丢

```
ad-hoc（codesign --sign -）
    designated => cdhash H"65424899..."                    ← 每次编译都变
固定证书
    designated => identifier "dev.local.lockcurtain"
                  and certificate leaf = H"7fa3491..."      ← 不变
```

系统把 designated requirement 整个存进 `csreq`。ad-hoc 的 requirement 就是 cdhash，所以：

| 操作 | ad-hoc | 固定证书 |
|---|---|---|
| 改代码重编译 | 授权失效 | 保留 |
| 改 Info.plist | 授权失效 | 保留 |
| 重新签署 | 授权失效 | 保留 |

`build.sh` 默认使用本机的自签名证书，可用 `LOCKCURTAIN_CERT` 指定其他证书。

## 系统权限

| 权限 | 用途 | 怎么给 |
|---|---|---|
| 屏幕录制 | 读取壁纸窗口 | `--args --request-permissions` 或系统设置 |
| 辅助功能 | 全局按键 / 鼠标监听（退出遮罩） | 需在系统设置里手动勾选 |

辅助功能没有弹窗（应用不带 Dock 图标时不会出现），
需要到「系统设置 → 隐私与安全性 → 辅助功能」点 `+` 添加 `LockCurtain.app`。

## 文件结构

```
LockCurtain/
├── build.sh                      图标 + 编译 + 签署 + 权限检查
├── README.md
├── Sources/
│   ├── main.swift                入口，命令行参数分发
│   ├── AppDelegate.swift         主菜单、菜单栏、Dock 图标、reopen、命令分发
│   ├── StatusPanel.swift         菜单栏左键弹出的面板：常用操作、阻止睡眠和保持唤醒、过去 24 小时
│   ├── Preferences.swift         通用设置的 UserDefaults key
│   ├── SettingsWindow.swift      设置窗口（SwiftUI）：通用 / 离开模式 / 远程控制 / 权限
│   ├── RulesPane.swift           设置窗口的规则页和规则编辑器
│   ├── Rules.swift               规则模型、条件判断、边沿触发（纯函数）
│   ├── RuleEngine.swift          规则存储、系统状态采集、定时检查
│   ├── OverlayController.swift   遮罩窗口、锁屏监听、退出路径
│   ├── SkyLightSpace.swift       把遮罩放进层级 400 的私有空间（私有 API，失效时退回）
│   ├── CurtainArt.swift          遮罩图案的列表和视图
│   ├── MechEye.swift             遮罩上的机械眼（SwiftUI Canvas，按时间 t 画帧）
│   ├── ArtPresets.swift          其余动画图案：魔瞳、镇宅符、机械表、保险库门、挂锁
│   ├── WallpaperCapture.swift    壁纸采集（纯 async）
│   ├── CurtainInputFilter.swift  真人输入 / 合成输入判定
│   ├── CurtainCapture.swift      带排除的整屏抓取 + windowID 发布 + 运行时文件路径
│   ├── PowerGuard.swift          离开模式的防休眠、亮度
│   ├── KeepAwake.swift           保持唤醒：不盖遮罩的防休眠，定时或跟着某个 app 结束
│   ├── SleepBlockers.swift       现在谁在阻止睡眠（读电源断言），分显示器 / 系统两类
│   ├── SleepLog.swift            解析 pmset -g log 的电源断言和睡眠 / 唤醒事件
│   ├── SleepLedger.swift         过去 24 小时的睡眠 / 在用 / 被阻止统计
│   ├── IntervalSet.swift         时间区间的并、交、差
│   ├── ProcessTable.swift        读进程表：全部 pid、可执行文件路径
│   ├── ControlServer.swift       控制接口：Unix 域套接字服务端 + --send 命令行客户端
│   └── ScreenChangeCoalescer.swift  屏幕变化通知合并 + 布局差异比对
├── Tests/
│   ├── ScreenChangeCoalescerSelfTest.swift  合并器自测，运行方式见文件头
│   ├── SleepLogSelfTest.swift    电源日志解析、区间代数、24 小时统计的自测
│   └── RulesSelfTest.swift       规则自测，运行方式见文件头
├── Tools/
│   ├── make-icon.swift           用代码画 App 图标，build.sh 调用
│   └── EyePreview.swift          离线渲染动画图案的拼图和 GIF，运行方式见文件头
├── proposals/                    未合入的改动提案；已合入的在 archive/
└── LockCurtain.app               构建产物
```

## 命令行

```bash
open LockCurtain.app                           # 正常运行；已在运行时打开设置窗口
open -n LockCurtain.app --args --status        # 打印系统权限
open -n LockCurtain.app --args --preview       # 立即显示遮罩并常驻（直到按键或点击）
open -n LockCurtain.app --args --capture       # 抓取所有屏幕壁纸
open -n LockCurtain.app --args --no-stealth    # 关闭抓屏透明
open -n LockCurtain.app --args --level 3000    # 自定义窗口层级
open -n LockCurtain.app --args --no-space      # 不用私有空间，只靠窗口层级
LockCurtain.app/Contents/MacOS/LockCurtain --send status   # 控制运行中的实例，见「控制接口」
```

