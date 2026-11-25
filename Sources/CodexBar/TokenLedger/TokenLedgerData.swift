import CodexBarCore
import Foundation
import Observation

actor TokenLedgerHistoryStore {
    private let file: URL
    private var history: TokenLedgerHistory?
    private var pendingWrite = false
    private var failedToRead = false

    init(file: URL) {
        self.file = file
    }

    func update(
        publication: SpendDashboardPublication,
        enabled: Set<ProviderInstanceID>) -> (TokenLedgerTotals, Bool)
    {
        var history = self.history ?? self.load()
        let result = history.ingest(publication, enabledProviders: enabled)
        self.history = history
        self.pendingWrite = self.pendingWrite || result.changed
        if self.failedToRead { return (result.totals, true) }
        if self.pendingWrite {
            do {
                try CredentialFileWriter.writePrivate(JSONEncoder().encode(history), to: self.file)
                self.pendingWrite = false
            } catch {
                return (result.totals, true)
            }
        }
        return (result.totals, false)
    }

    private func load() -> TokenLedgerHistory {
        guard FileManager.default.fileExists(atPath: self.file.path) else { return .init() }
        do {
            let data = try Data(contentsOf: self.file)
            return try JSONDecoder().decode(TokenLedgerHistory.self, from: data)
        } catch {
            // Preserve a damaged or temporarily unreadable file for recovery.
            self.failedToRead = true
            return .init()
        }
    }
}

struct TokenLedgerExchangeRates: Equatable {
    var rates: [String: Double] = [:]
    var fetchedAt: Date?

    func sum(_ amounts: [TokenLedgerAmount], currency: TokenLedgerCurrency) -> Decimal? {
        guard !amounts.isEmpty else { return nil }
        var total: Decimal = 0
        for amount in amounts {
            if amount.currency == currency.rawValue || amount.value == 0 {
                total += amount.value
                continue
            }
            guard let source = self.rate(amount.currency), let target = self.rate(currency.rawValue)
            else { return nil }
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

@MainActor
@Observable
final class TokenLedgerData {
    private(set) var totals = TokenLedgerTotals()
    private(set) var exchange = TokenLedgerExchangeRates()
    private(set) var persistenceFailed = false

    @ObservationIgnored private let history: TokenLedgerHistoryStore
    @ObservationIgnored private var pendingPublication: SpendDashboardPublication?
    @ObservationIgnored private var enabled: Set<ProviderInstanceID> = []
    @ObservationIgnored private var historyTask: Task<Void, Never>?
    @ObservationIgnored private var ratesTask: Task<Void, Never>?

    init(file: URL) {
        self.history = TokenLedgerHistoryStore(file: file)
        self.readRates()
    }

    func update(
        publication: SpendDashboardPublication,
        enabled: Set<ProviderInstanceID>,
        preferences: TokenLedgerPreferences)
    {
        self.pendingPublication = publication
        self.enabled = enabled
        guard self.historyTask == nil else { return }
        self.historyTask = Task { [weak self, weak preferences] in
            guard let self else { return }
            while let publication = self.pendingPublication {
                self.pendingPublication = nil
                let (totals, failed) = await self.history.update(publication: publication, enabled: self.enabled)
                self.totals = totals
                self.persistenceFailed = failed
            }
            self.historyTask = nil
            if let preferences { self.refreshRatesIfNeeded(preferences: preferences) }
        }
    }

    func refreshRatesIfNeeded(preferences: TokenLedgerPreferences) {
        guard self.ratesTask == nil, preferences.options.enabled else { return }
        self.readRates()
        let target = preferences.options.currency.rawValue
        let requiresRates = self.totals.apiCosts.contains { $0.currency != target && $0.value != 0 }
            || preferences.payments.contains { $0.currency.rawValue != target && $0.amount != 0 }
        guard requiresRates else { return }
        self.ratesTask = Task { [weak self] in
            await CurrencyExchange.shared.refreshVerifiedRatesIfNeeded()
            self?.readRates()
            self?.ratesTask = nil
        }
    }

    private func readRates() {
        let verified = CurrencyExchange.shared.verifiedRateSnapshot()
        let exchange = TokenLedgerExchangeRates(rates: verified.rates, fetchedAt: verified.fetchedAt)
        if self.exchange != exchange { self.exchange = exchange }
    }
}

@MainActor
extension UsageStore {
    func tokenLedgerProviderName(_ id: ProviderInstanceID) -> String {
        if let provider = id.firstPartyProvider { return self.metadata(for: provider).displayName }
        return UserProviderPluginRegistry.plugin(for: id)?.manifest.name ?? id.rawValue
    }
}
