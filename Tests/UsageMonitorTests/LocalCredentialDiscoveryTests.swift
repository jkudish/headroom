import Darwin
import Foundation
import Testing
@testable import UsageMonitor

@Suite struct LocalCredentialDiscoveryTests {
    @Test func literalAssignmentsAndAllowlistedAliases() throws {
        let result = LocalCredentialDiscovery.scan(environment: [:], dotenv: """
        # Synthetic credentials only
        export SEARCHAPI_API_KEY="fixture-search" # comment
        FIRECRAWL_API_KEY='fixture-fire#literal'
        JINA_AI_API_KEY=fixture-jina # comment
        YOU_COM_API_KEY=fixture-you
        UNKNOWN_API_KEY=fixture-ignored
        """)
        #expect(result.issues.isEmpty)
        #expect(Set(result.candidates.map(\.provider)) == [.searchAPI, .firecrawl, .jina, .you])
        let fire = try #require(result.candidates.first { $0.provider == .firecrawl })
        #expect(fire.connectionSecrets()?.key == "fixture-fire#literal")
        #expect(fire.source == .dotenv)
        #expect(fire.maskedValue == "••••••••")
    }

    @Test func executableOrAmbiguousAssignmentsNeverBecomeCredentials() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("must-not-exist")
        let payloads = ["$(touch \(marker.path))", "`touch \(marker.path)`", "${OTHER}", "$OTHER",
                        "'$(touch \(marker.path))'", "\"$OTHER\"", "fixture;touch \(marker.path)",
                        "fixture && echo bad", "fixture|cat", "fixture>file", "fixture\\", "\"unterminated",
                        "'fixture' trailing", "two words", "\"fixture\"#ambiguous", "fixture\u{0}bad",
                        " fixture", " \"fixture\"", "fixture$\u{301}", "fixture`\u{301}"]
        for payload in payloads {
            let result = LocalCredentialDiscovery.scan(environment: [:], dotenv: "SEARCHAPI_API_KEY=\(payload)")
            #expect(result.candidates.isEmpty)
            #expect(!result.issues.isEmpty)
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func environmentIsLiteralAndSourcesStaySeparate() throws {
        let result = LocalCredentialDiscovery.scan(environment: ["SEARCHAPI_API_KEY": "fixture-env"],
                                                   dotenv: "SEARCHAPI_API_KEY=fixture-first\nSEARCHAPI_API_KEY=fixture-last")
        #expect(result.candidates.count == 2)
        #expect(result.candidates.map(\.source) == [.inheritedEnvironment, .dotenv])
        #expect(result.candidates.map { $0.connectionSecrets()?.key } == ["fixture-env", "fixture-last"])
        #expect(Set(result.candidates.map(\.id)).count == 2)
        let invalidLast = LocalCredentialDiscovery.scan(environment: [:],
            dotenv: "SEARCHAPI_API_KEY=fixture-stale\nSEARCHAPI_API_KEY=$OTHER")
        #expect(invalidLast.candidates.isEmpty)
        // An already sourced environment is data, not shell syntax. Password punctuation stays literal.
        let literal = LocalCredentialDiscovery.scan(environment: ["DATAFORSEO_LOGIN": "fixture@example.test",
                                                                  "DATAFORSEO_PASSWORD": "literal$;# password"])
        #expect(literal.candidates.first?.connectionSecrets()?.key == "literal$;# password")
    }

    @Test func billingCredentialTypesAndProviderIsolation() throws {
        let environment = [
            "OPENROUTER_API_KEY": "fixture-router", "OPENROUTER_MANAGEMENT_KEY": "fixture-wallet",
            "OPENAI_API_KEY": "fixture-inference", "OPENAI_ADMIN_KEY": "fixture-admin",
            "OPENAI_ORG_ID": "org-fixture", "ANTHROPIC_API_KEY": "sk-ant-admin-still-ordinary-name",
            "ANTHROPIC_ADMIN_API_KEY": "fixture-anthropic-admin", "XAI_API_KEY": "fixture-xai-search",
            "XAI_MANAGEMENT_API_KEY": "fixture-xai-management", "EXA_API_KEY": "fixture-exa-search",
            "EXA_SERVICE_KEY": "fixture-exa-service", "EXA_API_KEY_ID": "fixture-selected-id",
            "PARALLEL_API_KEY": "fixture-parallel-search", "PARALLEL_ACCESS_TOKEN": "fixture-parallel-account",
            "SERPAPI_API_KEY": "fixture-serp", "TAVILY_API_KEY": "fixture-tavily",
            "VALYU_API_KEY": "fixture-valyu", "AMP_ACCESS_TOKEN": "fixture-ignore", "BRAVE_API_KEY": "fixture-ignore"
        ]
        let result = LocalCredentialDiscovery.scan(environment: environment)
        #expect(result.candidates.count == 15)
        for name in ["OPENAI_API_KEY", "ANTHROPIC_API_KEY", "XAI_API_KEY", "EXA_API_KEY", "PARALLEL_API_KEY"] {
            let candidate = try #require(result.candidates.first { $0.variable == name })
            #expect(candidate.eligibility == .unsupportedCredentialType)
            #expect(candidate.connectionSecrets() == nil)
        }
        let admin = try #require(result.candidates.first { $0.variable == "OPENAI_ADMIN_KEY" })
        #expect(admin.optionHints == ["organizationID": "org-fixture"])
        let exa = try #require(result.candidates.first { $0.variable == "EXA_SERVICE_KEY" })
        #expect(exa.optionHints == ["keyID": "fixture-selected-id"])
        #expect(exa.connectionSecrets()?.key == "fixture-exa-service")
        for (name, mode) in [("OPENROUTER_API_KEY", "key"), ("OPENROUTER_MANAGEMENT_KEY", "wallet")] {
            #expect(result.candidates.first { $0.variable == name }?.optionHints == ["mode": mode])
        }
        #expect(!result.candidates.contains { [.claude, .codex, .amp, .grok, .brave].contains($0.provider) })
        #expect(result.candidates.allSatisfy { !$0.hint.isEmpty })
    }

    @Test func companionsCannotCrossSourcesAndEachChoiceHasAnIdentity() throws {
        let result = LocalCredentialDiscovery.scan(environment: ["DATAFORSEO_PASSWORD": "fixture-password",
            "EXA_SERVICE_KEY": "fixture-service", "OPENAI_ADMIN_KEY": "fixture-admin",
            "OPENAI_ORG_ID": "org-one", "OPENAI_ORGANIZATION_ID": "org-two"],
            dotenv: "DATAFORSEO_LOGIN=fixture-login\nEXA_API_KEY_ID=fixture-id")
        #expect(result.candidates.filter { $0.provider == .dataForSEO }.count == 2)
        for candidate in result.candidates where [.dataForSEO, .exa].contains(candidate.provider) {
            #expect(!candidate.isSelectable)
            #expect(candidate.connectionSecrets() == nil)
        }
        let admins = result.candidates.filter { $0.provider == .openAIAPI }
        #expect(admins.count == 2)
        #expect(Set(admins.map(\.id)).count == 2)
        #expect(Set(admins.compactMap { $0.optionHints["organizationID"] }) == ["org-one", "org-two"])
        let paired = LocalCredentialDiscovery.scan(environment: ["DATAFORSEO_API_LOGIN": "fixture-api-login",
                                                                 "DATAFORSEO_API_PASSWORD": "fixture-api-password"])
        #expect(paired.candidates.first?.connectionSecrets()?.username == "fixture-api-login")
        #expect(paired.candidates.first?.connectionSecrets()?.key == "fixture-api-password")
    }

    @Test func candidatesAndReportsNeverDescribeSecrets() throws {
        let result = LocalCredentialDiscovery.scan(environment: ["DATAFORSEO_LOGIN": "private-fixture-login",
                                                                 "DATAFORSEO_PASSWORD": "private-fixture-password"])
        let candidate = try #require(result.candidates.first)
        var dumped = ""
        dump(result, to: &dumped)
        let descriptions = [String(describing: candidate), String(reflecting: candidate),
                            String(describing: result), String(reflecting: result), dumped,
                            String(describing: candidate.id), candidate.maskedValue, candidate.hint]
        for description in descriptions {
            #expect(!description.contains("private-fixture-login"))
            #expect(!description.contains("private-fixture-password"))
        }
        #expect(candidate.maskedValue == "••••••••")
    }

    @Test func inputBoundsAndSafeExplicitFileErrors() throws {
        let oversized = String(repeating: "x", count: LocalCredentialDiscovery.maximumFileBytes + 1)
        #expect(LocalCredentialDiscovery.scan(environment: [:], dotenv: oversized).issues == [.fileTooLarge])
        let lines = String(repeating: "# comment\n", count: LocalCredentialDiscovery.maximumLines + 1)
        #expect(LocalCredentialDiscovery.scan(environment: [:], dotenv: lines).issues == [.tooManyLines])
        #expect(LocalCredentialDiscovery.scan(environment: [:], dotenv: "SEARCHAPI_API_KEY=" + String(repeating: "x", count: 4097)).candidates.isEmpty)
        #expect(LocalCredentialDiscovery.scan(environment: [:], dotenv: String(repeating: "K", count: 129) + "=fixture").candidates.isEmpty)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("SEARCHAPI_API_KEY=fixture-file".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = LocalCredentialDiscovery.scan(environment: [:], dotenvFile: url)
        #expect(result.candidates.first?.connectionSecrets()?.key == "fixture-file")
        try Data([0xff, 0xfe]).write(to: url)
        #expect(LocalCredentialDiscovery.scan(environment: [:], dotenvFile: url).issues == [.invalidUTF8])
        let absent = url.appendingPathComponent("private-path")
        let failed = LocalCredentialDiscovery.scan(environment: ["SEARCHAPI_API_KEY": "fixture-retained"], dotenvFile: absent)
        #expect(failed.issues == [.fileUnavailable])
        #expect(failed.candidates.count == 1)
        #expect(!String(describing: failed).contains("private-path"))
        #expect(LocalCredentialDiscovery.scan(environment: [:]).candidates.isEmpty)
    }

    @Test func discoveryCatalogMatchesOnlyRequestedProviders() {
        let supported: Set<Provider> = [.openRouter, .searchAPI, .dataForSEO, .firecrawl, .openAIAPI,
            .anthropicAPI, .xaiAPI, .serpAPI, .tavily, .jina, .exa, .parallel, .valyu, .you]
        #expect(Set(Provider.allCases.filter(LocalCredentialDiscovery.supports)) == supported)
    }

    @Test func shellBlocksAndMultilineSyntaxFailClosed() {
        let texts = ["SEARCHAPI_API_KEY=fixture-valid\nsource other.env",
                     "OTHER='unterminated\nSEARCHAPI_API_KEY=fixture-hidden\n'",
                     "OTHER=fixture\\\nSEARCHAPI_API_KEY=fixture-hidden",
                     "if true; then\nSEARCHAPI_API_KEY=fixture-conditional\nfi"]
        for text in texts {
            let result = LocalCredentialDiscovery.scan(environment: [:], dotenv: text)
            #expect(result.candidates.isEmpty)
            #expect(result.issues == [.ambiguousSyntax])
        }
    }

    @Test func boundsHaveValidControlsAndEnvironmentValuesAreChecked() {
        let valid = String(repeating: "v", count: 4096)
        #expect(LocalCredentialDiscovery.scan(environment: ["SEARCHAPI_API_KEY": valid]).candidates.count == 1)
        #expect(LocalCredentialDiscovery.scan(environment: [:], dotenv: "SEARCHAPI_API_KEY=" + valid).candidates.count == 1)
        for value in [valid + "x", "\u{0}", "fixture\nsecond", " \t "] {
            let result = LocalCredentialDiscovery.scan(environment: ["SEARCHAPI_API_KEY": value])
            #expect(result.candidates.isEmpty)
            #expect(result.issues == [.rejectedAssignments(1)])
        }
        let lines = Array(repeating: "#", count: LocalCredentialDiscovery.maximumLines - 1).joined(separator: "\n")
        #expect(LocalCredentialDiscovery.scan(environment: [:], dotenv: lines + "\nSEARCHAPI_API_KEY=fixture").candidates.count == 1)
        let prefix = "SEARCHAPI_API_KEY=fixture\n#"
        let exactBytes = prefix + String(repeating: "x", count: LocalCredentialDiscovery.maximumFileBytes - prefix.utf8.count)
        #expect(exactBytes.utf8.count == LocalCredentialDiscovery.maximumFileBytes)
        #expect(LocalCredentialDiscovery.scan(environment: [:], dotenv: exactBytes).candidates.count == 1)
    }

    @Test func windowsLineEndingsAndLiteralQuotedPasswords() {
        let result = LocalCredentialDiscovery.scan(environment: [:],
            dotenv: "DATAFORSEO_LOGIN='fixture@example.test'\r\nexport DATAFORSEO_PASSWORD='literal; # password'\r\n")
        #expect(result.candidates.count == 1)
        #expect(result.candidates.first?.connectionSecrets()?.key == "literal; # password")
        #expect(result.candidates.first?.connectionSecrets()?.username == "fixture@example.test")
    }

    @Test func explicitFileScanRejectsSymlinksDirectoriesAndFIFOs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = directory.appendingPathComponent("fixture.env")
        let link = directory.appendingPathComponent("link.env")
        let pipe = directory.appendingPathComponent("pipe.env")
        try Data("SEARCHAPI_API_KEY=fixture".utf8).write(to: fixture)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture)
        #expect(mkfifo(pipe.path, 0o600) == 0)
        for url in [directory, link, pipe, URL(string: "https://example.test/not-local.env")!] {
            let result = LocalCredentialDiscovery.scan(environment: [:], dotenvFile: url)
            #expect(result.candidates.isEmpty)
            #expect(result.issues == [.fileUnavailable])
        }
        try Data(repeating: 0x61, count: LocalCredentialDiscovery.maximumFileBytes + 1).write(to: fixture)
        #expect(LocalCredentialDiscovery.scan(environment: [:], dotenvFile: fixture).issues == [.fileTooLarge])
    }
}
