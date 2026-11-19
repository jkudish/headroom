import Foundation
import Testing
@testable import UsageMonitor

private let antigravityReport = """
{"status": "SUCCESS", "command": {"name": "usage", "data": {"groups": [
  {"name": "Gemini Models", "buckets": [
    {"id": "gemini-weekly", "window": "weekly", "remaining_fraction": 0.86, "reset_time": "2099-09-17T18:40:27Z"},
    {"id": "gemini-5h", "window": "5h", "remaining_fraction": 0.95, "reset_time": "2099-09-13T03:48:04.5Z"}]},
  {"name": "Claude and GPT models", "buckets": [
    {"id": "3p-5h", "window": "5h", "remaining_fraction": 1.4},
    {"id": "3p-daily", "window": "daily", "remaining_fraction": 0.5}]}]}}}
"""

@Test func antigravityParsesGroupedRemainingQuotasAndKeepsInvalidValuesUnavailable() throws {
    let snapshot = try AntigravityClient.snapshot(Data(antigravityReport.utf8), identity: nil)
    #expect(snapshot.metrics.map(\.title) == ["Gemini Models · Weekly", "Gemini Models · 5-hour", "Claude and GPT models · 5-hour"])
    #expect(abs((snapshot.metrics[0].value ?? 0) - 86) < 0.0001 && snapshot.metrics[0].kind == .quota)
    #expect(snapshot.metrics[1].resetsAt != nil)
    #expect(snapshot.metrics[2].value == nil && snapshot.metrics[2].resetsAt == nil)
}

@Test func antigravityRejectsFailedOrUnrecognizedReports() {
    for body in [#"{"status": "ERROR", "command": {"name": "usage", "data": {"groups": []}}}"#,
                 #"{"status": "SUCCESS", "command": {"name": "help", "data": {}}}"#,
                 #"{"status": "SUCCESS", "command": {"name": "usage", "data": {"groups": []}}}"#, "not json"] {
        #expect(throws: MonitorError.invalidResponse) { try AntigravityClient.snapshot(Data(body.utf8), identity: nil) }
    }
}

@Test func antigravityIdentityUsesIDTokenClaimsWithoutExposingTokens() throws {
    let claims = try JSONSerialization.data(withJSONObject: ["sub": "fixture-subject", "email": "person@example.com"])
        .base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    let file = #"{"token": {"access_token": "a", "refresh_token": "r", "token_type": "Bearer", "expiry": "2099-01-01T00:00:00Z"}, "auth_method": "consumer", "id_token": "eyJhbGciOiJub25lIn0.\#(claims).sig"}"#
    let identity = try #require(try AntigravityAuth.identity(Data(file.utf8)))
    #expect(identity.accountID == "fixture-subject" && identity.email == "person@example.com")
    #expect(try AntigravityAuth.identity(Data(#"{"token": {"access_token": "a", "refresh_token": "r"}}"#.utf8)) == nil)
    #expect(throws: MonitorError.signInRequired) { try AntigravityAuth.identity(Data(#"{"token": {"access_token": ""}}"#.utf8)) }
}

@Test func antigravityFetchRequiresSignedInPrivateHomeAndUsesInjectedReport() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try AccountStore(root: root)
    let id = UUID()
    try store.prepare(id)
    let client = AntigravityClient(store: store, usage: { _ in Data(antigravityReport.utf8) })
    await #expect(throws: MonitorError.signInRequired) { try await client.fetch(id) }
    let directory = AntigravityAuth.home(id, store: store).appendingPathComponent(".gemini/antigravity-cli")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let token = directory.appendingPathComponent("antigravity-oauth-token")
    try Data(#"{"token": {"access_token": "a", "refresh_token": "r"}}"#.utf8).write(to: token)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: token.path)
    #expect(try await client.fetch(id).metrics.count == 3)
    try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: token.path)
    await #expect(throws: MonitorError.invalidProfile) { try await client.fetch(id) }
    let environment = try AntigravityAuth.environment(id, store: store)
    #expect(environment["HOME"] == AntigravityAuth.home(id, store: store).path && environment["SSH_TTY"] != nil)
    #expect(environment["AGY_CLI_DISABLE_AUTO_UPDATE"] == "true")
    #expect(environment["PATH"]?.hasPrefix(store.profile(id).appendingPathComponent("bin").path + ":") == true)
}

@Test func antigravityLoginPromptAcceptsOnlyAgyGoogleOAuthLinks() {
    let link = "https://accounts.google.com/o/oauth2/auth?access_type=offline&client_id=fixture.apps.googleusercontent.com&code_challenge=abc&code_challenge_method=S256&redirect_uri=https%3A%2F%2Fantigravity.google%2Foauth-callback&response_type=code&state=xyz"
    let output = "Authentication required. Please visit the URL to log in:\n  \(link)\n\nWaiting for authentication (timeout 60s)...\n"
    #expect(LoginPrompt.parse(output, provider: .antigravity)?.url.absoluteString == link)
    let terminal = output.replacingOccurrences(of: "\n", with: "\r\n")
    #expect(LoginPrompt.parse(terminal, provider: .antigravity)?.url.absoluteString == link)
    let redirected = link.replacingOccurrences(of: "antigravity.google", with: "evil.example")
    #expect(LoginPrompt.parse("\(redirected)\n", provider: .antigravity) == nil)
    #expect(LoginPrompt.parse(output, provider: .claude) == nil)
}

@Test func antigravitySignInRunsAgyInsidePrivatePseudoTerminal() throws {
    guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/agy") || FileManager.default.isExecutableFile(atPath: "/usr/local/bin/agy") else { return }
    let arguments = try AntigravityAuth.loginArguments()
    #expect(AntigravityAuth.terminal.path == "/usr/bin/script")
    #expect(Array(arguments.prefix(2)) == ["-q", "/dev/null"])
    #expect(arguments[2].hasSuffix("/agy"))
    #expect(Array(arguments.dropFirst(3)) == AntigravityAuth.usageArguments)
}
