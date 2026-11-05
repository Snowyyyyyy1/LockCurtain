import SwiftUI

/// 设置 › 这台电脑 › 网络地址：填电脑上显示的那个地址。存下就马上试连一次（第一次会弹 iOS 的「本地网络」询问）。
struct NetworkAddressView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @FocusState private var focused: Bool

    @State private var reason: SaveCheck.Reason?
    @State private var saved = false
    /// 保存后把文本换成规范写法；这一次改动不算「用户又在编辑」，不清掉「存好了」
    @State private var canonicalAfterSave: String?
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
                    .onChange(of: text) { _, new in
                        if new == canonicalAfterSave { canonicalAfterSave = nil; return }
                        reason = nil
                        saved = false
                    }
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("填电脑上显示的这个地址。手机和电脑在同一个网络里，或者都装了 Tailscale 这类工具，就能连上。")
                    if let reason {
                        Text(NetworkAddressCopy.text(for: reason))
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    if saved {
                        Text(NetworkAddressCopy.saved)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
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
        saved = false
        switch SaveCheck.evaluate(text: text, paired: model.paired && !model.demoMode) {
        case .reject(let why):
            reason = why
        case .save:
            focused = false
            if model.saveNetworkAddress(text) {
                reason = nil
                saved = true
                if let canonical = model.networkAddress?.text, canonical != text {
                    canonicalAfterSave = canonical
                    text = canonical
                }
            } else {
                reason = .malformed
            }
        }
    }
}
