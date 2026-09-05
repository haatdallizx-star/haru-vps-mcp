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
                    LabeledContent("HealthKit", value: sync.status.authorized ? "Request completed" : "Request needed")
                    if !sync.status.authorized {
                        Button("Request authorization") { sync.requestAuthorization() }
                    }
                }

                Section("Background delivery") {
                    LabeledContent("Delivery", value: sync.status.backgroundDeliveryEnabled ? "Enabled" : "Not confirmed")
                    if let error = sync.status.backgroundDeliveryError {
                        LabeledContent("Delivery error", value: error)
                    }
                }

                Section("Queue") {
                    LabeledContent("Pending batches", value: "\(sync.status.pendingCount)")
                    LabeledContent("In-flight batches", value: "\(sync.status.inflightCount)")
                }

                Section("Collection") {
                    if let error = sync.status.lastSyncError {
                        LabeledContent("Read / save error", value: error)
                    } else {
                        Text("No reported read / save error")
                    }
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
