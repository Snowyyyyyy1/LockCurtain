import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var showUnpairConfirmation = false
    @State private var showPairing = false

    var body: some View {
        NavigationStack {
            Form {
                macSection
                if model.demoMode || model.paired {
                    liftSection
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
                Button("撤销", role: .destructive) {
                    model.unpair()
                    dismiss()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("以后要重新配对才能控制这台 Mac。")
            }
        }
        .sheet(isPresented: $showPairing) {
            PairingSheet()
        }
    }

    // MARK: - Sections

    private var macSection: some View {
        Section {
            if model.demoMode || model.paired {
                LabeledContent("已配对", value: model.macName ?? "Mac")
                Button("撤销配对", role: .destructive) {
                    showUnpairConfirmation = true
                }
            } else {
                Button("配对") {
                    showPairing = true
                }
            }
        } header: {
            Text("这台 Mac")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                if !model.demoMode && !model.paired {
                    Text("在 Mac 上打开 LockCurtain，点「配对手机」，把 6 位码输进来。")
                }
                Text("第一次连上、或者断开以后重新连上，要在手机上把 LockCurtain 打开一下。")
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
            Text("手机解锁着、人走到这台 Mac 附近，幕布就撤下来。手机锁着的时候不撤。")
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
            Text("不连 Mac，也能看到连上、盖上是什么样。")
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
