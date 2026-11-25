import Foundation
import Testing
@testable import LedgerCore

struct AccountingTests {
    private let timestamp = "2026-11-10T12:00:00Z"

    private func line(_ values: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
    }

    private func count(_ input: Int, _ cached: Int, _ output: Int) -> [String: Int] {
        ["input_tokens": input, "cached_input_tokens": cached, "output_tokens": output]
    }

    private func entry(_ type: String, _ payload: [String: Any], timestamp: String? = nil) throws -> Data {
        try self.line(["type": type, "timestamp": timestamp ?? self.timestamp, "payload": payload])
    }

    @Test
    func `codex typed and legacy views of one request count once across file copies`() throws {
        var ledger = LedgerState(timeZone: "UTC")
        let usage = self.count(100, 40, 10)
        let prefix = try self.entry("session_meta", ["id": "session", "model_provider": "openai"])
        let context = try self.entry("turn_context", ["model": "gpt-5.4"])
        let legacy = try self.entry("event_msg", ["type": "token_count", "info": [
            "total_token_usage": usage, "last_token_usage": usage,
        ]])
        let typed = try self.entry("token_usage_record", [
            "thread_id": "session",
            "response_id": "response",
            "usage": usage,
            "thread_token_usage": usage,
        ])
        for rows in [[prefix, context, legacy, typed], [prefix, context, typed, legacy]] {
            var scanner = TranscriptState()
            for row in rows {
                if let observation = scanner.consume(row, provider: .codex) {
                    ledger.record(observation, provider: .codex)
                }
            }
        }
        let persisted = try JSONEncoder().encode(ledger)
        let restored = try JSONDecoder().decode(LedgerState.self, from: persisted)
        #expect(restored.events.count == 1)
        #expect(restored.totals(stale: false, partial: false).totalTokens == 110)
        let cost = try #require(restored.totals(stale: false, partial: false).apiCosts.first).value
        #expect(abs(NSDecimalNumber(decimal: cost).doubleValue - 0.00031) < 1e-12)
    }

    @Test
    func `ambiguous legacy mirrors do not add a second aggregate copy`() throws {
        var ledger = LedgerState(timeZone: "UTC")
        let now = try #require(TranscriptState.date(self.timestamp))
        ledger.record(.init(identity: "weak", date: now, tokens: 40, authoritative: false), provider: .codex)
        ledger.record(.init(
            identity: "response1",
            alias: "weak",
            date: now,
            tokens: 40,
            authoritative: true), provider: .codex)
        ledger.record(.init(
            identity: "response2",
            alias: "weak",
            date: now,
            tokens: 50,
            authoritative: true), provider: .codex)
        ledger.record(.init(identity: "weak", date: now, tokens: 40, authoritative: false), provider: .codex)
        #expect(ledger.totals(stale: false, partial: false).totalTokens == 90)
        #expect(ledger.totals(stale: false, partial: false).tokenCoverageIsPartial)
    }

    @Test
    func `fork legacy counters cannot re-add a parent balance`() throws {
        var scanner = TranscriptState()
        _ = try scanner.consume(
            self.entry("session_meta", ["id": "child", "forked_from_id": "parent"]),
            provider: .codex)
        let row = try self.entry("event_msg", ["type": "token_count", "info": [
            "total_token_usage": self.count(100, 20, 10), "last_token_usage": self.count(100, 20, 10),
        ]])
        #expect(scanner.consume(row, provider: .codex) == nil)
        #expect(scanner.partial)
    }

    @Test
    func `claude stream fragments merge and cached categories remain disjoint`() throws {
        var scanner = TranscriptState()
        var ledger = LedgerState(timeZone: "UTC")
        for output in [1, 20, 11] {
            let row = try self.line([
                "type": "assistant", "requestId": "req", "timestamp": self.timestamp,
                "message": ["id": "msg", "model": "claude-sonnet-4-6", "usage": [
                    "input_tokens": 100, "output_tokens": output, "cache_read_input_tokens": 200,
                    "cache_creation_input_tokens": 50, "cache_creation": ["ephemeral_1h_input_tokens": 10],
                ]],
            ])
            let observation = scanner.consume(row, provider: .claude)
            let event = try #require(observation)
            ledger.record(event, provider: .claude)
        }
        let totals = ledger.totals(stale: false, partial: false)
        #expect(totals.totalTokens == 370)
        let cost = try #require(totals.apiCosts.first).value
        #expect(abs(NSDecimalNumber(decimal: cost).doubleValue - 0.00087) < 1e-12)
    }

