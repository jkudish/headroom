import Darwin
import Foundation

/// Opt-in discovery only. The caller supplies a snapshot of the app's inherited
/// environment (not an interactive shell's environment), text, or a selected file.
/// Nothing is read on initialization, executed, persisted, or validated remotely.
enum LocalCredentialDiscovery {
    static let maximumFileBytes = 256 * 1024
    static let maximumLines = 4096
    private static let maximumValueBytes = 4096
    private static let maximumLineBytes = 8192
    private static let maximumKeyBytes = 128

    enum Source: String, Hashable, Sendable {
        case inheritedEnvironment, dotenv
        var title: String { self == .dotenv ? "Dotenv file" : "App environment" }
    }

    enum Eligibility: Equatable, Sendable {
        /// A name matches the required type; validity, ownership and scopes are unverified.
        case selectable
        case missingCompanions([String])
        case unsupportedCredentialType
    }

    enum Issue: Equatable, Sendable {
        case fileUnavailable, fileTooLarge, tooManyLines, invalidUTF8, ambiguousSyntax
        case rejectedAssignments(Int)
        case rejectedEnvironmentValues(Int)

        var message: String {
            switch self {
            case .fileUnavailable: "File unavailable. Use a regular local file, not a symlink."
            case .fileTooLarge: "File exceeds 256 KiB."
            case .tooManyLines: "File exceeds 4096 lines."
            case .invalidUTF8: "File must use UTF-8."
            case .ambiguousSyntax: "Shell or multiline syntax found. No file keys loaded."
            case .rejectedAssignments(let count): "Dotenv file: skipped \(count) entries. Values must be plain text, nonempty and at most 4096 bytes."
            case .rejectedEnvironmentValues(let count): "App environment: skipped \(count) empty, oversized or invalid values."
            }
        }
    }

