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
            if request.url?.lastPathComponent == "rate-limit-reset-credits" {
                return subscriptionResponse(request, "", status: 404)
            }
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
        #expect(alice.identity?.accountID == "person-not-workspace")
        #expect(alice.identity?.organizationID == "workspace-a")
        #expect(alice.identity?.email == "alice@example.test")
        #expect(alice.identity?.name == "Alice team")
        #expect(alice.metrics.first?.value == 76.5)
        #expect(alice.metrics.first?.resetsAt == Date(timeIntervalSince1970: 1791909000))
        #expect(bob.identity?.accountID == "person-not-workspace")
        #expect(bob.identity?.organizationID == "workspace-b")
        #expect(bob.identity?.email == "bob@example.test")
        #expect(bob.metrics.first?.value == 9)
        #expect(alice.metrics.count == 1)
        await #expect(throws: MonitorError.signInRequired) { try await client.fetch(absent) }
    }

    @Test @MainActor func codexPeopleInOneWorkspaceStaySeparateAndCannotSwapAfterRestart() async throws {
        let store = try subscriptionStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let a = Account(label: "", provider: .codex), b = Account(label: "", provider: .codex)
        try store.save([a, b])
        let tokenA = try writeCodexAuth(store, a.id, workspace: "shared", email: "alice@example.test", humanID: "alice")
        _ = try writeCodexAuth(store, b.id, workspace: "shared", email: "bob@example.test", humanID: "bob")
        let client = CodexClient(store: store, http: ProviderHTTP { request in
            #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "shared")
            if request.url?.lastPathComponent == "accounts" { return subscriptionResponse(request, "", status: 404) }
            let alice = request.value(forHTTPHeaderField: "Authorization") == "Bearer \(tokenA)"
            return subscriptionResponse(request, "{\"rate_limit\":{\"primary_window\":{\"used_percent\":\(alice ? 19 : 83)}}}")
        })
        let monitor = try Monitor(store: store, fetch: { try await client.fetch($0) })
        await monitor.refresh(a.id)
        await monitor.refresh(b.id)
        #expect(monitor.entries.map { $0.snapshot?.metrics.first?.value } == [81, 17])
        #expect(try store.load().map { $0.identity?.accountID } == ["alice", "bob"])
        let restarted = try Monitor(store: store, fetch: { try await client.fetch($0) })
        _ = try writeCodexAuth(store, a.id, workspace: "shared", email: "bob@example.test", humanID: "bob")
        await restarted.refresh(a.id)
        #expect(restarted.entries[0].snapshot == nil)
        #expect(restarted.entries[0].error == MonitorError.identityChanged.localizedDescription)

        let missingHuman = try fixtureJWT([
            "exp": 4102444800, "https://api.openai.com/auth": ["chatgpt_account_id": "shared"],
            "https://api.openai.com/profile": ["email": "bob@example.test"]
        ])
        let auth = store.profile(a.id).appendingPathComponent("auth.json")
        try JSONSerialization.data(withJSONObject: ["tokens": [
            "access_token": missingHuman, "id_token": tokenA, "account_id": "shared"
        ]]).write(to: auth)
        await restarted.refresh(a.id)
        #expect(restarted.entries[0].snapshot == nil)
        #expect(restarted.entries[0].error == MonitorError.signInRequired.localizedDescription)
        #expect(try store.load()[0].identity?.accountID == "alice")

        await restarted.refresh(b.id)
        #expect(restarted.entries[1].snapshot?.metrics.first?.value == 17)
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

    @Test(arguments: ["expired", "no-expiry", "wrong-workspace", "no-workspace", "no-user", "bad-jwt", "api-key"])
    func codexRejectsUnusableTokensWithoutRefreshing(_ scenario: String) async throws {
        let store = try subscriptionStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let id = UUID()
        let expiry: Double? = scenario == "no-expiry" ? nil : scenario == "expired" ? 1 : 4102444800
        _ = try writeCodexAuth(store, id, workspace: "selected", email: "person@example.test", expiry: expiry,
                              claimWorkspace: scenario == "wrong-workspace" ? "other" : scenario == "no-workspace" ? "" : nil,
                              mode: scenario, humanID: scenario == "no-user" ? "" : "person-not-workspace")
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
            if request.url?.lastPathComponent == "rate-limit-reset-credits" {
                return subscriptionResponse(request, "", status: 403)
            }
            return subscriptionResponse(request, """
            {"account_id":"selected","rate_limit":{"primary_window":null,
             "secondary_window":{"used_percent":68,"limit_window_seconds":604800,"reset_at":1792342800}},
             "credits":{"has_credits":true,"unlimited":false,"balance":"1234.5"},
             "spend_control":{"individual_limit":{"limit":100000,"used":"7761","remaining_percent":92.239,"reset_at":1792342800}}}
            """)
        }
        let result = try await CodexClient(store: store, http: http).fetch(id)
        #expect(result.metrics.filter { $0.kind == .quota }.map(\.value) == [32, 92.239])
        #expect(result.metrics.first?.title == "Weekly")
        #expect(result.metrics.first?.resetsAt == Date(timeIntervalSince1970: 1792342800))
        #expect(result.metrics.first { $0.title == "Credit balance" }?.value == 1234.5)
        #expect(result.metrics.first { $0.kind == .spend }?.value == 7761)
        #expect(result.metrics.first { $0.kind == .cap }?.value == 100000)
        #expect(result.metrics.filter { $0.kind != .quota }.allSatisfy { $0.unit == "credits" })
    }

    @Test func codexDisplaysPlanCreditRemainingAndAccountScopedResetInventory() async throws {
        let store = try subscriptionStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let id = UUID()
        let token = try writeCodexAuth(store, id, workspace: "selected", email: "person@example.test")
        let client = CodexClient(store: store, http: ProviderHTTP { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
            #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "selected")
            #expect(request.httpMethod == "GET")
            if request.url?.lastPathComponent == "accounts" { return subscriptionResponse(request, "", status: 404) }
            if request.url?.lastPathComponent == "rate-limit-reset-credits" {
                #expect(request.value(forHTTPHeaderField: "OpenAI-Beta") == "codex-1")
                return subscriptionResponse(request, """
                {"available_count":3,"credits":[
                  {"id":"one","reset_type":"codex_rate_limits","status":"available","granted_at":"2026-10-13T21:00:00Z","expires_at":"2030-10-20T21:00:00.123Z","title":"One reset","description":"Resets Codex windows"},
                  {"id":"expired","reset_type":"codex_rate_limits","status":"available","expires_at":"2020-01-01T00:00:00Z"},
                  {"id":"used","reset_type":"codex_rate_limits","status":"redeemed","expires_at":"2030-10-15T21:00:00Z"}]}
                """)
            }
            return subscriptionResponse(request, """
            {"plan_type":"pro","rate_limit":{"secondary_window":{"used_percent":37,"limit_window_seconds":604800}},
             "individual_limit":{"limit":100000,"used":"50061.32","resets_at":1792342800},
             "credits":{"balance":"4321.75"}}
            """)
        })
        let snapshot = try await client.fetch(id)
        #expect(snapshot.plan == "Pro 200")
        #expect(snapshot.resetCredits?.availableCount == 3) // A partial list must not replace the reported count.
        #expect(snapshot.resetCredits?.expirations.count == 1)
        #expect(snapshot.resetCredits?.credits.map(\.id) == ["one", "expired", "used"])
        #expect(snapshot.resetCredits?.credits.first?.title == "One reset")
        #expect(snapshot.resetCredits?.credits.first?.description == "Resets Codex windows")
        #expect(snapshot.resetCredits?.credits.first?.grantedAt == Date(timeIntervalSince1970: 1791925200))
        #expect(snapshot.resetCredits?.credits.map(\.canUse) == [true, false, false])
        let left = try #require(snapshot.metrics.first { $0.title == "Credits left" }?.value)
        #expect(abs(left - 49938.68) < 0.000001)
        #expect(snapshot.metrics.first { $0.title == "Individual credit quota" }?.resetsAt == Date(timeIntervalSince1970: 1792342800))
        #expect(snapshot.metrics.first { $0.kind == .balance && $0.title == "Credit balance" }?.value == 4321.75)
    }

    @Test(arguments: ["{}", "{\"available_count\":-1,\"credits\":[]}",
                      "{\"available_count\":2,\"credits\":[{\"id\":\"x\",\"reset_type\":\"codex_rate_limits\",\"status\":\"available\",\"expires_at\":\"invalid\"}]}"])
    func codexBadSupplementDoesNotEraseGoodQuotas(_ body: String) async throws {
        let store = try subscriptionStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let id = UUID()
        _ = try writeCodexAuth(store, id, workspace: "selected", email: "person@example.test")
        let snapshot = try await CodexClient(store: store, http: ProviderHTTP { request in
            if request.url?.lastPathComponent == "accounts" { return subscriptionResponse(request, "", status: 404) }
            if request.url?.lastPathComponent == "rate-limit-reset-credits" { return subscriptionResponse(request, body) }
            return subscriptionResponse(request, "{\"plan_type\":\"future_plan\",\"rate_limit\":{\"primary_window\":{\"used_percent\":17}}}")
        }).fetch(id)
        #expect(snapshot.metrics.first?.value == 83)
        #expect(snapshot.plan == "future_plan")
        #expect(snapshot.resetCredits == nil)
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

    @Test(arguments: ["reset", "nothing_to_reset", "no_credit", "already_redeemed", "unknown", "malformed"])
    func codexResetUsesExplicitCreditAndBearerBoundHuman(_ result: String) async throws {
        let store = try subscriptionStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let owner = AccountIdentity(accountID: "alice", organizationID: "shared", email: "alice@example.test")
        let account = Account(label: "", identity: owner, provider: .codex)
        try store.save([account])
        let token = try writeCodexAuth(store, account.id, workspace: "shared", email: owner.email, humanID: "alice")
        let attempt = UUID()
        let client = CodexClient(store: store, http: ProviderHTTP { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
            #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "shared")
            #expect(request.value(forHTTPHeaderField: "OpenAI-Beta") == "codex-1")
            if request.httpMethod == "GET" { return subscriptionResponse(request, resetInventoryFixture) }
            #expect(request.url?.absoluteString == "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/consume")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            let payload = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: String])
            #expect(payload == ["credit_id": "selected-credit", "redeem_request_id": attempt.uuidString])
            return subscriptionResponse(request, result == "malformed" ? "{\"code\":\"reset\",\"windows_reset\":-1}" : "{\"code\":\"\(result)\"}")
        })
        if ["unknown", "malformed"].contains(result) {
            await #expect(throws: MonitorError.invalidResponse) { try await client.consumeReset(account, creditID: "selected-credit", requestID: attempt) }
        } else {
            let outcome = try await client.consumeReset(account, creditID: "selected-credit", requestID: attempt)
            #expect(outcome.code.rawValue == result)
            #expect(outcome.windowsReset == 0)
        }
        // Same workspace, different human: reject before even the inventory GET.
        _ = try writeCodexAuth(store, account.id, workspace: "shared", email: "bob@example.test", humanID: "bob")
        let denied = CodexClient(store: store, http: ProviderHTTP { _ in
            Issue.record("Changed owner must not send reset requests")
            throw MonitorError.network
        })
        await #expect(throws: MonitorError.identityChanged) { try await denied.consumeReset(account, creditID: "selected-credit", requestID: attempt) }
    }

    @Test @MainActor func resetRetryAfterRestartReusesAttemptAndNeverAnotherAccount() async throws {
        let store = try subscriptionStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let identity = AccountIdentity(accountID: "alice", organizationID: "shared", email: "alice@example.test")
        let account = Account(label: "", identity: identity, provider: .codex)
        try store.save([account])
        _ = try writeCodexAuth(store, account.id, workspace: "shared", email: identity.email, humanID: "alice")
        let ledger = ResetFixture()
        let client = CodexClient(store: store, http: ProviderHTTP { request in
            if request.httpMethod == "GET" { return subscriptionResponse(request, resetInventoryFixture) }
            return try await ledger.send(request)
        })
        let credit = LimitResetCredit(id: "selected-credit", resetType: "codex_rate_limits", status: "available",
                                    grantedAt: nil, expiresAt: nil, title: nil, description: nil)
        let snapshot = UsageSnapshot(identity: identity, metrics: [], resetCredits: .init(availableCount: 1, expirations: [], credits: [credit]))
        let monitor = try Monitor(store: store, fetch: { _ in snapshot }, consume: {
            try await client.consumeReset($0, creditID: $1, requestID: $2)
        })
        await monitor.refresh(account.id)
        await #expect(throws: MonitorError.network) { try await monitor.useReset(account.id, creditID: credit.id) }
        let restarted = try Monitor(store: store, fetch: { _ in snapshot }, consume: {
            try await client.consumeReset($0, creditID: $1, requestID: $2)
        })
        await restarted.refresh(account.id)
        let outcome = try await restarted.useReset(account.id, creditID: credit.id)
        #expect(outcome.code == .already_redeemed)
        let requests = await ledger.requests
        #expect(requests.count == 2)
        #expect(requests[0] == requests[1])
        #expect(requests[0]["credit_id"] == "selected-credit")
        #expect(UUID(uuidString: requests[0]["redeem_request_id"] ?? "") != nil)
        #expect(restarted.entries[0].resetting == false)
        await #expect(throws: MonitorError.invalidResponse) { try await restarted.useReset(UUID(), creditID: credit.id) }
        await #expect(throws: MonitorError.invalidResponse) { try await restarted.useReset(account.id, creditID: "not-in-inventory") }
        #expect(await ledger.requests.count == 2)
    }

    @Test(arguments: ["redeemed", "expired", "wrong-type", "absent"])
    func codexResetCannotUseUnavailableInventory(_ mode: String) async throws {
        let store = try subscriptionStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let account = Account(label: "", identity: .init(accountID: "alice", organizationID: "shared", email: "a@example.test"), provider: .codex)
        try store.save([account])
        _ = try writeCodexAuth(store, account.id, workspace: "shared", email: "a@example.test", humanID: "alice")
        let client = CodexClient(store: store, http: ProviderHTTP { request in
            #expect(request.httpMethod == "GET")
            let expiry = mode == "expired" ? "2020-01-01T00:00:00Z" : "2030-01-01T00:00:00Z"
            let list = mode == "absent" ? "[]" : "[{\"id\":\"selected-credit\",\"status\":\"\(mode == "redeemed" ? "redeemed" : "available")\",\"reset_type\":\"\(mode == "wrong-type" ? "other" : "codex_rate_limits")\",\"expires_at\":\"\(expiry)\"}]"
            return subscriptionResponse(request, "{\"available_count\":1,\"credits\":\(list)}")
        })
        await #expect(throws: MonitorError.invalidResponse) { try await client.consumeReset(account, creditID: "selected-credit", requestID: UUID()) }
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

private let resetInventoryFixture = #"{"available_count":1,"credits":[{"id":"decoy","reset_type":"other","status":"available"},{"id":"selected-credit","reset_type":"codex_rate_limits","status":"available"}]}"#

private actor ResetFixture {
    var requests: [[String: String]] = []
    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let payload = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: String])
        requests.append(payload)
        if requests.count == 1 { throw MonitorError.network } // A server success with a lost response is also possible.
        return subscriptionResponse(request, #"{"code":"already_redeemed","windows_reset":2}"#)
    }
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
                            expiry: Double? = 4102444800, claimWorkspace: String? = nil, mode: String = "",
                            humanID: String = "person-not-workspace") throws -> String {
    try store.prepare(id)
    var claims: [String: Any] = [
        "https://api.openai.com/auth": ["chatgpt_account_id": claimWorkspace ?? workspace,
                                      "chatgpt_user_id": humanID,
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
