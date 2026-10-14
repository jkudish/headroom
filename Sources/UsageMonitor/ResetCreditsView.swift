import SwiftUI

struct ResetCreditsView: View {
    @Bindable var monitor: Monitor
    let accountID: UUID
    let demo: Bool
    let finish: () -> Void
    @State private var confirmation: LimitResetCredit?
    @State private var result: String?

    private var entry: AccountEntry? { monitor.entries.first { $0.id == accountID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Available resets").font(.title2.weight(.semibold))
            Text(entry?.displayName ?? "Account unavailable").font(.headline).textSelection(.enabled)
            Text(entry?.snapshot?.resetCredits.map { "\($0.availableCount) available" } ?? "Inventory unavailable")
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(entry?.snapshot?.resetCredits?.credits ?? []) { credit in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(credit.title ?? "Reset credit").font(.headline)
                                Spacer()
                                Text(credit.canUse ? "Available" : credit.status == "available" ? "Expired or unsupported" : credit.status)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Text(credit.id).font(.caption.monospaced()).textSelection(.enabled)
                            if let description = credit.description { Text(description).font(.callout) }
                            if let granted = credit.grantedAt { Text("Granted \(granted.usageResetText())").font(.caption).foregroundStyle(.secondary) }
                            Text(credit.expiresAt.map { "Expires \($0.usageResetText())" } ?? "Expiry not reported")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("Use reset…") { confirmation = credit }
                                .disabled(demo || !credit.canUse || entry?.resetting == true || entry?.refreshing == true)
                                .accessibilityIdentifier("useReset-\(credit.id)")
                        }
                        Divider()
                    }
                    Text("Only resets listed here can be used. The total may include others.")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 360)
            if entry?.resetting == true { ProgressView("Applying reset…").controlSize(.small) }
            if let result { Text(result).font(.callout).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("Close", action: finish).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Refresh") { Task { await monitor.refresh(accountID) } }
                    .disabled(demo || entry?.resetting == true || entry?.refreshing == true)
            }
        }.padding(22).frame(width: 400)
        .alert("Use one reset credit?", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }),
               presenting: confirmation) { credit in
            Button("Cancel", role: .cancel) { confirmation = nil }.keyboardShortcut(.defaultAction)
            Button("Use reset", role: .destructive) {
                guard !demo else { return }
                confirmation = nil
                Task {
                    do { result = try await monitor.useReset(accountID, creditID: credit.id).message }
                    catch {
                        result = "Reset unconfirmed. \((error as? MonitorError)?.localizedDescription ?? "Could not save the request.") Refresh before retrying."
                    }
                }
            }.disabled(demo || entry?.resetting == true || entry?.refreshing == true)
        } message: { credit in
            Text("Account: \(entry?.displayName ?? "Unavailable")\nCredit: \(credit.title ?? "Reset credit") (\(credit.id))\n\nResets Codex limits and may spend this credit. This cannot be undone.")
        }
    }
}
