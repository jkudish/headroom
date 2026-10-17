import Foundation

enum AmpCLI {
    static func usage(_ token: String, id: UUID, store: AccountStore) async throws -> String {
        guard token.hasPrefix("sgamp_"), token.utf8.count <= 16384,
              !token.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw MonitorError.signInRequired }
        // Prefer the official installation over user shell wrappers.
        let paths = ["/opt/homebrew/bin/amp", "/usr/local/bin/amp"]
        guard let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw MonitorError.unsupported("Install Amp's official CLI to read Orb usage with this access token.")
        }
        try store.prepare(id)
        let home = store.profile(id).deletingLastPathComponent().appendingPathComponent("home")
        let environment = ["HOME": home.path, "XDG_CONFIG_HOME": home.appendingPathComponent(".config").path,
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "AMP_API_KEY": token,
            "AMP_SKIP_UPDATE_CHECK": "1", "BROWSER": "/usr/bin/false", "NO_COLOR": "1", "TERM": "dumb"]
        let data = try await ScopedCLI.run(executable: URL(fileURLWithPath: path), arguments: ["usage"],
                                          environment: environment, directory: store.profile(id))
        let text = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: #"\x{1B}\[[0-9;]*[A-Za-z]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "**", with: "")
        guard !text.isEmpty else { throw MonitorError.invalidResponse }
        return text
    }
}
