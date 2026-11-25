import CodexBarCore
import CryptoKit
import Foundation

struct TokenLedgerAmount: Sendable, Equatable {
    let currency: String
    let value: Decimal
}

struct TokenLedgerTotals: Sendable, Equatable {
    var tokens: [ProviderInstanceID: Decimal] = [:]
    var apiCosts: [TokenLedgerAmount] = []
    var tokenCoverageIsPartial = false
    var priceCoverageIsPartial = false
    var stale = false

    var totalTokens: Decimal? {
        self.tokens.isEmpty ? nil : self.tokens.values.reduce(0, +)
    }
}

struct TokenLedgerHistory: Codable, Sendable {
    private struct Bucket: Codable, Equatable {
        let tokens: Int?
        let cost: Decimal?

        /// Retain a larger previous observation when the new bucket is a subset.
        func merging(_ current: Self) -> Self {
            if let tokens = self.tokens, current.tokens == nil || tokens > current.tokens ?? 0 {
                return self
            }
            return Self(tokens: current.tokens, cost: current.cost ?? self.cost)
        }
    }

    private struct Source: Codable, Equatable {
        var days: [String: Bucket] = [:]
        var sessions: [String: Bucket] = [:]
        var hasConfirmedEmpty = false
        var partialTokens = false
        var partialPrices = false
        var ambiguousRotation = false

        var tokenCount: Decimal? {
            let candidates = [Self.sumTokens(self.days), Self.sumTokens(self.sessions)].compactMap(\.self)
            return candidates.max() ?? (self.hasConfirmedEmpty ? 0 : nil)
        }

        var price: Decimal? {
            let sessionTokens = Self.sumTokens(self.sessions) ?? 0
            let dayTokens = Self.sumTokens(self.days) ?? 0
            let primary = sessionTokens > dayTokens ? self.sessions : self.days
            let prices = primary.values.compactMap(\.cost)
            return prices.isEmpty ? nil : prices.reduce(0, +)
        }

        mutating func ingest(_ snapshot: CostUsageTokenSnapshot, calendar: Calendar) {
            let eligiblePrice = snapshot.costProvenance == .listPriceEstimate
            var dayRows: [String: Bucket] = [:]
            var incompleteTokens = false
            var incompletePrices = false
            for row in snapshot.daily {
                guard let day = CostUsageTokenSnapshot.localDayKey(for: row.date, calendar: calendar) else {
                    incompleteTokens = true
                    incompletePrices = true
                    continue
                }
                let tokens = row.totalTokens.flatMap { $0 >= 0 ? $0 : nil }
                let cost = eligiblePrice ? Self.cost(row.costUSD) : nil
                incompleteTokens = incompleteTokens || tokens == nil || row.incompleteRequestCount > 0
                incompletePrices = incompletePrices || (row.unpricedRequestCount ?? 0) > 0
                    || row.incompleteRequestCount > 0 || (cost == nil && tokens != 0)
                let previous = dayRows[day]
                dayRows[day] = Bucket(
                    tokens: Self.add(previous?.tokens, tokens),
                    cost: Self.add(previous?.cost, cost))
            }

            let observedTokens = Self.sumTokens(dayRows)
            if let expected = snapshot.last30DaysTokens, expected != 0,
               observedTokens != Decimal(expected)
            {
                incompleteTokens = true
            }

            var sessionRows: [String: Bucket] = [:]
            var sessionsCoverDays = snapshot.detailsAreComplete && !snapshot.historyScanIsPartial
                && !incompleteTokens && observedTokens != nil && !snapshot.sessions.isEmpty
            if sessionsCoverDays {
                for session in snapshot.sessions {
                    guard let tokens = session.totalTokens, tokens >= 0 else {
                        sessionsCoverDays = false
                        break
                    }
                    let key = TokenLedgerHistory.fingerprint(session.sessionID)
                    guard sessionRows[key] == nil else {
                        sessionsCoverDays = false
                        break
                    }
                    sessionRows[key] = Bucket(tokens: tokens, cost: eligiblePrice ? Self.cost(session.costUSD) : nil)
                }
                sessionsCoverDays = sessionsCoverDays && Self.sumTokens(sessionRows) == observedTokens
            }

            if sessionsCoverDays {
                // Complete session projections reconcile with the upstream daily total. A rotated
                // session can be kept without masking new sessions that occur on the same day.
                self.sessions.merge(sessionRows) { $0.merging($1) }
            } else if self.days.contains(where: { key, value in
                guard let tokens = value.tokens, tokens > 0 else { return false }
                return (dayRows[key]?.tokens ?? 0) < tokens
            }) {
                // Daily-only feeds cannot prove whether a shrinking bucket and a later increase overlap.
                self.ambiguousRotation = true
            }
            self.days.merge(dayRows) { $0.merging($1) }
            self.hasConfirmedEmpty = self.hasConfirmedEmpty ||
                (snapshot.last30DaysTokens == 0 && snapshot.historyCoverageIsEstablished && dayRows.isEmpty)
            self.partialTokens = incompleteTokens || snapshot.historyScanIsPartial || !snapshot
                .historyCoverageIsEstablished
            self.partialPrices = incompletePrices || self.partialTokens
        }

