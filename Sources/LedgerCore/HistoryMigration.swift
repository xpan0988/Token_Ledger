import Foundation

/// Read only the fields used to recover usage whose original transcript disappeared.
struct PriorLedger: Decodable {
    struct Pricing: Decodable {
        let model: String?
        let tokens: TokenCounts
        let oneHour: Int?
        let codexCacheRetention: String?
    }

    struct Event: Decodable {
        let provider: ProviderInstanceID
        let day: String
        let tokens: Int
        let pricing: Pricing?
        let authoritative: Bool

        var counts: TokenCounts? {
            guard var counts = self.pricing?.tokens else { return nil }
            if self.provider == .codex {
                counts.input -= counts.cached + counts.written
                if self.pricing?.codexCacheRetention == "12h" { counts.longWrites = counts.written }
            } else {
                counts.longWrites = min(counts.written, max(0, self.pricing?.oneHour ?? 0))
            }
            return counts.total == self.tokens && min(counts.input, counts.cached, counts.written, counts.output) >= 0
                ? counts : nil
        }
    }

    struct Metadata: Decodable {
        let timeZone: String
        let deletedThrough: Date?
        let observedProviders: Set<ProviderInstanceID>
        let legacyDays: [ProviderInstanceID: [String: HistoryBucket]]
        let legacyUndated: [ProviderInstanceID: HistoryBucket]
    }

    let events: [String: Event]

    func reconcile(_ provider: ProviderInstanceID, into state: inout LedgerState, store: UsageStore) throws {
        let replay = state.summaries()[provider] ?? UsageSummary()
        for (id, event) in self.events where event.provider == provider && event.tokens > 0 {
            if provider == .codex {
                if try store.contains(.codex, id) || store.contains(.migration, id) { continue }
                // A missing legacy row on a replayed day has no evidence of disjoint usage.
                if !event.authoritative, replay.days[event.day, default: 0] > 0 { continue }
                if event.authoritative {
                    _ = try store.insert(.codex, id)
                } else {
                    _ = try store.insert(.recovered, id)
                    state.recoveredProviders.insert(provider)
                }
            } else if try store.contains(.claude, id) || store.contains(.migration, id) {
                continue
            } else {
                _ = try store.insert(.recovered, id)
                state.recoveredProviders.insert(provider)
            }
            if let counts = event.counts {
                state.usage[provider, default: .init()].add(counts, model: event.pricing?.model ?? "", day: event.day)
            } else {
                state.usage[provider, default: .init()].opaque += event.tokens
                state.usage[provider, default: .init()].days[event.day, default: 0] += event.tokens
            }
        }
        state.reconciled.insert(provider)
    }

    func preview(for providers: Set<ProviderInstanceID>) -> [ProviderInstanceID: UsageSummary] {
        var result: [ProviderInstanceID: UsageSummary] = [:]
        for event in self.events.values where providers.contains(event.provider) && event.tokens > 0 {
            if let counts = event.counts {
                result[event.provider, default: .init()].add(
                    counts, model: event.pricing?.model ?? "", day: event.day)
            } else {
                result[event.provider, default: .init()].opaque += event.tokens
            }
        }
        return result
    }
}
