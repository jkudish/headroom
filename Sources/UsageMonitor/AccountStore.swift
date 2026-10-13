import CryptoKit
import Foundation
import LocalAuthentication
import Security

struct AccountStore: Sendable {
    let root: URL

    init(root: URL) throws {
        self.root = root.standardizedFileURL
        try privateDirectory(self.root)
    }

    static func local() throws -> Self {
        try Self(root: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/UsageMonitorPoC"))
    }

    func profile(_ id: UUID) -> URL {
        root.appendingPathComponent("accounts/\(id.uuidString)/config")
    }

    func prepare(_ id: UUID) throws {
        try validateProfile(id)
        try privateDirectory(root.appendingPathComponent("accounts"))
        let accountRoot = profile(id).deletingLastPathComponent()
        try privateDirectory(accountRoot)
        try privateDirectory(profile(id))
        try privateDirectory(accountRoot.appendingPathComponent("home"))
    }

    func load() throws -> [Account] {
        try rejectSymlink(root)
        let file = root.appendingPathComponent("accounts.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        try rejectSymlink(file)
        let accounts = try JSONDecoder().decode([Account].self, from: Data(contentsOf: file))
        guard Set(accounts.map(\.id)).count == accounts.count else { throw MonitorError.invalidProfile }
        return accounts
    }

    func save(_ accounts: [Account]) throws {
        try rejectSymlink(root)
        let file = root.appendingPathComponent("accounts.json")
        try rejectSymlink(file)
        try JSONEncoder().encode(accounts).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    // Confirmed in Claude Code 2.1.291: SHA-256 of NFC config path, first eight hex characters.
    // Never query the unscoped "Claude Code-credentials" service.
    func keychainService(_ id: UUID) -> String {
        let path = profile(id).path.precomposedStringWithCanonicalMapping
        let hash = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-\(hash.prefix(8))"
    }

    func credentials(_ id: UUID, allowInteraction: Bool = false) throws -> Credential {
        try validateProfile(id)
        var query = keychainQuery(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = !allowInteraction
        query[kSecUseAuthenticationContext as String] = context
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data { return try Credential.decode(data) }
        guard status == errSecItemNotFound else { throw MonitorError.keychainUnavailable }
        // Claude Code uses this scoped fallback when the macOS Keychain cannot accept a write.
        let file = profile(id).appendingPathComponent(".credentials.json")
        guard FileManager.default.fileExists(atPath: file.path) else { throw MonitorError.signInRequired }
        try rejectSymlink(file)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard let mode = attributes[.posixPermissions] as? NSNumber,
              mode.intValue & 0o077 == 0 else { throw MonitorError.invalidProfile }
        return try Credential.decode(Data(contentsOf: file))
    }

    func saveSecrets(_ secrets: ConnectionSecrets, for id: UUID) throws {
        try validateProfile(id)
        guard !secrets.key.isEmpty,
              !secrets.key.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              secrets.key.utf8.count <= 16384 else { throw MonitorError.signInRequired }
        let data = try JSONEncoder().encode(secrets)
        let query = secretQuery(id)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw MonitorError.keychainUnavailable }
        } else if status != errSecSuccess { throw MonitorError.keychainUnavailable }
    }

    func secrets(_ id: UUID, allowInteraction: Bool = false) throws -> ConnectionSecrets {
        try validateProfile(id)
        var query = secretQuery(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = !allowInteraction
        query[kSecUseAuthenticationContext as String] = context
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { throw MonitorError.signInRequired }
        guard status == errSecSuccess, let data = item as? Data,
              let secrets = try? JSONDecoder().decode(ConnectionSecrets.self, from: data) else {
            throw MonitorError.keychainUnavailable
        }
        return secrets
    }

    func helperEnvironment(_ id: UUID) throws -> [String: String] {
        try prepare(id)
        let home = profile(id).deletingLastPathComponent().appendingPathComponent("home").path
        return [
            // macOS security discovers the login Keychain through HOME. Config overrides
            // below isolate Claude without redirecting the operating system's Keychain.
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "USER": NSUserName(), "LOGNAME": NSUserName(),
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "CLAUDE_CONFIG_DIR": profile(id).path,
            "CLAUDE_SECURESTORAGE_CONFIG_DIR": profile(id).path,
            "ANTHROPIC_CONFIG_DIR": home + "/.config/anthropic",
            "XDG_CONFIG_HOME": home + "/.config",
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
            "BROWSER": "/usr/bin/false", "TERM": "dumb", "NO_COLOR": "1"
        ]
    }

    func deleteProfile(_ id: UUID) throws {
        try validateProfile(id)
        let status = SecItemDelete(keychainQuery(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw MonitorError.keychainUnavailable }
        let secretStatus = SecItemDelete(secretQuery(id) as CFDictionary)
        guard secretStatus == errSecSuccess || secretStatus == errSecItemNotFound else { throw MonitorError.keychainUnavailable }
        let directory = profile(id).deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    private func keychainQuery(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: keychainService(id), kSecAttrAccount as String: NSUserName()]
    }

    private func secretQuery(_ id: UUID) -> [String: Any] {
        let scope = SHA256.hash(data: Data(root.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "dev.jkudish.usage-monitor-poc.keys.\(scope)",
                kSecAttrAccount as String: id.uuidString]
    }

    private func validateProfile(_ id: UUID) throws {
        for file in [root, root.appendingPathComponent("accounts"), profile(id).deletingLastPathComponent(), profile(id)] {
            try rejectSymlink(file)
        }
    }

    private func privateDirectory(_ url: URL) throws {
        try rejectSymlink(url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func rejectSymlink(_ url: URL) throws {
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw MonitorError.invalidProfile
        }
    }
}
