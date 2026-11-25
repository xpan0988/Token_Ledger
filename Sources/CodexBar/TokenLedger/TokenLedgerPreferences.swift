import CodexBarCore
import Foundation
import Observation

enum TokenLedgerLanguage: String, Codable, CaseIterable {
    case english = "en"
    case chinese = "zh-Hans"

    var locale: Locale {
        Locale(identifier: self == .english ? "en_AU" : "zh_CN")
    }

    func text(_ key: String) -> String {
        L(key, language: self.rawValue, table: "TokenLedger")
    }

    var name: String {
        self == .english ? "English" : "简体中文"
    }
}

enum TokenLedgerCurrency: String, Codable, CaseIterable {
    case aud = "AUD"
    case usd = "USD"
    case cny = "CNY"
    case eur = "EUR"
    case gbp = "GBP"

    var symbol: String {
        switch self {
        case .aud: "A$"
        case .usd: "US$"
        case .cny: "CN¥"
        case .eur: "€"
        case .gbp: "£"
        }
    }

    var label: String {
        "\(self.rawValue) (\(self.symbol))"
    }
}

struct TokenLedgerPayment: Codable, Identifiable, Equatable {
    let id: UUID
    let provider: ProviderInstanceID
    let providerName: String
    let amount: Decimal
    let currency: TokenLedgerCurrency
    let estimated: Bool
}

struct TokenLedgerOptions: Codable, Equatable {
    var enabled = false
    var shortcutEnabled = true
    var alwaysOnTop = true
    var followsActiveSpace = true
    var clickThrough = false
    var opacity = 1.0
    var hiddenProviders: Set<ProviderInstanceID> = []
    var currency = TokenLedgerCurrency.aud
    var language = TokenLedgerLanguage.english
}

@MainActor
@Observable
final class TokenLedgerPreferences {
    private static let optionsKey = "tokenLedger.options.v1"
    private static let paymentsKey = "tokenLedger.payments.v1"
    private let defaults: UserDefaults

    var options: TokenLedgerOptions {
        didSet {
            self.persist(self.options, key: Self.optionsKey)
            let signature = Self.menuSignature(for: self.options)
            if signature != self.menuSignature { self.menuSignature = signature }
        }
    }

    private(set) var payments: [TokenLedgerPayment] {
        didSet { self.persist(self.payments, key: Self.paymentsKey) }
    }

    private(set) var hidden = false
    private(set) var menuSignature: String

    init(defaults: UserDefaults) {
        self.defaults = defaults
        let options = defaults.data(forKey: Self.optionsKey)
            .flatMap { try? JSONDecoder().decode(TokenLedgerOptions.self, from: $0) } ?? .init()
        self.options = options
        self.menuSignature = Self.menuSignature(for: options)
        self.payments = defaults.data(forKey: Self.paymentsKey)
            .flatMap { try? JSONDecoder().decode([TokenLedgerPayment].self, from: $0) } ?? []
    }

    func text(_ key: String) -> String {
        self.options.language.text(key)
    }

    func text(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: self.text(key), locale: self.options.language.locale, arguments: arguments)
    }

    func toggleVisibility() {
        guard self.options.enabled else { return }
        self.hidden.toggle()
    }

    func save(_ payment: TokenLedgerPayment) {
        guard !payment.amount.isNaN, payment.amount >= 0 else { return }
        if let index = self.payments.firstIndex(where: { $0.id == payment.id }) {
            self.payments[index] = payment
        } else {
            self.payments.append(payment)
        }
    }

    func remove(_ id: UUID) {
        self.payments.removeAll { $0.id == id }
    }

    private static func menuSignature(for options: TokenLedgerOptions) -> String {
        options.enabled ? options.language.rawValue : ""
    }

    private func persist(_ value: some Encodable, key: String) {
        if let encoded = try? JSONEncoder().encode(value) {
            self.defaults.set(encoded, forKey: key)
        }
    }
}
