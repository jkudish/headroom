import Foundation
import Testing
@testable import UsageMonitor

private func billingHTTP(_ body: String, status: Int = 200,
                         check: @escaping @Sendable (URLRequest) throws -> Void = { _ in }) -> ProviderHTTP {
    ProviderHTTP { request in
        try check(request)
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status,
                                               httpVersion: nil, headerFields: nil)!)
    }
}

private func metric(_ snapshot: UsageSnapshot, _ title: String) throws -> UsageMetric {
    try #require(snapshot.metrics.first { $0.title == title })
}

private actor BillingRequests {
    var requests: [URLRequest] = []
    func record(_ request: URLRequest) { requests.append(request) }
}

@Test func openRouterWalletUsesPurchasedMinusUsedWithoutAssumingIdentity() async throws {
    let client = BillingClient(http: billingHTTP(#"{"data":{"total_credits":103.75,"total_usage":28.5}}"#) { request in
        #expect(request.url?.absoluteString == "https://openrouter.ai/api/v1/credits")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-management")
    })
    let result = try await client.fetch(Account(label: "", provider: .openRouter), secrets: .init(key: "fixture-management"))
    #expect(result.identity == nil)
    #expect(try metric(result, "Wallet balance").value == 75.25)
    #expect(try metric(result, "Credits used").kind == .spend)
    #expect(!result.metrics.contains { $0.kind == .quota })
}

@Test func openRouterKeyModeKeepsKeyCapsSeparateFromWallet() async throws {
    let client = BillingClient(http: billingHTTP(#"{"data":{"usage":28.5,"usage_monthly":3.75,"limit":80,"limit_remaining":51.5,"creator_user_id":"user-7","organization_id":"org-2"}}"#) { request in
        #expect(request.url?.path == "/api/v1/key")
    })
    let result = try await client.fetch(Account(label: "", provider: .openRouter, options: ["mode": "key"]), secrets: .init(key: "fixture-key"))
    #expect(result.identity?.accountID == "user-7")
    #expect(try metric(result, "Key cap").value == 80)
    #expect(try metric(result, "Key remaining cap").value == 51.5)
    #expect(try metric(result, "Monthly key spend").value == 3.75)
    #expect(try metric(result, "Wallet balance").kind == .note)
}

@Test func searchAPIUsesBearerAndRemainingPercentWithReset() async throws {
    let client = BillingClient(http: billingHTTP(#"{"account":{"current_month_usage":37,"monthly_allowance":200,"remaining_credits":163},"subscription":{"period_end":"2026-11-04T00:34:59Z"}}"#) { request in
        #expect(request.url?.absoluteString == "https://www.searchapi.io/api/v1/me")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-search")
    })
    let result = try await client.fetch(Account(label: "", provider: .searchAPI), secrets: .init(key: "fixture-search"))
    #expect(try metric(result, "Search quota").value == 81.5)
    #expect(try metric(result, "Search quota").resetsAt != nil)
    #expect(try metric(result, "Searches used").value == 37)
    #expect(result.identity == nil)
}

@Test func dataForSEOUsesAPILoginAndPasswordAndUSD() async throws {
    let client = BillingClient(http: billingHTTP(#"{"status_code":20000,"tasks":[{"status_code":20000,"result":[{"login":"fixture-login","money":{"total":213.5,"balance":79.25}}]}]}"#) { request in
        #expect(request.url?.absoluteString == "https://api.dataforseo.com/v3/appendix/user_data")
        let auth = "Basic " + Data("fixture-login:fixture-password-42".utf8).base64EncodedString()
        #expect(request.value(forHTTPHeaderField: "Authorization") == auth)
    })
    let result = try await client.fetch(Account(label: "", provider: .dataForSEO), secrets: .init(key: "fixture-password-42", username: "fixture-login"))
    #expect(try metric(result, "Wallet balance").value == 79.25)
    #expect(try metric(result, "Credits used").value == 134.25)
    #expect(try metric(result, "Wallet balance").unit == "USD")
    #expect(result.identity == nil)
}

@Test func firecrawlDoesNotTurnExtraCreditsIntoMisleadingQuota() async throws {
    let client = BillingClient(http: billingHTTP(#"{"success":true,"data":{"remainingCredits":1300,"planCredits":1000,"billingPeriodEnd":"2026-11-01T00:00:00Z"}}"#) { request in
        #expect(request.url?.absoluteString == "https://api.firecrawl.dev/v2/team/credit-usage")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-firecrawl")
    })
    let result = try await client.fetch(Account(label: "", provider: .firecrawl), secrets: .init(key: "fixture-firecrawl"))
    #expect(try metric(result, "Credits remaining").value == 1300)
    #expect(try metric(result, "Plan credits").value == 1000)
    #expect(!result.metrics.contains { $0.kind == .quota })
}

