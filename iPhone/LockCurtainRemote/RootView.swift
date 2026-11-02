import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.needsOnboarding {
                OnboardingView()
            } else {
                NavigationStack {
                    HomeView()
                }
            }
        }
    }
}

#Preview {
    RootView()
        .environment(AppModel())
}
