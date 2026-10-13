import Foundation
import Observation

@MainActor @Observable
final class LoginController {
    private(set) var accountID: UUID?
    private(set) var authorizationURL: URL?
    private(set) var error: String?
    private(set) var submitted = false
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var buffer = ""
    private var attempt: UUID?

    func start(_ id: UUID, store: AccountStore, completion: @escaping @MainActor (UUID) -> Void) throws {
        guard process == nil else { throw MonitorError.loginBusy }
        let paths = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude").path,
                     "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        guard let executable = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw MonitorError.helperMissing
        }
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let attempt = UUID()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["auth", "login", "--claudeai"]
        process.environment = try store.helperEnvironment(id)
        process.currentDirectoryURL = store.profile(id).deletingLastPathComponent()
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
        accountID = id
        authorizationURL = nil
        error = nil
        submitted = false
        do { try process.run() }
        catch { finish(); throw MonitorError.helperFailed }
    }

    func submit(_ code: String) throws {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !submitted, process?.isRunning == true, let input,
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
        submitted = false
        buffer = ""
    }

    private func receive(_ data: Data, attempt: UUID) {
        guard self.attempt == attempt, !submitted else { return }
        buffer += String(decoding: data, as: UTF8.self)
        buffer = String(buffer.suffix(32768))
        // Keep the helper's complete first-party URL, including its PKCE challenge and state.
        // Neither helper output nor codes are logged or saved.
        let pattern = #"https://(?:claude\.com/cai|claude\.ai)/oauth/authorize\?[^\s\x{1B}]+(?=\r?\n)"#
        guard let range = buffer.range(of: pattern, options: .regularExpression),
              let url = URL(string: String(buffer[range])),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.queryItems?.first(where: { $0.name == "client_id" })?.value == "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
              parts.queryItems?.contains(where: { $0.name == "state" && $0.value?.isEmpty == false }) == true else { return }
        authorizationURL = url
    }
}
