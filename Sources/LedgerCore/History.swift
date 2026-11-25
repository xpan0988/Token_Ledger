import Foundation

struct HistoryBucket: Codable {
    var tokens: Decimal
    var cost: Decimal?
    var currency = "USD"
    var unpriced = false

    mutating func add(_ other: Self) {
        self.tokens += other.tokens
        if let cost = other.cost { self.cost = (self.cost ?? 0) + cost }
        self.unpriced = self.unpriced || other.unpriced
    }
}

struct HistoricalEvent: Codable {
    let provider: ProviderInstanceID
    let day: String
    let tokens: Decimal
    let cost: Double?
    let authoritative: Bool
}

struct LedgerState: Codable {
    var timeZone = TimeZone.current.identifier
    var deletedThrough: Date?
    var events: [String: HistoricalEvent] = [:]
    var aliases: [String: String] = [:]
    var ambiguousAliases: Set<String> = []
    var cursors: [String: TranscriptCursor] = [:]
    var partialProviders: Set<ProviderInstanceID> = []
    var observedProviders: Set<ProviderInstanceID> = []
    var legacyDays: [ProviderInstanceID: [String: HistoryBucket]] = [:]
    var legacyUndated: [ProviderInstanceID: HistoryBucket] = [:]

    mutating func record(_ row: UsageObservation, provider: ProviderInstanceID) {
        guard self.deletedThrough.map({ row.date > $0 }) ?? true else { return }
        let day = Self.day(row.date, zone: self.timeZone)
        let mapped = row.alias.flatMap { self.aliases[$0] }
        if !row.authoritative {
            if self.ambiguousAliases.contains(row.identity) { self.partialProviders.insert(provider) }
            if self.aliases[row.identity] != nil { return }
        }
        if let prior = self.events[row.identity] {
            guard prior.provider == provider else { return }
            if prior.day != day { self.partialProviders.insert(provider) }
            // Keep the largest complete observation of a request. Streamed rows can
            // carry progressively larger output totals under the same message ID.
            guard row.tokens > prior.tokens
                || (row.tokens == prior.tokens && prior.cost == nil && row.cost != nil)
            else { return }
        } else if let alias = row.alias {
            if let weak = self.events[alias], !weak.authoritative {
                self.events.removeValue(forKey: alias)
            }
            if let mapped, mapped != row.identity { self.ambiguousAliases.insert(alias) }
            self.aliases[alias] = mapped ?? row.identity
        }
        self.events[row.identity] = HistoricalEvent(
            provider: provider,
            day: day,
            tokens: row.tokens,
            cost: row.cost,
            authoritative: row.authoritative)
        self.observedProviders.insert(provider)
    }

    mutating func delete(through cutoff: Date) {
        self = LedgerState(timeZone: self.timeZone, deletedThrough: cutoff, cursors: self.cursors)
    }

