import Foundation

struct ClaudeClient: Sendable {
    let credentials: @Sendable (UUID) async throws -> Credential
    let renew: (@Sendable (UUID, String) async throws -> Credential)?
    let send: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    init(store: AccountStore) {
        let auth = ClaudeAuth(store: store)
        credentials = { try await auth.credential($0) }
        renew = { try await auth.credential($0, rejectedToken: $1) }
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        let session = URLSession(configuration: config, delegate: RejectRedirects(), delegateQueue: nil)
        send = { request in
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw MonitorError.invalidResponse }
            return (data, http)
        }
    }

    init(credentials: @escaping @Sendable (UUID) async throws -> Credential,
         renew: (@Sendable (UUID, String) async throws -> Credential)? = nil,
         send: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)) {
        self.credentials = credentials
        self.renew = renew
        self.send = send
    }

    func fetch(_ id: UUID) async throws -> UsageSnapshot {
        let credential = try await credentials(id)
        do { return try await fetch(credential) }
        catch MonitorError.http(401) {
            guard let renew else { throw MonitorError.http(401) }
            // At most one renewal/retry; 403 and 429 never spend a refresh token.
            return try await fetch(renew(id, credential.accessToken))
        }
    }

    private func fetch(_ credential: Credential) async throws -> UsageSnapshot {
        let token = credential.accessToken
        let profile = try await request("profile", token: token)
        struct Profile: Decodable {
            struct User: Decodable {
                let uuid: String
                let email: String?
                let name: String?
                enum CodingKeys: String, CodingKey {
                    case uuid, email, emailAddress, emailAddressSnake = "email_address"
                    case displayName = "display_name"
                }
                init(from decoder: Decoder) throws {
                    let values = try decoder.container(keyedBy: CodingKeys.self)
                    uuid = try values.decode(String.self, forKey: .uuid)
                    email = try values.decodeIfPresent(String.self, forKey: .emailAddressSnake)
                        ?? values.decodeIfPresent(String.self, forKey: .emailAddress)
                        ?? values.decodeIfPresent(String.self, forKey: .email)
                    let displayName = try values.decodeIfPresent(String.self, forKey: .displayName)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    name = displayName?.isEmpty == false ? displayName : nil
                }
            }
            struct Organization: Decodable {
                let uuid: String
                let rateLimitTier: String?
                let organizationType: String?
                enum CodingKeys: String, CodingKey {
                    case uuid, rateLimitTier = "rate_limit_tier", organizationType = "organization_type"
                }
                init(from decoder: Decoder) throws {
                    let values = try decoder.container(keyedBy: CodingKeys.self)
                    uuid = try values.decode(String.self, forKey: .uuid)
                    rateLimitTier = try? values.decode(String.self, forKey: .rateLimitTier)
                    organizationType = try? values.decode(String.self, forKey: .organizationType)
                }
                var planLabel: String? {
                    let family = organizationType.flatMap { $0.hasPrefix("claude_") ? String($0.dropFirst(7)) : nil }
                    // Fresh tier wins. A fresh family without a multiplier must not reuse a cached one.
                    return Credential.planLabel(subscriptionType: nil, rateLimitTier: rateLimitTier)
                        ?? Credential.planLabel(subscriptionType: family, rateLimitTier: nil)
                }
            }
            let account: User
            let organization: Organization
        }
        guard let decoded = try? JSONDecoder().decode(Profile.self, from: profile),
              !decoded.account.uuid.isEmpty, !decoded.organization.uuid.isEmpty else { throw MonitorError.invalidResponse }
        let usageData: Data
        do {
            usageData = try await request("usage?cedar_ember=1", token: token)
        } catch MonitorError.http(let status) where status == 400 || status == 403 {
            // Older deployments may reject the optional inventory query. Preserve ordinary usage.
            usageData = try await request("usage", token: token)
        }
        guard let usage = try? JSONDecoder().decode(ClaudeUsage.self, from: usageData) else { throw MonitorError.invalidResponse }
        return UsageSnapshot(
            identity: AccountIdentity(accountID: decoded.account.uuid, organizationID: decoded.organization.uuid,
                                      email: decoded.account.email ?? "Email unavailable", name: decoded.account.name),
            usage: usage, fetchedAt: Date(), plan: decoded.organization.planLabel ?? credential.planLabel
        )
    }

    private func request(_ endpoint: String, token: String) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/\(endpoint)")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("claude-cli/2.1.291 (external, cli)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await send(request)
            guard response.statusCode == 200 else { throw MonitorError.http(response.statusCode) }
            return data
        } catch let error as MonitorError { throw error }
        catch { throw MonitorError.network }
    }
}

private final class RejectRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
