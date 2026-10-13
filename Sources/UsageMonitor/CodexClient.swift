import Darwin
import Foundation

struct CodexClient: Sendable {
    let store: AccountStore
    var http: ProviderHTTP = ProviderHTTP()

    func fetch(_ id: UUID) async throws -> UsageSnapshot {
        let credential = try CodexCredential.decode(CodexProfile.authData(id, store: store))
        let data = try await request("wham/usage", credential: credential)
        guard let usage = try? JSONDecoder().decode(CodexUsage.self, from: data) else {
            throw MonitorError.invalidResponse
        }
        if let account = usage.account_id, account != credential.workspace {
            throw MonitorError.identityChanged
        }
        let metrics = try usage.metrics()

        // This endpoint provides workspace labels, not a verified human profile.
        // Failure to enrich a label must not discard a successful quota response.
        var name: String?
        if let data = try? await request("accounts", credential: credential),
           let accounts = try? JSONDecoder().decode(CodexAccounts.self, from: data) {
            let selected = accounts.items.filter { $0.id == credential.workspace }
            if selected.count == 1 { name = selected.first?.name }
        }
        return UsageSnapshot(identity: AccountIdentity(
            // OpenAI uses chatgpt_account_id for both account and workspace identity.
            // Never substitute chatgpt_user_id or the first/default organization.
            accountID: credential.workspace, organizationID: credential.workspace,
            email: credential.email ?? "Email unavailable", name: name
        ), metrics: metrics)
    }

    private func request(_ path: String, credential: CodexCredential) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/\(path)")!)
        request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
        request.setValue(credential.workspace, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
        return try await http.data(for: request)
    }
}

enum CodexAuth {
    static let loginArguments = ["login", "--device-auth", "-c", "cli_auth_credentials_store=\"file\""]

    // Use this as the complete child environment, never merge ambient credentials.
    // Launch in store.profile(id); the device code is transient UI state, not a log.
    static func environment(_ id: UUID, store: AccountStore) throws -> [String: String] {
        do { try store.prepare(id) }
        catch { throw MonitorError.invalidProfile }
        try CodexProfile.validate(id, store: store)
        let home = store.profile(id).deletingLastPathComponent().appendingPathComponent("home")
        return [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "USER": NSUserName(), "LOGNAME": NSUserName(),
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "CODEX_HOME": store.profile(id).path,
            "XDG_CONFIG_HOME": home.appendingPathComponent(".config").path,
            "BROWSER": "/usr/bin/false", "TERM": "dumb", "NO_COLOR": "1"
        ]
    }
}

