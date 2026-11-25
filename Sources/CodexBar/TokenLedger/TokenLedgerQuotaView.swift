import CodexBarCore
import SwiftUI

struct TokenLedgerQuotaView: View {
    let provider: TokenLedgerProvider
    let preferences: TokenLedgerPreferences
    let cadence: RefreshFrequency
    let now: Date

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                self.ring(
                    self.provider.quotas.fiveHour,
                    diameter: 46,
                    width: 3.5,
                    opacity: 1)
                self.ring(
                    self.provider.quotas.weekly,
                    diameter: 32,
                    width: 3,
                    opacity: 0.63)
            }
            .frame(width: 50, height: 50)
            Text(self.provider.name)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity)
        .help(self.toolTip)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(self.provider.name)
        .accessibilityValue(self.toolTip)
    }

    private func ring(_ window: RateWindow?, diameter: CGFloat, width: CGFloat, opacity: Double) -> some View {
        let accent = TokenLedgerProvider.accent(self.provider.id)
        let radius = diameter - width
        let unavailable = window == nil
        return ZStack {
            Circle()
                .stroke(
                    unavailable ? Color.white.opacity(0.13) : accent.opacity(0.20 * opacity),
                    style: StrokeStyle(lineWidth: width, lineCap: .round, dash: unavailable ? [1.6, 5.4] : []))
            if let window {
                Circle()
                    .trim(from: 0, to: TokenLedgerQuotas.progress(window))
                    .stroke(
                        accent.opacity(opacity * (self.isStale(window) ? 0.43 : 1)),
                        style: StrokeStyle(lineWidth: width, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: radius, height: radius)
    }

    private var toolTip: String {
        [
            self.quotaLine("ledger.fiveHour", self.provider.quotas.fiveHour),
            self.quotaLine("ledger.weekly", self.provider.quotas.weekly),
        ].joined(separator: "\n")
    }

    private func quotaLine(_ key: String, _ window: RateWindow?) -> String {
        let label = self.preferences.text(key)
        guard let window else {
            return self.preferences.text("ledger.quotaLine", label, self.preferences.text("ledger.unavailable"))
        }
        let locale = self.preferences.options.language.locale
        let percent = (window.usedPercent / 100).formatted(.percent.locale(locale).precision(.fractionLength(0...2)))
        var line = self.preferences.text("ledger.quotaLine", label, percent)
        if let date = window.resetsAt {
            let format = Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale)
            line += " · " + self.preferences.text("ledger.resetsAt", date.formatted(format))
        } else {
            line += " · " + self.preferences.text("ledger.noReset")
        }
        if self.isStale(window) {
            line += " · " + self.preferences.text("ledger.lastKnown")
        }
        return line
    }

    private func isStale(_ window: RateWindow) -> Bool {
        let quotas = self.provider.quotas
        let expiry = min(
            window.resetsAt ?? .distantFuture,
            quotas.staleAfter(refreshFrequency: self.cadence) ?? .distantFuture)
        return quotas.failed || expiry <= self.now
    }
}
