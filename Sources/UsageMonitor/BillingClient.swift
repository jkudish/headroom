import Foundation

struct BillingClient: Sendable {
    let http: ProviderHTTP

    init(http: ProviderHTTP = ProviderHTTP()) {
        self.http = http
    }

    func fetch(_ account: Account, secrets: ConnectionSecrets) async throws -> UsageSnapshot {
        guard !secrets.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !secrets.key.contains(where: { $0.isNewline }) else { throw MonitorError.signInRequired }
        let now = Date()
        switch account.provider {
        case .openRouter:
            let mode = account.options["mode"] ?? "wallet"
            guard mode == "wallet" || mode == "key" else { throw MonitorError.invalidProfile }
            let root = try await get("https://openrouter.ai/api/v1/\(mode == "key" ? "key" : "credits")", secrets: secrets)
            guard let data = root["data"] as? [String: Any] else { throw MonitorError.invalidResponse }
            if mode == "key" {
                let identity = (data["creator_user_id"] as? String).flatMap { id in
                    id.isEmpty ? nil : AccountIdentity(accountID: id, organizationID: data["organization_id"] as? String ?? "", email: "")
                }
                return UsageSnapshot(identity: identity, metrics: [
                    .init(title: "Monthly key spend", kind: .spend, value: number(data["usage_monthly"]), unit: "USD", detail: "Current UTC month; this key only"),
                    .init(title: "Key credits used", kind: .spend, value: number(data["usage"]), unit: "USD", detail: "All time; this key only"),
                    .init(title: "Key cap", kind: .cap, value: number(data["limit"]), unit: "USD", detail: data["limit_reset"] as? String),
                    .init(title: "Key remaining cap", kind: .cap, value: number(data["limit_remaining"]), unit: "USD", detail: "Not an account wallet balance"),
                    walletUnavailable
                ], fetchedAt: now)
            }
            let purchased = number(data["total_credits"]), used = number(data["total_usage"])
            return UsageSnapshot(metrics: [
                .init(title: "Wallet balance", kind: .balance, value: difference(purchased, used), unit: "USD"),
                .init(title: "Credits used", kind: .spend, value: used, unit: "USD", detail: "All time")
            ], fetchedAt: now)
        case .searchAPI:
            let root = try await get("https://www.searchapi.io/api/v1/me", secrets: secrets)
            guard let data = root["account"] as? [String: Any] else { throw MonitorError.invalidResponse }
            let remaining = number(data["remaining_credits"]), allowance = number(data["monthly_allowance"])
            var quota: Double?
            if let remaining, let allowance, allowance > 0, (0...allowance).contains(remaining) {
                quota = remaining / allowance * 100
            }
            let reset = date((root["subscription"] as? [String: Any])?["period_end"])
            return UsageSnapshot(metrics: [
                .init(title: "Search quota", kind: .quota, value: quota, resetsAt: reset),
                .init(title: "Searches remaining", kind: .count, value: remaining, unit: "searches", resetsAt: reset),
                .init(title: "Searches used", kind: .count, value: number(data["current_month_usage"]), unit: "searches"),
                .init(title: "Monthly allowance", kind: .cap, value: allowance, unit: "searches")
            ], fetchedAt: now)
        case .dataForSEO:
            guard let username = secrets.username, !username.isEmpty,
                  !username.contains(":"), !username.contains(where: { $0.isNewline }) else { throw MonitorError.signInRequired }
            let auth = "Basic " + Data("\(username):\(secrets.key)".utf8).base64EncodedString()
            let root = try await get("https://api.dataforseo.com/v3/appendix/user_data", secrets: secrets, headers: ["Authorization": auth])
            guard number(root["status_code"]) == 20000,
                  let tasks = root["tasks"] as? [[String: Any]], tasks.count == 1,
                  number(tasks[0]["status_code"]) == 20000,
                  let results = tasks[0]["result"] as? [[String: Any]], results.count == 1 else { throw MonitorError.invalidResponse }
            let money = results[0]["money"] as? [String: Any] ?? [:]
            let balance = number(money["balance"])
            return UsageSnapshot(metrics: [
                .init(title: "Wallet balance", kind: .balance, value: balance, unit: "USD"),
                .init(title: "Credits used", kind: .spend, value: difference(number(money["total"]), balance), unit: "USD",
                      detail: "All-time deposits minus balance; not month-to-date spend")
            ], fetchedAt: now)
        case .firecrawl:
            let root = try await get("https://api.firecrawl.dev/v2/team/credit-usage", secrets: secrets)
            guard root["success"] as? Bool != false, let data = root["data"] as? [String: Any] else { throw MonitorError.invalidResponse }
            return UsageSnapshot(metrics: [
                .init(title: "Credits remaining", kind: .count, value: number(data["remainingCredits"]), unit: "credits",
                      resetsAt: date(data["billingPeriodEnd"]), detail: "May include coupon and purchased credits"),
                .init(title: "Plan credits", kind: .cap, value: number(data["planCredits"]), unit: "credits", detail: "Excludes coupon and purchased credits")
            ], fetchedAt: now)
        case .openAIAPI, .anthropicAPI:
            return try await costs(account, secrets: secrets, now: now)
        default:
            throw MonitorError.unsupported("This provider has no supported billing connector.")
        }
    }

