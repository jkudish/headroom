import SwiftUI

struct ConnectionView: View {
    let monitor: Monitor
    let provider: Provider
    let account: Account?
    let demo: Bool
    let finish: () -> Void
    @State private var key = ""
    @State private var username = ""
    @State private var selector = ""
    @State private var mode = "wallet"
    @State private var region = "global"
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(account == nil ? "Connect" : "Reconnect") \(provider.title)").font(.title2.weight(.semibold))
            Text(provider.connectionHelp).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Link("Open provider dashboard", destination: provider.dashboardURL)
            if provider.supportsRead && !provider.usesHelper {
                if provider == .dataForSEO { TextField("API login", text: $username) }
                SecureField(provider == .dataForSEO ? "API password" : provider == .cursor ? "Cursor session Cookie header" : "API key or access token", text: $key)
                    .accessibilityIdentifier("connectionCredential")
                if provider == .openRouter {
                    Picker("Report", selection: $mode) {
                        Text("Account wallet (management key)").tag("wallet")
                        Text("This API key's spend and cap").tag("key")
                    }.disabled(account != nil)
                }
                if provider == .zai {
                    Picker("Region", selection: $region) {
                        Text("Global · z.ai").tag("global")
                        Text("China · BigModel").tag("cn")
                    }.disabled(account != nil)
                }
                if provider == .exa || provider == .openAIAPI {
                    TextField(provider == .exa ? "API key ID to report" : "Organization ID (optional)", text: $selector)
                        .disabled(account != nil)
                }
                Text("Saved only in this Mac's Keychain, separately for each connection.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error { UsageWarning(message: error) }
            HStack {
                Button(provider.supportsRead ? "Cancel" : "Close", action: finish)
                Spacer()
                if provider.supportsRead && !provider.usesHelper {
                    Button("Save connection", action: save).keyboardShortcut(.defaultAction)
                        .disabled(demo || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || (provider == .dataForSEO && username.isEmpty)
                                  || (provider == .exa && selector.isEmpty))
                }
            }
        }
        .textFieldStyle(.roundedBorder).padding(22).frame(width: 400)
        .onAppear {
            mode = account?.options["mode"] ?? "wallet"
            region = account?.options["region"] ?? "global"
            selector = account?.options[provider == .exa ? "keyID" : "organizationID"] ?? ""
        }
        .onDisappear { key = ""; username = "" }
    }

    private func save() {
        guard !demo else { return }
        error = nil
        do {
            let secrets = ConnectionSecrets(key: key.trimmingCharacters(in: .whitespacesAndNewlines),
                                            username: provider == .dataForSEO ? username.trimmingCharacters(in: .whitespacesAndNewlines) : nil)
            let id: UUID
            if let account {
                try monitor.reconnect(account.id, secrets: secrets)
                id = account.id
            } else {
                var options: [String: String] = [:]
                if provider == .openRouter { options["mode"] = mode }
                if provider == .zai { options["region"] = region }
                if provider == .exa { options["keyID"] = selector.trimmingCharacters(in: .whitespacesAndNewlines) }
                if provider == .openAIAPI { options["organizationID"] = selector.trimmingCharacters(in: .whitespacesAndNewlines) }
                id = try monitor.add(label: "", provider: provider, options: options, secrets: secrets)
            }
            key = ""; username = ""
            finish()
            Task { await monitor.refresh(id) }
        } catch { self.error = (error as? MonitorError)?.localizedDescription ?? "Could not save this connection." }
    }
}
