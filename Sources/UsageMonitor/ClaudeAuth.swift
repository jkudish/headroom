import CryptoKit
import Darwin
import Foundation

// The same kernel lock protects login, renewal and removal, including another Headroom process.
final class ClaudeCredentialLease: Sendable {
    private let descriptor: Int32

    init(file: URL) throws {
        let fd = open(file.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw MonitorError.invalidProfile }
        var attributes = stat()
        guard fstat(fd, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG,
              attributes.st_uid == getuid(), attributes.st_nlink == 1 else {
            close(fd)
            throw MonitorError.invalidProfile
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw MonitorError.loginBusy
        }
        descriptor = fd
    }

    deinit { close(descriptor) }
}

struct ClaudeAuth: Sendable {
    let store: AccountStore
    let read: @Sendable (UUID) async throws -> Data
    let renew: @Sendable (UUID, [String: String]) async throws -> Void

    init(store: AccountStore) {
        self.store = store
        read = { id in
            if try store.hasDurableClaudeAccess(id) { return try await Self.brokeredRead(id, store: store) }
            return try store.credentialData(id)
        }
        renew = { id, environment in
            let paths = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude").path,
                         "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            guard let executable = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                throw MonitorError.helperMissing
            }
            // Deliberately detached: dismissing a view must not kill a rotating-token write.
            _ = try await Task.detached {
                try await ScopedCLI.run(executable: URL(fileURLWithPath: executable),
                    arguments: ["auth", "login", "--claudeai"], environment: environment,
                    directory: store.profile(id), timeout: 120)
            }.value
        }
    }

    init(store: AccountStore, read: @escaping @Sendable (UUID) async throws -> Data,
         renew: @escaping @Sendable (UUID, [String: String]) async throws -> Void) {
        self.store = store
        self.read = read
        self.renew = renew
    }

    func credential(_ id: UUID, rejectedToken: String? = nil) async throws -> Credential {
        let lease = try store.claudeLease(id)
        defer { withExtendedLifetime(lease) {} }
        let data = try await read(id)
        let credential = try Credential.decode(data, allowExpired: true)
        let expiresSoon = credential.expiresAt.map { $0 / 1000 <= Date().timeIntervalSince1970 + 900 } ?? false
        let rejected = rejectedToken == credential.accessToken
        if !expiresSoon && !rejected { return try Credential.decode(data) }
        struct Root: Decodable {
            struct OAuth: Decodable { let refreshToken: String? }
            let claudeAiOauth: OAuth
        }
        guard let refresh = try? JSONDecoder().decode(Root.self, from: data).claudeAiOauth.refreshToken,
              !refresh.isEmpty, let scopes = credential.scopes, !scopes.isEmpty else {
            if rejected { throw MonitorError.signInRequired }
            return try Credential.decode(data)
        }
        // Old accounts retain their direct Keychain path until explicit account-scoped consent.
        guard try store.hasDurableClaudeAccess(id) else { throw MonitorError.keychainUnavailable }
        let fingerprint = SHA256.hash(data: Data(refresh.utf8)).map { String(format: "%02x", $0) }.joined()
        let journal = store.profile(id).appendingPathComponent("renewal.json")
        guard (try? journal.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw MonitorError.invalidProfile
        }
        if FileManager.default.fileExists(atPath: journal.path) {
            guard let saved = try? Data(contentsOf: journal),
                  let previous = try? JSONDecoder().decode(String.self, from: saved), previous != fingerprint else {
                throw MonitorError.renewalUnconfirmed
            }
        }
        var environment = try store.helperEnvironment(id)
        environment["CLAUDE_CODE_OAUTH_REFRESH_TOKEN"] = refresh
        environment["CLAUDE_CODE_OAUTH_SCOPES"] = scopes.joined(separator: " ")
        // Persist before exchange. Uncertain outcomes may never replay this refresh token.
        try JSONEncoder().encode(fingerprint).write(to: journal, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journal.path)
        let receipt = try FileHandle(forWritingTo: journal)
        defer { try? receipt.close() }
        try receipt.synchronize()
        do { try await renew(id, environment) }
        catch MonitorError.helperMissing {
            // Executable lookup failed before spawning: no token exchange was possible.
            try FileManager.default.removeItem(at: journal)
            throw MonitorError.helperMissing
        }
        catch { /* A failed/terminated helper may still have persisted a rotated credential. */ }
        guard let updatedData = try? await read(id),
              let updated = try? Credential.decode(updatedData),
              let expiration = updated.expiresAt, expiration / 1000 > Date().timeIntervalSince1970 + 30,
              updated.accessToken != credential.accessToken else { throw MonitorError.renewalUnconfirmed }
        try FileManager.default.removeItem(at: journal)
        return updated
    }

    static func grantDurableAccess(_ id: UUID, store: AccountStore) async throws {
        let lease = try store.claudeLease(id)
        defer { withExtendedLifetime(lease) {} }
        _ = try Credential.decode(try await brokeredRead(id, store: store, timeout: 120), allowExpired: true)
        try store.enableDurableClaudeAccess(id)
    }

    private static func brokeredRead(_ id: UUID, store: AccountStore, timeout: TimeInterval = 5) async throws -> Data {
        // Never use an ambient service, unscoped login, shell, or user-supplied keychain name.
        let environment = try store.helperEnvironment(id)
        do {
            let data = try await ScopedCLI.run(executable: URL(fileURLWithPath: "/usr/bin/security"),
                arguments: ["find-generic-password", "-a", NSUserName(), "-s", store.keychainService(id), "-w"],
                environment: environment, directory: store.profile(id), timeout: timeout, notFoundStatus: 44)
            guard data.count <= 65_536, data.first == UInt8(ascii: "{") else { throw MonitorError.keychainUnavailable }
            return data
        } catch MonitorError.signInRequired { return try store.credentialFile(id) }
        catch { throw MonitorError.keychainUnavailable }
    }
}
