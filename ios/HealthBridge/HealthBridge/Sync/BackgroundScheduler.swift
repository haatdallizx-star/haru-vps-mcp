import BackgroundTasks
import Foundation

public enum BackgroundScheduler {
    public static let identifier = "com.haru.healthbridge.refresh"

    public static func register(coordinator: SyncCoordinator) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            schedule()
            let work = Task {
                do {
                    try await coordinator.syncNow()
                    refresh.setTaskCompleted(success: true)
                } catch {
                    refresh.setTaskCompleted(success: false)
                }
            }
            refresh.expirationHandler = { work.cancel() }
        }
    }

    public static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
