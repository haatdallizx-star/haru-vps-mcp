import SwiftUI

@main
struct HealthBridgeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var sync = AppDependencies.shared.sync

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(sync)
                .onChange(of: scenePhase) { phase in
                    if phase == .active { sync.requestAuthorization() }
                }
        }
    }
}
