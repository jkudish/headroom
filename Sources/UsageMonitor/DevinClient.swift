import Foundation

struct DevinClient: Sendable {
    var http = ProviderHTTP()

    func fetch(_ account: Account, secrets: ConnectionSecrets, now: Date = Date()) async throws -> UsageSnapshot {
        guard account.provider == .devin else { throw MonitorError.invalidProfile }
        guard let token = Self.bearerToken(secrets.key) else { throw MonitorError.signInRequired }
        let entered = account.options["organization"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let organization: DevinOrganization
        if let parsed = DevinOrganization(entered), parsed.internalID != nil {
            organization = parsed
        } else if entered.isEmpty {
            guard let resolved = await resolveOrganization(account, token: token, slug: nil) else { throw MonitorError.unsupported(Self.organizationHelp) }
            organization = resolved
        } else {
            guard let parsed = DevinOrganization(entered) else { throw MonitorError.unsupported(Self.organizationHelp) }
            organization = await resolveOrganization(account, token: token, slug: parsed.paths[0]) ?? parsed
        }
        var lastError = MonitorError.invalidResponse
        for path in organization.paths {
            var request = URLRequest(url: URL(string: "https://app.devin.ai/api/\(path)/billing/quota/usage")!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("en-US,en", forHTTPHeaderField: "Accept-Language")
            if let internalID = organization.internalID { request.setValue(internalID, forHTTPHeaderField: "x-cog-org-id") }
            let data: Data, response: HTTPURLResponse
            do { (data, response) = try await http.send(request) }
            catch let error as MonitorError { throw error }
            catch { throw MonitorError.network }
            if response.statusCode == 404 { lastError = .http(404); continue }
            if response.statusCode == 401 || response.statusCode == 403 {
                await Self.resolvedOrganizations.clear(account.id)
                // Some Devin sessions are accepted only with the internal organization ID header.
                let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
                throw MonitorError.unsupported(organization.internalID == nil || detail == "No organizations found for auth1 user"
                    ? Self.rejectedForSlug : Self.rejectedToken)
            }
            guard (200...299).contains(response.statusCode) else { throw MonitorError.http(response.statusCode) }
            return try Self.snapshot(data, now: now)
        }
        throw lastError == .http(404) ? MonitorError.unsupported("Devin organization not found. " + Self.organizationHelp) : lastError
    }

    static let resolvedOrganizations = DevinOrganizationCache()

    // Devin's own sign-in hook reports the token's organization. Usage requests are accepted
    // only with that internal ID, so a slug or blank field is resolved through it once.
    private func resolveOrganization(_ account: Account, token: String, slug: String?) async -> DevinOrganization? {
        let key = slug?.lowercased() ?? ""
        if let cached = await Self.resolvedOrganizations.get(account.id, key) { return DevinOrganization(cached) }
        var request = URLRequest(url: URL(string: "https://app.devin.ai/api/users/post-auth")!)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let data = try? await http.data(for: request),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["org_id"] as? String, let organization = DevinOrganization(id), organization.internalID != nil
        else { return nil }
        if let slug, (object["org_name"] as? String)?.lowercased() != slug.lowercased() { return nil }
        await Self.resolvedOrganizations.set(account.id, key, id)
        return organization
    }

    static let rejectedForSlug = "Devin rejected this token for that organization name. Reconnect and paste the request copied as cURL; Headroom reads the org-… ID from it."
    static let rejectedToken = "Devin rejected this token. Reconnect and paste a freshly copied app.devin.ai request (Copy as cURL)."
    static let organizationHelp = "Devin couldn't find this token's organization. Paste an app.devin.ai request copied as cURL, or enter the org-… ID from its x-cog-org-id header."

    // Extracts only the bearer token and organization ID from a copied cURL command or
    // request headers. Cookies and other headers in the paste are discarded.
    static func copiedRequest(_ raw: String) -> (token: String, organization: String?)? {
        let text = raw.replacingOccurrences(of: "\\\n", with: " ")
        func capture(_ pattern: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
        guard let token = capture(#"authorization:\s*bearer\s+([!#-&(-~]+?)(?=['"\s\\]|$)"#).flatMap(bearerToken) else { return nil }
        let organization = capture(#"x-cog-org-id:\s*(org[-_][A-Za-z0-9_-]+)"#)
            ?? capture(#"app\.devin\.ai/api/(org[-_][A-Za-z0-9_-]+)/"#)
        return (token, organization)
    }

    // Accepts a bare token, "Bearer <token>", or a copied "Authorization: Bearer <token>" header line.
    static func bearerToken(_ raw: String) -> String? {
        var token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.lowercased().hasPrefix("authorization:") { token = String(token.dropFirst(14)).trimmingCharacters(in: .whitespaces) }
        if token.lowercased().hasPrefix("bearer ") { token = String(token.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
        guard !token.isEmpty, token.utf8.count <= 16384,
              token.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) else { return nil }
        return token
    }

    static func snapshot(_ data: Data, now: Date = Date()) throws -> UsageSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MonitorError.invalidResponse }
        let hideDaily = (root["hide_daily_quota"] as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue } ?? false
        let hasDaily = !hideDaily && (root["daily_percentage"] != nil || root["daily_reset_at"] != nil)
        let hasWeekly = root["weekly_percentage"] != nil || root["weekly_reset_at"] != nil
        guard hasDaily || hasWeekly else { throw MonitorError.invalidResponse }
        var metrics: [UsageMetric] = []
        if hasDaily { metrics.append(quota("Daily", used: root["daily_percentage"], reset: root["daily_reset_at"])) }
        if hasWeekly { metrics.append(quota("Weekly", used: root["weekly_percentage"], reset: root["weekly_reset_at"])) }
        if let balance = dollars(root["overage_balance"]) ?? dollars(root["overage_balance_cents"]).map({ $0 / 100 }) {
            metrics.append(.init(title: "Extra usage balance", kind: .balance, value: balance, unit: "USD"))
        }
        let plan = ["plan_name", "plan", "tier"].lazy.compactMap { key -> String? in
            guard let text = (root[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty, text.count <= 64 else { return nil }
            return text
        }.first
        // The quota endpoint does not return a verifiable account identity.
        return UsageSnapshot(metrics: metrics, fetchedAt: now, plan: plan)
    }

    // Devin reports used percentages. Out-of-range or missing values stay unavailable.
    private static func quota(_ title: String, used: Any?, reset: Any?) -> UsageMetric {
        let remaining = number(used).flatMap { (0...100).contains($0) ? 100 - $0 : nil }
        return .init(title: title, kind: .quota, value: remaining, resetsAt: date(reset))
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }

    private static func dollars(_ value: Any?) -> Double? {
        number(value).flatMap { $0 >= 0 ? $0 : nil }
    }

    private static func date(_ value: Any?) -> Date? {
        if let text = value as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: text)
        }
        guard let seconds = number(value), seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1000 : seconds)
    }
}

actor DevinOrganizationCache {
    private var ids: [UUID: (key: String, id: String)] = [:]
    func get(_ account: UUID, _ key: String) -> String? { ids[account]?.key == key ? ids[account]?.id : nil }
    func set(_ account: UUID, _ key: String, _ id: String) { ids[account] = (key, id) }
    func clear(_ account: UUID) { ids[account] = nil }
}

struct DevinOrganization: Equatable {
    let paths: [String]
    let internalID: String?

    // Accepts an org slug, an internal org-… / org_… ID, or an app.devin.ai organization URL.
    init?(_ raw: String?) {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if let scheme = text.range(of: "://") {
            guard text[..<scheme.lowerBound].lowercased() == "https" else { return nil }
            text = String(text[scheme.upperBound...])
        }
        text = String(text.prefix { $0 != "?" && $0 != "#" })
        var parts = text.split(separator: "/").map(String.init)
        if let host = parts.first?.lowercased(), host.contains(".") {
            guard host == "devin.ai" || host.hasSuffix(".devin.ai") else { return nil }
            parts.removeFirst()
        }
        let value: String
        if parts.count >= 2, ["org", "organizations"].contains(parts[0].lowercased()) { value = parts[1] }
        else if parts.count == 1 { value = parts[0] }
        else { return nil }
        guard value.count <= 128, value.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else { return nil }
        if value.hasPrefix("org-") || value.hasPrefix("org_") {
            paths = [value, "organizations/\(value)"]
            internalID = value
        } else {
            paths = [value, "org/\(value)"]
            internalID = nil
        }
    }
}
