import Foundation

struct ZaiClient: Sendable {
    var http: ProviderHTTP = ProviderHTTP()

    func fetch(_ account: Account, secrets: ConnectionSecrets) async throws -> UsageSnapshot {
        guard account.provider == .zai else { throw MonitorError.invalidProfile }
        let host: String
        switch account.options["region"] ?? "global" {
        case "global": host = "api.z.ai"
        case "cn": host = "open.bigmodel.cn"
        default: throw MonitorError.invalidProfile
        }
        guard !secrets.key.isEmpty,
              secrets.key.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) else {
            throw MonitorError.signInRequired
        }
        var request = URLRequest(url: URL(string: "https://\(host)/api/monitor/usage/quota/limit")!)
        request.setValue("Bearer \(secrets.key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en", forHTTPHeaderField: "Accept-Language")
        let data = try await http.data(for: request)
        guard let response = try? JSONDecoder().decode(ZaiQuota.self, from: data),
              response.success, response.code == 200 else { throw MonitorError.invalidResponse }
        var metrics: [UsageMetric] = []
        for limit in response.data.limits {
            if let metric = try limit.metric() { metrics.append(metric) }
        }
        if metrics.isEmpty {
            metrics.append(.init(title: "Quota", kind: .note, value: nil, detail: "No supported quotas returned"))
        }
        // This quota endpoint does not verify an account identity or expose a wallet.
        return UsageSnapshot(metrics: metrics)
    }
}

private struct ZaiQuota: Decodable {
    struct Quotas: Decodable { let limits: [Limit] }
    let code: Int
    let success: Bool
    let data: Quotas

    struct Limit: Decodable {
        let type: String
        let unit: Int?
        let number: Int?
        let percentage: Double?
        let usage: Int?
        let currentValue: Int?
        let remaining: Int?
        let nextResetTime: Double?

        func metric() throws -> UsageMetric? {
            let title: String
            switch type {
            case "TOKENS_LIMIT": title = "Tokens"
            case "CREDIT_LIMIT": title = "Credits"
            case "TIME_LIMIT": title = "MCP"
            default: return nil
            }
            guard let unit, let number, number > 0, let percentage, (0...100).contains(percentage),
                  usage.map({ $0 >= 0 }) ?? true, currentValue.map({ $0 >= 0 }) ?? true,
                  remaining.map({ $0 >= 0 }) ?? true else { throw MonitorError.invalidResponse }
            var usedPercent = percentage
            if let usage, usage > 0 {
                let total = Double(usage)
                let fromRemaining = remaining.map { total - Double($0) }
                let fromCurrent = currentValue.map(Double.init)
                if let used = fromRemaining ?? fromCurrent {
                    // Count fields can be rounded independently. Prefer the more
                    // conservative consumed amount, as the reference connector does.
                    usedPercent = min(100, max(0, max(used, fromCurrent ?? used) / total * 100))
                }
            }
            let period: String
            var detail: String?
            if type == "TIME_LIMIT", unit == 5, number == 1 {
                // The documented/reference MCP marker means monthly, not one minute.
                // Do not turn that label into an invented reset date or 30-day window.
                period = "monthly"
            } else if let name = [1: "day", 3: "hour", 5: "minute", 6: "week"][unit] {
                period = "\(number) \(name)\(number == 1 ? "" : "s")"
            } else {
                period = "period unavailable"
                detail = "Provider period unit \(unit), number \(number)"
            }
            let reset = nextResetTime.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0 / 1000) : nil }
            return .init(title: "\(title) (\(period))", kind: .quota, value: 100 - usedPercent,
                         resetsAt: reset, detail: detail)
        }
    }
}
