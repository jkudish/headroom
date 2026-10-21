import AppKit
import ServiceManagement

@MainActor
struct LaunchAtLogin {
    var readStatus: () -> SMAppService.Status = { SMAppService.mainApp.status }
    var register: () throws -> Void = { try SMAppService.mainApp.register() }
    var unregister: () async throws -> Void = { try await SMAppService.mainApp.unregister() }

    var menuState: NSControl.StateValue {
        switch readStatus() {
        case .enabled: .on
        case .requiresApproval: .mixed
        default: .off
        }
    }

    func toggle() async throws {
        switch readStatus() {
        case .enabled, .requiresApproval: try await unregister()
        default: try register()
        }
    }
}
