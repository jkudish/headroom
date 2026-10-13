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
    try await gate.set(selected.id, identity: "alice", utilization: 13)
    await gate.pause()
    let monitor = try Monitor(store: store, fetch: { _ in snapshot }, consume: { account, _, _ in
        _ = try await gate.fetch(account.id)
        return try JSONDecoder().decode(ResetOutcome.self, from: response(#"{"code":"reset","windows_reset":2}"#))
    })
    await monitor.refresh(selected.id)
    let reset = Task { try await monitor.useReset(selected.id, creditID: credit.id) }
    await gate.waitUntilStarted()
    await #expect(throws: MonitorError.invalidResponse) { try await monitor.useReset(selected.id, creditID: credit.id) }
    #expect(throws: MonitorError.loginBusy) { try monitor.remove(selected.id) }
    #expect(throws: MonitorError.loginBusy) { try monitor.reconnect(selected.id, secrets: .init(key: "not-saved")) }
    try monitor.remove(first.id)
    await gate.resume()
    #expect(try await reset.value.windowsReset == 2)
    #expect(monitor.entries.map(\.id) == [selected.id])
    #expect(!monitor.entries[0].resetting)
    #expect(monitor.entries[0].snapshot?.identity == owner)
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
    func pause() { paused = true }
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
