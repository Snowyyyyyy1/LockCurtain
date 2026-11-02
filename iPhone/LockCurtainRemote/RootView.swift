import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

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
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                model.refreshLocationStatus()
            }
        }
    }
}

#Preview {
    RootView()
        .environment(AppModel())
}
