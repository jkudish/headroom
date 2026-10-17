import Foundation

struct GrokBotClient: Sendable {
    var http = ProviderHTTP()

    func fetch(_ account: Account, secrets: ConnectionSecrets) async throws -> UsageSnapshot {
        let cookie = secrets.key.hasPrefix("Cookie:") ? String(secrets.key.dropFirst(7)).trimmingCharacters(in: .whitespaces) : secrets.key
        guard cookie.contains("="), cookie.utf8.count <= 16384,
              !cookie.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw MonitorError.signInRequired }
        var request = URLRequest(url: URL(string: "https://cursor.com/api/auth/me")!)
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        let data = try await http.data(for: request)
        guard let user = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = user["sub"] as? String, !id.isEmpty else { throw MonitorError.invalidResponse }
        let identity = AccountIdentity(accountID: id, organizationID: "", email: user["email"] as? String ?? "")
        if let owner = account.identity, !identity.matches(owner) { throw MonitorError.identityChanged }
        let usage = try await AdditionalClient(http: http).fetch(account, secrets: secrets)
        return UsageSnapshot(identity: identity, metrics: usage.metrics, fetchedAt: usage.fetchedAt, plan: usage.plan)
    }
}
