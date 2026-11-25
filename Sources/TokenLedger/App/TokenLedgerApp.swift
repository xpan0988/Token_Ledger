import AppKit
import Observation
import SwiftUI

@main
enum TokenLedgerEntry {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = LedgerApplication()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class LedgerApplication: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let preferences: TokenLedgerPreferences
    private let data: TokenLedgerData
    private let login = LoginPreference()
    private var panel: TokenLedgerPanelController?
    private var settingsWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var shortcut: GlobalShortcut?

    override init() {
        let legacy = LegacyMigration.detect()
        self.preferences = TokenLedgerPreferences(defaults: .standard, legacy: legacy?.defaults)
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.data = TokenLedgerData(
            preferences: self.preferences,
            directory: base.appendingPathComponent("Token Ledger"),
            legacy: legacy)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = TokenLedgerPanelController(preferences: self.preferences, data: self.data) { [weak self] in
            self?.showSettings()
        }
        self.panel = controller
        self.shortcut = GlobalShortcut { [weak self] in self?.togglePanel() }
        self.installMenu()
        controller.start()
        self.observeSettings()
        self.data.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        self.shortcut?.setEnabled(false)
    }

    private func observeSettings() {
        let enabled = withObservationTracking {
            self.preferences.options.shortcutEnabled
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeSettings() }
        }
        self.shortcut?.setEnabled(enabled)
        self.settingsWindow?.title = self.preferences.text("ledger.settings")
        self.statusItem?.button?.toolTip = self.preferences.text("ledger.title")
        if let menu = self.statusItem?.menu { self.menuNeedsUpdate(menu) }
    }

    private func installMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: "Token Ledger")
        item.button?.image?.isTemplate = true
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        self.statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let visible = self.preferences.options.enabled && !self.preferences.hidden
        self.add(visible ? "ledger.hide" : "ledger.show", action: #selector(self.togglePanel), to: menu)
        self.add("ledger.settings", action: #selector(self.showSettings), to: menu, key: ",")
        if self.preferences.options.clickThrough {
            self.add("ledger.disableClickThrough", action: #selector(self.recoverClickThrough), to: menu)
        }
        menu.addItem(.separator())
        self.add("ledger.quit", action: #selector(self.quit), to: menu, key: "q")
    }

    private func add(_ key: String, action: Selector, to menu: NSMenu, key shortcut: String = "") {
        let item = NSMenuItem(title: self.preferences.text(key), action: action, keyEquivalent: shortcut)
        item.target = self
        menu.addItem(item)
    }

    @objc private func togglePanel() { self.preferences.toggleVisibility() }

    @objc private func recoverClickThrough() { self.preferences.options.clickThrough = false }

    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func showSettings() {
        self.login.refresh()
        let window: NSWindow
        if let existing = self.settingsWindow {
            window = existing
        } else {
            let frame = NSRect(x: 0, y: 0, width: 550, height: 615)
            window = NSWindow(
                contentRect: frame,
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false)
            let root = TokenLedgerSettingsView(preferences: self.preferences, login: self.login, data: self.data)
                .frame(minWidth: 450, minHeight: 440)
            window.contentViewController = NSHostingController(rootView: root)
            window.isReleasedWhenClosed = false
            window.center()
            self.settingsWindow = window
        }
        window.title = self.preferences.text("ledger.settings")
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
