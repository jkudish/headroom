import Foundation
import Testing
@testable import UsageMonitor

@Suite struct SubscriptionClientTests {
    @Test func codexFetchUsesOnlyTheSelectedProfileAndBearerWorkspacePair() async throws {
        let store = try subscriptionStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let a = UUID(), b = UUID(), absent = UUID()
        let tokenA = try writeCodexAuth(store, a, workspace: "workspace-a", email: "alice@example.test")
        let tokenB = try writeCodexAuth(store, b, workspace: "workspace-b", email: "bob@example.test")
        let http = ProviderHTTP { request in
            let workspace = request.value(forHTTPHeaderField: "ChatGPT-Account-Id")
            let alice = workspace == "workspace-a"
            #expect(workspace == "workspace-a" || workspace == "workspace-b")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(alice ? tokenA : tokenB)")
            #expect(request.httpMethod == "GET")
            #expect(request.url?.host == "chatgpt.com")
            if request.url?.path == "/backend-api/accounts" {
                // The first/default workspace is deliberately not the selected one.
                return subscriptionResponse(request, """
                {"items":[{"id":"decoy","name":"Wrong"},{"id":"\(workspace!)","name":"\(alice ? "Alice team" : "Bob team")"}]}
                """)
            }
            #expect(request.url?.path == "/backend-api/wham/usage")
            return subscriptionResponse(request, """
            {"account_id":"\(workspace!)","rate_limit":{"primary_window":{"used_percent":\(alice ? 23.5 : 91),"limit_window_seconds":18000,"reset_at":1791909000}}}
            """)
        }
        let client = CodexClient(store: store, http: http)
        async let first = client.fetch(a)
        async let second = client.fetch(b)
        let (alice, bob) = try await (first, second)
        #expect(alice.identity?.accountID == "workspace-a")
        #expect(alice.identity?.organizationID == "workspace-a")
        #expect(alice.identity?.email == "alice@example.test")
        #expect(alice.identity?.name == "Alice team")
        #expect(alice.metrics.first?.value == 76.5)
        #expect(alice.metrics.first?.resetsAt == Date(timeIntervalSince1970: 1791909000))
        #expect(bob.identity?.accountID == "workspace-b")
        #expect(bob.identity?.email == "bob@example.test")
        #expect(bob.metrics.first?.value == 9)
        #expect(alice.metrics.count == 1)
        await #expect(throws: MonitorError.signInRequired) { try await client.fetch(absent) }
    }

    @Test func codexMissingProfileNeverSendsOrFallsBackToAmbientCredentials() async throws {
        let store = try subscriptionStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let id = UUID()
        try store.prepare(id)
        let http = ProviderHTTP { _ in
            Issue.record("A missing selected auth.json must never send a request")
            throw MonitorError.network
        }
        await #expect(throws: MonitorError.signInRequired) { try await CodexClient(store: store, http: http).fetch(id) }
    }

    @Test func codexHelperEnvironmentKeepsRealHomeButIsolatesCredentialsAndConfig() throws {
        let store = try subscriptionStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let a = UUID(), b = UUID()
        let first = try CodexAuth.environment(a, store: store)
        let second = try CodexAuth.environment(b, store: store)
        #expect(first["HOME"] == FileManager.default.homeDirectoryForCurrentUser.path)
        #expect(first["CODEX_HOME"] == store.profile(a).path)
        #expect(second["CODEX_HOME"] == store.profile(b).path)
        #expect(first["XDG_CONFIG_HOME"] != second["XDG_CONFIG_HOME"])
        #expect(first["OPENAI_API_KEY"] == nil)
        #expect(first["CODEX_ACCESS_TOKEN"] == nil)
        #expect(first["HTTP_PROXY"] == nil)
        #expect(CodexAuth.loginArguments == ["login", "--device-auth", "-c", "cli_auth_credentials_store=\"file\""])
    }

