import Foundation

package struct TokenLedgerExchangeRates: Codable, Equatable, Sendable {
    package var rates: [String: Double] = [:]
    package var fetchedAt: Date?

    package init(rates: [String: Double] = [:], fetchedAt: Date? = nil) {
        self.rates = rates
        self.fetchedAt = fetchedAt
    }

    package func sum(_ amounts: [TokenLedgerAmount], currency: String) -> Decimal? {
        guard !amounts.isEmpty else { return nil }
        var total: Decimal = 0
        for amount in amounts {
            if amount.currency == currency || amount.value == 0 {
                total += amount.value
                continue
            }
            guard let source = self.rate(amount.currency), let target = self.rate(currency) else { return nil }
            total += amount.value / source * target
        }
        return total.isNaN ? nil : total
    }

    private func rate(_ code: String) -> Decimal? {
        if code == "USD" { return 1 }
        guard let rate = self.rates[code], rate > 0 else { return nil }
        return TokenLedgerFormatting.decimal(rate)
    }
}

package actor CurrencyCache {
    private let file: URL
    private var snapshot: TokenLedgerExchangeRates
    private var attemptedAt: Date?

    package init(file: URL) {
        self.file = file
        self.snapshot = (try? Data(contentsOf: file)).flatMap {
            try? JSONDecoder().decode(TokenLedgerExchangeRates.self, from: $0)
        } ?? .init()
    }

    package func refresh(needed: Bool) async -> TokenLedgerExchangeRates {
        guard needed else { return self.snapshot }
        let now = Date()
        if self.snapshot.fetchedAt.map({ now.timeIntervalSince($0) < 86400 }) == true { return self.snapshot }
        if self.attemptedAt.map({ now.timeIntervalSince($0) < 300 }) == true { return self.snapshot }
        self.attemptedAt = now

        struct Response: Decodable { let result: String; let rates: [String: Double] }
        do {
            let url = URL(string: "https://open.er-api.com/v6/latest/USD")!
            let request = URLRequest(url: url, timeoutInterval: 12)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return self.snapshot }
            let parsed = try JSONDecoder().decode(Response.self, from: data)
            guard parsed.result == "success", parsed.rates["USD"] == 1 else { return self.snapshot }
            self.snapshot = TokenLedgerExchangeRates(
                rates: parsed.rates.filter { $0.value.isFinite && $0.value > 0 },
                fetchedAt: now)
            try CredentialFileWriter.writePrivate(JSONEncoder().encode(self.snapshot), to: self.file)
        } catch {
            // Keep the last verified conversion for offline display.
        }
        return self.snapshot
    }
}
