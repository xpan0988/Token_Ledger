import Foundation
import Testing
@testable import LedgerCore
@testable import TokenLedger

@MainActor
struct PresentationTests {
    @Test
    func `compact Chinese token units and international money units promote after rounding`() {
        let english = TokenLedgerLanguage.english.locale
        let chinese = TokenLedgerLanguage.chinese.locale
        #expect(TokenLedgerFormatting.compact(11_640_000_000, locale: english) == "11.64B")
        #expect(TokenLedgerFormatting.compact(999_995, locale: english) == "1M")
        #expect(TokenLedgerFormatting.compact(28624, locale: chinese) == "28.62K")
        #expect(TokenLedgerFormatting.compact(11_640_000_000, locale: chinese, chineseUnits: true) == "116.4亿")
        #expect(TokenLedgerFormatting.compact(99_999_996, locale: chinese, chineseUnits: true) == "1亿")
        #expect(TokenLedgerFormatting.compact(1_250_000_000_000, locale: chinese, chineseUnits: true) == "1.25万亿")
    }

    @Test
    func `provider launch from the GUI adds fallback paths to the child environment`() throws {
        let command = try #require(ProviderProcess.command("sh", environment: [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "CODEX_HOME": "/test/fixture",
        ]))
        let path = try #require(command.environment["PATH"]).split(separator: ":")
        #expect(command.executable.lastPathComponent == "sh")
        #expect(path.prefix(4).map(String.init) == ["/usr/bin", "/bin", "/usr/sbin", "/sbin"])
        #expect(path.contains("/opt/homebrew/bin"))
        #expect(path.contains("/usr/local/bin"))
        #expect(Set(path).count == path.count)
        #expect(command.environment["CODEX_HOME"] == "/test/fixture")
    }

    @Test
    func `codex chooses genuine five-hour and weekly quotas`() throws {
        let quota = try #require(QuotaCollector.codexWindows(["rateLimits": [
            "primary": ["usedPercent": 0, "windowDurationMins": 300],
            "secondary": ["usedPercent": 44, "windowDurationMins": 10080],
        ]]))
        let rates = TokenLedgerQuotas(snapshot: quota, failed: false)
        #expect(rates.fiveHour?.usedPercent == 0)
        #expect(rates.weekly?.usedPercent == 44)
        #expect(QuotaCollector.codexWindows(["rateLimits": [
            "primary": ["usedPercent": 50, "windowDurationMins": 1440],
        ]]) == nil)
    }

    @Test
    func `claude quota parser ignores model-specific weekly limits and translates remaining usage`() throws {
        let text = """
        Current session
        24% used
        Current week (all models)
        31% remaining
        Current week (Sonnet only)
        92% used
        """
        let snapshot = try #require(QuotaCollector.claudeWindows(text))
        #expect(snapshot.primary?.usedPercent == 24)
        #expect(snapshot.secondary?.usedPercent == 69)
        #expect(QuotaCollector.claudeWindows("Current week (Sonnet only) 92% used") == nil)
        #expect(!QuotaCollector.claudePromptIsReady("Do you trust this folder? ❯"))
    }

    @Test
    func `preferences and payments retain original currencies across language and visibility changes`() throws {
        let domain = "TokenLedger-test-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = TokenLedgerPreferences(defaults: defaults)
        #expect(preferences.options.currency == .aud)
        #expect(preferences.text("ledger.totalPaid") == "Total Paid")
        preferences.options.language = .chinese
        preferences.options.hiddenProviders.insert(.claude)
        preferences.options.disabledProviders.insert(.codex)
        let payment = TokenLedgerPayment(
            id: UUID(),
            provider: .claude,
            providerName: "Claude",
            amount: 25,
            currency: .usd,
            estimated: true)
        preferences.save(payment)
        let reloaded = TokenLedgerPreferences(defaults: defaults)
        #expect(reloaded.text("ledger.totalPaid") == "累计订阅支出")
        #expect(reloaded.options.hiddenProviders == [.claude])
        #expect(reloaded.options.disabledProviders == [.codex])
        #expect(reloaded.payments == [payment])
    }

    @Test
    func `embedded preferences are copied once and corrections stay local`() throws {
        let oldName = "TokenLedger-old-\(UUID())"
        let newName = "TokenLedger-new-\(UUID())"
        let old = try #require(UserDefaults(suiteName: oldName))
        let current = try #require(UserDefaults(suiteName: newName))
        defer {
            old.removePersistentDomain(forName: oldName)
            current.removePersistentDomain(forName: newName)
        }
        let options = Data(#"""
        {"enabled":true,"shortcutEnabled":true,"alwaysOnTop":true,"followsActiveSpace":true,
         "clickThrough":false,"opacity":0.72,"hiddenProviders":["claude"],"currency":"CNY","language":"zh-Hans"}
        """#.utf8)
        let frame = "{{100, 200}, {280, 180}}"
        let payment = TokenLedgerPayment(
            id: UUID(), provider: .gemini, providerName: "Gemini", amount: 80, currency: .eur, estimated: true)
        let payments = try JSONEncoder().encode([payment])
        old.set(options, forKey: "tokenLedger.options.v1")
        old.set(payments, forKey: "tokenLedger.payments.v1")
        old.set(frame, forKey: "tokenLedger.frame")

        let migrated = TokenLedgerPreferences(defaults: current, legacy: old)
        #expect(migrated.options.currency == .cny)
        #expect(migrated.options.hiddenProviders == [.claude])
        #expect(migrated.options.disabledProviders.isEmpty)
        #expect(migrated.options.opacity == 0.72)
        #expect(migrated.payments == [payment])
        #expect(current.string(forKey: "tokenLedger.frame") == frame)
        migrated.remove(payment.id)

        #expect(TokenLedgerPreferences(defaults: current, legacy: old).payments.isEmpty)
        #expect(old.data(forKey: "tokenLedger.payments.v1") == payments)
        #expect(old.data(forKey: "tokenLedger.options.v1") == options)
    }

    @Test
    func `currency needs verified rates only for conversion`() {
        let amounts = [TokenLedgerAmount(currency: "AUD", value: 30), TokenLedgerAmount(currency: "USD", value: 10)]
        #expect(TokenLedgerExchangeRates().sum(amounts, currency: "AUD") == nil)
        #expect(TokenLedgerExchangeRates(rates: ["AUD": 1.5]).sum(amounts, currency: "AUD") == 45)
        #expect(TokenLedgerExchangeRates().sum(Array(amounts.prefix(1)), currency: "AUD") == 30)
    }

    @Test
    func `panel stays in bounds on a secondary display with a negative origin`() {
        #expect(TokenLedgerPanelController.constrain(-300, to: -188...1290, snap: false) == -188)
        #expect(TokenLedgerPanelController.constrain(-182, to: -188...1290, snap: true) == -180)
        #expect(TokenLedgerPanelController.constrain(1281, to: -188...1290, snap: true) == 1282)
    }
}
