import Foundation

struct Account: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var label: String
    var identity: AccountIdentity?
    var provider: Provider
    var options: [String: String]

    init(id: UUID = UUID(), label: String, identity: AccountIdentity? = nil,
         provider: Provider = .claude, options: [String: String] = [:]) {
        self.id = id
        self.label = label
        self.identity = identity
        self.provider = provider
        self.options = options
    }

    enum CodingKeys: String, CodingKey { case id, label, identity, provider, options }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        label = try values.decode(String.self, forKey: .label)
        identity = try values.decodeIfPresent(AccountIdentity.self, forKey: .identity)
        provider = try values.decodeIfPresent(Provider.self, forKey: .provider) ?? .claude
        options = try values.decodeIfPresent([String: String].self, forKey: .options) ?? [:]
    }

    var displayName: String {
        if let email = identity?.email, !email.isEmpty, email != "Email unavailable" { return email }
        if let id = identity?.accountID, !id.isEmpty { return id }
        return "New \(provider.title) account"
    }

    var showInMenuBar: Bool {
        get { options["showInMenuBar"] != "false" }
        set { options["showInMenuBar"] = newValue ? "true" : "false" }
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
    let savedResets: SavedResets?
    let cloudCredits: CloudCredits?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour", sevenDay = "seven_day", extraUsage = "extra_usage"
        case savedResets = "cedar_ember", cloudCredits = "iguana_necktie"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        fiveHour = try values.decodeIfPresent(Window.self, forKey: .fiveHour)
        sevenDay = try values.decodeIfPresent(Window.self, forKey: .sevenDay)
        extraUsage = try values.decodeIfPresent(ExtraUsage.self, forKey: .extraUsage)
        // Supplemental blocks must never invalidate ordinary quotas or spending.
        savedResets = try? values.decode(SavedResets.self, forKey: .savedResets)
        cloudCredits = try? values.decode(CloudCredits.self, forKey: .cloudCredits)
    }

    fileprivate static func parseDate(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
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
            resetsAt.flatMap(ClaudeUsage.parseDate)
        }

        func formattedReset(timeZone: TimeZone = .current) -> String? {
            resetDate?.usageResetText(timeZone: timeZone)
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

    struct SavedResets: Decodable, Sendable {
        let eligible: Bool
        let grants: [Grant]

        // No redemption handles are decoded, persisted, or exposed to a Use action.
        struct Grant: Decodable, Sendable {
            let resetsLeft: Int
            let resetsTotal: Int?
            let paused: Bool
            let startsAt: String?
            let endsAt: String?
            enum CodingKeys: String, CodingKey {
                case resetsLeft = "resets_left", resetsTotal = "resets_total", paused
                case startsAt = "starts_at", endsAt = "ends_at"
            }
        }

        func metric(at now: Date) -> UsageMetric? {
            guard eligible, grants.count <= 200 else { return nil }
            var count = 0
            var expirations: [Date] = []
            for grant in grants {
                let start = grant.startsAt.flatMap(ClaudeUsage.parseDate)
                let end = grant.endsAt.flatMap(ClaudeUsage.parseDate)
                guard grant.resetsLeft >= 0, grant.resetsTotal.map({ $0 >= grant.resetsLeft }) ?? true,
                      grant.startsAt == nil || start != nil, grant.endsAt == nil || end != nil else { return nil }
                guard !grant.paused, start.map({ $0 <= now }) ?? true, end.map({ $0 > now }) ?? true,
                      grant.resetsLeft > 0 else { continue }
                let sum = count.addingReportingOverflow(grant.resetsLeft)
                guard !sum.overflow, sum.partialValue <= 9_007_199_254_740_991 else { return nil }
                count = sum.partialValue
                if let end { expirations.append(end) }
            }
            let expiry = expirations.min().map { " Next known expiry \($0.usageResetText())." } ?? ""
            return .init(title: "Available resets", kind: .count, value: Double(count), unit: "resets",
                         detail: "Saved resets; use may require reaching a limit.\(expiry)")
        }
    }

    struct CloudCredits: Decodable, Sendable {
        let limit: Double
        let used: Double?
        let remaining: Double?
        let expiresAt: String?
        let lockedReason: String?
        enum CodingKeys: String, CodingKey {
            case limit = "limit_dollars", used = "used_dollars", remaining = "remaining_dollars"
            case expiresAt = "resets_at", lockedReason = "locked_reason"
        }

        func metric(at now: Date) -> UsageMetric? {
            guard limit.isFinite, limit > 0,
                  used.map({ $0.isFinite && (0...limit).contains($0) }) ?? true,
                  remaining.map({ $0.isFinite && (0...limit).contains($0) }) ?? true,
                  let balance = remaining ?? used.map({ limit - $0 }) else { return nil }
            let expiry = expiresAt.flatMap(ClaudeUsage.parseDate)
            guard expiresAt == nil || expiry != nil else { return nil }
            let expired = expiry.map { $0 <= now } ?? false
            let locked = lockedReason?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            let detail = expiry.map { "\(expired ? "Expired" : "Expires") \($0.usageResetText()). " } ?? ""
            // These are already dollars. Expiry is not a recurring reset or an Extra usage wallet.
            return .init(title: "Cloud credits", kind: .balance, value: expired || locked ? nil : balance,
                         unit: "USD", detail: detail + (locked ? "Unavailable. " : "") + "Promotional cloud-session credits")
        }
    }
}

