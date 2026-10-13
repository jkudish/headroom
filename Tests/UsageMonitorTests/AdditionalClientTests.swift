import Foundation
import Testing
@testable import UsageMonitor

private func additionalHTTP(_ body: String) -> ProviderHTTP {
    ProviderHTTP(send: { request in
        (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    })
}

@Test func ampKeepsAgentDollarsOrbHoursAndCreditsSeparate() async throws {
    let client = AdditionalClient(http: additionalHTTP(#"""
    {"ok":true,"result":{"displayText":"Signed in as test@example.test\nAmp Megawatt Tier: agent usage $18.57 of $20 remaining, orb usage 732.8h of 750h a1.small orb hours remaining - period 2026-09-13 to 2026-10-13\nIndividual credits: $31.25 remaining"}}
    """#))
    let result = try await client.fetch(Account(label: "", provider: .amp), secrets: .init(key: "fixture-amp"))
    #expect(result.metrics.contains(.init(title: "Agent remaining", kind: .balance, value: 18.57, unit: "USD")))
    #expect(result.metrics.contains(.init(title: "Orb remaining", kind: .count, value: 732.8, unit: "a1.small hours")))
    #expect(result.metrics.contains(.init(title: "Individual credits", kind: .balance, value: 31.25, unit: "USD")))
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
        let client = AdditionalClient(http: additionalHTTP("""
        {"subscriptionTier":"SuperGrok","config":{"creditUsagePercent":6,"currentPeriod":{"start":"2026-10-01T00:00:00Z","end":"2026-11-01T00:00:00Z"}\(wallet)}}
        """))
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
            body = "{\"scope\":\"SCOPE_TEAM\",\"scopeId\":\"\(team)\"}"
        } else {
            #expect(request.url?.path == "/v1/billing/teams/\(team)/prepaid/balance")
            body = "{\"total\":{\"val\":\"-1446\"},\"changes\":[]}"
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }))
    let snapshot = try await client.fetch(Account(label: "", provider: .xaiAPI), secrets: .init(key: "fixture-management"))
    #expect(snapshot.identity?.organizationID == team)
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
