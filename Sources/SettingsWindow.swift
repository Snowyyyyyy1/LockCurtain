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
    /// 抓完回调（按钮字换成「已抓取」）
    var grabWallpaper: (@escaping () -> Void) -> Void
    var openPairing: () -> Void
    var openStartGuide: () -> Void
    /// 蓝牙权限还没问过：建 CBCentralManager 让系统弹框
    var requestBluetooth: () -> Void
}

/// 设置窗口现在在哪一页；面板「手机」一行、右键菜单「到指定时间…」从外面切页
@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var pane: Pane? = .general
    /// 保持唤醒页：打开时直接显示选钟点那一行
    @Published var pickTime = false
}

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let store: RuleStore
    private let actions: AppActions
    private let pairing: PhonePairing
    private let keepAwake: KeepAwake
    let nav = SettingsNavigation()

    init(store: RuleStore, actions: AppActions, pairing: PhonePairing, keepAwake: KeepAwake) {
        self.store = store
        self.actions = actions
        self.pairing = pairing
        self.keepAwake = keepAwake
    }

    func show(_ pane: Pane) {
        nav.pane = pane
        show()
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
            let host = NSHostingController(rootView: SettingsView(store: store, actions: actions, pairing: pairing,
                                                                  keepAwake: keepAwake, nav: nav))
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

/// 侧栏顺序（A1，两端一致）：通用 / 手机 / 离开模式 / 保持唤醒 / 规则 / 远程控制 / 权限
enum Pane: String, CaseIterable, Identifiable {
    case general, phone, away, keepAwake, rules, remote, permissions
    var id: Self { self }
    var title: String {
        switch self {
        case .general: "通用"
        case .phone: "手机"
        case .away: "离开模式"
        case .keepAwake: "保持唤醒"
        case .rules: "规则"
        case .remote: "远程控制"
        case .permissions: "权限"
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .phone: "iphone"
        case .away: "figure.walk.departure"
        case .keepAwake: "cup.and.saucer"
        case .rules: "list.bullet.rectangle"
        case .remote: "network"
        case .permissions: "hand.raised"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var store: RuleStore
    let actions: AppActions
    @ObservedObject var pairing: PhonePairing
    @ObservedObject var keepAwake: KeepAwake
    @ObservedObject var nav: SettingsNavigation

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $nav.pane) { p in
                Label(p.title, systemImage: p.symbol).tag(p)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 180, max: 220)
        } detail: {
            Group {
                switch nav.pane ?? .general {
                case .general: GeneralPane(actions: actions)
                case .phone: PhonePane(pairing: pairing, openPairing: actions.openPairing)
                case .away: AwayPane(actions: actions)
                case .keepAwake: KeepAwakePane(keepAwake: keepAwake, nav: nav)
                case .rules: RulesPane(store: store)
                case .remote: RemotePane()
                case .permissions: PermissionsPane(actions: actions, pairing: pairing)
                }
            }
            .navigationTitle((nav.pane ?? .general).title)
        }
        .frame(minWidth: 680, minHeight: 440)
    }
}

// MARK: - 通用