private enum CodexProfile {
    // Open each component relative to a validated directory descriptor. O_NOFOLLOW
    // keeps a swapped symlink from redirecting the selected UUID's credential read.
    private static func directory(_ id: UUID, store: AccountStore) throws -> Int32 {
        var fd = open(store.root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw MonitorError.invalidProfile }
        do {
            try check(fd, directory: true)
            for component in ["accounts", id.uuidString, "config"] {
                let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else {
                    throw errno == ENOENT ? MonitorError.signInRequired : .invalidProfile
                }
                close(fd)
                fd = next
                try check(fd, directory: true)
            }
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    private static func check(_ fd: Int32, directory: Bool) throws {
        var attributes = stat()
        guard fstat(fd, &attributes) == 0,
              attributes.st_uid == geteuid(), attributes.st_mode & 0o077 == 0,
              attributes.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG),
              directory || (attributes.st_nlink == 1 && attributes.st_size <= 1_048_576) else {
            throw MonitorError.invalidProfile
        }
    }

    static func validate(_ id: UUID, store: AccountStore) throws {
        let dir = try directory(id, store: store)
        defer { close(dir) }
        for file in ["auth.json", "config.toml"] {
            let fd = openat(dir, file, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else {
                if errno == ENOENT { continue } // A new isolated profile is valid for login.
                throw MonitorError.invalidProfile
            }
            defer { close(fd) }
            try check(fd, directory: false)
        }
    }

    static func authData(_ id: UUID, store: AccountStore) throws -> Data {
        let dir = try directory(id, store: store)
        defer { close(dir) }
        let fd = openat(dir, "auth.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw errno == ENOENT ? MonitorError.signInRequired : .invalidProfile }
        defer { close(fd) }
        try check(fd, directory: false)
        do {
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            return try handle.read(upToCount: 1_048_577) ?? Data()
        } catch { throw MonitorError.invalidProfile }
    }
}

private struct CodexCredential {
    let token: String
    let workspace: String
    let email: String?

    static func decode(_ data: Data) throws -> Self {
        struct AuthFile: Decodable {
            struct Tokens: Decodable { let access_token: String; let id_token: String?; let account_id: String? }
            let tokens: Tokens
        }
        guard let file = try? JSONDecoder().decode(AuthFile.self, from: data),
              safeHeader(file.tokens.access_token),
              let access = try? CodexClaims.decode(file.tokens.access_token),
              let expiration = access.exp, expiration.isFinite,
              expiration > Date().timeIntervalSince1970 + 30,
              let workspace = access.workspace, safeHeader(workspace) else {
            throw MonitorError.signInRequired
        }
        if let selected = file.tokens.account_id, selected != workspace { throw MonitorError.identityChanged }
        let identity = file.tokens.id_token.flatMap { try? CodexClaims.decode($0) }
        if let other = identity?.workspace, other != workspace { throw MonitorError.identityChanged }
        return Self(token: file.tokens.access_token, workspace: workspace,
                    email: identity?.email ?? identity?.profile?.email ?? access.email ?? access.profile?.email)
    }

    private static func safeHeader(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy { (33...126).contains($0.value) }
    }
}

private struct CodexClaims: Decodable {
    struct Auth: Decodable { let chatgpt_account_id: String? }
    struct Profile: Decodable { let email: String? }
    let exp: Double?
    let email: String?
    let chatgpt_account_id: String?
    let auth: Auth?
    let profile: Profile?
    var workspace: String? { auth?.chatgpt_account_id ?? chatgpt_account_id }
    enum CodingKeys: String, CodingKey {
        case exp, email, chatgpt_account_id
        case auth = "https://api.openai.com/auth", profile = "https://api.openai.com/profile"
    }

    // Payload decoding is NOT cryptographic verification. The provider validates
    // the bearer on fetch. Claims only scope the request and supply local metadata.
    static func decode(_ token: String) throws -> Self {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw MonitorError.signInRequired }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else { throw MonitorError.signInRequired }
        return try JSONDecoder().decode(Self.self, from: data)
    }
}

private struct CodexAccounts: Decodable {
    struct Item: Decodable { let id: String; let name: String? }
    let items: [Item]
}

private struct CodexUsage: Decodable {
    struct Window: Decodable {
        let used_percent: Double
        let limit_window_seconds: Int?
        let reset_at: Double?

        func metric(_ fallback: String) throws -> UsageMetric {
            guard (0...100).contains(used_percent) else { throw MonitorError.invalidResponse }
            let title: String
            if let seconds = limit_window_seconds, seconds > 0 {
                title = seconds % 3600 == 0 ? "\(seconds / 3600)-hour" : "\(seconds)-second"
            } else { title = fallback }
            return .init(title: title, kind: .quota, value: 100 - used_percent,
                         resetsAt: reset_at.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil })
        }
    }
    struct Limit: Decodable {
        let limit: CodexNumber?
        let used: CodexNumber?
        let remaining_percent: Double?
        let reset_at: Double?

        func metrics() throws -> [UsageMetric] {
            let cap = limit?.value, spent = used?.value
            guard cap.map({ $0 >= 0 }) ?? true, spent.map({ $0 >= 0 }) ?? true,
                  remaining_percent.map({ (0...100).contains($0) }) ?? true else { throw MonitorError.invalidResponse }
            let remaining = remaining_percent ?? cap.flatMap { total in
                total > 0 ? spent.map { max(0, 100 - $0 / total * 100) } : nil
            }
            var rows: [UsageMetric] = []
            if let remaining {
                rows.append(.init(title: "Individual credit quota", kind: .quota, value: remaining,
                                  resetsAt: reset_at.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }))
            }
            // Backend credit quantities are not documented as cents or USD.
            if let spent { rows.append(.init(title: "Credits used", kind: .spend, value: spent, unit: "credits")) }
            if let cap { rows.append(.init(title: "Credit limit", kind: .cap, value: cap, unit: "credits")) }
            return rows
        }
    }
    struct RateLimit: Decodable { let primary_window: Window?; let secondary_window: Window?; let individual_limit: Limit? }
    struct SpendControl: Decodable { let individual_limit: Limit? }
    struct Credits: Decodable { let has_credits: Bool?; let unlimited: Bool?; let balance: CodexNumber? }
    let account_id: String?
    let rate_limit: RateLimit?
    let credits: Credits?
    let individual_limit: Limit?
    let spend_control: SpendControl?

    func metrics() throws -> [UsageMetric] {
        guard rate_limit != nil || credits != nil || individual_limit != nil || spend_control?.individual_limit != nil else {
            throw MonitorError.invalidResponse
        }
        var rows: [UsageMetric] = []
        if let primary = rate_limit?.primary_window { rows.append(try primary.metric("Primary quota")) }
        if let secondary = rate_limit?.secondary_window { rows.append(try secondary.metric("Secondary quota")) }
        if let limit = individual_limit ?? rate_limit?.individual_limit ?? spend_control?.individual_limit {
            rows += try limit.metrics()
        }
        if let credits {
            if credits.unlimited == true {
                rows.append(.init(title: "Credits", kind: .note, value: nil, unit: "credits", detail: "Unlimited"))
            } else if let balance = credits.balance?.value {
                guard balance >= 0 else { throw MonitorError.invalidResponse }
                rows.append(.init(title: "Credit balance", kind: .balance, value: balance, unit: "credits"))
            }
        }
        if rows.isEmpty { rows.append(.init(title: "Quota", kind: .note, value: nil, detail: "No quota windows returned")) }
        return rows
    }
}

private struct CodexNumber: Decodable {
    let value: Double
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let number = (try? container.decode(Double.self)) ?? (try? container.decode(String.self)).flatMap(Double.init)
        guard let number, number.isFinite else { throw MonitorError.invalidResponse }
        value = number
    }
}
