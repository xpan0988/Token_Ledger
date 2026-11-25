// First-party list-price tables and formulas extracted from CodexBar (MIT).
import Foundation

enum LedgerPricing {
    struct CodexPricing {
        let inputCostPerToken: Double
        let outputCostPerToken: Double
        let cacheReadInputCostPerToken: Double?
        /// Optional cache-write (cache creation) rate. When nil, write tokens are billed at the
        /// uncached input rate (legacy Codex folding behavior).
        let cacheWriteInputCostPerToken: Double?
        let displayLabel: String?

        let thresholdTokens: Int?
        let inputCostPerTokenAboveThreshold: Double?
        let outputCostPerTokenAboveThreshold: Double?
        let cacheReadInputCostPerTokenAboveThreshold: Double?
        let cacheWriteInputCostPerTokenAboveThreshold: Double?

        init(
            inputCostPerToken: Double,
            outputCostPerToken: Double,
            cacheReadInputCostPerToken: Double?,
            displayLabel: String? = nil,
            cacheWriteInputCostPerToken: Double? = nil,
            thresholdTokens: Int? = nil,
            inputCostPerTokenAboveThreshold: Double? = nil,
            outputCostPerTokenAboveThreshold: Double? = nil,
            cacheReadInputCostPerTokenAboveThreshold: Double? = nil,
            cacheWriteInputCostPerTokenAboveThreshold: Double? = nil)
        {
            self.inputCostPerToken = inputCostPerToken
            self.outputCostPerToken = outputCostPerToken
            self.cacheReadInputCostPerToken = cacheReadInputCostPerToken
            self.cacheWriteInputCostPerToken = cacheWriteInputCostPerToken
            self.displayLabel = displayLabel
            self.thresholdTokens = thresholdTokens
            self.inputCostPerTokenAboveThreshold = inputCostPerTokenAboveThreshold
            self.outputCostPerTokenAboveThreshold = outputCostPerTokenAboveThreshold
            self.cacheReadInputCostPerTokenAboveThreshold = cacheReadInputCostPerTokenAboveThreshold
            self.cacheWriteInputCostPerTokenAboveThreshold = cacheWriteInputCostPerTokenAboveThreshold
        }
    }

    private static func longContextPricing(
        input: Double,
        cached: Double? = nil,
        write: Double? = nil,
        output: (standard: Double, long: Double)) -> CodexPricing
    {
        CodexPricing(
            inputCostPerToken: input,
            outputCostPerToken: output.standard,
            cacheReadInputCostPerToken: cached,
            cacheWriteInputCostPerToken: write,
            thresholdTokens: 272_000,
            inputCostPerTokenAboveThreshold: input * 2,
            outputCostPerTokenAboveThreshold: output.long,
            cacheReadInputCostPerTokenAboveThreshold: cached.map { $0 * 2 },
            cacheWriteInputCostPerTokenAboveThreshold: write.map { $0 * 2 })
    }

    struct ClaudePricing {
        let inputCostPerToken: Double
        let outputCostPerToken: Double
        let cacheCreationInputCostPerToken: Double
        let cacheReadInputCostPerToken: Double

        let thresholdTokens: Int?
        let inputCostPerTokenAboveThreshold: Double?
        let outputCostPerTokenAboveThreshold: Double?
        let cacheCreationInputCostPerTokenAboveThreshold: Double?
        let cacheReadInputCostPerTokenAboveThreshold: Double?
    }

    struct ClaudeCostTokens {
        let input: Int
        let cacheRead: Int
        let cacheCreation: Int
        let cacheCreation1h: Int
        let output: Int
    }

