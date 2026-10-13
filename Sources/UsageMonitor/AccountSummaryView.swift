import AppKit
import SwiftUI

// Transparent content shared by the native menu and the account management window.
struct AccountSummaryView: View {
    let entry: AccountEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 9) {
                ProviderIcon(provider: entry.account.provider).frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.displayName).font(.headline).lineLimit(1).truncationMode(.middle)
                        .help(entry.displayName)
                    Text(entry.account.provider.title).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(entry.snapshot?.plan ?? "Plan unavailable").font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).help(entry.snapshot?.plan ?? "The provider did not report a plan")
                    if entry.refreshing { ProgressView().controlSize(.small) }
                }
            }
            if let snapshot = entry.snapshot {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text("Updated \(snapshot.fetchedAt.formatted(.relative(presentation: .named)))")
                        .font(.caption).foregroundStyle(.secondary)
                        .help("Last successful read: \(snapshot.fetchedAt.formatted())")
                }
                let creditLeft = snapshot.metrics.first { $0.title == "Credits left" }
                let creditCap = snapshot.metrics.first { $0.title == "Credit limit" }
                let creditQuota = snapshot.metrics.first { $0.title == "Individual credit quota" }
                ForEach(Array(snapshot.metrics.enumerated()), id: \.offset) { _, metric in
                    if !["Credits left", "Credits used", "Credit limit", "Individual credit quota"].contains(metric.title)
                        || creditLeft == nil || creditCap == nil {
                        metricRow(metric)
                    }
                }
                if entry.account.provider == .codex {
                    Divider()
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text("Limit Reset Credits").font(.callout.weight(.medium))
                            Spacer(minLength: 4)
                            Text(snapshot.resetCredits.map { "\($0.availableCount) available" } ?? "Unavailable")
                                .font(.callout.monospacedDigit())
                        }
                        if let expiry = snapshot.resetCredits?.expirations.first {
                            Text("Next known expiry \(expiry.usageResetText())")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if let left = creditLeft, let cap = creditCap {
                    Divider()
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text("Credits").font(.callout.weight(.medium))
                            Spacer()
                            Text("\(formatted(left)) left").font(.callout.monospacedDigit())
                        }
                        if let quota = creditQuota { quotaBar(quota) }
                        HStack {
                            Text("\(formatted(cap)) credit limit").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                        }
                        if let reset = creditQuota?.resetsAt { resetLabel(reset) }
                    }.help("Remaining individual allowance, not the wallet balance")
                }
            } else if let message = entry.error {
                UsageWarning(message: message)
            } else {
                Text(entry.refreshing ? "Checking usage…" : "Usage unavailable until this account connects.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func metricRow(_ metric: UsageMetric) -> some View {
        if metric.kind == .quota {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(metric.title).font(.callout.weight(.medium))
                    Text(metric.value == nil ? "Unavailable" : "\(MenuBarAccountImage.text(metric)) left")
                        .font(.callout.monospacedDigit()).foregroundStyle(metric.remainingColor)
                    Spacer(minLength: 0)
                }
                quotaBar(metric)
                if let reset = metric.resetsAt { resetLabel(reset) }
                else { Text("Reset time unavailable").font(.caption).foregroundStyle(.secondary) }
            }
        } else {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(metric.title == "Credit balance" ? "Wallet credits" : metric.title).font(.callout)
                    Spacer(minLength: 6)
                    if metric.kind != .note {
                        Text(formatted(metric)).font(.callout.monospacedDigit())
                    }
                }
                if let reset = metric.resetsAt { resetLabel(reset) }
                if let detail = metric.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder private func quotaBar(_ metric: UsageMetric) -> some View {
        if let remaining = metric.value, remaining.isFinite, (0...100).contains(remaining) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.1))
                    Capsule().fill(metric.remainingColor).frame(width: geometry.size.width * remaining / 100)
                }
            }.frame(height: 6)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(metric.title) remaining").accessibilityValue("\(remaining) percent")
        }
    }

    private func resetLabel(_ reset: Date) -> some View {
        Text(reset <= Date() ? "Reset time passed — refresh to update" : "Resets \(reset.usageResetText())")
            .font(.caption).foregroundStyle(.secondary)
    }

    private func formatted(_ metric: UsageMetric) -> String {
        guard let value = metric.value, value.isFinite else { return "Unavailable" }
        if ["USD", "EUR", "GBP", "CAD", "CNY"].contains(metric.unit) {
            return value.formatted(.currency(code: metric.unit))
        }
        return value.formatted(.number.precision(.fractionLength(0...2))) + (metric.unit == "credits" ? "" : " \(metric.unit)")
    }
}

struct UsageWarning: View {
    let message: String
    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).accessibilityHidden(true)
            Text(message).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
        }.font(.callout).accessibilityElement(children: .combine)
    }
}

struct ProviderIcon: View {
    let provider: Provider
    var body: some View {
        if let image = provider.logo {
            Image(nsImage: image).renderingMode(provider == .codex ? .template : .original)
                .resizable().scaledToFit().accessibilityLabel(provider.title)
        } else {
            Text(String(provider.title.prefix(1))).font(.headline).accessibilityLabel(provider.title)
        }
    }
}

extension Provider {
    var logo: NSImage? {
        let name: String
        switch self {
        case .claude: name = "claude-logo"
        case .codex: name = "openai-logo"
        case .amp: name = "amp-logo"
        default: return nil
        }
        return Bundle.module.url(forResource: name, withExtension: "png").flatMap(NSImage.init(contentsOf:))
    }
}
