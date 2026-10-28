<p align="center"><img src="docs/images/icon.png" width="128" alt=""></p>

<h1 align="center">LockCurtain</h1>

<p align="center">离开电脑时，agent 照常干活，路过的人只看到一块遮罩。</p>

<p align="center">中文 · <a href="README.en.md">English</a></p>

<p align="center"><img src="docs/images/curtain.gif" alt="离开模式下的遮罩：星空背景上的机械眼和提示文案"></p>

让 Claude Code、Codex 这类 agent 跑长任务时，人走开一会儿就两头为难：
锁屏的话，截屏、模拟点击这类自动化操作不一定还能用；不锁屏的话，谁路过都能看到、碰到你的桌面。

LockCurtain 的**离开模式**不锁屏，而是用一层遮罩盖住所有屏幕：

- **agent 不受影响**：遮罩对截屏和录屏透明，自动化工具拍到的是遮罩下面的真实桌面；程序发出的键鼠输入照常放行。
- **真人碰不到桌面**：有人按键盘或点鼠标，这次输入被吞掉，电脑随即锁屏，等系统锁屏界面出来了才撤遮罩。

Mac 和 Windows 都有。

## 功能

- **离开模式**：手动进入，或者交给规则：空闲 N 分钟、某个 app 或进程在运行、有 app 在阻止睡眠、某个时间段、接着电源，开着的条件都满足时自动进入。离开期间电脑不睡。
- **遮罩样式**：图案有机械眼、魔瞳、镇宅符、机械表、保险库、挂锁，也可以用自己的图片；背景有壁纸、模糊壁纸、纯黑，和程序画的星空、远山、碳纤维。遮罩上的两行字也能改。
- **锁屏遮罩**（仅 Mac）：真的锁屏时也盖一层同样的遮罩。
- **面板**（菜单栏 / 通知区域）：现在谁在阻止睡眠、过去 24 小时睡了多久，以及「保持唤醒」：不盖遮罩，只让电脑不睡。
- **命令行**：`--send away` / `hide` / `status`，agent 和脚本可以自己进入离开模式。Mac 上还能用 iPhone 快捷指令通过 SSH 远程开。
- **自动更新**：每天检查一次，有新版本先问你；遮罩盖着时不弹窗，也不重启。

界面目前只有中文。

## 安装

### Mac

需要 macOS 14 或更新版本、Apple 芯片（M 系列）。

