import SwiftUI

@main
@MainActor
struct LockCurtainRemoteApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
    }
}
