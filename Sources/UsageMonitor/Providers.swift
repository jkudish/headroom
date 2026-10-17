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
        case .cursor: "Grok Bot"
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
    var supportsRead: Bool { ![Self.exa, .brave, .perplexity, .gemini, .kagi].contains(self) }

    var connectionHelp: String {
        switch self {
        case .claude: "Sign in through Claude Code using the browser profile for this account."
        case .codex: "Sign in through Codex using the browser profile for this account."
        case .zai: "Use your Coding Plan key and billing region."
        case .openRouter: "Use a management key for wallet balance, or an API key for its spend and cap."
        case .searchAPI: "Use an API key to see monthly searches and remaining credits."
        case .dataForSEO: "Use the login and password from API Access, not your website password."
        case .firecrawl: "Use a team API key. Credits include purchases and coupons."
        case .openAIAPI: "Use an organization Admin key. Reports monthly API spend, not wallet balance."
        case .anthropicAPI: "Use an organization sk-ant-admin key, not a standard API key. Reports API spend, not Claude limits or wallet balance."
        case .xaiAPI: "Use a team Management key with billing read access. Reports prepaid API balance, not SuperGrok limits or promotional credits."
        case .amp: "Use an Amp access token to see Agent, Orb and credit readings when available."
        case .grok: "Manual option: paste a SuperGrok access token, not an xAI API key. Manual tokens need renewal. Reports credits, not a separate 5-hour meter."
        case .cursor: "Manual option: paste the session Cookie header from cursor.com. Grok Bot uses this sign-in service, separate from SuperGrok."
        case .serpAPI: "Use an API key to see remaining searches."
        case .tavily: "Use an API key to see plan credits and key usage."
        case .jina: "Use an API key to see token balance. Experimental connector."
        case .exa: "Exa support is paused. Check usage in the Exa dashboard."
        case .parallel: "Use an Account API OAuth token, not a search key. Reports prepaid balance and pending charges."
        case .valyu: "Use a key with billing:read to see credits and pay-as-you-go spend."
        case .brave, .perplexity, .gemini, .kagi: "Billing is not supported. Check the dashboard."
        case .you: "Use an API key with account balance access."
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
