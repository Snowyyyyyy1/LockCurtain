import SwiftUI

/// 设置 › 这台电脑 › 网络地址：填电脑上显示的那个地址。存下就马上试连一次（第一次会弹 iOS 的「本地网络」询问）。
struct NetworkAddressView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @FocusState private var focused: Bool

    private var parsed: NetworkAddress? { NetworkAddress.parse(text) }
    private var failed: Bool { model.networkAddress != nil && model.networkStatus == .failed }

    var body: some View {
        Form {
            Section {
                TextField("192.168.1.23:52811", text: $text)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit(save)
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("填电脑上显示的这个地址。手机和电脑在同一个网络里，或者都装了 Tailscale 这类工具，就能连上。")
                    if failed {
                        Text("连不上这个地址。看一眼电脑上那行对不对，两边的网络通不通。")
                    }
                }
            }
            Section {
                Button(action: save) {
                    HStack {
                        Text("保存")
                        if model.networkStatus == .trying {
                            Spacer()
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
                .disabled(parsed == nil)
                Button("清除", role: .destructive) {
                    model.clearNetworkAddress()
                    text = ""
                    focused = false
                }
                .disabled(model.networkAddress == nil && text.isEmpty)
            }
        }
        .navigationTitle("网络地址")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { text = model.networkAddress?.text ?? "" }
    }

    private func save() {
        guard parsed != nil else { return }
        focused = false
        if model.saveNetworkAddress(text) {
            text = model.networkAddress?.text ?? text
        }
    }
}
