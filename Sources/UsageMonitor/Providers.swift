import Foundation

enum Provider: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude, codex, zai, openRouter, searchAPI, dataForSEO, firecrawl
    case openAIAPI, anthropicAPI, xaiAPI, amp, grok, cursor, serpAPI, tavily, jina, exa
    case parallel, brave, perplexity, valyu, gemini, you, kagi

    var id: String { rawValue }
    var title: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .zai: "z.ai Coding Plan"
        case .openRouter: "OpenRouter"
        case .searchAPI: "SearchAPI"
        case .dataForSEO: "DataForSEO"
        case .firecrawl: "Firecrawl"
        case .openAIAPI: "OpenAI API"
        case .anthropicAPI: "Anthropic API"
        case .xaiAPI: "xAI API"
        case .amp: "Amp"
        case .grok: "Grok / SuperGrok"
        case .cursor: "Cursor Grok Bot"
        case .serpAPI: "SerpAPI"
        case .tavily: "Tavily"
        case .jina: "Jina AI"
        case .exa: "Exa"
        case .parallel: "Parallel"
        case .brave: "Brave"
        case .perplexity: "Perplexity"
        case .valyu: "Valyu"
        case .gemini: "Gemini"
        case .you: "You.com"
        case .kagi: "Kagi"
        }
    }

    var usesHelper: Bool { self == .claude || self == .codex }
    var supportsRead: Bool { ![Self.brave, .perplexity, .gemini, .kagi].contains(self) }

    var connectionHelp: String {
        switch self {
        case .claude: "Sign in with Claude Code in any browser profile. This app keeps each account separate."
        case .codex: "Sign in with the official Codex helper. Use the browser profile for the account you want; your CLI login stays untouched."
        case .zai: "Use a Coding Plan API key. Choose the region where your plan is billed. Only quotas returned by z.ai are shown."
        case .openRouter: "Wallet mode requires a management key. API key mode shows key-level spend and caps, not your account wallet."
        case .searchAPI: "Use a SearchAPI key to read the account's monthly searches and remaining search credits."
        case .dataForSEO: "Use the API login and API password from API Access, not your website password. This account read is free."
        case .firecrawl: "Use a team API key. Remaining credits can include purchased or coupon credits beyond your plan allowance."
        case .openAIAPI: "Requires an organization Admin key. Shows month-to-date API spend. Wallet balance is not available from this API."
        case .anthropicAPI: "Requires an organization sk-ant-admin key. Individual accounts cannot use this Admin API. Shows API spend, not Claude subscription limits or wallet balance."
        case .xaiAPI: "Use a team-scoped xAI Management API key with billing read access. Shows the team's prepaid API balance, not SuperGrok limits. Promotional credits and API spend are not included."
        case .amp: "Paste an Amp access token from a separate account. Reads the private balance API for agent allowance, orb hours and credits when the plan reports them."
        case .grok: "Paste a SuperGrok OAuth access token from Grok's sign-in flow, not an xAI developer API key. Shows the reported credit period and prepaid credits; no separate 5-hour meter is established. Tokens may need manual renewal."
        case .cursor: "Paste a Cursor session Cookie header from the account you want. This is Cursor's Grok Bot allowance, not SuperGrok. The private endpoint can change."
        case .serpAPI: "Use a SerpAPI key. The account read is free and returns remaining searches. SerpAPI requires the key in its request query; the app never logs that URL."
        case .tavily: "Use a Tavily API key. Shows plan credits and separate key usage/caps for the current billing cycle."
        case .jina: "Experimental: paste a Jina API key. Reads the root balance response documented by Jina's maintainer. If its format changes, the app reports unavailable."
        case .exa: "Requires a Team Management service key and the ID of the API key to report. Exa must enable Team Management for your team. Shows key-level spend, not wallet balance."
        case .parallel: "Paste a Parallel Account API OAuth access token, not a standard search API key. Shows organization prepaid balance and pending charges separately."
        case .valyu: "Use a Valyu key with billing:read scope. Shows organization credits and pay-as-you-go usage in USD."
        case .brave, .perplexity, .gemini, .kagi: "Account billing is not connected yet. An independent read-only billing credential and endpoint have not been established. You can check the provider dashboard; no key will be collected."
        case .you: "Use a You.com API key with account balance access. The balance belongs to the individual or organization that owns the key."
        }
    }

    var dashboardURL: URL {
        let address: String
        switch self {
        case .claude: address = "https://claude.ai/settings/usage"
        case .codex: address = "https://chatgpt.com/codex/settings/usage"
        case .zai: address = "https://z.ai/manage-apikey/subscription"
        case .openRouter: address = "https://openrouter.ai/settings/credits"
        case .searchAPI: address = "https://www.searchapi.io/dashboard"
        case .dataForSEO: address = "https://app.dataforseo.com/api-access"
        case .firecrawl: address = "https://www.firecrawl.dev/app"
        case .openAIAPI: address = "https://platform.openai.com/usage"
        case .anthropicAPI: address = "https://platform.claude.com/settings/usage"
        case .xaiAPI: address = "https://console.x.ai/team/default/management-keys"
        case .amp: address = "https://ampcode.com/settings"
        case .grok: address = "https://grok.com/"
        case .cursor: address = "https://cursor.com/dashboard"
        case .serpAPI: address = "https://serpapi.com/dashboard"
        case .tavily: address = "https://app.tavily.com/"
        case .jina: address = "https://jina.ai/api-dashboard"
        case .exa: address = "https://dashboard.exa.ai/api-keys"
        case .parallel: address = "https://platform.parallel.ai/"
        case .brave: address = "https://api-dashboard.search.brave.com/"
        case .perplexity: address = "https://console.perplexity.ai/"
        case .valyu: address = "https://platform.valyu.ai/"
        case .gemini: address = "https://aistudio.google.com/usage"
        case .you: address = "https://you.com/platform"
        case .kagi: address = "https://kagi.com/settings?p=api"
        }
        return URL(string: address)!
    }
}

struct ConnectionSecrets: Codable, Equatable, Sendable {
    var key: String
    var username: String? = nil
    var additional: String? = nil
}

struct UsageMetric: Equatable, Sendable {
    enum Kind: String, Sendable { case quota, balance, spend, cap, count, note }
    let title: String
    let kind: Kind
    let value: Double?
    var unit: String = "%"
    var resetsAt: Date? = nil
    var detail: String? = nil
}

// All provider clients use an ephemeral, cookie-free transport. Redirects never
// carry a credential to another host. Callers own a fixed provider URL.
struct ProviderHTTP: Sendable {
    let send: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    init(send: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)) {
        self.send = send
    }

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration, delegate: ProviderRedirectGuard(), delegateQueue: nil)
        send = { request in
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw MonitorError.invalidResponse }
            return (data, response)
        }
    }

    func data(for request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await send(request)
            guard (200...299).contains(response.statusCode) else { throw MonitorError.http(response.statusCode) }
            return data
        } catch let error as MonitorError { throw error }
        catch { throw MonitorError.network }
    }
}

private final class ProviderRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