    @Test(arguments: ["symlink", "public-config"])
    func codexHelperCannotReadAnUnsafeConfig(_ scenario: String) throws {
        let store = try subscriptionStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let a = UUID(), b = UUID()
        try store.prepare(a)
        try store.prepare(b)
        let other = store.profile(b).appendingPathComponent("config.toml")
        try Data("cli_auth_credentials_store = \"keyring\"".utf8).write(to: other)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: other.path)
        let config = store.profile(a).appendingPathComponent("config.toml")
        if scenario == "symlink" {
            try FileManager.default.createSymbolicLink(at: config, withDestinationURL: other)
        } else {
            try Data("cli_auth_credentials_store = \"file\"".utf8).write(to: config)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: config.path)
        }
        #expect(throws: MonitorError.invalidProfile) { try CodexAuth.environment(a, store: store) }
    }

    @Test(arguments: ["file-link", "directory-link", "public-file", "hard-link"])
    func codexRejectsUnsafeCredentialPathsBeforeSending(_ scenario: String) async throws {
        let store = try subscriptionStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let a = UUID(), b = UUID()
        _ = try writeCodexAuth(store, a, workspace: "a", email: "a@example.test")
        _ = try writeCodexAuth(store, b, workspace: "b", email: "b@example.test")
        let target = store.profile(a).appendingPathComponent("auth.json")
        let other = store.profile(b).appendingPathComponent("auth.json")
        switch scenario {
        case "directory-link":
            try FileManager.default.removeItem(at: store.profile(a))
            try FileManager.default.createSymbolicLink(at: store.profile(a), withDestinationURL: store.profile(b))
        case "public-file":
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
        case "hard-link":
            try FileManager.default.removeItem(at: target)
            try FileManager.default.linkItem(at: other, to: target)
        default:
            try FileManager.default.removeItem(at: target)
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: other)
        }
        let http = ProviderHTTP { _ in
            Issue.record("Unsafe credentials must not leave the process")
            throw MonitorError.network
        }
        await #expect(throws: MonitorError.invalidProfile) { try await CodexClient(store: store, http: http).fetch(a) }
        #expect(throws: MonitorError.invalidProfile) { try CodexAuth.environment(a, store: store) }
    }

    @Test(arguments: ["expired", "no-expiry", "wrong-workspace", "no-workspace", "bad-jwt", "api-key"])
    func codexRejectsUnusableTokensWithoutRefreshing(_ scenario: String) async throws {
        let store = try subscriptionStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let id = UUID()
        let expiry: Double? = scenario == "no-expiry" ? nil : scenario == "expired" ? 1 : 4102444800
        _ = try writeCodexAuth(store, id, workspace: "selected", email: "person@example.test", expiry: expiry,
                              claimWorkspace: scenario == "wrong-workspace" ? "other" : scenario == "no-workspace" ? "" : nil,
                              mode: scenario)
        let http = ProviderHTTP { _ in
            Issue.record("Invalid auth must not send usage or token-refresh requests")
            throw MonitorError.network
        }
        let expected: MonitorError = scenario == "wrong-workspace" ? .identityChanged : .signInRequired
        await #expect(throws: expected) { try await CodexClient(store: store, http: http).fetch(id) }
    }

    @Test func codexMapsMissingWindowsAndOpaqueCreditsWithoutInventingDollars() async throws {
        let store = try subscriptionStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let id = UUID()
        _ = try writeCodexAuth(store, id, workspace: "selected", email: "person@example.test")
        let http = ProviderHTTP { request in
            if request.url?.lastPathComponent == "accounts" { return subscriptionResponse(request, "", status: 404) }
            return subscriptionResponse(request, """
            {"account_id":"selected","rate_limit":{"primary_window":null,
             "secondary_window":{"used_percent":68,"limit_window_seconds":604800,"reset_at":1792342800}},
             "credits":{"has_credits":true,"unlimited":false,"balance":"1234.5"},
             "spend_control":{"individual_limit":{"limit":100000,"used":"7761","remaining_percent":92.239,"reset_at":1792342800}}}
            """)
        }
        let result = try await CodexClient(store: store, http: http).fetch(id)
        #expect(result.metrics.filter { $0.kind == .quota }.map(\.value) == [32, 92.239])
        #expect(result.metrics.first?.resetsAt == Date(timeIntervalSince1970: 1792342800))
        #expect(result.metrics.first { $0.kind == .balance }?.value == 1234.5)
        #expect(result.metrics.first { $0.kind == .spend }?.value == 7761)
        #expect(result.metrics.first { $0.kind == .cap }?.value == 100000)
        #expect(result.metrics.filter { $0.kind != .quota }.allSatisfy { $0.unit == "credits" })
    }

    @Test func subscriptionsDoNotTurnAbsentQuotaWindowsIntoFullMeters() async throws {
        let store = try subscriptionStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let id = UUID()
        _ = try writeCodexAuth(store, id, workspace: "selected", email: "person@example.test")
        let codex = try await CodexClient(store: store, http: ProviderHTTP { request in
            if request.url?.lastPathComponent == "accounts" { return subscriptionResponse(request, "", status: 404) }
            return subscriptionResponse(request, "{\"rate_limit\":{\"primary_window\":null,\"secondary_window\":null}}")
        }).fetch(id)
        let zai = try await ZaiClient(http: ProviderHTTP { request in
            subscriptionResponse(request, "{\"code\":200,\"success\":true,\"data\":{\"limits\":[]}}")
        }).fetch(.init(label: "", provider: .zai), secrets: .init(key: "selected"))
        #expect(codex.metrics.allSatisfy { $0.value == nil && $0.kind == .note })
        #expect(zai.metrics.allSatisfy { $0.value == nil && $0.kind == .note })
    }

    @Test(arguments: ["{}", "{\"account_id\":\"wrong\",\"rate_limit\":{}}",
                      "{\"rate_limit\":{\"primary_window\":{\"used_percent\":101}}}",
                      "{\"rate_limit\":{\"primary_window\":{\"used_percent\":\"secret-body\"}}}"])
    func codexRejectsMalformedUsageOrResponseIdentity(_ body: String) async throws {
        let store = try subscriptionStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let id = UUID()
        _ = try writeCodexAuth(store, id, workspace: "selected", email: "person@example.test")
        let client = CodexClient(store: store, http: ProviderHTTP { request in subscriptionResponse(request, body) })
        await #expect(throws: body.contains("wrong") ? MonitorError.identityChanged : .invalidResponse) {
            try await client.fetch(id)
        }
    }

    @Test func zaiUsesSelectedKeyAndAllowlistedRegionWithReturnedPeriodsAndMillisecondResets() async throws {
        let first = Account(label: "Global", provider: .zai, options: ["region": "global"])
        let second = Account(label: "CN", provider: .zai, options: ["region": "cn"])
        let client = ZaiClient(http: ProviderHTTP { request in
            let global = request.url?.host == "api.z.ai"
            #expect(request.url?.host == "api.z.ai" || request.url?.host == "open.bigmodel.cn")
            #expect(request.url?.path == "/api/monitor/usage/quota/limit")
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(global ? "global-key" : "cn-key")")
            return subscriptionResponse(request, """
            {"code":200,"success":true,"data":{"limits":[
             {"type":"TOKENS_LIMIT","unit":3,"number":2,"percentage":\(global ? 23 : 81),"nextResetTime":1791909000123},
             {"type":"TOKENS_LIMIT","unit":6,"number":2,"percentage":68},
             {"type":"TIME_LIMIT","unit":5,"number":1,"percentage":44}
            ]}}
            """)
        })
        async let a = client.fetch(first, secrets: .init(key: "global-key"))
        async let b = client.fetch(second, secrets: .init(key: "cn-key"))
        let (global, cn) = try await (a, b)
        #expect(global.identity == nil)
        #expect(global.metrics.map(\.value) == [77, 32, 56])
        #expect(cn.metrics.first?.value == 19)
        #expect(global.metrics.map(\.title) == ["Tokens (2 hours)", "Tokens (2 weeks)", "MCP (monthly)"])
        #expect(global.metrics.first?.resetsAt == Date(timeIntervalSince1970: 1791909000.123))
        #expect(global.metrics[1].resetsAt == nil)
        #expect(global.metrics.allSatisfy { $0.kind == .quota })
    }

    @Test func zaiUsesCountsConservativelyAndPreservesUnknownPeriodsWithoutInventingWindows() async throws {
        let client = ZaiClient(http: ProviderHTTP { request in
            subscriptionResponse(request, """
            {"code":200,"success":true,"data":{"limits":[
             {"type":"CREDIT_LIMIT","unit":3,"number":4,"percentage":10,"usage":1000,"currentValue":233,"remaining":700},
             {"type":"TOKENS_LIMIT","unit":99,"number":9,"percentage":37},
             {"type":"FUTURE_LIMIT","unit":3,"number":5,"percentage":90}
            ]}}
            """)
        })
        let result = try await client.fetch(.init(label: "", provider: .zai), secrets: .init(key: "selected"))
        #expect(result.metrics.map(\.value) == [70, 63])
        #expect(result.metrics[1].title == "Tokens (period unavailable)")
        #expect(result.metrics[1].detail?.contains("unit 99") == true)
        #expect(result.metrics.allSatisfy { $0.resetsAt == nil })
    }

    @Test(arguments: ["", "\nkey", "key\r\nInjected: true"])
    func zaiMissingOrUnsafeKeysNeverSend(_ key: String) async throws {
        let client = ZaiClient(http: ProviderHTTP { _ in
            Issue.record("Missing/unsafe credentials must not leave the process")
            throw MonitorError.network
        })
        await #expect(throws: MonitorError.signInRequired) {
            try await client.fetch(.init(label: "", provider: .zai), secrets: .init(key: key))
        }
    }

    @Test func zaiArbitraryRegionsCannotRedirectTheSelectedKey() async throws {
        let client = ZaiClient(http: ProviderHTTP { _ in
            Issue.record("An unsupported region must not send credentials")
            throw MonitorError.network
        })
        await #expect(throws: MonitorError.invalidProfile) {
            try await client.fetch(.init(label: "", provider: .zai, options: ["region": "https://attacker.test"]),
                                   secrets: .init(key: "selected"))
        }
    }

    @Test(arguments: ["{}", "{\"code\":200,\"success\":false,\"msg\":\"secret-body\",\"data\":{\"limits\":[]}}",
                      "{\"code\":200,\"success\":true,\"data\":{\"limits\":[{\"type\":\"TOKENS_LIMIT\",\"unit\":3,\"number\":5,\"percentage\":-1}]}}",
                      "{\"code\":200,\"success\":true,\"data\":{\"limits\":[{\"type\":\"TOKENS_LIMIT\",\"unit\":3,\"number\":5,\"percentage\":\"secret-body\"}]}}"])
    func zaiMalformedResponsesAreSafeErrors(_ body: String) async throws {
        let client = ZaiClient(http: ProviderHTTP { request in subscriptionResponse(request, body) })
        await #expect(throws: MonitorError.invalidResponse) {
            try await client.fetch(.init(label: "", provider: .zai), secrets: .init(key: "selected"))
        }
    }

    @Test(arguments: [401, 403, 429, 500])
    func subscriptionErrorsNeverSurfaceRawBodies(_ status: Int) async throws {
        let store = try subscriptionStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let id = UUID()
        _ = try writeCodexAuth(store, id, workspace: "selected", email: "person@example.test")
        let http = ProviderHTTP { request in subscriptionResponse(request, "secret-body", status: status) }
        await #expect(throws: MonitorError.http(status)) { try await CodexClient(store: store, http: http).fetch(id) }
        await #expect(throws: MonitorError.http(status)) {
            try await ZaiClient(http: http).fetch(.init(label: "", provider: .zai), secrets: .init(key: "selected"))
        }
        #expect(!MonitorError.http(status).localizedDescription.contains("secret-body"))
    }
}

