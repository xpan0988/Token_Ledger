import CodexBarCore
import Foundation

enum TokenLedgerFormatting {
    private static let suffixes = ["", "K", "M", "B", "T"]

    static func compact(
        _ value: Decimal,
        locale: Locale,
        rounding: Decimal.RoundingMode = .plain) -> String
    {
        let magnitude = abs(value)
        var divisor: Decimal = 1
        var index = 0
        while index < Self.suffixes.count - 1, magnitude >= divisor * 1000 {
            divisor *= 1000
            index += 1
        }

        var scaled = value / divisor
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 2, rounding)
        if abs(rounded) >= 1000, index < Self.suffixes.count - 1 {
            index += 1
            scaled /= 1000
            NSDecimalRound(&rounded, &scaled, 2, rounding)
        }
        return rounded.formatted(.number.locale(locale).precision(.fractionLength(0...2)).grouping(.never))
            + Self.suffixes[index]
    }

    static func full(_ value: Decimal, locale: Locale) -> String {
        // Decimal retains up to 38 significant digits, including fractional source precision.
        value.formatted(.number.locale(locale).precision(.fractionLength(0...38)))
    }

    static func parsePayment(_ input: String, locale: Locale) -> Decimal? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let separator = locale.decimalSeparator ?? "."
        let parts = text.components(separatedBy: separator)
        guard (1...2).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }),
              parts.joined().count <= 38,
              let amount = Decimal(string: text, locale: locale), !amount.isNaN
        else { return nil }
        return amount
    }

    static func decimal(_ value: Double) -> Decimal? {
        guard value.isFinite else { return nil }
        return Decimal(string: String(value), locale: Locale(identifier: "en_US_POSIX"))
    }
}

struct TokenLedgerQuotas {
    let fiveHour: RateWindow?
    let weekly: RateWindow?
    let updatedAt: Date?
    let failed: Bool

    init(snapshot: UsageSnapshot?, failed: Bool) {
        let windows = [snapshot?.primary, snapshot?.secondary, snapshot?.tertiary].compactMap(\.self)
        let available = windows.filter { !$0.isSyntheticPlaceholder && $0.usedPercent.isFinite }
        self.fiveHour = available.first { $0.windowMinutes == 300 }
        self.weekly = available.first { $0.windowMinutes == 7 * 24 * 60 }
        self.updatedAt = snapshot?.updatedAt
        self.failed = failed
    }

    func staleAfter(refreshFrequency: RefreshFrequency) -> Date? {
        self.updatedAt?.addingTimeInterval(max(900, (refreshFrequency.seconds ?? 900) * 3))
    }

    static func progress(_ window: RateWindow) -> Double {
        UsagePercent(raw: window.usedPercent).displayClamped / 100
    }
}
