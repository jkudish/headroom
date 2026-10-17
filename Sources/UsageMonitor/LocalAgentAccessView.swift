import AppKit
import SwiftUI

struct LocalAgentAccessView: View {
    @State var enabled: Bool
    let setEnabled: (Bool) throws -> Void
    let finish: () -> Void
    @State private var error: String?

    private var configuration: String {
        let executable = Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.executableURL?.path
            : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Headroom.app/Contents/MacOS/UsageMonitor").path
        guard let executable else { return "Could not locate Headroom's executable." }
        let config = ["mcpServers": ["headroom": ["command": executable, "args": ["--mcp"]] as [String: Any]]]
        return String(decoding: (try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data(), as: UTF8.self)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Local agent access").font(.title2.bold())
            Toggle("Share usage through MCP", isOn: Binding(get: { enabled }, set: { value in
                do { try setEnabled(value); enabled = value; error = nil }
                catch { self.error = "Could not update the local usage snapshot." }
            }))
            Text("Agents on this Mac can read account names and cached usage. They cannot read keys, refresh providers, or use resets.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Use this configuration in your local agent or Amp's jBeast runner. Keep Headroom running for fresh readings.")
                .fixedSize(horizontal: false, vertical: true)
            Text(configuration).font(.caption.monospaced()).textSelection(.enabled)
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            Text("Local standard input/output only. No network listener. Turning this off removes the shared snapshot.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error { UsageWarning(message: error) }
            HStack {
                Button("Copy MCP config") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(configuration, forType: .string)
                }
                Spacer()
                Button("Done", action: finish).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 480)
    }
}