    private static let codex: [String: CodexPricing] = [
        "gpt-5": CodexPricing(
            inputCostPerToken: 1.25e-6,
            outputCostPerToken: 1e-5,
            cacheReadInputCostPerToken: 1.25e-7),
        "gpt-5-codex": CodexPricing(
            inputCostPerToken: 1.25e-6,
            outputCostPerToken: 1e-5,
            cacheReadInputCostPerToken: 1.25e-7),
        "gpt-5-mini": CodexPricing(
            inputCostPerToken: 2.5e-7,
            outputCostPerToken: 2e-6,
            cacheReadInputCostPerToken: 2.5e-8),
        "gpt-5-nano": CodexPricing(
            inputCostPerToken: 5e-8,
            outputCostPerToken: 4e-7,
            cacheReadInputCostPerToken: 5e-9),
        "gpt-5-pro": CodexPricing(
            inputCostPerToken: 1.5e-5,
            outputCostPerToken: 1.2e-4,
            cacheReadInputCostPerToken: nil),
        "gpt-5.1": CodexPricing(
            inputCostPerToken: 1.25e-6,
            outputCostPerToken: 1e-5,
            cacheReadInputCostPerToken: 1.25e-7),
        "gpt-5.1-codex": CodexPricing(
            inputCostPerToken: 1.25e-6,
            outputCostPerToken: 1e-5,
            cacheReadInputCostPerToken: 1.25e-7),
        "gpt-5.1-codex-max": CodexPricing(
            inputCostPerToken: 1.25e-6,
            outputCostPerToken: 1e-5,
            cacheReadInputCostPerToken: 1.25e-7),
        "gpt-5.1-codex-mini": CodexPricing(
            inputCostPerToken: 2.5e-7,
            outputCostPerToken: 2e-6,
            cacheReadInputCostPerToken: 2.5e-8),
        "gpt-5.2": CodexPricing(
            inputCostPerToken: 1.75e-6,
            outputCostPerToken: 1.4e-5,
            cacheReadInputCostPerToken: 1.75e-7),
        "gpt-5.2-codex": CodexPricing(
            inputCostPerToken: 1.75e-6,
            outputCostPerToken: 1.4e-5,
            cacheReadInputCostPerToken: 1.75e-7),
        "gpt-5.2-pro": CodexPricing(
            inputCostPerToken: 2.1e-5,
            outputCostPerToken: 1.68e-4,
            cacheReadInputCostPerToken: nil),
        "gpt-5.3-codex": CodexPricing(
            inputCostPerToken: 1.75e-6,
            outputCostPerToken: 1.4e-5,
            cacheReadInputCostPerToken: 1.75e-7),
        "gpt-5.3-codex-spark": CodexPricing(
            inputCostPerToken: 0,
            outputCostPerToken: 0,
            cacheReadInputCostPerToken: 0,
            displayLabel: "Research Preview"),
        "gpt-5.4": Self.longContextPricing(input: 2.5e-6, cached: 2.5e-7, output: (1.5e-5, 2.25e-5)),
        "gpt-5.4-mini": CodexPricing(
            inputCostPerToken: 7.5e-7,
            outputCostPerToken: 4.5e-6,
            cacheReadInputCostPerToken: 7.5e-8),
        "gpt-5.4-nano": CodexPricing(
            inputCostPerToken: 2e-7,
            outputCostPerToken: 1.25e-6,
            cacheReadInputCostPerToken: 2e-8),
        "gpt-5.4-pro": Self.longContextPricing(input: 3e-5, output: (1.8e-4, 2.7e-4)),
        "gpt-5.5": Self.longContextPricing(input: 5e-6, cached: 5e-7, output: (3e-5, 4.5e-5)),
        "gpt-5.5-pro": Self.longContextPricing(input: 3e-5, output: (1.8e-4, 2.7e-4)),
        // https://developers.openai.com/api/docs/models/gpt-6-astra and /api/docs/pricing.
        // The full request switches to long-context rates above 272K input tokens, including Fast mode.
        "gpt-6-astra": Self.longContextPricing(input: 1e-5, cached: 1e-6, write: 1.25e-5, output: (5e-5, 7.5e-5)),
        "gpt-6.1-sol": Self.longContextPricing(input: 2e-6, cached: 1e-7, write: 2.5e-6, output: (1e-5, 1.5e-5)),
        "gpt-6.1-terra": Self.longContextPricing(input: 1e-6, cached: 5e-8, write: 1.25e-6, output: (5e-6, 7.5e-6)),
        "gpt-6-sol": Self.longContextPricing(input: 2e-6, cached: 2e-7, write: 2.5e-6, output: (1e-5, 1.5e-5)),
        "gpt-6-luna": Self.longContextPricing(input: 1e-7, cached: 1e-8, write: 1.25e-7, output: (5e-7, 7.5e-7)),
        "gpt-6.2-astra": Self.longContextPricing(
            input: 8e-6, cached: 4e-7, write: 1e-5, output: (4e-5, 6e-5)),
        "gpt-6.2-sol": Self.longContextPricing(
            input: 2e-6, cached: 1e-7, write: 2.5e-6, output: (1e-5, 1.5e-5)),
        // GPT-5.6 Sol/Terra/Luna (OpenAI pricing page + model cards).
        // Long context: prompts with >272K input tokens are 2x input / 1.5x output for the full
        // request. Cache writes: 1.25x uncached input. API Fast support and multipliers are applied
        // separately after Standard pricing resolves from models.dev or this bundled fallback.
        // Sol was repriced from $5/$30 to $4/$20 on 2026-08-21.
        "gpt-5.6-sol": Self.longContextPricing(
            input: 4e-6, cached: 4e-7, write: 5e-6, output: (2e-5, 3e-5)),
        "gpt-5.6-terra": Self.longContextPricing(
            input: 2e-6, cached: 2e-7, write: 2.5e-6, output: (1.2e-5, 1.8e-5)),
        "gpt-5.6-luna": Self.longContextPricing(
            input: 2e-7, cached: 2e-8, write: 2.5e-7, output: (1.2e-6, 1.8e-6)),
        // Daybreak Cyber models (OpenAI pricing page). No long-context tier is published, and
        // gpt-5.5-cyber lists no cache-write rate.
        "gpt-5.6-cyber": CodexPricing(
            inputCostPerToken: 1.25e-5,
            outputCostPerToken: 7.5e-5,
            cacheReadInputCostPerToken: 1.25e-6,
            cacheWriteInputCostPerToken: 1.5625e-5),
        "gpt-5.5-cyber": CodexPricing(
            inputCostPerToken: 1.25e-5,
            outputCostPerToken: 7.5e-5,
            cacheReadInputCostPerToken: 1.25e-6),
    ]