extension Date {
    func usageResetText(timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.timeZone = timeZone
        formatter.dateFormat = calendar.component(.minute, from: self) == 0
            ? "EEE MMM d 'at' ha" : "EEE MMM d 'at' h:mma"
        formatter.amSymbol = "am"
        formatter.pmSymbol = "pm"
        return formatter.string(from: self)
    }
}

struct UsageSnapshot: Sendable {
    let identity: AccountIdentity?
    private let fixedMetrics: [UsageMetric]
    private let savedResets: ClaudeUsage.SavedResets?
    private let cloudCredits: ClaudeUsage.CloudCredits?
    let fetchedAt: Date
    let plan: String?
    let resetCredits: LimitResetCredits?
    let reportedEmail: String?

    var metrics: [UsageMetric] { metrics(at: Date()) }

    func metrics(at now: Date) -> [UsageMetric] {
        fixedMetrics + [savedResets?.metric(at: now), cloudCredits?.metric(at: now)].compactMap { $0 }
    }

    var availabilityChangeDates: [Date] {
        let bounds = (savedResets?.grants ?? []).flatMap { [$0.startsAt, $0.endsAt] } + [cloudCredits?.expiresAt]
        return Array(Set(bounds.compactMap { $0.flatMap(ClaudeUsage.parseDate) })).sorted()
    }

    init(identity: AccountIdentity? = nil, metrics: [UsageMetric], fetchedAt: Date = Date(),
         plan: String? = nil, resetCredits: LimitResetCredits? = nil, reportedEmail: String? = nil) {
        self.identity = identity
        fixedMetrics = metrics
        savedResets = nil
        cloudCredits = nil
        self.fetchedAt = fetchedAt
        self.plan = plan
        self.resetCredits = resetCredits
        self.reportedEmail = reportedEmail
    }

    init(identity: AccountIdentity, usage: ClaudeUsage, fetchedAt: Date, plan: String? = nil) {
        self.identity = identity
        self.fetchedAt = fetchedAt
        self.plan = plan
        resetCredits = nil
        reportedEmail = nil
        savedResets = usage.savedResets
        cloudCredits = usage.cloudCredits
        var rows = [UsageMetric(title: "5-hour", kind: .quota, value: usage.fiveHour?.remaining,
                               resetsAt: usage.fiveHour?.resetDate),
                    UsageMetric(title: "Weekly", kind: .quota, value: usage.sevenDay?.remaining,
                               resetsAt: usage.sevenDay?.resetDate)]
        if let extra = usage.extraUsage, extra.isEnabled == true {
            rows.append(.init(title: "Extra usage spent", kind: .spend, value: extra.spent,
                              unit: extra.currency ?? "USD", detail: "This month"))
            rows.append(.init(title: "Extra usage cap", kind: .cap, value: extra.cap, unit: extra.currency ?? "USD"))
        } else {
            rows.append(.init(title: "Extra usage", kind: .note, value: nil,
                              detail: usage.extraUsage?.isEnabled == false ? "Disabled" : "Unavailable"))
        }
        fixedMetrics = rows
    }
}

struct LimitResetCredits: Sendable {
    let availableCount: Int
    let expirations: [Date]
    var credits: [LimitResetCredit] = []
}

struct LimitResetCredit: Identifiable, Equatable, Sendable {
    let id: String
    let resetType: String
    let status: String
    let grantedAt: Date?
    let expiresAt: Date?
    let title: String?
    let description: String?

