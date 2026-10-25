# LockCurtain

macOS 锁屏壁纸遮罩。锁屏时在每块屏幕上覆盖一层「当前壁纸 + 压暗 + 头像 + 提示文案」，
并把遮罩做成对屏幕捕获透明，让后台自动化任务照常工作。

纯视觉层：不改变系统锁屏状态，不干预输入目标，不处理任何账号信息。

## 快速开始

```bash
cd ~/Code/LockCurtain
./build.sh
open -n LockCurtain.app
```

菜单栏出现 🌙，点开：

| 菜单项 | 作用 |
|---|---|
| 锁屏遮罩预览 | 立即显示遮罩，不用真的锁屏 |
| 紧急关闭遮罩 | 任何时候强制撤掉遮罩 |
| 模拟锁屏 | 显示遮罩，3 秒后触发系统锁屏 |
| 申请屏幕录制权限 | 读取壁纸所需 |
| 申请辅助功能权限 | 全局按键监听所需 |
| 抓取当前壁纸 | 每块屏存一张到 `/tmp/lockcurtain-wallpaper-menu-<i>.png` |
| 打印权限状态 | 查看当前授权 |

## 怎么退出遮罩

遮罩在 `CGShieldingWindowLevel() + 1`，覆盖一切。三条退出路径：

1. **按任意键** —— 全局按键监听
2. **点任意鼠标键** —— 全局鼠标监听
3. **看门狗** —— 超过 120 秒强制撤掉，防止监听失效时锁死

前两条依赖辅助功能权限。都失效时用菜单「紧急关闭遮罩」，或 `pkill -9 -f LockCurtain`。

## 界面构成

```
NSWindow  styleMask = 0
          level     = 2147483629
          ignoresMouseEvents = true
          canBecomeKey = false
└── contentView
    ├── wallpaperView   layer.contents = CGImage, contentsGravity = resizeAspectFill
    ├── dimView         black alpha 0.28
    ├── avatarView      85x85 圆角 39，2pt 白色描边 alpha 0.92，内部图标 44x44
    └── textStack       15pt medium / 12pt semibold，宽 194 / 186，
                        vertical + centerX，spacing 15，centerY +33.5
```

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
field41 == 0  → 硬件（真人）      → 撤掉遮罩
field41 != 0  → 程序合成的事件    → 放行
```

所以不需要为每个工具维护白名单。已验证的来源：

| 来源 | 结果 |
|---|---|
| CGEvent 原生事件 | 遮罩保持 |
| `osascript` System Events 按键 | 遮罩保持 |
| cua-driver（移动 / 按键 / 点击） | 遮罩保持 |

想改成「除自己之外谁动键鼠都算真人」，设 `LOCKCURTAIN_STRICT=1`。

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
拍到的都是真实桌面，画面里没有遮罩的头像和文案。

想关闭这个行为（例如希望录屏时对方能看到遮罩），加 `--no-stealth`。

### 如果确实需要显式排除

遮罩会把 windowID 写到 `/tmp/lockcurtain-overlay.json`：

```json
{ "pid": 8398, "windowIDs": [51622, 51623], "updatedAt": "2026-10-25T07:20:32Z" }
```

配合封装好的接口使用：

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
├── build.sh                      编译 + 签署 + 权限检查
├── README.md
├── Sources/
│   ├── main.swift                入口，命令行参数分发
│   ├── AppDelegate.swift         菜单栏、权限申请、抓取壁纸
│   ├── OverlayController.swift   遮罩窗口、锁屏监听、退出路径
│   ├── WallpaperCapture.swift    壁纸采集（纯 async）
│   ├── CurtainInputFilter.swift  真人输入 / 合成输入判定
│   └── CurtainCapture.swift      带排除的整屏抓取 + windowID 发布
└── LockCurtain.app               构建产物
```

## 命令行

```bash
open -n LockCurtain.app                        # 正常运行
open -n LockCurtain.app --args --status        # 打印系统权限
open -n LockCurtain.app --args --preview       # 立即显示遮罩并常驻
open -n LockCurtain.app --args --capture       # 抓取所有屏幕壁纸
open -n LockCurtain.app --args --no-stealth    # 关闭抓屏透明
open -n LockCurtain.app --args --level 3000    # 自定义窗口层级
```

