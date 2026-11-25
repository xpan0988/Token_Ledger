import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct TokenLedgerTests {
    @Test
    func `compact numbers preserve suffixes and promote after rounding in both languages`() {
        let cases: [(Decimal, String)] = [
            (850, "850"), (12500, "12.5K"), (4_892_000, "4.89M"), (12_842_719_306, "12.84B"),
            (1_250_000_000_000, "1.25T"), (28624, "28.62K"), (2040, "2.04K"),
            (999_994, "999.99K"), (999_995, "1M"),
        ]
        for language in TokenLedgerLanguage.allCases {
            for (value, display) in cases {
                #expect(TokenLedgerFormatting.compact(value, locale: language.locale) == display)
            }
        }
    }

    @Test
    func `quota durations preserve zero and distinguish placeholders from missing windows`() {
        let now = Date()
        let placeholder = self.window(0, minutes: 300, synthetic: true)
        let zero = self.window(0, minutes: 10080)
        let quotas = TokenLedgerQuotas(
            snapshot: UsageSnapshot(
                primary: self.window(79, minutes: 1440),
                secondary: placeholder,
                tertiary: zero,
                updatedAt: now),
            failed: true)
        #expect(quotas.fiveHour == nil)
        #expect(quotas.weekly == zero)
        #expect(quotas.failed)
        #expect(quotas.staleAfter(refreshFrequency: .thirtyMinutes) == now.addingTimeInterval(5400))
        #expect(TokenLedgerQuotas.progress(zero) == 0)
        #expect(TokenLedgerQuotas.progress(self.window(135, minutes: 300)) == 1)
    }

    @Test
    func `currency conversion preserves original amounts and requires verified rates`() {
        let amounts = [
            TokenLedgerAmount(currency: "USD", value: 10),
            TokenLedgerAmount(currency: "GBP", value: 16),
            TokenLedgerAmount(currency: "AUD", value: 6),
        ]
        let rates = TokenLedgerExchangeRates(rates: ["AUD": 1.5, "GBP": 0.8])
        #expect(rates.sum(amounts, currency: .aud) == 51)
        #expect(rates.sum(amounts, currency: .usd) == 34)
        #expect(rates.sum(amounts, currency: .cny) == nil)
        #expect(TokenLedgerExchangeRates().sum(Array(amounts.suffix(1)), currency: .aud) == 6)
        #expect(TokenLedgerExchangeRates().sum(amounts, currency: .aud) == nil)
        #expect(amounts[0].currency == "USD")
    }

    @Test
    func `payments and preferences persist and corrections update the same record`() throws {
        let domain = "TokenLedgerTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = TokenLedgerPreferences(defaults: defaults)
        #expect(preferences.options.currency == .aud)
        #expect(preferences.options.language == .english)
        #expect(preferences.text("ledger.totalPaid") == "Total Paid")
        let id = UUID()
        preferences.options.language = .chinese
        preferences.options.clickThrough = true
        preferences.save(self.payment(id: id, amount: 37.50, estimated: true))
        preferences.save(self.payment(id: id, amount: 42.18, estimated: false))
        let reloaded = TokenLedgerPreferences(defaults: defaults)
        #expect(reloaded.text("ledger.totalPaid") == "累计订阅支出")
        #expect(reloaded.options.clickThrough)
        #expect(reloaded.payments == [self.payment(id: id, amount: 42.18, estimated: false)])
        #expect(TokenLedgerFormatting.parsePayment("4.125", locale: .init(identifier: "en_AU")) == 4.125)
        #expect(TokenLedgerFormatting.parsePayment("4,125", locale: .init(identifier: "en_AU")) == nil)
        reloaded.remove(id)
        #expect(TokenLedgerPreferences(defaults: defaults).payments.isEmpty)
    }

    @Test
    func `session imports retain rotated sessions and deduplicate reappearing sessions after restart`() throws {
        var ledger = TokenLedgerHistory()
        let first = self.publication(
            rows: [self.row("2026-11-01", tokens: 4_000_000_000, cost: 15)],
            sessions: [self.session("first", tokens: 4_000_000_000, cost: 15)])
        let enabled: Set<ProviderInstanceID> = [.claude]
        #expect(ledger.ingest(first, enabledProviders: enabled).totals.totalTokens == 4_000_000_000)
        #expect(!ledger.ingest(first, enabledProviders: enabled).changed)

        let bytes = try JSONEncoder().encode(ledger)
        var restored = try JSONDecoder().decode(TokenLedgerHistory.self, from: bytes)
        let rotated = self.publication(
            rows: [self.row("2026-11-01", tokens: 1_000_000_000, cost: 5)],
            sessions: [self.session("second", tokens: 1_000_000_000, cost: 5)])
        let result = restored.ingest(rotated, enabledProviders: enabled).totals
        #expect(result.totalTokens == 5_000_000_000)
        #expect(result.apiCosts == [TokenLedgerAmount(currency: "USD", value: 20)])
        #expect(!result.tokenCoverageIsPartial)

        let recovered = self.publication(
            rows: [self.row("2026-11-01", tokens: 5_000_000_000, cost: 20)],
            sessions: [
                self.session("first", tokens: 4_000_000_000, cost: 15),
                self.session("second", tokens: 1_000_000_000, cost: 5),
            ])
        #expect(restored.ingest(recovered, enabledProviders: enabled).totals.totalTokens == 5_000_000_000)
    }

    @Test
    func `daily-only rotation retains old dates and repeated input does not add tokens`() {
        var ledger = TokenLedgerHistory()
        let enabled: Set<ProviderInstanceID> = [.claude]
        let first = self.publication(rows: [self.row("2026-11-01", tokens: 200, cost: 6)])
        #expect(ledger.ingest(first, enabledProviders: enabled).totals.totalTokens == 200)
        let later = self.publication(rows: [self.row("2026-11-02", tokens: 100, cost: 3)])
        let result = ledger.ingest(later, enabledProviders: enabled).totals
        #expect(result.totalTokens == 300)
        #expect(result.apiCosts == [TokenLedgerAmount(currency: "USD", value: 9)])
        #expect(result.tokenCoverageIsPartial)
        #expect(!ledger.ingest(later, enabledProviders: enabled).changed)
    }

    @Test
    func `unpriced token usage and vendor metered costs are excluded from the API estimate`() {
        let enabled: Set<ProviderInstanceID> = [.claude]
        var ledger = TokenLedgerHistory()
        let unpriced = self.publication(rows: [self.row("2026-11-01", tokens: 800, cost: nil)])
        let partial = ledger.ingest(unpriced, enabledProviders: enabled).totals
        #expect(partial.totalTokens == 800)
        #expect(partial.apiCosts.isEmpty)
        #expect(partial.priceCoverageIsPartial)
        let metered = self.publication(
            rows: [self.row("2026-11-01", tokens: 800, cost: 12)], provenance: .vendorMetered)
        #expect(ledger.ingest(metered, enabledProviders: enabled).totals.apiCosts.isEmpty)
    }

    @Test
    func `stale data stays in its account scope`() {
        var ledger = TokenLedgerHistory()
        let enabled: Set<ProviderInstanceID> = [.claude]
        _ = ledger.ingest(
            self.publication(rows: [self.row("2026-11-01", tokens: 900, cost: 8)]), enabledProviders: enabled)
        let unavailable = ledger.ingest(
            self.publication(rows: [], state: .unavailable), enabledProviders: enabled).totals
        #expect(unavailable.totalTokens == 900)
        #expect(unavailable.stale)
        let changed = ledger.ingest(
            self.publication(rows: [], owner: "other", state: .unavailable), enabledProviders: enabled).totals
        #expect(changed.totalTokens == nil)
        #expect(changed.priceCoverageIsPartial)
    }

    @Test
    func `screen positions clamp and snap to visible edges including negative origins`() {
        #expect(TokenLedgerPanelController.constrain(-300, to: -188...1290, snap: false) == -188)
        #expect(TokenLedgerPanelController.constrain(-182, to: -188...1290, snap: true) == -180)
        #expect(TokenLedgerPanelController.constrain(1281, to: -188...1290, snap: true) == 1282)
        #expect(TokenLedgerPanelController.constrain(950, to: -188...1290, snap: true) == 950)
    }

    private func window(_ used: Double, minutes: Int, synthetic: Bool = false) -> RateWindow {
        RateWindow(
            usedPercent: used,
            windowMinutes: minutes,
            resetsAt: nil,
            resetDescription: nil,
            isSyntheticPlaceholder: synthetic)
    }

    private func payment(id: UUID, amount: Decimal, estimated: Bool) -> TokenLedgerPayment {
        TokenLedgerPayment(
            id: id, provider: .codex, providerName: "Codex", amount: amount, currency: .usd, estimated: estimated)
    }

    private func row(_ date: String, tokens: Int, cost: Double?) -> CostUsageDailyReport.Entry {
        CostUsageDailyReport.Entry(
            date: date,
            inputTokens: 100,
            outputTokens: 50,
            cacheReadTokens: 75,
            totalTokens: tokens,
            costUSD: cost,
            modelsUsed: nil,
            modelBreakdowns: nil,
            unpricedRequestCount: cost == nil ? 1 : 0)
    }

    private func session(_ id: String, tokens: Int, cost: Double) -> CostUsageSessionBreakdown {
        CostUsageSessionBreakdown(
            sessionID: id,
            lastActivity: Date(),
            inputTokens: nil,
            cachedInputTokens: nil,
            outputTokens: nil,
            totalTokens: tokens,
            requestCount: 1,
            costUSD: cost,
            modelBreakdowns: [])
    }

    private func publication(
        rows: [CostUsageDailyReport.Entry],
        sessions: [CostUsageSessionBreakdown] = [],
        provenance: CostProvenance = .listPriceEstimate,
        owner: String = "default",
        state: SpendSourcePublication.State = .available) -> SpendDashboardPublication
    {
        let now = Date()
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: rows.compactMap(\.totalTokens).reduce(0, +),
            last30DaysCostUSD: rows.compactMap(\.costUSD).reduce(0, +),
            costProvenance: provenance,
            daily: rows,
            sessions: sessions,
            detailsAreComplete: !sessions.isEmpty,
            updatedAt: now)
        let input = SpendDashboardModel.ProviderInput(provider: .claude, displayName: "Claude", snapshot: snapshot)
        return SpendDashboardPublication(
            revision: 1,
            generation: 1,
            configuration: SpendDashboardConfiguration(
                costUsageEnabled: true,
                providerIDs: ["claude"],
                codexAccountIdentities: [],
                sourceOwnershipFingerprints: ["claude:\(UUID())"],
                recordedUsageScopes: ["claude": owner],
                bucketTimeZoneIdentifier: "UTC"),
            loadedAt: now,
            isRefreshing: false,
            inputs: state == .available ? [input] : [],
            sources: [
                SpendSourcePublication(
                    id: "claude", provider: .claude, displayName: "Claude", role: .subscription, state: state),
            ])
    }
}
