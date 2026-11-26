import Foundation

/// USD per million tokens, for a single published Standard base-context schedule.
struct TokenRates: Codable, Hashable, Sendable {
    let input: Double
    let cacheRead: Double
    let cacheWrite: Double
    let longWrite: Double
    let output: Double

    var values: [Double] {
        [self.input, self.cacheRead, self.cacheWrite, self.longWrite, self.output]
    }

    var valid: Bool {
        self.values.allSatisfy { (0...1_000_000).contains($0) }
    }

    func usd(_ counts: TokenCounts) -> Double {
        (Double(counts.input) * self.input + Double(counts.cached) * self.cacheRead
            + Double(counts.written - counts.longWrites) * self.cacheWrite
            + Double(counts.longWrites) * self.longWrite + Double(counts.output) * self.output) / 1_000_000
    }
}

private struct FeedRate: Decodable {
    let input: Double?
    let output: Double?
    let cacheRead: Double?
    let cacheWrite: Double?
    let cacheWrite1hMultiple: Double?
    let validFrom: Date?

    func standard(for provider: ProviderInstanceID) -> TokenRates? {
        guard let input = self.input, let output = self.output else { return nil }
        let rates = TokenRates(
            input: input, cacheRead: self.cacheRead ?? input * 0.1,
            cacheWrite: self.cacheWrite ?? input * (provider == .claude ? 1.25 : 1),
            longWrite: input * (self.cacheWrite1hMultiple ?? (provider == .claude ? 2 : 2.5)),
            output: output)
        return rates.valid ? rates : nil
    }
}

private struct FeedProviders<Value: Decodable>: Decodable {
    let openai: Value
    let anthropic: Value
}

