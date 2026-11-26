import CoreFoundation
import Foundation

/// Disjoint categories across both providers. The fifth field is the subset of writes with a longer TTL.
struct TokenCounts: Codable, Equatable, Sendable {
    var input = 0
    var cached = 0
    var written = 0
    var output = 0
    var longWrites = 0

    private enum CodingKeys: String, CodingKey { case input, cached, written, output, longWrites }

    init(input: Int = 0, cached: Int = 0, written: Int = 0, output: Int = 0, longWrites: Int = 0) {
        self.input = input
        self.cached = cached
        self.written = written
        self.output = output
        self.longWrites = longWrites
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            input: value.decode(Int.self, forKey: .input),
            cached: value.decode(Int.self, forKey: .cached),
            written: value.decode(Int.self, forKey: .written),
            output: value.decode(Int.self, forKey: .output),
            longWrites: value.decodeIfPresent(Int.self, forKey: .longWrites) ?? 0)
    }

    var total: Int {
        self.input + self.cached + self.written + self.output
    }

    var signature: String {
        "\(self.input + self.cached + self.written):\(self.cached):\(self.output)"
    }

    static func + (left: Self, right: Self) -> Self {
        Self(
            input: left.input + right.input,
            cached: left.cached + right.cached,
            written: left.written + right.written,
            output: left.output + right.output,
            longWrites: left.longWrites + right.longWrites)
    }

    static func += (left: inout Self, right: Self) { left = left + right }
    static func -= (left: inout Self, right: Self) { left = left - right }

    static func - (left: Self, right: Self) -> Self {
        Self(
            input: left.input - right.input,
            cached: left.cached - right.cached,
            written: left.written - right.written,
            output: left.output - right.output,
            longWrites: left.longWrites - right.longWrites)
    }

    func delta(from previous: Self) -> Self? {
        let difference = self - previous
        return min(difference.input, difference.cached, difference.written, difference.output) >= 0 ? difference : nil
    }

    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              (0...1e13).contains(number.doubleValue), number.doubleValue.rounded() == number.doubleValue
        else { return nil }
        return number.intValue
    }

    static func decode(_ row: [String: Any], claude: Bool = false) -> Self? {
        func count(_ keys: String...) -> Int? {
            for key in keys {
                if let value = row[key] { return Self.integer(value) }
            }
            return 0
        }
        guard let input = self.integer(row["input_tokens"]), let output = self.integer(row["output_tokens"]),
              let cache = claude ? count("cache_read_input_tokens") : count(
                  "cached_input_tokens",
                  "cache_read_input_tokens"),
              let write = claude ? count("cache_creation_input_tokens") : count("cache_write_input_tokens"),
              claude || cache + write <= input else { return nil }
        let long = self.integer((row["cache_creation"] as? [String: Any])?["ephemeral_1h_input_tokens"]) ?? 0
        return Self(
            input: claude ? input : input - cache - write,
            cached: cache,
            written: write,
            output: output,
            longWrites: min(long, write))
    }
}

enum UsageRecord {
    case modern(thread: String, response: String, legacyPrefix: Date?)
    case legacy(thread: String, mirror: String)
    case claude(message: String, request: String?)
}

struct UsageObservation {
    let record: UsageRecord
    let date: Date
    let model: String
    let counts: TokenCounts
}

struct TranscriptState: Codable {
    private var thread: String?
    private var inherited = false
    private var discardedRoute = false
    private var model = ""
    private var legacyCounter: TokenCounts?
    private var legacyDate: Date?
    private var modernCounter: TokenCounts?
    private var modernThread: String?
    var partial = false

    private static let codexMarkers = ["session_meta", "token_usage_record", "token_count", "turn_context"]
        .map { Data("\"\($0)\"".utf8) }
    private static let claudeMarkers = ["\"assistant\"", "\"usage\""].map { Data($0.utf8) }

    mutating func consume(_ line: Data, provider: ProviderInstanceID) -> UsageObservation? {
        let interesting = provider == .codex
            ? Self.codexMarkers.contains { line.range(of: $0) != nil }
            : Self.claudeMarkers.allSatisfy { line.range(of: $0) != nil }
        guard interesting else { return nil }
        return autoreleasepool { self.parse(line, provider: provider) }
    }

    private mutating func parse(_ line: Data, provider: ProviderInstanceID) -> UsageObservation? {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = object["type"] as? String else { self.partial = true; return nil }
        if provider == .claude { return self.claude(type, object) }
        guard let payload = object["payload"] as? [String: Any] else { return nil }
        switch type {
        case "session_meta":
            self.thread = Self.identifier(payload["id"] ?? payload["session_id"])
            self.inherited = payload["forked_from_id"] is String || payload["history_base_thread_id"] is String
                || payload["history_base_thread"] is String
                || (payload["history_mode"] as? String)?.contains("fork") == true
            self.discardedRoute = (payload["model_provider"] as? String).map { $0 != "openai" } ?? false
        case "turn_context":
            self.model = Self.identifier(payload["model"]) ?? ""
        case "event_msg" where payload["type"] as? String == "token_count":
            return self.legacy(payload, date: Self.date(object["timestamp"]))
        case "token_usage_record":
            return self.modern(payload, date: Self.date(object["timestamp"]))
        default: break
        }
        return nil
    }

