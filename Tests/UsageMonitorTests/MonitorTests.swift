import Foundation
import SwiftUI
import Testing
@testable import UsageMonitor

private func temporaryStore() throws -> AccountStore {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    return try AccountStore(root: root)
}

private func response(_ value: String) -> Data { Data(value.utf8) }

@Test func oldClaudeRecordsKeepIDsAndNewProviderRecordsKeepTheirProvider() throws {
    let id = UUID()
    let old = try JSONDecoder().decode(Account.self, from: response("{\"id\":\"\(id)\",\"label\":\"Personal\"}"))
    #expect(old.id == id)
    #expect(old.label == "Personal") // Preserve legacy data without using it as the heading.
    #expect(old.displayName == "New Claude account")
    let codex = try JSONDecoder().decode(Account.self, from: response("{\"id\":\"\(id)\",\"label\":\"Work\",\"provider\":\"codex\"}"))
    let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(codex)) as? [String: Any])
    #expect(encoded["provider"] as? String == "codex")
    let unnamed = Account(label: "", identity: .init(accountID: "org", organizationID: "org", email: ""), provider: .parallel)
    #expect(unnamed.displayName == "org")
}

@Test func openRouterHeadingsDescribeTheConnectionWithoutDisplayingInternalUserIDs() throws {
    let owner = AccountIdentity(accountID: "user_fixture_opaque", organizationID: "org-fixture", email: "")
    let key = Account(label: "Legacy", identity: owner, provider: .openRouter, options: ["mode": "key"])
    let restored = try JSONDecoder().decode(Account.self, from: JSONEncoder().encode(key))
    #expect(restored.displayName == "API key")
    #expect(AccountEntry(account: restored).displayName == "API key")
    #expect(restored.identity == owner)
    #expect(Account(label: "", provider: .openRouter).displayName == "Wallet")
    #expect(Account(label: "", provider: .openRouter, options: ["mode": "key"]).displayName == "API key")
    let identified = Account(label: "", identity: .init(accountID: "user_fixture", organizationID: "", email: "alice@example.test"),
                             provider: .openRouter, options: ["mode": "key"])
    #expect(identified.displayName == "alice@example.test")
}

@Test @MainActor func everyProviderHasABundledLogoInsteadOfALetterFallback() {
    for provider in Provider.allCases {
        #expect(provider.logo != nil, "Missing logo for \(provider.title)")
    }
}

@Test func enteredKeysStayOutOfMetadataAndSeparateAcrossAccounts() throws {
    let store = try temporaryStore()
    let a = Account(label: "A", provider: .openRouter), b = Account(label: "B", provider: .openRouter)
    defer { try? store.deleteProfile(a.id); try? store.deleteProfile(b.id); try? FileManager.default.removeItem(at: store.root) }
    try store.save([a, b])
    try store.saveSecrets(.init(key: "fixture-private-key-a"), for: a.id)
    #expect(try store.secrets(a.id).key == "fixture-private-key-a")
    #expect(throws: MonitorError.signInRequired) { try store.secrets(b.id) }
    let metadata = try String(contentsOf: store.root.appendingPathComponent("accounts.json"), encoding: .utf8)
    #expect(!metadata.contains("fixture-private-key-a"))
    try store.deleteProfile(a.id)
    #expect(throws: MonitorError.signInRequired) { try store.secrets(a.id) }
}

@Test func metersUseRemainingPercentAndCentsWithoutInventingMissingLimits() throws {
    let usage = try JSONDecoder().decode(ClaudeUsage.self, from: response("""
    {"five_hour":{"utilization":23.5,"resets_at":"2026-10-13T16:30:00.123Z"},
     "seven_day":{"utilization":94,"resets_at":"2026-10-18T09:00:00+00:00"},
     "extra_usage":{"is_enabled":true,"used_credits":1234,"monthly_limit":5000}}
    """))
    #expect(usage.fiveHour?.remaining == 76.5)
    #expect(usage.sevenDay?.remaining == 6)
    #expect(usage.fiveHour?.resetDate == Date(timeIntervalSince1970: 1791909000.123))
    #expect(usage.extraUsage?.spent == 12.34)
    #expect(usage.extraUsage?.cap == 50)
    let absent = try JSONDecoder().decode(ClaudeUsage.self, from: response("""
    {"five_hour":null,"extra_usage":{"is_enabled":true,"used_credits":750,"monthly_limit":null}}
    """))
    #expect(absent.fiveHour == nil)
    #expect(absent.sevenDay == nil)
    #expect(absent.extraUsage?.spent == 7.5)
    #expect(absent.extraUsage?.cap == nil)
}

@Test func malformedMetersAreNotPresentedAsHealthy() throws {
    let usage = try JSONDecoder().decode(ClaudeUsage.self, from: response("""
    {"five_hour":{"utilization":-3},"seven_day":{"utilization":101}}
    """))
    #expect(usage.fiveHour?.remaining == nil)
    #expect(usage.sevenDay?.remaining == nil)
}

@Test @MainActor func menuBarKeepsEachAccountsQuotaOrderAndUnknownSeparateFromZero() {
    let entry = AccountEntry(account: Account(label: "A", provider: .codex), snapshot: UsageSnapshot(metrics: [
        .init(title: "Credits left", kind: .balance, value: 1234, unit: "credits"),
        .init(title: "Weekly", kind: .quota, value: 0),
        .init(title: "5-hour", kind: .quota, value: 9),
        .init(title: "Malformed", kind: .quota, value: 101)
    ]))
    #expect(entry.menuBarMetrics.map(\.title) == ["5-hour", "Weekly"])
    #expect(entry.menuBarMetrics.map(\.value) == [9, 0])
    #expect(AccountEntry(account: .init(label: "B")).menuBarMetrics.isEmpty)
    let wallet = AccountEntry(account: .init(label: "Wallet", provider: .openRouter), snapshot: UsageSnapshot(metrics: [
        .init(title: "Spend", kind: .spend, value: 72, unit: "USD"),
        .init(title: "Wallet credits", kind: .balance, value: 37.82, unit: "USD")
    ]))
    #expect(wallet.menuBarMetrics.map(\.value) == [37.82])
    #expect(MenuBarAccountImage.text(.init(title: "Quota", kind: .quota, value: 0)) == "0%")
    #expect(MenuBarAccountImage.text(.init(title: "Quota", kind: .quota, value: 0.04)) == "<1%")
    #expect(MenuBarAccountImage.text(.init(title: "Quota", kind: .quota, value: nil)) == "—")
}

