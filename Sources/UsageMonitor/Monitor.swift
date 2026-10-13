import Foundation
import Observation

struct AccountEntry: Identifiable {
    var account: Account
    var snapshot: UsageSnapshot?
    var error: String?
    var refreshing = false
    var id: UUID { account.id }
}

@MainActor @Observable
final class Monitor {
    private(set) var entries: [AccountEntry]
    let store: AccountStore
    private let fetch: @Sendable (UUID) async throws -> UsageSnapshot
    private var requests: [UUID: UUID] = [:]

    init(store: AccountStore, fetch: @escaping @Sendable (UUID) async throws -> UsageSnapshot) throws {
        self.store = store
        self.fetch = fetch
        entries = try store.load().map { AccountEntry(account: $0) }
    }

    func add(label: String) throws -> UUID {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = Account(label: String(label.prefix(80)))
        try store.prepare(account.id)
        try store.save(entries.map(\.account) + [account])
        entries.append(AccountEntry(account: account))
        return account.id
    }

    func rename(_ id: UUID, label: String) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        var accounts = entries.map(\.account)
        accounts[index].label = String(label.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        try store.save(accounts)
        entries[index].account = accounts[index]
    }

    func remove(_ id: UUID) throws {
        guard entries.contains(where: { $0.id == id }) else { return }
        try store.deleteProfile(id)
        try store.save(entries.filter { $0.id != id }.map(\.account))
        requests[id] = nil
        entries.removeAll { $0.id == id }
    }

    func beginLogin(_ id: UUID) {
        requests[id] = nil
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].snapshot = nil
        entries[index].error = nil
        entries[index].refreshing = false
    }

    func refresh(_ id: UUID) async {
        guard let index = entries.firstIndex(where: { $0.id == id }), !entries[index].refreshing else { return }
        let requestID = UUID()
        requests[id] = requestID
        entries[index].refreshing = true
        entries[index].error = nil
        do {
            let snapshot = try await fetch(id)
            guard requests[id] == requestID, let current = entries.firstIndex(where: { $0.id == id }) else { return }
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
        } catch {
            guard requests[id] == requestID, let current = entries.firstIndex(where: { $0.id == id }) else { return }
            entries[current].snapshot = nil
            // Never surface network bodies, credentials, or helper output in errors.
            entries[current].error = (error as? MonitorError)?.localizedDescription ?? "Could not save this account's state."
        }
        if requests[id] == requestID, let current = entries.firstIndex(where: { $0.id == id }) {
            entries[current].refreshing = false
            requests[id] = nil
        }
    }
}
