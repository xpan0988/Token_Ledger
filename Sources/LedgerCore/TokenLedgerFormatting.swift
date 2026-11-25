import Foundation

package enum TokenLedgerFormatting {
    private static let suffixes = ["", "K", "M", "B", "T"]
    private static let chineseSuffixes = ["", "万", "亿", "万亿"]

    package static func compact(
        _ value: Decimal,
        locale: Locale,
        chineseUnits: Bool = false) -> String
    {
        let suffixes = chineseUnits ? Self.chineseSuffixes : Self.suffixes
        let step: Decimal = chineseUnits ? 10000 : 1000
        let magnitude = abs(value)
        var divisor: Decimal = 1
        var index = 0
        while index < suffixes.count - 1, magnitude >= divisor * step {
            divisor *= step
            index += 1
        }

        var scaled = value / divisor
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 2, .plain)
        if abs(rounded) >= step, index < suffixes.count - 1 {
            index += 1
            scaled /= step
            NSDecimalRound(&rounded, &scaled, 2, .plain)
        }
        return rounded.formatted(.number.locale(locale).precision(.fractionLength(0...2)).grouping(.never))
            + suffixes[index]
    }

    package static func full(_ value: Decimal, locale: Locale) -> String {
        // Decimal retains up to 38 significant digits, including fractional source precision.
        value.formatted(.number.locale(locale).precision(.fractionLength(0...38)))
    }

    package static func parsePayment(_ input: String, locale: Locale) -> Decimal? {
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

    package static func decimal(_ value: Double) -> Decimal? {
        guard value.isFinite else { return nil }
        return Decimal(string: String(value), locale: Locale(identifier: "en_US_POSIX"))
    }
}

package struct TokenLedgerQuotas {
    package let fiveHour: RateWindow?
    package let weekly: RateWindow?
    package let updatedAt: Date?
    package let failed: Bool

    package init(snapshot: UsageSnapshot?, failed: Bool) {
        let windows = [snapshot?.primary, snapshot?.secondary, snapshot?.tertiary].compactMap(\.self)
        let available = windows.filter { !$0.isSyntheticPlaceholder && $0.usedPercent.isFinite }
        self.fiveHour = available.first { $0.windowMinutes == 300 }
        self.weekly = available.first { $0.windowMinutes == 7 * 24 * 60 }
        self.updatedAt = snapshot?.updatedAt
        self.failed = failed
    }

    package var staleAfter: Date? {
        self.updatedAt?.addingTimeInterval(900)
    }

    package static func progress(_ window: RateWindow) -> Double {
        min(100, max(0, window.usedPercent)) / 100
    }
}
