import Foundation

struct AdditionalClient: Sendable {
    var http: ProviderHTTP = ProviderHTTP()

    func fetch(_ account: Account, secrets: ConnectionSecrets) async throws -> UsageSnapshot {
        guard !secrets.key.isEmpty,
              !secrets.key.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw MonitorError.signInRequired
        }
        if account.provider == .xaiAPI {
            let validation = try await request("https://management-api.x.ai/auth/management-keys/validation", secrets: secrets)
            guard let fields = (try? JSONSerialization.jsonObject(with: validation)) as? [String: Any],
                  fields["scope"] as? String == "SCOPE_TEAM", let team = fields["scopeId"] as? String,
                  UUID(uuidString: team) != nil else { throw MonitorError.invalidResponse }
            let data = try await request("https://management-api.x.ai/v1/billing/teams/\(team)/prepaid/balance", secrets: secrets)
            guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let amount = (root["total"] as? [String: Any])?["val"] as? String,
                  amount.range(of: #"^-?[0-9]+$"#, options: .regularExpression) != nil,
                  let cents = Double(amount), cents.isFinite else { throw MonitorError.invalidResponse }
            // xAI's ledger counts purchases as negative and spending as positive.
            return UsageSnapshot(identity: .init(accountID: team, organizationID: team, email: ""),
                                 metrics: [.init(title: "Prepaid API balance", kind: .balance, value: -cents / 100, unit: "USD")])
        }
        if account.provider == .jina {
            // Jina's maintainer documents this root read. It does not fetch a URL.
            let data = try await request("https://r.jina.ai/", secrets: secrets, accept: "text/plain")
            let text = String(decoding: data, as: UTF8.self)
            guard let amount = capture(#"(?m)^\[Balance left\]\s*([0-9]+(?:\.[0-9]+)?)\s*$"#, in: text).first.flatMap(Double.init), amount.isFinite else {
                throw MonitorError.unsupported("Jina's experimental balance response changed. Check the Jina dashboard.")
            }
            return UsageSnapshot(metrics: [.init(title: "Tokens remaining", kind: .count, value: amount, unit: "tokens")])
        }
        let data: Data
        switch account.provider {
        case .amp:
            data = try await request("https://ampcode.com/api/internal?userDisplayBalanceInfo", secrets: secrets,
                                     method: "POST", body: Data(#"{"method":"userDisplayBalanceInfo","params":{}}"#.utf8))
        case .grok:
            guard !secrets.key.hasPrefix("xai-"), !secrets.key.contains("=") else {
                throw MonitorError.unsupported("Use a SuperGrok OAuth access token, not an xAI developer key or cookie.")
            }
            data = try await request("https://cli-chat-proxy.grok.com/v1/billing?format=credits", secrets: secrets,
                                     headers: ["x-xai-token-auth": "xai-grok-cli"])
        case .cursor:
            let cookie = secrets.key.hasPrefix("Cookie:") ? String(secrets.key.dropFirst(7)).trimmingCharacters(in: .whitespaces) : secrets.key
            guard cookie.contains("="), cookie.utf8.count <= 16384 else {
                throw MonitorError.unsupported("Paste a Cursor session Cookie header, not a Grok token.")
            }
            data = try await request("https://cursor.com/api/dashboard/get-sand-usage-status", secrets: secrets,
                                     method: "POST", body: Data("{}".utf8), headers: ["Cookie": cookie, "Origin": "https://cursor.com"])
        case .serpAPI:
            var url = URLComponents(string: "https://serpapi.com/account.json")!
            // SerpAPI requires the key in the query. Never log requests or URLs.
            url.queryItems = [URLQueryItem(name: "api_key", value: secrets.key)]
            data = try await request(url.url!.absoluteString, secrets: secrets, headers: ["Authorization": ""])
        case .tavily:
            data = try await request("https://api.tavily.com/usage", secrets: secrets)
        case .you:
            data = try await request("https://api.you.com/v1/billing/account_balance", secrets: secrets, headers: ["X-API-Key": secrets.key])
        case .parallel:
            data = try await request("https://api.parallel.ai/account/service/v1/balance", secrets: secrets)
        case .valyu:
            data = try await request("https://api.valyu.ai/v1/account/balance", secrets: secrets, headers: ["x-api-key": secrets.key])
        case .exa:
            guard let id = account.options["keyID"], !id.isEmpty,
                  id.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else {
                throw MonitorError.unsupported("Exa requires the API key ID to report and a team service key with Team Management access.")
            }
            data = try await request("https://admin-api.exa.ai/team-management/api-keys/\(id)/usage", secrets: secrets,
                                     headers: ["x-api-key": secrets.key])
        default: throw MonitorError.unsupported("An account billing API has not been established for this provider. Open its dashboard.")
        }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], root["error"] == nil else {
            throw MonitorError.invalidResponse
        }
        var metrics: [UsageMetric] = []
        var identity: AccountIdentity?
        switch account.provider {
        case .amp:
            guard root["ok"] as? Bool == true, let result = root["result"] as? [String: Any],
                  let text = result["displayText"] as? String else { throw MonitorError.invalidResponse }
            let agent = capture(#"agent usage \$([0-9.]+) of \$([0-9.]+) remaining"#, in: text).compactMap(Double.init)
            let orb = capture(#"orb usage ([0-9.]+)h of ([0-9.]+)h a1\.small orb hours remaining"#, in: text).compactMap(Double.init)
            if agent.count == 2 {
                metrics += [.init(title: "Agent", kind: .quota, value: percent(agent[0], limit: agent[1])),
                            .init(title: "Agent remaining", kind: .balance, value: agent[0], unit: "USD"),
                            .init(title: "Agent allowance", kind: .cap, value: agent[1], unit: "USD")]
            }
            if orb.count == 2 {
                metrics += [.init(title: "Orb", kind: .quota, value: percent(orb[0], limit: orb[1])),
                            .init(title: "Orb remaining", kind: .count, value: orb[0], unit: "a1.small hours"),
                            .init(title: "Orb allowance", kind: .cap, value: orb[1], unit: "a1.small hours")]
            }
            for line in text.split(separator: "\n") {
                let parts = capture(#"^(Individual credits|Workspace [^:\n]{1,100}): \$([0-9.]+) remaining\s*$"#, in: String(line))
                if parts.count == 2, let balance = Double(parts[1]), balance.isFinite {
                    metrics.append(.init(title: parts[0], kind: .balance, value: balance, unit: "USD"))
                }
            }
            if metrics.isEmpty { throw MonitorError.invalidResponse }
            if agent.isEmpty { metrics.append(.init(title: "Agent allowance", kind: .note, value: nil, detail: "Not reported by this plan")) }
            if orb.isEmpty { metrics.append(.init(title: "Orb allowance", kind: .note, value: nil, detail: "Not reported by this plan")) }
        case .grok:
            guard let config = root["config"] as? [String: Any] else { throw MonitorError.invalidResponse }
            let period = config["currentPeriod"] as? [String: Any] ?? [:]
            let used = number(config["creditUsagePercent"])
            let remaining = used.flatMap { (0...100).contains($0) ? 100 - $0 : nil }
            guard remaining != nil || config["prepaidBalance"] != nil else { throw MonitorError.invalidResponse }
            metrics = [.init(title: "Credit period", kind: .quota, value: remaining,
                             resetsAt: date(period["end"] ?? config["billingPeriodEnd"])),
                       .init(title: "Prepaid credits", kind: .balance,
                             value: number((config["prepaidBalance"] as? [String: Any])?["val"]).map { $0 / 100 }, unit: "USD")]
        case .cursor:
            guard let used = number(root["usagePercent"]), (0...100).contains(used) else { throw MonitorError.invalidResponse }
            let paid = (root["includedLimitZero"] as? Bool).map { !$0 } ?? (root["hasNonZeroIncludedLimit"] as? Bool ?? false)
            let trial = date(root["sandTrialExpiresAt"])
            guard paid || (trial.map { $0 > Date() } ?? false) else {
                return UsageSnapshot(metrics: [.init(title: "Grok Bot", kind: .note, value: nil, detail: "No active included allowance or trial")])
            }
            metrics = [.init(title: paid ? "Grok Bot" : "Grok Bot trial", kind: .quota, value: 100 - used,
                             resetsAt: paid ? date(root["nextResetTimestampUtc"]) : nil)]
        case .serpAPI:
            guard let remaining = number(root["total_searches_left"]) else { throw MonitorError.invalidResponse }
            metrics = [.init(title: "Searches remaining", kind: .count, value: remaining, unit: "searches"),
                       .init(title: "Used this month", kind: .count, value: number(root["this_month_usage"]), unit: "searches"),
                       .init(title: "Monthly allowance", kind: .cap, value: number(root["searches_per_month"]), unit: "searches")]
            if let id = root["account_id"] as? String, !id.isEmpty {
                identity = .init(accountID: id, organizationID: "", email: root["account_email"] as? String ?? "")
            }
        case .you:
            guard let data = root["data"] as? [String: Any], let fields = data["attributes"] as? [String: Any],
                  let balance = number(fields["balance"]) else { throw MonitorError.invalidResponse }
            metrics = [.init(title: "Credits remaining", kind: .balance, value: balance / 100, unit: "USD")]
            if let id = data["id"] as? String, !id.isEmpty { identity = .init(accountID: id, organizationID: "", email: "") }
        case .parallel:
            guard let invoiced = root["will_invoice"] as? Bool, let balance = number(root["credit_balance_cents"]),
                  let pending = number(root["pending_debit_balance_cents"]), let org = root["org_id"] as? String, !org.isEmpty else { throw MonitorError.invalidResponse }
            identity = .init(accountID: org, organizationID: org, email: "")
            if invoiced { metrics = [.init(title: "Billing", kind: .note, value: nil, detail: "Postpaid invoice account; prepaid balance does not apply")] }
            else {
                metrics = [.init(title: "Prepaid balance", kind: .balance, value: balance / 100, unit: "USD"),
                           .init(title: "Pending charges", kind: .spend, value: pending / 100, unit: "USD", detail: "In-flight or not yet synced; shown separately")]
            }
        case .valyu:
            guard let balance = number(root["credit_balance_usd"]) else { throw MonitorError.invalidResponse }
            metrics = [.init(title: "Credits remaining", kind: .balance, value: balance, unit: "USD"),
                       .init(title: "Pay-as-you-go used", kind: .spend, value: number(root["payg_usage_usd"]), unit: "USD")]
        case .tavily:
            guard let fields = root["account"] as? [String: Any], let used = number(fields["plan_usage"]) else { throw MonitorError.invalidResponse }
            let limit = number(fields["plan_limit"])
            let remaining = limit.flatMap { $0 >= used && used >= 0 ? $0 - used : nil }
            metrics = [.init(title: "Plan credits remaining", kind: .count, value: remaining, unit: "credits"),
                       .init(title: "Plan used", kind: .count, value: used, unit: "credits"),
                       .init(title: "Plan allowance", kind: .cap, value: limit, unit: "credits")]
            if let key = root["key"] as? [String: Any] {
                metrics.append(.init(title: "Key credits used", kind: .count, value: number(key["usage"]), unit: "credits"))
                metrics.append(.init(title: "Key cap", kind: .cap, value: number(key["limit"]), unit: "credits"))
            }
        case .exa:
            guard let spend = number(root["total_cost_usd"]), let id = root["api_key_id"] as? String,
                  id == account.options["keyID"], let team = root["team_id"] as? String else { throw MonitorError.invalidResponse }
            identity = .init(accountID: id, organizationID: team, email: "", name: root["api_key_name"] as? String)
            metrics = [.init(title: "API key spend", kind: .spend, value: spend, unit: "USD", detail: "Last 30 days; selected key only"),
                       .init(title: "Wallet balance", kind: .note, value: nil, detail: "Not returned by the Team Management usage API")]
        default: throw MonitorError.invalidResponse
        }
        return UsageSnapshot(identity: identity, metrics: metrics)
    }

    private func request(_ endpoint: String, secrets: ConnectionSecrets, method: String = "GET", body: Data? = nil,
                         headers: [String: String] = [:], accept: String = "application/json") async throws -> Data {
        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = method
        request.httpBody = body
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("UsageMonitor/0.1", forHTTPHeaderField: "User-Agent")
        if headers["Cookie"] == nil && headers["x-api-key"] == nil && headers["X-API-Key"] == nil {
            let token = secrets.key.hasPrefix("Bearer ") ? String(secrets.key.dropFirst(7)) : secrets.key
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        for (header, value) in headers { request.setValue(value.isEmpty ? nil : value, forHTTPHeaderField: header) }
        return try await http.data(for: request)
    }

    private func number(_ raw: Any?) -> Double? {
        guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }

    private func percent(_ remaining: Double, limit: Double) -> Double? {
        guard limit > 0, (0...limit).contains(remaining) else { return nil }
        return remaining / limit * 100
    }

    private func date(_ raw: Any?) -> Date? {
        guard let text = raw as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    private func capture(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return [] }
        return (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
    }
}
