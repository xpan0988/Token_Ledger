import LedgerCore
import SwiftUI

struct TokenLedgerProvider: Identifiable {
    let id: ProviderInstanceID
    let name: String
    let quotas: TokenLedgerQuotas

    static func accent(_ id: ProviderInstanceID) -> Color {
        let palette: [UInt32] = [0xC8ABCD, 0x98B8C8, 0xC2AD80, 0xAAB58B, 0xC78F9B, 0x85B7AE, 0xB1A4CE]
        let hex: UInt32 = switch id {
        case .codex: 0xA3BFAD
        case .claude: 0xD7A087
        case .gemini: 0x929AF7
        default: palette[id.rawValue.utf8.reduce(0) { ($0 * 31 + Int($1)) % palette.count }]
        }
        return Color(
            red: Double((hex >> 16) & 255) / 255,
            green: Double((hex >> 8) & 255) / 255,
            blue: Double(hex & 255) / 255)
    }
}

struct TokenLedgerPanelView: View {
    let preferences: TokenLedgerPreferences
    let data: TokenLedgerData
    let openSettings: () -> Void

    private var background: Color {
        Color(red: 25 / 255, green: 25 / 255, blue: 27 / 255)
    }

    private var foreground: Color {
        Color(red: 0.94, green: 0.93, blue: 0.93)
    }

    private var secondary: Color {
        Color(white: 0.66)
    }

    private var providers: [TokenLedgerProvider] {
        ProviderInstanceID.supported
            .filter { !self.preferences.options.hiddenProviders.contains($0) }
            .map { id in
                TokenLedgerProvider(
                    id: id,
                    name: id.displayName,
                    quotas: TokenLedgerQuotas(
                        snapshot: self.data.quotas[id],
                        failed: self.data.quotaFailures.contains(id)))
            }
    }

    var body: some View {
        let providers = self.providers
        let shape = RoundedRectangle(cornerRadius: 13)
        VStack(spacing: 0) {
            self.header
            self.providerRow(providers)
                .padding(.top, 3)
            Rectangle()
                .fill(.white.opacity(0.09))
                .frame(height: 1)
                .padding(.top, 4)
                .padding(.bottom, 4)
            self.tokenSummary(providerOrder: providers.map(\.id))
            self.financialSummary
                .padding(.top, 4)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(self.foreground)
        .background(self.background, in: shape)
        .overlay { shape.strokeBorder(.white.opacity(0.12), lineWidth: 1).allowsHitTesting(false) }
        .clipShape(shape)
        .environment(\.colorScheme, .dark)
        .contextMenu {
            Button(self.preferences.text("ledger.settings"), action: self.openSettings)
            Button(self.preferences.text("ledger.enableClickThrough")) {
                self.preferences.options.clickThrough = true
            }
            Button(self.preferences.text("ledger.hide")) { self.preferences.toggleVisibility() }
        }
    }

    private var header: some View {
        HStack {
            Text(self.preferences.text("ledger.title").uppercased(with: self.preferences.options.language.locale))
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.25)
                .foregroundStyle(self.secondary)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button(action: self.openSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 22, height: 17)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(self.secondary)
            .help(self.preferences.text("ledger.settings"))
            .accessibilityLabel(self.preferences.text("ledger.settings"))
        }
    }

