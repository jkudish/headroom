import Foundation
import Testing
@testable import UsageMonitor

private func devinHTTP(_ body: String, status: Int = 200,
                       check: @escaping @Sendable (URLRequest) throws -> Void = { _ in }) -> ProviderHTTP {
    ProviderHTTP { request in
        if request.url?.path == "/api/users/post-auth" {
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }
        try check(request)
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private let devinAccount = Account(label: "", provider: .devin, options: ["organization": "fixture-team"])

@Test func devinReadsDailyAndWeeklyRemainingWithResetsPlanAndBalance() async throws {
    let body = """
    {"daily_percentage": 25, "daily_reset_at": "2026-11-20T00:00:00Z", "weekly_percentage": 60.5,
     "weekly_reset_at": 1795392000000, "plan_name": "Core", "overage_balance_cents": 1250}
    """
    let snapshot = try await DevinClient(http: devinHTTP(body) { request in
        #expect(request.url?.absoluteString == "https://app.devin.ai/api/fixture-team/billing/quota/usage")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
        #expect(request.value(forHTTPHeaderField: "x-cog-org-id") == nil)
    }).fetch(devinAccount, secrets: .init(key: "Authorization: Bearer fixture-token"))
    let daily = try #require(snapshot.metrics.first { $0.title == "Daily" })
    let weekly = try #require(snapshot.metrics.first { $0.title == "Weekly" })
    #expect(daily.value == 75 && daily.kind == .quota)
    #expect(daily.resetsAt == ISO8601DateFormatter().date(from: "2026-11-20T00:00:00Z"))
    #expect(weekly.value == 39.5)
    #expect(weekly.resetsAt == Date(timeIntervalSince1970: 1_795_392_000))
    #expect(snapshot.plan == "Core")
    #expect(snapshot.identity == nil)
    let balance = try #require(snapshot.metrics.first { $0.kind == .balance })
    #expect(balance.value == 12.5 && balance.unit == "USD")
}

@Test func devinKeepsMissingOrInvalidPercentagesUnavailable() throws {
    let snapshot = try DevinClient.snapshot(Data(#"{"daily_reset_at": "2026-11-20T00:00:00Z", "weekly_percentage": 140}"#.utf8))
    #expect(snapshot.metrics.count == 2)
    #expect(snapshot.metrics.allSatisfy { $0.kind == .quota && $0.value == nil })
    #expect(!snapshot.metrics.contains { $0.kind == .balance })
    let flags = try DevinClient.snapshot(Data(#"{"weekly_percentage": true, "overage_balance": -3}"#.utf8))
    #expect(flags.metrics.map(\.value) == [nil])
}

@Test func devinHonorsHiddenDailyQuotaAndRejectsUnrecognizedResponses() throws {
    let hidden = try DevinClient.snapshot(Data(#"{"hide_daily_quota": true, "daily_percentage": 10, "weekly_percentage": 20}"#.utf8))
    #expect(hidden.metrics.map(\.title) == ["Weekly"])
    #expect(throws: MonitorError.invalidResponse) { try DevinClient.snapshot(Data(#"{"detail": "ok"}"#.utf8)) }
    #expect(throws: MonitorError.invalidResponse) { try DevinClient.snapshot(Data("[]".utf8)) }
}

@Test func devinInternalOrganizationUsesHeaderAndFallsBackOnlyAfterNotFound() async throws {
    let seen = LockedPaths()
    let account = Account(label: "", provider: .devin, options: ["organization": "https://app.devin.ai/organizations/org-fixture/settings"])
    let snapshot = try await DevinClient(http: ProviderHTTP { request in
        seen.append(request.url!.path)
        #expect(request.value(forHTTPHeaderField: "x-cog-org-id") == "org-fixture")
        let first = request.url!.path == "/api/org-fixture/billing/quota/usage"
        return (Data((first ? "{}" : #"{"weekly_percentage": 0}"#).utf8),
                HTTPURLResponse(url: request.url!, statusCode: first ? 404 : 200, httpVersion: nil, headerFields: nil)!)
    }).fetch(account, secrets: .init(key: "fixture-token"))
    #expect(seen.values == ["/api/org-fixture/billing/quota/usage", "/api/organizations/org-fixture/billing/quota/usage"])
    #expect(snapshot.metrics.first?.value == 100)
    await #expect(throws: MonitorError.unsupported("Devin organization not found. " + DevinClient.organizationHelp)) {
        try await DevinClient(http: devinHTTP("{}", status: 404)).fetch(devinAccount, secrets: .init(key: "fixture-token"))
    }
    await #expect(throws: MonitorError.unsupported(DevinClient.rejectedForSlug)) {
        try await DevinClient(http: devinHTTP("{}", status: 401)).fetch(devinAccount, secrets: .init(key: "fixture-token"))
    }
    let internalAccount = Account(label: "", provider: .devin, options: ["organization": "org-fixture"])
    await #expect(throws: MonitorError.unsupported(DevinClient.rejectedToken)) {
        try await DevinClient(http: devinHTTP("{}", status: 401)).fetch(internalAccount, secrets: .init(key: "fixture-token"))
    }
    await #expect(throws: MonitorError.unsupported(DevinClient.rejectedForSlug)) {
        try await DevinClient(http: devinHTTP(#"{"detail": "No organizations found for auth1 user"}"#, status: 403))
            .fetch(internalAccount, secrets: .init(key: "fixture-token"))
    }
}

@Test func devinRejectsUnsafeCredentialsAndOrganizations() async throws {
    let never = devinHTTP("{}") { _ in Issue.record("No request expected") }
    await #expect(throws: MonitorError.signInRequired) {
        try await DevinClient(http: never).fetch(devinAccount, secrets: .init(key: "Bearer two words"))
    }
    for organization in ["", "../admin", "https://evil.example/org/team", "http://app.devin.ai/org/team", "Silent Hacks", "app.devin.ai/settings/usage"] {
        await #expect(throws: MonitorError.unsupported(DevinClient.organizationHelp)) {
            try await DevinClient(http: never).fetch(Account(label: "", provider: .devin, options: ["organization": organization]),
                                                     secrets: .init(key: "fixture-token"))
        }
    }
    #expect(DevinOrganization("https://app.devin.ai/org/acme/settings/usage")?.paths == ["acme", "org/acme"])
    #expect(DevinOrganization("app.devin.ai/org/acme/settings?tab=usage")?.paths == ["acme", "org/acme"])
    #expect(DevinOrganization("org/acme")?.paths == ["acme", "org/acme"])
    #expect(DevinOrganization(" acme/ ")?.paths == ["acme", "org/acme"])
}

private final class LockedPaths: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    var values: [String] { lock.withLock { paths } }
    func append(_ path: String) { lock.withLock { paths.append(path) } }
}

@Test func devinCopiedCurlKeepsOnlyTokenAndOrganizationID() throws {
    let curl = """
    curl 'https://app.devin.ai/api/silent-team/billing/quota/usage' \\
      -H 'accept: application/json' \\
      -H 'authorization: Bearer eyJfixture.payload.sig' \\
      -b 'session=private-cookie' \\
      -H 'x-cog-org-id: org-fixture123'
    """
    let copied = try #require(DevinClient.copiedRequest(curl))
    #expect(copied.token == "eyJfixture.payload.sig")
    #expect(copied.organization == "org-fixture123")
    let headers = "accept: application/json\nauthorization: Bearer eyJfixture.payload.sig\n"
    #expect(DevinClient.copiedRequest(headers)?.token == "eyJfixture.payload.sig")
    #expect(DevinClient.copiedRequest(headers)?.organization == nil)
    let path = #"curl "https://app.devin.ai/api/org_abc/billing/quota/usage" -H "Authorization: Bearer tok""#
    #expect(DevinClient.copiedRequest(path)?.organization == "org_abc")
    #expect(DevinClient.copiedRequest(path)?.token == "tok")
    #expect(DevinClient.copiedRequest("curl https://app.devin.ai -H 'accept: */*'") == nil)
}

@Test func devinResolvesBlankOrMatchingOrganizationThroughPostAuthOnce() async throws {
    final class Calls: @unchecked Sendable { var postAuth = 0; var quota: [String] = [] }
    let calls = Calls()
    let http = ProviderHTTP { request in
        if request.url?.path == "/api/users/post-auth" {
            calls.postAuth += 1
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
            return (Data(#"{"org_id": "org-fixture1", "org_name": "Fixture-Team"}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        calls.quota.append("\(request.url!.path) \(request.value(forHTTPHeaderField: "x-cog-org-id") ?? "-")")
        return (Data(#"{"daily_percentage": 10, "weekly_percentage": 20}"#.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let blank = Account(label: "", provider: .devin, options: [:])
    _ = try await DevinClient(http: http).fetch(blank, secrets: .init(key: "fixture-token"))
    _ = try await DevinClient(http: http).fetch(blank, secrets: .init(key: "fixture-token"))
    let slug = Account(label: "", provider: .devin, options: ["organization": "fixture-team"])
    _ = try await DevinClient(http: http).fetch(slug, secrets: .init(key: "fixture-token"))
    let other = Account(label: "", provider: .devin, options: ["organization": "other-team"])
    _ = try await DevinClient(http: http).fetch(other, secrets: .init(key: "fixture-token"))
    #expect(calls.postAuth == 3)
    #expect(calls.quota == [
        "/api/org-fixture1/billing/quota/usage org-fixture1", "/api/org-fixture1/billing/quota/usage org-fixture1",
        "/api/org-fixture1/billing/quota/usage org-fixture1", "/api/other-team/billing/quota/usage -",
    ])
}
