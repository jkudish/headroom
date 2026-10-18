import Foundation
import Testing
@testable import UsageMonitor

private func oauth(_ access: String, refresh: String = "fixture-refresh", expiry: Double = 1) -> Data {
    Data("""
    {"claudeAiOauth":{"accessToken":"\(access)","refreshToken":"\(refresh)","expiresAt":\(expiry),"scopes":["user:profile","user:inference"]}}
    """.utf8)
}

private actor AuthFixture {
    var data: [UUID: Data]
    var renewals = 0
    var persist = true
    var failAfterSave = false
    init(_ data: [UUID: Data], persist: Bool = true, failAfterSave: Bool = false) {
        self.data = data; self.persist = persist; self.failAfterSave = failAfterSave
    }
    func read(_ id: UUID) throws -> Data { try #require(data[id]) }
    func renew(_ id: UUID, _ environment: [String: String]) throws {
        #expect(environment["CLAUDE_CODE_OAUTH_REFRESH_TOKEN"] == "fixture-refresh")
        #expect(environment["CLAUDE_CODE_OAUTH_SCOPES"] == "user:profile user:inference")
        renewals += 1
        if persist { data[id] = oauth("renewed", refresh: "rotated", expiry: 4_000_000_000_000) }
        if failAfterSave { throw MonitorError.helperFailed }
    }
}

@Test func expiredClaudeCredentialRenewsOnlyItsSelectedProfile() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = try AccountStore(root: root)
    defer { try? FileManager.default.removeItem(at: root) }
    let a = UUID(), b = UUID()
    try store.prepare(a); try store.prepare(b)
    try store.enableDurableClaudeAccess(a)
    let fixture = AuthFixture([a: oauth("expired-a"), b: oauth("valid-b", expiry: 4_000_000_000_000)])
    let auth = ClaudeAuth(store: store, read: { try await fixture.read($0) }, renew: { try await fixture.renew($0, $1) })
    #expect(try await auth.credential(a).accessToken == "renewed")
    #expect(try await auth.credential(b).accessToken == "valid-b")
    #expect(await fixture.renewals == 1)
    #expect(!FileManager.default.fileExists(atPath: store.profile(a).appendingPathComponent("renewal.json").path))
}

@Test(arguments: [14.0, 16.0])
func claudeCredentialRenewsWithinFifteenMinutesButNotEarlier(minutesLeft: Double) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = try AccountStore(root: root)
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    try store.prepare(id)
    try store.enableDurableClaudeAccess(id)
    let expiry = Date().addingTimeInterval(minutesLeft * 60).timeIntervalSince1970 * 1000
    let fixture = AuthFixture([id: oauth("still-valid", expiry: expiry)])
    let auth = ClaudeAuth(store: store, read: { try await fixture.read($0) }, renew: { try await fixture.renew($0, $1) })
    #expect(try await auth.credential(id).accessToken == (minutesLeft == 14 ? "renewed" : "still-valid"))
    #expect(try await auth.credential(id).accessToken == (minutesLeft == 14 ? "renewed" : "still-valid"))
    #expect(await fixture.renewals == (minutesLeft == 14 ? 1 : 0))
}

@Test func uncertainClaudeRenewalIsNotReplayedAfterRelaunch() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = try AccountStore(root: root)
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    try store.prepare(id)
    try store.enableDurableClaudeAccess(id)
    let fixture = AuthFixture([id: oauth("expired")], persist: false)
    for _ in 0..<2 {
        let auth = ClaudeAuth(store: store, read: { try await fixture.read($0) }, renew: { try await fixture.renew($0, $1) })
        await #expect(throws: MonitorError.renewalUnconfirmed) { try await auth.credential(id) }
    }
    #expect(await fixture.renewals == 1)
    let journal = try Data(contentsOf: store.profile(id).appendingPathComponent("renewal.json"))
    #expect(!String(decoding: journal, as: UTF8.self).contains("fixture-refresh"))
}

