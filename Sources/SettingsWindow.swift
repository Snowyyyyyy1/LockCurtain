// SettingsWindow.swift —— 设置窗口（AppKit 窗口 + SwiftUI 内容）
//
// App 生命周期仍是 AppKit（main.swift + AppDelegate），设置界面用 SwiftUI 写，
// 放进 NSHostingController。开关直接用 @AppStorage 读写 UserDefaults，
// Dock / 菜单栏图标由 AppDelegate 监听 UserDefaults 变化后应用。

import AppKit
import Combine
import ServiceManagement
import SwiftUI

/// 设置界面需要调用的 App 动作
struct AppActions {
    var enterAway: () -> Void
    var grabWallpaper: () -> Void
}

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let store: RuleStore
    private let actions: AppActions

    init(store: RuleStore, actions: AppActions) {
        self.store = store
        self.actions = actions
    }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "LockCurtain 设置"
            w.titlebarAppearsTransparent = true
            w.toolbarStyle = .unified
            w.isReleasedWhenClosed = false
            w.contentMinSize = NSSize(width: 680, height: 440)
            let host = NSHostingController(rootView: SettingsView(store: store, actions: actions))
            // 默认会按每页内容的理想尺寸缩放窗口，切换页面时窗口跟着跳；只取最小尺寸，大小交给用户
            host.sizingOptions = [.minSize]
            w.contentViewController = host
            w.setContentSize(NSSize(width: 760, height: 520))
            w.center()
            w.setFrameAutosaveName("LockCurtainSettings")
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// 切换 Dock 图标会让 App 失去激活，设置窗口沉到后面；切完重新提到前面
    func bringToFrontIfVisible() {
        guard let w = window, w.isVisible else { return }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}

// MARK: - 根视图

private enum Pane: String, CaseIterable, Identifiable {
    case general, away, rules, remote, permissions
    var id: Self { self }
    var title: String {
        switch self {
        case .general: "通用"
        case .away: "离开模式"
        case .rules: "规则"
        case .remote: "远程控制"
        case .permissions: "权限"
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .away: "figure.walk.departure"
        case .rules: "list.bullet.rectangle"
        case .remote: "network"
        case .permissions: "hand.raised"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var store: RuleStore
    let actions: AppActions
    @State private var pane: Pane? = .general

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $pane) { p in
                Label(p.title, systemImage: p.symbol).tag(p)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 180, max: 220)
        } detail: {
            Group {
                switch pane ?? .general {
                case .general: GeneralPane()
                case .away: AwayPane(actions: actions)
                case .rules: RulesPane(store: store)
                case .remote: RemotePane()
                case .permissions: PermissionsPane(actions: actions)
                }
            }
            .navigationTitle((pane ?? .general).title)
        }
        .frame(minWidth: 680, minHeight: 440)
    }
}

// MARK: - 通用

private struct GeneralPane: View {
    @AppStorage(PrefKey.showDockIcon) private var showDock = false
    @AppStorage(PrefKey.showMenuBarIcon) private var showMenuBar = true
    @AppStorage(PrefKey.curtainOnLock) private var curtainOnLock = true
    @AppStorage(PrefKey.curtainArt) private var art = CurtainArt.mechEye
    @AppStorage(PrefKey.curtainImage) private var customImage: Data?
    @AppStorage(PrefKey.curtainImageRound) private var roundImage = true
    @State private var pickingImage = false
    @AppStorage(PrefKey.curtainBackground) private var background = CurtainBackground.wallpaper
    @State private var backgroundThumbs: [CurtainBackground: CGImage] = [:]
    @AppStorage(PrefKey.curtainTitle) private var curtainTitle = Prefs.defaultCurtainTitle
    @AppStorage(PrefKey.curtainSubtitle) private var curtainSubtitle = Prefs.defaultCurtainSubtitle
    /// 登录项的状态在系统那边，用户也能在系统设置里改，每次打开这页重读
    @State private var loginStatus = SMAppService.mainApp.status
    /// Sparkle 自己存这个设置，改的时候要经过它才会重排检查时间
    @State private var autoUpdate = Updater.shared.automaticallyChecks