@Test(arguments: [Provider.openRouter, .searchAPI, .firecrawl])
func missingBillingFieldsNeverBecomeZero(provider: Provider) async throws {
    let result = try await BillingClient(http: billingHTTP(#"{"data":{},"account":{}}"#))
        .fetch(Account(label: "", provider: provider), secrets: .init(key: "fixture"))
    #expect(result.metrics.allSatisfy { $0.value == nil })
}

@Test(arguments: [Provider.openAIAPI, .anthropicAPI])
func costReportsAggregateEveryPageAndKeepOneUTCRange(provider: Provider) async throws {
    let before = Date()
    let requests = BillingRequests()
    let client = BillingClient(http: ProviderHTTP { request in
        await requests.record(request)
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        let query = Dictionary(uniqueKeysWithValues: components.queryItems!.map { ($0.name, $0.value!) })
        #expect(request.httpMethod == "GET")
        #expect(!request.url!.absoluteString.contains("fixture-admin"))
        let second = query["page"] == "page/2+="
        let body: String
        if provider == .openAIAPI {
            #expect(components.host == "api.openai.com")
            #expect(components.path == "/v1/organization/costs")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-admin")
            #expect(request.value(forHTTPHeaderField: "OpenAI-Organization") == "org-fixture")
            let end = Double(query["end_time"]!)!
            #expect(end >= floor(before.timeIntervalSince1970))
            #expect(end <= Date().timeIntervalSince1970)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            #expect(Double(query["start_time"]!) == calendar.dateInterval(of: .month, for: before)!.start.timeIntervalSince1970)
            body = second ? #"{"data":[{"results":[{"amount":{"value":4.125,"currency":"usd"}}]}],"has_more":false,"next_page":null}"#
                : #"{"data":[{"results":[{"amount":{"value":12.75,"currency":"usd"}}]}],"has_more":true,"next_page":"page/2+="}"#
        } else {
            #expect(components.host == "api.anthropic.com")
            #expect(components.path == "/v1/organizations/cost_report")
            #expect(request.value(forHTTPHeaderField: "x-api-key") == "fixture-admin")
            #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
            #expect(query["starting_at"]?.hasSuffix("T00:00:00Z") == true)
            #expect(query["ending_at"] != nil)
            body = second ? #"{"data":[{"results":[{"amount":"412.5","currency":"USD"}]}],"has_more":false,"next_page":null}"#
                : #"{"data":[{"results":[{"amount":"1275","currency":"USD"}]}],"has_more":true,"next_page":"page/2+="}"#
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    })
    let result = try await client.fetch(Account(label: "", provider: provider, options: ["organizationID": "org-fixture"]), secrets: .init(key: "fixture-admin"))
    #expect(try metric(result, "Month-to-date spend").value == 16.875)
    #expect(try metric(result, "Wallet balance").kind == .note)
    #expect(result.identity == nil)
    let sent = await requests.requests
    #expect(sent.count == 2)
    let ranges = sent.map { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)!.queryItems!.filter { $0.name != "page" } }
    #expect(ranges[0] == ranges[1])
    if provider == .anthropicAPI {
        let query = Dictionary(uniqueKeysWithValues: ranges[0].map { ($0.name, $0.value!) })
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let formatter = ISO8601DateFormatter()
        #expect(query["starting_at"] == formatter.string(from: calendar.dateInterval(of: .month, for: result.fetchedAt)!.start))
        #expect(query["ending_at"] == formatter.string(from: result.fetchedAt))
    }
}

@Test(arguments: [Provider.openAIAPI, .anthropicAPI])
func incompleteOrLoopingCostsFailVisibly(provider: Provider) async throws {
    for cursor in ["null", "\"repeat\""] {
        let body = "{\"data\":[],\"has_more\":true,\"next_page\":\(cursor)}"
        await #expect(throws: MonitorError.invalidResponse) {
            try await BillingClient(http: billingHTTP(body)).fetch(Account(label: "", provider: provider), secrets: .init(key: "fixture"))
        }
    }
}

@Test(arguments: [Provider.openAIAPI, .anthropicAPI])
func missingCostAmountIsUnavailableNotPartialSpend(provider: Provider) async throws {
    let result = try await BillingClient(http: billingHTTP(#"{"data":[{"results":[{}]}],"has_more":false}"#))
        .fetch(Account(label: "", provider: provider), secrets: .init(key: "fixture"))
    #expect(try metric(result, "Month-to-date spend").value == nil)
}

@Test func providerErrorsNeverExposeResponseBodies() async throws {
    await #expect(throws: MonitorError.http(403)) {
        try await BillingClient(http: billingHTTP(#"{"error":"secret-echo"}"#, status: 403))
            .fetch(Account(label: "", provider: .openRouter), secrets: .init(key: "fixture"))
    }
    await #expect(throws: MonitorError.invalidResponse) {
        try await BillingClient(http: billingHTTP(#"{"status_code":40501,"status_message":"secret-echo","tasks":[]}"#))
            .fetch(Account(label: "", provider: .dataForSEO), secrets: .init(key: "fixture", username: "login"))
    }
}

@Test(arguments: ["123garbage", "1,234", "NaN", "", "1e999"])
func malformedAnthropicDecimalCostsStayUnavailable(amount: String) async throws {
    let body = "{\"data\":[{\"results\":[{\"amount\":\"\(amount)\",\"currency\":\"USD\"}]}],\"has_more\":false}"
    let result = try await BillingClient(http: billingHTTP(body))
        .fetch(Account(label: "", provider: .anthropicAPI), secrets: .init(key: "fixture"))
    #expect(try metric(result, "Month-to-date spend").value == nil)
}

@Test func missingDataForSEOMoneyAndBooleanValuesAreNotZero() async throws {
    let result = try await BillingClient(http: billingHTTP(#"{"status_code":20000,"tasks":[{"status_code":20000,"result":[{"money":{"balance":true}}]}]}"#))
        .fetch(Account(label: "", provider: .dataForSEO), secrets: .init(key: "fixture", username: "login"))
    #expect(result.metrics.allSatisfy { $0.value == nil })
}

@Test(arguments: [Provider.openAIAPI, .anthropicAPI])
func failedSecondCostPageNeverReturnsFirstPageTotal(provider: Provider) async throws {
    let client = BillingClient(http: ProviderHTTP { request in
        let second = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.contains { $0.name == "page" }
        let body = second ? #"{"error":"credential-echo"}"# : #"{"data":[],"has_more":true,"next_page":"https://evil.invalid/steal"}"#
        #expect(request.url?.host == (provider == .openAIAPI ? "api.openai.com" : "api.anthropic.com"))
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: second ? 403 : 200, httpVersion: nil, headerFields: nil)!)
    })
    await #expect(throws: MonitorError.http(403)) {
        try await client.fetch(Account(label: "", provider: provider), secrets: .init(key: "fixture"))
    }
}

@Test(arguments: [Provider.openAIAPI, .anthropicAPI])
func confirmedEmptyCostReportCanShowZero(provider: Provider) async throws {
    let result = try await BillingClient(http: billingHTTP(#"{"data":[{"results":[]}],"has_more":false,"next_page":null}"#))
        .fetch(Account(label: "", provider: provider), secrets: .init(key: "fixture"))
    #expect(try metric(result, "Month-to-date spend").value == 0)
}

@Test func invalidCredentialsAndModesFailBeforeTransport() async throws {
    let client = BillingClient(http: ProviderHTTP { _ in
        Issue.record("Invalid connection must not send a request")
        throw MonitorError.network
    })
    await #expect(throws: MonitorError.signInRequired) {
        try await client.fetch(Account(label: "", provider: .openRouter), secrets: .init(key: ""))
    }
    await #expect(throws: MonitorError.signInRequired) {
        try await client.fetch(Account(label: "", provider: .dataForSEO), secrets: .init(key: "password", username: "bad:login"))
    }
    await #expect(throws: MonitorError.invalidProfile) {
        try await client.fetch(Account(label: "", provider: .openRouter, options: ["mode": "https://evil.invalid"]), secrets: .init(key: "fixture"))
    }
}

@Test(arguments: [Provider.openAIAPI, .anthropicAPI])
func malformedPaginationCannotMasqueradeAsComplete(provider: Provider) async throws {
    await #expect(throws: MonitorError.invalidResponse) {
        try await BillingClient(http: billingHTTP(#"{"data":[],"has_more":false,"next_page":42}"#))
            .fetch(Account(label: "", provider: provider), secrets: .init(key: "fixture"))
    }
}
