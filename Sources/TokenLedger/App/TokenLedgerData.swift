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
    private(set) var quotaFailures: Set<ProviderInstanceID> = []

    @ObservationIgnored private let preferences: TokenLedgerPreferences
    @ObservationIgnored private let collector: HistoryCollector
    @ObservationIgnored private let rates: CurrencyCache
    @ObservationIgnored private let probeDirectory: URL
    @ObservationIgnored private var quotaTask: Task<Void, Never>?
    @ObservationIgnored private var historyTask: Task<Void, Never>?
    @ObservationIgnored private var currencyTask: Task<Void, Never>?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var lastEnabled: Set<ProviderInstanceID>?

    init(preferences: TokenLedgerPreferences, directory: URL, legacy: LegacyMigration?) {
        self.preferences = preferences
        self.collector = HistoryCollector(
            file: directory.appendingPathComponent("history.json"),
            locations: .local(),
            legacyFile: legacy?.historyFile,
            legacyZone: legacy?.timeZone)
        self.rates = CurrencyCache(file: directory.appendingPathComponent("rates.json"))
        self.probeDirectory = directory.appendingPathComponent("Provider Probes", isDirectory: true)
    }

    func start() {
        self.observe()
        self.timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
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
            self.quotaTask = nil
            self.historyTask?.cancel()
            self.historyTask = nil
            self.quotas = self.quotas.filter { enabled.contains($0.key) }
            self.quotaFailures.formIntersection(enabled)
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
    }

    private func refreshHistory() {
        guard self.historyTask == nil else { return }
        self.historyTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
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

    private func refreshQuotas() {
        let enabled = self.enabled
        guard !enabled.isEmpty, self.quotaTask == nil else { return }
        do {
            try FileManager.default.createDirectory(at: self.probeDirectory, withIntermediateDirectories: true)
        } catch {
            self.quotaFailures = enabled
            return
        }
        let directory = self.probeDirectory
        self.quotaTask = Task { [weak self] in
            await withTaskGroup(of: (ProviderInstanceID, UsageSnapshot?).self) { tasks in
                for provider in enabled {
                    tasks.addTask { await (provider, QuotaCollector.fetch(provider, workingDirectory: directory)) }
                }
                for await (provider, snapshot) in tasks {
                    guard !Task.isCancelled, let self else { continue }
                    if let snapshot {
                        self.quotas[provider] = snapshot
                        self.quotaFailures.remove(provider)
                    } else {
                        self.quotaFailures.insert(provider)
                    }
                }
            }
            if !Task.isCancelled { self?.quotaTask = nil }
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
