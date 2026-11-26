import CryptoKit
import Foundation

package struct ProviderInstanceID: Codable, Hashable, Comparable, Sendable {
    package let rawValue: String

    package init(_ rawValue: String) { self.rawValue = rawValue }

    package init(from decoder: Decoder) throws {
        self.rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.rawValue)
    }

    package static let codex = Self("codex")
    package static let claude = Self("claude")
    package static let gemini = Self("gemini")
    package static let supported: [Self] = [.codex, .claude]

    package var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        case .gemini: "Gemini"
        default: self.rawValue
        }
    }

    package static func < (left: Self, right: Self) -> Bool { left.rawValue < right.rawValue }
}

package struct RateWindow: Equatable, Sendable {
    package let usedPercent: Double
    package let windowMinutes: Int
    package let resetsAt: Date?
    package let isSyntheticPlaceholder: Bool

    package init(usedPercent: Double, windowMinutes: Int, resetsAt: Date?, isSyntheticPlaceholder: Bool = false) {
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
        self.isSyntheticPlaceholder = isSyntheticPlaceholder
    }
}

package struct UsageSnapshot: Sendable {
    package let primary: RateWindow?
    package let secondary: RateWindow?
    package let tertiary: RateWindow?
    package let updatedAt: Date

    package init(primary: RateWindow?, secondary: RateWindow?, tertiary: RateWindow? = nil, updatedAt: Date = Date()) {
        self.primary = primary
        self.secondary = secondary
        self.tertiary = tertiary
        self.updatedAt = updatedAt
    }
}

package struct TokenLedgerAmount: Sendable, Equatable {
    package let currency: String
    package let value: Decimal

    package init(currency: String, value: Decimal) {
        self.currency = currency
        self.value = value
    }
}

package struct TokenLedgerTotals: Sendable, Equatable {
    package var tokens: [ProviderInstanceID: Decimal] = [:]
    package var apiCosts: [TokenLedgerAmount] = []
    package var tokenCoverageIsPartial = false
    package var priceCoverageIsPartial = false
    package var stale = false

    package init() {}

    package var totalTokens: Decimal? {
        self.tokens.isEmpty ? nil : self.tokens.values.reduce(0, +)
    }

    package func displayTokens(codexLifetime: Int64?) -> Decimal? {
        guard let codexLifetime else { return self.totalTokens }
        var display = self.tokens
        display[.codex] = Decimal(codexLifetime)
        return display.values.reduce(0, +)
    }
}

enum LedgerIdentity {
    static func hash(_ value: String) -> String {
        Data(SHA256.hash(data: Data(value.utf8)).prefix(20)).base64EncodedString()
    }
}
