import AppKit
import SwiftUI

struct MonitorView: View {
    @Bindable var monitor: Monitor
    @Bindable var login: LoginController
    let demo: Bool
    let openWindow: () -> Void
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
                    Text("Claude subscriptions · \(monitor.entries.count) \(monitor.entries.count == 1 ? "account" : "accounts")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { openWindow() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
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
                            Text("All your Claude accounts, separately.").font(.headline)
                            Text("Add an account and sign in through Claude Code. Your existing CLI login stays untouched.")
                                .foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }.frame(maxWidth: .infinity).padding(.vertical, 26)
                    }
                    ForEach(monitor.entries) { entry in accountCard(entry) }
                    if login.accountID != nil { loginCard }
                    if let message = error ?? login.error {
                        Label(message, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Divider()
                    Button("Add Claude account", systemImage: "plus") {
                        perform {
                            let id = try monitor.add(label: "")
                            startLogin(id)
                        }
                    }.disabled(demo || login.accountID != nil).accessibilityIdentifier("addAccount")
                }.padding(18)
            }
            Divider()
            HStack {
                Button("Refresh all", systemImage: "arrow.clockwise") {
                    Task { for entry in monitor.entries { await monitor.refresh(entry.id) } }
                }.disabled(demo || login.accountID != nil || monitor.entries.isEmpty || monitor.entries.contains(where: \.refreshing))
                Spacer()
                Button("Quit") { login.cancel(); NSApplication.shared.terminate(nil) }
            }.padding(12)
        }
        .frame(minWidth: 440, minHeight: 440)
        .alert("Account name", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $editedLabel)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") {
                if let id = renaming { perform { try monitor.rename(id, label: editedLabel) } }
                renaming = nil
            }
        } message: { Text("Leave blank to use the name from your Claude account.") }
        .alert("Remove this account?", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } })) {
            Button("Cancel", role: .cancel) { removal = nil }
            Button("Remove", role: .destructive) {
                if let id = removal { perform { try monitor.remove(id) } }
                removal = nil
            }
        } message: { Text("Delete only this app's saved profile and scoped credentials. Other Claude logins stay untouched.") }
        .onChange(of: login.accountID) { _, _ in code = "" }
    }

    private func accountCard(_ entry: AccountEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                if let url = Bundle.module.url(forResource: "claude-logo", withExtension: "png"),
                   let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable().interpolation(.high)
                        .scaledToFit().frame(width: 22, height: 22).accessibilityLabel("Claude")
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.account.displayName).font(.headline)
                    if entry.account.identity?.email != entry.account.displayName {
                        Text(entry.account.identity?.email ?? "Not connected")
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                Spacer()
                if entry.refreshing { ProgressView().controlSize(.small) }
                Menu {
                    Button("Rename account…") { editedLabel = entry.account.label; renaming = entry.id }
                    Button("Sign in again") { startLogin(entry.id) }
                    Button("Remove account", role: .destructive) { removal = entry.id }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).fixedSize().disabled(demo || login.accountID != nil)
                .accessibilityLabel("Actions for \(entry.account.displayName)")
            }
            if let snapshot = entry.snapshot {
                meter("5-hour", window: snapshot.usage.fiveHour)
                meter("Weekly", window: snapshot.usage.sevenDay)
                extraUsage(snapshot.usage.extraUsage)
                HStack {
                    Text("Checked \(snapshot.fetchedAt.formatted(date: .omitted, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Button("Refresh") { Task { await monitor.refresh(entry.id) } }
                        .disabled(demo || entry.refreshing || login.accountID != nil)
                }
            } else {
                if let message = entry.error {
                    Label(message, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Usage unavailable until this account signs in.").font(.callout).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Sign in with Claude") { startLogin(entry.id) }
                    Button("Refresh") { Task { await monitor.refresh(entry.id) } }
                    if entry.error == MonitorError.keychainUnavailable.localizedDescription {
                        Button("Allow Keychain access") { grantAccess(entry.id) }
                    }
                }.disabled(demo || entry.refreshing || login.accountID != nil || granting != nil)
                if entry.error == MonitorError.keychainUnavailable.localizedDescription {
                    Text("Allow access only to this app's scoped Claude Code entry. Choose Always Allow to enable later usage checks.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
    }

    private func meter(_ title: String, window: ClaudeUsage.Window?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                Text(title).font(.callout.weight(.medium)).frame(width: 58, alignment: .leading)
                if let remaining = window?.remaining {
                    let color = window?.remainingColor ?? .secondary
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(color.opacity(0.15))
                            Capsule().fill(color).frame(width: geometry.size.width * remaining / 100)
                        }
                    }.frame(height: 6)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(title) remaining").accessibilityValue("\(remaining) percent")
                    Text("\(remaining.formatted(.number.precision(.fractionLength(0...1))))% left")
                        .font(.callout.monospacedDigit()).foregroundStyle(color).frame(width: 78, alignment: .trailing)
                } else {
                    Spacer()
                    Text("Unavailable").font(.callout).foregroundStyle(.secondary)
                }
            }
            if let reset = window?.resetDate {
                Text(reset <= Date() ? "Reset time passed — refresh to update" : "Resets \(window?.formattedReset() ?? "")")
                    .font(.caption).foregroundStyle(.secondary)
            } else { Text("Reset time unavailable").font(.caption).foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder private func extraUsage(_ extra: ClaudeUsage.ExtraUsage?) -> some View {
        if extra?.isEnabled == false {
            Text("Extra usage disabled").font(.caption).foregroundStyle(.secondary)
        } else if let extra, extra.isEnabled == true, let spent = extra.spent {
            let currency = extra.currency ?? "USD"
            HStack {
                Text("Extra usage").font(.caption)
                Spacer()
                if let cap = extra.cap {
                    Text("\(spent.formatted(.currency(code: currency))) / \(cap.formatted(.currency(code: currency))) monthly cap")
                        .font(.caption.monospacedDigit())
                } else {
                    Text("\(spent.formatted(.currency(code: currency))) spent · cap unavailable").font(.caption.monospacedDigit())
                }
            }.foregroundStyle(.secondary)
        } else { Text("Extra usage unavailable").font(.caption).foregroundStyle(.secondary) }
    }

    private var loginCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sign in: \(monitor.entries.first(where: { $0.id == login.accountID })?.account.displayName ?? "Claude")").font(.headline)
            Text("Open this link in the browser profile for the account you want. Complete Claude's sign-in, then paste its code below if asked.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let url = login.authorizationURL {
                HStack {
                    Link("Open Claude sign-in", destination: url)
                    Button("Copy login link") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string) }
                }
                SecureField("Authorization code", text: $code).textFieldStyle(.roundedBorder).accessibilityIdentifier("authorizationCode")
                Button("Complete sign-in") { perform { try login.submit(code); code = "" } }
                    .disabled(code.isEmpty)
            } else {
                HStack { ProgressView().controlSize(.small); Text(login.submitted ? "Completing sign-in…" : "Waiting for Claude Code's login link…") }
            }
            Button("Cancel sign-in") { login.cancel(); code = "" }
        }.padding(14).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }

    private func startLogin(_ id: UUID) {
        openWindow()
        perform {
            try login.start(id, store: monitor.store) { id in Task { await monitor.refresh(id) } }
            monitor.beginLogin(id)
        }
    }

    private func grantAccess(_ id: UUID) {
        granting = id
        error = nil
        let store = monitor.store
        Task {
            do {
                try await Task.detached { _ = try store.credentials(id, allowInteraction: true) }.value
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
        guard let remaining else { return .secondary }
        if remaining == 0 { return .red }
        return remaining <= 10 ? .orange : .accentColor
    }
}

@MainActor
func makeMonitorPanel(_ content: NSView) -> NSView {
    let panel: NSView
    if #available(macOS 26, *) {
        let glass = NSGlassEffectView()
        glass.style = .regular
        glass.cornerRadius = 16
        glass.contentView = content
        panel = glass
    } else {
        let material = NSVisualEffectView()
        material.material = .popover
        material.blendingMode = .behindWindow
        material.state = .active
        material.addSubview(content)
        panel = material
    }
    content.autoresizingMask = [.width, .height]
    content.frame = panel.bounds
    return panel
}
