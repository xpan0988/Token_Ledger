import Foundation
import Testing
@testable import LedgerCore

struct AccountingTests {
    private let timestamp = "2026-11-10T12:00:00Z"

    private func count(_ input: Int, _ cached: Int = 0, _ output: Int = 0) -> [String: Int] {
        ["input_tokens": input, "cached_input_tokens": cached, "output_tokens": output]
    }

    private func entry(_ type: String, _ payload: [String: Any], _ offset: Int = 0) -> [String: Any] {
        ["type": type, "timestamp": "2026-11-10T12:00:\(String(format: "%02d", offset))Z", "payload": payload]
    }

    private func append(_ rows: [[String: Any]], to file: URL) throws {
        var data = Data()
        for row in rows {
            try data.append(JSONSerialization.data(withJSONObject: row))
            data.append(0x0A)
        }
        if FileManager.default.fileExists(atPath: file.path) {
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try data.write(to: file)
        }
    }

    private func modern(_ id: String, _ usage: Int, _ cumulative: Int, _ offset: Int, thread: String = "thread")
        -> [String: Any]
    {
        self.entry("token_usage_record", [
            "thread_id": thread, "response_id": id, "model": "gpt-5.5",
            "usage": self.count(usage, usage / 2), "thread_token_usage": self.count(cumulative, cumulative / 2),
        ], offset)
    }

    private func legacy(_ last: Int, _ cumulative: Int, _ offset: Int) -> [String: Any] {
        self.entry("event_msg", ["type": "token_count", "info": [
            "total_token_usage": self.count(cumulative, cumulative / 2), "last_token_usage": self.count(last, last / 2),
        ]], offset)
    }

    @Test
    func `mixed Codex counters with drift choose one stream and preserve resets and child usage`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("sessions/thread.jsonl")
        try self.append([
            self.entry("session_meta", ["id": "thread"]),
            self.entry("turn_context", ["model": "gpt-5.5"]),
            self.legacy(100, 100, 1), self.modern("first", 100, 100, 2),
            self.modern("aux", 50, 150, 3),
            self.legacy(200, 300, 4), self.modern("next", 200, 350, 5),
            self.modern("reset", 50, 50, 6), self.legacy(50, 50, 7),
        ], to: source)
        try self.append([
            self.entry("session_meta", ["id": "child", "source": ["subagent": "thread_spawn"]]),
            self.entry("turn_context", ["model": "gpt-5.5"]), self.legacy(20, 20, 1),
            self.legacy(20, 20, 2), self.legacy(30, 50, 3), self.legacy(20, 20, 4),
        ], to: root.appendingPathComponent("sessions/child.jsonl"))
        let locations = UsageLocations(codex: root, claude: root)
        let file = root.appendingPathComponent("history.sqlite")
        let collector = HistoryCollector(file: file, locations: locations)
        let first = await collector.collect([.codex])
        #expect(first.totals.totalTokens == 470)
        #expect(!first.persistenceFailed)

