import AppKit
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
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var status: NSStatusItem?
    private var popover: NSPopover?
    private var window: NSWindow?
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
                try store.save([Account(label: "Personal"), Account(label: "Work")])
                let ids = try store.load().map(\.id)
                monitor = try Monitor(store: store, fetch: { id in try Self.demoSnapshot(work: id == ids[1]) })
            } else {
                store = try AccountStore.local()
                let client = ClaudeClient(store: store)
                monitor = try Monitor(store: store, fetch: { try await client.fetch($0) })
            }
            guard let monitor else { return }
            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentSize = NSSize(width: 360, height: 670)
            let controller = NSViewController()
            controller.view = makeMonitorPanel(NSHostingView(rootView: view(monitor)))
            popover.contentViewController = controller
            self.popover = popover
            let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            status.button?.image = NSImage(systemSymbolName: "gauge.with.dots.needle.50percent", accessibilityDescription: "Usage Monitor")
            status.button?.target = self
            status.button?.action = #selector(togglePopover)
            self.status = status
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
        MonitorView(monitor: monitor, login: login, demo: demo, openWindow: { [weak self] in self?.openWindow() })
    }

    @objc private func togglePopover() {
        guard let button = status?.button, let popover else { return }
        if popover.isShown { popover.performClose(nil) }
        else { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
    }

    private func openWindow() {
        guard let monitor else { return }
        popover?.performClose(nil)
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 720),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = demo ? "Usage Monitor — Demo" : "Usage Monitor"
            window.isOpaque = false
            window.backgroundColor = .clear
            window.contentView = makeMonitorPanel(NSHostingView(rootView: view(monitor)))
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

    nonisolated private static func demoSnapshot(work: Bool) throws -> UsageSnapshot {
        let data = Data("""
        {"five_hour":{"utilization":\(work ? 90 : 23.5),"resets_at":"2030-10-13T16:30:00Z"},
         "seven_day":{"utilization":\(work ? 100 : 42),"resets_at":"2030-10-18T09:00:00Z"},
         "extra_usage":{"is_enabled":true,"used_credits":\(work ? 3210 : 1234),"monthly_limit":5000}}
        """.utf8)
        return UsageSnapshot(identity: AccountIdentity(accountID: work ? "demo-work" : "demo-personal", organizationID: work ? "work-org" : "personal-org", email: work ? "work@example.test" : "personal@example.test"),
                             usage: try JSONDecoder().decode(ClaudeUsage.self, from: data), fetchedAt: Date())
    }
}
