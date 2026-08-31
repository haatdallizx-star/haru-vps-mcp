import Foundation

/// A stable, random installation identifier used as the bridge `device_id`.
/// Explicitly NOT an advertising or hardware identifier — it is generated once
/// per install and stored in the app's UserDefaults.
enum DeviceIdentity {
    static func current(defaults: UserDefaults = .standard) -> String {
        let key = "healthbridge_device_id"
        if let existing = defaults.string(forKey: key) {
            return existing
        }
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: key)
        return fresh
    }
}
