import HealthBridgeCore
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    private var coordinator: SyncCoordinator?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let config = SecureConfig()
        coordinator = try? SyncCoordinator(config: config)
        if let coordinator {
            BackgroundScheduler.register(coordinator: coordinator)
            BackgroundScheduler.schedule()
            if config.serverURL != nil, (try? config.token()) != nil {
                Task { try? await coordinator.prepare() }
            }
        }
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        BackgroundScheduler.schedule()
    }
}
