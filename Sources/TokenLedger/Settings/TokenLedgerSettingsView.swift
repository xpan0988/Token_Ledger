import LedgerCore
import SwiftUI

struct TokenLedgerSettingsView: View {
    @Bindable var preferences: TokenLedgerPreferences
    @Bindable var login: LoginPreference
    let data: TokenLedgerData
    @State private var editor: EditPayment?

    @State private var deletingHistory = false
    @State private var deletionFailed = false

    private var providers: [ProviderInstanceID] {
        ProviderInstanceID.supported
    }

    var body: some View {
        @Bindable var preferences = self.preferences
        Form {
            Section(self.preferences.text("ledger.general")) {
                Toggle(self.preferences.text("ledger.enable"), isOn: $preferences.options.enabled)
                Toggle(self.preferences.text("ledger.launchAtLogin"), isOn: Binding {
                    self.login.enabled
                } set: { self.login.set($0) })
                if self.login.failed {
                    Text(self.preferences.text("ledger.loginFailure")).font(.caption).foregroundStyle(.secondary)
                } else if self.login.requiresApproval {
                    Text(self.preferences.text("ledger.loginApproval")).font(.caption).foregroundStyle(.secondary)
                }
                Toggle(self.preferences.text("ledger.shortcutEnabled"), isOn: $preferences.options.shortcutEnabled)
                if self.preferences.options.shortcutEnabled {
                    LabeledContent(self.preferences.text("ledger.shortcut"), value: "⌃⌥⌘L")
                }
            }
            Section(self.preferences.text("ledger.collectHistory")) {
                ForEach(self.providers, id: \.self) { id in
                    Toggle(id.displayName, isOn: Binding {
                        !self.preferences.options.disabledProviders.contains(id)
                    } set: { collecting in
                        if collecting {
                            self.preferences.options.disabledProviders.remove(id)
                        } else {
                            self.preferences.options.disabledProviders.insert(id)
                        }
                    })
                }
                Text(self.preferences.text("ledger.historyHelp")).font(.caption).foregroundStyle(.secondary)
                Button(self.preferences.text("ledger.deleteHistory"), role: .destructive) {
                    self.deletingHistory = true
                }
                if self.deletionFailed {
                    Text(self.preferences.text("ledger.persistenceFailed")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section(self.preferences.text("ledger.appearance")) {
                LabeledContent(self.preferences.text("ledger.opacity")) {
                    Slider(value: $preferences.options.opacity, in: 0.35...1)
                        .frame(width: 145)
                        .accessibilityLabel(self.preferences.text("ledger.opacity"))
                    Text(preferences.options.opacity.formatted(.percent.precision(.fractionLength(0))))
                        .monospacedDigit()
                        .frame(width: 45, alignment: .trailing)
                }
                Toggle(self.preferences.text("ledger.alwaysOnTop"), isOn: $preferences.options.alwaysOnTop)
                Toggle(self.preferences.text("ledger.followSpace"), isOn: $preferences.options.followsActiveSpace)
                Toggle(self.preferences.text("ledger.clickThrough"), isOn: $preferences.options.clickThrough)
                Text(self.preferences.text("ledger.recoveryHelp"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !self.providers.isEmpty {
                    DisclosureGroup(self.preferences.text("ledger.visibleProviders")) {
                        ForEach(self.providers, id: \.self) { id in
                            Toggle(id.displayName, isOn: Binding {
                                !self.preferences.options.hiddenProviders.contains(id)
                            } set: { shown in
                                if shown {
                                    self.preferences.options.hiddenProviders.remove(id)
                                } else {
                                    self.preferences.options.hiddenProviders.insert(id)
                                }
                            })
                        }
                    }
                }
            }
            Section(self.preferences.text("ledger.regional")) {
                Picker(self.preferences.text("ledger.currency"), selection: $preferences.options.currency) {
                    ForEach(TokenLedgerCurrency.allCases, id: \.self) { currency in
                        Text(currency.label).tag(currency)
                    }
                }
                Picker(self.preferences.text("ledger.language"), selection: $preferences.options.language) {
                    ForEach(TokenLedgerLanguage.allCases, id: \.self) { language in
                        Text(language.name).tag(language)
                    }
                }
                Link(
                    self.preferences.text("ledger.rateAttribution"),
                    destination: URL(string: "https://www.exchangerate-api.com")!)
                    .font(.caption)
            }
            self.paymentSection
        }
        .formStyle(.grouped)
        .confirmationDialog(
            self.preferences.text("ledger.deleteHistory"),
            isPresented: self.$deletingHistory)
        {
            Button(self.preferences.text("ledger.delete"), role: .destructive) {
                Task { self.deletionFailed = await !(self.data.deleteHistory()) }
            }
            Button(self.preferences.text("ledger.cancel"), role: .cancel) {}
        } message: {
            Text(self.preferences.text("ledger.deleteHistoryHelp"))
        }
        .environment(\.locale, preferences.options.language.locale)
            .sheet(item: self.$editor) { draft in
                TokenLedgerPaymentEditor(
                    draft: draft,
                    providerNames: self.paymentProviders,
                    preferences: self.preferences)
            }
    }

    private var paymentProviders: [ProviderInstanceID: String] {
        var result = Dictionary(
            self.providers.map { ($0, $0.displayName) },
            uniquingKeysWith: { first, _ in first })
        for payment in self.preferences.payments where result[payment.provider] == nil {
            result[payment.provider] = payment.providerName
        }
        return result
    }

    private var paymentSection: some View {
        Section {
            if self.preferences.payments.isEmpty {
                Text(self.preferences.text("ledger.noPayments"))
                    .foregroundStyle(.secondary)
            }
            ForEach(self.preferences.payments) { payment in
                LabeledContent {
                    Button(self.preferences.text("ledger.edit")) {
                        self.editor = EditPayment(payment: payment)
                    }
                    .accessibilityLabel(self.preferences.text("ledger.editPaymentFor", payment.providerName))
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(self.paymentProviders[payment.provider] ?? payment.providerName)
                        let amount = TokenLedgerFormatting.full(
                            payment.amount, locale: self.preferences.options.language.locale)
                        let status = self.preferences.text(payment.estimated ? "ledger.estimated" : "ledger.confirmed")
                        Text("\(payment.currency.rawValue) \(amount) · \(status)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
            Button(self.preferences.text("ledger.addPayment")) { self.editor = EditPayment(payment: nil) }
                .disabled(self.paymentProviders.isEmpty)
        } header: {
            Text(self.preferences.text("ledger.payments"))
        } footer: {
            Text(self.preferences.text("ledger.paymentHelp"))
        }
    }
}

private struct EditPayment: Identifiable {
    let id = UUID()
    let payment: TokenLedgerPayment?
}

private struct TokenLedgerPaymentEditor: View {
    let draft: EditPayment
    let providerNames: [ProviderInstanceID: String]
    let preferences: TokenLedgerPreferences
    @Environment(\.dismiss) private var dismiss
    @State private var provider: ProviderInstanceID?
    @State private var amount: String
    @State private var currency: TokenLedgerCurrency
    @State private var estimated: Bool
    @State private var confirmingDelete = false

    init(
        draft: EditPayment,
        providerNames: [ProviderInstanceID: String],
        preferences: TokenLedgerPreferences)
    {
        self.draft = draft
        self.providerNames = providerNames
        self.preferences = preferences
        let payment = draft.payment
        _provider = State(initialValue: payment?.provider ?? Self.sortedProviders(providerNames).first)
        _amount = State(initialValue: payment.map { NSDecimalNumber(decimal: $0.amount).stringValue } ?? "")
        _currency = State(initialValue: payment?.currency ?? preferences.options.currency)
        _estimated = State(initialValue: payment?.estimated ?? false)
    }

    private var parsedAmount: Decimal? {
        TokenLedgerFormatting.parsePayment(self.amount, locale: self.preferences.options.language.locale)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text(self.preferences.text(self.draft.payment == nil ? "ledger.addPayment" : "ledger.editPayment"))
                .font(.headline)
            Form {
                Picker(self.preferences.text("ledger.provider"), selection: self.$provider) {
                    ForEach(Self.sortedProviders(self.providerNames), id: \.self) { id in
                        Text(self.providerNames[id] ?? id.rawValue).tag(Optional(id))
                    }
                }
                TextField(self.preferences.text("ledger.amount"), text: self.$amount)
                Picker(self.preferences.text("ledger.paymentCurrency"), selection: self.$currency) {
                    ForEach(TokenLedgerCurrency.allCases, id: \.self) { currency in
                        Text(currency.label).tag(currency)
                    }
                }
                Toggle(self.preferences.text("ledger.estimated"), isOn: self.$estimated)
            }
            if !self.amount.isEmpty, self.parsedAmount == nil {
                Text(self.preferences.text("ledger.invalidAmount"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                if self.draft.payment != nil {
                    Button(self.preferences.text("ledger.delete"), role: .destructive) {
                        self.confirmingDelete = true
                    }
                }
                Spacer()
                Button(self.preferences.text("ledger.cancel")) { self.dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(self.preferences.text("ledger.save")) { self.save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(self.provider == nil || self.parsedAmount == nil)
            }
        }
        .padding(22)
        .frame(width: 375)
        .confirmationDialog(self.preferences.text("ledger.deletePayment"), isPresented: self.$confirmingDelete) {
            Button(self.preferences.text("ledger.delete"), role: .destructive) {
                if let payment = self.draft.payment { self.preferences.remove(payment.id) }
                self.dismiss()
            }
            Button(self.preferences.text("ledger.cancel"), role: .cancel) {}
        }
    }

    private func save() {
        guard let provider, let amount = self.parsedAmount, let name = self.providerNames[provider] else { return }
        self.preferences.save(TokenLedgerPayment(
            id: self.draft.payment?.id ?? UUID(),
            provider: provider,
            providerName: name,
            amount: amount,
            currency: self.currency,
            estimated: self.estimated))
        self.dismiss()
    }

    private static func sortedProviders(_ names: [ProviderInstanceID: String]) -> [ProviderInstanceID] {
        names.sorted { $0.value.localizedStandardCompare($1.value) == .orderedAscending }.map(\.key)
    }
}
