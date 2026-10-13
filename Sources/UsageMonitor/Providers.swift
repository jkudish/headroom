import Foundation

enum Provider: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude, codex, zai, openRouter, searchAPI, dataForSEO, firecrawl
    case openAIAPI, anthropicAPI, amp, grok, cursor, serpAPI, tavily, jina, exa
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
