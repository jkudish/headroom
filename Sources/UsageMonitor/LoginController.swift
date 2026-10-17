import Foundation
import Observation

@MainActor @Observable
final class LoginController {
    private(set) var accountID: UUID?
    private(set) var authorizationURL: URL?
    private(set) var deviceCode: String?
    private(set) var provider: Provider = .claude
    private(set) var error: String?
    private(set) var submitted = false
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var buffer = ""
    private var attempt: UUID?

    func start(_ id: UUID, provider: Provider = .claude, store: AccountStore,
               completion: @escaping @MainActor (UUID) -> Void) throws {
        guard process == nil else { throw MonitorError.loginBusy }
        guard provider.usesHelper || provider == .grok else { throw MonitorError.invalidProfile }
        let helper = provider == .grok ? "grok" : provider == .codex ? "codex" : "claude"
        let paths = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/\(helper)").path,
                     "/opt/homebrew/bin/\(helper)", "/usr/local/bin/\(helper)"]
        let executable = provider == .grok ? try GrokAuth.executable().path : paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        guard let executable else {
            throw MonitorError.unsupported("Install \(provider.title)'s official CLI at ~/.local/bin/\(helper) or with Homebrew.")
        }
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let attempt = UUID()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = provider == .grok ? ["login", "--oauth"] : provider == .codex ? CodexAuth.loginArguments : ["auth", "login", "--claudeai"]
        process.environment = try provider == .grok ? GrokAuth.environment(id, store: store) : provider == .codex ? CodexAuth.environment(id, store: store) : store.helperEnvironment(id)
        process.currentDirectoryURL = store.profile(id)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            Task { @MainActor in self?.receive(data, attempt: attempt) }
        }
        process.terminationHandler = { [weak self] process in
            let succeeded = process.terminationStatus == 0
            Task { @MainActor in
                guard let self, self.attempt == attempt else { return }
                self.finish()
                if succeeded { completion(id) }
                else { self.error = MonitorError.helperFailed.localizedDescription }
            }
        }
        self.process = process
        self.input = input
        self.output = output
        self.attempt = attempt
        self.provider = provider
        accountID = id
        authorizationURL = nil
        deviceCode = nil
        error = nil
        submitted = false
        do { try process.run() }
        catch { finish(); throw MonitorError.helperFailed }
    }

    func submit(_ code: String) throws {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard provider == .claude, !submitted, process?.isRunning == true, let input,
              !code.isEmpty, code.utf8.count <= 4096,
              code.range(of: #"^[A-Za-z0-9_.\-#]+$"#, options: .regularExpression) != nil else {
            throw MonitorError.invalidCode
        }
        do { try input.fileHandleForWriting.write(contentsOf: Data((code + "\n").utf8)) }
        catch { throw MonitorError.helperFailed }
        submitted = true
        authorizationURL = nil
        buffer = ""
    }

    func cancel() {
        let running = process
        finish()
        if running?.isRunning == true { running?.terminate() }
    }

    private func finish() {
        attempt = nil
        output?.fileHandleForReading.readabilityHandler = nil
        process?.terminationHandler = nil
        try? input?.fileHandleForWriting.close()
        try? output?.fileHandleForReading.close()
        process = nil
        input = nil
        output = nil
        accountID = nil
        authorizationURL = nil
        deviceCode = nil
        submitted = false
        buffer = ""
    }

    private func receive(_ data: Data, attempt: UUID) {
        guard self.attempt == attempt, !submitted else { return }
        buffer += String(decoding: data, as: UTF8.self)
        buffer = String(buffer.suffix(32768))
        guard let prompt = LoginPrompt.parse(buffer, provider: provider) else { return }
        authorizationURL = prompt.url
        deviceCode = prompt.deviceCode
    }
}

struct LoginPrompt {
    let url: URL
    let deviceCode: String?

    static func parse(_ output: String, provider: Provider) -> Self? {
        let buffer = output.replacingOccurrences(of: #"\x{1B}\[[0-9;]*[A-Za-z]"#, with: "", options: .regularExpression)
        if provider == .codex {
            guard buffer.range(of: #"(?m)^\s*https://auth\.openai\.com/codex/device\s*$"#, options: .regularExpression) != nil,
                  let marker = buffer.range(of: "Enter this one-time code"),
                  let code = buffer[marker.upperBound...].range(of: #"\b[A-Z0-9]{4}-[A-Z0-9]{5}\b"#, options: .regularExpression) else { return nil }
            return Self(url: URL(string: "https://auth.openai.com/codex/device")!, deviceCode: String(buffer[code]))
        }
        if provider == .grok {
            guard let range = buffer.range(of: #"https://auth\.x\.ai/oauth2/authorize\?[^\s\x{1B}]+(?=\r?\n)"#, options: .regularExpression),
                  let url = URL(string: String(buffer[range])),
                  let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  parts.host == "auth.x.ai", parts.user == nil, parts.password == nil, parts.port == nil,
                  let items = parts.queryItems, Set(items.map(\.name)).count == items.count,
                  items.first(where: { $0.name == "response_type" })?.value == "code",
                  items.first(where: { $0.name == "code_challenge_method" })?.value == "S256",
                  ["state", "nonce", "code_challenge", "client_id"].allSatisfy({ name in items.contains(where: { $0.name == name && $0.value?.isEmpty == false }) }),
                  let callback = items.first(where: { $0.name == "redirect_uri" })?.value.flatMap(URLComponents.init(string:)),
                  callback.scheme == "http", callback.host == "127.0.0.1", callback.port != nil,
                  callback.path == "/callback", callback.user == nil, callback.password == nil else { return nil }
            return Self(url: url, deviceCode: nil)
        }
        guard provider == .claude else { return nil }
        // Keep the helper's full PKCE URL. Never log or persist output or codes.
        let pattern = #"https://(?:claude\.com/cai|claude\.ai)/oauth/authorize\?[^\s\x{1B}]+(?=\r?\n)"#
        guard let range = buffer.range(of: pattern, options: .regularExpression),
              let url = URL(string: String(buffer[range])),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.queryItems?.first(where: { $0.name == "client_id" })?.value == "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
              parts.queryItems?.contains(where: { $0.name == "state" && $0.value?.isEmpty == false }) == true else { return nil }
        return Self(url: url, deviceCode: nil)
    }
}