        private static func sumTokens(_ rows: [String: Bucket]) -> Decimal? {
            let tokens = rows.values.compactMap(\.tokens)
            return tokens.isEmpty ? nil : tokens.reduce(Decimal.zero) { $0 + Decimal($1) }
        }

        private static func cost(_ value: Double?) -> Decimal? {
            guard let value, value >= 0 else { return nil }
            return TokenLedgerFormatting.decimal(value)
        }

        private static func add(_ left: Int?, _ right: Int?) -> Int? {
            guard let left, let right else { return left ?? right }
            let sum = left.addingReportingOverflow(right)
            return sum.overflow ? nil : sum.partialValue
        }

        private static func add(_ left: Decimal?, _ right: Decimal?) -> Decimal? {
            guard let left, let right else { return left ?? right }
            return left + right
        }
    }

    private struct SourceKey: Codable, Hashable {
        let provider: ProviderInstanceID
        let currency: String
        let fingerprint: String
    }

    private var sources: [SourceKey: Source] = [:]
    private var selected: [ProviderInstanceID: [SourceKey]] = [:]

    mutating func ingest(
        _ publication: SpendDashboardPublication,
        enabledProviders: Set<ProviderInstanceID>) -> (totals: TokenLedgerTotals, changed: Bool)
    {
        guard let config = publication.configuration, config.costUsageEnabled else {
            return (self.totals(stale: true), false)
        }
        // The shared pipeline owns Pi reconciliation and the OpenCodex replacement policy.
        let visible = SpendDashboardModel.visibleInputs(
            publication.inputs,
            hiddenSourceIDs: [],
            hideNativeCodexWhenOpenCodexPresent: config.hideNativeCodexCostWhenOpenCodexPresent)
        let visibleIDs = Set(visible.map(\.id))
        let states = Dictionary(publication.sources.map { ($0.id, $0.state) }, uniquingKeysWith: { first, _ in first })
        var current: [ProviderInstanceID: [SourceKey]] = [:]
        var changed = false
        for input in visible where enabledProviders.contains(input.provider) {
            let currency = input.snapshot.currencyCode
            let key = Self.key(provider: input.provider, source: input.id, currency: currency, config: config)
            current[input.provider, default: []].append(key)
            guard states[input.id] != .staleLastKnown else { continue }
            var source = self.sources[key] ?? Source()
            source.ingest(input.snapshot, calendar: config.bucketCalendar)
            if source != self.sources[key] {
                self.sources[key] = source
                changed = true
            }
        }
        for source in publication.sources where !visibleIDs.contains(source.id) {
            guard let provider = source.provider, enabledProviders.contains(provider) else { continue }
            if config.hideNativeCodexCostWhenOpenCodexPresent, source.role == .subscription,
               provider == .codex, visibleIDs.contains(SpendDashboardModel.openCodexSourceID)
            { continue }
            let identity = Self.key(provider: provider, source: source.id, currency: "USD", config: config)
            let candidates = (self.selected[provider] ?? []).filter { $0.fingerprint == identity.fingerprint }
            let keys = candidates.isEmpty ? [identity] : candidates
            current[provider, default: []].append(contentsOf: keys)
            if source.state == .confirmedEmpty, self.sources[keys[0]] == nil {
                self.sources[keys[0]] = Source(hasConfirmedEmpty: true)
                changed = true
            }
        }
        for (provider, keys) in current where !publication.isRefreshing {
            let next = Set(keys)
            if next != Set(self.selected[provider] ?? []) {
                self.selected[provider] = Array(next)
                changed = true
            }
        }
        let stale = publication.sources.contains { $0.state == .staleLastKnown || $0.state == .unavailable }
        var totals = self.totals(stale: stale || publication.isRefreshing, using: current)
        let configuredIDs = Set(config.providerIDs.compactMap {
            ProviderInstanceID(rawValue: $0.replacingOccurrences(of: "plugin/", with: ""))
        })
        let unavailable = !configuredIDs.isSuperset(of: enabledProviders)
        totals.tokenCoverageIsPartial = totals.tokenCoverageIsPartial || unavailable
        totals.priceCoverageIsPartial = totals.priceCoverageIsPartial || unavailable
        return (totals, changed)
    }

