import SwiftUI

/// Local diagnostics: authorization, background delivery, queue depth, last
/// upload result, and manual sync. Enough to distinguish HealthKit/query
/// failures from background-wake and network failures without opening a device
/// console.
struct StatusView: View {
    @EnvironmentObject private var sync: SyncEngine

    var body: some View {
        NavigationStack {
            Form {
                Section("Authorization") {
                    LabeledContent("HealthKit", value: sync.status.authorized ? "Granted" : "Not authorized")
                    if !sync.status.authorized {
                        Button("Request authorization") { sync.requestAuthorization() }
                    }
                }

                Section("Background delivery") {
                    LabeledContent("Observers", value: sync.status.backgroundDeliveryEnabled ? "Registered" : "Not registered")
                }

                Section("Queue") {
                    LabeledContent("Pending batches", value: "\(sync.status.pendingCount)")
                    LabeledContent("In-flight batches", value: "\(sync.status.inflightCount)")
                }

                Section("Upload") {
                    LabeledContent("Last result", value: sync.status.lastUpload)
                    if let error = sync.status.lastError {
                        LabeledContent("Last error", value: error)
                    }
                }

                Section {
                    Button("Manual sync") { sync.manualSync() }
                    Button("Drain queue") { sync.drainQueue() }
                }
            }
            .navigationTitle("HealthBridge")
        }
    }
}
