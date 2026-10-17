import AppKit
import SwiftUI

struct MonitorView: View {
    @Bindable var monitor: Monitor
    @Bindable var login: LoginController
    let demo: Bool
    let openWindow: () -> Void
    let connect: (Provider, Account?) -> Void
    var showResets: (Account) -> Void = { _ in }
    @State private var code = ""
    @State private var error: String?
    @State private var removal: UUID?
    @State private var granting: UUID?
    @State private var selectedProvider: Provider?

    private var provider: Provider { selectedProvider ?? monitor.entries.first?.account.provider ?? .claude }
    private var accounts: [AccountEntry] { monitor.entries.filter { $0.account.provider == provider } }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: $selectedProvider) {
                    ForEach(Provider.allCases.filter { service in
                        service.supportsRead || monitor.entries.contains { $0.account.provider == service }
                    }) { service in
                        HStack(spacing: 10) {
                            ProviderIcon(provider: service).frame(width: 20, height: 20)
                                .foregroundStyle(selectedProvider == service ? Color.white : Color(nsColor: .labelColor))
                            Text(service.title).lineLimit(1)
                                .foregroundStyle(selectedProvider == service ? Color.white : Color(nsColor: .labelColor))
                            Spacer(minLength: 0)
                            let count = monitor.entries.filter { $0.account.provider == service }.count
                            if count > 0 {
                                Text("\(count)").font(.caption.monospacedDigit())
                                    .foregroundStyle(selectedProvider == service ? Color.white.opacity(0.8) : Color(nsColor: .secondaryLabelColor))
                            }
                        }
                        .padding(.vertical, 3)
                        .tag(service)
                        .accessibilityIdentifier("service-\(service.rawValue)")
                    }
                }
                .listStyle(.sidebar)
                .navigationTitle("Headroom")
                Divider()
                HStack {
                    Button("Refresh all", systemImage: "arrow.clockwise") {
                        Task { for entry in monitor.entries { await monitor.refresh(entry.id) } }
                    }.disabled(demo || login.accountID != nil || monitor.entries.isEmpty || monitor.entries.contains(where: \.refreshing))
                    Spacer()
                }.buttonStyle(.borderless).padding(14)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    ProviderIcon(provider: provider).frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(provider.title).font(.title2.weight(.semibold))
                        Text("\(accounts.count) \(accounts.count == 1 ? "account" : "accounts") · Checks every \(provider == .claude ? "5 minutes" : "minute")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Add account", systemImage: "plus") { addProvider(provider) }
                        .disabled(demo || login.accountID != nil || !provider.supportsRead)
                        .accessibilityIdentifier("addAccount")
                }.padding(24)
                Form {
                    if demo { Label("Demo data", systemImage: "testtube.2").foregroundStyle(.orange) }
                    if login.accountID != nil { Section { loginSection } }
                    if accounts.isEmpty {
                        ContentUnavailableView {
                            Label("No \(provider.title) accounts", systemImage: "person.crop.circle.badge.plus")
                        } description: {
                            Text("Add an account to see its usage here.")
                        } actions: {
                            Button("Add account") { addProvider(provider) }
                                .disabled(demo || login.accountID != nil || !provider.supportsRead)
                        }
                    }
                    ForEach(accounts) { entry in
                        Section { accountSection(entry) }
                    }
                    if let message = error ?? login.error { UsageWarning(message: message) }
                }.formStyle(.grouped)
            }
        }
        .frame(minWidth: 740, minHeight: 480)
        .alert("Remove this account?", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } })) {
            Button("Cancel", role: .cancel) { removal = nil }
            Button("Remove", role: .destructive) {
                if let id = removal { perform { try monitor.remove(id) } }
                removal = nil
            }
        } message: { Text("Removes this app's saved account and credentials. Other logins are not affected.") }
        .onAppear { if selectedProvider == nil { selectedProvider = provider } }
        .onChange(of: login.accountID) { _, id in
            code = ""
            if id != nil { selectedProvider = login.provider }
        }
    }

    private func accountSection(_ entry: AccountEntry) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            AccountSummaryView(entry: entry)
            HStack {
                Button("Refresh") { Task { await monitor.refresh(entry.id) } }
                    .disabled(demo || entry.refreshing || entry.resetting || login.accountID != nil)
                Spacer()
                Menu {
                    Button("Reconnect…") { reconnect(entry.account) }
                    Link("Dashboard", destination: entry.account.provider.dashboardURL)
                    Button("Remove account", role: .destructive) { removal = entry.id }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).fixedSize().disabled(demo || login.accountID != nil || entry.resetting)
                .accessibilityLabel("Actions for \(entry.displayName)")
            }
            if entry.account.provider == .codex {
                Button("Use reset…") { showResets(entry.account) }
                    .buttonStyle(.borderless).disabled(login.accountID != nil || entry.resetting)
                    .accessibilityIdentifier("windowResets-\(entry.id)")
            }
            Toggle("Show in menu bar", isOn: Binding(get: { entry.account.showInMenuBar }, set: { visible in
                perform { try monitor.setMenuBarVisibility(entry.id, visible: visible) }
            })).toggleStyle(.switch).controlSize(.small).disabled(demo)
            if entry.snapshot == nil {
                VStack(alignment: .leading, spacing: 6) {
                    Button(entry.account.provider.usesHelper ? "Sign in" : "Enter credentials") { reconnect(entry.account) }
                    if entry.error == MonitorError.keychainUnavailable.localizedDescription {
                        Button("Allow Keychain access") { grantAccess(entry.id) }
                    }
                }.disabled(demo || entry.refreshing || login.accountID != nil || granting != nil)
                if entry.error == MonitorError.keychainUnavailable.localizedDescription {
                    Text("Choose Always Allow for this account's Keychain entry.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .help("Unlock the login Keychain if macOS asks. Approve only this entry to allow later usage checks.")
                }
            }
        }
        .font(.body).padding(.vertical, 8)
    }

    private var loginSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sign in: \(monitor.entries.first(where: { $0.id == login.accountID })?.account.displayName ?? "Claude")").font(.headline)
            Text(login.provider == .codex
                 ? "Open the link in the right browser profile, then enter the code on OpenAI's page."
                 : "Open the link in the right browser profile. Sign in, then paste Claude's code below.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .help(login.provider == .codex ? "Enable device code authorization in ChatGPT Security settings if sign-in is blocked." : "Use the browser profile for the account you want to connect.")
            if let url = login.authorizationURL {
                HStack {
                    Link("Open \(login.provider.title) sign-in", destination: url)
                    Button("Copy link") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string) }
                }
                if let deviceCode = login.deviceCode {
                    HStack {
                        Text(deviceCode).font(.title2.monospaced().weight(.semibold)).textSelection(.enabled)
                        Button("Copy code", systemImage: "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(deviceCode, forType: .string)
                        }.accessibilityIdentifier("copyDeviceCode")
                    }
                    HStack { ProgressView().controlSize(.small); Text("Waiting for browser approval…") }
                } else {
                    SecureField("Authorization code", text: $code).textFieldStyle(.roundedBorder).accessibilityIdentifier("authorizationCode")
                    Button("Complete sign-in") { perform { try login.submit(code); code = "" } }
                        .disabled(code.isEmpty)
                }
            } else {
                HStack { ProgressView().controlSize(.small); Text(login.submitted ? "Completing sign-in…" : "Waiting for \(login.provider.title)'s login link…") }
            }
            Button("Cancel sign-in") { login.cancel(); code = "" }
        }.padding(.vertical, 4)
    }

    private func startLogin(_ id: UUID) {
        guard !monitor.entries.contains(where: \.resetting) else { return }
        openWindow()
        perform {
            guard let provider = monitor.entries.first(where: { $0.id == id })?.account.provider else { return }
            try login.start(id, provider: provider, store: monitor.store) { id in Task { await monitor.refresh(id) } }
            monitor.beginLogin(id)
        }
    }

    private func addProvider(_ provider: Provider) {
        if provider.usesHelper {
            guard !demo else { return }
            perform { startLogin(try monitor.add(label: "", provider: provider)) }
        } else { connect(provider, nil) }
    }

    private func reconnect(_ account: Account) {
        if account.provider.usesHelper { startLogin(account.id) }
        else { connect(account.provider, account) }
    }

    private func grantAccess(_ id: UUID) {
        granting = id
        error = nil
        let store = monitor.store
        let provider = monitor.entries.first(where: { $0.id == id })?.account.provider
        Task {
            do {
                try await Task.detached {
                    if provider == .claude { _ = try store.credentials(id, allowInteraction: true) }
                    else { _ = try store.secrets(id, allowInteraction: true) }
                }.value
                await monitor.refresh(id)
            } catch { self.error = (error as? MonitorError)?.localizedDescription ?? "Could not access the scoped Keychain entry." }
            granting = nil
        }
    }

    private func perform(_ action: () throws -> Void) {
        error = nil
        do { try action() }
        catch { self.error = (error as? MonitorError)?.localizedDescription ?? "Could not update local account storage." }
    }
}

extension ClaudeUsage.Window {
    var remainingColor: Color {
        UsageMetric(title: "", kind: .quota, value: remaining).remainingColor
    }
}

extension UsageMetric {
    var remainingColor: Color {
        guard let remaining = value, remaining.isFinite, (0...100).contains(remaining) else { return .secondary }
        if remaining == 0 { return .red }
        return remaining <= 10 ? .orange : .accentColor
    }
}