    private mutating func modern(_ payload: [String: Any], date: Date?) -> UsageObservation? {
        guard !self.discardedRoute, let thread = Self.identifier(payload["thread_id"]),
              let id = Self.identifier(payload["response_id"]), let date
        else {
            self.partial = true
            return nil
        }
        let last = (payload["usage"] as? [String: Any]).flatMap { TokenCounts.decode($0) }
        let total = (payload["thread_token_usage"] as? [String: Any]).flatMap { TokenCounts.decode($0) }
        let key = LedgerIdentity.hash("codex-thread:\(thread)")
        let previous = self.modernThread == key ? self.modernCounter : nil
        let delta = previous.flatMap { total?.delta(from: $0) }
        let firstOwned = self.modernThread == nil && thread == self.thread && !self.inherited
        let prefix: Date? = if firstOwned, let last, let legacy = self.legacyCounter,
                               total?.delta(from: last) == legacy, let previous = self.legacyDate, previous < date
        {
            previous
        } else {
            nil
        }
        self.modernCounter = total
        self.modernThread = key
        // Use the native cumulative delta in a continuous stream. The native increment bounds
        // jumps across a resume, reset or interleaved auxiliary request.
        let continuous = last == nil || delta == last
        let baseline = (previous != nil || firstOwned) ? total : nil
        guard var usage = (continuous ? delta : nil) ?? last ?? baseline else {
            self.partial = true
            return nil
        }
        guard usage.total > 0 else { return nil }
        if payload["prompt_cache_retention"] as? String == "12h" { usage.longWrites = usage.written }
        return UsageObservation(
            record: .modern(
                thread: key, response: LedgerIdentity.hash("codex-response:\(id)"), legacyPrefix: prefix),
            date: date,
            model: Self.identifier(payload["model"]) ?? self.model,
            counts: usage)
    }

    private mutating func legacy(_ payload: [String: Any], date: Date?) -> UsageObservation? {
        guard let info = payload["info"] as? [String: Any] else { return nil }
        guard !self.discardedRoute, let thread = self.thread, let date,
              let raw = info["total_token_usage"] as? [String: Any], let total = TokenCounts.decode(raw)
        else {
            self.partial = true
            return nil
        }
        let previous = self.legacyCounter
        self.legacyCounter = total
        defer { self.legacyDate = date }
        let last = (info["last_token_usage"] as? [String: Any]).flatMap { TokenCounts.decode($0) }
        if self.inherited, previous == nil {
            self.partial = true
            return nil
        }
        let delta = previous.flatMap { total.delta(from: $0) }
        if delta?.total == 0 { return nil }
        // Trust a continuous legacy counter. A native last increment is safer at a resume,
        // reset or unexplained jump than importing the balance carried into the file.
        let continuous = last == nil || delta == last
        let usage = (continuous ? delta : nil) ?? last ?? total
        guard usage.total > 0 else { return nil }
        return UsageObservation(
            record: .legacy(
                thread: LedgerIdentity.hash("codex-thread:\(thread)"),
                mirror: LedgerIdentity.hash("codex-token-count:\(thread):\(total.signature)")),
            date: date,
            model: self.model,
            counts: usage)
    }

    private mutating func claude(_ type: String, _ object: [String: Any]) -> UsageObservation? {
        guard type == "assistant", let message = object["message"] as? [String: Any],
              let raw = message["usage"] as? [String: Any] else { return nil }
        guard let model = Self.identifier(message["model"]), model.hasPrefix("claude-"), !model.contains("_vrtx_"),
              let date = Self.date(object["timestamp"]), let id = Self.identifier(message["id"]),
              let counts = TokenCounts.decode(raw, claude: true) else { self.partial = true; return nil }
        guard counts.total > 0 else { return nil }
        if message["stop_reason"] is NSNull, counts.input > 0, counts.output == 0,
           raw["cache_read_input_tokens"] == nil, raw["cache_creation_input_tokens"] == nil { return nil }
        let request = Self.identifier(object["requestId"] ?? object["request_id"])
        return UsageObservation(
            record: .claude(
                message: LedgerIdentity.hash("claude-message:\(id)"),
                request: request
                    .map { LedgerIdentity.hash("claude-request:\(id):\($0)") }),
            date: date,
            model: model,
            counts: counts)
    }

    private static func identifier(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty, value.utf8.count <= 512 else { return nil }
        return value
    }

    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text))
            ?? (try? Date.ISO8601FormatStyle().parse(text))
    }
}
