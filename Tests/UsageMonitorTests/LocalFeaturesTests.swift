import Foundation
import Testing
@testable import UsageMonitor

@Test func resetExpiryRemindersUseUnusedCreditsAndDoNotReplayOldThresholds() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let expiry = now.addingTimeInterval(2 * 3600)
    let account = Account(label: "", provider: .codex, options: ["resetAlerts": "true"])
    let credits = LimitResetCredits(availableCount: 1, expirations: [expiry], credits: [
        .init(id: "private-credit-handle", resetType: "codex_rate_limits", status: "available", grantedAt: nil,
              expiresAt: expiry, title: nil, description: nil),
        .init(id: "already-used", resetType: "codex_rate_limits", status: "redeemed", grantedAt: nil,
              expiresAt: now.addingTimeInterval(1800), title: nil, description: nil)
    ])
    let snapshot = UsageSnapshot(metrics: [], fetchedAt: now, resetCredits: credits)
    let entry = AccountEntry(account: account, snapshot: snapshot)
    let reminders = ResetReminders.plan(entry, now: now)
    #expect(reminders.map(\.hoursBefore) == [3, 1])
    #expect(reminders.map(\.date) == [now.addingTimeInterval(1), expiry.addingTimeInterval(-3600)])
    #expect(reminders.allSatisfy { !$0.id.contains("private-credit-handle") })
    #expect(ResetReminders.expiringCount(entry, now: now) == 1)
    #expect(ResetReminders.plan(entry, now: expiry).isEmpty)
    let stale = AccountEntry(account: account, snapshot: UsageSnapshot(metrics: [], fetchedAt: now.addingTimeInterval(-1800), resetCredits: credits))
    #expect(ResetReminders.plan(stale, now: now).isEmpty)
    let pending = reminders.map(\.id)
    #expect(ResetReminders.cancellations(pending, entries: [entry], now: now).isEmpty)
    #expect(ResetReminders.cancellations(pending, entries: [stale], now: now).isEmpty)
    #expect(ResetReminders.cancellations(pending, entries: [AccountEntry(account: account)], now: now).isEmpty)
    let spent = AccountEntry(account: account, snapshot: UsageSnapshot(metrics: [], fetchedAt: now))
    #expect(ResetReminders.cancellations(pending, entries: [spent], now: now) == pending)
    var disabled = account
    disabled.options["resetAlerts"] = nil
    #expect(ResetReminders.cancellations(pending, entries: [AccountEntry(account: disabled)], now: now) == pending)
    #expect(ResetReminders.cancellations(pending + ["unrelated"], entries: [], now: now) == pending)
}

@Test func claudeReminderCountsOnlyActiveUnpausedGrants() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let formatter = ISO8601DateFormatter()
    let expiry = formatter.string(from: now.addingTimeInterval(11 * 3600))
    let future = formatter.string(from: now.addingTimeInterval(60))
    let usage = try JSONDecoder().decode(ClaudeUsage.self, from: Data("""
    {"cedar_ember":{"eligible":true,"grants":[
    {"resets_left":2,"paused":false,"ends_at":"\(expiry)"},
    {"resets_left":9,"paused":true,"ends_at":"\(expiry)"},
    {"resets_left":5,"paused":false,"starts_at":"\(future)","ends_at":"\(expiry)"}]}}
    """.utf8))
    let snapshot = UsageSnapshot(identity: .init(accountID: "a", organizationID: "o", email: "a@example.test"),
                                 usage: usage, fetchedAt: now)
    let entry = AccountEntry(account: .init(label: ""), snapshot: snapshot)
    #expect(ResetReminders.expiringCount(entry, now: now) == 2)
    #expect(ResetReminders.plan(entry, now: now).map(\.hoursBefore) == [12, 3, 1])
}

