import SwiftUI

@main
@MainActor
struct LockCurtainRemoteApp: App {
    @UIApplicationDelegateAdaptor(LockCurtainAppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
    }
}