    private var walletUnavailable: UsageMetric {
        .init(title: "Wallet balance", kind: .note, value: nil, unit: "USD",
              detail: "Not available through this API.")
    }

    private func costs(_ account: Account, secrets: ConnectionSecrets, now: Date) async throws -> UsageSnapshot {
        let anthropic = account.provider == .anthropicAPI
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.dateInterval(of: .month, for: now)!.start
        let formatter = ISO8601DateFormatter()
        let endpoint = anthropic ? "https://api.anthropic.com/v1/organizations/cost_report" : "https://api.openai.com/v1/organization/costs"
        let bounds = anthropic
            ? [URLQueryItem(name: "starting_at", value: formatter.string(from: start)), URLQueryItem(name: "ending_at", value: formatter.string(from: now))]
            : [URLQueryItem(name: "start_time", value: String(Int(start.timeIntervalSince1970))), URLQueryItem(name: "end_time", value: String(Int(now.timeIntervalSince1970)))]
        var headers = anthropic ? ["x-api-key": secrets.key, "anthropic-version": "2023-06-01"] : [:]
        if !anthropic, let organization = account.options["organizationID"], !organization.isEmpty {
            guard !organization.contains(where: { $0.isNewline }) else { throw MonitorError.invalidProfile }
            headers["OpenAI-Organization"] = organization
        }
        var page: String?
        var seen = Set<String>()
        var total = Decimal.zero
        var currency: String?
        var available = true
        repeat {
            try Task.checkCancellation()
            var query = bounds + [URLQueryItem(name: "limit", value: "31")]
            if let page { query.append(URLQueryItem(name: "page", value: page)) }
            let root = try await get(endpoint, secrets: secrets, headers: headers, query: query)
            guard let buckets = root["data"] as? [[String: Any]], let hasMore = root["has_more"] as? Bool else { throw MonitorError.invalidResponse }
            for bucket in buckets {
                guard let results = bucket["results"] as? [[String: Any]] else { throw MonitorError.invalidResponse }
                for result in results {
                    let amount = anthropic ? result : result["amount"] as? [String: Any] ?? [:]
                    let raw = anthropic ? amount["amount"] as? String : number(amount["value"]).map { String($0) }
                    guard let raw, raw.range(of: #"^-?[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?\z"#, options: .regularExpression) != nil,
                          var value = Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")),
                          let code = amount["currency"] as? String, !code.isEmpty,
                          NSDecimalNumber(decimal: value).doubleValue.isFinite else { available = false; continue }
                    if anthropic {
                        // Anthropic decimal strings are cents; OpenAI values are already currency units.
                        guard code.uppercased() == "USD" else { available = false; continue }
                        value /= 100
                    }
                    if let currency, currency != code.uppercased() { available = false }
                    currency = code.uppercased()
                    total += value
                }
            }
            if let cursor = root["next_page"], !(cursor is NSNull), !(cursor is String) {
                throw MonitorError.invalidResponse
            }
            page = root["next_page"] as? String
            if hasMore || page != nil {
                guard let page, !page.isEmpty, seen.insert(page).inserted, seen.count <= 1000 else { throw MonitorError.invalidResponse }
            }
        } while page != nil
        let value = NSDecimalNumber(decimal: total).doubleValue
        let month = DateFormatter()
        month.locale = .current
        month.timeZone = TimeZone(secondsFromGMT: 0)
        month.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        return UsageSnapshot(metrics: [
            .init(title: "Month-to-date spend", kind: .spend, value: available && value.isFinite ? value : nil,
                  unit: currency ?? "USD", detail: "\(month.string(from: now)) · UTC · Reporting may lag"),
            walletUnavailable
        ], fetchedAt: now)
    }

    private func get(_ endpoint: String, secrets: ConnectionSecrets, headers: [String: String] = [:],
                     query: [URLQueryItem] = []) async throws -> [String: Any] {
        var components = URLComponents(string: endpoint)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(secrets.key)", forHTTPHeaderField: "Authorization")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if headers["x-api-key"] != nil { request.setValue(nil, forHTTPHeaderField: "Authorization") }
        let data = try await http.data(for: request)
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw MonitorError.invalidResponse }
        guard root["error"] == nil else { throw MonitorError.invalidResponse }
        return root
    }

    private func number(_ raw: Any?) -> Double? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        return value.isFinite ? value : nil
    }

    private func difference(_ first: Double?, _ second: Double?) -> Double? {
        guard let first, let second, (first - second).isFinite else { return nil }
        return first - second
    }

    private func date(_ raw: Any?) -> Date? {
        guard let string = raw as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}
