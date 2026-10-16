import SwiftUI

struct ConnectionView: View {
    let monitor: Monitor
    let provider: Provider
    let account: Account?
    let demo: Bool
    let finish: () -> Void
    var discover: (Bool, Bool) -> LocalCredentialDiscovery.Report = { environment, dotenv in
        let values = environment ? ProcessInfo.processInfo.environment : [:]
        if dotenv {
            return LocalCredentialDiscovery.scan(environment: values,
                dotenvFile: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".env"))
        }
        return LocalCredentialDiscovery.scan(environment: values)
    }
    @State private var key = ""
    @State private var username = ""
    @State private var selector = ""
    @State private var mode = "wallet"
    @State private var region = "global"
    @State private var error: String?
    @State private var readEnvironment = true
    @State private var readDotenv = true
    @State private var discoveryReport: LocalCredentialDiscovery.Report?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(account == nil ? "Connect" : "Reconnect") \(provider.title)").font(.title2.weight(.semibold))
            Text(provider.connectionHelp).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Link("Dashboard", destination: provider.dashboardURL)
            if provider.supportsRead && !provider.usesHelper {
                if provider == .dataForSEO { TextField("API login", text: $username) }
                SecureField(provider == .dataForSEO ? "API password" : provider == .cursor ? "Cursor session Cookie header" : "API key or access token", text: $key)
                    .accessibilityIdentifier("connectionCredential")
                if provider == .openRouter {
                    Picker("Report", selection: $mode) {
                        Text("Wallet · management key").tag("wallet")
                        Text("API key · spend and cap").tag("key")
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
                Text("Saved in your Mac's Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
                if LocalCredentialDiscovery.supports(provider) {
                    discoverySection
                }
            }
            if let error { UsageWarning(message: error) }
            HStack {
                Button(provider.supportsRead ? "Cancel" : "Close", action: finish)
                Spacer()
                if provider.supportsRead && !provider.usesHelper {
                    Button("Save", action: save).keyboardShortcut(.defaultAction)
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
        .onDisappear { key = ""; username = ""; discoveryReport = nil }
    }

    private var discoverySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("Find a saved key").font(.headline)
            HStack {
                Toggle("~/.env", isOn: $readDotenv)
                Toggle("App environment", isOn: $readEnvironment)
                Spacer()
                Button("Scan") {
                    discoveryReport = discover(readEnvironment, readDotenv)
                }
                .disabled(demo || (!readEnvironment && !readDotenv))
                .accessibilityIdentifier("scanLocalCredentials")
            }.toggleStyle(.checkbox).font(.caption)
            Text("Scan reads these sources. Add or Update saves one key.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .help("The app never runs shell startup files. Its environment may differ from your terminal. Key validity and billing permissions are checked when fetching usage.")
            if let discoveryReport {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        let candidates = discoveryReport.candidates.filter { $0.provider == provider }
                        ForEach(candidates) { candidate in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(candidate.variable).font(.caption.monospaced()).textSelection(.enabled)
                                if !candidate.companionVariables.isEmpty {
                                    Text("With \(candidate.companionVariables.joined(separator: ", "))")
                                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                HStack {
                                    Text("\(candidate.source.title) · \(candidate.maskedValue)")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Button(account == nil ? "Add" : "Update") {
                                        guard let secrets = candidate.connectionSecrets(), matchesOptions(candidate) else { return }
                                        save(secrets, optionHints: candidate.optionHints)
                                    }
                                    .disabled(demo || !candidate.isSelectable || !matchesOptions(candidate))
                                    .accessibilityLabel("\(account == nil ? "Add" : "Update") credential from \(candidate.variable) in \(candidate.source.title), companions: \(candidate.companionVariables.joined(separator: ", "))")
                                    .accessibilityIdentifier("useLocalCredential-\(candidate.variable)-\(candidate.source.title)\(candidate.companionVariables.isEmpty ? "" : "-" + candidate.companionVariables.joined(separator: "-"))")
                                }
                                Text(discoveryHint(candidate))
                                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                    .help(candidate.hint)
                            }
                        }
                        if candidates.isEmpty {
                            Text("No matching keys found.").font(.caption)
                        }
                        ForEach(Array(discoveryReport.issues.enumerated()), id: \.offset) { _, issue in
                            Text(issue.message).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 140)
            }
        }
        .onChange(of: readDotenv) { _, _ in discoveryReport = nil }
        .onChange(of: readEnvironment) { _, _ in discoveryReport = nil }
    }

    private func discoveryHint(_ candidate: LocalCredentialDiscovery.Candidate) -> String {
        guard matchesOptions(candidate) else { return "Different report. Add as a new account." }
        switch candidate.eligibility {
        case .selectable:
            if provider == .openRouter {
                return candidate.optionHints["mode"] == "key" ? "Reports this key's spend and cap." : "Reports the account wallet."
            }
            if let keyID = candidate.optionHints["keyID"] { return "Reports API key \(keyID)." }
            if let organizationID = candidate.optionHints["organizationID"] { return "Reports organization \(organizationID)." }
            return "Permissions checked after adding."
        case .unsupportedCredentialType:
            if provider == .xaiAPI {
                return "XAI_API_KEY is treated as an inference key, not tested. For a Management key, use XAI_MANAGEMENT_KEY or paste it above."
            }
            if provider == .exa {
                return "EXA_API_KEY is treated as a search key, not tested. For billing, use EXA_SERVICE_KEY and EXA_API_KEY_ID, or enter both above."
            }
            return "Key type inferred from the variable name, not tested. Billing/admin key required."
        case .missingCompanions(let names): return "Needs \(names.joined(separator: " or ")) in this source."
        }
    }

    private func matchesOptions(_ candidate: LocalCredentialDiscovery.Candidate) -> Bool {
        guard let account else { return true }
        return candidate.optionHints.allSatisfy { name, value in
            let saved = account.options[name] ?? (provider == .openRouter && name == "mode" ? "wallet" : nil)
            return saved == value
        }
    }

    private func save() {
        let secrets = ConnectionSecrets(key: key.trimmingCharacters(in: .whitespacesAndNewlines),
                                        username: provider == .dataForSEO ? username.trimmingCharacters(in: .whitespacesAndNewlines) : nil)
        save(secrets)
    }

    private func save(_ secrets: ConnectionSecrets, optionHints: [String: String] = [:]) {
        guard !demo else { return }
        error = nil
        do {
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
                options.merge(optionHints) { _, detected in detected }
                id = try monitor.add(label: "", provider: provider, options: options, secrets: secrets)
            }
            key = ""; username = ""; discoveryReport = nil
            finish()
            Task { await monitor.refresh(id) }
        } catch { self.error = (error as? MonitorError)?.localizedDescription ?? "Could not save this connection." }
    }
}
