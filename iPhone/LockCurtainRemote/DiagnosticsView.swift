import SwiftUI

struct DiagnosticsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                LabeledContent("蓝牙", value: model.bluetoothDiagnosticValue)
                LabeledContent("信号", value: model.signalDiagnosticValue)
                LabeledContent("最后一次事件", value: model.lastEventDiagnosticValue)
                if let timing = LinkTiming.shared.displayText {
                    // COPY-TODO: 开发看的：冷启动到连上用了多久（毫秒，每一步）。暂用「冷启动 → 已连上」，正式版 Camo 定或干脆只在开发包里出现
                    VStack(alignment: .leading, spacing: 2) {
                        Text("冷启动 → 已连上")
                        Text(timing)
                            .font(.footnote.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            } header: {
                Text("连接")
            } footer: {
                Text("这些只是这一次连接的情况，不上传。")
            }

            #if DEBUG
            // 开发用的蓝牙探针：正式包里没有（design v2.9 P1-1）
            Section {
                NavigationLink {
                    ContentView()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("蓝牙探针")
                        Text("给开发看的，验完就删。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("探针")
            }
            #endif
        }
        .navigationTitle("排查信息")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        DiagnosticsView()
            .environment(AppModel())
    }
}
