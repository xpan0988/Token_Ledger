import CryptoKit
import Foundation
import Testing
@testable import LedgerCore

struct PricingCatalogTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func current(_ models: [String: [String: Double]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "openai": ["models": models.mapValues { ["cost": $0] }],
            "anthropic": ["models": ["claude-test": ["cost": ["input": 4, "output": 20, "cache_read": 0.2]]]],
        ])
    }

    private func history(_ schedule: [String: Double]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "schema": 2, "prices": [
                "openai": ["gpt-new": ["standard": [["start": "2026-01-01T00:00:00Z", "rates": schedule]]]],
                "anthropic": ["claude-new": ["standard": [[
                    "start": "2026-01-01T00:00:00Z",
                    "rates": ["input": 5, "output": 22],
                ]]]],
            ],
        ])
    }

    @Test
    func `premium valuation selects a published schedule as a unit and validates rates`() throws {
        var catalog = ModelPriceCatalog()
        let inputHeavy = try self.history(["input": 10, "output": 5, "cache_read": 1])
        let outputHeavy = try self.history(["input": 4, "output": 25, "cache_read": 0.2])
        let invalid = try self.history(["input": 100, "output": 100, "cache_read": -1])
        try catalog.merge(#require(ModelPriceCatalog(history: inputHeavy, now: self.now)))
        try catalog.merge(#require(ModelPriceCatalog(history: outputHeavy, now: self.now)))
        #expect(ModelPriceCatalog(history: invalid, now: self.now) == nil)
        let price = catalog.premium("gpt-new", provider: .codex, counts: .init(input: 10000, output: 10000))
        #expect(price?.input == 4)
        #expect(price?.output == 25)
        #expect(price?.cacheRead == 0.2)
        #expect(catalog.premium("gpt-new", provider: .codex, counts: .init(input: 1_000_000))?.input == 10)
    }

    @Test
    func `top two by volume weight the remaining models and Astra values unpriced Codex categories`() throws {
        let rates = try self.current([
            "top": ["input": 4, "output": 20, "cache_read": 0.4, "cache_write": 5],
            "second": ["input": 8, "output": 40, "cache_read": 0.8, "cache_write": 10],
            "rest": ["input": 99, "output": 99],
        ])
        let catalog = try #require(ModelPriceCatalog(current: rates))
        let summary = UsageSummary(models: [
            "top": .init(cached: 4_000_000), "second": .init(cached: 2_000_000),
            "rest": .init(input: 100_000, cached: 200_000, written: 100_000, output: 100_000),
            "gpt-reserve": .init(cached: 100_000, output: 10000),
        ])
        let estimate = catalog.estimate(summary, provider: .codex)
        #expect(estimate.representatives.map(\.model) == ["top", "second"])
        #expect(estimate.proxyTokens == 110_000)
        #expect(!estimate.partial)
        let expected = 1.6 + 1.6 + (4 * 2.98 + 2 * 5.96) / 6 + 0.6
        #expect(abs((estimate.usd ?? 0) - expected) < 1e-12)
    }

    @Test
    func `catalog refresh persists compact premium rates and reloads offline`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try self.history(["input": 10, "output": 20, "cache_read": 1])
        let new = try self.history(["input": 5, "output": 10, "cache_read": 0.5])
        func store(_ data: Data) -> PricingCatalogStore {
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return PricingCatalogStore(directory: root) { url in
                if url.lastPathComponent == "latest.json" {
                    return try JSONSerialization.data(withJSONObject: ["sha256": hash])
                }
                guard url.lastPathComponent == hash + ".json" else { throw URLError(.badURL) }
                return data
            }
        }
        #expect(await store(old).refresh(now: self.now) != nil)
        #expect(await store(new).refresh(now: self.now.addingTimeInterval(60)) == nil)
        #expect(await store(new).refresh(now: self.now.addingTimeInterval(90000)) != nil)
        let offline = PricingCatalogStore(directory: root) { _ in throw URLError(.notConnectedToInternet) }
        #expect(await offline.refresh(now: self.now.addingTimeInterval(180_000)) == nil)
        let catalog = await offline.snapshot()
        #expect(catalog.premium("gpt-new", provider: .codex, counts: .init(input: 1))?.input == 10)
    }
}