    private static func claudeListPrice(
        input: Double, output: Double, cacheRead: Double,
        threshold: Int? = nil, above: ClaudePricing? = nil) -> ClaudePricing
    {
        let million = 1_000_000.0
        return ClaudePricing(
            inputCostPerToken: input / million,
            outputCostPerToken: output / million,
            cacheCreationInputCostPerToken: 1.25 * input / million,
            cacheReadInputCostPerToken: cacheRead / million,
            thresholdTokens: threshold,
            inputCostPerTokenAboveThreshold: above?.inputCostPerToken,
            outputCostPerTokenAboveThreshold: above?.outputCostPerToken,
            cacheCreationInputCostPerTokenAboveThreshold: above?.cacheCreationInputCostPerToken,
            cacheReadInputCostPerTokenAboveThreshold: above?.cacheReadInputCostPerToken)
    }

    private static let claude: [String: ClaudePricing] = [
        // Launch rates for the four observed Claude IDs, in USD per million tokens.
        // https://platform.claude.com/docs/en/about-claude/pricing
        "claude-opus-5-5": Self.claudeListPrice(input: 4, output: 20, cacheRead: 0.20),
        "claude-sonnet-5-5": Self.claudeListPrice(input: 2, output: 10, cacheRead: 0.10),
        "claude-fable-5-2": Self.claudeListPrice(input: 8, output: 40, cacheRead: 0.20),
        "claude-haiku-5-5": Self.claudeListPrice(
            input: 0.10, output: 0.50, cacheRead: 0.01, threshold: 100_000,
            above: Self.claudeListPrice(input: 0.50, output: 2.50, cacheRead: 0.05)),
        "claude-fable-5": ClaudePricing(
            inputCostPerToken: 1e-5,
            outputCostPerToken: 5e-5,
            cacheCreationInputCostPerToken: 1.25e-5,
            cacheReadInputCostPerToken: 1e-6,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-haiku-4-5-20251001": ClaudePricing(
            inputCostPerToken: 1e-6,
            outputCostPerToken: 5e-6,
            cacheCreationInputCostPerToken: 1.25e-6,
            cacheReadInputCostPerToken: 1e-7,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-haiku-4-5": ClaudePricing(
            inputCostPerToken: 1e-6,
            outputCostPerToken: 5e-6,
            cacheCreationInputCostPerToken: 1.25e-6,
            cacheReadInputCostPerToken: 1e-7,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        // Mythos is served to verified organizations only and is absent from the models.dev
        // anthropic catalog. Rates: https://platform.claude.com/docs/en/about-claude/pricing
        "claude-mythos-5": ClaudePricing(
            inputCostPerToken: 1e-5,
            outputCostPerToken: 5e-5,
            cacheCreationInputCostPerToken: 1.25e-5,
            cacheReadInputCostPerToken: 1e-6,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-mythos-5-1": ClaudePricing(
            inputCostPerToken: 1e-5,
            outputCostPerToken: 5e-5,
            cacheCreationInputCostPerToken: 1.25e-5,
            cacheReadInputCostPerToken: 2.5e-7,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-mythos-5-2": ClaudePricing(
            inputCostPerToken: 8e-6,
            outputCostPerToken: 4e-5,
            cacheCreationInputCostPerToken: 1e-5,
            cacheReadInputCostPerToken: 2e-7,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-opus-4-5-20251101": ClaudePricing(
            inputCostPerToken: 5e-6,
            outputCostPerToken: 2.5e-5,
            cacheCreationInputCostPerToken: 6.25e-6,
            cacheReadInputCostPerToken: 5e-7,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-opus-4-5": ClaudePricing(
            inputCostPerToken: 5e-6,
            outputCostPerToken: 2.5e-5,
            cacheCreationInputCostPerToken: 6.25e-6,
            cacheReadInputCostPerToken: 5e-7,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-opus-4-6-20260205": ClaudePricing(
            inputCostPerToken: 5e-6,
            outputCostPerToken: 2.5e-5,
            cacheCreationInputCostPerToken: 6.25e-6,
            cacheReadInputCostPerToken: 5e-7,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-opus-4-6": ClaudePricing(
            inputCostPerToken: 5e-6,
            outputCostPerToken: 2.5e-5,
            cacheCreationInputCostPerToken: 6.25e-6,
            cacheReadInputCostPerToken: 5e-7,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-opus-4-7": ClaudePricing(
            inputCostPerToken: 5e-6,
            outputCostPerToken: 2.5e-5,
            cacheCreationInputCostPerToken: 6.25e-6,
            cacheReadInputCostPerToken: 5e-7,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-opus-4-8": ClaudePricing(
            inputCostPerToken: 5e-6,
            outputCostPerToken: 2.5e-5,
            cacheCreationInputCostPerToken: 6.25e-6,
            cacheReadInputCostPerToken: 5e-7,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-sonnet-4-5": ClaudePricing(
            inputCostPerToken: 3e-6,
            outputCostPerToken: 1.5e-5,
            cacheCreationInputCostPerToken: 3.75e-6,
            cacheReadInputCostPerToken: 3e-7,
            thresholdTokens: 200_000,
            inputCostPerTokenAboveThreshold: 6e-6,
            outputCostPerTokenAboveThreshold: 2.25e-5,
            cacheCreationInputCostPerTokenAboveThreshold: 7.5e-6,
            cacheReadInputCostPerTokenAboveThreshold: 6e-7),
        "claude-sonnet-4-6": ClaudePricing(
            inputCostPerToken: 3e-6,
            outputCostPerToken: 1.5e-5,
            cacheCreationInputCostPerToken: 3.75e-6,
            cacheReadInputCostPerToken: 3e-7,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-sonnet-4-5-20250929": ClaudePricing(
            inputCostPerToken: 3e-6,
            outputCostPerToken: 1.5e-5,
            cacheCreationInputCostPerToken: 3.75e-6,
            cacheReadInputCostPerToken: 3e-7,
            thresholdTokens: 200_000,
            inputCostPerTokenAboveThreshold: 6e-6,
            outputCostPerTokenAboveThreshold: 2.25e-5,
            cacheCreationInputCostPerTokenAboveThreshold: 7.5e-6,
            cacheReadInputCostPerTokenAboveThreshold: 6e-7),
        "claude-opus-4-20250514": ClaudePricing(
            inputCostPerToken: 1.5e-5,
            outputCostPerToken: 7.5e-5,
            cacheCreationInputCostPerToken: 1.875e-5,
            cacheReadInputCostPerToken: 1.5e-6,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-opus-4-1": ClaudePricing(
            inputCostPerToken: 1.5e-5,
            outputCostPerToken: 7.5e-5,
            cacheCreationInputCostPerToken: 1.875e-5,
            cacheReadInputCostPerToken: 1.5e-6,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-sonnet-4-20250514": ClaudePricing(
            inputCostPerToken: 3e-6,
            outputCostPerToken: 1.5e-5,
            cacheCreationInputCostPerToken: 3.75e-6,
            cacheReadInputCostPerToken: 3e-7,
            thresholdTokens: 200_000,
            inputCostPerTokenAboveThreshold: 6e-6,
            outputCostPerTokenAboveThreshold: 2.25e-5,
            cacheCreationInputCostPerTokenAboveThreshold: 7.5e-6,
            cacheReadInputCostPerTokenAboveThreshold: 6e-7),
    ]

    // GPT-5.6 Terra and Luna rates effective before 2026-07-30 (Unix 1785369600).
    // Terra/Luna values from the OpenAI pricing page snapshot in PR #2521.
    // Co-authored-by: iam-brain (historical rate values).
    static let codexGPT56PricingCutoff = Date(timeIntervalSince1970: 1_785_369_600)
    // Sol repricing is dated August 21 in https://developers.openai.com/api/docs/changelog.
    private static let codexSolPricingCutoff = Date(timeIntervalSince1970: 1_787_270_400)
    private static let codexHistoricalPricing: [String: (cutoff: Date, pricing: CodexPricing)] = [
        "gpt-5.6-sol": (Self.codexSolPricingCutoff, Self.longContextPricing(
            input: 5e-6, cached: 5e-7, write: 6.25e-6, output: (3e-5, 4.5e-5))),
        "gpt-5.6-terra": (Self.codexGPT56PricingCutoff, Self.longContextPricing(
            input: 2.5e-6, cached: 2.5e-7, write: 3.125e-6, output: (1.5e-5, 2.25e-5))),
        "gpt-5.6-luna": (Self.codexGPT56PricingCutoff, Self.longContextPricing(
            input: 1e-6, cached: 1e-7, write: 1.25e-6, output: (6e-6, 9e-6))),
    ]

    private static let claudeFullContextStandardPricingCutoff = Date(timeIntervalSince1970: 1_773_360_000)
    // Anthropic reduced Sonnet 5.5 cache reads on 2026-10-07. Other rates were unchanged.
    // https://platform.claude.com/docs/en/release-notes/overview
    private static let claudeSonnet55CacheCutoff = Date(timeIntervalSince1970: 1_791_331_200)
    private static let claudeSonnet55Launch = Self.claudeListPrice(input: 2, output: 10, cacheRead: 0.20)
    private static let claudeHistoricalLongContext: [String: ClaudePricing] = [
        "claude-opus-4-6": ClaudePricing(
            inputCostPerToken: 5e-6,
            outputCostPerToken: 2.5e-5,
            cacheCreationInputCostPerToken: 6.25e-6,
            cacheReadInputCostPerToken: 5e-7,
            thresholdTokens: 200_000,
            inputCostPerTokenAboveThreshold: 1e-5,
            outputCostPerTokenAboveThreshold: 3.75e-5,
            cacheCreationInputCostPerTokenAboveThreshold: 1.25e-5,
            cacheReadInputCostPerTokenAboveThreshold: 1e-6),
        "claude-sonnet-4-6": ClaudePricing(
            inputCostPerToken: 3e-6,
            outputCostPerToken: 1.5e-5,
            cacheCreationInputCostPerToken: 3.75e-6,
            cacheReadInputCostPerToken: 3e-7,
            thresholdTokens: 200_000,
            inputCostPerTokenAboveThreshold: 6e-6,
            outputCostPerTokenAboveThreshold: 2.25e-5,
            cacheCreationInputCostPerTokenAboveThreshold: 7.5e-6,
            cacheReadInputCostPerTokenAboveThreshold: 6e-7),
    ]

    static func normalizeCodexModel(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("openai/") {
            trimmed = String(trimmed.dropFirst("openai/".count))
        }

        // OpenAI routes the unsuffixed gpt-5.6 alias to Sol.
        if trimmed == "gpt-5.6" {
            return "gpt-5.6-sol"
        }

        // Codex uses gpt-reserve for the Luna Reserve quota bucket.
        if trimmed == "gpt-reserve" {
            return "gpt-5.6-luna"
        }

        // OpenAI's Daybreak aliases currently point to Sol (blue) and Cyber (red).
        // https://developers.openai.com/api/docs/pricing
        if trimmed == "gpt-daybreak-blue-latest" {
            return "gpt-5.6-sol"
        }
        if trimmed == "gpt-daybreak-red-latest" {
            return "gpt-5.6-cyber"
        }

        if self.codex[trimmed] != nil {
            return trimmed
        }

        if let datedSuffix = trimmed.range(of: #"-\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) {
            let base = String(trimmed[..<datedSuffix.lowerBound])
            if self.codex[base] != nil {
                return base
            }
        }
        return trimmed
    }

    static func normalizeClaudeModel(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("anthropic.") {
            trimmed = String(trimmed.dropFirst("anthropic.".count))
        }

        if let lastDot = trimmed.lastIndex(of: "."),
           trimmed.contains("claude-")
        {
            let tail = String(trimmed[trimmed.index(after: lastDot)...])
            if tail.hasPrefix("claude-") {
                trimmed = tail
            }
        }

        if let vRange = trimmed.range(of: #"-v\d+:\d+$"#, options: .regularExpression) {
            trimmed.removeSubrange(vRange)
        }

        if let baseRange = trimmed.range(of: #"-\d{8}$"#, options: .regularExpression) {
            let base = String(trimmed[..<baseRange.lowerBound])
            if self.claude[base] != nil {
                return base
            }
        }

        return trimmed
    }

    static func codexAPIFastMultiplier(model: String) -> Double? {
        switch self.normalizeCodexModel(model) {
        case "gpt-5.4", "gpt-5.4-mini", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna": 2
        case "gpt-6-astra", "gpt-6.1-sol", "gpt-6.1-terra", "gpt-6-luna", "gpt-6.2-astra", "gpt-6.2-sol": 2
        case "gpt-5.5": 2.5
        default: nil
        }
    }

    /// Published API rates, including the promotion ending at midnight Pacific on March 1, 2027.
    static func codexAPIUltrafastMultiplier(model: String, date: Date?) -> Double? {
        switch self.normalizeCodexModel(model) {
        case "gpt-6-astra", "gpt-6.1-sol": 6
        case "gpt-6.2-astra", "gpt-6.2-sol":
            date.map { $0.timeIntervalSince1970 < 1_803_888_000 ? 3 : 6 }
        default: nil
        }
    }

    private static func codexAPIFastAllowsLongContext(model: String) -> Bool {
        switch self.normalizeCodexModel(model) {
        case "gpt-6-astra", "gpt-6.1-sol", "gpt-6.1-terra", "gpt-6-luna", "gpt-6.2-astra", "gpt-6.2-sol": true
        default: false
        }
    }

    static func codexCostUSD(
        pricing: CodexPricing,
        inputTokens: Int,
        cachedInputTokens: Int,
        cacheWriteInputTokens: Int = 0,
        outputTokens: Int) -> Double
    {
        // Codex/OpenAI reports `input_tokens` as the total prompt size, with cached reads as a
        // SUBSET of it. Cache writes (when tracked separately, e.g. Pi) are also a subset of the
        // non-cached remainder. Clamp so tokens are never invented or double-billed.
        let totalInput = max(0, inputTokens)
        let cached = min(max(0, cachedInputTokens), totalInput)
        let remainingAfterCache = totalInput - cached
        let cacheWrite = min(max(0, cacheWriteInputTokens), remainingAfterCache)
        let nonCached = remainingAfterCache - cacheWrite
        let cachedRate = pricing.cacheReadInputCostPerToken ?? pricing.inputCostPerToken

        let usesLongContextRates = pricing.thresholdTokens.map { totalInput > $0 } ?? false
        let inputRate = usesLongContextRates
            ? pricing.inputCostPerTokenAboveThreshold ?? pricing.inputCostPerToken
            : pricing.inputCostPerToken
        let cachedInputRate = usesLongContextRates
            ? pricing.cacheReadInputCostPerTokenAboveThreshold ?? pricing.cacheReadInputCostPerToken ?? inputRate
            : cachedRate
        let cacheWriteRate = usesLongContextRates
            ? pricing.cacheWriteInputCostPerTokenAboveThreshold
            ?? pricing.cacheWriteInputCostPerToken
            ?? inputRate
            : pricing.cacheWriteInputCostPerToken ?? inputRate
        let outputRate = usesLongContextRates
            ? pricing.outputCostPerTokenAboveThreshold ?? pricing.outputCostPerToken
            : pricing.outputCostPerToken

        return (Double(nonCached) * inputRate)
            + (Double(cached) * cachedInputRate)
            + (Double(cacheWrite) * cacheWriteRate)
            + (Double(max(0, outputTokens)) * outputRate)
    }

    private static func claudeCostUSD(
        pricing: ClaudePricing,
        tokens: ClaudeCostTokens) -> Double
    {
        let input = max(0, tokens.input)
        let cacheRead = max(0, tokens.cacheRead)
        let cacheCreationTotal = max(0, tokens.cacheCreation)
        let cacheCreation1h = min(max(0, tokens.cacheCreation1h), cacheCreationTotal)
        let cacheCreation5m = cacheCreationTotal - cacheCreation1h
        let usesLongContextRates = pricing.thresholdTokens.map { threshold in
            // Nonnegative components that overflow necessarily exceed every representable threshold.
            Decimal(input) + Decimal(cacheRead) + Decimal(cacheCreationTotal) > Decimal(threshold)
        } ?? false
        let inputRate = usesLongContextRates
            ? pricing.inputCostPerTokenAboveThreshold ?? pricing.inputCostPerToken
            : pricing.inputCostPerToken
        let cacheReadRate = usesLongContextRates
            ? pricing.cacheReadInputCostPerTokenAboveThreshold ?? pricing.cacheReadInputCostPerToken
            : pricing.cacheReadInputCostPerToken
        let cacheCreation5mRate = usesLongContextRates
            ? pricing.cacheCreationInputCostPerTokenAboveThreshold ?? pricing.cacheCreationInputCostPerToken
            : pricing.cacheCreationInputCostPerToken
        let outputRate = usesLongContextRates
            ? pricing.outputCostPerTokenAboveThreshold ?? pricing.outputCostPerToken
            : pricing.outputCostPerToken

        return Double(input) * inputRate
            + Double(cacheRead) * cacheReadRate
            + Double(cacheCreation5m) * cacheCreation5mRate
            + Double(cacheCreation1h) * inputRate * 2
            + Double(max(0, tokens.output)) * outputRate
    }

    static func codexCost(model: String?, tokens: TokenCounts, date: Date, tier: String?) -> Double? {
        guard let model else { return nil }
        let key = self.normalizeCodexModel(model)
        let historical = self.codexHistoricalPricing[key]
        let pricing = if let historical, date < historical.cutoff {
            historical.pricing
        } else {
            self.codex[key]
        }
        guard let pricing else { return nil }
        let multiplier: Double? = switch tier {
        case nil, "default", "standard", "flex": tier == "flex" ? nil : 1
        case "priority", "fast":
            tokens.input > 272_000 && !self.codexAPIFastAllowsLongContext(model: key)
                ? nil : self.codexAPIFastMultiplier(model: key)
        case "ultrafast": self.codexAPIUltrafastMultiplier(model: key, date: date)
        default: nil
        }
        return multiplier.map {
            $0 * self.codexCostUSD(
                pricing: pricing,
                inputTokens: tokens.input,
                cachedInputTokens: tokens.cached,
                cacheWriteInputTokens: tokens.written,
                outputTokens: tokens.output)
        }
    }

    static func claudeCost(
        model: String, tokens: TokenCounts, oneHour: Int, date: Date,
        tier: String? = nil, speed: String? = nil, inferenceGeo: String? = nil) -> Double?
    {
        guard tier == nil || tier == "standard" else { return nil }
        let key = self.normalizeClaudeModel(model)
        let rate: ClaudePricing? = if key == "claude-sonnet-5-5" && date < self.claudeSonnet55CacheCutoff {
            self.claudeSonnet55Launch
        } else if date < self.claudeFullContextStandardPricingCutoff {
            self.claudeHistoricalLongContext[key] ?? self.claude[key]
        } else {
            self.claude[key]
        }
        let speedMultiplier: Double
        switch speed {
        case nil, "standard": speedMultiplier = 1
        case "fast" where key == "claude-opus-5-5" || key == "claude-fable-5-2" || key == "claude-opus-4-8":
            speedMultiplier = 2
        default: return nil
        }
        let geographyMultiplier = inferenceGeo == "us" ? 1.1 : 1.0
        return rate.map {
            speedMultiplier * geographyMultiplier * self.claudeCostUSD(
                pricing: $0,
                tokens: ClaudeCostTokens(
                    input: tokens.input,
                    cacheRead: tokens.cached,
                    cacheCreation: tokens.written,
                    cacheCreation1h: oneHour,
                    output: tokens.output))
        }
    }
}