    private func providerRow(_ providers: [TokenLedgerProvider]) -> some View {
        let now = Date()
        let changes = providers.flatMap { provider in
            [
                provider.quotas.staleAfter,
                provider.quotas.fiveHour?.resetsAt,
                provider.quotas.weekly?.resetsAt,
            ].compactMap(\.self)
        }
        let dates = [now] + changes.filter { $0 > now }.sorted()
        return TimelineView(.explicit(dates)) { context in
            let timestamp = max(context.date, now)
            if providers.isEmpty {
                Text(self.preferences.text("ledger.noProviders"))
                    .font(.system(size: 10))
                    .foregroundStyle(self.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                GeometryReader { geometry in
                    ScrollView(.horizontal) {
                        HStack(spacing: 3) {
                            ForEach(providers) { provider in
                                TokenLedgerQuotaView(
                                    provider: provider,
                                    preferences: self.preferences,
                                    now: timestamp)
                                    .frame(width: max(56, (geometry.size.width + 3) / CGFloat(providers.count) - 3))
                            }
                        }
                    }
                    .scrollIndicators(.never)
                }
                .frame(height: 60)
            }
        }
    }

    private func tokenSummary(providerOrder: [ProviderInstanceID]) -> some View {
        let totals = self.data.totals
        let number = totals.totalTokens
        let notes = [
            self.preferences.text("ledger.recordedOnly"),
            totals.tokenCoverageIsPartial ? self.preferences.text("ledger.partialTokens") : nil,
            totals.stale ? self.preferences.text("ledger.lastKnown") : nil,
            self.data.persistenceFailed ? self.preferences.text("ledger.persistenceFailed") : nil,
        ].compactMap(\.self)
        return VStack(spacing: 1) {
            Text(self.preferences.text("ledger.totalTokens").uppercased(with: self.preferences.options.language.locale))
                .font(.system(size: 9, weight: .medium))
                .tracking(0.85)
                .foregroundStyle(self.secondary)
            Text(self.displayValue(number))
                .font(.system(size: 23, weight: .semibold))
                .monospacedDigit()
                .contentTransition(.identity)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .foregroundStyle(totals.stale && number != nil ? self.secondary : self.foreground)
            TokenLedgerDistribution(tokens: totals.tokens, providerOrder: providerOrder)
                .frame(width: 172, height: 3)
                .padding(.top, 1)
                .accessibilityHidden(true)
        }
        .help(self.tooltip(number: number, currency: nil, notes: notes))
        .accessibilityElement(children: .combine)
    }

    private var financialSummary: some View {
        let currency = self.preferences.options.currency
        let totals = self.data.totals
        let payments = self.preferences.payments
        let paidAmounts = payments.map { TokenLedgerAmount(currency: $0.currency.rawValue, value: $0.amount) }
        let priceNotes = [
            self.preferences.text("ledger.estimateOnly"),
            totals.priceCoverageIsPartial ? self.preferences.text("ledger.partialCost") : nil,
            totals.stale ? self.preferences.text("ledger.lastKnown") : nil,
        ].compactMap(\.self)
        let includesEstimates = payments.contains(where: \.estimated)
        let paymentNotes = includesEstimates ? [self.preferences.text("ledger.includesEstimates")] : []
        return HStack(spacing: 10) {
            self.moneyMetric(
                title: "ledger.apiEquivalent",
                amounts: totals.apiCosts,
                currency: currency,
                notes: priceNotes)
            self.moneyMetric(
                title: "ledger.totalPaid",
                amounts: paidAmounts,
                currency: currency,
                approximate: includesEstimates,
                notes: paymentNotes)
        }
    }

    private func moneyMetric(
        title: String,
        amounts: [TokenLedgerAmount],
        currency: TokenLedgerCurrency,
        approximate: Bool = false,
        notes: [String]) -> some View
    {
        let number = self.data.exchange.sum(amounts, currency: currency.rawValue)
        let needsRates = amounts.contains { $0.currency != currency.rawValue && $0.value != 0 }
        var details = notes
        if needsRates {
            if number == nil {
                details.append(self.preferences.text("ledger.noConversion"))
            } else if let fetchedAt = self.data.exchange.fetchedAt {
                let format = Date.FormatStyle(date: .abbreviated, time: .omitted)
                    .locale(self.preferences.options.language.locale)
                details.append(self.preferences.text("ledger.rateDate", fetchedAt.formatted(format)))
            }
        }
        return VStack(spacing: 1) {
            Text(self.preferences.text(title))
                .font(.system(size: 10))
                .foregroundStyle(self.secondary)
            Text(self.displayValue(number, currency: currency, approximate: approximate))
                .font(.system(size: 15, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(number == nil ? self.secondary : self.foreground)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(maxWidth: .infinity)
        .help(self.tooltip(number: number, currency: currency, notes: details))
        .accessibilityElement(children: .combine)
    }

    private func displayValue(
        _ value: Decimal?,
        currency: TokenLedgerCurrency? = nil,
        approximate: Bool = false) -> String
    {
        guard let value else { return "—" }
        let prefix = approximate ? "≈" : ""
        let language = self.preferences.options.language
        return prefix + (currency?.symbol ?? "")
            + TokenLedgerFormatting.compact(
                value,
                locale: language.locale,
                chineseUnits: currency == nil && language == .chinese)
    }

    private func tooltip(number: Decimal?, currency: TokenLedgerCurrency?, notes: [String]) -> String {
        let prefix = currency.map { $0.rawValue + " " } ?? ""
        let full = number
            .map { prefix + TokenLedgerFormatting.full($0, locale: self.preferences.options.language.locale) }
        return ([full ?? self.preferences.text("ledger.unavailable")] + notes).joined(separator: "\n")
    }
}

private struct TokenLedgerDistribution: View {
    let tokens: [ProviderInstanceID: Decimal]
    let providerOrder: [ProviderInstanceID]

    var body: some View {
        Canvas { context, size in
            let listed = Set(self.providerOrder)
            let remainder = self.tokens.keys.filter { !listed.contains($0) }.sorted { $0.rawValue < $1.rawValue }
            let entries = (self.providerOrder + remainder).compactMap { id -> (ProviderInstanceID, Decimal)? in
                guard let tokens = self.tokens[id], tokens > 0 else { return nil }
                return (id, tokens)
            }
            let total = entries.reduce(Decimal.zero) { $0 + $1.1 }
            if total == 0 {
                let frame = CGRect(origin: .zero, size: size)
                context.fill(Path(roundedRect: frame, cornerRadius: size.height / 2), with: .color(.white.opacity(0.1)))
                return
            }
            let gap = min(2, size.width / CGFloat(entries.count * 3))
            let segmentWidth = size.width - gap * CGFloat(entries.count - 1)
            var start: CGFloat = 0
            for (id, tokens) in entries {
                let length = segmentWidth * NSDecimalNumber(decimal: tokens / total).doubleValue
                let frame = CGRect(x: start, y: 0, width: length, height: size.height)
                context.fill(
                    Path(roundedRect: frame, cornerRadius: min(length, size.height) / 2),
                    with: .color(TokenLedgerProvider.accent(id)))
                start += length + gap
            }
        }
    }
}
