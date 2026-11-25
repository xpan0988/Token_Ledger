import Foundation
import LedgerCore
import Observation

enum TokenLedgerLanguage: String, Codable, CaseIterable {
    case english = "en"
    case chinese = "zh-Hans"

    var locale: Locale {
        Locale(identifier: self == .english ? "en_AU" : "zh_CN")
    }

    private static let bundles: [Self: Bundle] = {
        let resources = Bundle.main.url(forResource: "TokenLedger_TokenLedger", withExtension: "bundle")
            .flatMap(Bundle.init(url:)) ?? Bundle.module
        return Dictionary(uniqueKeysWithValues: Self.allCases.map { language in
            let path = resources.path(forResource: language.rawValue, ofType: "lproj")
                ?? resources.path(forResource: language.rawValue.lowercased(), ofType: "lproj")
            return (language, path.flatMap(Bundle.init(path:)) ?? resources)
        })
    }()

    func text(_ key: String) -> String {
        Self.bundles[self]?.localizedString(forKey: key, value: nil, table: "TokenLedger") ?? key
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
    var enabled = true
    var shortcutEnabled = true
    var alwaysOnTop = true
    var followsActiveSpace = true
    var clickThrough = false
    var opacity = 1.0
    var disabledProviders: Set<ProviderInstanceID> = []
    var hiddenProviders: Set<ProviderInstanceID> = []
    var currency = TokenLedgerCurrency.aud
    var language = TokenLedgerLanguage.english
}

@MainActor
@Observable
final class TokenLedgerPreferences {
    private static let optionsKey = "tokenLedger.options.v1"
    private static let paymentsKey = "tokenLedger.payments.v1"
    let defaults: UserDefaults

    var options: TokenLedgerOptions {
        didSet {
            self.persist(self.options, key: Self.optionsKey)
        }
    }

    private(set) var payments: [TokenLedgerPayment] {
        didSet { self.persist(self.payments, key: Self.paymentsKey) }
    }

    private(set) var hidden = false

    init(defaults: UserDefaults, legacy: UserDefaults? = nil) {
        self.defaults = defaults
        let pending = !defaults.bool(forKey: "tokenLedger.migrated")
        let incoming = pending ? legacy : nil
        let stored = defaults.data(forKey: Self.optionsKey)
        var optionData = stored ?? incoming?.data(forKey: Self.optionsKey)
        if stored == nil, let data = optionData,
           var old = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        {
            old["disabledProviders"] = []
            optionData = try? JSONSerialization.data(withJSONObject: old)
        }
        self.options = optionData.flatMap { try? JSONDecoder().decode(TokenLedgerOptions.self, from: $0) } ?? .init()
        let payments = defaults.data(forKey: Self.paymentsKey) ?? incoming?.data(forKey: Self.paymentsKey)
        self.payments = payments.flatMap { try? JSONDecoder().decode([TokenLedgerPayment].self, from: $0) } ?? []
        if pending {
            self.persist(self.options, key: Self.optionsKey)
            self.persist(self.payments, key: Self.paymentsKey)
            if defaults.object(forKey: "tokenLedger.frame") == nil,
               let frame = incoming?.string(forKey: "tokenLedger.frame")
            {
                defaults.set(frame, forKey: "tokenLedger.frame")
            }
            defaults.set(true, forKey: "tokenLedger.migrated")
        }
    }

    func text(_ key: String) -> String {
        self.options.language.text(key)
    }

    func text(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: self.text(key), locale: self.options.language.locale, arguments: arguments)
    }

    func toggleVisibility() {
        if self.options.enabled {
            self.hidden.toggle()
        } else {
            self.hidden = false
            self.options.enabled = true
        }
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

    private func persist(_ value: some Encodable, key: String) {
        if let encoded = try? JSONEncoder().encode(value) {
            self.defaults.set(encoded, forKey: key)
        }
    }
}