@MainActor @Test func ampQuotaTextMatchesDashboardRoundingWithoutChangingOtherProviders() {
    let cases: [(Double, String)] = [(0, "0%"), (0.04, "<0.5%"), (0.49, "<0.5%"), (0.5, "1%"),
                                   (8.9, "9%"), (57.3, "57%"), (99.49, "99%"), (99.5, ">99.5%"), (100, "100%")]
    for (value, expected) in cases {
        #expect(MenuBarAccountImage.text(.init(title: "Agent", kind: .quota, value: value), provider: .amp) == expected)
    }
    #expect(MenuBarAccountImage.text(.init(title: "Weekly", kind: .quota, value: 8.9), provider: .codex) == "8.9%")
    #expect(MenuBarAccountImage.text(.init(title: "Agent", kind: .quota, value: nil), provider: .amp) == "—")
}

@Test func freshProfilesNeverUseAnAmbientCredentialAndMetadataSurvivesRestart() throws {
    let store = try temporaryStore()
    defer { try? FileManager.default.removeItem(at: store.root) }
    let a = Account(label: "Personal")
    let b = Account(label: "Work")
    try store.prepare(a.id)
    try store.prepare(b.id)
    try store.save([a, b])
    // A real absent profile must fail closed even on a signed-in development machine.
    #expect(throws: MonitorError.signInRequired) { try store.credentials(b.id) }
    let credentialFile = store.profile(a.id).appendingPathComponent(".credentials.json")
    try response("""
    {"claudeAiOauth":{"accessToken":"fixture-account-a","expiresAt":4102444800000,"scopes":["user:profile"]}}
    """).write(to: credentialFile)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: credentialFile.path)
    #expect(try store.credentials(a.id).accessToken == "fixture-account-a")
    #expect(throws: MonitorError.signInRequired) { try store.credentials(b.id) }
    let restarted = try AccountStore(root: store.root)
    #expect(try restarted.load() == [a, b])
    #expect(store.profile(a.id) != store.profile(b.id))
}

@Test func helperFindsTheRealKeychainButKeepsAccountConfigsSeparate() throws {
    let store = try temporaryStore()
    defer { try? FileManager.default.removeItem(at: store.root) }
    let a = UUID(), b = UUID()
    let first = try store.helperEnvironment(a)
    let second = try store.helperEnvironment(b)
    #expect(first["HOME"] == FileManager.default.homeDirectoryForCurrentUser.path)
    #expect(first["CLAUDE_CONFIG_DIR"] == store.profile(a).path)
    #expect(first["CLAUDE_SECURESTORAGE_CONFIG_DIR"] == store.profile(a).path)
    #expect(first["CLAUDE_CONFIG_DIR"] != second["CLAUDE_CONFIG_DIR"])
    #expect(first["ANTHROPIC_CONFIG_DIR"] != second["ANTHROPIC_CONFIG_DIR"])
    #expect(first["ANTHROPIC_API_KEY"] == nil)
}

@Test @MainActor func accountHeadingsUseEmailAndPreserveLegacyLabelsWithoutDisplayingThem() async throws {
    let store = try temporaryStore()
    defer { try? FileManager.default.removeItem(at: store.root) }
    let service = FixtureService()
    let monitor = try Monitor(store: store, fetch: { id in try await service.fetch(id) })
    let id = try monitor.add(label: "")
    try await service.set(id, identity: "alice", utilization: 19)
    await monitor.refresh(id)
    #expect(monitor.entries[0].account.label == "")
    #expect(monitor.entries[0].account.displayName == "alice@example.test")
    try monitor.rename(id, label: "  Personal  ")
    await monitor.refresh(id)
    #expect(monitor.entries[0].account.displayName == "alice@example.test")
    #expect(monitor.entries[0].account.label == "Personal")
    let restarted = try Monitor(store: store, fetch: { id in try await service.fetch(id) })
    #expect(restarted.entries[0].account.displayName == "alice@example.test")
    try restarted.rename(id, label: "")
    #expect(restarted.entries[0].account.displayName == "alice@example.test")
}

@Test @MainActor func menuBarVisibilityPersistsWithoutRemovingAccountsOrIdentity() async throws {
    let store = try temporaryStore()
    defer { try? FileManager.default.removeItem(at: store.root) }
    let owner = AccountIdentity(accountID: "alice", organizationID: "work", email: "alice@example.test")
    let a = Account(label: "Legacy", identity: owner), b = Account(label: "", provider: .codex)
    try store.save([a, b])
    let monitor = try Monitor(store: store, fetch: { _ in throw MonitorError.network })
    #expect(monitor.entries.allSatisfy { $0.account.showInMenuBar })
    try monitor.setMenuBarVisibility(a.id, visible: false)
    let restarted = try Monitor(store: store, fetch: { _ in throw MonitorError.network })
    #expect(restarted.entries.map(\.id) == [a.id, b.id])
    #expect(restarted.entries.map { $0.account.showInMenuBar } == [false, true])
    #expect(restarted.entries[0].account.identity == owner)
    #expect(restarted.entries[0].account.displayName == owner.email)
    try restarted.setMenuBarVisibility(a.id, visible: true)
    #expect(try store.load().allSatisfy(\.showInMenuBar))
}

