import Foundation
import Testing
@testable import UsageMonitor

private func additionalHTTP(_ body: String) -> ProviderHTTP {
    ProviderHTTP(send: { request in
        (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    })
}

@Test func ampUnrecognizedCLIOutputFallsBackToSelectedTokenHTTP() async throws {
    let client = AdditionalClient(http: ProviderHTTP { request in
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer selected-fallback")
        let panel = request.url?.path.contains("/remote/") == true
        let body = Data(#"{"ok":true,"result":{"displayText":"Individual credits: $41.23 remaining"}}"#.utf8)
        return (panel ? Data() : body, HTTPURLResponse(url: request.url!, statusCode: panel ? 403 : 200, httpVersion: nil, headerFields: nil)!)
    }, ampUsage: { token in
        #expect(token == "selected-fallback")
        return "new unrecognized CLI format"
    })
    let snapshot = try await client.fetch(.init(label: "", provider: .amp), secrets: .init(key: "selected-fallback"))
    #expect(snapshot.metrics.first?.value == 41.23)
}

@Test func ampKeepsAgentDollarsOrbHoursAndCreditsSeparate() async throws {
    let client = AdditionalClient(http: additionalHTTP(#"""
    {"ok":true,"result":{"displayText":"Signed in as test@example.test (Fixture team)\nAmp Megawatt Tier: agent usage $18.57 of $20 remaining, orb usage 732.8h of 750h a1.small orb hours remaining - period 2026-09-13 to 2026-10-13\nIndividual credits: $31.25 remaining"}}
    """#))
    let result = try await client.fetch(Account(label: "", provider: .amp), secrets: .init(key: "fixture-amp"))
    #expect(result.metrics.contains(.init(title: "Agent remaining", kind: .balance, value: 18.57, unit: "USD")))
    #expect(result.metrics.contains(.init(title: "Orb remaining", kind: .count, value: 732.8, unit: "a1.small hours")))
    #expect(result.metrics.contains(.init(title: "Individual credits", kind: .balance, value: 31.25, unit: "USD")))
    #expect(result.reportedEmail == "test@example.test")
    #expect(result.plan == "Megawatt")
    #expect(result.identity == nil) // Display metadata does not invent a stable owner ID.
    #expect(!result.metrics.contains { $0.title == "Provider-reported agent cap" })
    let missingOrb = try await AdditionalClient(http: additionalHTTP(#"{"ok":true,"result":{"displayText":"agent usage $55.02 of $600 remaining\nIndividual credits: $17 remaining"}}"#))
        .fetch(Account(label: "", provider: .amp), secrets: .init(key: "fixture-amp"))
    #expect(!missingOrb.metrics.contains { $0.kind == .cap && $0.unit == "USD" })
    #expect(missingOrb.metrics.first { $0.title == "Orb usage" }?.detail == "Unavailable — dashboard response not recognized")
    #expect(!missingOrb.metrics.contains { $0.title == "Orb" && $0.value != nil })
}

@Test(arguments: [401, 403, 429], [false, true])
func ampDashboardErrorsExplainMissingOrbWithoutDiscardingAgentOrExposingResponseText(_ status: Int, _ legacyStatus: Bool) async throws {
    let client = AdditionalClient(http: ProviderHTTP { request in
        let panel = request.url?.path.contains("/remote/") == true
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer selected-amp")
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        let error = legacyStatus ? """
            {"type":"error","status":\(status),"error":{"message":"private-provider-detail"}}
            """ : """
            {"type":"error","error":{"status":\(status),"message":"private-provider-detail"}}
            """
        let body = panel ? error : #"{"ok":true,"result":{"displayText":"agent usage $34.32 of $600 remaining"}}"#
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    })
    let result = try await client.fetch(.init(label: "", provider: .amp), secrets: .init(key: "selected-amp"))
    #expect(result.metrics.first { $0.title == "Agent remaining" }?.value == 34.32)
    #expect(result.metrics.first { $0.title == "Orb usage" }?.detail == "Unavailable — dashboard request failed (HTTP \(status))")
    #expect(!result.metrics.contains { ($0.detail ?? "").contains("private-provider-detail") })
}

@Test func ampDashboardRedirectExplainsMissingOrbWithoutExposingItsLocation() async throws {
    let panel = #"[{"redirect":1},"/sign-in?private-provider-detail"]"#
    let encoded = try JSONSerialization.data(withJSONObject: ["type": "result", "data": panel])
    let client = AdditionalClient(http: ProviderHTTP { request in
        (encoded, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }, ampUsage: { _ in "agent usage $34.32 of $600 remaining" })
    let result = try await client.fetch(.init(label: "", provider: .amp), secrets: .init(key: "selected-amp"))
    #expect(result.metrics.first { $0.title == "Agent remaining" }?.value == 34.32)
    #expect(result.metrics.first { $0.title == "Orb usage" }?.detail == "Unavailable — dashboard redirected")
    #expect(!result.metrics.contains { ($0.detail ?? "").contains("private-provider-detail") })
}

@Test func ampPartialDashboardDoesNotReplaceAWorkingCLIOrbReadingWithUnknown() async throws {
    let panel = #"[{"q":1},{"rjke8/getAccountSettingsPanelData/":2},{"v":3},{"user":4,"subscriptionUsageBuckets":6},{"email":5},"amp@example.test",{"general":7},{"percentRemaining":8},31]"#
    let encoded = try JSONSerialization.data(withJSONObject: ["type": "result", "data": panel])
    let client = AdditionalClient(http: ProviderHTTP { request in
        (encoded, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }, ampUsage: { _ in
        "Amp Gigawatt Tier: agent usage $34.32 of $600 remaining, orb usage 72h of 800h a1.small orb hours remaining"
    })
    let result = try await client.fetch(.init(label: "", provider: .amp), secrets: .init(key: "selected-amp"))
    #expect(result.metrics.first { $0.title == "Agent" }?.value == 31)
    #expect(result.metrics.first { $0.title == "Agent remaining" } == nil)
    #expect(result.metrics.first { $0.title == "Orb" }?.value == 9)
    #expect(result.metrics.first { $0.title == "Orb remaining" }?.value == 72)
    #expect(!result.metrics.contains { $0.title == "Orb usage" })
}

@Test(arguments: ["Subscription Gigawatt:", "Amp Gigawatt Subscription:"])
func ampLegacyFallbackPreservesIndependentPercentagesWithoutInventingDollarBalances(_ heading: String) async throws {
    let display = "Signed in as legacy@example.test\n\(heading) 19% other usage and 83% orb usage remaining - resets upon renewal in 4 days\nIndividual credits: $27.50 remaining"
    let body = try JSONSerialization.data(withJSONObject: ["ok": true, "result": ["displayText": display]])
    let client = AdditionalClient(http: ProviderHTTP { request in
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer selected-legacy")
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        let panel = request.url?.path.contains("/remote/") == true
        return (panel ? Data() : body, HTTPURLResponse(url: request.url!, statusCode: panel ? 403 : 200,
                                                       httpVersion: nil, headerFields: nil)!)
    })
    let result = try await client.fetch(.init(label: "", provider: .amp), secrets: .init(key: "selected-legacy"))
    #expect(result.reportedEmail == "legacy@example.test")
    #expect(result.plan == "Gigawatt")
    #expect(result.metrics.filter { $0.kind == .quota }.map(\.value) == [19, 83])
    #expect(result.metrics.allSatisfy { $0.resetsAt == nil }) // Rounded countdowns are not exact reset dates.
    #expect(result.metrics.filter { $0.kind == .balance }.map(\.value) == [27.5])
    #expect(!result.metrics.contains { $0.kind == .cap || $0.kind == .note || $0.kind == .count })
    #expect(result.identity == nil)
}

@Test func ampDashboardSuppliesEmailTierAndIndependentOrbQuotaForTheSelectedToken() async throws {
    // SvelteKit remote-query reference table. Each object's values are table indices;
    // Date's payload is inline, unlike ordinary object properties.
    let panel = #"""
    [{"_":1,"q":15},{"user":2,"subscription":4,"subscriptionUsageBuckets":8},
     {"email":3},"amp@example.test",{"planName":5,"periodEndAt":6,"status":17,"cancelAtPeriodEnd":18,"freeRenewalsRemaining":19,"payerCompatible":20},"Gigawatt",
     ["Date","2030-10-19T00:00:00.000Z"],null,{"general":9,"orb":11},
     {"percentRemaining":10},8.9,{"percentRemaining":12},57.3,null,null,
     {"rjke8/getAccountSettingsPanelData/":16},{"v":1},"active",false,0,true]
    """#
    let encoded = try JSONSerialization.data(withJSONObject: ["type": "result", "data": panel])
    let client = AdditionalClient(http: ProviderHTTP { request in
        #expect(request.url?.host == "ampcode.com")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer selected-amp")
        let body: Data
        if request.url?.path == "/_app/remote/rjke8/getAccountSettingsPanelData" {
            #expect(request.httpMethod == "GET")
            #expect(request.httpBody == nil)
            body = encoded
        } else {
            #expect(request.url?.path == "/api/internal")
            #expect(request.url?.query == "userDisplayBalanceInfo")
            #expect(request.httpMethod == "POST")
            body = Data(#"{"ok":true,"result":{"displayText":"agent usage $55.02 of $600 remaining\nIndividual credits: $17 remaining"}}"#.utf8)
        }
        return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    })
    let result = try await client.fetch(.init(label: "", provider: .amp), secrets: .init(key: "selected-amp"))
    #expect(result.reportedEmail == "amp@example.test")
    #expect(result.plan == "Gigawatt")
    #expect(result.metrics.first { $0.title == "Agent" }?.value == 8.9)
    #expect(result.metrics.first { $0.title == "Orb" }?.value == 57.3)
    #expect(result.metrics.filter { $0.kind == .quota }.allSatisfy { $0.resetsAt == Date(timeIntervalSince1970: 1918591200) })
    #expect(result.metrics.contains(.init(title: "Individual credits", kind: .balance, value: 17, unit: "USD")))
    #expect(!result.metrics.contains { $0.title == "Agent remaining" || $0.kind == .cap || $0.kind == .note })
}

@Test(arguments: ["renewing", "free-renewal", "ending", "inactive", "past", "incompatible-payer",
                  "missing-status", "missing-cancellation", "missing-payer", "missing-free-renewals",
                  "numeric-cancellation", "numeric-payer", "boolean-free-renewals"])
func ampResetDatesRequireEstablishedRenewalWithoutDiscardingOtherReadings(_ state: String) async throws {
    var nodes: [Any] = [
        ["q": 1], ["rjke8/getAccountSettingsPanelData/": 2], ["v": 3],
        ["user": 4, "subscription": 6, "subscriptionUsageBuckets": 13],
        ["email": 5], "amp@example.test",
        ["planName": 7, "periodEndAt": 8, "status": 9, "cancelAtPeriodEnd": 10,
         "freeRenewalsRemaining": 11, "payerCompatible": 12],
        "Gigawatt", ["Date", "2030-10-19T00:00:00.000Z"], "active", false, 0, true,
        ["general": 14, "orb": 15], ["percentRemaining": 16], ["percentRemaining": 17], 8.9, 57.3
    ]
    switch state {
    case "free-renewal": nodes[10] = true; nodes[11] = 1; nodes[12] = false
    case "ending": nodes[10] = true
    case "inactive": nodes[9] = "inactive"
    case "past": nodes[8] = ["Date", "2020-10-19T00:00:00.000Z"]
    case "incompatible-payer": nodes[12] = false
    case "missing-status": nodes[9] = NSNull()
    case "missing-cancellation": nodes[10] = NSNull()
    case "missing-payer": nodes[12] = NSNull()
    case "missing-free-renewals": nodes[10] = true; nodes[11] = NSNull()
    case "numeric-cancellation": nodes[10] = 0
    case "numeric-payer": nodes[12] = 1
    case "boolean-free-renewals": nodes[10] = true; nodes[11] = true
    default: break
    }
    let table = String(decoding: try JSONSerialization.data(withJSONObject: nodes), as: UTF8.self)
    let encoded = try JSONSerialization.data(withJSONObject: ["type": "result", "data": table])
    let client = AdditionalClient(http: ProviderHTTP { request in
        let body = request.url?.path.contains("/remote/") == true ? encoded :
            Data(#"{"ok":true,"result":{"displayText":"Individual credits: $17 remaining"}}"#.utf8)
        return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    })
    let result = try await client.fetch(.init(label: "", provider: .amp), secrets: .init(key: "fixture-amp"))
    let quotas = result.metrics.filter { $0.kind == .quota }
    let reset = ["renewing", "free-renewal"].contains(state) ? Date(timeIntervalSince1970: 1918591200) : nil
    #expect(quotas.count == 2)
    #expect(quotas.map(\.value) == [8.9, 57.3])
    #expect(quotas.allSatisfy { $0.resetsAt == reset })
    #expect(result.reportedEmail == "amp@example.test")
    #expect(result.plan == "Gigawatt")
    #expect(result.metrics.first { $0.kind == .balance }?.value == 17)
}

@Test(arguments: ["denied", "malformed", "invalid-values"])
func ampSupplementalFailurePreservesCreditsWithoutInventingDashboardValues(_ mode: String) async throws {
    let panel = #"[{"q":1},{"rjke8/getAccountSettingsPanelData/":2},{"v":3},{"user":4,"subscriptionUsageBuckets":6},{"email":5},"bad email",{"general":7,"orb":9},{"percentRemaining":8},true,{"percentRemaining":10},150]"#
    let encoded = try JSONSerialization.data(withJSONObject: ["type": "result", "data": mode == "malformed" ? #"[{"q":999}]"# : panel])
    let client = AdditionalClient(http: ProviderHTTP { request in
        let dashboard = request.url?.path.contains("/remote/") == true
        let body = dashboard ? encoded : Data(#"{"ok":true,"result":{"displayText":"Individual credits: $17 remaining"}}"#.utf8)
        return (body, HTTPURLResponse(url: request.url!, statusCode: dashboard && mode == "denied" ? 403 : 200, httpVersion: nil, headerFields: nil)!)
    })
    let result = try await client.fetch(.init(label: "", provider: .amp), secrets: .init(key: "selected"))
    #expect(result.reportedEmail == nil)
    #expect(result.metrics.first { $0.kind == .balance }?.value == 17)
    #expect(result.metrics.filter { $0.kind == .quota }.allSatisfy { $0.value == nil })
}

@Test func grokConvertsCentsButDoesNotInventASecondWindow() async throws {
    let balances: [(String, Double?)] = [
        (#"{"val":1446}"#, 14.46), (#"{"val":"1446"}"#, 14.46),
        (#"{"val":0}"#, 0), (#"{"val":"0"}"#, 0), ("{}", 0),
        ("", nil), ("null", nil), (#"{"val":null}"#, nil), (#"{"val":true}"#, nil),
        (#"{"other":0}"#, nil), (#"{"val":-1}"#, nil), (#"{"val":1.5}"#, nil),
        (#"{"val":"1446garbage"}"#, nil), (#"{"val":9007199254740993}"#, nil)
    ]
    for (balance, expected) in balances {
        let wallet = balance.isEmpty ? "" : ",\"prepaidBalance\":\(balance)"
        let client = AdditionalClient(http: ProviderHTTP { request in
            let body = request.url?.path == "/v1/user" ? #"{"userId":"fixture-person"}"# : """
            {"subscription_tier":"SuperGrok","config":{"creditUsagePercent":6,"currentPeriod":{"start":"2026-10-01T00:00:00Z","end":"2026-11-01T00:00:00Z"}\(wallet)}}
            """
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let result = try await client.fetch(Account(label: "", provider: .grok), secrets: .init(key: "fixture-grok"))
        #expect(result.metrics.filter { $0.kind == .quota }.count == 1)
        #expect(result.metrics.first?.value == 94)
        #expect(result.metrics.first?.title == "Credit period")
        #expect(result.metrics.first(where: { $0.kind == .balance })?.value == expected)
        #expect(result.metrics.first(where: { $0.kind == .balance })?.unit == "USD")
    }
}

@Test func cursorExhaustedEntitlementStillShowsZeroAndTrialHasNoRecurringReset() async throws {
    let account = Account(label: "", provider: .cursor)
    let secrets = ConnectionSecrets(key: "WorkosCursorSessionToken=fixture")
    let paid = try await AdditionalClient(http: additionalHTTP("""
    {"usagePercent":100,"includedLimitZero":false,"hasAvailableUsage":false,"nextResetTimestampUtc":"2030-10-16T04:00:00Z"}
    """)).fetch(account, secrets: secrets)
    #expect(paid.metrics.first?.value == 0)
    #expect(paid.metrics.first?.resetsAt != nil)
    let trial = try await AdditionalClient(http: additionalHTTP("""
    {"usagePercent":42,"includedLimitZero":true,"sandTrialExpiresAt":"2030-10-20T00:00:00Z","nextResetTimestampUtc":"2030-10-16T04:00:00Z"}
    """)).fetch(account, secrets: secrets)
    #expect(trial.metrics.first?.value == 58)
    #expect(trial.metrics.first?.resetsAt == nil)
}

@Test func extraAPIsPreserveUnitsWithoutReplacingBalancesWithSpend() async throws {
    for (provider, body, title, value, unit) in [
        (Provider.serpAPI, "{\"total_searches_left\":250,\"this_month_usage\":17,\"searches_per_month\":100}", "Searches remaining", 250.0, "searches"),
        (.you, "{\"data\":{\"id\":\"you-account\",\"attributes\":{\"balance\":718924.5}}}", "Credits remaining", 7189.245, "USD"),
        (.parallel, "{\"org_id\":\"org\",\"credit_balance_cents\":1234,\"pending_debit_balance_cents\":217,\"will_invoice\":false}", "Prepaid balance", 12.34, "USD"),
        (.valyu, "{\"credit_balance_usd\":42.18,\"payg_usage_usd\":7.82,\"will_invoice\":false}", "Credits remaining", 42.18, "USD"),
        (.tavily, "{\"account\":{\"plan_usage\":19,\"plan_limit\":120},\"key\":{\"usage\":7,\"limit\":null}}", "Plan credits remaining", 101.0, "credits"),
        (.exa, "{\"api_key_id\":\"key_1\",\"team_id\":\"team_1\",\"total_cost_usd\":45.67,\"period\":{\"start\":\"2026-09-13T00:00:00Z\",\"end\":\"2026-10-13T00:00:00Z\"}}", "API key spend", 45.67, "USD")
    ] {
        let result = try await AdditionalClient(http: additionalHTTP(body)).fetch(
            Account(label: "", provider: provider, options: ["keyID": "key_1"]), secrets: .init(key: "fixture-key"))
        let metric = try #require(result.metrics.first(where: { $0.title == title }))
        #expect(metric.value == value)
        #expect(metric.unit == unit)
    }
    let postpaid = try await AdditionalClient(http: additionalHTTP("{\"org_id\":\"org\",\"credit_balance_cents\":0,\"pending_debit_balance_cents\":0,\"will_invoice\":true}"))
        .fetch(Account(label: "", provider: .parallel), secrets: .init(key: "fixture"))
    #expect(!postpaid.metrics.contains(where: { $0.kind == .balance && $0.value == 0 }))
}

@Test func malformedAdditionalResponsesCannotLookLikeZeroUsage() async throws {
    for provider in [Provider.amp, .grok, .cursor, .serpAPI, .you, .parallel, .valyu, .tavily, .exa] {
        await #expect(throws: MonitorError.invalidResponse) {
            try await AdditionalClient(http: additionalHTTP("{}")).fetch(
                Account(label: "", provider: provider, options: ["keyID": "key_1"]),
                secrets: .init(key: provider == .cursor ? "WorkosCursorSessionToken=fixture" : "fixture"))
        }
    }
}

@Test func xaiBalanceUsesTheValidatedTeamAndNegatesTheCentsLedger() async throws {
    let team = "65c1e471-205f-4566-9c5a-07198bcdf4ce"
    let client = AdditionalClient(http: ProviderHTTP(send: { request in
        #expect(request.httpMethod == "GET")
        #expect(request.url?.host == "management-api.x.ai")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-management")
        let body: String
        if request.url?.path == "/auth/management-keys/validation" {
            body = "{\"scope\":\"SCOPE_TEAM\",\"scopeId\":\"\(team)\",\"name\":\"Headroom billing\"}"
        } else {
            #expect(request.url?.path == "/v1/billing/teams/\(team)/prepaid/balance")
            body = "{\"total\":{\"val\":\"-1446\"},\"changes\":[]}"
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }))
    let snapshot = try await client.fetch(Account(label: "", provider: .xaiAPI), secrets: .init(key: "fixture-management"))
    #expect(snapshot.identity?.organizationID == team)
    #expect(snapshot.identity?.name == "Headroom billing")
    #expect(Account(label: "", identity: snapshot.identity, provider: .xaiAPI).displayName == "Headroom billing")
    let unnamed = Account(label: "", identity: .init(accountID: team, organizationID: team, email: ""), provider: .xaiAPI)
    #expect(unnamed.displayName == "API team · 8bcdf4ce")
    #expect(try JSONDecoder().decode(Account.self, from: JSONEncoder().encode(unnamed)).identity == unnamed.identity)
    #expect(snapshot.metrics == [.init(title: "Prepaid API balance", kind: .balance, value: 14.46, unit: "USD")])
    for body in ["{}", "{\"scope\":\"SCOPE_ORGANIZATION\",\"scopeId\":\"\(team)\"}",
                 "{\"scope\":\"SCOPE_TEAM\",\"scopeId\":\"../other\"}"] {
        await #expect(throws: MonitorError.invalidResponse) {
            try await AdditionalClient(http: additionalHTTP(body)).fetch(Account(label: "", provider: .xaiAPI), secrets: .init(key: "fixture"))
        }
    }
}

@Test func jinaReadsOnlyTheRootBalanceAndRejectsChangedText() async throws {
    let client = AdditionalClient(http: ProviderHTTP(send: { request in
        #expect(request.url?.absoluteString == "https://r.jina.ai/")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-jina")
        return (Data("[Balance left] 74123\n".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }))
    let snapshot = try await client.fetch(Account(label: "", provider: .jina), secrets: .init(key: "fixture-jina"))
    #expect(snapshot.metrics == [.init(title: "Tokens remaining", kind: .count, value: 74123, unit: "tokens")])
    await #expect(throws: MonitorError.unsupported("Jina's experimental balance response changed. Check the Jina dashboard.")) {
        try await AdditionalClient(http: additionalHTTP("Welcome to Jina Reader\n")).fetch(Account(label: "", provider: .jina), secrets: .init(key: "fixture"))
    }
}
