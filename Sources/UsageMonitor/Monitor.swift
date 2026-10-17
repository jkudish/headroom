import Foundation
import Observation

struct AccountEntry: Identifiable {
    var account: Account
    var snapshot: UsageSnapshot?
    var error: String?
    var refreshing = false
    var resetting = false
    var id: UUID { account.id }

    var displayName: String { snapshot?.reportedEmail ?? account.displayName }

    var menuBarMetrics: [UsageMetric] {
        let metrics = snapshot?.metrics ?? []
        let quotas = metrics.filter { $0.kind == .quota && $0.value.map { $0.isFinite && (0...100).contains($0) } == true }
        // Session then weekly, independent of backend window order. Other quotas retain their order.
        let ordered = quotas.filter { $0.title == "5-hour" } + quotas.filter { $0.title == "Weekly" }
            + quotas.filter { !["5-hour", "Weekly"].contains($0.title) }
        if !ordered.isEmpty { return Array(ordered.prefix(2)) }
        return Array(metrics.filter { $0.kind == .balance && $0.value.map { $0.isFinite && $0 >= 0 } == true }.prefix(1))
    }
}

@MainActor @Observable
final class Monitor {
    private(set) var entries: [AccountEntry]
    let store: AccountStore
    private let fetch: @Sendable (UUID) async throws -> UsageSnapshot
    private let consume: @Sendable (Account, String, UUID) async throws -> ResetOutcome
    private let now: () -> Date
    private var requests: [UUID: UUID] = [:]
    private var refreshSchedule: [UUID: (after: Date, failures: Int, rateLimited: Bool)] = [:]

    var nextAutomaticRefresh: Date? {
        entries.filter { !$0.refreshing && !$0.resetting && $0.account.provider.supportsRead }
            .compactMap { refreshSchedule[$0.id]?.after }.min()
    }

    init(store: AccountStore, fetch: @escaping @Sendable (UUID) async throws -> UsageSnapshot,
         consume: (@Sendable (Account, String, UUID) async throws -> ResetOutcome)? = nil,
         now: @escaping () -> Date = Date.init) throws {
        self.store = store
        self.fetch = fetch
        self.now = now
        self.consume = consume ?? { account, credit, request in
            try await CodexClient(store: store).consumeReset(account, creditID: credit, requestID: request)
        }
        entries = try store.load().map { AccountEntry(account: $0) }
    }

    func add(label: String, provider: Provider = .claude, options: [String: String] = [:],
             secrets: ConnectionSecrets? = nil) throws -> UUID {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = Account(label: String(label.prefix(80)), provider: provider, options: options)
        try store.prepare(account.id)
        do {
            if let secrets { try store.saveSecrets(secrets, for: account.id) }
            try store.save(entries.map(\.account) + [account])
        } catch {
            try? store.deleteProfile(account.id)
            throw error
        }
        entries.append(AccountEntry(account: account))
        return account.id
    }

    func reconnect(_ id: UUID, secrets: ConnectionSecrets) throws {
        guard entries.contains(where: { $0.id == id }) else { return }
        guard entries.first(where: { $0.id == id })?.resetting != true else { throw MonitorError.loginBusy }
        try store.saveSecrets(secrets, for: id)
        try setGrokHelper(id, enabled: false)
        beginLogin(id)
    }