package struct ModelPriceCatalog: Codable, Sendable {
    private struct Entry: Decodable {
        let start: Date?
        let rates: FeedRate?
    }

    private struct Aliases: Decodable {
        let models: [String: String]
    }

    private struct History: Decodable {
        let schema: Int
        let prices: FeedProviders<[String: [String: [Entry]]]>
        let aliases: Aliases?
    }

    private struct CurrentModel: Decodable {
        let cost: FeedRate?
        let canonicalModelId: String?
    }

    private struct Current: Decodable {
        let models: [String: CurrentModel]
    }

    private var prices: [ProviderInstanceID: [String: Set<TokenRates>]] = [:]
    private var aliases: [String: String] = [:]

    package init() {}

    init?(history: Data, now: Date = Date()) {
        let decoder = Self.decoder()
        guard let feed = try? decoder.decode(History.self, from: history), feed.schema == 2 else { return nil }
        self.aliases = feed.aliases?.models ?? [:]
        for (provider, models) in [(ProviderInstanceID.codex, feed.prices.openai), (.claude, feed.prices.anthropic)] {
            for (model, modes) in models {
                for entry in modes["standard"] ?? [] {
                    guard let rates = entry.rates, let start = rates.validFrom ?? entry.start,
                          max(start, entry.start ?? start) <= now,
                          let rate = rates.standard(for: provider) else { continue }
                    self.retain(rate, model: model, provider: provider)
                }
            }
            guard self.prices[provider]?.isEmpty == false else { return nil }
        }
    }

    init?(current: Data) {
        guard let feed = try? Self.decoder().decode(FeedProviders<Current>.self, from: current) else { return nil }
        for (provider, catalog) in [(ProviderInstanceID.codex, feed.openai), (.claude, feed.anthropic)] {
            for (name, model) in catalog.models {
                if let rate = (model.cost ?? model.canonicalModelId.flatMap { catalog.models[$0]?.cost })?
                    .standard(for: provider)
                {
                    self.retain(rate, model: name, provider: provider)
                }
            }
            guard self.prices[provider]?.isEmpty == false else { return nil }
        }
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private mutating func retain(_ rate: TokenRates, model: String, provider: ProviderInstanceID) {
        func dominates(_ lhs: TokenRates, _ rhs: TokenRates) -> Bool {
            zip(lhs.values, rhs.values).allSatisfy { $0 >= $1 }
        }
        var schedules = self.prices[provider]?[model] ?? []
        if schedules.contains(where: { dominates($0, rate) }) { return }
        schedules = schedules.filter { !dominates(rate, $0) }
        schedules.insert(rate)
        self.prices[provider, default: [:]][model] = schedules
    }

    mutating func merge(_ catalog: Self) {
        self.aliases.merge(catalog.aliases) { _, latest in latest }
        for (provider, models) in catalog.prices {
            for (model, schedules) in models {
                for rate in schedules {
                    self.retain(rate, model: model, provider: provider)
                }
            }
        }
    }

    func canonical(_ name: String, provider: ProviderInstanceID) -> String {
        let vendor = provider == .codex ? "openai/" : "anthropic/"
        let raw = name.hasPrefix(vendor) ? String(name.dropFirst(vendor.count)) : name
        if provider == .codex, Self.proxyModels.contains(raw) { return raw }
        if let alias = self.aliases[raw], alias.hasPrefix(vendor) {
            return String(alias.dropFirst(vendor.count))
        }
        if let suffix = raw.range(of: #"-\d{4}-\d{2}-\d{2}$|-\d{8}$"#, options: .regularExpression) {
            let base = String(raw[..<suffix.lowerBound])
            if self.prices[provider]?[base] != nil || Self.bootstrap[base] != nil { return base }
        }
        return raw
    }

    func premium(_ model: String, provider: ProviderInstanceID, counts: TokenCounts) -> TokenRates? {
        let canonical = self.canonical(model, provider: provider)
        var rates = self.prices[provider]?[canonical] ?? []
        rates.formUnion(self.prices[provider]?[model] ?? [])
        if let rate = Self.bootstrap[canonical] { rates.insert(rate) }
        return rates.filter(\.valid).max {
            let left = $0.usd(counts)
            let right = $1.usd(counts)
            if left != right { return left < right }
            return $0.values.lexicographicallyPrecedes($1.values)
        }
    }

    struct Representative {
        let model: String
        let tokens: Int
        let rates: TokenRates?
    }

    struct Estimate {
        let representatives: [Representative]
        let usd: Double?
        let proxyTokens: Int
        let partial: Bool
    }

    func estimate(_ summary: UsageSummary, provider: ProviderInstanceID) -> Estimate {
        var models: [String: TokenCounts] = [:]
        for (name, counts) in summary.models where counts.total > 0 {
            let name = self.canonical(name, provider: provider)
            models[name, default: .init()] += counts
        }
        let ranked = models.keys.filter { !$0.isEmpty }.sorted {
            let left = models[$0]?.total ?? 0
            let right = models[$1]?.total ?? 0
            return left == right ? $0 < $1 : left > right
        }
        let priced = models.reduce(into: [String: TokenRates]()) { rates, item in
            rates[item.key] = self.premium(item.key, provider: provider, counts: item.value)
        }
        let codex = provider == .codex
        let unpricedCounts = models.reduce(into: TokenCounts()) { sum, item in
            if priced[item.key] == nil { sum += item.value }
        }
        let proxy = codex ? self.premium("gpt-6-astra", provider: provider, counts: unpricedCounts) : nil
        let top = ranked.prefix(2).map { model in
            Representative(model: model, tokens: models[model]?.total ?? 0, rates: priced[model] ?? proxy)
        }
        let weighted = top.compactMap { item in item.rates.map { (Double(item.tokens), $0) } }
        let weight = weighted.reduce(0) { $0 + $1.0 }
        var usd = 0.0
        var valued = 0
        var proxyTokens = 0
        for (model, counts) in models {
            if codex, priced[model] == nil, let proxy {
                usd += proxy.usd(counts)
                proxyTokens += counts.total
            } else if top.contains(where: { $0.model == model }), let rate = priced[model] {
                usd += rate.usd(counts)
            } else if weight > 0 {
                usd += weighted.reduce(0) { $0 + $1.0 * $1.1.usd(counts) } / weight
            } else if let rate = priced[model] {
                usd += rate.usd(counts)
            } else {
                continue
            }
            valued += counts.total
        }
        // Historical records with only a total inherit the observed provider's average value per token.
        if valued > 0 { usd += Double(summary.opaque) * usd / Double(valued) }
        return Estimate(
            representatives: top,
            usd: valued > 0 ? usd : nil,
            proxyTokens: proxyTokens,
            partial: summary.total > valued + (valued > 0 ? summary.opaque : 0))
    }

    // Public launch schedules keep fresh/offline installs useful while the public feed is unavailable.
    // https://developers.openai.com/api/docs/pricing
    // https://platform.claude.com/docs/en/about-claude/pricing
    private static let proxyModels = ["codex-auto-review", "gpt-reserve"]
    private static let bootstrap: [String: TokenRates] = [
        "gpt-5.4": .init(input: 2.5, cacheRead: 0.25, cacheWrite: 2.5, longWrite: 6.25, output: 15),
        "gpt-5.5": .init(input: 5, cacheRead: 0.5, cacheWrite: 5, longWrite: 12.5, output: 30),
        "gpt-6.1-sol": .init(input: 2, cacheRead: 0.1, cacheWrite: 2.5, longWrite: 5, output: 10),
        "gpt-6-astra": .init(input: 10, cacheRead: 1, cacheWrite: 12.5, longWrite: 25, output: 50),
        "claude-opus-5-5": .init(input: 4, cacheRead: 0.2, cacheWrite: 5, longWrite: 8, output: 20),
        "claude-fable-5-2": .init(input: 8, cacheRead: 0.2, cacheWrite: 10, longWrite: 16, output: 40),
        "claude-sonnet-4-6": .init(input: 3, cacheRead: 0.3, cacheWrite: 3.75, longWrite: 6, output: 15),
    ]
}
