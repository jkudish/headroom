import AppKit

@MainActor enum MenuBarAccountImage {
    static func text(_ metric: UsageMetric) -> String {
        guard let value = metric.value, value.isFinite else { return "—" }
        if metric.kind == .quota {
            if value > 0 && value < 1 { return "<1%" }
            return value.formatted(.number.precision(.fractionLength(0...1))) + "%"
        }
        if ["USD", "EUR", "GBP", "CAD", "CNY"].contains(metric.unit) {
            return value.formatted(.currency(code: metric.unit))
        }
        return value.formatted(.number.precision(.fractionLength(0...1)))
    }

    static func make(_ entries: [AccountEntry], appearance: NSAppearance) -> NSImage {
        let images = entries.filter { $0.account.showInMenuBar }.map { make($0, appearance: appearance) }
        guard !images.isEmpty else {
            return NSImage(systemSymbolName: "gauge.with.dots.needle.50percent", accessibilityDescription: "Usage Monitor")!
        }
        let gap: CGFloat = 10
        let width = images.reduce(0) { $0 + $1.size.width } + gap * CGFloat(images.count - 1)
        let image = NSImage(size: NSSize(width: width, height: 22))
        image.lockFocus()
        var x: CGFloat = 0
        for part in images {
            part.draw(in: NSRect(x: x, y: 0, width: part.size.width, height: 22))
            x += part.size.width + gap
        }
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    static func make(_ entry: AccountEntry, appearance: NSAppearance) -> NSImage {
        let metrics = entry.menuBarMetrics
        let values = metrics.isEmpty ? [entry.refreshing ? "…" : "—"] : metrics.map(text)
        let stacked = values.count == 2
        let font = NSFont.monospacedDigitSystemFont(ofSize: stacked ? 9 : 12, weight: .semibold)
        let width = ceil(values.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 12)
        let image = NSImage(size: NSSize(width: 25 + width, height: 22))
        appearance.performAsCurrentDrawingAppearance {
            image.lockFocus()
            if let logo = entry.account.provider.logo {
                let rect = NSRect(x: 0, y: 2, width: 18, height: 18)
                logo.draw(in: rect)
                if entry.account.provider == .codex {
                    NSColor.labelColor.setFill()
                    rect.fill(using: .sourceIn)
                }
            } else {
                let letter = String(entry.account.provider.title.prefix(1)) as NSString
                letter.draw(at: NSPoint(x: 3, y: 3), withAttributes: [.font: NSFont.systemFont(ofSize: 16, weight: .semibold),
                                                                 .foregroundColor: NSColor.labelColor])
            }
            for (index, value) in values.enumerated() {
                let metric = metrics.indices.contains(index) ? metrics[index] : nil
                let color: NSColor
                if metric?.kind == .quota, let remaining = metric?.value {
                    color = remaining == 0 ? .systemRed : remaining <= 10 ? .systemOrange : .labelColor
                } else { color = .labelColor }
                let point = NSPoint(x: 24 + width - (value as NSString).size(withAttributes: [.font: font]).width,
                                    y: stacked ? (index == 0 ? 11 : 1) : 4)
                (value as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: color])
            }
            image.unlockFocus()
        }
        image.isTemplate = false
        return image
    }
}
