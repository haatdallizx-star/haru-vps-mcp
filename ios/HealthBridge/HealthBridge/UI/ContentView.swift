import HealthBridgeCore
import SwiftUI

@MainActor
final class BridgeViewModel: ObservableObject {
    @Published var serverURL = ""
    @Published var token = ""
    @Published var status = "Not configured"
    @Published var queueDepth = 0
    @Published var busy = false

    private let config = SecureConfig()
    private var coordinator: SyncCoordinator?

    init() {
        serverURL = config.serverURL?.absoluteString ?? ""
        coordinator = try? SyncCoordinator(config: config)
        queueDepth = coordinator?.queueDepth() ?? 0
        if config.serverURL != nil { status = "Configured" }
    }

    func saveAndAuthorize() async {
        guard let url = URL(string: serverURL) else { status = "Invalid server URL"; return }
        busy = true
        defer { busy = false }
        do {
            try config.save(serverURL: url, token: token)
            let coordinator = try SyncCoordinator(config: config)
            self.coordinator = coordinator
            try await coordinator.prepare()
            try await coordinator.syncNow()
            queueDepth = coordinator.queueDepth()
            token = ""
            status = "Authorized and synced"
        } catch { status = "Setup failed: \(error.localizedDescription)" }
    }

    func syncNow() async {
        guard let coordinator else { status = "Configure server first"; return }
        busy = true
        defer { busy = false }
        do {
            try await coordinator.syncNow()
            queueDepth = coordinator.queueDepth()
            status = "Sync requested"
        } catch { status = "Sync failed: \(error.localizedDescription)" }
    }

    func testConnection() async {
        guard let url = config.statusURL, let token = try? config.token(), let token else { status = "Configure server first"; return }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            status = (200...299).contains(code) ? "Server reachable" : "Server returned HTTP \(code)"
        } catch { status = "Connection failed: \(error.localizedDescription)" }
    }
}

struct ContentView: View {
    @StateObject private var model = BridgeViewModel()

    var body: some View {
        NavigationStack {
            Form {
                Section("Private server") {
                    TextField("https://health.example.com", text: $model.serverURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    SecureField("Bearer token", text: $model.token)
                    Button("Save & Authorize HealthKit") { Task { await model.saveAndAuthorize() } }
                        .disabled(model.busy)
                    Button("Test Connection") { Task { await model.testConnection() } }
                        .disabled(model.busy)
                }
                Section("Sync") {
                    LabeledContent("Queue", value: "\(model.queueDepth)")
                    LabeledContent("Status", value: model.status)
                    Button("Sync Now") { Task { await model.syncNow() } }
                        .disabled(model.busy)
                }
                Section("Metrics") {
                    Text("Heart rate · HRV · Steps · Sleep")
                    Text("First sync reads the latest 24 hours. Later syncs are incremental.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("HealthBridge")
        }
    }
}
