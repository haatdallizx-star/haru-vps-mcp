import SwiftUI

@main
struct HealthBridgeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var sync = AppDependencies.shared.sync

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(sync)
        }
    }
}
