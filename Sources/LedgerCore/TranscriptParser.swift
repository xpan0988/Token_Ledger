// Accounting follows the upstream Codex and Claude JSONL formats. See LICENSE.
import CoreFoundation
import Foundation

struct TokenCounts: Codable, Equatable {
    var input: Int
    var cached: Int
    var written: Int
    var output: Int

    var total: Decimal {
        Decimal(self.input) + Decimal(self.output)
    }

    var signature: String {
        "\(self.input):\(self.cached):\(self.output)"
    }

    func subtracting(_ previous: Self) -> Self? {
        guard self.input >= previous.input, self.cached >= previous.cached, self.output >= previous.output,
              self.written >= previous.written else { return nil }
        return Self(
            input: self.input - previous.input,
            cached: self.cached - previous.cached,
            written: self.written - previous.written,
            output: self.output - previous.output)
    }

    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0,
              number.doubleValue < Double(Int.max), number.doubleValue.rounded(.towardZero) == number.doubleValue
        else { return nil }
        return number.intValue
    }

    private static func optional(_ row: [String: Any], _ keys: [String]) -> Int? {
        let supplied = keys.compactMap { row[$0] }
        let values = supplied.compactMap(Self.integer)
        guard values.count == supplied.count else { return nil }
        return values.max() ?? 0
    }

    static func decode(_ row: [String: Any], claude: Bool = false) -> Self? {
        guard let input = integer(row["input_tokens"]), let output = integer(row["output_tokens"]),
              let cache = optional(
                  row,
                  claude ? ["cache_read_input_tokens"]
                      : ["cached_input_tokens", "cache_read_input_tokens"]),
              let write = optional(row, claude ? ["cache_creation_input_tokens"] : ["cache_write_input_tokens"]),
              claude || (cache <= input && write <= input - cache)
        else { return nil }
        return Self(input: input, cached: cache, written: write, output: output)
    }
}

struct UsageObservation {
    let identity: String
    var alias: String?
    var date: Date
    var tokens: Decimal
    var cost: Double?
    var authoritative: Bool
}

struct TranscriptState: Codable {
    private var thread: String?
    private var inherited = false
    private var discardedRoute = false
    private var model: String?
    private var tier: String?
    private var previous: TokenCounts?
    private var legacyDiverged = false
    var partial = false

    private static let codexTypes: Set<String> = [
        "session_meta", "turn_context", "event_msg", "token_usage_record", "thread_settings_applied",
    ]
    private static let modernMarkers = [
        "session_meta",
        "token_usage_record",
        "token_count",
        "turn_context",
        "thread_settings_applied",
    ].map { Data($0.utf8) }
    private static let claudeMarkers = ["\"assistant\"", "\"usage\""].map { Data($0.utf8) }

    mutating func consume(_ line: Data, provider: ProviderInstanceID) -> UsageObservation? {
        let interesting = provider == .codex
            ? Self.modernMarkers.contains { line.range(of: $0) != nil }
            : Self.claudeMarkers.allSatisfy { line.range(of: $0) != nil }
        guard interesting else { return nil }
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = object["type"] as? String
        else { self.partial = true; return nil }
        if provider == .claude { return self.claude(type: type, object: object) }
        guard Self.codexTypes.contains(type), let payload = object["payload"] as? [String: Any] else { return nil }
        switch type {
        case "session_meta":
            self.thread = Self.identifier(payload["id"] ?? payload["session_id"])
            self.inherited = payload["forked_from_id"] is String || payload["history_base_thread_id"] is String
                || payload["history_base_thread"] is String || payload["thread_source"] is [String: Any]
                || (payload["source"] as? [String: Any])?["subagent"] != nil
                || (payload["history_mode"] as? String).map { $0.contains("fork") } == true
            let route = payload["model_provider"] as? String
            self.discardedRoute = route.map { $0 != "openai" } ?? false
        case "turn_context":
            self.model = Self.identifier(payload["model"])
            self.tier = Self.identifier(payload["service_tier"]) ?? self.tier
        case "thread_settings_applied":
            self.tier = Self.identifier(payload["service_tier"])
        case "event_msg":
            return self.legacyCodex(payload: payload, date: Self.date(object["timestamp"]))
        case "token_usage_record":
            return self.typedCodex(payload: payload, date: Self.date(object["timestamp"]))
        default: break
        }
        return nil
    }

