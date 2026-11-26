import Foundation

struct UsageSummary: Codable {
    var models: [String: TokenCounts] = [:]
    var days: [String: Int] = [:]
    var opaque = 0

    var total: Int {
        self.opaque + self.models.values.reduce(0) { $0 + $1.total }
    }

    mutating func add(_ counts: TokenCounts, model: String, day: String, removing: Bool = false) {
        if removing {
            self.models[model, default: .init()] -= counts
            self.days[day, default: 0] -= counts.total
        } else {
            self.models[model, default: .init()] += counts
            self.days[day, default: 0] += counts.total
        }
    }

    mutating func merge(_ other: Self) {
        self.models.merge(other.models, uniquingKeysWith: +)
        self.days.merge(other.days, uniquingKeysWith: +)
        self.opaque += other.opaque
    }
}

struct LedgerState: Codable {
    struct CodexThread: Codable {
        var modern = false
        var legacy: UsageSummary?
        var legacyEnd: Date?
    }

    struct ClaudeFragment: Codable {
        let request: String?
        let model: String
        let day: String
        let counts: TokenCounts
    }

    var timeZone = TimeZone.current.identifier
    var deletedThrough: Date?
    var usage: [ProviderInstanceID: UsageSummary] = [:]
    var threads: [String: CodexThread] = [:]
    var partialProviders: Set<ProviderInstanceID> = []
    var observedProviders: Set<ProviderInstanceID> = []
    var legacyDays: [ProviderInstanceID: [String: HistoryBucket]] = [:]
    var legacyUndated: [ProviderInstanceID: HistoryBucket] = [:]
    var reconciled: Set<ProviderInstanceID> = []
    var recoveredProviders: Set<ProviderInstanceID> = []

    mutating func record(_ row: UsageObservation, store: UsageStore, migrating: Bool) throws {
        guard self.deletedThrough.map({ row.date > $0 }) ?? true else { return }
        let day = Self.day(row.date, zone: self.timeZone)
        switch row.record {
        case let .modern(thread, response, prefix):
            if self.threads[thread]?.modern != true {
                let prior = self.threads[thread]
                let prefixMatches = if let prefix, let end = prior?.legacyEnd {
                    end <= prefix
                } else {
                    false
                }
                self.threads[thread] = CodexThread(modern: true, legacy: prefixMatches ? prior?.legacy : nil)
            }
            if try store.insert(.codex, response) {
                self.usage[.codex, default: .init()].add(row.counts, model: row.model, day: day)
                self.observedProviders.insert(.codex)
            }
        case let .legacy(thread, mirror):
            if migrating { _ = try store.insert(.migration, mirror) }
            guard self.threads[thread]?.modern != true else { return }
            if self.recoveredProviders.contains(.codex), try store.contains(.recovered, mirror) { return }
            // The timestamp distinguishes a new epoch that happens to reach a previous counter value.
            let key = LedgerIdentity.hash("\(mirror):\(row.date.timeIntervalSince1970):\(row.counts.signature)")
            if try store.insert(.codex, key) {
                var coverage = self.threads[thread] ?? CodexThread()
                var summary = coverage.legacy ?? UsageSummary()
                summary.add(row.counts, model: row.model, day: day)
                coverage.legacy = summary
                coverage.legacyEnd = max(coverage.legacyEnd ?? row.date, row.date)
                self.threads[thread] = coverage
                self.observedProviders.insert(.codex)
            }
        case let .claude(message, request):
            if migrating, let request { _ = try store.insert(.migration, request) }
            if self.recoveredProviders.contains(.claude), try store.contains(.recovered, request ?? message) { return }
            var fragments = try store.load([ClaudeFragment].self, .claude, message) ?? []
            let index = fragments.firstIndex { $0.request == request || $0.request == nil }
            if let index {
                let old = fragments[index]
                guard (old.request == nil && request != nil) || row.counts.total > old.counts.total else { return }
                self.usage[.claude, default: .init()].add(old.counts, model: old.model, day: old.day, removing: true)
                fragments.remove(at: index)
            } else if request == nil, !fragments.isEmpty {
                return
            }
            fragments.append(ClaudeFragment(request: request, model: row.model, day: day, counts: row.counts))
            try store.save(fragments, .claude, message)
            self.usage[.claude, default: .init()].add(row.counts, model: row.model, day: day)
            self.observedProviders.insert(.claude)
        }
    }

