import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var showSettings = false
    @State private var showPairing = false
    @Namespace private var glassNS

    var body: some View {
        List {
            Section {
                MacScreenIllustration(
                    state: model.screenState,
                    showsDemoBadge: model.demoMode
                )
                .frame(maxWidth: .infinity)
                .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 20, trailing: 0))
            }

            Section {
                curtainRow
                macRow
                autoRow
            } footer: {
                sectionFooter
            }

            if model.demoMode {
                demoSection
            }
        }
        .listStyle(.insetGrouped)
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if showsBottomBar {
                bottomBar
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
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
            Text(model.macDisplayValue)
                .foregroundStyle(.secondary)
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
        case .curtain, .closing:
            "curtains.closed"
        case .desktop, .empty:
            "curtains.open"
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private var sectionFooter: some View {
        switch model.connection {
        case .notPaired:
            Text("在 Mac 上打开 LockCurtain，点「配对手机」，把 6 位码输进来。")
        case .notConnected:
            Text("Mac 要醒着、在附近，蓝牙也要开着。")
        case .macOffline:
            Text("Mac 睡了或者没开机，它醒着时会自己连上。")
        case .bluetoothOff:
            Text("打开 iPhone 的蓝牙，才能找到这台 Mac。")
        case .connected:
            if model.phase != .closed && !model.didTimeOut && !model.hasAlwaysLocation && !model.demoMode {
                Text("定位没给“始终”，现在只能手动。")
            }
        }
    }

    // MARK: - Bottom bar

    private var showsBottomBar: Bool {
        model.connection == .connected || model.connection == .notPaired
    }

    private var bottomBar: some View {
        GlassEffectContainer {
            VStack(spacing: 10) {
                if model.connection == .notPaired {
                    Button {
                        showPairing = true
                    } label: {
                        Text("去配对")
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 50)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .glassEffectID("action", in: glassNS)
                    .transition(.opacity)
                } else if model.phase == .closed && !model.isPending {
                    closedNote
                        .glassEffect(.regular, in: .rect(cornerRadius: 26))
                        .glassEffectID("action", in: glassNS)
                        .transition(.opacity)
                } else {
                    if model.didTimeOut {
                        Text("Mac 没有回应，状态没变。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .transition(.opacity)
                    }
                    coverButton
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity)
        }
        .animation(.smooth(duration: 0.35), value: model.phase)
        .animation(.smooth(duration: 0.35), value: model.isPending)
        .animation(.smooth(duration: 0.35), value: model.didTimeOut)
        .animation(.smooth(duration: 0.35), value: model.connection)
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
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(true)
            .glassEffectID("action", in: glassNS)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 50)
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
                .frame(minHeight: 50)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .glassEffectID("action", in: glassNS)
            .accessibilityHint("发给这台 Mac，盖上幕布")
        }
    }

    private var closedNote: some View {
        VStack(spacing: 2) {
            Text("回到 Mac 前按任意键解锁。")
                .font(.subheadline.weight(.semibold))
            Text("手机上不能撤下幕布。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(.vertical, 14)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Demo

    private var demoBanner: some View {
        HStack(spacing: 8) {
            Text("演示")
                .font(.caption.bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(.orange, in: .capsule)
                .foregroundStyle(.black)
            Text("下面是模拟状态，没有连接任何 Mac")
                .font(.footnote)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.14), in: .rect(cornerRadius: 18))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(.systemGroupedBackground), ignoresSafeAreaEdges: [])
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
            if model.demoScenario == .away {
                LabeledContent(
                    "走远",
                    value: model.phase == .closed ? "已盖上" : "已走远"
                )
                .foregroundStyle(.secondary)
            }

            Picker(
                "演示里切换",
                selection: Binding(
                    get: { model.demoScenario },
                    set: { model.selectDemoScenario($0) }
                )
            ) {
                Text("已连上这台 Mac").tag(AppModel.DemoScenario.connected)
                Text("幕布已盖上").tag(AppModel.DemoScenario.closed)
                Text("走远自动盖上").tag(AppModel.DemoScenario.away)
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }
}

#Preview {
    NavigationStack {
        HomeView()
            .environment(AppModel())
    }
}
