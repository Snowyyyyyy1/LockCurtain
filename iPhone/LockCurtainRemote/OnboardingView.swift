import SwiftUI

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var showPairing = false

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: "laptopcomputer.and.iphone")
                        .font(.system(size: 64))
                        .foregroundStyle(.tint)
                        .symbolRenderingMode(.hierarchical)

                    Text("先和你的 Mac 连上")
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)

                    Text("在 Mac 上打开 LockCurtain，点「配对手机」，把 6 位码输进来。")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)

                    Text("第一次连上、或者断开以后重新连上，要在手机上把 LockCurtain 打开一下。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .padding(.top, -8)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
                .frame(minHeight: proxy.size.height, alignment: .center)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: .infinity)
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.showDemoExitNotice {
                Text("演示已退出，这里还是没连上 Mac")
                    .font(.subheadline)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 16)
                    .background(.regularMaterial, in: .capsule)
                    .padding(.top, 8)
                    .transition(.opacity)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            GlassEffectContainer(spacing: 12) {
                VStack(spacing: 12) {
                    Button {
                        model.prepareForPairing()
                        showPairing = true
                    } label: {
                        Text("去配对")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 3)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)

                    Button {
                        model.setDemoMode(true)
                    } label: {
                        Text("手上没有 Mac？先看看演示")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 3)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: model.showDemoExitNotice)
        .sheet(isPresented: $showPairing) {
            PairingSheet()
        }
    }
}

#Preview {
    OnboardingView()
        .environment(AppModel())
}
