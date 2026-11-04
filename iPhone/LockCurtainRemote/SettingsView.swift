import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var showUnpairConfirmation = false
    @State private var showPairing = false
    /// 换电脑（copy v11 §13）
    @State private var showReplaceAlert = false
    @State private var pairingReplaces = false

    var body: some View {
        NavigationStack {
            Form {
                macSection
                if model.demoMode || model.paired {
                    liftSection
                    liftAuthSection
                }
                if AppModel.autoCoverVisible {
                    autoSection
                    readOnlySection
                }
                demoSection
                aboutSection
                Section {
                    MadeWithAirBuild()
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(role: .close) {
                        dismiss()
                    }
                    .accessibilityLabel("关闭")
                }
            }
            .confirmationDialog(
                "撤销这台手机的配对？",
                isPresented: $showUnpairConfirmation,
                titleVisibility: .visible
            ) {
                Button("撤销配对", role: .destructive) {
                    model.unpair()
                    dismiss()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("以后要重新配对才能控制这台电脑。")
            }
            // 换电脑：先说清楚是「换」，不是「加」；取消或者没配上，原来那台不动
            .alert("换成另一台电脑？", isPresented: $showReplaceAlert) {
                Button("取消", role: .cancel) {}
                Button("继续配对") {
                    pairingReplaces = true
                    showPairing = true
                }
            } message: {
                Text("配好以后，现在这台会断开；要再用它，得在这台手机上重新配一次。")
            }
            #if DEBUG
            .onAppear {
                // 截图用：-lcOpenReplaceAlert 一打开设置就弹「换成另一台电脑？」
                if ProcessInfo.processInfo.arguments.contains("-lcOpenReplaceAlert") {
                    showReplaceAlert = true
                }
            }
            #endif
        }
        .sheet(isPresented: $showPairing, onDismiss: { pairingReplaces = false }) {
            PairingSheet(replacing: pairingReplaces)
        }
    }

    // MARK: - Sections

    private var macSection: some View {
        Section {
            if model.demoMode || model.paired {
                LabeledContent("已配对", value: model.macName ?? "这台电脑")
                if model.paired && !model.demoMode {
                    Button("配另一台电脑") {
                        showReplaceAlert = true
                    }
                    .foregroundStyle(.tint)
                }
                Button("撤销配对", role: .destructive) {
                    showUnpairConfirmation = true
                }
            } else {
                Button("配对") {
                    pairingReplaces = false
                    showPairing = true
                }
            }
        } header: {
            Text("这台电脑")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                if !model.demoMode && !model.paired {
                    Text("在电脑上打开 LockCurtain 设置里的「手机」，点「配对手机」，把 6 位码输进来。")
                }
                Text("断开以后要重新连，打开 LockCurtain 等十几秒；连上以后锁屏、切后台都不会断，不用一直开着。")
            }
        }
    }

    private var liftSection: some View {
        Section {
            Toggle(
                "走近撤下",
                isOn: Binding(
                    get: { model.liftOnApproach },
                    set: { model.setLiftOnApproach($0) }
                )
            )
        } header: {
            Text("撤下")
        } footer: {
            Text("手机解锁着、人走到这台电脑附近，幕布就撤下来。手机锁着的时候不撤。")
        }
    }

    /// 撤下前验证面容 (copy v13.4 §11)：脚注跟着开关变，关着那句就在开关正下面
    private var liftAuthSection: some View {
        Section {
            Toggle(
                "撤下前验证面容",
                isOn: Binding(
                    get: { model.liftNeedsFaceID },
                    set: { model.setLiftNeedsFaceID($0) }
                )
            )
        } footer: {
            if model.liftNeedsFaceID {
                Text("点「现在撤下」时先看你一眼，免得别人拿起你解锁着的手机就把幕布撤了。")
            } else {
                Text("关着的时候，拿到你解锁着的手机的人也能撤下幕布。")
            }
        }
    }

    private var autoSection: some View {
        Section {
            Toggle(
                "走远自动盖上",
                isOn: Binding(
                    get: { model.autoEnabled },
                    set: { model.setAutoEnabled($0) }
                )
            )
            .disabled(!model.canToggleAuto)

        } header: {
            Text("自动")
        } footer: {
            autoFooter
        }
    }

    private var autoFooter: some View {
        Text("只有走远会盖。回来不会自动撤。")
    }

    private var readOnlySection: some View {
        Section {
            LabeledContent("灵敏度", value: "标准")
                .foregroundStyle(.secondary)
            LabeledContent("离开后等", value: "默认")
                .foregroundStyle(.secondary)
        } footer: {
            Text("这两项等实测出结果才能调，先按默认走。")
        }
    }

    private var demoSection: some View {
        Section {
            Toggle(
                "演示模式",
                isOn: Binding(
                    get: { model.demoMode },
                    set: { isOn in
                        model.setDemoMode(isOn)
                        if !isOn && !model.paired {
                            dismiss()
                        }
                    }
                )
            )
        } header: {
            Text("演示")
        } footer: {
            Text("不连电脑，也能看到连上、盖上是什么样。")
        }
    }

    private var aboutSection: some View {
        Section("关于") {
            LabeledContent("版本", value: appVersion)
            NavigationLink("排查信息") {
                DiagnosticsView()
            }
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
}

#Preview {
    SettingsView()
        .environment(AppModel())
}
