import AppKit

extension StatusItemController {
    func addTokenLedgerMenu(to menu: NSMenu) {
        let preferences = self.settings.tokenLedger
        guard preferences.options.enabled else { return }

        let submenu = NSMenu(title: preferences.text("ledger.title"))
        let actions: [(String, Selector)] = [
            ("ledger.toggle", #selector(self.toggleTokenLedger)),
            ("ledger.disableClickThrough", #selector(self.recoverTokenLedgerInteraction)),
            ("ledger.settings", #selector(self.openTokenLedgerSettings)),
        ]
        for (key, action) in actions {
            let item = NSMenuItem(title: preferences.text(key), action: action, keyEquivalent: "")
            item.target = self
            submenu.addItem(item)
        }
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        menu.addItem(item)
    }

    @objc private func toggleTokenLedger() {
        self.settings.tokenLedger.toggleVisibility()
    }

    @objc private func recoverTokenLedgerInteraction() {
        self.settings.tokenLedger.options.clickThrough = false
    }

    @objc private func openTokenLedgerSettings() {
        self.settingsOpenHandler?(.tokenLedger)
    }
}
