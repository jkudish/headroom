import Foundation

struct AntigravityClient: Sendable {
    let store: AccountStore
    var usage: (@Sendable (UUID) async throws -> Data)? = nil

    func fetch(_ id: UUID) async throws -> UsageSnapshot {
        let identity = try AntigravityAuth.identity(AntigravityAuth.tokenData(id, store: store))
        let data: Data
        if let usage { data = try await usage(id) }
        else {
            data = try await ScopedCLI.run(executable: AntigravityAuth.executable(), arguments: AntigravityAuth.usageArguments,
                                           environment: AntigravityAuth.environment(id, store: store),
                                           directory: store.profile(id), timeout: 45)
        }
        return try Self.snapshot(data, identity: identity)
    }

    static func snapshot(_ data: Data, identity: AccountIdentity?, now: Date = Date()) throws -> UsageSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["status"] as? String == "SUCCESS",
              let command = root["command"] as? [String: Any], command["name"] as? String == "usage",
              let groups = (command["data"] as? [String: Any])?["groups"] as? [[String: Any]],
              groups.count <= 20 else { throw MonitorError.invalidResponse }
        var metrics: [UsageMetric] = []
        for group in groups {
            guard let name = text(group["name"]), let buckets = group["buckets"] as? [[String: Any]], buckets.count <= 20 else { continue }
            for bucket in buckets {
                let window: String
                switch bucket["window"] as? String {
                case "5h": window = "5-hour"
                case "weekly": window = "Weekly"
                default: continue
                }
                let fraction = (bucket["remaining_fraction"] as? NSNumber).flatMap { number -> Double? in
                    guard CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
                          (0...1).contains(number.doubleValue) else { return nil }
                    return number.doubleValue
                }
                let reset = (bucket["reset_time"] as? String).flatMap(parseDate)
                metrics.append(.init(title: "\(name) · \(window)", kind: .quota, value: fraction.map { $0 * 100 },
                                     resetsAt: reset.flatMap { $0 > now ? $0 : nil }))
            }
        }
        guard !metrics.isEmpty else { throw MonitorError.invalidResponse }
        return UsageSnapshot(identity: identity, metrics: metrics, fetchedAt: now)
    }

    private static func text(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, text.count <= 64 else { return nil }
        return text
    }

    private static func parseDate(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }
}

enum AntigravityAuth {
    // Print mode signs in when needed, then reports quotas without running a model turn.
    static let usageArguments = ["-p", "/usage", "--output-format", "json"]
    static let callback = "https://antigravity.google/oauth-callback"
    // agy offers interactive Google sign-in only with a controlling terminal, which a
    // menu bar app lacks. script(1) gives sign-in a private pseudo-terminal.
    static let terminal = URL(fileURLWithPath: "/usr/bin/script")

    static func loginArguments() throws -> [String] {
        ["-q", "/dev/null", try executable().path] + usageArguments
    }

    static func executable() throws -> URL {
        let paths = ["/opt/homebrew/bin/agy", "/usr/local/bin/agy",
                     FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/agy").path]
        guard let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw MonitorError.unsupported("Install the official Antigravity CLI (agy) with Homebrew to sign in.")
        }
        return URL(fileURLWithPath: path)
    }

    static func home(_ id: UUID, store: AccountStore) -> URL {
        store.profile(id).deletingLastPathComponent().appendingPathComponent("home")
    }

    static func environment(_ id: UUID, store: AccountStore) throws -> [String: String] {
        try store.prepare(id)
        let launchers = store.profile(id).appendingPathComponent("bin")
        try installLaunchers(launchers)
        // SSH_TTY selects agy's file token storage inside this private home, so the
        // user's own agy login and Keychain item are never read or replaced.
        return ["HOME": home(id, store: store).path, "SSH_TTY": "headroom",
                "PATH": "\(launchers.path):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
                "AGY_CLI_DISABLE_AUTO_UPDATE": "true", "BROWSER": "/usr/bin/false", "TERM": "dumb", "NO_COLOR": "1"]
    }

    // agy opens the system browser itself. Failing launchers keep sign-in inside Headroom's
    // link and stop background refreshes from opening browser windows.
    private static func installLaunchers(_ directory: URL) throws {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        if manager.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            let attributes = try? manager.attributesOfItem(atPath: directory.path)
            guard isDirectory.boolValue, attributes?[.type] as? FileAttributeType == .typeDirectory else { throw MonitorError.invalidProfile }
        } else {
            do { try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
            catch { throw MonitorError.invalidProfile }
        }
        for name in ["open", "xdg-open"] {
            let file = directory.appendingPathComponent(name)
            if let attributes = try? manager.attributesOfItem(atPath: file.path) {
                guard attributes[.type] as? FileAttributeType == .typeRegular else { throw MonitorError.invalidProfile }
                continue
            }
            guard manager.createFile(atPath: file.path, contents: Data("#!/bin/sh\nexit 1\n".utf8),
                                     attributes: [.posixPermissions: 0o700]) else { throw MonitorError.invalidProfile }
        }
    }

    static func tokenData(_ id: UUID, store: AccountStore) throws -> Data {
        var fd = open(home(id, store: store).path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw errno == ENOENT ? MonitorError.signInRequired : .invalidProfile }
        defer { close(fd) }
        for component in [".gemini", "antigravity-cli"] {
            let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw errno == ENOENT ? MonitorError.signInRequired : .invalidProfile }
            close(fd)
            fd = next
        }
        let file = openat(fd, "antigravity-oauth-token", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw errno == ENOENT ? MonitorError.signInRequired : .invalidProfile }
        defer { close(file) }
        var attributes = stat()
        guard fstat(file, &attributes) == 0, attributes.st_uid == geteuid(), attributes.st_mode & 0o022 == 0,
              attributes.st_mode & S_IFMT == S_IFREG, attributes.st_size <= 1_048_576 else { throw MonitorError.invalidProfile }
        do { return try FileHandle(fileDescriptor: file, closeOnDealloc: false).read(upToCount: 1_048_577) ?? Data() }
        catch { throw MonitorError.invalidProfile }
    }

    // Reads only identity claims. The token itself stays with agy, which owns refresh.
    static func identity(_ data: Data) throws -> AccountIdentity? {
        guard let file = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = file["token"] as? [String: Any],
              let access = token["access_token"] as? String, !access.isEmpty,
              (token["refresh_token"] as? String)?.isEmpty == false else { throw MonitorError.signInRequired }
        guard let idToken = file["id_token"] as? String, !idToken.isEmpty else { return nil }
        let parts = idToken.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw MonitorError.invalidResponse }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let decoded = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: decoded) as? [String: Any],
              let subject = claims["sub"] as? String, !subject.isEmpty, subject.count <= 256 else { throw MonitorError.invalidResponse }
        return AccountIdentity(accountID: subject, organizationID: "", email: claims["email"] as? String ?? "")
    }
}
