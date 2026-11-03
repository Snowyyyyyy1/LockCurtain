import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showSettings = false
    @State private var showPairing = false
    @Namespace private var glassNS

    var body: some View {
        ScrollViewReader { proxy in
            list
            #if DEBUG
            .task {
                // 截图用：-lcScrollToStatus 一启动就滚到「幕布 / 这台 Mac」那组
                if ProcessInfo.processInfo.arguments.contains("-lcScrollToStatus") {
                    try? await Task.sleep(for: .milliseconds(800))
                    proxy.scrollTo("status", anchor: .top)
                }

            }
            #endif
        }
    }

    private var list: some View {
        List {
            if isAXSize {
                // v2.7.4 大字：不放示意图；「幕布」单独一组，说明紧贴在「已盖上」下面；「这台 Mac」另起一组
                Section {
                    curtainRow
                } footer: {
                    curtainFooterAX
                }
                .id("status")

                Section {
                    macRow
                    if AppModel.autoCoverVisible {
                        autoRow
                    }
                } footer: {
                    macFooterAX
                }
                .id("mac")
            } else {
                Section {
                    MacScreenIllustration(
                        state: model.screenState,
                        showsDemoBadge: model.demoMode
                    )
                    .frame(maxWidth: .infinity)
                    .listRowInsets(EdgeInsets(top: 20, leading: 0, bottom: 16, trailing: 0))
                }

                Section {
                    curtainRow
                    macRow
                    if AppModel.autoCoverVisible {
                        autoRow
                    }
                } footer: {
                    standardFooter
                }
                .id("status")
            }

            if model.demoMode {
                demoSection
                    .id("demo")
            }
        }
        .listStyle(.insetGrouped)
        #if DEBUG
        // 截图用：-lcScrollToBottom 一启动就停在最底（真正的最大滚动位置，含底栏让出的空间）
        .background {
            if ProcessInfo.processInfo.arguments.contains("-lcScrollToBottom") {
                DebugScrollToBottom()
            }
        }
        #endif
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .navigationTitle("LockCurtain")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("设置", systemImage: "gearshape") {
                    showSettings = true
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.demoMode {
                demoBanner
            }
        }
        .safeAreaBar(edge: .bottom, spacing: 0) {
            if showsBottomBar {
                bottomBar
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        #if DEBUG
        .onAppear {
            // 截图用：-lcOpenSettings 一启动就打开设置
            if ProcessInfo.processInfo.arguments.contains("-lcOpenSettings") {
                showSettings = true
            }
        }
        #endif
        .sheet(isPresented: $showPairing) {
            PairingSheet()
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: model.coverTapCount)
        .sensoryFeedback(.success, trigger: model.phase) { _, newPhase in
            newPhase == .closed && model.connection == .connected
        }
        .sensoryFeedback(.warning, trigger: model.didTimeOut) { _, isTimedOut in
            isTimedOut
        }
        .sensoryFeedback(.impact(weight: .light), trigger: model.liftTapCount)
        .sensoryFeedback(.impact(weight: .light), trigger: model.findAgainTapCount)
        .sensoryFeedback(.warning, trigger: model.liftWarningCount)
        .sensoryFeedback(.success, trigger: model.showLiftedNote) { _, isShown in
            isShown
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background { model.appDidEnterBackground() }
            if newPhase == .active { model.appDidBecomeActive() }
        }
    }

    // MARK: - Rows

    private var curtainRow: some View {
        LabeledContent {
            Text(model.curtainDisplayValue)
                .foregroundStyle(.secondary)
        } label: {
            Label {
                HStack(spacing: 6) {
                    Text("幕布")
                    if model.demoMode {
                        demoTagsmall
                    }
                }
            } icon: {
                Image(systemName: curtainSymbol)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("幕布")
        .accessibilityValue(model.curtainVoiceValue)
    }

    private var macRow: some View {
        LabeledContent {
            if model.unlinkedMacState == .waiting {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(model.macDisplayValue)
                }
                .foregroundStyle(.secondary)
            } else {
                Text(model.macDisplayValue)
                    .foregroundStyle(.secondary)
            }
        } label: {
            Label("这台 Mac", systemImage: "laptopcomputer")
        }
    }

    private var autoRow: some View {
        Button {
            showSettings = true
        } label: {
            HStack(spacing: 8) {
                Label {
                    Text("自动")
                        .foregroundStyle(.primary)
                } icon: {
                    Image(systemName: "figure.walk")
                        .foregroundStyle(.tint)
                }
                Spacer(minLength: 8)
                Text(model.autoDisplayValue)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private var curtainSymbol: String {
        switch model.screenState {
        case .curtain, .closing, .lifting:
            "curtains.closed"
        case .desktop, .empty:
            "curtains.open"
        }
    }

    // MARK: - Footer

    /// 连续断了 5 次、已经停下不再重连：主屏换成「连不上这台 Mac。」那一套，不再显示一般的排查提示
    private var showsGaveUp: Bool {
        model.connectionGaveUp && model.paired && !model.demoMode && model.connection != .connected
    }

    /// 辅助功能大字（AX1–AX5）：说明和状态行从底部玻璃挪到「幕布 / 这台 Mac」分组的 footer，底部只留一颗全宽「现在撤下」
    private var isAXSize: Bool { dynamicTypeSize.isAccessibilitySize }

    /// 已连上、不在「连不上」那一套里
    private var showsLiftFooter: Bool {
        isAXSize && !showsGaveUp && model.connection == .connected
    }

    /// 幕布盖着、不在「正在盖上…」：两行说明该出现的时候
    private var showsClosedNote: Bool {
        model.phase == .closed && !model.isPending
    }

    /// 大字：「幕布」组的 footer = 状态行 + 两行说明（已连上时）
    @ViewBuilder
    private var curtainFooterAX: some View {
        if showsLiftFooter {
            VStack(alignment: .leading, spacing: 8) {
                axLiftFooter
            }
        }
    }

    /// 大字：「这台 Mac」组的 footer = 连接相关的提示（刚配好 / 没连上的排查）
    @ViewBuilder
    private var macFooterAX: some View {
        if showsLiftFooter {
            if model.justPaired {
                VStack(alignment: .leading, spacing: 8) {
                    Text("以后它自己会连上；万一断了，打开 LockCurtain 等一下就好。")
                    if model.liftOnApproach && !showsClosedNote {
                        Text("以后回到电脑前，手机解锁着、走近，幕布就撤下。")
                    }
                }
            }
        } else {
            standardFooter
        }
    }

    /// AX 大字时 footer 里的状态行 + 两行说明
    @ViewBuilder
    private var axLiftFooter: some View {
        if showsClosedNote {
            if let notice = model.liftNotice, notice != .alreadyUncovered {
                Text(liftNoticeText(notice))
            }
            VStack(alignment: .leading, spacing: 2) {
                // footer 默认整体是 secondary：第一行显式 Color.primary + 半粗，第二行显式 secondary
                Text(model.liftOnApproach
                     ? "回到电脑前，手机解锁着、走近，幕布就撤下。"
                     : "回到电脑前按任意键解锁。")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.primary)
                Text(model.liftOnApproach
                     ? "手机锁着不算，别人拿着也撤不下来。"
                     : "「走近撤下」关着，手机撤不下来。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        } else if !model.didTimeOut {
            if model.liftNotice == .alreadyUncovered {
                Text("幕布已经是撤下的了。")
            } else if model.showLiftedNote {
                Text("幕布撤下了。Mac 要是自己锁了屏，还得照常输密码。")
            }
        }
    }

    @ViewBuilder
    private var standardFooter: some View {
        if showsGaveUp {
            EmptyView()
        } else if model.justPaired && model.connection != .notPaired {
            VStack(alignment: .leading, spacing: 8) {
                genericFooter
                Text("以后它自己会连上；万一断了，打开 LockCurtain 等一下就好。")
                if model.liftOnApproach {
                    Text("以后回到电脑前，手机解锁着、走近，幕布就撤下。")
                }
            }
        } else {
            genericFooter
        }
    }

    @ViewBuilder
    private var genericFooter: some View {
        if let state = model.unlinkedMacState {
            // 配过对、没连上的三种：等这台 Mac 来连… / 没连上 / 蓝牙关了
            Text(state.footer)
        } else {
            switch model.connection {
            case .notPaired:
                Text("在 Mac 上打开 LockCurtain，点「配对手机」，把 6 位码输进来。")
            case .bluetoothOff:
                Text(AppModel.UnlinkedMacState.bluetoothOff.footer)
            case .notConnected, .connected:
                EmptyView()
            }
        }
    }

    // MARK: - Bottom bar

    private var showsBottomBar: Bool {
        if showsLiftFooter && showsClosedNote && !model.liftOnApproach {
            return false   // AX 大字、「走近撤下」关着：两行在 footer，底部什么都没有
        }
        return model.connection == .connected || model.connection == .notPaired || showsGaveUp
            || model.unlinkedMacState == .stopped
    }

    private var bottomBar: some View {
        GlassEffectContainer {
            VStack(spacing: 10) {
                if showsGaveUp {
                    GaveUpNotice(prominent: true) {
                        model.prepareForPairing()
                    }
                    .transition(.opacity)
                } else if model.connection == .notPaired {
                    Button {
                        showPairing = true
                    } label: {
                        Text("去配对")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 3)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .glassEffectID("action", in: glassNS)
                    .transition(.opacity)
                } else if model.unlinkedMacState == .stopped {
                    // 「没连上」：和「盖上幕布」同一个位置、同样大小
                    Button {
                        model.findMacAgain()
                    } label: {
                        Text(AppModel.UnlinkedMacState.retryButtonTitle)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 3)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .glassEffectID("action", in: glassNS)
                    .transition(.opacity)
                } else if showsClosedNote && showsLiftFooter {
                    axLiftButton
                        .transition(.opacity)
                } else if showsClosedNote {
                    closedNote
                        .glassEffect(.clear, in: .rect(cornerRadius: 26))
                        .glassEffectID("action", in: glassNS)
                        .transition(.opacity)
                } else {
                    if model.didTimeOut {
                        Text("Mac 没有回应，状态没变。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .transition(.opacity)
                    } else if showsLiftFooter {
                        // AX 大字：撤下后的那两句在 footer 里
                    } else if model.liftNotice == .alreadyUncovered {
                        Text("幕布已经是撤下的了。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .transition(.opacity)
                    } else if model.showLiftedNote {
                        Text("幕布撤下了。Mac 要是自己锁了屏，还得照常输密码。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .transition(.opacity)
                    }
                    coverButton
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity)
        }
        .animation(.smooth(duration: 0.35), value: model.phase)
        .animation(.smooth(duration: 0.35), value: model.isPending)
        .animation(.smooth(duration: 0.35), value: model.didTimeOut)
        .animation(.smooth(duration: 0.35), value: model.connection)
        .animation(.smooth(duration: 0.35), value: model.connectionGaveUp)
        .animation(.smooth(duration: 0.35), value: model.unlinkedMacState)
        .animation(.smooth(duration: 0.35), value: model.isLifting)
        .animation(.smooth(duration: 0.35), value: model.liftNotice)
        .animation(.smooth(duration: 0.35), value: model.showLiftedNote)
    }

    @ViewBuilder
    private var coverButton: some View {
        if model.isPending {
            Button {
            } label: {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("正在盖上…")
                }
                .padding(.vertical, 3)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(true)
            .glassEffectID("action", in: glassNS)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
        } else {
            Button {
                model.cover()
            } label: {
                Label(
                    model.didTimeOut ? "再试一次" : "盖上幕布",
                    systemImage: "curtains.closed"
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .glassEffectID("action", in: glassNS)
            .accessibilityHint("发给这台 Mac，盖上幕布")
        }
    }

    /// 幕布盖着：「走近撤下」开着时两行说明 + 现在撤下；关着时两行说明、没有按钮
    private var closedNote: some View {
        VStack(spacing: 10) {
            if let notice = model.liftNotice, notice != .alreadyUncovered {
                Text(liftNoticeText(notice))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
            VStack(spacing: 2) {
                if model.liftOnApproach {
                    Text("回到电脑前，手机解锁着、走近，幕布就撤下。")
                        .font(.subheadline.weight(.semibold))
                    Text("手机锁着不算，别人拿着也撤不下来。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("回到电脑前按任意键解锁。")
                        .font(.subheadline.weight(.semibold))
                    Text("「走近撤下」关着，手机撤不下来。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            if model.liftOnApproach {
                liftButton
            }
        }
        .multilineTextAlignment(.center)
        .padding(.top, 14)
        .padding(.bottom, model.liftOnApproach ? 6 : 14)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var liftButton: some View {
        if model.isLifting {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("正在撤下…")
            }
            .font(.body.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(minHeight: 44)
            .accessibilityElement(children: .combine)
        } else {
            Button(model.liftNotice == .timedOut ? "再试一次" : "现在撤下") {
                model.liftNow()
            }
            .font(.body.weight(.semibold))
            .buttonStyle(.borderless)
            .frame(minHeight: 44)
            .accessibilityHint("先验证面容，再撤下这台 Mac 的幕布")
        }
    }

    /// AX 大字时底部唯一的按钮：全宽玻璃「现在撤下」，变体同 liftButton
    @ViewBuilder
    private var axLiftButton: some View {
        if model.isLifting {
            Button {
            } label: {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("正在撤下…")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .disabled(true)
            .glassEffectID("action", in: glassNS)
            .accessibilityElement(children: .combine)
        } else {
            Button {
                model.liftNow()
            } label: {
                Text(model.liftNotice == .timedOut ? "再试一次" : "现在撤下")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 3)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .glassEffectID("action", in: glassNS)
            .accessibilityHint("先验证面容，再撤下这台 Mac 的幕布")
        }
    }

    private func liftNoticeText(_ notice: AppModel.LiftNotice) -> String {
        switch notice {
        case .timedOut: "Mac 没有回应，幕布还盖着。"
        case .tooFar: "离这台 Mac 太远，走近再试。"
        case .refused: "这次没撤下来，再按一次。"
        case .alreadyUncovered: "幕布已经是撤下的了。"
        }
    }

    // MARK: - Demo

    private var demoBanner: some View {
        demoBannerContent
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            // 不透明的页面底色垫底，再叠 14% 橙：列表滚到横幅下面也透不出来
            RoundedRectangle(cornerRadius: 18)
                .fill(Color(.systemGroupedBackground))
                .overlay(RoundedRectangle(cornerRadius: 18).fill(.orange.opacity(0.14)))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(.systemGroupedBackground), ignoresSafeAreaEdges: [])
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("演示，下面是模拟状态，没有连接任何 Mac")
    }

    private var demoBannerContent: some View {
        HStack(spacing: 8) {
            Text("演示")
                .font(.caption.bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(.orange, in: .capsule)
                .foregroundStyle(.black)
            // 大字时横幅一直钉在上面，只放短句，免得占掉小半屏；VoiceOver 读整句（见 demoBanner）
            Text(isAXSize ? "模拟状态" : "下面是模拟状态，没有连接任何 Mac")
                .font(.footnote)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var demoTagsmall: some View {
        Text("演示")
            .font(.caption2.bold())
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(.orange, in: .rect(cornerRadius: 6))
            .foregroundStyle(.black)
            .accessibilityHidden(true)
    }

    private var demoSection: some View {
        Section("演示里切换") {
            Picker(
                "演示里切换",
                selection: Binding(
                    get: { model.demoScenario },
                    set: { model.selectDemoScenario($0) }
                )
            ) {
                Text("已连上这台 Mac").tag(AppModel.DemoScenario.connected)
                Text("幕布已盖上").tag(AppModel.DemoScenario.closed)
                Text("幕布撤下了").tag(AppModel.DemoScenario.lifted)
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }
}

/// 连续断了几次、已经不再自己重连时显示：主屏和配对页共用同一套文字
struct GaveUpNotice: View {
    /// 主屏底栏用玻璃大按钮；配对页里用普通的 bordered 按钮
    var prominent = false
    var retry: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            VStack(spacing: 4) {
                Text("连不上这台 Mac。")
                    .font(prominent ? .subheadline.weight(.semibold) : .title2.bold())
                Text("已经试了 5 次，先停在这儿。")
                    .font(prominent ? .subheadline : .body)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .accessibilityElement(children: .combine)

            if prominent {
                Button(action: retry) {
                    Text("再试一次")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 3)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            } else {
                Button("再试一次", action: retry)
                    .buttonStyle(.bordered)
                    .padding(.top, 6)
            }

            Text("在你回来之前，我不会自己在后台重连。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}

#Preview {
    NavigationStack {
        HomeView()
            .environment(AppModel())
    }
}

#if DEBUG
/// 截图用：-lcScrollToBottom 时找到 List 底下的 UIScrollView，滚到真正的最底（含底栏让出的 inset），并打印 inset 方便查
private struct DebugScrollToBottom: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.isUserInteractionEnabled = false
        // 自适应高度的行要滚到了才量准，contentSize 会变：多滚几次直到不再变
        for i in 0..<5 { DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 + Double(i) * 0.4) {
            guard let window = v.window,
                  let sv = Self.scrollViews(in: window).max(by: { $0.contentSize.height < $1.contentSize.height })
            else { print("lcScroll: no scroll view"); return }
            let maxY = sv.contentSize.height + sv.adjustedContentInset.bottom - sv.bounds.height
            sv.setContentOffset(CGPoint(x: 0, y: max(-sv.adjustedContentInset.top, maxY)), animated: false)
            let msg = "lcScroll: content=\(sv.contentSize.height) bounds=\(sv.bounds.height) adjInset=\(sv.adjustedContentInset) contentInset=\(sv.contentInset) safe=\(sv.safeAreaInsets) offset=\(sv.contentOffset.y) svFrameInWindow=\(sv.convert(sv.bounds, to: nil)) window=\(window.bounds)"
            let path = NSTemporaryDirectory() + "lcScroll.txt"
            let old = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            try? (old + msg + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        } }
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
    static func scrollViews(in view: UIView) -> [UIScrollView] {
        var out: [UIScrollView] = []
        if let s = view as? UIScrollView { out.append(s) }
        for sub in view.subviews { out += scrollViews(in: sub) }
        return out
    }
}
#endif
