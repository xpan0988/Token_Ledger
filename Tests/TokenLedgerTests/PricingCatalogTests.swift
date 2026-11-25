import CryptoKit
import Foundation
import Testing
@testable import LedgerCore

struct PricingCatalogTests {
    private let current = Data(#"""
    {
      "openai":{"models":{"new-model":{"cost":{"input":1,"output":2,"cache_read":0.25}}}},
      "anthropic":{"models":{"new-claude":{"cost":{"input":2,"output":3}}}}
    }
    """#.utf8)

    private func historical(oldRate: Int = 5) -> Data {
        Data("""
        {
          "schema":2, "aliases":{"models":{}},
          "prices":{
            "openai":{"new-model":{
              "standard":[
                {"start":null,"rates":{"input":\(oldRate),"output":10,"cache_read":1,
                  "valid_from":"2026-07-09T12:00:00Z","valid_from_basis":"documented",
                  "tiers":[{"above":100000,"input":8,"output":12,"cache_read":2}]}},
                {"start":"2026-08-21T00:00:00Z","rates":{"input":4,"output":8,"cache_read":0.40,
                  "valid_from":"2026-08-21T00:00:00Z","valid_from_basis":"documented"}}
              ]
            }},
            "anthropic":{"new-claude":{"standard":[
                {"start":null,"rates":{"input":3,"output":10,"cache_read":0.20,"cache_write":3.75,
                  "cache_write_1h_multiple":2.0,"valid_from":"2026-09-01T00:00:00Z"}}
            ]}}
          }
        }
        """.utf8)
    }

    @Test
    func `catalog corrections reprice persisted usage and respect the original date`() throws {
        let before = try #require(TranscriptState.date("2026-08-20T23:59:59Z"))
        let after = before.addingTimeInterval(1)
        let tokens = TokenCounts(input: 100, cached: 40, written: 0, output: 10)
        let input = RequestPricing(date: before, model: "new-model", tokens: tokens)
        var state = LedgerState(timeZone: "UTC")
        state.record(
            .init(identity: "id", date: before, tokens: 110, pricing: input, authoritative: true),
            provider: .codex)
        let bytes = try JSONEncoder().encode(state)
        let restored = try JSONDecoder().decode(LedgerState.self, from: bytes)
        let catalog = ModelPriceCatalog(historicalData: self.historical(), currentData: self.current)
        let changed = ModelPriceCatalog(historicalData: self.historical(oldRate: 7), currentData: self.current)
        #expect(catalog.quote(input, provider: .codex)?.basis == .verifiedHistory)
        let first = try #require(restored.totals(stale: false, partial: false, prices: catalog).apiCosts.first)
        let second = try #require(restored.totals(stale: false, partial: false, prices: changed).apiCosts.first)
        #expect(first.value == Decimal(string: "0.00044"))
        #expect(second.value == Decimal(string: "0.00056"))
        let newRequest = RequestPricing(date: after, model: "new-model", tokens: tokens)
        #expect(catalog.quote(newRequest, provider: .codex)?.usd == 0.000336)
        let early = before.addingTimeInterval(-86400 * 100)
        #expect(catalog.quote(.init(date: early, model: "new-model", tokens: tokens), provider: .codex)?
            .basis == .current)
        #expect(catalog.quote(.init(date: before, model: "unknown", tokens: tokens), provider: .codex) == nil)
        #expect(catalog
            .quote(.init(date: before, model: "new-model", tokens: tokens, tier: "fast"), provider: .codex) == nil)
    }

    @Test
    func `catalog keeps provider cache accounting and switches the full context tier`() throws {
        let date = try #require(TranscriptState.date("2026-10-01T00:00:00Z"))
        let catalog = ModelPriceCatalog(historicalData: self.historical())
        let claude = RequestPricing(
            date: date, model: "new-claude", tokens: .init(input: 100, cached: 200, written: 50, output: 20),
            oneHour: 10)
        #expect(catalog.quote(claude, provider: .claude)?.usd == 0.00075)
        let old = try #require(TranscriptState.date("2026-08-01T00:00:00Z"))
        let codex = RequestPricing(
            date: old, model: "new-model", tokens: .init(input: 100_001, cached: 100_000, written: 0, output: 1))
        #expect(catalog.quote(codex, provider: .codex)?.usd == 0.20002)
    }

    @Test
    func `the former 200k field does not overvalue early GPT-5.5 usage`() throws {
        let date = try #require(TranscriptState.date("2026-05-06T00:00:00Z"))
        let fixture = try #require(String(bytes: self.historical(), encoding: .utf8))
            .replacingOccurrences(of: "new-model", with: "gpt-5.5")
            .replacingOccurrences(of: "100000", with: "200000")
            .replacingOccurrences(of: "2026-07-09", with: "2026-04-24")
        let catalog = ModelPriceCatalog(historicalData: Data(fixture.utf8))
        let input = RequestPricing(
            date: date, model: "gpt-5.5", tokens: .init(input: 225_000, cached: 0, written: 0, output: 0))
        #expect(catalog.quote(input, provider: .codex)?.usd == 1.125)
    }

    @Test
    func `catalog refresh is throttled and a corrupt update leaves the durable cache usable`() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let feed = CatalogFeed(history: self.historical(), current: self.current)
        let store = PricingCatalogStore(directory: directory) { try await feed.get($0) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let first = await store.refresh(unknownModels: [], now: now)
        #expect(first?.historical != nil)
        #expect(first?.current != nil)
        #expect(await feed.requestCount == 3)

        #expect(await store.refresh(unknownModels: ["new-unknown"], now: now.addingTimeInterval(60)) == nil)
        #expect(await feed.requestCount == 3)
        await feed.invalidate()
        #expect(await store.refresh(unknownModels: ["new-unknown"], now: now.addingTimeInterval(3600)) == nil)
        #expect(await feed.requestCount > 3)

        let reopened = PricingCatalogStore(directory: directory) { try await feed.get($0) }
        let cached = await reopened.snapshot()
        #expect(cached.historical != nil)
        #expect(cached.current != nil)
        let visits = await feed.requestCount
        #expect(await reopened.refresh(unknownModels: [], now: now.addingTimeInterval(86399)) == nil)
        #expect(await feed.requestCount == visits)
        #expect(await reopened.refresh(unknownModels: [], now: now.addingTimeInterval(86400)) == nil)
        #expect(await feed.requestCount > visits)
    }
}

private actor CatalogFeed {
    let history: Data
    let current: Data
    let digest: String
    var requestCount = 0
    var invalid = false

    init(history: Data, current: Data) {
        self.history = history
        self.current = current
        self.digest = SHA256.hash(data: history).map { String(format: "%02x", $0) }.joined()
    }

    func invalidate() { self.invalid = true }

    func get(_ url: URL) throws -> Data {
        self.requestCount += 1
        if url.host == "models.dev" { return self.invalid ? Data("{}".utf8) : self.current }
        guard url.host == "raw.githubusercontent.com" else { throw URLError(.unsupportedURL) }
        if url.lastPathComponent == "latest.json" {
            let digest = self.invalid ? String(repeating: "a", count: 64) : self.digest
            return Data("{\"sha256\":\"\(digest)\"}".utf8)
        }
        return self.history
    }
}
