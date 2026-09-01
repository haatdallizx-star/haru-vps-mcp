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

    private init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HealthBridge", isDirectory: true)

        config = SecureConfig()
        outbox = Outbox(root: base.appendingPathComponent("outbox"))
        anchorStore = AnchorStore(url: base.appendingPathComponent("anchors"))
        uploader = Uploader(outbox: outbox)

        // NOTE: this must NOT be a background URLSession. A background session
        // supports only upload/download tasks driven by a delegate; calling
        // `dataTask(with:completionHandler:)` on one raises an uncatchable
        // NSGenericException ("Completion handler blocks are not supported in
        // background sessions") and kills the process on launch as soon as the
        // outbox has anything to drain.
        //
        // Losing the out-of-process session is acceptable here: HealthKit
        // background delivery still relaunches the app, and the outbox already
        // treats an interrupted upload as retryable (`recoverInflightBatches`
        // on launch), so a transfer cut short is retried rather than lost.
        let uploadConfig = URLSessionConfiguration.default
        uploadConfig.waitsForConnectivity = true
        uploadConfig.timeoutIntervalForRequest = 30
        let uploadSession = URLSession(configuration: uploadConfig)

        sync = SyncEngine(
            config: config,
            outbox: outbox,
            anchorStore: anchorStore,
            uploader: uploader,
            send: { request, complete in
                let task = uploadSession.dataTask(with: request) { data, response, error in
                    complete(data, response, error)
                }
                task.resume()
            }
        )
    }
}

/// Registers HealthKit observers and requests read authorization at launch. iOS
/// relaunches the app for HealthKit events via the registered observers even when
/// the UI is not opened, provided they are registered here in didFinishLaunching.
final class AppDelegate: NSObject, UIApplicationDelegate {
    private lazy var sync = AppDependencies.shared.sync

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        sync.startBackgroundDelivery()
        sync.requestAuthorization()
        return true
    }
}
