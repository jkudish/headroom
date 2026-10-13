import AppKit
import SwiftUI

struct MonitorView: View {
    @Bindable var monitor: Monitor
    @Bindable var login: LoginController
    let demo: Bool
    let openWindow: () -> Void
    let connect: (Provider, Account?) -> Void
    @State private var renaming: UUID?
    @State private var editedLabel = ""
    @State private var code = ""
    @State private var error: String?
    @State private var removal: UUID?
    @State private var granting: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "gauge.with.dots.needle.50percent").font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Usage Monitor").font(.title3.weight(.semibold))
                    Text("\(monitor.entries.count) independent \(monitor.entries.count == 1 ? "connection" : "connections")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                addAccountMenu
                Button { openWindow() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(.borderless)
                    .help("Open account window").accessibilityLabel("Open account window")
            }.padding(18)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if demo {
                        Label("Demo — fixture data, not live usage", systemImage: "testtube.2")
                            .font(.callout.weight(.medium)).foregroundStyle(.orange)
                    }
                    if monitor.entries.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "person.crop.circle.badge.plus").font(.system(size: 34)).foregroundStyle(.secondary)
                            Text("All your accounts, separately.").font(.headline)
                            Text("Connect a subscription or API account. Your existing CLI logins stay untouched.")
                                .foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }.frame(maxWidth: .infinity).padding(.vertical, 26)
                    }
                    if login.accountID != nil {
                        loginSection
                        Divider()
                    }
                    ForEach(monitor.entries) { entry in
                        accountSection(entry)
                        if entry.id != monitor.entries.last?.id { Divider() }
                    }
                    if let message = error ?? login.error {
                        Label(message, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(18)
            }
            Divider()
            HStack {
                Button("Refresh all", systemImage: "arrow.clockwise") {
                    Task { for entry in monitor.entries { await monitor.refresh(entry.id) } }
                }.disabled(demo || login.accountID != nil || monitor.entries.isEmpty || monitor.entries.contains(where: \.refreshing))
                Spacer()
                Button("Quit") { login.cancel(); NSApplication.shared.terminate(nil) }
            }.buttonStyle(.borderless).padding(12)
        }
        .frame(minWidth: 340, minHeight: 440)
        .alert("Account name", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $editedLabel)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") {
                if let id = renaming { perform { try monitor.rename(id, label: editedLabel) } }
                renaming = nil
            }
        } message: { Text("Leave blank to use the name returned by the provider, when available.") }
        .alert("Remove this account?", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } })) {
            Button("Cancel", role: .cancel) { removal = nil }
            Button("Remove", role: .destructive) {
                if let id = removal { perform { try monitor.remove(id) } }
                removal = nil
            }
        } message: { Text("Delete only this app's saved profile and scoped credentials. Other logins stay untouched.") }
        .onChange(of: login.accountID) { _, _ in code = "" }
    }

    private var addAccountMenu: some View {
        Menu {
            ForEach(Provider.allCases.filter(\.supportsRead)) { provider in
                Button(provider.title) { addProvider(provider) }
            }
            Divider()
            Menu("Dashboard only — not connected yet") {
                ForEach(Provider.allCases.filter { !$0.supportsRead }) { provider in
                    Button(provider.title) { connect(provider, nil) }
                }
            }
        } label: {
            Image(systemName: "plus").font(.title3.weight(.medium)).frame(width: 28, height: 28)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .help("Connect another service").accessibilityLabel("Connect another service")
        .disabled(login.accountID != nil).accessibilityIdentifier("addAccount")
    }

    private func accountSection(_ entry: AccountEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                if entry.account.provider == .claude,
                   let url = Bundle.module.url(forResource: "claude-logo", withExtension: "png"),
                   let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable().interpolation(.high)
                        .scaledToFit().frame(width: 22, height: 22).accessibilityLabel("Claude")
                } else if entry.account.provider == .codex,
                          let url = Bundle.module.url(forResource: "openai-logo", withExtension: "png"),
                          let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).renderingMode(.template).resizable().interpolation(.high)
                        .scaledToFit().frame(width: 22, height: 22).accessibilityLabel("OpenAI")
                } else {
                    Text(String(entry.account.provider.title.prefix(1))).font(.headline)
                        .frame(width: 22, height: 22).foregroundStyle(.secondary)
                        .accessibilityLabel(entry.account.provider.title)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.account.displayName).font(.headline).lineLimit(1).truncationMode(.middle)
                    Text(entry.account.provider.title).font(.caption).foregroundStyle(.secondary)
                    if let email = entry.account.identity?.email, !email.isEmpty, email != entry.account.displayName {
                        Text(email).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer()
                if entry.refreshing { ProgressView().controlSize(.small) }
                Menu {
                    Button("Rename account…") { editedLabel = entry.account.label; renaming = entry.id }
                    Button("Reconnect account…") { reconnect(entry.account) }
                    Link("Provider dashboard", destination: entry.account.provider.dashboardURL)
                    Button("Remove account", role: .destructive) { removal = entry.id }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).fixedSize().disabled(demo || login.accountID != nil)
                .accessibilityLabel("Actions for \(entry.account.displayName)")
            }
            if let snapshot = entry.snapshot {
                ForEach(Array(snapshot.metrics.enumerated()), id: \.offset) { _, metric in
                    metricRow(metric)
                }
                HStack {
                    Text("Checked \(snapshot.fetchedAt.formatted(date: .omitted, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Button("Refresh") { Task { await monitor.refresh(entry.id) } }
                        .buttonStyle(.borderless)
                        .disabled(demo || entry.refreshing || login.accountID != nil)
                }
            } else {
                if let message = entry.error {
                    Label(message, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Usage unavailable until this account connects.").font(.callout).foregroundStyle(.secondary)
                }
                HStack {
                    Button(entry.account.provider.usesHelper ? "Sign in" : "Enter credentials") { reconnect(entry.account) }
                    Button("Refresh") { Task { await monitor.refresh(entry.id) } }
                    if entry.error == MonitorError.keychainUnavailable.localizedDescription {
                        Button("Allow Keychain access") { grantAccess(entry.id) }
                    }
                }.disabled(demo || entry.refreshing || login.accountID != nil || granting != nil)
                if entry.error == MonitorError.keychainUnavailable.localizedDescription {
                    Text("Allow access only to this connection's Keychain entry. Choose Always Allow to enable later usage checks.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private func metricRow(_ metric: UsageMetric) -> some View {
        if metric.kind == .quota {
            meter(metric)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(metric.title).font(.caption)
                    Spacer(minLength: 6)
                    if let value = metric.value, value.isFinite {
                        Text(metric.unit.count == 3 && ["USD", "EUR", "GBP", "CAD", "CNY"].contains(metric.unit)
                             ? value.formatted(.currency(code: metric.unit))
                             : "\(value.formatted(.number.precision(.fractionLength(0...2)))) \(metric.unit)")
                            .font(.caption.monospacedDigit())
                    } else if metric.kind != .note {
                        Text("Unavailable").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let reset = metric.resetsAt {
                    Text("Resets \(reset.usageResetText())").font(.caption).foregroundStyle(.secondary)
                }
                if let detail = metric.detail { Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2).help(detail) }
            }
        }
    }

    private func meter(_ metric: UsageMetric) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                Text(metric.title).font(.callout.weight(.medium)).lineLimit(1)
                Spacer(minLength: 6)
                if let remaining = metric.value, remaining.isFinite, (0...100).contains(remaining) {
                    Text("\(remaining.formatted(.number.precision(.fractionLength(0...1))))% left")
                        .font(.callout.monospacedDigit()).foregroundStyle(metric.remainingColor)
                } else {
                    Text("Unavailable").font(.callout).foregroundStyle(.secondary)
                }
            }
            if let remaining = metric.value, remaining.isFinite, (0...100).contains(remaining) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(metric.remainingColor.opacity(0.15))
                        Capsule().fill(metric.remainingColor).frame(width: geometry.size.width * remaining / 100)
                    }
                }.frame(height: 6)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(metric.title) remaining").accessibilityValue("\(remaining) percent")
            }
            if let reset = metric.resetsAt {
                Text(reset <= Date() ? "Reset time passed — refresh to update" : "Resets \(reset.usageResetText())")
                    .font(.caption).foregroundStyle(.secondary)
            } else { Text("Reset time unavailable").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private var loginSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sign in: \(monitor.entries.first(where: { $0.id == login.accountID })?.account.displayName ?? "Claude")").font(.headline)
            Text(login.provider == .codex
                 ? "Open this link in the browser profile for the account you want. Enter the device code on OpenAI's page; this app waits for approval. Enable device code authorization in ChatGPT security settings if needed."
                 : "Open this link in the browser profile for the account you want. Complete Claude's sign-in, then paste its code below if asked.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let url = login.authorizationURL {
                HStack {
                    Link("Open \(login.provider.title) sign-in", destination: url)
                    Button("Copy login link") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string) }
                }
                if let deviceCode = login.deviceCode {
                    Text(deviceCode).font(.title2.monospaced().weight(.semibold)).textSelection(.enabled)
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