private struct GeneralPane: View {
    let actions: AppActions
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
    /// nil = 没改过，跟着「回来时」变（D6）
    @AppStorage(PrefKey.curtainSubtitle) private var storedSubtitle: String?
    @AppStorage(PrefKey.awayUnlock) private var awayUnlock = AwayUnlock.lockScreen
    /// D11：登录项没加进去 / 图片打不开 的一行结果，1.5 秒后消失
    @State private var loginError: String?
    @State private var imageFailed = false
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
                if let loginError {
                    Text("没加进登录项：\(loginError)").foregroundStyle(.red)
                } else if loginStatus == .requiresApproval {
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
                        // 沙盒外的 App 也照样包一层：从「最近使用」里选的文件要这样才读得到
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        if let small = (try? Data(contentsOf: url)).flatMap(CurtainImage.encode) {
                            customImage = small
                        } else {
                            imageFailed = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { imageFailed = false }
                        }
                    }
                    if imageFailed {
                        Text("这张图打不开，换一张").foregroundStyle(.red)
                    }
                    Toggle("裁成圆形", isOn: $roundImage)
                }
            } header: {
                Text("幕布图案")
            } footer: {
                Text(art == .custom ? "没选图片时用账户头像。选的图会缩小后存进 LockCurtain 的设置，原图删掉也不影响。下次盖上幕布时生效。"
                                    : "显示在幕布中间、提示文案上方。下次盖上幕布时生效。")
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
                Text("幕布背景")
            } footer: {
                Text("壁纸和模糊壁纸用盖上幕布时抓到的当前壁纸；星空、远山、碳纤维是程序画的，不用抓屏。下次盖上幕布时生效。")
                    .foregroundStyle(.secondary)
            }
            Section {
                TextField("标题", text: $curtainTitle, prompt: Text("不显示"))
                TextField("提示", text: Binding(
                    get: { storedSubtitle ?? Prefs.defaultCurtainSubtitle(for: .away, unlock: awayUnlock) },
                    set: { storedSubtitle = $0 }), prompt: Text("不显示"))
            } header: {
                Text("幕布文字")
            } footer: {
                HStack {
                    Text("显示在图案下面，太长会自动换行。留空就不显示这一行。下次盖上幕布时生效。")
                        .foregroundStyle(.secondary)
                    if curtainTitle != Prefs.defaultCurtainTitle || Prefs.customCurtainSubtitle != nil {
                        Button("恢复默认") {
                            curtainTitle = Prefs.defaultCurtainTitle
                            storedSubtitle = nil
                        }
                    }
                }
            }
            Section {
                Toggle("锁屏时也盖上幕布", isOn: $curtainOnLock)
            } header: {
                Text("锁屏")
            } footer: {
                Text("在系统锁屏界面上盖一层幕布。离开模式和规则不受这个开关影响。")
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
                Button("再看一遍开始指南", action: actions.openStartGuide)
            } header: {
                Text("关于")
            } footer: {
                if Updater.shared.isAvailable {
                    Text("每天检查一次 GitHub 上的新版本，有新版本时提示，点了才安装。幕布盖着的时候不提示、不重启。")
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
            if on {
                loginError = error.localizedDescription
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { loginError = nil }
            }
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
    @AppStorage(PrefKey.awayUnlock) private var unlock = AwayUnlock.lockScreen

    var body: some View {
        Form {
            Section {
                Toggle("屏幕常亮", isOn: $keepDisplayOn)
                Toggle("亮度调到最低", isOn: $dimBrightness)
            } header: {
                Text("防休眠")
            } footer: {
                Text("关掉「屏幕常亮」后只阻止系统休眠，屏幕可以熄灭；如果系统设置了熄屏后立即要求密码，会话会被锁上。亮度只对内置屏有效，撤下幕布时恢复。设置在下次进入离开模式时生效。")
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker("回来时", selection: $unlock) {
                    Text("先锁屏，再撤下幕布").tag(AwayUnlock.lockScreen)
                    Text("验证 Mac 密码或触控 ID，通过后撤下幕布").tag(AwayUnlock.systemAuth)
                }
                Button("盖上幕布", action: actions.enterAway)
            } header: {
                Text("离开模式")
            } footer: {
                Text("幕布盖着的时候，你的按键、点击、滚动、鼠标移动和触控板手势都会被吞掉，不会传给下层的 app；agent 的合成输入照常穿透。选「验证」时，按一下键盘或点一下，幕布下方出现解锁面板，像锁屏一样输密码或用触控 ID；密码由系统在本机核对，LockCurtain 只拿到通过与否，不保存。通过就直接撤下幕布，连错 3 次改成先锁屏再撤；Esc 或 60 秒没操作只收起面板，幕布留着。设置在下次进入离开模式时生效。")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 远程控制

private struct RemotePane: View {
    /// 页面上永远是能跑的那一行：真实的可执行文件路径（有空格就加引号）+ --send away（Camo §16.9）
    private let line: String = {
        let cli = Bundle.main.executablePath ?? "/Applications/LockCurtain.app/Contents/MacOS/LockCurtain"
        return (cli.contains(" ") ? "\"\(cli)\"" : cli) + " --send away"
    }()
    @State private var copied = false

    var body: some View {
        Form {
            Section {
                HStack {
                    Text(line).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        .lineLimit(2).truncationMode(.middle)
                    Spacer()
                    Button(copied ? "已拷贝" : "拷贝") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(line, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    }
                }
            } header: {
                Text("命令行")
            } footer: {
                Text("一行命令进，一行 JSON 出；成功时退出码 0。App 本身不监听任何网络端口，只接受本机当前用户的连接。把 away 换成 hide、status、preview、settings，就是另外四个命令。照这行抄，别自己改。")
                    .foregroundStyle(.secondary)
            }
            Section {
                Text("1. 系统设置 → 通用 → 共享 → 打开「远程登录」，建议只允许密钥登录")
                Text("2. 快捷指令里添加「通过 SSH 运行脚本」，脚本填上面「命令行」那一行")
                Text("3. iPhone 和 Mac 不在同一网络时，用组网工具（如 Surge Ponte）连到 Mac")
            } header: {
                Text("用 iPhone 快捷指令远程控制")
            } footer: {
                Text("远程开启要求 Mac 醒着。")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 权限

private struct PermissionsPane: View {
    let actions: AppActions
    @ObservedObject var pairing: PhonePairing
    @State private var screenRecording = SystemPermissions.screenRecording
    @State private var accessibility = SystemPermissions.accessibility
    @State private var bluetooth = SystemPermissions.bluetooth
    @State private var grabbed = false
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                row("屏幕录制", ok: screenRecording, detail: "读取当前壁纸，画幕布背景",
                    request: SystemPermissions.requestScreenRecording)
                row("辅助功能", ok: accessibility, detail: "监听并吞掉真人输入，一碰就撤下幕布",
                    request: SystemPermissions.requestAccessibility)
                // copy v15 §17.1-2
                row("蓝牙", ok: bluetooth == .allowed, detail: "用来和配对的手机连接。关掉的话，手机就找不到这台电脑。") {
                    if bluetooth == .notDetermined { actions.requestBluetooth() } else { SystemPermissions.openPrivacy("Privacy_Bluetooth") }
                }
            } header: {
                Text("系统权限")
            } footer: {
                // 只有这次运行里屏幕录制从没授权变成已授权，才要重开（别的权限改了当场生效）
                if !SystemPermissions.screenRecordingAtLaunch && screenRecording {
                    HStack {
                        Text("改完要重新打开 LockCurtain 才生效。").foregroundStyle(.secondary)
                        Button("重新打开 LockCurtain", action: SystemPermissions.relaunch)
                    }
                }
            }
            Section("排查信息") {
                Button(grabbed ? "已抓取" : "抓取当前壁纸") {
                    actions.grabWallpaper {
                        grabbed = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { grabbed = false }
                    }
                }
                Button("打开日志文件夹", action: LogFolder.open)
            }
        }
        .formStyle(.grouped)
        .onReceive(timer) { _ in
            screenRecording = SystemPermissions.screenRecording
            accessibility = SystemPermissions.accessibility
            bluetooth = SystemPermissions.bluetooth
        }
    }

    private func row(_ title: String, ok: Bool, detail: String, request: @escaping () -> Void) -> some View {
        LabeledContent {
            if ok {
                Label("已授权", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("打开设置", action: request)
            }
        } label: {
            Text(title)
            Text(detail)
        }
    }
}

// MARK: - 手机（A1）

struct PhonePane: View {
    @ObservedObject var pairing: PhonePairing
    let openPairing: () -> Void
    @State private var confirming: PhonePairing.PhoneInfo?

    private static let footer = "手机能做的：盖上幕布；你走近、手机解锁着时撤下幕布；开关保持唤醒。"

    var body: some View {
        VStack(spacing: 0) {
            if let banner { banner.padding([.horizontal, .top], 20) }
            if pairing.phones.isEmpty { empty } else { list }
        }
        .alert("撤销这台手机的配对？", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
               presenting: confirming) { phone in
            Button("取消", role: .cancel) { confirming = nil }
            // 撤完那一行直接消失，不弹「已撤销」，也不再打开配对窗口（D3b）
            Button("撤销配对", role: .destructive) {
                pairing.unpair(phone.id)
                confirming = nil
            }
        } message: { _ in
            Text("撤销后，这台手机要重新输码才能再盖上幕布。其他手机的配对不受影响。")
        }
    }

    /// 蓝牙用不了：叠在上面的一条黄色横幅（状态 3）
    private var banner: AnyView? {
        let radio: PhonePairing.Radio = SystemPermissions.bluetooth == .denied ? .unauthorized : pairing.radio
        let text: String
        var button: (String, () -> Void)?
        switch radio {
        case .off:
            text = "蓝牙关了，手机连不上。"
            // COPY-TODO: 按钮字 Camo 没写，用 Colo 布局里的「打开蓝牙设置」
            button = ("打开蓝牙设置", SystemPermissions.openBluetoothSettings)
        case .unauthorized:
            text = "没拿到蓝牙权限。"
            // COPY-TODO: 按钮字 Camo 没写；Colo 写「去授权」，按 D4 统一成「打开设置」
            button = ("打开设置", { SystemPermissions.openPrivacy("Privacy_Bluetooth") })
        case .unsupported:
            text = "这台电脑的蓝牙用不了，手机连不上。"
        case .on, .unknown:
            return nil
        }
        return AnyView(GroupBox {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color(nsColor: .systemYellow))
                Text(text)
                Spacer()
                if let button { Button(button.0, action: button.1) }
            }
            .padding(4)
        })
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "iphone").font(.system(size: 40)).foregroundStyle(.tertiary)
            Text("还没配对手机").font(.headline)
            Text("配对以后，手机上能盖上幕布、走近时撤下幕布，还能开关保持唤醒。")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            Text("手机上先装 LockCurtain。").foregroundStyle(.secondary)
            Button("配对手机…", action: openPairing).buttonStyle(.borderedProminent).padding(.top, 6)
            Spacer()
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        Form {
            Section {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    ForEach(pairing.phones) { phone in row(phone, now: context.date) }
                }
            } header: {
                Text("已配对的手机")
            }
            Section {
                Button("配对手机…", action: openPairing)
            } footer: {
                Text(Self.footer).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ phone: PhonePairing.PhoneInfo, now: Date) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "iphone").font(.system(size: 24)).foregroundStyle(.secondary).frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Self.title(phone)
                HStack(spacing: 6) {
                    Circle().fill(phone.connected ? Color(nsColor: .systemGreen) : Color(nsColor: .systemGray))
                        .frame(width: 8, height: 8)
                    Text(status(phone, now: now)).font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("撤销配对") { confirming = phone }
        }
        .padding(.vertical, 2)
    }

    private func status(_ phone: PhonePairing.PhoneInfo, now: Date) -> String {
        if phone.connected { return "已连上" }
        guard let seen = phone.lastSeen else { return "没连上" }
        return "没连上 · 上次连上：\(Self.ago(seen, now: now))"
    }

    /// 「iPhone · 11 月 4 日配上」：名字正常颜色，配上的日期次要颜色，同一行（开始指南也用）
    static func title(_ phone: PhonePairing.PhoneInfo, prefix: String = "") -> Text {
        guard let at = phone.pairedAt else { return Text(prefix + phone.name) }
        let date = Text(" · \(monthDay(at))配上").foregroundColor(.secondary)
        return Text("\(prefix + phone.name)\(date)")
    }

    /// 11 月 4 日
    static func monthDay(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.month, .day], from: d)
        return "\(c.month ?? 0) 月 \(c.day ?? 0) 日"
    }

    /// 刚刚 / N 分钟前 / N 小时前 / 昨天 / M 月 D 日（Camo §16.1，只用这五种）
    static func ago(_ d: Date, now: Date) -> String {
        let s = now.timeIntervalSince(d)
        if s < 60 { return "刚刚" }
        if s < 3600 { return "\(Int(s / 60)) 分钟前" }
        let cal = Calendar.current
        if cal.isDate(d, inSameDayAs: now) { return "\(Int(s / 3600)) 小时前" }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(d, inSameDayAs: y) { return "昨天" }
        return monthDay(d)
    }
}

// MARK: - 保持唤醒（A3）

private struct KeepAwakePane: View {
    @ObservedObject var keepAwake: KeepAwake
    @ObservedObject var nav: SettingsNavigation
    @State private var endTime = KeepAwakeText.defaultEndTime()

    var body: some View {
        Form {
            Section {
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    if let until = keepAwake.until {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("LockCurtain 保持唤醒")
                                // COPY-TODO: 「· 手机开的」是 Colo 布局里的字，Camo 没单独给
                                Text(KeepAwakeText.detail(until) + (keepAwake.fromPhone ? " · 手机开的" : ""))
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer()
                            // 带边框的下拉按钮，和「停止」一样高、一样的样子，中间 8pt
                            HStack(spacing: 8) {
                                KeepAwakePullDown(title: "改时长", keepAwake: keepAwake) {
                                    endTime = KeepAwakeText.defaultEndTime()
                                    nav.pickTime = true
                                }
                                Button("停止") { keepAwake.stop() }
                                    .buttonStyle(.bordered)
                            }
                        }
                    } else {
                        HStack {
                            Text("关")
                            Spacer()
                            Menu("开始") { items }.fixedSize()
                        }
                    }
                }
                if nav.pickTime {
                    KeepAwakeTimePicker(keepAwake: keepAwake, endTime: $endTime) { nav.pickTime = false }
                }
            } header: {
                Text("保持唤醒")
            } footer: {
                Text("不盖幕布，只让电脑不睡；屏幕照样会熄灭。手机上也能开关。离开模式里的防休眠是另一件事，在「离开模式」那一页。")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var items: some View {
        KeepAwakeMenuItems(keepAwake: keepAwake) {
            endTime = KeepAwakeText.defaultEndTime()
            nav.pickTime = true
        }
    }
}
