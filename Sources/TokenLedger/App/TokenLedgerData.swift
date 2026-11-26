import Foundation
import LedgerCore
import Observation

@MainActor
@Observable
final class TokenLedgerData {
    private(set) var totals = TokenLedgerTotals()
    private(set) var exchange = TokenLedgerExchangeRates()
    private(set) var persistenceFailed = false
    private(set) var quotas: [ProviderInstanceID: UsageSnapshot] = [:]
    private(set) var codexProfile: CodexProfileValue?
    private(set) var quotaFailures: Set<ProviderInstanceID> = []

    @ObservationIgnored private let preferences: TokenLedgerPreferences
    @ObservationIgnored private let collector: HistoryCollector
    @ObservationIgnored private let rates: CurrencyCache
    @ObservationIgnored private let priceCatalog: PricingCatalogStore
    @ObservationIgnored private let probeDirectory: URL
    @ObservationIgnored private var profileCache: CodexProfileCache
    @ObservationIgnored private var lastQuotaProbe: [ProviderInstanceID: Date] = [:]
    @ObservationIgnored private var quotaTask: Task<Void, Never>?
    @ObservationIgnored private var historyTask: Task<Void, Never>?
    @ObservationIgnored private var currencyTask: Task<Void, Never>?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var pricingTask: Task<Void, Never>?
    @ObservationIgnored private var loadedPricing = false
    @ObservationIgnored private var lastEnabled: Set<ProviderInstanceID>?

    init(preferences: TokenLedgerPreferences, directory: URL, legacy: LegacyMigration?) {
        self.preferences = preferences
        self.collector = HistoryCollector(
            file: directory.appendingPathComponent("history.sqlite"),
            locations: .local(),
            legacyFile: legacy?.historyFile,
            legacyZone: legacy?.timeZone)
        self.rates = CurrencyCache(file: directory.appendingPathComponent("rates.json"))
        self.priceCatalog = PricingCatalogStore(directory: directory)
        self.probeDirectory = directory.appendingPathComponent("Provider Probes", isDirectory: true)
        self.profileCache = CodexProfileCache(file: directory.appendingPathComponent("codex-profile.json"))
    }

    func start() {
        self.observe()
        self.timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300), tolerance: .seconds(30))
                if Task.isCancelled { return }
                self?.refresh()
            }
        }
    }

    private func observe() {
        let enabled = withObservationTracking {
            _ = self.preferences.payments
            _ = self.preferences.options.currency
            return self.enabled
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        if enabled != self.lastEnabled {
            self.lastEnabled = enabled
            self.quotaTask?.cancel()
            self.lastQuotaProbe = self.lastQuotaProbe.filter { enabled.contains($0.key) }
            self.historyTask?.cancel()
            self.historyTask = nil
            self.quotas = self.quotas.filter { enabled.contains($0.key) }
            self.quotaFailures.formIntersection(enabled)
            if !enabled.contains(.codex) { self.codexProfile = nil }
            self.refresh()
        }
        self.refreshCurrency()
    }

    private var enabled: Set<ProviderInstanceID> {
        Set(ProviderInstanceID.supported).subtracting(self.preferences.options.disabledProviders)
    }

    private func refresh() {
        self.refreshHistory()
        self.refreshQuotas()
        self.refreshCurrency()
        self.refreshPricing()
    }

    private func refreshHistory() {
        guard self.historyTask == nil else { return }
        self.historyTask = Task { [weak self] in
            guard let self else { return }
            if !self.loadedPricing {
                await self.collector.updatePricing(self.priceCatalog.snapshot())
                self.loadedPricing = true
            }
            while !Task.isCancelled {
                let result = await self.collector.collect(self.enabled)
                guard !Task.isCancelled else { return }
                self.totals = result.totals
                self.persistenceFailed = result.persistenceFailed
                self.refreshCurrency()
                guard result.pending else {
                    self.historyTask = nil
                    return
                }
                try? await Task.sleep(for: .milliseconds(900))
            }
        }
    }

    private func refreshPricing() {
        guard self.pricingTask == nil else { return }
        let store = self.priceCatalog
        self.pricingTask = Task { [weak self] in
            let update = await store.refresh()
            guard let self else { return }
            self.pricingTask = nil
            if let update, let totals = await self.collector.updatePricing(update) {
                self.totals = totals
                self.refreshCurrency()
            }
        }
    }

    private func refreshQuotas() {
        guard self.quotaTask == nil else { return }
        let now = Date()
        let due = ProviderInstanceID.supported.filter { provider in
            guard self.enabled.contains(provider) else { return false }
            let interval: TimeInterval = provider == .claude ? 900 : 300
            // Allow a small scheduling tolerance on the shared five-minute refresh.
            return self.lastQuotaProbe[provider].map { now.timeIntervalSince($0) >= interval - 30 } ?? true
        }
        guard !due.isEmpty else { return }
        do {
            try FileManager.default.createDirectory(at: self.probeDirectory, withIntermediateDirectories: true)
        } catch {
            self.quotaFailures.formUnion(due)
            return
        }
        let directory = self.probeDirectory
        self.quotaTask = Task { [weak self] in
            for provider in due {
                guard !Task.isCancelled else { break }
                let started = Date()
                let result = await QuotaCollector.fetch(provider, workingDirectory: directory)
                guard !Task.isCancelled, let self else { break }
                self.lastQuotaProbe[provider] = started
                if provider == .codex { self.codexProfile = self.profileCache.resolve(result.codexProfile) }
                if let snapshot = result.quota {
                    self.quotas[provider] = snapshot
                    self.quotaFailures.remove(provider)
                } else {
                    self.quotaFailures.insert(provider)
                }
            }
            self?.quotaTask = nil
            if Task.isCancelled { self?.refreshQuotas() }
        }
    }

    private func refreshCurrency() {
        guard self.currencyTask == nil else { return }
        let target = self.preferences.options.currency.rawValue
        let needed = self.totals.apiCosts.contains { $0.currency != target && $0.value != 0 }
            || self.preferences.payments.contains { $0.currency.rawValue != target && $0.amount != 0 }
        let rates = self.rates
        self.currencyTask = Task { [weak self] in
            let snapshot = await rates.refresh(needed: needed)
            self?.exchange = snapshot
            self?.currencyTask = nil
        }
    }

    func deleteHistory() async -> Bool {
        self.historyTask?.cancel()
        self.historyTask = nil
        let deleted = await self.collector.delete()
        self.persistenceFailed = !deleted
        self.refreshHistory()
        return deleted
    }
}