    func totals(stale: Bool, partial: Bool) -> TokenLedgerTotals {
        var totals = TokenLedgerTotals()
        totals.stale = stale
        totals.tokenCoverageIsPartial = partial || !self.partialProviders.isEmpty
        var current: [ProviderInstanceID: [String: HistoryBucket]] = [:]
        for event in self.events.values {
            let cost = event.cost.flatMap(TokenLedgerFormatting.decimal)
            current[event.provider, default: [:]][event.day, default: HistoryBucket(tokens: 0)]
                .add(HistoryBucket(tokens: event.tokens, cost: cost, unpriced: cost == nil))
        }
        var amounts: [String: Decimal] = [:]
        let providers = Set(current.keys).union(self.legacyDays.keys).union(self.legacyUndated.keys)
        for provider in providers {
            var dates = current[provider] ?? [:]
            for (day, old) in self.legacyDays[provider] ?? [:] {
                if let new = dates[day] {
                    // The old checkpoint lacks event IDs. Day boundaries prove that
                    // different dates are disjoint. A shared day is a lower bound.
                    totals.tokenCoverageIsPartial = true
                    let retained = new.tokens >= old.tokens ? new : old
                    dates[day] = retained
                } else {
                    dates[day] = old
                }
            }
            let dated = dates.values.reduce(Decimal.zero) { $0 + $1.tokens }
            if let old = self.legacyUndated[provider], old.tokens > dated {
                totals.tokens[provider] = old.tokens
                if let cost = old.cost { amounts[old.currency, default: 0] += cost }
                totals.priceCoverageIsPartial = true
            } else {
                totals.tokens[provider] = dated
                for bucket in dates.values {
                    if let cost = bucket.cost { amounts[bucket.currency, default: 0] += cost }
                    totals.priceCoverageIsPartial = totals.priceCoverageIsPartial || bucket.unpriced
                }
            }
            totals.tokenCoverageIsPartial = totals.tokenCoverageIsPartial || self.legacyUndated[provider] != nil
        }
        for provider in self.observedProviders where totals.tokens[provider] == nil {
            totals.tokens[provider] = 0
        }
        totals.priceCoverageIsPartial = totals.priceCoverageIsPartial || totals.tokenCoverageIsPartial
        totals.apiCosts = amounts.sorted { $0.key < $1.key }
            .map { TokenLedgerAmount(currency: $0.key, value: $0.value) }
        return totals
    }

    static func day(_ date: Date, zone: String) -> String {
        let style = Date.ISO8601FormatStyle(timeZone: TimeZone(identifier: zone) ?? .gmt)
            .year().month().day().dateSeparator(.dash)
        return date.formatted(style)
    }
}

/// The shapes are the direct Codable layouts of the embedded app's checkpoint.
/// Source identities and session-only totals from it carry no date-level join evidence.
struct LegacyHistory: Decodable {
    struct Identity: Decodable, Hashable {
        let provider: ProviderInstanceID
        let currency: String
        let fingerprint: String
    }

    struct Bucket: Decodable {
        let tokens: Decimal?
        let cost: Decimal?
    }

    struct Source: Decodable {
        let days: [String: Bucket]
        let sessions: [String: Bucket]
        let hasConfirmedEmpty: Bool
        let partialTokens: Bool
        let partialPrices: Bool
        let ambiguousRotation: Bool
    }

    let sources: [Identity: Source]
    let selected: [ProviderInstanceID: [Identity]]

    func importSelected(into state: inout LedgerState) {
        for (provider, keys) in self.selected {
            for key in Set(keys) where key.provider == provider {
                guard let source = self.sources[key] else { continue }
                if source.hasConfirmedEmpty { state.observedProviders.insert(provider) }
                if source.partialTokens || source.partialPrices || source.ambiguousRotation {
                    state.partialProviders.insert(provider)
                }
                for (day, old) in source.days
                    where day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
                {
                    guard let bucket = Self.bucket(old, currency: key.currency) else { continue }
                    let previous = state.legacyDays[provider]?[day]
                    if previous != nil { state.partialProviders.insert(provider) }
                    if bucket.tokens > previous?.tokens ?? -1 {
                        state.legacyDays[provider, default: [:]][day] = bucket
                    }
                }
                let sessions = source.sessions.values.compactMap { Self.bucket($0, currency: key.currency) }
                guard !sessions.isEmpty else { continue }
                var undated = HistoryBucket(tokens: 0, currency: key.currency)
                for session in sessions {
                    undated.add(session)
                }
                let dayTotal = source.days.values.compactMap(\.tokens).reduce(Decimal.zero, +)
                if undated.tokens > dayTotal, undated.tokens > state.legacyUndated[provider]?.tokens ?? 0 {
                    state.legacyUndated[provider] = undated
                }
            }
        }
    }

    private static func bucket(_ old: Bucket, currency: String) -> HistoryBucket? {
        guard let tokens = old.tokens, !tokens.isNaN, tokens >= 0 else { return nil }
        let cost = old.cost.flatMap { !$0.isNaN && $0 >= 0 ? $0 : nil }
        return HistoryBucket(tokens: tokens, cost: cost, currency: currency, unpriced: cost == nil && tokens > 0)
    }
}