    @Test
    func `dated migration combines disjoint days and takes a lower bound for an overlapping day`() throws {
        var ledger = LedgerState(timeZone: "UTC")
        ledger.legacyDays[.codex] = [
            "2026-11-08": HistoryBucket(tokens: 5_000_000_000, cost: 2),
            "2026-11-10": HistoryBucket(tokens: 800, cost: 3),
        ]
        ledger.legacyUndated[.codex] = HistoryBucket(tokens: 5_000_000_900, cost: 5)
        let now = try #require(TranscriptState.date(self.timestamp))
        ledger.record(.init(identity: "new", date: now, tokens: 1200, cost: 4, authoritative: true), provider: .codex)
        ledger.record(.init(
            identity: "next",
            date: now.addingTimeInterval(86400),
            tokens: 210,
            cost: 1,
            authoritative: true), provider: .codex)
        let result = ledger.totals(stale: false, partial: false)
        #expect(result.totalTokens == 5_000_001_410)
        #expect(result.tokenCoverageIsPartial)
        #expect(result.apiCosts.first?.value == 7)
    }

    @Test
    func `legacy checkpoint migration is read-only and persists independently`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyFile = root.appendingPathComponent("token-ledger-history.json")
        let snapshot = Data(#"""
        {
            "sources":[{"provider":"codex","currency":"USD","fingerprint":"abc"}, {
                "days":{"2026-11-08":{"tokens":5000000000,"cost":10}},
                "sessions":{"hash":{"tokens":5000000020,"cost":11}},
                "hasConfirmedEmpty":false,"partialTokens":false,"partialPrices":false,"ambiguousRotation":true
            }],
            "selected":["codex",[{"provider":"codex","currency":"USD","fingerprint":"abc"}]]
        }
        """#.utf8)
        try snapshot.write(to: legacyFile)
        let file = root.appendingPathComponent("standalone.json")
        let locations = UsageLocations(codex: root.appendingPathComponent("codex"), claude: root)
        let migrated = HistoryCollector(file: file, locations: locations, legacyFile: legacyFile, legacyZone: "UTC")
        let result = await migrated.collect([])
        #expect(result.totals.totalTokens == 5_000_000_020)
        #expect(result.totals.apiCosts == [TokenLedgerAmount(currency: "USD", value: 11)])
        #expect(result.totals.tokenCoverageIsPartial)
        #expect(!result.persistenceFailed)
        let original = try Data(contentsOf: legacyFile)
        #expect(original == snapshot)

        let reloaded = HistoryCollector(file: file, locations: locations)
        #expect(await reloaded.collect([]).totals == result.totals)
    }

    @Test
    func `provider restart, log rotation, disable and deletion preserve the intended boundary`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let codex = root.appendingPathComponent("codex")
        let claude = root.appendingPathComponent("claude")
        let sessions = codex.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let source = sessions.appendingPathComponent("a.jsonl")
        let file = root.appendingPathComponent("history.json")
        let locations = UsageLocations(codex: codex, claude: claude)
        let prefix = try self.entry("session_meta", ["id": "session"])
        let context = try self.entry("turn_context", ["model": "gpt-5.4"])
        let usage = self.count(75, 10, 25)
        let first = try self.entry("token_usage_record", [
            "thread_id": "session",
            "response_id": "a",
            "usage": usage,
            "thread_token_usage": usage,
        ])
        try [prefix, context, first].reduce(into: Data()) { $0.append($1); $0.append(0x0A) }.write(to: source)
        let collector = HistoryCollector(file: file, locations: locations)
        #expect(await collector.collect([.codex]).totals.totalTokens == 100)
        try FileManager.default.moveItem(at: source, to: sessions.appendingPathComponent("renamed.jsonl"))
        let reload = HistoryCollector(file: file, locations: locations)
        #expect(await reload.collect([]).totals.totalTokens == 100)
        #expect(await reload.collect([.codex]).totals.totalTokens == 100)
        let cutoff = try #require(TranscriptState.date(self.timestamp))
        #expect(await reload.delete(through: cutoff))
        try FileManager.default.copyItem(at: sessions.appendingPathComponent("renamed.jsonl"), to: source)
        #expect(await reload.collect([.codex]).totals.totalTokens == nil)
        #expect(FileManager.default.fileExists(atPath: source.path))
    }
}
