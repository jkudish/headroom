import Foundation
import OSLog

struct AdditionalClient: Sendable {
    var http: ProviderHTTP = ProviderHTTP()
    var ampUsage: (@Sendable (String) async throws -> String)? = nil
    private enum AmpDashboardError: Error { case redirected }

    func fetch(_ account: Account, secrets: ConnectionSecrets, ampCLIStatus: String = "not configured") async throws -> UsageSnapshot {
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
            let name = (fields["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let keyName = name.flatMap { !$0.isEmpty && $0.utf8.count <= 256 && !$0.contains(where: { $0.isNewline }) ? $0 : nil }
            return UsageSnapshot(identity: .init(accountID: team, organizationID: team, email: "", name: keyName),
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
        var usedAmpCLI = false
        var cliStatus = ampCLIStatus
        switch account.provider {
        case .amp:
            var output: String?
            if let ampUsage {
                do { output = try await ampUsage(secrets.key); cliStatus = "succeeded" }
                catch { cliStatus = ampFailure(error) }
            }
            if let text = output {
                data = try JSONSerialization.data(withJSONObject: ["ok": true, "result": ["displayText": text]])
                usedAmpCLI = true
            } else {
                data = try await request("https://ampcode.com/api/internal?userDisplayBalanceInfo", secrets: secrets,
                                         method: "POST", body: Data(#"{"method":"userDisplayBalanceInfo","params":{}}"#.utf8))
            }
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
        var reportedEmail: String?
        var plan: String?
        switch account.provider {
        case .amp:
            guard root["ok"] as? Bool == true, let result = root["result"] as? [String: Any],
                  let text = result["displayText"] as? String else { throw MonitorError.invalidResponse }
            reportedEmail = capture(#"(?m)^Signed in as ([^\s@()]+@[^\s@()]+)(?: \([^\r\n)]+\))?\s*$"#, in: text).first
            plan = capture(#"(?m)^Amp ([^\r\n:]{1,100}?) Tier:"#, in: text).first
            let amount = #"([0-9]+(?:,[0-9]{3})*(?:\.[0-9]+)?)"#
            let agent = capture(#"agent usage \$"# + amount + #" of \$"# + amount + " remaining", in: text)
                .compactMap { Double($0.replacingOccurrences(of: ",", with: "")) }
            let orbFields = capture(#"(?i)\borb\s+usage\s+"# + amount + #"h\s+of\s+"# + amount + #"h\b([^\r\n,()]{0,100})remaining\b"#, in: text)
            let orb = orbFields.prefix(2)
                .compactMap { Double($0.replacingOccurrences(of: ",", with: "")) }
            let orbUnit = orbFields.last?.range(of: #"(?i)^\s+a1\.small\s+orb\s+hours\s+$"#, options: .regularExpression) != nil
                ? "a1.small hours" : "Orb hours"
            if agent.count == 2 {
                metrics += [.init(title: "Agent", kind: .quota, value: percent(agent[0], limit: agent[1])),
                            .init(title: "Agent remaining", kind: .balance, value: agent[0], unit: "USD")]
            }
            if orb.count == 2 {
                metrics += [.init(title: "Orb", kind: .quota, value: percent(orb[0], limit: orb[1])),
                            .init(title: "Orb remaining", kind: .count, value: orb[0], unit: orbUnit),
                            .init(title: "Orb allowance", kind: .cap, value: orb[1], unit: orbUnit)]
            }
            // Legacy percentages are already remaining, not spent dollars or hours.
            let legacy = [#"(?m)^Subscription ([^\r\n:]{1,100}): "#, #"(?m)^Amp ([^\r\n:]{1,100}) Subscription: "#]
                .map { capture($0 + #"([0-9]+(?:\.[0-9]+)?)% other usage and ([0-9]+(?:\.[0-9]+)?)% orb usage remaining\b"#, in: text) }
                .first { $0.count == 3 }
            if let legacy, let other = Double(legacy[1]), let orbPercent = Double(legacy[2]),
               (0...100).contains(other), (0...100).contains(orbPercent) {
                plan = plan ?? legacy[0]
                if agent.isEmpty { metrics.append(.init(title: "Agent", kind: .quota, value: other)) }
                if orb.isEmpty { metrics.append(.init(title: "Orb", kind: .quota, value: orbPercent)) }
            }
            for line in text.split(separator: "\n") {
                let parts = capture(#"^(Individual credits|Workspace [^:\n]{1,100}): \$([0-9.]+) remaining\s*$"#, in: String(line))
                if parts.count == 2, let balance = Double(parts[1]), balance.isFinite {
                    metrics.append(.init(title: parts[0], kind: .balance, value: balance, unit: "USD"))
                }
            }
            if metrics.isEmpty {
                if usedAmpCLI {
                    return try await AdditionalClient(http: http).fetch(account, secrets: secrets, ampCLIStatus: "output not recognized")
                }
                throw MonitorError.invalidResponse
            }
            // Amp's own Account panel has separate subscription buckets. The CLI's
            // dollar allowance is not assumed to be the same meter as that panel.
            var orbStatus = "Unavailable — no Orb reading in dashboard response"
            do {
                let data = try await request("https://ampcode.com/_app/remote/rjke8/getAccountSettingsPanelData", secrets: secrets)
                let panel = try ampDashboard(data)
                reportedEmail = panel.reportedEmail ?? reportedEmail
                plan = panel.plan ?? plan
                let readings = panel.metrics.filter { $0.value != nil }
                if readings.contains(where: { $0.title == "Agent" }) {
                    metrics.removeAll { ["Agent", "Agent remaining"].contains($0.title) }
                }
                if readings.contains(where: { $0.title == "Orb" }) {
                    metrics.removeAll { ["Orb", "Orb remaining", "Orb allowance"].contains($0.title) }
                }
                metrics.insert(contentsOf: readings, at: 0)
            } catch AmpDashboardError.redirected {
                orbStatus = "Unavailable — dashboard redirected"
            } catch MonitorError.invalidResponse {
                orbStatus = "Unavailable — dashboard response not recognized"
            } catch {
                orbStatus = "Unavailable — dashboard request failed (\(ampFailure(error)))"
            }
            if !metrics.contains(where: { $0.title == "Agent" }) {
                metrics.append(.init(title: "Agent allowance", kind: .note, value: nil, detail: "No Agent reading available"))
            }
            if !metrics.contains(where: { $0.title == "Orb" }) {
                metrics.append(.init(title: "Orb usage", kind: .note, value: nil, detail: orbStatus))
                // Fixed status labels only: never log tokens, response bodies, emails or helper output.
                Logger(subsystem: "dev.jkudish.usage-monitor-poc", category: "AmpOrb")
                    .notice("CLI: \(cliStatus, privacy: .public); CLI used: \(usedAmpCLI); \(orbStatus, privacy: .public)")
            } else if usedAmpCLI {
                let validQuota = metrics.contains { $0.title == "Orb" && $0.value?.isFinite == true }
                Logger(subsystem: "dev.jkudish.usage-monitor-poc", category: "AmpOrb")
                    .notice("Orb reading available; valid quota: \(validQuota); CLI used: true")
            }
        case .grok:
            return try await grokSnapshot(data, identity: GrokClient.identity(token: secrets.key, http: http))
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
        return UsageSnapshot(identity: identity, metrics: metrics, plan: plan, reportedEmail: reportedEmail)
    }

    func grokSnapshot(_ data: Data, identity: AccountIdentity? = nil) throws -> UsageSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], root["error"] == nil,
              let config = root["config"] as? [String: Any] else { throw MonitorError.invalidResponse }
        let period = config["currentPeriod"] as? [String: Any] ?? [:]
        let remaining = number(config["creditUsagePercent"]).flatMap { (0...100).contains($0) ? 100 - $0 : nil }
        guard remaining != nil || config["prepaidBalance"] != nil else { throw MonitorError.invalidResponse }
        return UsageSnapshot(identity: identity, metrics: [
            .init(title: "Credit period", kind: .quota, value: remaining, resetsAt: date(period["end"] ?? config["billingPeriodEnd"])),
            .init(title: "Prepaid credits", kind: .balance, value: grokPrepaidUSD(config["prepaidBalance"]), unit: "USD")
        ], plan: root["subscription_tier"] as? String)
    }

    private func ampDashboard(_ data: Data) throws -> UsageSnapshot {
        // Narrow devalue reader for the public frontend's zero-argument query.
        // No JS execution or recursive hydration; only fixed field paths are read.
        guard data.count <= 1_048_576,
              let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MonitorError.invalidResponse
        }
        // The remote endpoint can return an application error inside HTTP 200.
        if envelope["type"] as? String == "error",
           let status = number((envelope["error"] as? [String: Any])?["status"] ?? envelope["status"]),
           (400...599).contains(status), status.rounded(.towardZero) == status {
            throw MonitorError.http(Int(status))
        }
        guard envelope["type"] as? String == "result", let encoded = envelope["data"] as? String,
              let bytes = encoded.data(using: .utf8),
              let nodes = try? JSONSerialization.jsonObject(with: bytes) as? [Any], !nodes.isEmpty else {
            throw MonitorError.invalidResponse
        }
        if let root = nodes[0] as? [String: Any], root["redirect"] != nil, root["q"] == nil {
            throw AmpDashboardError.redirected
        }
        func field(_ object: Any?, _ key: String) -> Any? {
            guard let reference = number((object as? [String: Any])?[key]),
                  reference >= 0, reference < Double(nodes.count), reference.rounded(.towardZero) == reference else { return nil }
            return nodes[Int(reference)]
        }
        guard let panel = field(field(field(nodes[0], "q"), "rjke8/getAccountSettingsPanelData/"), "v") as? [String: Any],
              field(panel, "user") is [String: Any] else { throw MonitorError.invalidResponse }
        let email = (field(field(panel, "user"), "email") as? String).flatMap {
            $0.range(of: #"^[^\s@]+@[^\s@]+$"#, options: .regularExpression) != nil ? $0 : nil
        }
        let subscription = field(panel, "subscription")
        let plan = (field(subscription, "planName") as? String).flatMap { $0.isEmpty ? nil : $0 }
        let taggedDate = field(subscription, "periodEndAt") as? [String]
        let periodEnd = taggedDate?.count == 2 && taggedDate?.first == "Date" ? date(taggedDate?[1]) : nil
        func boolean(_ raw: Any?) -> Bool? {
            guard let value = raw as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
            return value.boolValue
        }
        var reset: Date?
        // Match the dashboard's renewal/payer branches and its two-hour reset offset.
        if field(subscription, "status") as? String == "active", let periodEnd, periodEnd > Date(),
           let cancelled = boolean(field(subscription, "cancelAtPeriodEnd")),
           cancelled || boolean(field(subscription, "payerCompatible")) == true,
           !cancelled || (number(field(subscription, "freeRenewalsRemaining")) ?? 0) > 0 {
            reset = periodEnd.addingTimeInterval(-7200)
        }
        var metrics: [UsageMetric] = []
        if let buckets = field(panel, "subscriptionUsageBuckets") as? [String: Any] {
            for (key, title) in [("general", "Agent"), ("orb", "Orb")] {
                let remaining = number(field(field(buckets, key), "percentRemaining"))
                    .flatMap { (0...100).contains($0) ? $0 : nil }
                metrics.append(.init(title: title, kind: .quota, value: remaining, resetsAt: reset))
            }
        }
        return UsageSnapshot(metrics: metrics, plan: plan, reportedEmail: email)
    }

    private func ampFailure(_ error: Error) -> String {
        switch error {
        case MonitorError.http(let status): "HTTP \(status)"
        case MonitorError.network: "network error"
        case MonitorError.helperFailed: "CLI failed"
        case MonitorError.signInRequired: "credentials unavailable"
        case MonitorError.invalidProfile: "account files inaccessible"
        case MonitorError.unsupported: "CLI unavailable"
        default: "request failed"
        }
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

    private func grokPrepaidUSD(_ raw: Any?) -> Double? {
        guard let fields = raw as? [String: Any] else { return nil }
        // Grok's proto3 Cent omits a zero scalar; only a present empty object is zero.
        if fields.isEmpty { return 0 }
        guard let value = fields["val"] else { return nil }
        let cents: Int64?
        if let text = value as? String {
            cents = Int64(text)
        } else {
            guard let data = try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed) else { return nil }
            cents = try? JSONDecoder().decode(Int64.self, from: data)
        }
        guard let cents, cents >= 0, let amount = Double(exactly: cents) else { return nil }
        return amount / 100
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