    private mutating func typedCodex(payload: [String: Any], date: Date?) -> UsageObservation? {
        guard !self.discardedRoute else { self.partial = true; return nil }
        guard let thread = Self.identifier(payload["thread_id"]),
              let id = Self.identifier(payload["response_id"]),
              let rawUsage = payload["usage"] as? [String: Any],
              let rawTotal = payload["thread_token_usage"] as? [String: Any],
              let usage = TokenCounts.decode(rawUsage), let total = TokenCounts.decode(rawTotal),
              total.subtracting(usage) != nil, let date
        else { self.partial = true; return nil }
        // A copied prefix can contain the parent thread's typed rows. Their response IDs
        // stay global, so the reference can never bill both the parent and child.
        guard usage.total > 0 else { return nil }
        let model = Self.identifier(payload["model"]) ?? self.model
        let tier = Self.identifier(payload["service_tier"]) ?? self.tier
        return UsageObservation(
            identity: LedgerIdentity.hash("codex-response:\(id)"),
            alias: Self.codexMirror(thread: thread, total: total),
            date: date,
            tokens: usage.total,
            cost: LedgerPricing.codexCost(model: model, tokens: usage, date: date, tier: tier),
            authoritative: true)
    }

    private mutating func legacyCodex(payload: [String: Any], date: Date?) -> UsageObservation? {
        guard payload["type"] as? String == "token_count", let info = payload["info"] as? [String: Any] else {
            return nil
        }
        guard !self.discardedRoute, let thread = self.thread, let date,
              let rawTotal = info["total_token_usage"] as? [String: Any], let total = TokenCounts.decode(rawTotal)
        else { self.partial = true; return nil }
        let last = (info["last_token_usage"] as? [String: Any]).flatMap { TokenCounts.decode($0) }
        let previous = self.previous
        if !self.inherited, !self.legacyDiverged {
            self.previous = total
        }
        if previous == total { return nil }
        let delta: TokenCounts
        if let previous, !self.inherited, !self.legacyDiverged {
            guard let difference = total.subtracting(previous) else {
                self.legacyDiverged = true
                self.partial = true
                return nil
            }
            if let last, difference != last {
                // A truncated, interleaved or resumed trace can jump a cumulative counter.
                // Keep only the corroborated request and flag the gap.
                guard difference.subtracting(last) != nil else { self.partial = true; return nil }
                self.partial = true
                delta = last
            } else {
                delta = difference
            }
        } else if let last, !self.inherited, !self.legacyDiverged, total.subtracting(last) != nil {
            if total != last { self.partial = true }
            delta = last
        } else {
            // A fork's legacy counters may echo a parent. Preserve the omission as partial.
            self.partial = true
            return nil
        }
        guard delta.total > 0 else { return nil }
        return UsageObservation(
            identity: Self.codexMirror(thread: thread, total: total),
            date: date,
            tokens: delta.total,
            cost: LedgerPricing.codexCost(model: self.model, tokens: delta, date: date, tier: self.tier),
            authoritative: false)
    }

    private mutating func claude(type: String, object: [String: Any]) -> UsageObservation? {
        guard type == "assistant", let message = object["message"] as? [String: Any],
              let raw = message["usage"] as? [String: Any] else { return nil }
        guard let model = Self.identifier(message["model"]), !model.hasPrefix("anthropic."),
              !model.contains("_vrtx_"), model.hasPrefix("claude-")
        else { self.partial = true; return nil }
        guard let date = Self.date(object["timestamp"]), let messageID = Self.identifier(message["id"]),
              let tokens = TokenCounts.decode(raw, claude: true)
        else { self.partial = true; return nil }
        guard tokens.total + Decimal(tokens.cached) + Decimal(tokens.written) > 0 else { return nil }
        if message["stop_reason"] is NSNull, tokens.input > 0, tokens.output == 0,
           raw["cache_read_input_tokens"] == nil, raw["cache_creation_input_tokens"] == nil
        { return nil }
        let request = Self.identifier(object["requestId"] ?? object["request_id"])
        let oneHour = TokenCounts.integer((raw["cache_creation"] as? [String: Any])?["ephemeral_1h_input_tokens"]) ?? 0
        return UsageObservation(
            identity: request.map { LedgerIdentity.hash("claude-request:\(messageID):\($0)") }
                ?? LedgerIdentity.hash("claude-message:\(messageID)"),
            alias: request.map { _ in LedgerIdentity.hash("claude-message:\(messageID)") },
            date: date,
            tokens: tokens.total + Decimal(tokens.cached) + Decimal(tokens.written),
            cost: LedgerPricing.claudeCost(model: model, tokens: tokens, oneHour: oneHour, date: date),
            authoritative: request != nil)
    }

    private static func codexMirror(thread: String, total: TokenCounts) -> String {
        LedgerIdentity.hash("codex-token-count:\(thread):\(total.signature)")
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