    var body: some View {
        Form {
            Section {
                Toggle("登录时打开 LockCurtain", isOn: Binding(get: { loginStatus == .enabled }, set: setOpenAtLogin))
            } header: {
                Text("启动")
            } footer: {
                if loginStatus == .requiresApproval {
                    HStack {
                        Text("还要在系统设置的登录项里允许。").foregroundStyle(.secondary)
                        Button("打开登录项设置") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
            }
            .onAppear { loginStatus = SMAppService.mainApp.status }
            Section {
                Toggle("在 Dock 中显示", isOn: $showDock)
                Toggle("在菜单栏中显示", isOn: $showMenuBar)
            } header: {
                Text("图标")
            } footer: {
                if !showDock && !showMenuBar {
                    Text("两个图标都隐藏后，在访达或启动台里再次打开 LockCurtain 即可回到这里，也可以运行 LockCurtain --send settings。")
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                    ForEach(CurtainArt.allCases) { a in
                        ArtTile(art: a, selected: a == art) { art = a }
                    }
                }
                if art == .custom {
                    LabeledContent {
                        HStack {
                            if customImage != nil {
                                Button("改回账户头像") { customImage = nil }
                            }
                            Button("选择图片…") { pickingImage = true }
                        }
                    } label: {
                        Text("图片")
                        Text(customImage == nil ? "账户头像" : "自己选的图片")
                    }
                    .fileImporter(isPresented: $pickingImage, allowedContentTypes: [.image]) { result in
                        guard case .success(let url) = result else { return }
                        // 缩小后存进设置，原图挪走、删掉都不影响
                        if let small = (try? Data(contentsOf: url)).flatMap(CurtainImage.encode) {
                            customImage = small
                        } else {
                            NSSound.beep()
                        }
                    }
                    Toggle("裁成圆形", isOn: $roundImage)
                }
            } header: {
                Text("遮罩图案")
            } footer: {
                Text(art == .custom ? "没选图片时用账户头像。选的图会缩小后存进 LockCurtain 的设置，原图删掉也不影响。下次显示遮罩时生效。"
                                    : "显示在遮罩中间、提示文案上方。下次显示遮罩时生效。")
                    .foregroundStyle(.secondary)
            }
            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                    ForEach(CurtainBackground.allCases) { b in
                        BackgroundTile(background: b, thumbnail: backgroundThumbs[b], selected: b == background) { background = b }
                    }
                }
                .task { backgroundThumbs = await BackgroundTile.thumbnails() }
            } header: {
                Text("遮罩背景")
            } footer: {
                Text("壁纸和模糊壁纸用显示遮罩时抓到的当前壁纸；星空、远山、碳纤维是程序画的，不用抓屏。下次显示遮罩时生效。")
                    .foregroundStyle(.secondary)
            }
            Section {
                TextField("标题", text: $curtainTitle, prompt: Text("不显示"))
                TextField("提示", text: $curtainSubtitle, prompt: Text("不显示"))
            } header: {
                Text("遮罩文字")
            } footer: {
                HStack {
                    Text("显示在图案下面，太长会自动换行。留空就不显示这一行。下次显示遮罩时生效。")
                        .foregroundStyle(.secondary)
                    if curtainTitle != Prefs.defaultCurtainTitle || curtainSubtitle != Prefs.defaultCurtainSubtitle {
                        Button("恢复默认") {
                            curtainTitle = Prefs.defaultCurtainTitle
                            curtainSubtitle = Prefs.defaultCurtainSubtitle
                        }
                    }
                }
            }
            Section {
                Toggle("锁屏时显示遮罩", isOn: $curtainOnLock)
            } header: {
                Text("锁屏")
            } footer: {
                Text("在系统锁屏界面上盖一层遮罩。离开模式和规则不受这个开关影响。")
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("版本", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-")
                if Updater.shared.isAvailable {
                    Toggle("自动检查更新", isOn: Binding(get: { autoUpdate }, set: {
                        autoUpdate = $0
                        Updater.shared.automaticallyChecks = $0
                    }))
                    Button("检查更新…") { Updater.shared.checkForUpdates() }
                }
            } header: {
                Text("关于")
            } footer: {
                if Updater.shared.isAvailable {
                    Text("每天检查一次 GitHub 上的新版本，有新版本时提示，点了才安装。遮罩显示时不提示、不重启。")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("登录项 %@ 失败：%@", on ? "register" : "unregister", "\(error)")
        }
        loginStatus = SMAppService.mainApp.status
    }
}

/// 图案缩略图：深色底上画一份，选中的那个在动
private struct ArtTile: View {
    let art: CurtainArt
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(Color(red: 0.10, green: 0.11, blue: 0.17))
                    if art == .none {
                        Image(systemName: "circle.slash").font(.title2).foregroundStyle(.white.opacity(0.45))
                    } else {
                        CurtainArtView(art: art, animated: selected)
                            .frame(width: art.size, height: art.size)
                            .scaleEffect(76 / art.size)
                            .frame(width: 76, height: 76)
                    }
                }
                .frame(width: 96, height: 96)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2.5))
                Text(art.title).font(.caption)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 背景缩略图：屏幕比例的小图，叠上和遮罩一样的压暗
private struct BackgroundTile: View {
    let background: CurtainBackground
    let thumbnail: CGImage?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Color.black
                    if let thumbnail {
                        Image(decorative: thumbnail, scale: 2).resizable().scaledToFill()
                        Color.black.opacity(background.dim)
                    } else if background.usesWallpaper {
                        Image(systemName: "photo").font(.title3).foregroundStyle(.white.opacity(0.45))
                    }
                }
                .frame(width: 96, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2.5))
                Text(background.title).font(.caption)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// 每种背景一张缩略图：程序画的按 480×300 点画，壁纸类用主屏的当前壁纸；纯黑没有图
    static func thumbnails() async -> [CurtainBackground: CGImage] {
        var out = await Task.detached {
            var drawn: [CurtainBackground: CGImage] = [:]
            for b in CurtainBackground.allCases {
                drawn[b] = b.render(size: CGSize(width: 480, height: 300), scale: 0.4)
            }
            return drawn
        }.value
        if let id = NSScreen.main?.displayID, let wp = await WallpaperCapture.preview(displayID: id) {
            out[.wallpaper] = wp
            out[.blurred] = await Task.detached { CurtainBackground.blurred.prepare(wp) }.value
        }
        return out
    }
}

