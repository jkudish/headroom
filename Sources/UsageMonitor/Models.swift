import Foundation

struct Account: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var label: String
    var identity: AccountIdentity?

    init(id: UUID = UUID(), label: String, identity: AccountIdentity? = nil) {
        self.id = id
        self.label = label
        self.identity = identity
    }

    var displayName: String {
        if !label.isEmpty { return label }
        return identity?.name ?? identity?.email ?? "New Claude account"
    }
}

struct AccountIdentity: Codable, Equatable, Sendable {
    let accountID: String
    let organizationID: String
    let email: String
    var name: String? = nil

    func matches(_ other: Self) -> Bool {
        accountID == other.accountID && organizationID == other.organizationID
    }
}

struct ClaudeUsage: Decodable, Sendable {
    let fiveHour: Window?
    let sevenDay: Window?
    let extraUsage: ExtraUsage?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour", sevenDay = "seven_day", extraUsage = "extra_usage"
    }

    struct Window: Decodable, Sendable {
        let utilization: Double?
        let resetsAt: String?

        enum CodingKeys: String, CodingKey {
            case utilization, resetsAt = "resets_at"
        }

        var remaining: Double? {
            guard let utilization, utilization.isFinite, (0...100).contains(utilization) else { return nil }
            return 100 - utilization
        }

        var resetDate: Date? {
            guard let resetsAt else { return nil }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: resetsAt) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: resetsAt)
        }

        func formattedReset(timeZone: TimeZone = .current) -> String? {
            guard let date = resetDate else { return nil }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US")
            formatter.timeZone = timeZone
            formatter.dateFormat = calendar.component(.minute, from: date) == 0
                ? "EEE MMM d 'at' ha" : "EEE MMM d 'at' h:mma"
            formatter.amSymbol = "am"
            formatter.pmSymbol = "pm"
            return formatter.string(from: date)
        }
    }

    struct ExtraUsage: Decodable, Sendable {
        let isEnabled: Bool?
        let usedCredits: Double?
        let monthlyLimit: Double?
        let currency: String?

        enum CodingKeys: String, CodingKey {
            case isEnabled = "is_enabled", usedCredits = "used_credits"
            case monthlyLimit = "monthly_limit", currency
        }

        var spent: Double? { usedCredits.flatMap { $0 >= 0 && $0.isFinite ? $0 / 100 : nil } }
        var cap: Double? { monthlyLimit.flatMap { $0 >= 0 && $0.isFinite ? $0 / 100 : nil } }
    }
}

struct UsageSnapshot: Sendable {
    let identity: AccountIdentity
    let usage: ClaudeUsage
    let fetchedAt: Date
}

struct Credential: Decodable, Sendable {
    let accessToken: String
    let expiresAt: Double?
    let scopes: [String]?

    static func decode(_ data: Data, now: Date = Date()) throws -> Self {
        struct Root: Decodable { let claudeAiOauth: Credential? }
        guard let root = try? JSONDecoder().decode(Root.self, from: data),
              let credential = root.claudeAiOauth,
              !credential.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MonitorError.signInRequired
        }
        guard credential.scopes?.contains("user:profile") == true else { throw MonitorError.missingScope }
        if let expiration = credential.expiresAt, expiration / 1000 <= now.timeIntervalSince1970 + 30 {
            throw MonitorError.signInRequired
        }
        return credential
    }
}

enum MonitorError: Error, LocalizedError, Equatable {
    case signInRequired, missingScope, identityChanged, duplicateAccount
    case keychainUnavailable, invalidProfile, invalidResponse, http(Int), network
    case helperMissing, helperFailed, loginBusy, invalidCode

    var errorDescription: String? {
        switch self {
        case .signInRequired: "Sign in to this account. Its credentials are missing or expired."
        case .missingScope: "This token cannot read subscription usage. Use Claude subscription sign-in."
        case .identityChanged: "This profile now belongs to a different account or organization. Remove it and add a new account."
        case .duplicateAccount: "This Claude account and organization are already connected. Sign in with a different account."
        case .keychainUnavailable: "The scoped Keychain entry is unavailable. Unlock the login Keychain and retry."
        case .invalidProfile: "The account profile is unsafe or inaccessible. No credentials were used."
        case .invalidResponse: "Claude returned an unsupported response. Usage is unavailable."
        case .http(401): "Claude rejected this login. Sign in again."
        case .http(403): "Claude denied access to subscription usage."
        case .http(429): "Claude rate-limited usage checks. Wait before refreshing."
        case .http(let status): "Claude usage request failed (HTTP \(status))."
        case .network: "Could not reach Claude. Check your connection and retry."
        case .helperMissing: "Install Claude Code at ~/.local/bin/claude, /opt/homebrew/bin/claude, or /usr/local/bin/claude."
        case .helperFailed: "Claude Code sign-in did not finish. Retry the login."
        case .loginBusy: "Finish or cancel the current sign-in first."
        case .invalidCode: "Paste the authorization code shown by Claude, not an API key or URL."
        }
    }
}
