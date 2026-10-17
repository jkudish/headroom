import Foundation
import UserNotifications

enum ResetReminders {
    struct Reminder {
        let id: String
        let date: Date
        let hoursBefore: Int
        let count: Int
        let expiry: Date
    }

    static func plan(_ entry: AccountEntry, now: Date) -> [Reminder] {
        Dictionary(grouping: expirations(entry, now: now), by: \.date).sorted { $0.key < $1.key }.flatMap { expiry, grants in
            let count = grants.reduce(0) { $0 + $1.count }
            let thresholds = [12, 3, 1]
            let overdue = thresholds.last { expiry.addingTimeInterval(Double(-$0 * 3600)) <= now }
            return thresholds.compactMap { hours -> Reminder? in
                let date = expiry.addingTimeInterval(Double(-hours * 3600))
                guard date > now || hours == overdue else { return nil }
                return Reminder(id: "reset.\(entry.id).\(Int(expiry.timeIntervalSince1970)).\(hours)",
                                date: max(date, now.addingTimeInterval(1)), hoursBefore: hours, count: count, expiry: expiry)
            }
        }
    }

    static func expiringCount(_ entry: AccountEntry, now: Date) -> Int {
        expirations(entry, now: now).filter { $0.date <= now.addingTimeInterval(12 * 3600) }.reduce(0) { $0 + $1.count }
    }

    static func cancellations(_ identifiers: [String], entries: [AccountEntry], now: Date) -> [String] {
        let wanted = Set(entries.filter { $0.account.options["resetAlerts"] == "true" }
            .flatMap { plan($0, now: now).map(\.id) })
        let unknown = Set(entries.filter { $0.account.options["resetAlerts"] == "true" && !hasFreshSnapshot($0, now: now) }
            .map { $0.id.uuidString })
        return identifiers.filter {
            $0.hasPrefix("reset.") && !wanted.contains($0)
                && !unknown.contains(String($0.split(separator: ".", maxSplits: 2, omittingEmptySubsequences: false)[1]))
        }
    }

    static func hasFreshSnapshot(_ entry: AccountEntry, now: Date) -> Bool {
        guard let snapshot = entry.snapshot else { return false }
        return (-60..<900).contains(now.timeIntervalSince(snapshot.fetchedAt))
    }

    private static func expirations(_ entry: AccountEntry, now: Date) -> [(date: Date, count: Int)] {
        guard [.claude, .codex].contains(entry.account.provider), hasFreshSnapshot(entry, now: now),
              let snapshot = entry.snapshot else { return [] }
        return snapshot.unusedResetExpirations(at: now)
    }
}

@MainActor final class ResetNotificationController: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private var scheduled = UserDefaults.standard.dictionary(forKey: "resetNotificationDates") as? [String: Double] ?? [:]
    private var task: Task<Void, Never>?
    private var fingerprint: String?
    var openAccount: ((UUID) -> Void)?

    override init() {
        super.init()
        center.delegate = self
    }

    func requestPermission() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound])
    }

    func update(_ entries: [AccountEntry], now: Date = Date()) {
        let reminders = entries.filter { $0.account.options["resetAlerts"] == "true" }
            .flatMap { entry in ResetReminders.plan(entry, now: now).map { (entry, $0) } }
        let state = entries.map { "\($0.id):\($0.account.options["resetAlerts"] == "true"):\(ResetReminders.hasFreshSnapshot($0, now: now))" }
        let key = (state + reminders.map { "\($0.1.id):\($0.1.count):\($0.0.displayName)" }).joined(separator: "|")
        guard key != fingerprint else { return }
        fingerprint = key
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            let pending = await center.pendingNotificationRequests()
            let delivered = await center.deliveredNotifications()
            guard !Task.isCancelled else { return }
            let wanted = Set(reminders.map { $0.1.id })
            let cancelled = ResetReminders.cancellations(pending.map(\.identifier) + delivered.map { $0.request.identifier }, entries: entries, now: now)
            center.removePendingNotificationRequests(withIdentifiers: cancelled)
            center.removeDeliveredNotifications(withIdentifiers: cancelled)
            scheduled = scheduled.filter { wanted.contains($0.key) || $0.value > now.addingTimeInterval(-30 * 86400).timeIntervalSince1970 }
            for (entry, reminder) in reminders {
                guard !Task.isCancelled else { return }
                // A previously scheduled past threshold is never replayed after refresh or relaunch.
                if let date = scheduled[reminder.id], date <= now.timeIntervalSince1970 { continue }
                let content = UNMutableNotificationContent()
                content.title = "\(entry.account.provider.title) reset\(reminder.count == 1 ? "" : "s") expiring"
                content.body = "\(entry.displayName): \(reminder.count) unused reset\(reminder.count == 1 ? "" : "s") expire \(reminder.expiry.usageResetText()). Review in Headroom."
                content.userInfo = ["accountID": entry.id.uuidString]
                content.sound = .default
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, reminder.date.timeIntervalSinceNow), repeats: false)
                do {
                    try await center.add(UNNotificationRequest(identifier: reminder.id, content: content, trigger: trigger))
                    scheduled[reminder.id] = reminder.date.timeIntervalSince1970
                } catch { fingerprint = nil }
            }
            UserDefaults.standard.set(scheduled, forKey: "resetNotificationDates")
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .list, .sound] }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse) async {
        guard let raw = response.notification.request.content.userInfo["accountID"] as? String,
              let id = UUID(uuidString: raw) else { return }
        await MainActor.run { self.openAccount?(id) }
    }
}