// MARK: - 离开模式

private struct AwayPane: View {
    let actions: AppActions
    @AppStorage(PrefKey.awayKeepDisplayOn) private var keepDisplayOn = true
    @AppStorage(PrefKey.awayDimBrightness) private var dimBrightness = false

    var body: some View {
        Form {
            Section {
                Toggle("屏幕常亮", isOn: $keepDisplayOn)
                Toggle("亮度调到最低", isOn: $dimBrightness)
            } header: {
                Text("防休眠")
            } footer: {
                Text("关掉「屏幕常亮」后只阻止系统休眠，屏幕可以熄灭；如果系统设置了熄屏后立即要求密码，会话会被锁上。亮度只对内置屏有效，撤掉遮罩时恢复。设置在下次进入离开模式时生效。")
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("回来时") { Text("碰一下键盘或鼠标：先锁屏，再撤掉遮罩") }
                Button("立即进入离开模式", action: actions.enterAway)
            } header: {
                Text("离开模式")
            } footer: {
                Text("遮罩期间你的按键和点击会被吞掉，不会传给下层的 app；agent 的合成输入照常穿透。")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 远程控制

private struct RemotePane: View {
    private let cli = Bundle.main.executablePath ?? "/Applications/LockCurtain.app/Contents/MacOS/LockCurtain"
    private let commands: [(String, String)] = [
        ("away", "进入离开模式（App 没运行时会先拉起）"),
        ("hide", "撤掉遮罩；离开模式下先锁屏再撤"),
        ("status", "查询状态，输出一行 JSON"),
        ("preview", "显示预览遮罩"),
        ("settings", "打开这个窗口"),
    ]

    var body: some View {
        Form {
            Section("命令行") {
                LabeledContent("路径") {
                    HStack {
                        Text(cli).font(.system(.body, design: .monospaced)).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                        Button("拷贝") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(cli, forType: .string)
                        }
                    }
                }
                ForEach(commands, id: \.0) { c in
                    LabeledContent {
                        Text(c.1).foregroundStyle(.secondary)
                    } label: {
                        Text("--send \(c.0)").font(.system(.body, design: .monospaced))
                    }
                }
            }
            Section {
                Text("1. 系统设置 → 通用 → 共享 → 打开「远程登录」，建议只允许密钥登录")
                Text("2. 快捷指令里添加「通过 SSH 运行脚本」，脚本填：命令行路径 --send away")
                Text("3. iPhone 和 Mac 不在同一网络时，用组网工具（如 Surge Ponte）连到 Mac")
            } header: {
                Text("用 iPhone 快捷指令远程控制")
            } footer: {
                Text("App 本身不监听任何网络端口，只接受本机当前用户的连接。远程开启要求 Mac 醒着。")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 权限

private struct PermissionsPane: View {
    let actions: AppActions
    @State private var screenRecording = CGPreflightScreenCaptureAccess()
    @State private var accessibility = AXIsProcessTrusted()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                row("屏幕录制", ok: screenRecording, detail: "读取当前壁纸，画遮罩背景") {
                    _ = CGRequestScreenCaptureAccess()
                    open("Privacy_ScreenCapture")
                }
                row("辅助功能", ok: accessibility, detail: "监听并吞掉真人输入，碰一下就退出遮罩") {
                    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                    _ = AXIsProcessTrustedWithOptions(opts)
                }
            } header: {
                Text("系统权限")
            } footer: {
                Text("屏幕录制授权后需要重启 App 才生效。")
                    .foregroundStyle(.secondary)
            }
            Section("诊断") {
                Button("抓取当前壁纸", action: actions.grabWallpaper)
            }
        }
        .formStyle(.grouped)
        .onReceive(timer) { _ in
            screenRecording = CGPreflightScreenCaptureAccess()
            accessibility = AXIsProcessTrusted()
        }
    }

    private func row(_ title: String, ok: Bool, detail: String, request: @escaping () -> Void) -> some View {
        LabeledContent {
            if ok {
                Label("已授权", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("去授权", action: request)
            }
        } label: {
            Text(title)
            Text(detail)
        }
    }

    private func open(_ anchor: String) {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(u)
        }
    }
}