@Test func localMCPExportsOnlyReadingsAndPreservesUnknownAndStale() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let account = Account(label: "", identity: .init(accountID: "private-provider-id", organizationID: "private-org", email: "fixture@example.test"),
                          provider: .codex, options: ["key": "must-not-export", "resetAttempt:private-handle": "private-request"])
    let entry = AccountEntry(account: account, snapshot: UsageSnapshot(metrics: [
        .init(title: "5-hour", kind: .quota, value: nil), .init(title: "Weekly", kind: .quota, value: 0)
    ], fetchedAt: now.addingTimeInterval(-901)))
    let exported = LocalMCP.export([entry], now: now)
    let json = String(decoding: try JSONSerialization.data(withJSONObject: exported), as: UTF8.self)
    #expect(!json.contains("must-not-export"))
    #expect(!json.contains("private-"))
    let result = try #require(LocalMCP.response(["jsonrpc": "2.0", "id": 2, "method": "tools/call",
        "params": ["name": "get_usage", "arguments": ["account_id": account.id.uuidString]]], snapshot: exported, now: now)?["result"] as? [String: Any])
    let body = try #require(result["structuredContent"] as? [String: Any])
    let rows = try #require(body["accounts"] as? [[String: Any]])
    #expect(rows.count == 1)
    #expect(rows[0]["stale"] as? Bool == true)
    let metrics = try #require(rows[0]["metrics"] as? [[String: Any]])
    #expect(metrics[0]["value"] is NSNull)
    #expect(metrics[1]["value"] as? Double == 0)
    #expect(LocalMCP.response(["jsonrpc": "2.0", "method": "notifications/initialized"], snapshot: exported, now: now) == nil)
    let denied = LocalMCP.response(["jsonrpc": "2.0", "id": 3, "method": "tools/call",
        "params": ["name": "refresh", "arguments": [:]]], snapshot: exported, now: now)
    #expect((denied?["error"] as? [String: Any])?["code"] as? Int == -32602)
}

@Test func scopedCLIUsesOnlyTheSuppliedEnvironment() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let result = try await ScopedCLI.run(executable: URL(fileURLWithPath: "/usr/bin/env"), arguments: [],
        environment: ["AMP_API_KEY": "fixture-selected", "HOME": root.path], directory: root)
    let text = String(decoding: result, as: UTF8.self)
    #expect(Set(text.split(separator: "\n").map(String.init)) == ["AMP_API_KEY=fixture-selected", "HOME=\(root.path)"])
    await #expect(throws: MonitorError.helperFailed) {
        try await ScopedCLI.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"],
                                environment: [:], directory: root, timeout: 0.05)
    }
}

@Test func grokHelperBindsServerIdentityAndReadsOnlyItsOwnProfile() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = try AccountStore(root: root)
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID(), other = UUID()
    try store.prepare(id)
    let auth = Data(#"{"https://auth.x.ai::fixture-client":{"key":"fixture-grok-token","user_id":"cached-not-authoritative","oidc_issuer":"https://auth.x.ai"}}"#.utf8)
    let file = store.profile(id).appendingPathComponent("auth.json")
    try auth.write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    let config = store.profile(id).appendingPathComponent("config.toml")
    try Data("# Official helper creates a readable config\n".utf8).write(to: config)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: config.path)
    let http = ProviderHTTP { request in
        #expect(request.url?.absoluteString == "https://cli-chat-proxy.grok.com/v1/user")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-grok-token")
        return (Data(#"{"userId":"verified-person","principalId":"verified-team","email":"grok@example.test"}"#.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let client = GrokClient(store: store, http: http, billing: { selected in
        #expect(selected == id)
        let environment = try GrokAuth.environment(selected, store: store)
        #expect(environment["GROK_AUTH_PATH"] == file.path)
        return Data(#"{"config":{"creditUsagePercent":27,"prepaidBalance":{"val":1234}},"subscription_tier":"SuperGrok"}"#.utf8)
    })
    let result = try await client.fetch(id)
    #expect(result.identity?.accountID == "verified-person")
    #expect(result.identity?.organizationID == "verified-team")
    #expect(result.identity?.email == "grok@example.test")
    #expect(result.metrics.first?.value == 73)
    #expect(result.plan == "SuperGrok")
    await #expect(throws: MonitorError.signInRequired) { try await client.fetch(other) }
    for mode in [0o664, 0o645] {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: config.path)
        await #expect(throws: MonitorError.invalidProfile) { try await client.fetch(id) }
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: config.path)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
    await #expect(throws: MonitorError.invalidProfile) { try await client.fetch(id) }
}

@Test func grokLoginLinksRequireOfficialPKCEAndLoopbackCallback() throws {
    let url = "https://auth.x.ai/oauth2/authorize?client_id=fixture&response_type=code&state=fixture-state&nonce=fixture-nonce&code_challenge=fixture-challenge&code_challenge_method=S256&redirect_uri=http%3A%2F%2F127.0.0.1%3A43210%2Fcallback"
    #expect(LoginPrompt.parse("Open this URL to sign in:\n  \(url)\n", provider: .grok)?.url.absoluteString == url)
    #expect(LoginPrompt.parse(url.replacingOccurrences(of: "auth.x.ai", with: "auth.x.ai.evil.test") + "\n", provider: .grok) == nil)
    #expect(LoginPrompt.parse(url.replacingOccurrences(of: "127.0.0.1", with: "evil.test") + "\n", provider: .grok) == nil)
    #expect(LoginPrompt.parse(url.replacingOccurrences(of: "S256", with: "plain") + "\n", provider: .grok) == nil)
}