@Test @MainActor func pendingResetRejectsDuplicateUseAndSurvivesAnotherAccountRemoval() async throws {
    let store = try temporaryStore()
    defer { try? FileManager.default.removeItem(at: store.root) }
    let first = Account(label: "First")
    let owner = AccountIdentity(accountID: "alice", organizationID: "shared", email: "alice@example.test")
    let selected = Account(label: "", identity: owner, provider: .codex)
    try store.save([first, selected])
    let credit = LimitResetCredit(id: "selected", resetType: "codex_rate_limits", status: "available",
                                grantedAt: nil, expiresAt: nil, title: nil, description: nil)
    let snapshot = UsageSnapshot(identity: owner, metrics: [], resetCredits: .init(availableCount: 1, expirations: [], credits: [credit]))
    let gate = FixtureService()
    let polling = PollFixture()
    var now = Date(timeIntervalSince1970: 2_000_000_000)
    try await gate.set(selected.id, identity: "alice", utilization: 13)
    await gate.pause()
    let monitor = try Monitor(store: store, fetch: { id in
        _ = try await polling.fetch(id)
        return snapshot
    }, consume: { account, _, _ in
        _ = try await gate.fetch(account.id)
        return try JSONDecoder().decode(ResetOutcome.self, from: response(#"{"code":"reset","windows_reset":2}"#))
    }, now: { now })
    await monitor.refresh(selected.id)
    let reset = Task { try await monitor.useReset(selected.id, creditID: credit.id) }
    await gate.waitUntilStarted()
    now += 60
    await monitor.refreshDue(maxAge: 30)
    #expect(await polling.count(selected.id) == 1)
    await #expect(throws: MonitorError.invalidResponse) { try await monitor.useReset(selected.id, creditID: credit.id) }
    #expect(throws: MonitorError.loginBusy) { try monitor.remove(selected.id) }
    #expect(throws: MonitorError.loginBusy) { try monitor.reconnect(selected.id, secrets: .init(key: "not-saved")) }
    try monitor.remove(first.id)
    await gate.resume()
    #expect(try await reset.value.windowsReset == 2)
    #expect(monitor.entries.map(\.id) == [selected.id])
    #expect(!monitor.entries[0].resetting)
    #expect(monitor.entries[0].snapshot?.identity == owner)
    #expect(await polling.count(selected.id) == 2)
}

@Test @MainActor func uncertainResetBlocksAnotherCreditUntilSuccessfulRefresh() async throws {
    let store = try temporaryStore()
    defer { try? FileManager.default.removeItem(at: store.root) }
    let owner = AccountIdentity(accountID: "alice", organizationID: "shared", email: "alice@example.test")
    let account = Account(label: "", identity: owner, provider: .codex)
    try store.save([account])
    let credits = ["A", "B"].map {
        LimitResetCredit(id: $0, resetType: "codex_rate_limits", status: "available", grantedAt: nil,
                         expiresAt: nil, title: nil, description: nil)
    }
    let snapshot = UsageSnapshot(identity: owner, metrics: [.init(title: "Weekly", kind: .quota, value: 0)],
                                 resetCredits: .init(availableCount: 2, expirations: [], credits: credits))
    let service = ResetRecoveryFixture(snapshot)
    let monitor = try Monitor(store: store, fetch: { _ in try await service.fetch() },
                              consume: { _, credit, _ in try await service.consume(credit) })
    await monitor.refresh(account.id)
    await #expect(throws: MonitorError.network) { try await monitor.useReset(account.id, creditID: "A") }
    await #expect(throws: MonitorError.invalidResponse) { try await monitor.useReset(account.id, creditID: "B") }
    #expect(await service.sent == ["A"])
    await service.failRefresh(true)
    await monitor.refresh(account.id)
    await #expect(throws: MonitorError.invalidResponse) { try await monitor.useReset(account.id, creditID: "B") }
    #expect(await service.sent == ["A"])
    let restarted = try Monitor(store: store, fetch: { _ in try await service.fetch() },
                                consume: { _, credit, _ in try await service.consume(credit) })
    await restarted.refresh(account.id)
    await #expect(throws: MonitorError.invalidResponse) { try await restarted.useReset(account.id, creditID: "B") }
    #expect(await service.sent == ["A"])
    await service.failRefresh(false)
    await restarted.refresh(account.id)
    await #expect(throws: MonitorError.network) { try await restarted.useReset(account.id, creditID: "B") }
    #expect(await service.sent == ["A", "B"])
}

private actor ResetRecoveryFixture {
    let snapshot: UsageSnapshot
    var failing = false
    private(set) var sent: [String] = []
    init(_ snapshot: UsageSnapshot) { self.snapshot = snapshot }
    func failRefresh(_ failing: Bool) { self.failing = failing }
    func fetch() throws -> UsageSnapshot {
        if failing { throw MonitorError.network }
        return snapshot
    }
    func consume(_ credit: String) throws -> ResetOutcome {
        sent.append(credit)
        throw MonitorError.network
    }
}

@Test func limitColorsAndResetTextMatchTheDisplayedBoundaries() throws {
    func window(_ used: Double) -> ClaudeUsage.Window { .init(utilization: used, resetsAt: "2026-10-16T04:00:00Z") }
    #expect(window(100).remainingColor == .red)
    #expect(window(99.9).remainingColor == .orange)
    #expect(window(90).remainingColor == .orange)
    #expect(window(89.9).remainingColor == .accentColor)
    #expect(window(101).remainingColor == .secondary)
    let zone = try #require(TimeZone(identifier: "America/Vancouver"))
    #expect(window(100).formattedReset(timeZone: zone) == "Thu Oct 15 at 9pm")
    let halfHour = ClaudeUsage.Window(utilization: 25, resetsAt: "2026-10-16T04:30:00Z")
    #expect(halfHour.formattedReset(timeZone: zone) == "Thu Oct 15 at 9:30pm")
}

@Test @MainActor func twoAccountsRefreshIndependentlyAndRejectIdentityChanges() async throws {
    let store = try temporaryStore()
    defer { try? FileManager.default.removeItem(at: store.root) }
    let a = Account(label: "Personal")
    let b = Account(label: "Work")
    try store.save([a, b])
    let service = FixtureService()
    let monitor = try Monitor(store: store, fetch: { id in try await service.fetch(id) })
    try await service.set(a.id, identity: "alice", utilization: 13)
    try await service.set(b.id, identity: "bob", utilization: 87)
    await monitor.refresh(a.id)
    await monitor.refresh(b.id)
    #expect(monitor.entries[0].snapshot?.metrics.first?.value == 87)
    #expect(monitor.entries[1].snapshot?.metrics.first?.value == 13)
    #expect(try store.load()[0].identity?.accountID == "alice")
    try await service.set(a.id, identity: "bob", utilization: 2)
    await monitor.refresh(a.id)
    #expect(monitor.entries[0].snapshot == nil)
    #expect(monitor.entries[0].error == MonitorError.identityChanged.localizedDescription)
    #expect(monitor.entries[1].snapshot?.metrics.first?.value == 13)
    // Binding is durable, not just an in-memory check.
    let restarted = try Monitor(store: store, fetch: { id in try await service.fetch(id) })
    await restarted.refresh(a.id)
    #expect(restarted.entries[0].snapshot == nil)
}

@Test @MainActor func removedAccountCannotReturnThroughADelayedRefresh() async throws {
    let store = try temporaryStore()
    defer { try? FileManager.default.removeItem(at: store.root) }
    let a = Account(label: "Remove me")
    try store.prepare(a.id)
    try store.save([a])
    let service = FixtureService()
    try await service.set(a.id, identity: "alice", utilization: 13)
    await service.pause()
    let monitor = try Monitor(store: store, fetch: { id in try await service.fetch(id) })
    let refresh = Task { await monitor.refresh(a.id) }
    await service.waitUntilStarted()
    try monitor.remove(a.id)
    await service.resume()
    await refresh.value
    #expect(monitor.entries.isEmpty)
    #expect(try store.load().isEmpty)
}

@Test @MainActor func aBoundAccountCannotLoseItsIdentityOnRefresh() async throws {
    let store = try temporaryStore()
    defer { try? FileManager.default.removeItem(at: store.root) }
    let account = Account(label: "Work", identity: .init(accountID: "alice", organizationID: "org", email: "alice@example.test"), provider: .openRouter)
    try store.save([account])
    let monitor = try Monitor(store: store, fetch: { _ in
        UsageSnapshot(metrics: [.init(title: "Spend", kind: .spend, value: 7, unit: "USD")])
    })
    await monitor.refresh(account.id)
    #expect(monitor.entries[0].snapshot == nil)
    #expect(monitor.entries[0].error == MonitorError.invalidResponse.localizedDescription)
    #expect(try store.load()[0].identity?.accountID == "alice")
}

@Test func clientKeepsSelectedAccountCredentialsAndProfileTogether() async throws {
    let a = UUID(), b = UUID()
    let client = ClaudeClient(credentials: { id in
        try Credential.decode(response("""
        {"claudeAiOauth":{"accessToken":"\(id == a ? "fixture-alice" : "fixture-bob")","scopes":["user:profile"],
          "subscriptionType":"\(id == a ? "max" : "pro")","rateLimitTier":"default_claude_max_20x"}}
        """))
    }, send: { request in
        let alice = request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-alice"
        let profile = alice
            ? "{\"account\":{\"uuid\":\"alice\",\"email_address\":\"alice@example.test\",\"display_name\":\"  Alice  \"},\"organization\":{\"uuid\":\"personal\"}}"
            : "{\"account\":{\"uuid\":\"bob\",\"emailAddress\":\"bob@example.test\"},\"organization\":{\"uuid\":\"work\"}}"
        let payload = request.url?.lastPathComponent == "profile" ? profile : "{\"five_hour\":{\"utilization\":\(alice ? 19 : 83)}}"
        return (response(payload), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    })
    async let first = client.fetch(a)
    async let second = client.fetch(b)
    let (alice, bob) = try await (first, second)
    #expect(alice.identity?.accountID == "alice")
    #expect(alice.identity?.email == "alice@example.test")
    #expect(Account(label: "Custom", identity: alice.identity).displayName == "alice@example.test")
    #expect(alice.metrics.first?.value == 81)
    #expect(alice.plan == "Max 20x")
    #expect(bob.identity?.accountID == "bob")
    #expect(bob.identity?.email == "bob@example.test")
    #expect(Account(label: "", identity: bob.identity).displayName == "bob@example.test")
    #expect(bob.metrics.first?.value == 17)
    #expect(bob.plan == "Pro")
}

@Test func freshClaudeProfileOverridesCachedPlanWithoutBorrowingItsMultiplier() async throws {
    let cases: [(String, String)] = [
        (#""rate_limit_tier":"default_claude_max_20x","organization_type":"claude_max""#, "Max 20x"),
        (#""rate_limit_tier":"default_claude_max_5x","organization_type":"claude_max""#, "Max 5x"),
        (#""organization_type":"claude_max""#, "Max"),
        (#""organization_type":"claude_pro""#, "Pro"),
        (#""rate_limit_tier":{},"organization_type":"claude_max""#, "Max"),
        (#""rate_limit_tier":17,"organization_type":null"#, "Max 5x"),
        (#""rate_limit_tier":"unknown_future_tier","organization_type":"unknown""#, "Max 5x"),
        (#""organization_type":false"#, "Max 5x")
    ]
    for (fields, expected) in cases {
        let client = ClaudeClient(credentials: { _ in
            try Credential.decode(response(#"{"claudeAiOauth":{"accessToken":"fixture","scopes":["user:profile"],"subscriptionType":"max","rateLimitTier":"default_claude_max_5x"}}"#))
        }, send: { request in
            let payload = request.url?.lastPathComponent == "profile"
                ? "{\"account\":{\"uuid\":\"alice\",\"email\":\"alice@example.test\"},\"organization\":{\"uuid\":\"org\",\(fields)}}"
                : #"{"five_hour":{"utilization":23},"seven_day":{"utilization":68}}"#
            return (response(payload), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let snapshot = try await client.fetch(UUID())
        #expect(snapshot.plan == expected, "Fresh profile: \(fields)")
        #expect(snapshot.identity?.accountID == "alice")
        #expect(snapshot.metrics[0].value == 77)
        #expect(snapshot.metrics[1].value == 32)
    }
}

@Test func claudeDisplaysSavedResetsAndSeparateDollarBalancesWithReadOnlyOAuth() async throws {
    let client = ClaudeClient(credentials: { _ in
        try Credential.decode(response(#"{"claudeAiOauth":{"accessToken":"fixture","scopes":["user:profile"]}}"#))
    }, send: { request in
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture")
        let payload: String
        if request.url?.lastPathComponent == "profile" {
            payload = #"{"account":{"uuid":"alice"},"organization":{"uuid":"org"}}"#
        } else {
            #expect(request.url?.query == "cedar_ember=1")
            #expect(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("claude-cli/") == true)
            payload = #"{"five_hour":{"utilization":23},"extra_usage":{"is_enabled":true,"used_credits":1984,"monthly_limit":12500},"cedar_ember":{"eligible":true,"grants":[{"resets_left":3,"resets_total":4,"paused":false,"usable_now":false,"ends_at":"2100-01-01T00:00:00Z"},{"resets_left":2,"paused":false},{"resets_left":19,"paused":true},{"resets_left":9,"paused":false,"starts_at":"2100-01-01T00:00:00Z"},{"resets_left":4,"paused":false,"ends_at":"2020-01-01T00:00:00Z"}]},"iguana_necktie":{"limit_dollars":100,"used_dollars":20,"remaining_dollars":80.5,"resets_at":"2100-01-02T00:00:00Z"}}"#
        }
        return (response(payload), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    })
    let snapshot = try await client.fetch(UUID())
    #expect(snapshot.identity?.accountID == "alice")
    #expect(snapshot.metrics.first?.value == 77)
    #expect(snapshot.metrics.first { $0.title == "Extra usage spent" }?.value == 19.84)
    #expect(snapshot.metrics.first { $0.title == "Extra usage cap" }?.value == 125)
    let resets = try #require(snapshot.metrics.first { $0.title == "Available resets" })
    #expect(resets.value == 5) // Saved count, not grant-record count or immediately usable count.
    #expect(resets.kind == .count)
    #expect(resets.resetsAt == nil) // Grant expiry is not a recurring quota reset.
    #expect(resets.detail?.contains("expiry") == true)
    let credits = try #require(snapshot.metrics.first { $0.title == "Cloud credits" })
    #expect(credits.value == 80.5) // Already dollars, not cents; reported remaining wins.
    #expect(credits.unit == "USD")
    #expect(credits.kind == .balance)
    #expect(credits.resetsAt == nil)
    #expect(credits.detail?.hasPrefix("Expires") == true)
}

@Test @MainActor func retainedClaudeSnapshotStopsOfferingExpiredCreditsWithoutAnotherFetch() async throws {
    let fetched = Date()
    let expiry = fetched.addingTimeInterval(1)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let timestamp = formatter.string(from: expiry)
    let usage = try JSONDecoder().decode(ClaudeUsage.self, from: response("""
    {"extra_usage":{"is_enabled":true,"used_credits":1984},
     "cedar_ember":{"eligible":true,"grants":[{"resets_left":5,"paused":false,"ends_at":"\(timestamp)"}]},
     "iguana_necktie":{"limit_dollars":100,"remaining_dollars":80.5,"resets_at":"\(timestamp)"}}
    """))
    let snapshot = UsageSnapshot(identity: .init(accountID: "alice", organizationID: "org", email: "alice@example.test"),
                                 usage: usage, fetchedAt: fetched)
    let entry = AccountEntry(account: Account(label: "", provider: .claude), snapshot: snapshot)
    #expect(snapshot.metrics.first { $0.title == "Available resets" }?.value == 5)
    #expect(entry.menuBarMetrics.first?.value == 80.5)
    try await Task.sleep(for: .seconds(1.1))
    #expect(Date() > expiry)
    #expect(snapshot.metrics.first { $0.title == "Available resets" }?.value == 0)
    #expect(snapshot.metrics.first { $0.title == "Cloud credits" }?.value == nil)
    #expect(snapshot.metrics.first { $0.title == "Cloud credits" }?.detail?.hasPrefix("Expired") == true)
    #expect(entry.menuBarMetrics.isEmpty)
    #expect(snapshot.metrics.first { $0.title == "Extra usage spent" }?.value == 19.84)
    #expect(snapshot.fetchedAt == fetched)
}

@Test func claudeCreditAvailabilityAndResetDateBoundariesStaySeparate() throws {
    let now = ISO8601DateFormatter().date(from: "2030-01-01T00:00:00Z")!
    let cases: [(String, Double?, String)] = [
        (#"{"limit_dollars":100,"used_dollars":27.25}"#, 72.75, "Promotional"),
        (#"{"limit_dollars":100,"remaining_dollars":0}"#, 0, "Promotional"),
        (#"{"limit_dollars":100,"remaining_dollars":80.5,"locked_reason":"not_eligible"}"#, nil, "Unavailable"),
        (#"{"limit_dollars":100,"remaining_dollars":80.5,"resets_at":"2030-01-01T00:00:00Z"}"#, nil, "Expired"),
        (#"{"limit_dollars":100,"remaining_dollars":80.5,"resets_at":"2030-01-01T00:00:01Z"}"#, 80.5, "Expires")
    ]
    for (credits, expected, detail) in cases {
        let data = response("""
        {"cedar_ember":{"eligible":true,"grants":[
          {"resets_left":2,"paused":false,"starts_at":"2030-01-01T00:00:00Z"},
          {"resets_left":3,"paused":false,"ends_at":"2030-01-01T00:00:00Z"},
          {"resets_left":7,"paused":false,"starts_at":"2030-01-01T00:00:01Z"}]},
         "iguana_necktie":\(credits)}
        """)
        let snapshot = UsageSnapshot(identity: .init(accountID: "alice", organizationID: "org", email: "alice@example.test"),
                                     usage: try JSONDecoder().decode(ClaudeUsage.self, from: data), fetchedAt: now)
        let metrics = snapshot.metrics(at: now)
        #expect(metrics.first { $0.title == "Available resets" }?.value == 2)
        let money = try #require(metrics.first { $0.title == "Cloud credits" })
        #expect(money.value == expected)
        #expect(money.detail?.contains(detail) == true)
        #expect(money.resetsAt == nil)
        #expect(snapshot.resetCredits == nil)
    }
}

@Test func optionalClaudeInventoryFailuresNeverHideOrdinaryQuotasAndMoney() async throws {
    let blocks = [
        #""cedar_ember":null,"iguana_necktie":{}"#,
        #""cedar_ember":{"eligible":false,"grants":[]},"iguana_necktie":null"#,
        #""cedar_ember":{"eligible":1,"grants":[]},"iguana_necktie":{"limit_dollars":100,"remaining_dollars":true}"#,
        #""cedar_ember":{"eligible":true,"grants":[{"resets_left":-1,"paused":false}]},"iguana_necktie":{"limit_dollars":100,"remaining_dollars":101}"#,
        #""cedar_ember":{"eligible":true,"grants":[{"resets_left":1,"paused":false,"ends_at":"bad"}]},"iguana_necktie":{"limit_dollars":100,"remaining_dollars":10,"resets_at":"bad"}"#,
        #""cedar_ember":{"eligible":true,"grants":[{"resets_left":1}]},"iguana_necktie":{"limit_dollars":100}"#,
        #""cedar_ember":{"eligible":true,"grants":[{"resets_left":1,"resets_total":0,"paused":false}]},"iguana_necktie":{"limit_dollars":-1,"remaining_dollars":0}"#,
        #""cedar_ember":{"eligible":true,"grants":[{"resets_left":9223372036854775807,"paused":false},{"resets_left":1,"paused":false}]},"iguana_necktie":{"limit_dollars":100,"used_dollars":-1}"#
    ]
    for block in blocks {
        let client = ClaudeClient(credentials: { _ in
            try Credential.decode(response(#"{"claudeAiOauth":{"accessToken":"fixture","scopes":["user:profile"]}}"#))
        }, send: { request in
            let payload = request.url?.lastPathComponent == "profile"
                ? #"{"account":{"uuid":"alice"},"organization":{"uuid":"org"}}"#
                : "{\"five_hour\":{\"utilization\":23},\"extra_usage\":{\"is_enabled\":true,\"used_credits\":1984},\(block)}"
            return (response(payload), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let snapshot = try await client.fetch(UUID())
        #expect(snapshot.metrics.first?.value == 77)
        #expect(snapshot.metrics.first { $0.title == "Extra usage spent" }?.value == 19.84)
        #expect(!snapshot.metrics.contains { $0.title == "Available resets" || $0.title == "Cloud credits" })
    }
}

@Test(arguments: [400, 403])
func rejectedClaudeInventoryQueryFallsBackToTheSameAccountsOrdinaryUsage(_ status: Int) async throws {
    let client = ClaudeClient(credentials: { _ in
        try Credential.decode(response(#"{"claudeAiOauth":{"accessToken":"fixture","scopes":["user:profile"]}}"#))
    }, send: { request in
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture")
        let payload = request.url?.lastPathComponent == "profile"
            ? #"{"account":{"uuid":"alice"},"organization":{"uuid":"org"}}"#
            : #"{"five_hour":{"utilization":23},"extra_usage":{"is_enabled":true,"used_credits":1984}}"#
        return (response(payload), HTTPURLResponse(url: request.url!, statusCode: request.url?.query == nil ? 200 : status, httpVersion: nil, headerFields: nil)!)
    })
    let snapshot = try await client.fetch(UUID())
    #expect(snapshot.identity?.accountID == "alice")
    #expect(snapshot.metrics.first?.value == 77)
    #expect(snapshot.metrics.first { $0.title == "Extra usage spent" }?.value == 19.84)
    #expect(snapshot.resetCredits == nil) // Claude display does not expose a Codex redemption handle.
}

@Test(arguments: ["null", "17", "{}"])
func malformedOptionalClaudePlanDoesNotInvalidateUsageCredentials(_ plan: String) throws {
    let credential = try Credential.decode(response("""
    {"claudeAiOauth":{"accessToken":"fixture","scopes":["user:profile"],"subscriptionType":\(plan),"rateLimitTier":\(plan)}}
    """))
    #expect(credential.accessToken == "fixture")
    #expect(credential.planLabel == nil)
}

@Test func expiredAndInferenceOnlyTokensCannotReadUsage() {
    #expect(throws: MonitorError.signInRequired) {
        try Credential.decode(response("{\"claudeAiOauth\":{\"accessToken\":\"fixture\",\"expiresAt\":1,\"scopes\":[\"user:profile\"]}}"))
    }
    #expect(throws: MonitorError.missingScope) {
        try Credential.decode(response("{\"claudeAiOauth\":{\"accessToken\":\"fixture\",\"scopes\":[\"user:inference\"]}}"))
    }
}

@Test func officialDevicePromptKeepsTheFullCodeAndRejectsOtherHosts() throws {
    let text = "Open this link\nhttps://auth.openai.com/codex/device\nEnter this one-time code\nABCD-EF123\n"
    let prompt = try #require(LoginPrompt.parse(text, provider: .codex))
    #expect(prompt.url.absoluteString == "https://auth.openai.com/codex/device")
    #expect(prompt.deviceCode == "ABCD-EF123")
    #expect(LoginPrompt.parse(text.replacingOccurrences(of: "auth.openai.com", with: "evil.example"), provider: .codex) == nil)
    #expect(LoginPrompt.parse(text.replacingOccurrences(of: "ABCD-EF123", with: "ABCD-EF12"), provider: .codex) == nil)
    #expect(LoginPrompt.parse(text.replacingOccurrences(of: "codex/device", with: "codex/device?redirect=evil"), provider: .codex) == nil)
}

@Test @MainActor func startingLoginInvalidatesAnEarlierRefresh() async throws {
    let store = try temporaryStore()
    defer { try? FileManager.default.removeItem(at: store.root) }
    let a = Account(label: "Reconnecting")
    try store.save([a])
    let service = FixtureService()
    try await service.set(a.id, identity: "old-account", utilization: 13)
    await service.pause()
    let monitor = try Monitor(store: store, fetch: { id in try await service.fetch(id) })
    let refresh = Task { await monitor.refresh(a.id) }
    await service.waitUntilStarted()
    monitor.beginLogin(a.id)
    await service.resume()
    await refresh.value
    #expect(monitor.entries[0].snapshot == nil)
    #expect(monitor.entries[0].account.identity == nil)
    #expect(!monitor.entries[0].refreshing)
}

private actor FixtureService {
    var values: [UUID: UsageSnapshot] = [:]
    var paused = false
    var started = false
    var pending: CheckedContinuation<Void, Never>?
    var startWaiter: CheckedContinuation<Void, Never>?

    func set(_ id: UUID, identity: String, utilization: Double) throws {
        let usage = try JSONDecoder().decode(ClaudeUsage.self, from: response("""
        {"five_hour":{"utilization":\(utilization)}}
        """))
        values[id] = UsageSnapshot(identity: AccountIdentity(accountID: identity, organizationID: "org-\(identity)", email: "\(identity)@example.test"), usage: usage, fetchedAt: Date())
    }
    func pause() { paused = true; started = false }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiter = $0 }
    }
    func resume() { paused = false; pending?.resume(); pending = nil }
    func fetch(_ id: UUID) async throws -> UsageSnapshot {
        started = true
        startWaiter?.resume(); startWaiter = nil
        if paused { await withCheckedContinuation { pending = $0 } }
        return try #require(values[id])
    }
}

@Test @MainActor func claudeChecksEveryFiveMinutesEvenWhenTheMenuReopens() async throws {
    let store = try temporaryStore()
    defer { try? FileManager.default.removeItem(at: store.root) }
    let claude = Account(label: "", provider: .claude), codex = Account(label: "", provider: .codex)
    try store.save([claude, codex])
    let service = PollFixture()
    var now = Date(timeIntervalSince1970: 2_000_000_000)
    let monitor = try Monitor(store: store, fetch: { try await service.fetch($0) }, now: { now })
    await monitor.refresh(claude.id)
    await monitor.refresh(codex.id)
    now += 30
    await monitor.refreshDue(maxAge: 30)
    #expect(await service.count(claude.id) == 1)
    #expect(await service.count(codex.id) == 2)
    now += 269
    await monitor.refreshDue(maxAge: 30)
    #expect(await service.count(claude.id) == 1)
    now += 1
    await monitor.refreshDue()
    await monitor.refreshDue(maxAge: 30)
    #expect(await service.count(claude.id) == 2)
    #expect(monitor.entries[0].snapshot?.metrics.first?.value == 2)
}

@Test @MainActor func claudeRateLimitCooldownAlsoBlocksManualRefreshes() async throws {
    let store = try temporaryStore()
    defer { try? FileManager.default.removeItem(at: store.root) }
    let claude = Account(label: "", provider: .claude), other = Account(label: "", provider: .claude)
    try store.save([claude, other])
    let service = PollFixture()
    await service.fail(claude.id, with: .http(429))
    var now = Date(timeIntervalSince1970: 2_000_000_000)
    let monitor = try Monitor(store: store, fetch: { try await service.fetch($0) }, now: { now })
    await monitor.refresh(claude.id)
    await monitor.refresh(other.id)
    for delay: TimeInterval in [600, 1200, 1800, 1800] {
        let before = await service.count(claude.id)
        await monitor.refresh(claude.id)
        now += delay - 1
        await monitor.refreshDue(maxAge: 30)
        await monitor.refresh(claude.id)
        #expect(await service.count(claude.id) == before)
        #expect(monitor.entries[0].error == MonitorError.http(429).localizedDescription)
        now += 1
        await monitor.refreshDue()
        #expect(await service.count(claude.id) == before + 1)
    }
    await service.fail(claude.id, with: nil)
    now += 1800
    await monitor.refreshDue()
    let recovered = await service.count(claude.id)
    #expect(monitor.entries[0].error == nil)
    #expect(monitor.entries[0].snapshot?.metrics.first?.value == Double(recovered))
    now += 299
    await monitor.refreshDue(maxAge: 30)
    #expect(await service.count(claude.id) == recovered)
    now += 1
    await monitor.refreshDue()
    #expect(await service.count(claude.id) == recovered + 1)
    #expect(await service.count(other.id) > 1)
}

@Test @MainActor func automaticUsageRefreshRespectsMinuteAndStaleMenuBoundaries() async throws {
    let store = try temporaryStore()
    defer { try? FileManager.default.removeItem(at: store.root) }
    let account = Account(label: "", provider: .codex)
    try store.save([account])
    let service = PollFixture()
    var now = Date(timeIntervalSince1970: 2_000_000_000)
    let monitor = try Monitor(store: store, fetch: { try await service.fetch($0) }, now: { now })
    await monitor.refresh(account.id)
    now += 59
    await monitor.refreshDue()
    #expect(await service.count(account.id) == 1)
    now += 1
    await monitor.refreshDue()
    #expect(await service.count(account.id) == 2)
    now += 29
    await monitor.refreshDue(maxAge: 30)
    #expect(await service.count(account.id) == 2)
    now += 1
    await monitor.refreshDue(maxAge: 30)
    await monitor.refreshDue(maxAge: 30)
    #expect(await service.count(account.id) == 3)
    #expect(monitor.entries[0].snapshot?.metrics.first?.value == 3)
}

@Test @MainActor func automaticBackoffAndAuthPauseStayAccountScoped() async throws {
    let store = try temporaryStore()
    defer { try? FileManager.default.removeItem(at: store.root) }
    let limited = Account(label: "", provider: .codex), blocked = Account(label: "", provider: .claude)
    try store.save([limited, blocked])
    let service = PollFixture()
    await service.fail(limited.id, with: .http(429))
    await service.fail(blocked.id, with: .keychainUnavailable)
    var now = Date(timeIntervalSince1970: 2_000_000_000)
    let monitor = try Monitor(store: store, fetch: { try await service.fetch($0) }, now: { now })
    await monitor.refresh(limited.id)
    await monitor.refresh(blocked.id)
    now += 119
    await monitor.refreshDue(maxAge: 30)
    #expect(await service.count(limited.id) == 1)
    now += 1
    await monitor.refreshDue()
    #expect(await service.count(limited.id) == 2)
    now += 239
    await monitor.refreshDue(maxAge: 30)
    #expect(await service.count(limited.id) == 2)
    now += 1
    await service.fail(limited.id, with: nil)
    await monitor.refreshDue()
    #expect(await service.count(limited.id) == 3)
    now += 60
    await monitor.refreshDue()
    #expect(await service.count(limited.id) == 4)
    #expect(await service.count(blocked.id) == 1)
    await service.fail(blocked.id, with: nil)
    await monitor.refresh(blocked.id) // Only an explicit user retry resumes this account.
    now += 300
    await monitor.refreshDue()
    #expect(await service.count(blocked.id) == 3)

    await service.fail(limited.id, with: .network)
    await monitor.refresh(limited.id)
    for delay: TimeInterval in [120, 240, 480, 960, 1800, 1800] {
        let before = await service.count(limited.id)
        now += delay - 1
        await monitor.refreshDue(maxAge: 30)
        #expect(await service.count(limited.id) == before)
        now += 1
        await monitor.refreshDue()
        #expect(await service.count(limited.id) == before + 1)
    }
    for failure in [MonitorError.signInRequired, .missingScope, .http(401), .http(403)] {
        await service.fail(blocked.id, with: failure)
        await monitor.refresh(blocked.id)
        let before = await service.count(blocked.id)
        now += 3600
        await monitor.refreshDue(maxAge: 30)
        #expect(await service.count(blocked.id) == before)
    }
}

@Test @MainActor func automaticRefreshCannotFetchAnAccountDuringReconnect() async throws {
    let store = try temporaryStore()
    defer { try? FileManager.default.removeItem(at: store.root) }
    let account = Account(label: "", provider: .claude)
    try store.save([account])
    let service = PollFixture()
    var now = Date(timeIntervalSince1970: 2_000_000_000)
    let monitor = try Monitor(store: store, fetch: { try await service.fetch($0) }, now: { now })
    await monitor.refresh(account.id)
    monitor.beginLogin(account.id)
    now += 3600
    await monitor.refreshDue(maxAge: 30)
    #expect(await service.count(account.id) == 1)
    #expect(monitor.entries[0].snapshot == nil)
}

@Test @MainActor func loginStartingDuringAutomaticBatchPausesRemainingAccounts() async throws {
    let store = try temporaryStore()
    defer { try? FileManager.default.removeItem(at: store.root) }
    let first = Account(label: ""), second = Account(label: "")
    try store.save([first, second])
    let service = FixtureService()
    try await service.set(first.id, identity: "first", utilization: 23)
    try await service.set(second.id, identity: "second", utilization: 13)
    var now = Date(timeIntervalSince1970: 2_000_000_000)
    var signingIn = false
    let monitor = try Monitor(store: store, fetch: { try await service.fetch($0) }, now: { now })
    await monitor.refresh(first.id)
    await monitor.refresh(second.id)
    try await service.set(second.id, identity: "second", utilization: 91)
    await service.pause()
    now += 300
    let batch = Task { await monitor.refreshDue(isPaused: { signingIn }) }
    await service.waitUntilStarted()
    monitor.beginLogin(first.id)
    signingIn = true
    await service.resume()
    await batch.value
    #expect(monitor.entries[0].snapshot == nil)
    #expect(monitor.entries[1].snapshot?.metrics.first?.value == 87)
    signingIn = false
    await monitor.refreshDue(isPaused: { signingIn })
    #expect(monitor.entries[0].snapshot == nil)
    #expect(monitor.entries[1].snapshot?.metrics.first?.value == 9)
}

private actor PollFixture {
    var counts: [UUID: Int] = [:]
    var errors: [UUID: MonitorError] = [:]
    func fail(_ id: UUID, with error: MonitorError?) { errors[id] = error }
    func count(_ id: UUID) -> Int { counts[id, default: 0] }
    func fetch(_ id: UUID) throws -> UsageSnapshot {
        counts[id, default: 0] += 1
        if let error = errors[id] { throw error }
        return UsageSnapshot(metrics: [.init(title: "Weekly", kind: .quota, value: Double(counts[id]!))])
    }
}