private func subscriptionStore() throws -> AccountStore {
    try AccountStore(root: FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent(UUID().uuidString))
}

private func subscriptionResponse(_ request: URLRequest, _ body: String, status: Int = 200) -> (Data, HTTPURLResponse) {
    (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
}

private func fixtureJWT(_ claims: [String: Any]) throws -> String {
    let payload = try JSONSerialization.data(withJSONObject: claims).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "eyJhbGciOiJub25lIn0.\(payload).fixture-signature"
}

@discardableResult
private func writeCodexAuth(_ store: AccountStore, _ id: UUID, workspace: String, email: String,
                            expiry: Double? = 4102444800, claimWorkspace: String? = nil, mode: String = "") throws -> String {
    try store.prepare(id)
    var claims: [String: Any] = [
        "https://api.openai.com/auth": ["chatgpt_account_id": claimWorkspace ?? workspace,
                                      "chatgpt_user_id": "person-not-workspace",
                                      "organizations": [["id": "decoy", "is_default": true], ["id": workspace]]],
        "https://api.openai.com/profile": ["email": email]
    ]
    if let expiry { claims["exp"] = expiry }
    let token = mode == "bad-jwt" ? "not-a-jwt" : try fixtureJWT(claims)
    let root: [String: Any] = mode == "api-key" ? ["OPENAI_API_KEY": "fixture-key"] : [
        "tokens": ["access_token": token, "id_token": token, "refresh_token": "unused-fixture", "account_id": workspace]
    ]
    let file = store.profile(id).appendingPathComponent("auth.json")
    try JSONSerialization.data(withJSONObject: root).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    return token
}
