import AppKit
import Observation
import SwiftUI

@main
enum UsageMonitorApp {
    @MainActor static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItems: [UUID: NSStatusItem] = [:]
    private var emptyStatus: NSStatusItem?
    private var appearanceObservations: [UUID: NSKeyValueObservation] = [:]
    private var window: NSWindow?
    private var connectionWindow: NSWindow?
    private var monitor: Monitor?
    private let login = LoginController()
    private var demoRoot: URL?
    private let demo = CommandLine.arguments.contains("--demo")

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let store: AccountStore
            if demo {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("usage-monitor-demo-\(UUID().uuidString)")
                demoRoot = root
                store = try AccountStore(root: root)
                let accounts = [Account(label: "Personal"), Account(label: "Work"),
                                Account(label: "Codex personal", provider: .codex),
                                Account(label: "Amp work", provider: .amp),
                                Account(label: "OpenRouter wallet", provider: .openRouter)]
                try store.save(accounts)
                monitor = try Monitor(store: store, fetch: { id in
                    guard let account = accounts.first(where: { $0.id == id }) else { throw MonitorError.invalidProfile }
                    return try Self.demoSnapshot(account)
                })
            } else {
                store = try AccountStore.local()
                monitor = try Monitor(store: store, fetch: { try await Self.fetch($0, store: store) })
            }
            guard let monitor else { return }
            observeAccounts()
            if CommandLine.arguments.contains("--window") || demo || monitor.entries.isEmpty { openWindow() }
            Task { for entry in monitor.entries { await monitor.refresh(entry.id) } }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Usage Monitor could not open account storage"
            alert.informativeText = "No credentials were read. Check permissions for ~/Library/Application Support/UsageMonitorPoC."
            alert.runModal()
            NSApplication.shared.terminate(nil)
        }
    }

    private func view(_ monitor: Monitor) -> MonitorView {
        MonitorView(monitor: monitor, login: login, demo: demo,
                    openWindow: { [weak self] in self?.openWindow() },
                    connect: { [weak self] provider, account in self?.openConnection(provider, account: account) })
    }

    private func openConnection(_ provider: Provider, account: Account?) {
        guard let monitor else { return }
        openWindow()
        if provider.usesHelper {
            guard !demo, login.accountID == nil else { return }
            do {
                let id = try account?.id ?? monitor.add(label: "", provider: provider)
                try login.start(id, provider: provider, store: monitor.store) { id in
                    Task { await monitor.refresh(id) }
                }
                monitor.beginLogin(id)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Could not start sign-in"
                alert.informativeText = (error as? MonitorError)?.localizedDescription ?? "Could not update local account storage."
                if let window { alert.beginSheetModal(for: window) }
            }
            return
        }
        guard connectionWindow == nil, let window else { return }
        let form = ConnectionView(monitor: monitor, provider: provider, account: account, demo: demo) { [weak self] in
            guard let self, let sheet = self.connectionWindow else { return }
            self.window?.endSheet(sheet)
            self.connectionWindow = nil
        }
        let content = NSHostingView(rootView: form)
        let sheet = NSWindow(contentRect: NSRect(origin: .zero, size: content.fittingSize),
                             styleMask: [.titled], backing: .buffered, defer: false)
        sheet.title = provider.title
        sheet.contentView = content
        sheet.isReleasedWhenClosed = false
        connectionWindow = sheet
        window.beginSheet(sheet)
    }

    nonisolated private static func fetch(_ id: UUID, store: AccountStore) async throws -> UsageSnapshot {
        guard let account = try store.load().first(where: { $0.id == id }) else { throw MonitorError.signInRequired }
        if account.provider == .claude { return try await ClaudeClient(store: store).fetch(id) }
        if account.provider == .codex { return try await CodexClient(store: store).fetch(id) }
        let secrets = try store.secrets(id)
        switch account.provider {
        case .zai: return try await ZaiClient().fetch(account, secrets: secrets)
        case .openRouter, .searchAPI, .dataForSEO, .firecrawl, .openAIAPI, .anthropicAPI:
            return try await BillingClient().fetch(account, secrets: secrets)
        default: return try await AdditionalClient().fetch(account, secrets: secrets)
        }
    }

    private func observeAccounts() {
        withObservationTracking {
            updateStatusItems()
            _ = login.accountID
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeAccounts() }
        }
    }

    private func newStatusItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        return item
    }

    private func updateStatusItems() {
        guard let monitor else { return }
        for id in Array(statusItems.keys) where !monitor.entries.contains(where: { $0.id == id }) {
            appearanceObservations[id] = nil
            if let item = statusItems.removeValue(forKey: id) { NSStatusBar.system.removeStatusItem(item) }
        }
        if monitor.entries.isEmpty {
            if emptyStatus == nil { emptyStatus = newStatusItem() }
            emptyStatus?.button?.image = NSImage(systemSymbolName: "gauge.with.dots.needle.50percent", accessibilityDescription: "Usage Monitor")
        } else if let emptyStatus {
            NSStatusBar.system.removeStatusItem(emptyStatus)
            self.emptyStatus = nil
        }
        for entry in monitor.entries {
            let item = statusItems[entry.id] ?? newStatusItem()
            statusItems[entry.id] = item
            guard let button = item.button else { continue }
            if appearanceObservations[entry.id] == nil {
                appearanceObservations[entry.id] = button.observe(\.effectiveAppearance) { [weak self] _, _ in
                    Task { @MainActor in self?.updateStatusItems() }
                }
            }
            button.image = MenuBarAccountImage.make(entry, appearance: button.effectiveAppearance)
            let readings = entry.menuBarMetrics.map { "\($0.title): \(MenuBarAccountImage.text($0))" }.joined(separator: ", ")
            let label = "\(entry.account.provider.title) — \(entry.account.displayName): \(readings.isEmpty ? entry.error ?? "Usage unavailable" : readings)"
            button.toolTip = label
            button.setAccessibilityLabel(label)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let monitor else { return }
        menu.removeAllItems()
        menu.appearance = NSApplication.shared.effectiveAppearance
        if demo { menu.addItem(NSMenuItem(title: "Demo — fixture data, not live usage", action: nil, keyEquivalent: "")) }
        if monitor.entries.isEmpty {
            menu.addItem(NSMenuItem(title: "No accounts connected", action: nil, keyEquivalent: ""))
        }
        for entry in monitor.entries {
            let content = NSHostingView(rootView: AccountSummaryView(entry: entry)
                .padding(.horizontal, 16).padding(.vertical, 10).frame(width: 360).fixedSize(horizontal: false, vertical: true))
            content.frame.size = NSSize(width: 360, height: max(1, ceil(content.fittingSize.height)))
            let row = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            row.view = content
            row.isEnabled = false
            menu.addItem(row)
            let actions = NSMenuItem(title: "Account actions", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            let idle = !demo && login.accountID == nil && !entry.refreshing
            addItem("Refresh account", to: submenu, action: #selector(refreshAccount), represented: entry.id.uuidString, enabled: idle)
            addItem(entry.account.provider.usesHelper ? "Sign in / reconnect…" : "Update credentials…", to: submenu,
                    action: #selector(reconnectAccount), represented: entry.id.uuidString, enabled: idle)
            addItem("Provider dashboard", to: submenu, action: #selector(openDashboard), represented: entry.id.uuidString)
            addItem("Rename or remove…", to: submenu, action: #selector(showAccountWindow))
            actions.submenu = submenu
            menu.addItem(actions)
            menu.addItem(.separator())
        }
        let connect = NSMenuItem(title: "Connect service…", action: nil, keyEquivalent: "")
        connect.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Connect service")
        let providers = NSMenu()
        providers.autoenablesItems = false
        for provider in Provider.allCases {
            addItem(provider.title + (provider.supportsRead ? "" : " — dashboard only"), to: providers,
                    action: #selector(connectProvider), represented: provider.rawValue, enabled: login.accountID == nil)
        }
        connect.submenu = providers
        menu.addItem(connect)
        addItem("Refresh all", to: menu, action: #selector(refreshAll),
                enabled: !demo && login.accountID == nil && !monitor.entries.isEmpty && !monitor.entries.contains(where: \.refreshing))
        addItem(login.accountID == nil ? "Open account window…" : "Continue sign-in…", to: menu, action: #selector(showAccountWindow))
        menu.addItem(.separator())
        addItem("Quit", to: menu, action: #selector(quit))
    }

    private func addItem(_ title: String, to menu: NSMenu, action: Selector,
                         represented: String? = nil, enabled: Bool = true) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = represented
        item.isEnabled = enabled
        menu.addItem(item)
    }

    private func selectedAccount(_ sender: NSMenuItem) -> Account? {
        guard let value = sender.representedObject as? String, let id = UUID(uuidString: value) else { return nil }
        return monitor?.entries.first { $0.id == id }?.account
    }

    @objc private func refreshAccount(_ sender: NSMenuItem) {
        guard !demo, login.accountID == nil, let id = selectedAccount(sender)?.id else { return }
        Task { await monitor?.refresh(id) }
    }
    @objc private func reconnectAccount(_ sender: NSMenuItem) {
        guard !demo, login.accountID == nil, let account = selectedAccount(sender) else { return }
        openConnection(account.provider, account: account)
    }
    @objc private func connectProvider(_ sender: NSMenuItem) {
        guard login.accountID == nil, let value = sender.representedObject as? String, let provider = Provider(rawValue: value) else { return }
        openConnection(provider, account: nil)
    }
    @objc private func openDashboard(_ sender: NSMenuItem) {
        if let account = selectedAccount(sender) { NSWorkspace.shared.open(account.provider.dashboardURL) }
    }
    @objc private func refreshAll() {
        guard !demo, login.accountID == nil, let monitor else { return }
        Task { for entry in monitor.entries { await monitor.refresh(entry.id) } }
    }
    @objc private func showAccountWindow() { openWindow() }
    @objc private func quit() { login.cancel(); NSApplication.shared.terminate(nil) }

    private func openWindow() {
        guard let monitor else { return }
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 720),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = demo ? "Usage Monitor — Demo" : "Usage Monitor"
            window.contentView = NSHostingView(rootView: view(monitor))
            window.minSize = NSSize(width: 360, height: 480)
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        login.cancel()
        if let demoRoot { try? FileManager.default.removeItem(at: demoRoot) }
    }

    nonisolated static func demoSnapshot(_ account: Account) throws -> UsageSnapshot {
        let reset = Date().addingTimeInterval(36 * 3600)
        switch account.provider {
        case .codex:
            return UsageSnapshot(identity: .init(accountID: "demo-codex", organizationID: "demo-codex-workspace", email: "codex@example.test"),
                                 metrics: [.init(title: "5-hour", kind: .quota, value: 8, resetsAt: reset),
                                           .init(title: "Weekly", kind: .quota, value: 63, resetsAt: reset),
                                           .init(title: "Individual credit quota", kind: .quota, value: 49.93868, resetsAt: reset),
                                           .init(title: "Credits left", kind: .balance, value: 49938.68, unit: "credits"),
                                           .init(title: "Credit limit", kind: .cap, value: 100000, unit: "credits")],
                                 plan: "Pro", resetCredits: .init(availableCount: 3, expirations: [reset.addingTimeInterval(7 * 86400)]))
        case .amp:
            return UsageSnapshot(metrics: [.init(title: "Agent remaining", kind: .balance, value: 18.57, unit: "USD"),
                                           .init(title: "Orb remaining", kind: .count, value: 732.8, unit: "a1.small hours"),
                                           .init(title: "Individual credits", kind: .balance, value: 31.25, unit: "USD")])
        case .openRouter:
            return UsageSnapshot(metrics: [.init(title: "Wallet credits", kind: .balance, value: 37.82, unit: "USD")])
        default: break
        }
        let work = account.label == "Work"
        let data = Data("""
        {"five_hour":{"utilization":\(work ? 90 : 23.5),"resets_at":"2030-10-13T16:30:00Z"},
         "seven_day":{"utilization":\(work ? 100 : 42),"resets_at":"2030-10-18T09:00:00Z"},
         "extra_usage":{"is_enabled":true,"used_credits":\(work ? 3210 : 1234),"monthly_limit":5000}}
        """.utf8)
        return UsageSnapshot(identity: AccountIdentity(accountID: work ? "demo-work" : "demo-personal", organizationID: work ? "work-org" : "personal-org", email: work ? "work@example.test" : "personal@example.test"),
                             usage: try JSONDecoder().decode(ClaudeUsage.self, from: data), fetchedAt: Date(), plan: work ? "Max 20x" : "Pro")
    }
}