    func setGrokHelper(_ id: UUID, enabled: Bool) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].account.provider == .grok else { return }
        var accounts = entries.map(\.account)
        accounts[index].options["grokAuth"] = enabled ? "helper" : nil
        try store.save(accounts)
        entries[index].account = accounts[index]
    }

    func rename(_ id: UUID, label: String) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        var accounts = entries.map(\.account)
        accounts[index].label = String(label.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        try store.save(accounts)
        entries[index].account = accounts[index]
    }

    func setMenuBarVisibility(_ id: UUID, visible: Bool) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        var accounts = entries.map(\.account)
        accounts[index].showInMenuBar = visible
        try store.save(accounts)
        entries[index].account = accounts[index]
    }

    func setResetAlerts(_ id: UUID, enabled: Bool) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }),
              [.claude, .codex].contains(entries[index].account.provider) else { return }
        var accounts = entries.map(\.account)
        accounts[index].options["resetAlerts"] = enabled ? "true" : nil
        try store.save(accounts)
        entries[index].account = accounts[index]
    }

    func useReset(_ id: UUID, creditID: String) async throws -> ResetOutcome {
        guard let index = entries.firstIndex(where: { $0.id == id }),
              entries[index].account.provider == .codex, !entries[index].refreshing, !entries[index].resetting,
              let owner = entries[index].account.identity,
              entries[index].snapshot?.identity?.matches(owner) == true,
              entries[index].snapshot?.resetCredits?.credits.first(where: { $0.id == creditID })?.canUse == true else {
            throw MonitorError.invalidResponse
        }
        let key = "resetAttempt:\(creditID)"
        var accounts = entries.map(\.account)
        let requestID: UUID
        if let saved = accounts[index].options[key] {
            guard let parsed = UUID(uuidString: saved) else { throw MonitorError.invalidProfile }
            requestID = parsed
        } else {
            requestID = UUID()
            accounts[index].options[key] = requestID.uuidString
            // Persist before sending. A lost response or restart must reuse this request.
            try store.save(accounts)
            entries[index].account = accounts[index]
        }
        entries[index].resetting = true
        defer { if let current = entries.firstIndex(where: { $0.id == id }) { entries[current].resetting = false } }
        let outcome: ResetOutcome
        do { outcome = try await consume(accounts[index], creditID, requestID) }
        catch {
            if let current = entries.firstIndex(where: { $0.id == id }) {
                entries[current].snapshot = nil
                entries[current].error = "Reset result unavailable. Refresh this account before using a reset."
            }
            throw error
        }
        guard let current = entries.firstIndex(where: { $0.id == id }) else { throw MonitorError.invalidResponse }
        entries[current].resetting = false
        await refresh(id)
        return outcome
    }

    func remove(_ id: UUID) throws {
        guard entries.contains(where: { $0.id == id }) else { return }
        guard entries.first(where: { $0.id == id })?.resetting != true else { throw MonitorError.loginBusy }
        try store.deleteProfile(id)
        try store.save(entries.filter { $0.id != id }.map(\.account))
        requests[id] = nil
        refreshSchedule[id] = nil
        entries.removeAll { $0.id == id }
    }

    func beginLogin(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }), !entries[index].resetting else { return }
        requests[id] = nil
        refreshSchedule[id] = nil
        entries[index].snapshot = nil
        entries[index].error = nil
        entries[index].refreshing = false
    }

    func refreshDue(maxAge: TimeInterval = 60, isPaused: () -> Bool = { false }) async {
        for id in entries.map(\.id) {
            guard !Task.isCancelled, !isPaused() else { return }
            guard let entry = entries.first(where: { $0.id == id }), entry.account.provider.supportsRead,
                  !entry.refreshing, !entry.resetting, let schedule = refreshSchedule[id] else { continue }
            let due = schedule.failures == 0 && entry.account.provider != .claude
                ? schedule.after.addingTimeInterval(maxAge - 60) : schedule.after
            if now() >= due { await refresh(id) }
        }
    }

    func rateLimitEndsAt(_ id: UUID) -> Date? {
        guard let schedule = refreshSchedule[id], schedule.rateLimited, now() < schedule.after else { return nil }
        return schedule.after
    }

    func refresh(_ id: UUID) async {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].account.provider.supportsRead,
              !entries[index].refreshing, !entries[index].resetting else { return }
        if rateLimitEndsAt(id) != nil { return }
        let requestID = UUID()
        requests[id] = requestID
        entries[index].refreshing = true
        entries[index].error = nil
        do {
            let snapshot = try await fetch(id)
            guard requests[id] == requestID, let current = entries.firstIndex(where: { $0.id == id }) else { return }
            if entries[current].account.identity != nil && snapshot.identity == nil {
                throw MonitorError.invalidResponse
            }
            if let returned = snapshot.identity {
                if let identity = entries[current].account.identity, !identity.matches(returned) {
                    throw MonitorError.identityChanged
                }
                if entries.contains(where: {
                    $0.id != id && $0.account.provider == entries[current].account.provider
                        && $0.account.identity?.matches(returned) == true
                }) { throw MonitorError.duplicateAccount }
            }
            var accounts = entries.map(\.account)
            if let identity = snapshot.identity { accounts[current].identity = identity }
            try store.save(accounts)
            entries[current].account = accounts[current]
            entries[current].snapshot = snapshot
            let interval: TimeInterval = entries[current].account.provider == .claude ? 300 : 60
            refreshSchedule[id] = (now().addingTimeInterval(interval), 0, false)
        } catch {
            guard requests[id] == requestID, let current = entries.firstIndex(where: { $0.id == id }) else { return }
            entries[current].snapshot = nil
            // Never surface network bodies, credentials, or helper output in errors.
            if entries[current].account.provider == .anthropicAPI, error as? MonitorError == .http(401) {
                entries[current].error = "Anthropic rejected this key. Billing requires an organization Admin key (sk-ant-admin…), not a standard API key."
            } else {
                entries[current].error = (error as? MonitorError)?.localizedDescription ?? "Could not save this account's state."
            }
            switch error as? MonitorError {
            case .signInRequired, .missingScope, .keychainUnavailable, .invalidProfile, .identityChanged,
                 .duplicateAccount, .http(401), .http(403), .unsupported:
                // Only a user retry/reconnect may resume credentials that require intervention.
                refreshSchedule[id] = nil
            default:
                let failures = min((refreshSchedule[id]?.failures ?? 0) + 1, 5)
                let limited = entries[current].account.provider == .claude && (error as? MonitorError) == .http(429)
                let delay = min(1800, (limited ? 300 : 60) * pow(2, Double(failures)))
                refreshSchedule[id] = (now().addingTimeInterval(delay), failures, limited)
            }
        }
        if requests[id] == requestID, let current = entries.firstIndex(where: { $0.id == id }) {
            entries[current].refreshing = false
            requests[id] = nil
        }
    }
}