@Test func manualGrokTokenAlsoReturnsAuthoritativeIdentity() async throws {
    let http = ProviderHTTP { request in
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-manual")
        let body = request.url?.path == "/v1/user" ? #"{"userId":"person","principalId":"team","email":"manual@example.test"}"#
            : #"{"config":{"creditUsagePercent":34},"subscription_tier":"SuperGrok"}"#
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let snapshot = try await AdditionalClient(http: http).fetch(.init(label: "", provider: .grok), secrets: .init(key: "fixture-manual"))
    #expect(snapshot.identity == .init(accountID: "person", organizationID: "team", email: "manual@example.test"))
    #expect(snapshot.metrics.first?.value == 66)
}

@Test func grokBotVerifiesTheSelectedSessionBeforeReadingUsage() async throws {
    let http = ProviderHTTP { request in
        #expect(request.value(forHTTPHeaderField: "Cookie") == "WorkosCursorSessionToken=fixture")
        let body = request.url?.path == "/api/auth/me" ? #"{"sub":"person-fixture","email":"bot@example.test"}"#
            : #"{"usagePercent":29,"includedLimitZero":false}"#
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let client = GrokBotClient(http: http)
    let secrets = ConnectionSecrets(key: "WorkosCursorSessionToken=fixture")
    let snapshot = try await client.fetch(Account(label: "", provider: .cursor), secrets: secrets)
    #expect(snapshot.identity?.email == "bot@example.test")
    #expect(snapshot.metrics.first?.value == 71)
    let wrong = Account(label: "", identity: .init(accountID: "other-person", organizationID: "", email: ""), provider: .cursor)
    await #expect(throws: MonitorError.identityChanged) { try await client.fetch(wrong, secrets: secrets) }
}

@Test func scopedBillingRPCRoundTripDoesNotWaitForEOF() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let helper = root.appendingPathComponent("fixture-helper")
    try Data("""
    #!/bin/sh
    IFS= read -r initialize
    case "$initialize" in *'"protocolVersion":1'*) ;; *) exit 2 ;; esac
    printf '%s\\n' '{"jsonrpc":"2.0","id":1,"result":{}}'
    IFS= read -r billing
    case "$billing" in *'"method":"_x.ai/billing"'*) ;; *) exit 3 ;; esac
    printf '%s\\n' '{"jsonrpc":"2.0","id":2,"result":{"config":{"creditUsagePercent":27}}}'
    IFS= read -r eof
    printf '%s' 'rotation-complete' > rotation-receipt
    """.utf8).write(to: helper)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
    let data = try await ScopedCLI.run(executable: helper, arguments: [], environment: [:], directory: root,
                                      billingRPC: true, timeout: 2)
    let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect((value?["config"] as? [String: Any])?["creditUsagePercent"] as? Int == 27)
    #expect(try String(contentsOf: root.appendingPathComponent("rotation-receipt"), encoding: .utf8) == "rotation-complete")
}

@Test func localMCPRejectsNonObjectArgumentsInsteadOfReturningAllAccounts() {
    let reply = LocalMCP.response(["jsonrpc": "2.0", "id": 7, "method": "tools/call",
        "params": ["name": "get_usage", "arguments": ["not-an-object"]]], snapshot: ["accounts": []], now: Date())
    #expect((reply?["error"] as? [String: Any])?["code"] as? Int == -32602)
}

@Test func localMCPSharingCanBeRevokedAndRejectsSymlinks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = try AccountStore(root: root)
    defer { try? FileManager.default.removeItem(at: root) }
    try LocalMCP.write([AccountEntry(account: .init(label: "", provider: .codex))], root: store.root, enabled: true)
    #expect((try LocalMCP.read(root: root)["accounts"] as? [[String: Any]])?.count == 1)
    try LocalMCP.write([], root: root, enabled: false)
    #expect(throws: (any Error).self) { try LocalMCP.read(root: root) }
    let target = root.appendingPathComponent("fixture.json")
    try Data(#"{"accounts":[]}"#.utf8).write(to: target)
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(LocalMCP.fileName), withDestinationURL: target)
    #expect(throws: (any Error).self) { try LocalMCP.read(root: root) }
}