@Test func claudeRenewalUsesPersistedCredentialsEvenIfHelperReportsFailure() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = try AccountStore(root: root)
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    try store.prepare(id)
    try store.enableDurableClaudeAccess(id)
    let fixture = AuthFixture([id: oauth("expired")], failAfterSave: true)
    let auth = ClaudeAuth(store: store, read: { try await fixture.read($0) }, renew: { try await fixture.renew($0, $1) })
    #expect(try await auth.credential(id).accessToken == "renewed")
    #expect(await fixture.renewals == 1)
}

@Test(arguments: [false, true])
func malformedOrUnreadableClaudeRenewalReceiptFailsClosedBeforeExchange(unreadable: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = try AccountStore(root: root)
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    try store.prepare(id)
    try store.enableDurableClaudeAccess(id)
    let receipt = store.profile(id).appendingPathComponent("renewal.json")
    try Data("incomplete receipt".utf8).write(to: receipt)
    if unreadable { try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: receipt.path) }
    let fixture = AuthFixture([id: oauth("expired")])
    let auth = ClaudeAuth(store: store, read: { try await fixture.read($0) }, renew: { try await fixture.renew($0, $1) })
    await #expect(throws: MonitorError.renewalUnconfirmed) { try await auth.credential(id) }
    #expect(await fixture.renewals == 0)
}

@Test func missingClaudeHelperDoesNotSpendOrQuarantineTheRefreshToken() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = try AccountStore(root: root)
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    try store.prepare(id)
    try store.enableDurableClaudeAccess(id)
    let fixture = AuthFixture([id: oauth("expired")])
    let auth = ClaudeAuth(store: store, read: { try await fixture.read($0) }, renew: { _, _ in throw MonitorError.helperMissing })
    await #expect(throws: MonitorError.helperMissing) { try await auth.credential(id) }
    #expect(!FileManager.default.fileExists(atPath: store.profile(id).appendingPathComponent("renewal.json").path))
}

@Test func legacyClaudeAccessDoesNotStartReplacementLoginWithoutDurableConsent() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = try AccountStore(root: root)
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    try store.prepare(id)
    let fixture = AuthFixture([id: oauth("expired")])
    let auth = ClaudeAuth(store: store, read: { try await fixture.read($0) }, renew: { try await fixture.renew($0, $1) })
    await #expect(throws: MonitorError.keychainUnavailable) { try await auth.credential(id) }
    #expect(await fixture.renewals == 0)
    #expect(!FileManager.default.fileExists(atPath: store.profile(id).appendingPathComponent("renewal.json").path))
}

@Test func claudeCredentialLeaseExcludesLoginRemovalAndOtherProcessesForOnlyOneAccount() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = try AccountStore(root: root)
    defer { try? FileManager.default.removeItem(at: root) }
    let a = UUID(), b = UUID()
    try store.prepare(a); try store.prepare(b)
    let lease = try store.claudeLease(a)
    withExtendedLifetime(lease) {
        #expect(throws: MonitorError.loginBusy) { try store.claudeLease(a) }
        #expect(throws: MonitorError.loginBusy) { try store.deleteProfile(a) }
        #expect(throws: Never.self) { _ = try store.claudeLease(b) }
    }
}

@Test func rejectedClaudeBearerRenewsOnceButRateLimitsNeverRenew() async throws {
    let id = UUID()
    let fixture = HTTPAuthFixture()
    let client = ClaudeClient(credentials: { _ in try Credential.decode(oauth("old", expiry: 4_000_000_000_000)) },
        renew: { account, rejected in
            #expect(account == id); #expect(rejected == "old")
            await fixture.renew()
            return try Credential.decode(oauth("new", expiry: 4_000_000_000_000))
        }, send: { await fixture.send($0) })
    await #expect(throws: MonitorError.http(401)) { try await client.fetch(id) }
    #expect(await fixture.renewals == 1)
    #expect(await fixture.tokens == ["Bearer old", "Bearer new"])
    await fixture.rateLimit()
    await #expect(throws: MonitorError.http(429)) { try await client.fetch(id) }
    #expect(await fixture.renewals == 1)
}

private actor HTTPAuthFixture {
    var renewals = 0
    var tokens: [String] = []
    var status = 401
    func renew() { renewals += 1 }
    func rateLimit() { status = 429 }
    func send(_ request: URLRequest) -> (Data, HTTPURLResponse) {
        tokens.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
        return (Data(), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