    func summaries() -> [ProviderInstanceID: UsageSummary] {
        var result = self.usage
        for thread in self.threads.values {
            if let legacy = thread.legacy { result[.codex, default: .init()].merge(legacy) }
        }
        for provider in Set(self.legacyDays.keys).union(self.legacyUndated.keys) {
            var summary = result[provider] ?? UsageSummary()
            for (day, old) in self.legacyDays[provider] ?? [:] {
                summary.opaque += max(0, old.tokens - summary.days[day, default: 0])
            }
            if let old = self.legacyUndated[provider] {
                summary.opaque += max(0, old.tokens - summary.total)
            }
            result[provider] = summary
        }
        return result
    }

    func totals(
        enabled: Set<ProviderInstanceID>, pending: Bool, prices: ModelPriceCatalog,
        preview: [ProviderInstanceID: UsageSummary] = [:]) -> TokenLedgerTotals
    {
        var totals = TokenLedgerTotals()
        let summaries = self.summaries()
            .merging(preview) { current, saved in current.total >= saved.total ? current : saved }
        totals.stale = enabled.isEmpty
        totals.tokenCoverageIsPartial = pending || !self.partialProviders.isEmpty || !preview.isEmpty
            || !self.observedProviders.union(summaries.keys).isSuperset(of: enabled)
        totals.priceCoverageIsPartial = totals.tokenCoverageIsPartial
        var cost: Decimal?
        for provider in self.observedProviders.union(summaries.keys) {
            let summary = summaries[provider] ?? UsageSummary()
            totals.tokens[provider] = Decimal(summary.total)
            let estimate = prices.estimate(summary, provider: provider)
            if let usd = estimate.usd.flatMap(TokenLedgerFormatting.decimal) {
                cost = (cost ?? 0) + usd
            }
            totals.priceCoverageIsPartial = totals.priceCoverageIsPartial || estimate.partial
        }
        totals.apiCosts = cost.map { [TokenLedgerAmount(currency: "USD", value: $0)] } ?? []
        return totals
    }

    static func day(_ date: Date, zone: String) -> String {
        date.formatted(Date.ISO8601FormatStyle(timeZone: TimeZone(identifier: zone) ?? .gmt)
            .year().month().day().dateSeparator(.dash))
    }
}

struct LegacyHistory: Decodable {
    struct Identity: Decodable, Hashable {
        let provider: ProviderInstanceID
        let currency: String
        let fingerprint: String
    }

    struct Bucket: Decodable {
        let tokens: Int?
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
                if source.partialTokens || source.ambiguousRotation {
                    state.partialProviders.insert(provider)
                }
                for (day, old) in source.days
                    where day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
                {
                    guard let bucket = Self.bucket(old) else { continue }
                    let previous = state.legacyDays[provider]?[day]
                    if previous != nil { state.partialProviders.insert(provider) }
                    if bucket.tokens > previous?.tokens ?? -1 {
                        state.legacyDays[provider, default: [:]][day] = bucket
                    }
                }
                let sessions = source.sessions.values.compactMap(Self.bucket)
                guard !sessions.isEmpty else { continue }
                let undated = HistoryBucket(tokens: sessions.map(\.tokens).reduce(0, +))
                let dayTotal = source.days.values.compactMap(\.tokens).reduce(0, +)
                if undated.tokens > dayTotal, undated.tokens > state.legacyUndated[provider]?.tokens ?? 0 {
                    state.legacyUndated[provider] = undated
                }
            }
        }
    }

    private static func bucket(_ old: Bucket) -> HistoryBucket? {
        guard let tokens = old.tokens, tokens >= 0 else { return nil }
        return HistoryBucket(tokens: tokens)
    }
}

struct HistoryBucket: Codable {
    let tokens: Int
}