        let archive = root.appendingPathComponent("archived_sessions/copy.jsonl")
        try FileManager.default.createDirectory(
            at: archive.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: archive)
        try self.append([self.modern("resumed", 120, 100_000, 9)], to: source)
        let reopened = HistoryCollector(file: file, locations: locations)
        #expect(await reopened.collect([.codex]).totals.totalTokens == 590)
        try FileManager.default.removeItem(at: source.deletingLastPathComponent())
        try FileManager.default.removeItem(at: archive.deletingLastPathComponent())
        #expect(await HistoryCollector(file: file, locations: locations).collect([]).totals.totalTokens == 590)
    }

    @Test
    func `legacy prefix survives only when the modern cumulative counter proves continuation`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("sessions/thread.jsonl")
        let file = root.appendingPathComponent("history.sqlite")
        let collector = HistoryCollector(file: file, locations: .init(codex: root, claude: root))
        try self.append([self.entry("session_meta", ["id": "thread"]), self.legacy(30, 30, 1)], to: source)
        #expect(await collector.collect([.codex]).totals.totalTokens == 30)
        try self.append([self.modern("next", 70, 100, 2), self.legacy(70, 100, 3)], to: source)
        #expect(await collector.collect([.codex]).totals.totalTokens == 100)
        let fork = root.appendingPathComponent("sessions/fork.jsonl")
        try self.append([
            self.entry("session_meta", ["id": "fork", "forked_from_id": "thread"]),
            self.legacy(100, 100, 1), self.legacy(20, 120, 2),
        ], to: fork)
        #expect(await collector.collect([.codex]).totals.totalTokens == 120)
        let cutoff = try #require(TranscriptState.date("2026-11-10T12:00:04Z"))
        #expect(await collector.delete(through: cutoff))
        try self.append([self.modern("after", 40, 140, 5)], to: source)
        #expect(await collector.collect([.codex]).totals.totalTokens == 40)
    }

    @Test
    func `claude streamed fragments and copied logs preserve disjoint cache categories`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("history.sqlite")
        let locations = UsageLocations(codex: root, claude: root)
        let source = root.appendingPathComponent("projects/session.jsonl")
        func row(_ output: Int, request: String? = "req") -> [String: Any] {
            var row: [String: Any] = [
                "type": "assistant", "timestamp": self.timestamp,
                "message": ["id": "msg", "model": "claude-sonnet-4-6", "usage": [
                    "input_tokens": 100, "output_tokens": output, "cache_read_input_tokens": 200,
                    "cache_creation_input_tokens": 50, "cache_creation": ["ephemeral_1h_input_tokens": 10],
                ]],
            ]
            row["requestId"] = request
            return row
        }
        let collector = HistoryCollector(file: file, locations: locations)
        try self.append([row(1, request: nil), row(20), row(11)], to: source)
        let totals = await collector.collect([.claude]).totals
        #expect(totals.totalTokens == 370)
        let cost = try #require(totals.apiCosts.first).value
        #expect(abs(NSDecimalNumber(decimal: cost).doubleValue - 0.00087) < 1e-12)
        let copy = source.deletingLastPathComponent().appendingPathComponent("copy.jsonl")
        try self.append([row(30, request: nil), row(20), row(21)], to: copy)
        let reload = HistoryCollector(file: file, locations: locations)
        #expect(await reload.collect([.claude]).totals.totalTokens == 371)
        try self.append([row(5, request: "different")], to: source)
        #expect(await reload.collect([.claude]).totals.totalTokens == 726)
    }

    @Test
    func `migration backs up v1 and retains unmatched recorded usage without importing legacy mirrors`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let oldFile = root.appendingPathComponent("history.json")
        let backup = root.appendingPathComponent("history-v1.backup.json")
        let file = root.appendingPathComponent("history.sqlite")
        let source = root.appendingPathComponent("sessions/thread.jsonl")
        try self.append([
            self.entry("session_meta", ["id": "thread"]), self.legacy(100, 200, 1),
            self.modern("retained", 100, 100, 2),
        ], to: source)
        let data = try JSONSerialization.data(withJSONObject: [
            "timeZone": "UTC",
            "events": [
                LedgerIdentity.hash("codex-response:retained"): [
                    "provider": "codex", "day": "2026-11-10", "tokens": 100, "authoritative": true,
                ],
                LedgerIdentity.hash("codex-token-count:thread:200:100:0"): [
                    "provider": "codex", "day": "2026-11-10", "tokens": 100, "authoritative": false,
                ],
                LedgerIdentity.hash("codex-response:rotated"): [
                    "provider": "codex", "day": "2026-11-09", "tokens": 250, "authoritative": true,
                ],
            ],
            "observedProviders": ["codex"], "legacyDays": [], "legacyUndated": [],
        ])
        try data.write(to: oldFile)
        let locations = UsageLocations(codex: root, claude: root)
        let collector = HistoryCollector(file: file, locations: locations)
        #expect(await collector.collect([]).totals.totalTokens == 450)
        #expect(await collector.collect([.codex]).totals.totalTokens == 350)
        #expect(try Data(contentsOf: backup) == data)
        #expect(!FileManager.default.fileExists(atPath: oldFile.path))
        try self.append([self.modern("rotated", 250, 350, 3)], to: source)
        let reopened = HistoryCollector(file: file, locations: locations)
        #expect(await reopened.collect([.codex]).totals.totalTokens == 350)
    }

    @Test
    func `embedded history imports existing day and session totals once`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyFile = root.appendingPathComponent("token-ledger-history.json")
        let snapshot = Data(#"""
        {
            "sources":[{"provider":"codex","currency":"USD","fingerprint":"abc"}, {
                "days":{"2026-11-08":{"tokens":5000000000}},
                "sessions":{"hash":{"tokens":5000000020}},
                "hasConfirmedEmpty":false,"partialTokens":false,"partialPrices":false,"ambiguousRotation":true
            }],
            "selected":["codex",[{"provider":"codex","currency":"USD","fingerprint":"abc"}]]
        }
        """#.utf8)
        try snapshot.write(to: legacyFile)
        let file = root.appendingPathComponent("history.sqlite")
        let locations = UsageLocations(codex: root, claude: root)
        let collector = HistoryCollector(file: file, locations: locations, legacyFile: legacyFile, legacyZone: "UTC")
        let result = await collector.collect([])
        #expect(result.totals.totalTokens == 5_000_000_020)
        #expect(result.totals.tokenCoverageIsPartial)
        #expect(result.totals.priceCoverageIsPartial)
        #expect(try Data(contentsOf: legacyFile) == snapshot)
        #expect(await HistoryCollector(file: file, locations: locations).collect([]).totals == result.totals)
    }
}
