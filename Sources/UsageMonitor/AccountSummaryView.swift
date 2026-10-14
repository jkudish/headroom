import AppKit
import SwiftUI

// Transparent content shared by the native menu and the account management window.
struct AccountSummaryView: View {
    let entry: AccountEntry
    var compact = false

    private var textFont: Font { compact ? .system(size: 12) : .callout }

    var body: some View {
        TimelineView(.periodic(from: .now, by: entry.snapshot?.availabilityChangeDates.isEmpty == false ? 1 : 60)) { context in
            summary(at: context.date)
        }
    }

    private func summary(at now: Date) -> some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 12) {
            if compact {
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.displayName).font(.system(size: 12, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    HStack {
                        Text(entry.snapshot?.plan ?? "Plan unavailable").font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if entry.refreshing { ProgressView().controlSize(.mini) }
                    }
                }
            } else {
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
            }
            if let snapshot = entry.snapshot {
                Text("Updated \(snapshot.fetchedAt.formatted(.relative(presentation: .named)))")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("Last successful read: \(snapshot.fetchedAt.formatted())")
                let metrics = snapshot.metrics(at: now)
                let creditLeft = metrics.first { $0.title == "Credits left" }
                let creditCap = metrics.first { $0.title == "Credit limit" }
                let creditQuota = metrics.first { $0.title == "Individual credit quota" }
                ForEach(Array(metrics.enumerated()), id: \.offset) { _, metric in
                    if !["Credits left", "Credits used", "Credit limit", "Individual credit quota"].contains(metric.title)
                        || creditLeft == nil || creditCap == nil {
                        metricRow(metric)
                    }
                }
                if entry.account.provider == .codex {
                    Divider()
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text("Available resets").font(textFont.weight(.medium))
                            Spacer(minLength: 4)
                            Text(snapshot.resetCredits.map { "\($0.availableCount)" } ?? "Unavailable")
                                .font(textFont.monospacedDigit())
                        }
                        if !compact, let expiry = snapshot.resetCredits?.expirations.first {
                            Text("Next known expiry \(expiry.usageResetText())")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if let left = creditLeft, let cap = creditCap {
                    Divider()
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text("Credits").font(textFont.weight(.medium))
                            Spacer()
                            Text("\(formatted(left)) left").font(textFont.monospacedDigit())
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
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        Text(metric.title).font(textFont.weight(.medium))
                        quotaValue(metric)
                    }.fixedSize()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(metric.title).font(textFont.weight(.medium))
                        quotaValue(metric)
                    }
                }
                quotaBar(metric)
                if let reset = metric.resetsAt { resetLabel(reset) }
                else { Text("Reset time unavailable").font(.caption).foregroundStyle(.secondary) }
            }
        } else {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(metric.title == "Credit balance" ? "Wallet credits" : metric.title).font(textFont)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 6)
                    if metric.kind != .note {
                        Text(formatted(metric)).font(textFont.monospacedDigit()).fixedSize()
                    }
                }
                if let reset = metric.resetsAt { resetLabel(reset) }
                if let detail = metric.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(compact ? 2 : nil).fixedSize(horizontal: false, vertical: true).help(detail)
                }
            }
        }
    }

    private func quotaValue(_ metric: UsageMetric) -> some View {
        Text(metric.value == nil ? "Unavailable" : "\(MenuBarAccountImage.text(metric, provider: entry.account.provider)) left")
            .font(textFont.monospacedDigit()).foregroundStyle(metric.remainingColor)
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
        let date = compact ? reset.formatted(.dateTime.month(.abbreviated).day().hour().minute()) : reset.usageResetText()
        return Text(reset <= Date() ? "Reset passed — refresh" : "Resets \(date)")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            .help(reset.usageResetText())
    }

    private func formatted(_ metric: UsageMetric) -> String {
        guard let value = metric.value, value.isFinite else { return "Unavailable" }
        if ["USD", "EUR", "GBP", "CAD", "CNY"].contains(metric.unit) {
            return value.formatted(.currency(code: metric.unit))
        }
        return value.formatted(.number.precision(.fractionLength(0...2))) + (metric.unit == "credits" ? "" : " \(metric.unit)")
    }
}

struct ProviderAccountGrid<Content: View>: View {
    let entries: [AccountEntry]
    @ViewBuilder var content: (AccountEntry) -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let provider = entries.first?.account.provider {
                HStack(spacing: 8) {
                    ProviderIcon(provider: provider).frame(width: 22, height: 22)
                    Text(provider.title).font(.headline)
                    Text("\(entries.count) \(entries.count == 1 ? "account" : "accounts")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(Array(stride(from: 0, to: entries.count, by: 2)), id: \.self) { start in
                HStack(alignment: .top, spacing: 12) {
                    content(entries[start]).frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
                    if start + 1 < entries.count {
                        content(entries[start + 1]).frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
                    } else {
                        Color.clear.frame(minWidth: 0, maxWidth: .infinity, maxHeight: 1)
                    }
                }
                if start + 2 < entries.count { Divider() }
            }
        }
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
