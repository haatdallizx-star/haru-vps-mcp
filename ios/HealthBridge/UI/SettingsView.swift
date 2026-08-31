import SwiftUI

/// Minimal settings: HTTPS server endpoint + bearer token. The token is stored
/// in Keychain (never in UserDefaults / source); the endpoint is stored in
/// UserDefaults. Neither is hardcoded.
struct SettingsView: View {
    @EnvironmentObject private var sync: SyncEngine
    @State private var endpoint = ""
    @State private var token = ""
    @State private var saved = false

    private let config = AppDependencies.shared.config

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("https://host/healthkit/v1/ingest", text: $endpoint)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    SecureField("Bearer token", text: $token)
                }

                Section {
                    Button("Save") { save() }
                        .disabled(endpoint.isEmpty || token.isEmpty)
                    if saved {
                        Text("Saved (token → Keychain, never UserDefaults)")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .onAppear { load() }
        }
    }

    private func load() {
        endpoint = config.endpoint?.absoluteString ?? ""
    }

    private func save() {
        config.save(endpoint: endpoint, token: token)
        token = ""
        saved = true
    }
}
