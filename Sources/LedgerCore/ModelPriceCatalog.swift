import Foundation

struct PriceQuote: Sendable {
    enum Basis: String {
        case verifiedHistory, datedHistory, bundled, current
    }

    let usd: Double
    let basis: Basis
}

struct CatalogProviders<Value: Decodable & Sendable>: Decodable, Sendable {
    let openai: Value
    let anthropic: Value

    func value(for provider: ProviderInstanceID) -> Value? {
        switch provider {
        case .codex: self.openai
        case .claude: self.anthropic
        default: nil
        }
    }
}

struct CatalogRate: Decodable, Sendable {
    struct Threshold: Decodable, Sendable {
        let type: String
        let size: Int
    }

    let input: Double?
    let output: Double?
    let cacheRead: Double?
    let cacheWrite: Double?
    let cacheWrite1hMultiple: Double?
    let above: Int?
    let tier: Threshold?
    let tiers: [Self]?
    let regions: [String: Double]?
    let validFrom: Date?
    let validFromBasis: String?

    var contextThreshold: Int? {
        self.above ?? (self.tier?.type == "context" ? self.tier?.size : nil)
    }

    var hasListPrice: Bool {
        [self.input, self.output].allSatisfy { $0.map { $0.isFinite && $0 >= 0 } == true }
    }

    func cost(_ usage: RequestPricing, provider: ProviderInstanceID, correctLegacyContext: Bool = false) -> Double? {
        guard self.hasListPrice else { return nil }
        let counts = usage.tokens
        let claude = provider == .claude
        let context = usage.contextSize(for: provider)
        let tier = self.tiers?.compactMap { rate -> (Int, Self)? in
            guard let declared = rate.contextThreshold else { return nil }
            let threshold = correctLegacyContext && declared == 200_000 ? 272_000 : declared
            guard context > Decimal(threshold) else { return nil }
            return (threshold, rate)
        }.max { $0.0 < $1.0 }?.1
        guard let input = tier?.input ?? self.input, let output = tier?.output ?? self.output else { return nil }
        let read = tier?.cacheRead ?? self.cacheRead
        let write = tier?.cacheWrite ?? self.cacheWrite
        let longWrites = if claude {
            min(usage.oneHour ?? 0, counts.written)
        } else {
            usage.codexCacheRetention == "12h" ? counts.written : 0
        }
        let shortWrites = counts.written - longWrites
        let uncached = claude ? counts.input : counts.input - counts.cached - counts.written
        guard uncached >= 0, shortWrites >= 0, longWrites >= 0,
              counts.cached == 0 || read != nil, shortWrites == 0 || write != nil else { return nil }

        let longMultiplier = tier?.cacheWrite1hMultiple ?? self.cacheWrite1hMultiple ?? (claude ? 2 : 2.5)
        let region = usage.inferenceGeo.flatMap { self.regions?[$0] }
            ?? (claude && usage.inferenceGeo == "us" ? 1.1 : 1)
        guard [input, output, read ?? 0, write ?? 0, longMultiplier, region]
            .allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
        let perMillion = Double(uncached) * input + Double(counts.output) * output
            + Double(counts.cached) * (read ?? 0) + Double(shortWrites) * (write ?? 0)
            + Double(longWrites) * input * longMultiplier
        let cost = perMillion * region / 1_000_000
        return cost.isFinite && cost >= 0 ? cost : nil
    }
}

struct HistoricalCatalogEntry: Decodable, Sendable {
    let start: Date?
    let rates: CatalogRate?

    var effective: Date? {
        // The feed sometimes has a null start or attaches tool changes
        // older than the model. Never extend its token price backwards.
        if let published = self.rates?.validFrom { return max(self.start ?? published, published) }
        return self.start
    }
}

struct PricingAliases: Decodable, Sendable {
    let models: [String: String]
}

struct CurrentCatalogModel: Decodable, Sendable {
    struct Experimental: Decodable, Sendable {
        let modes: [String: CurrentCatalogMode]?
    }

    let canonicalModelId: String?
    let cost: CatalogRate?
    let experimental: Experimental?
}

struct CurrentCatalogMode: Decodable, Sendable {
    let cost: CatalogRate?
}