    var canUse: Bool {
        status == "available" && resetType == "codex_rate_limits" && (expiresAt.map { $0 > Date() } ?? true)
    }
}

struct ResetOutcome: Decodable, Sendable {
    enum Code: String, Decodable, Sendable { case reset, nothing_to_reset, no_credit, already_redeemed }
    let code: Code
    let windowsReset: Int

    enum CodingKeys: String, CodingKey { case code, windowsReset = "windows_reset" }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        code = try values.decode(Code.self, forKey: .code)
        windowsReset = try values.decodeIfPresent(Int.self, forKey: .windowsReset) ?? 0
        guard windowsReset >= 0 else { throw MonitorError.invalidResponse }
    }

    var message: String {
        switch code {
        case .reset: "Reset applied (\(windowsReset) windows reported)."
        case .nothing_to_reset: "No limits needed resetting."
        case .no_credit: "The selected reset credit is no longer available."
        case .already_redeemed: "This request or credit was already redeemed. No second reset was requested."
        }
    }
}

struct Credential: Decodable, Sendable {
    let accessToken: String
    let expiresAt: Double?
    let scopes: [String]?
    var subscriptionType: String? = nil
    var rateLimitTier: String? = nil

    var planLabel: String? {
        Self.planLabel(subscriptionType: subscriptionType, rateLimitTier: rateLimitTier)
    }

    static func planLabel(subscriptionType: String?, rateLimitTier: String?) -> String? {
        let plans = ["pro": "Pro", "max": "Max", "team": "Team", "enterprise": "Enterprise"]
        let tier = (rateLimitTier ?? "").lowercased().split(separator: "_").map(String.init)
        let plan = subscriptionType.flatMap { plans[$0.lowercased()] }
            ?? tier.compactMap { plans[$0] }.first
        guard plan == "Max", let index = tier.firstIndex(of: "max"), tier.indices.contains(index + 1),
              ["5x", "20x"].contains(tier[index + 1]) else { return plan }
        return "Max \(tier[index + 1])"
    }

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

extension Credential {
    private enum CodingKeys: String, CodingKey { case accessToken, expiresAt, scopes, subscriptionType, rateLimitTier }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try values.decode(String.self, forKey: .accessToken)
        expiresAt = try values.decodeIfPresent(Double.self, forKey: .expiresAt)
        scopes = try values.decodeIfPresent([String].self, forKey: .scopes)
        // Helper plan metadata is optional; it never grants identity or usage access.
        subscriptionType = try? values.decode(String.self, forKey: .subscriptionType)
        rateLimitTier = try? values.decode(String.self, forKey: .rateLimitTier)
    }
}

enum MonitorError: Error, LocalizedError, Equatable {
    case signInRequired, missingScope, identityChanged, duplicateAccount
    case keychainUnavailable, invalidProfile, invalidResponse, http(Int), network
    case helperMissing, helperFailed, loginBusy, invalidCode
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .signInRequired: "Sign in to this account. Its credentials are missing or expired."
        case .missingScope: "This token cannot read subscription usage. Use Claude subscription sign-in."
        case .identityChanged: "This profile now belongs to a different account or organization. Remove it and add a new account."
        case .duplicateAccount: "This account and organization are already connected. Sign in with a different account."
        case .keychainUnavailable: "The scoped Keychain entry is unavailable. Unlock the login Keychain and retry."
        case .invalidProfile: "The account profile is unsafe or inaccessible. No credentials were used."
        case .invalidResponse: "The provider returned an unsupported response. Usage is unavailable."
        case .http(401): "The provider rejected these credentials. Reconnect this account."
        case .http(403): "The provider denied access. Check the credential's billing permissions."
        case .http(429): "The provider rate-limited usage checks. Wait before refreshing."
        case .http(let status): "Usage request failed (HTTP \(status))."
        case .network: "Could not reach the provider. Check your connection and retry."
        case .helperMissing: "Install Claude Code at ~/.local/bin/claude, /opt/homebrew/bin/claude, or /usr/local/bin/claude."
        case .helperFailed: "Provider sign-in did not finish. Retry the login."
        case .loginBusy: "Finish or cancel the current sign-in first."
        case .invalidCode: "Paste the authorization code shown by Claude, not an API key or URL."
        case .unsupported(let message): message
        }
    }
}