1. 从 [Releases](https://github.com/Snowyyyyyy1/LockCurtain/releases/latest) 下载 `LockCurtain-<版本>-mac.zip`，解压，把 LockCurtain 拖进「应用程序」文件夹。
2. 第一次打开时系统会拦下：App 用自建证书签名，没有经过 Apple 公证。到「系统设置 → 隐私与安全性」，往下翻到 LockCurtain 那一条，点「仍要打开」。
3. 给两个权限，设置窗口的「权限」页能看到状态：
   - **屏幕录制**：读当前壁纸，做遮罩背景。
   - **辅助功能**：监听键盘和鼠标，判断是不是有人回来了。系统不会弹窗，要在「系统设置 → 隐私与安全性 → 辅助功能」里点 `+` 把 LockCurtain 加进去。

### Windows

需要 Windows 10 2004 或更新版本（含 Windows 11），64 位。目前只在 Windows 11 ARM64 上实测过。不用另装 .NET。

1. 打开「设置 → 系统 → 系统信息」看「系统类型」：ARM 处理器（骁龙笔记本、Mac 上的虚拟机）下载 `LockCurtain-<版本>-win-arm64.zip`，其余下载 `-win-x64.zip`。
2. 解压，右键 `install.ps1` 选「使用 PowerShell 运行」，在 UAC 提示里点「是」。程序会装到 `C:\Program Files\LockCurtain`，以后每次登录都以管理员身份自动启动，不再弹 UAC。
   右键菜单里没有这一项时，在解压出来的文件夹里打开 PowerShell，运行 `powershell -ExecutionPolicy Bypass -File .\install.ps1`。
3. 程序没有代码签名，可能会看到「Windows 已保护你的电脑」：点「更多信息」，再点「仍要运行」。开着「智能应用控制」时，没签名的程序会被直接拦下，只能在 Windows 安全中心里把它关掉。

不是管理员的账户用不了 `install.ps1`：把解压出来的文件夹放在自己的目录里，直接运行 `LockCurtain.exe`，在设置里打开「登录时打开」。
这样运行时，如果前台是以管理员身份运行的窗口，按键会先落进那个窗口，约 0.2 秒后才锁屏。

卸载：运行 `install.ps1 -Uninstall`，会删掉计划任务和 `C:\Program Files\LockCurtain`。设置和日志在 `%LOCALAPPDATA%\LockCurtain`，不要了可以手动删。

和 Mac 版的差别：锁屏界面上盖不了遮罩，开始菜单这类系统弹出层会显示在遮罩上面；
「过去 24 小时」只记睡眠和唤醒，不记各程序阻止睡眠的历史；没有 iPhone 快捷指令的远程控制，只有命令行。

## 用法

点菜单栏（Windows 是通知区域）里的 LockCurtain 图标，选「进入离开模式」，然后就可以走开了。

回来时按任意键或点一下鼠标，电脑锁屏，用密码解锁就行。这一下输入不会落到 agent 正在操作的窗口上。

让 agent 自己进入离开模式：

```bash
# Mac
/Applications/LockCurtain.app/Contents/MacOS/LockCurtain --send away
# Windows（PowerShell）
& "C:\Program Files\LockCurtain\LockCurtain.exe" --send away
```

`hide` 撤遮罩（离开模式下同样先锁屏），`status` 输出一行 JSON。命令只能把遮罩拉起来或者锁屏，不能远程解锁。

规则在设置窗口的「规则」页。规则只在条件刚满足的那一刻触发一次，你回来撤掉遮罩后，不会马上又被盖上。

## 常见问题

**遮罩盖着时，agent 截的图真的不受影响？**
是。Mac 上遮罩窗口设了 `sharingType = .none`，Windows 上用 `WDA_EXCLUDEFROMCAPTURE`，系统的截屏和录屏都会跳过它。
在 Mac 上用 ScreenCaptureKit、`screencapture` 和 cua-driver 测过，拍到的都是遮罩下面的桌面，包括遮罩显示之后才打开的窗口。

**这样安全吗？**
遮罩不是锁。离开模式下桌面并没有锁上，遮罩防的是路过的人：看不到屏幕，碰一下就锁屏。
它防不住能在这台电脑上运行程序的人，比如通过 SSH 登录的人，或者 agent 本身。

**离开期间电脑会睡吗？**
不会。离开模式会阻止系统睡眠，默认屏幕也常亮（可以在设置里关掉）。真的锁屏之后就不再阻止，照常睡。MacBook 合上盖子照样会睡。

**遮罩撤不掉怎么办？**
Mac 上如果因为缺辅助功能权限，连续 2 分钟监听不到键盘和鼠标，LockCurtain 会自己先锁屏再撤遮罩。
还不行的话，从另一台设备 SSH 登录，运行 `pkill -9 -f LockCurtain`。

**会联网吗？**
只有自动更新会：每天从 GitHub 读一次更新清单，不收集任何数据。从源码编译的版本不检查更新。

## 从源码编译

Mac，需要 Xcode 或 Command Line Tools：

```bash
git clone https://github.com/Snowyyyyyy1/LockCurtain.git
cd LockCurtain
./build.sh
open LockCurtain.app
```

没有签名证书时用 ad-hoc 签名，每次重新编译都要重新给权限。自建一张证书就不用：钥匙串访问 → 证书助理 → 创建证书，类型选「代码签名」，然后 `echo "证书名" > .signing-cert`。

Windows 版也在 Mac 上编译：`brew install dotnet`，然后运行 `windows/build.sh`。

完整的用法、实现细节和实测记录见 [docs/guide.md](docs/guide.md)。

## 许可证

[AGPL-3.0](LICENSE)