package struct ModelPriceCatalog: Sendable {
    struct Historical: Decodable, Sendable {
        let schema: Int
        let prices: CatalogProviders<[String: [String: [HistoricalCatalogEntry]]]>
        let aliases: PricingAliases
    }

    struct CurrentProvider: Decodable, Sendable {
        let models: [String: CurrentCatalogModel]
    }

    /// models.dev used its legacy 200k field for these OpenAI models until #1755
    /// introduced the original published 272k threshold on May 12.
    /// https://github.com/anomalyco/models.dev/pull/1755
    private static let contextSchemaFix = Date(timeIntervalSince1970: 1_778_625_648)

    var historical: Historical?
    var current: CatalogProviders<CurrentProvider>?

    package init(historicalData: Data? = nil, currentData: Data? = nil) {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        if let historicalData, let decoded = try? decoder.decode(Historical.self, from: historicalData),
           decoded.schema == 2,
           Self.containsRates(decoded.prices.openai), Self.containsRates(decoded.prices.anthropic)
        {
            self.historical = decoded
        }
        if let currentData, let decoded = try? decoder.decode(
            CatalogProviders<CurrentProvider>.self,
            from: currentData),
            decoded.openai.models.values.contains(where: { $0.cost?.hasListPrice == true }),
            decoded.anthropic.models.values.contains(where: { $0.cost?.hasListPrice == true })
        {
            self.current = decoded
        }
    }

    private static func containsRates(_ models: [String: [String: [HistoricalCatalogEntry]]]) -> Bool {
        models.values.contains { $0["standard"]?.contains { $0.rates?.hasListPrice == true } == true }
    }

    func quote(_ usage: RequestPricing, provider: ProviderInstanceID) -> PriceQuote? {
        guard let model = usage.model else { return nil }
        let vendor = provider == .codex ? "openai" : "anthropic"
        let normalized = provider == .codex
            ? LedgerPricing.normalizeCodexModel(model) : LedgerPricing.normalizeClaudeModel(model)
        let alias = self.historical?.aliases.models[model]
        let prefix = vendor + "/"
        let names = [
            model,
            alias.flatMap { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : nil },
            normalized,
        ]
            .compactMap(\.self)
        let mode = Self.mode(usage, provider: provider)
        if let mode, let models = self.historical?.prices.value(for: provider) {
            for name in names {
                guard let timeline = models[name]?[mode],
                      let entry = timeline.last(where: { $0.effective.map { $0 <= usage.date } == true })
                else { continue }
                // A dated withdrawal explicitly ends the catalog's price.
                guard let rate = entry.rates else { return nil }
                let legacyOpenAIContext = (normalized == "gpt-5.4" || normalized == "gpt-5.5")
                    && rate.validFrom.map { $0 < Self.contextSchemaFix } == true
                if let cost = rate.cost(usage, provider: provider, correctLegacyContext: legacyOpenAIContext) {
                    let verified = rate.validFromBasis == "documented" || rate.validFromBasis == "scheduled"
                    return PriceQuote(usd: cost, basis: verified ? .verifiedHistory : .datedHistory)
                }
            }
        }
        if let cost = usage.cost(for: provider) {
            return PriceQuote(usd: cost, basis: .bundled)
        }
        guard let mode, let models = self.current?.value(for: provider)?.models else { return nil }
        for name in names {
            guard let model = models[name] else { continue }
            let canonical = model.canonicalModelId.flatMap { models[$0] }
            let base = model.cost ?? canonical?.cost
            let rate = mode == "standard"
                ? base : model.experimental?.modes?[mode]?.cost ?? canonical?.experimental?.modes?[mode]?.cost
            // A mode with short-context rates alone does not establish a long-context rate.
            if mode != "standard", rate?.tiers?.isEmpty != false,
               let threshold = base?.tiers?.compactMap(\.contextThreshold).min(),
               usage.contextSize(for: provider) > Decimal(threshold)
            {
                continue
            }
            if let cost = rate?.cost(usage, provider: provider) {
                return PriceQuote(usd: cost, basis: .current)
            }
        }
        return nil
    }

    private static func mode(_ usage: RequestPricing, provider: ProviderInstanceID) -> String? {
        if provider == .claude {
            guard usage.tier == nil || usage.tier == "standard" || usage.tier == "batch" else { return nil }
            if usage.tier == "batch" { return usage.speed == nil || usage.speed == "standard" ? "batch" : nil }
            return usage.speed ?? "standard"
        }
        switch usage.tier {
        case nil, "default", "standard": return "standard"
        case "priority": return "fast"
        default: return usage.tier
        }
    }
}
