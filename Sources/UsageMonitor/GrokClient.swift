import Foundation

struct GrokClient: Sendable {
    let store: AccountStore
    var http = ProviderHTTP()
    var billing: (@Sendable (UUID) async throws -> Data)? = nil

    func fetch(_ id: UUID) async throws -> UsageSnapshot {
        _ = try GrokAuth.token(HelperProfile.authData(id, store: store))
        let data: Data
        if let billing { data = try await billing(id) }
        else {
            data = try await ScopedCLI.run(executable: GrokAuth.executable(), arguments: ["agent", "--no-leader", "stdio"],
                environment: GrokAuth.environment(id, store: store), directory: store.profile(id), billingRPC: true)
        }
        // The official helper alone owns refresh-token rotation. Read its new bearer after billing.
        let token = try GrokAuth.token(HelperProfile.authData(id, store: store))
        return try await AdditionalClient().grokSnapshot(data, identity: Self.identity(token: token, http: http))
    }

    static func identity(token: String, http: ProviderHTTP) async throws -> AccountIdentity {
        var request = URLRequest(url: URL(string: "https://cli-chat-proxy.grok.com/v1/user")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("xai-grok-cli", forHTTPHeaderField: "X-XAI-Token-Auth")
        let user = try await http.data(for: request)
        guard let fields = try JSONSerialization.jsonObject(with: user) as? [String: Any],
              let person = fields["userId"] as? String, !person.isEmpty else { throw MonitorError.invalidResponse }
        let principal = fields["principalId"] as? String ?? fields["teamId"] as? String ?? ""
        return AccountIdentity(accountID: person, organizationID: principal, email: fields["email"] as? String ?? "")
    }
}

enum GrokAuth {
    static func executable() throws -> URL {
        let paths = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok/bin/grok").path,
                     "/opt/homebrew/bin/grok", "/usr/local/bin/grok"]
        guard let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw MonitorError.unsupported("Install the official Grok CLI to use browser sign-in.")
        }
        return URL(fileURLWithPath: path)
    }

    static func environment(_ id: UUID, store: AccountStore) throws -> [String: String] {
        try store.prepare(id)
        // Grok preserves ordinary config read permissions; credentials remain owner-only.
        try HelperProfile.validate(id, store: store, allowReadableConfig: true)
        let home = store.profile(id).deletingLastPathComponent().appendingPathComponent("home")
        return ["HOME": home.path, "XDG_CONFIG_HOME": home.appendingPathComponent(".config").path,
                "GROK_HOME": store.profile(id).path, "GROK_AUTH_PATH": store.profile(id).appendingPathComponent("auth.json").path,
                "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "TERM": "dumb", "NO_COLOR": "1",
                "GROK_DISABLE_AUTOUPDATER": "1"]
    }

    static func token(_ data: Data) throws -> String {
        guard let map = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MonitorError.signInRequired }
        let entries = map.filter { $0.key.hasPrefix("https://auth.x.ai::") }.compactMap { $0.value as? [String: Any] }
        guard entries.count == 1, let entry = entries.first,
              entry["oidc_issuer"] as? String == "https://auth.x.ai",
              let key = entry["key"] as? String, !key.isEmpty, key.utf8.count <= 16384,
              !key.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw MonitorError.signInRequired }
        return key
    }
}