    func totals(
        stale: Bool,
        enabledProviders: Set<ProviderInstanceID>? = nil) -> TokenLedgerTotals
    {
        var result = self.totals(stale: stale, using: [:])
        if let enabledProviders, !Set(result.tokens.keys).isSuperset(of: enabledProviders) {
            result.tokenCoverageIsPartial = true
            result.priceCoverageIsPartial = true
        }
        return result
    }

    private func totals(
        stale: Bool,
        using current: [ProviderInstanceID: [SourceKey]]) -> TokenLedgerTotals
    {
        var totals = TokenLedgerTotals(stale: stale)
        let selection = self.selected.merging(current) { _, new in new }
        var apiCosts: [String: Decimal] = [:]
        for (provider, keys) in selection {
            for key in Set(keys) {
                guard let source = self.sources[key], let tokens = source.tokenCount else {
                    totals.tokenCoverageIsPartial = true
                    totals.priceCoverageIsPartial = true
                    continue
                }
                totals.tokens[provider, default: 0] += tokens
                totals.tokenCoverageIsPartial = totals.tokenCoverageIsPartial
                    || source.partialTokens || source.ambiguousRotation
                totals.priceCoverageIsPartial = totals.priceCoverageIsPartial
                    || source.partialPrices || source.ambiguousRotation || (source.price == nil && tokens > 0)
                if let value = source.price {
                    apiCosts[key.currency, default: 0] += value
                }
            }
        }
        totals.apiCosts = apiCosts.sorted { $0.key < $1.key }
            .map { TokenLedgerAmount(currency: $0.key, value: $0.value) }
        return totals
    }

    private static func key(
        provider: ProviderInstanceID,
        source: String,
        currency: String,
        config: SpendDashboardConfiguration) -> SourceKey
    {
        let ownership = config.recordedUsageScopes[source]
        let scope = "\(source)|\(ownership ?? "")|\(config.bucketCalendar.timeZone.identifier)|"
            + "\(config.openCodexUsageLogsEnabled)|\(config.providerIDs.contains(UsageProvider.pi.rawValue))"
        return SourceKey(provider: provider, currency: currency, fingerprint: Self.fingerprint(scope))
    }

    private static func fingerprint(_ value: String) -> String {
        Data(SHA256.hash(data: Data(value.utf8))).base64EncodedString()
    }
}
