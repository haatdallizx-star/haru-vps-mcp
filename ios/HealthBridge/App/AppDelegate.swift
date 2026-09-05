import Combine
import Foundation
import UIKit

/// Builds the whole dependency graph once. Kept separate from the SwiftUI entry
/// so the app delegate (which must run in `didFinishLaunching` for HealthKit
/// background relaunch) and the UI share the same `SyncEngine`.
final class AppDependencies {
    static let shared = AppDependencies()

    let config: SecureConfig
    let outbox: Outbox
    let anchorStore: AnchorStore
    let uploader: Uploader
    let sync: SyncEngine
    let backgroundUploader: BackgroundUploader

    private init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HealthBridge", isDirectory: true)

        config = SecureConfig()
        outbox = Outbox(root: base.appendingPathComponent("outbox"))
        anchorStore = AnchorStore(url: base.appendingPathComponent("anchors"))
        uploader = Uploader(outbox: outbox)

        backgroundUploader = BackgroundUploader(
            outbox: outbox, config: config,
            bodyDirectory: base.appendingPathComponent("upload-bodies"),
            transport: BackgroundURLSessionTransfer()
        )
        sync = SyncEngine(config: config, outbox: outbox, anchorStore: anchorStore,
                          uploader: uploader, backgroundUploader: backgroundUploader)
    }
}

/// Registers HealthKit observers at launch. Authorization is requested by the foreground scene. iOS
/// relaunches the app for HealthKit events via the registered observers even when
/// the UI is not opened, provided they are registered here in didFinishLaunching.
final class AppDelegate: NSObject, UIApplicationDelegate {
    private lazy var sync = AppDependencies.shared.sync

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        sync.startBackgroundDelivery()
        return true
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == BackgroundURLSessionTransfer.identifier else {
            completionHandler()
            return
        }
        AppDependencies.shared.backgroundUploader.handleBackgroundEvents(completion: completionHandler)
    }

    func applicationProtectedDataDidBecomeAvailable(_ application: UIApplication) {
        sync.manualSync()
    }
}