    struct Report: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        let candidates: [Candidate]
        let issues: [Issue]
        var description: String { "Credential discovery: \(candidates.count) masked candidates; \(issues.count) issues" }
        var debugDescription: String { description }
        var customMirror: Mirror { Mirror(self, children: ["candidates": candidates, "issues": issues]) }
    }

    struct Candidate: Identifiable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        struct ID: Hashable, Sendable {
            let source: Source
            let variable: String
            let provider: Provider
            let companionVariables: [String]
        }

        let id: ID
        let eligibility: Eligibility
        let optionHints: [String: String]
        private let key: String
        private let username: String?
        var source: Source { id.source }
        var variable: String { id.variable }
        var provider: Provider { id.provider }
        var companionVariables: [String] { id.companionVariables }
        var maskedValue: String { "••••••••" }
        var isSelectable: Bool { eligibility == .selectable }
        var hint: String {
            switch eligibility {
            case .missingCompanions(let names): "Needs \(names.joined(separator: " or ")) in this source."
            case .unsupportedCredentialType: "Ordinary API keys cannot read billing. \(provider.connectionHelp)"
            case .selectable: "\(provider.connectionHelp) Key validity and permissions are unverified."
            }
        }

        /// Call only for an explicitly selected candidate. The caller owns the
        /// resulting secrets and must not render, log, or encode them as metadata.
        func connectionSecrets() -> ConnectionSecrets? {
            guard isSelectable else { return nil }
            return ConnectionSecrets(key: key, username: username)
        }

        var description: String { "\(provider.title): \(source.title), \(variable), \(maskedValue)" }
        var debugDescription: String { description }
        var customMirror: Mirror { Mirror(self, children: ["candidate": description, "eligibility": eligibility]) }

        fileprivate init(source: Source, variable: String, provider: Provider, companions: [String] = [],
                         eligibility: Eligibility = .selectable, options: [String: String] = [:],
                         key: String, username: String? = nil) {
            id = ID(source: source, variable: variable, provider: provider, companionVariables: companions)
            self.eligibility = eligibility
            optionHints = options
            self.key = key
            self.username = username
        }
    }

    // Ordinary aliases follow Librarium's provider-descriptor/profile catalog.
    // Admin/management aliases explicitly assert type; token prefixes/JWTs do not.
    private struct KeyRule {
        let provider: Provider
        let names: [String]
        var supported = true
        var mode: String? = nil
    }

    private static let rules: [KeyRule] = [
        .init(provider: .openRouter, names: ["OPENROUTER_API_KEY"], mode: "key"),
        .init(provider: .openRouter, names: ["OPENROUTER_MANAGEMENT_KEY", "OPENROUTER_MANAGEMENT_API_KEY"], mode: "wallet"),
        .init(provider: .searchAPI, names: ["SEARCHAPI_API_KEY"]),
        .init(provider: .firecrawl, names: ["FIRECRAWL_API_KEY"]),
        .init(provider: .openAIAPI, names: ["OPENAI_ADMIN_KEY", "OPENAI_ADMIN_API_KEY"]),
        .init(provider: .openAIAPI, names: ["OPENAI_API_KEY"], supported: false),
        .init(provider: .anthropicAPI, names: ["ANTHROPIC_ADMIN_KEY", "ANTHROPIC_ADMIN_API_KEY"]),
        .init(provider: .anthropicAPI, names: ["ANTHROPIC_API_KEY"], supported: false),
        .init(provider: .xaiAPI, names: ["XAI_MANAGEMENT_KEY", "XAI_MANAGEMENT_API_KEY"]),
        .init(provider: .xaiAPI, names: ["XAI_API_KEY"], supported: false),
        .init(provider: .serpAPI, names: ["SERPAPI_API_KEY", "SERPAPI_KEY"]),
        .init(provider: .tavily, names: ["TAVILY_API_KEY"]),
        .init(provider: .jina, names: ["JINA_AI_API_KEY", "JINA_API_KEY"]),
        .init(provider: .exa, names: ["EXA_SERVICE_KEY", "EXA_MANAGEMENT_API_KEY", "EXA_MANAGEMENT_KEY"]),
        .init(provider: .exa, names: ["EXA_API_KEY"], supported: false),
        .init(provider: .parallel, names: ["PARALLEL_ACCESS_TOKEN", "PARALLEL_ACCOUNT_ACCESS_TOKEN", "PARALLEL_ACCOUNT_API_TOKEN"]),
        .init(provider: .parallel, names: ["PARALLEL_API_KEY"], supported: false),
        .init(provider: .valyu, names: ["VALYU_API_KEY"]),
        .init(provider: .you, names: ["YOU_COM_API_KEY", "YOU_API_KEY", "YOUDOTCOM_API_KEY"])
    ]
    private static let logins = ["DATAFORSEO_LOGIN", "DATAFORSEO_API_LOGIN", "DATAFORSEO_USERNAME"]
    private static let passwords = ["DATAFORSEO_PASSWORD", "DATAFORSEO_API_PASSWORD"]
    private static let organizations = ["OPENAI_ORG_ID", "OPENAI_ORGANIZATION_ID", "OPENAI_ORGANIZATION"]
    private static let exaIDs = ["EXA_API_KEY_ID", "EXA_KEY_ID"]
    private static var allowedNames: Set<String> {
        Set(rules.flatMap(\.names) + logins + passwords + organizations + exaIDs)
    }

    static func supports(_ provider: Provider) -> Bool {
        provider.supportsRead && (provider == .dataForSEO || rules.contains { $0.provider == provider })
    }

    /// Environment candidates come first, but do not overwrite file candidates.
    /// Dotenv duplicates use the last assignment, including a rejected/empty one.
    /// Companions and alias combinations are separate choices within one source.
    static func scan(environment: [String: String], dotenv: String? = nil) -> Report {
        var issues: [Issue] = []
        var inherited: [String: String] = [:]
        var rejected = 0
        for name in allowedNames.sorted() {
            guard let value = environment[name] else { continue }
            // Already sourced values are literal data; never parse shell syntax here.
            if validValue(value) { inherited[name] = value } else { rejected += 1 }
        }
        if rejected > 0 { issues.append(.rejectedEnvironmentValues(rejected)) }
        var candidates = candidates(in: inherited, source: .inheritedEnvironment)
        if let dotenv {
            let parsed = parse(dotenv)
            issues += parsed.issues
            candidates += self.candidates(in: parsed.values, source: .dotenv)
        }
        return Report(candidates: candidates, issues: issues)
    }

    /// Opens only the explicitly supplied file, with no default home path.
    /// Refuses symlinks/devices/FIFOs and bounds the read even if the file grows.
    static func scan(environment: [String: String], dotenvFile: URL) -> Report {
        let inherited = scan(environment: environment)
        guard dotenvFile.isFileURL, !dotenvFile.path.utf8.contains(0) else {
            return Report(candidates: inherited.candidates, issues: inherited.issues + [.fileUnavailable])
        }
        let descriptor = open(dotenvFile.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            return Report(candidates: inherited.candidates, issues: inherited.issues + [.fileUnavailable])
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            return Report(candidates: inherited.candidates, issues: inherited.issues + [.fileUnavailable])
        }
        guard info.st_size <= maximumFileBytes else {
            return Report(candidates: inherited.candidates, issues: inherited.issues + [.fileTooLarge])
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while data.count <= maximumFileBytes {
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, min($0.count, maximumFileBytes + 1 - data.count)) }
            guard count >= 0 else {
                return Report(candidates: inherited.candidates, issues: inherited.issues + [.fileUnavailable])
            }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard data.count <= maximumFileBytes else {
            return Report(candidates: inherited.candidates, issues: inherited.issues + [.fileTooLarge])
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return Report(candidates: inherited.candidates, issues: inherited.issues + [.invalidUTF8])
        }
        return scan(environment: environment, dotenv: text)
    }

    private static func candidates(in values: [String: String], source: Source) -> [Candidate] {
        var result: [Candidate] = []
        for rule in rules where rule.provider.supportsRead {
            for name in rule.names {
                guard let key = values[name] else { continue }
                let companions = rule.provider == .openAIAPI ? organizations : rule.provider == .exa ? exaIDs : []
                let present = companions.filter { values[$0] != nil }
                for companion in present.isEmpty || !rule.supported ? [nil] : present.map(Optional.some) {
                    var options: [String: String] = [:]
                    if let mode = rule.mode { options["mode"] = mode }
                    if let companion { options[rule.provider == .exa ? "keyID" : "organizationID"] = values[companion] }
                    let eligibility: Eligibility = !rule.supported ? .unsupportedCredentialType
                        : rule.provider == .exa && present.isEmpty ? .missingCompanions(exaIDs) : .selectable
                    result.append(Candidate(source: source, variable: name, provider: rule.provider,
                        companions: companion.map { [$0] } ?? [], eligibility: eligibility, options: options, key: key))
                }
            }
        }
        let presentLogins = logins.filter { values[$0] != nil }
        let presentPasswords = passwords.filter { values[$0] != nil }
        for password in presentPasswords {
            for login in presentLogins.isEmpty ? [nil] : presentLogins.map(Optional.some) {
                result.append(Candidate(source: source, variable: password, provider: .dataForSEO,
                    companions: login.map { [$0] } ?? [],
                    eligibility: login == nil ? .missingCompanions(logins) : .selectable,
                    key: values[password]!, username: login.flatMap { values[$0] }))
            }
        }
        if presentPasswords.isEmpty {
            for login in presentLogins {
                result.append(Candidate(source: source, variable: login, provider: .dataForSEO,
                    eligibility: .missingCompanions(passwords), key: "", username: values[login]))
            }
        }
        return result
    }

    private static func validValue(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.utf8.count <= maximumValueBytes
            && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private static func parse(_ text: String) -> (values: [String: String], issues: [Issue]) {
        guard text.utf8.count <= maximumFileBytes else { return ([:], [.fileTooLarge]) }
        // Swift treats CRLF as one Character, so normalize before splitting on LF.
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count <= maximumLines else { return ([:], [.tooManyLines]) }
        var values: [String: String] = [:]
        var rejected = 0
        for raw in lines {
            var line = String(raw)
            if line.hasSuffix("\r") { line.removeLast() }
            line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") || line.hasPrefix("export\t") {
                line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            }
            guard let equals = line.firstIndex(of: "=") else { return ([:], [.ambiguousSyntax]) }
            let name = String(line[..<equals])
            let trimmedName = name.trimmingCharacters(in: .whitespaces)
            // Invalid later assignments must not resurrect an earlier credential.
            if allowedNames.contains(trimmedName) { values.removeValue(forKey: trimmedName) }
            guard name.utf8.count <= maximumKeyBytes, name == trimmedName,
                  let first = name.utf8.first, (65...90).contains(first) || (97...122).contains(first) || first == 95,
                  name.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }) else {
                rejected += 1
                continue
            }
            let rawValue = String(line[line.index(after: equals)...])
            // KEY= value is a shell command, not a literal assignment.
            guard rawValue.first?.isWhitespace != true else {
                rejected += 1
                continue
            }
            if rawValue.hasSuffix("\\") { return ([:], [.ambiguousSyntax]) }
            if let quote = rawValue.first, quote == "'" || quote == "\"",
               !rawValue.dropFirst().contains(quote) { return ([:], [.ambiguousSyntax]) }
            guard line.utf8.count <= maximumLineBytes, let value = literalValue(rawValue), validValue(value) else {
                rejected += 1
                continue
            }
            if allowedNames.contains(name) { values[name] = value }
        }
        return (values, rejected > 0 ? [.rejectedAssignments(rejected)] : [])
    }

    private static func literalValue(_ text: String) -> String? {
        let value: String
        if let quote = text.first, quote == "'" || quote == "\"" {
            guard let end = text.dropFirst().firstIndex(of: quote) else { return nil }
            let tail = text[text.index(after: end)...]
            guard tail.isEmpty || (tail.first == " " || tail.first == "\t")
                && (tail.trimmingCharacters(in: .whitespaces).isEmpty || tail.trimmingCharacters(in: .whitespaces).hasPrefix("#")) else { return nil }
            value = String(text[text.index(after: text.startIndex)..<end])
        } else {
            // Only whitespace-delimited comments. A # inside an unquoted word is literal.
            let end = text.indices.first { text[$0] == "#" && ($0 == text.startIndex || text[text.index(before: $0)].isWhitespace) }
            value = String(text[..<(end ?? text.endIndex)]).trimmingCharacters(in: .whitespaces)
            guard !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || "'\";|&<>()".unicodeScalars.contains($0) }) else { return nil }
        }
        // No interpolation, escapes, backticks or substitutions, even inside quotes.
        guard !value.unicodeScalars.contains(where: { "$`\\".unicodeScalars.contains($0) }) else { return nil }
        return value
    }
}
