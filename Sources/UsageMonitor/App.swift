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
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private var status: NSStatusItem?
    private var availabilityTimer: Timer?
    private var refreshTimer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var appearanceObservation: NSKeyValueObservation?
    private var window: NSWindow?
    private var connectionWindow: NSWindow?
    private var monitor: Monitor?
    private let login = LoginController()
    private var demoRoot: URL?
    private let demo = CommandLine.arguments.contains("--demo")

    func applicationDidFinishLaunching(_ notification: Notification) {
        installApplicationMenu()
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
                    connect: { [weak self] provider, account in self?.openConnection(provider, account: account) },
                    showResets: { [weak self] account in self?.openResetDetails(account) })
    }

    private func openConnection(_ provider: Provider, account: Account?) {
        guard let monitor, !monitor.entries.contains(where: \.resetting) else { return }
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
        guard connectionWindow == nil else { return }
        let form = ConnectionView(monitor: monitor, provider: provider, account: account, demo: demo) { [weak self] in
            self?.closeSheet()
        }
        presentSheet(provider.title, content: form)
    }

    private func openResetDetails(_ account: Account) {
        guard let monitor, account.provider == .codex, login.accountID == nil, connectionWindow == nil else { return }
        openWindow()
        presentSheet("Available resets", content: ResetCreditsView(monitor: monitor, accountID: account.id, demo: demo) { [weak self] in
            self?.closeSheet()
        })
    }

    private func closeSheet() {
        guard let sheet = connectionWindow else { return }
        window?.endSheet(sheet)
        connectionWindow = nil
    }

    private func presentSheet<V: View>(_ title: String, content view: V) {
        guard connectionWindow == nil, let window else { return }
        let content = NSHostingView(rootView: view)
        let sheet = NSWindow(contentRect: NSRect(origin: .zero, size: content.fittingSize),
                             styleMask: [.titled], backing: .buffered, defer: false)
        sheet.title = title
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
            updateStatusItem()
            scheduleAutomaticRefresh()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeAccounts() }
        }
    }

    private func scheduleAutomaticRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        guard !demo, login.accountID == nil, refreshTask == nil,
              let due = monitor?.nextAutomaticRefresh else { return }
        let timer = Timer(fire: due, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refreshDue() }
        }
        timer.tolerance = 1
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func refreshDue(maxAge: TimeInterval = 60) {
        guard !demo, login.accountID == nil, refreshTask == nil, let monitor else { return }
        refreshTimer?.invalidate()
        refreshTask = Task { [weak self] in
            await monitor.refreshDue(maxAge: maxAge, isPaused: { [weak self] in self?.login.accountID != nil })
            self?.refreshTask = nil
            self?.scheduleAutomaticRefresh()
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

    private func updateStatusItem() {
        availabilityTimer?.invalidate()
        availabilityTimer = nil
        guard let monitor else { return }
        let now = Date()
        if status == nil { status = newStatusItem() }
        guard let button = status?.button else { return }
        if appearanceObservation == nil {
            appearanceObservation = button.observe(\.effectiveAppearance) { [weak self] _, _ in
                Task { @MainActor in self?.updateStatusItem() }
            }
        }
        button.image = MenuBarAccountImage.make(monitor.entries, appearance: button.effectiveAppearance)
        let labels = monitor.entries.filter { $0.account.showInMenuBar }.map { entry in
            let readings = entry.menuBarMetrics.map { "\($0.title): \(MenuBarAccountImage.text($0, provider: entry.account.provider))" }.joined(separator: ", ")
            return "\(entry.account.provider.title) — \(entry.displayName): \(readings.isEmpty ? entry.error ?? "Usage unavailable" : readings)"
        }
        let label = labels.isEmpty ? "Usage Monitor — open all accounts" : labels.joined(separator: "\n")
        button.toolTip = nil
        button.setAccessibilityLabel(label)
        let nextChange = monitor.entries.filter { $0.account.showInMenuBar }
            .flatMap { $0.snapshot?.availabilityChangeDates ?? [] }.filter { $0 > now }.min()
        if let nextChange {
            // A one-shot display update at a known deadline, never a provider refresh.
            let timer = Timer(fire: nextChange, interval: 0, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.updateStatusItem() }
            }
            availabilityTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let monitor else { return }
        refreshDue(maxAge: 30)
        menu.removeAllItems()
        menu.appearance = NSApplication.shared.effectiveAppearance
        if demo { menu.addItem(NSMenuItem(title: "Demo data", action: nil, keyEquivalent: "")) }
        if monitor.entries.isEmpty {
            menu.addItem(NSMenuItem(title: "No accounts connected", action: nil, keyEquivalent: ""))
        }
        for provider in Provider.allCases {
            let entries = monitor.entries.filter { $0.account.provider == provider }
            guard !entries.isEmpty else { continue }
            let content = NSHostingView(rootView: ProviderAccountGrid(entries: entries) { [weak self] entry in
                VStack(alignment: .leading, spacing: 8) {
                    AccountSummaryView(entry: entry, compact: true)
                    if provider == .codex {
                        Button("Use reset…") { [weak self] in self?.openResetDetails(entry.account) }
                            .disabled(self?.login.accountID != nil || entry.resetting)
                            .accessibilityIdentifier("menuResets-\(entry.id)")
                    }
                }.buttonStyle(.borderless).font(.system(size: 12))
            }
                .padding(.horizontal, 16).padding(.vertical, 10).frame(width: 420).fixedSize(horizontal: false, vertical: true))
            content.frame.size = NSSize(width: 420, height: max(1, ceil(content.fittingSize.height)))
            let row = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            row.view = content
            row.isEnabled = false
            menu.addItem(row)
            let actions = NSMenuItem(title: "Account actions", action: nil, keyEquivalent: "")
            let accounts = NSMenu()
            accounts.autoenablesItems = false
            for entry in entries {
                let account = NSMenuItem(title: entry.displayName, action: nil, keyEquivalent: "")
                let submenu = NSMenu()
                submenu.autoenablesItems = false
                let idle = !demo && login.accountID == nil && !entry.refreshing && !entry.resetting
                addItem("Refresh", to: submenu, action: #selector(refreshAccount), represented: entry.id.uuidString, enabled: idle)
                addItem("Reconnect…", to: submenu,
                        action: #selector(reconnectAccount), represented: entry.id.uuidString, enabled: idle)
                if provider == .codex {
                    addItem("Available resets…", to: submenu, action: #selector(showResetDetails),
                            represented: entry.id.uuidString, enabled: login.accountID == nil && !entry.resetting)
                }
                addItem("Dashboard", to: submenu, action: #selector(openDashboard), represented: entry.id.uuidString)
                addItem("Account settings…", to: submenu, action: #selector(showAccountWindow))
                account.submenu = submenu
                accounts.addItem(account)
            }
            actions.submenu = accounts
            menu.addItem(actions)
            menu.addItem(.separator())
        }
        let connect = NSMenuItem(title: "Add account…", action: nil, keyEquivalent: "")
        connect.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add account")
        let providers = NSMenu()
        providers.autoenablesItems = false
        for provider in Provider.allCases.filter(\.supportsRead) {
            addItem(provider.title, to: providers,
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
    @objc private func showResetDetails(_ sender: NSMenuItem) {
        if let account = selectedAccount(sender) { openResetDetails(account) }
    }
    @objc private func quit() { login.cancel(); NSApplication.shared.terminate(nil) }

    private func installApplicationMenu() {
        let main = NSMenu()
        let application = NSMenuItem()
        let appMenu = NSMenu()
        let quit = NSMenuItem(title: "Quit Usage Monitor", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        appMenu.addItem(quit)
        application.submenu = appMenu
        main.addItem(application)
        let edit = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        for (title, action, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"),
                                     ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            editMenu.addItem(NSMenuItem(title: title, action: NSSelectorFromString(action), keyEquivalent: key))
        }
        edit.submenu = editMenu
        main.addItem(edit)
        NSApplication.shared.mainMenu = main
    }

    func windowWillClose(_ notification: Notification) {
        if let closed = notification.object as? NSWindow, closed === window {
            NSApplication.shared.setActivationPolicy(.accessory)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openWindow()
        return true
    }

    private func openWindow() {
        guard let monitor else { return }
        NSApplication.shared.setActivationPolicy(.regular)
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 720),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = demo ? "Usage Monitor — Demo" : "Usage Monitor"
            window.contentView = NSHostingView(rootView: view(monitor))
            window.minSize = NSSize(width: 360, height: 480)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        availabilityTimer?.invalidate()
        refreshTimer?.invalidate()
        refreshTask?.cancel()
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
                                 plan: "Pro 200", resetCredits: .init(availableCount: 3, expirations: [reset.addingTimeInterval(7 * 86400)], credits: [
                                    .init(id: "demo-reset-1", resetType: "codex_rate_limits", status: "available",
                                          grantedAt: Date().addingTimeInterval(-86400), expiresAt: reset.addingTimeInterval(7 * 86400),
                                          title: "Codex limit reset", description: "A fixture credit for preview only."),
                                    .init(id: "demo-reset-used", resetType: "codex_rate_limits", status: "redeemed",
                                          grantedAt: nil, expiresAt: nil, title: "Used reset", description: nil)
                                 ]))
        case .amp:
            return UsageSnapshot(metrics: [.init(title: "Agent", kind: .quota, value: 8.9, resetsAt: reset),
                                           .init(title: "Orb", kind: .quota, value: 57.3, resetsAt: reset),
                                           .init(title: "Individual credits", kind: .balance, value: 31.25, unit: "USD")],
                                 plan: "Gigawatt", reportedEmail: "amp@example.test")
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
