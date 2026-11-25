import AppKit
import CodexBarCore
import KeyboardShortcuts
import Observation
import SwiftUI

private final class TokenLedgerPanel: NSPanel {
    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }
}

@MainActor
final class TokenLedgerPanelController: NSObject, NSWindowDelegate {
    private static let frameKey = "tokenLedger.frame"
    private static let snapDistance: CGFloat = 18
    private static let edgeInset: CGFloat = 8
    private static let height: CGFloat = 180

    private let store: UsageStore
    private let settings: SettingsStore
    private let data: TokenLedgerData
    private let openSettings: () -> Void
    private var panel: NSPanel?
    private var settleMove: Task<Void, Never>?
    private var changingFrame = false
    private var historyRevision: UInt64?
    private var historyProviders: Set<ProviderInstanceID> = []
    private var trackedTop: Bool?
    private var trackedSpace: Bool?
    private var shortcutEnabled: Bool?

    init(store: UsageStore, settings: SettingsStore, openSettings: @escaping () -> Void) {
        self.store = store
        self.settings = settings
        self.openSettings = openSettings
        let historyFile = settings.configStore.fileURL.deletingLastPathComponent()
            .appendingPathComponent("token-ledger-history.json")
        self.data = TokenLedgerData(file: historyFile)
    }

    func start() {
        KeyboardShortcuts.onKeyUp(for: .toggleTokenLedger) { [weak self] in
            MainActor.assumeIsolated {
                self?.settings.tokenLedger.toggleVisibility()
            }
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.displayConfigurationChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil)
        self.observe()
    }

    private func observe() {
        let preferences = self.settings.tokenLedger
        let (options, hidden, providers, publication) = withObservationTracking {
            _ = preferences.payments
            let options = preferences.options
            guard options.enabled else {
                return (options, true, [ProviderInstanceID](), SpendDashboardPublication.empty)
            }
            return (
                options,
                preferences.hidden,
                self.store.enabledProvidersForDisplay(),
                self.store.spendDashboardPublication)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        self.applyShortcut(options.enabled && options.shortcutEnabled)
        guard options.enabled else {
            self.panel?.orderOut(nil)
            self.historyRevision = nil
            return
        }

        let enabled = Set(providers)
        if self.historyRevision != publication.revision || self.historyProviders != enabled {
            self.historyRevision = publication.revision
            self.historyProviders = enabled
            self.data.update(publication: publication, enabled: enabled, preferences: preferences)
        }
        self.data.refreshRatesIfNeeded(preferences: preferences)

        if hidden {
            self.panel?.orderOut(nil)
            return
        }
        let panel = self.panel ?? self.makePanel()
        self.panel = panel
        let behaviorChanged = self.trackedTop != options.alwaysOnTop || self.trackedSpace != options.followsActiveSpace
        if behaviorChanged {
            panel.level = options.alwaysOnTop ? .floating : .normal
            panel.collectionBehavior = options.followsActiveSpace
                ? [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications, .ignoresCycle]
                : [.fullScreenNone, .ignoresCycle]
            self.trackedTop = options.alwaysOnTop
            self.trackedSpace = options.followsActiveSpace
        }
        panel.title = preferences.text("ledger.title")
        panel.alphaValue = max(0.35, min(1, options.opacity))
        panel.ignoresMouseEvents = options.clickThrough

        self.reposition(visibleProviders: enabled.subtracting(options.hiddenProviders).count, snap: false)
        if !panel.isVisible || behaviorChanged {
            panel.orderFrontRegardless()
        }
    }

    private func applyShortcut(_ enabled: Bool) {
        guard self.shortcutEnabled != enabled else { return }
        self.shortcutEnabled = enabled
        if enabled {
            KeyboardShortcuts.enable(.toggleTokenLedger)
        } else {
            KeyboardShortcuts.disable(.toggleTokenLedger)
        }
    }

    private func makePanel() -> NSPanel {
        let panel = TokenLedgerPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: Self.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.title = self.settings.tokenLedger.text("ledger.title")
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
        panel.isMovableByWindowBackground = true
        panel.isExcludedFromWindowsMenu = true
        let hosting = NSHostingView(rootView: TokenLedgerPanelView(
            preferences: self.settings.tokenLedger,
            data: self.data,
            store: self.store,
            openSettings: self.openSettings))
        hosting.sizingOptions = []
        panel.contentView = hosting
        if let frame = self.settings.userDefaults.string(forKey: Self.frameKey) {
            panel.setFrame(NSRectFromString(frame), display: false)
        } else if let screen = NSScreen.main {
            panel.setFrameOrigin(NSPoint(
                x: screen.visibleFrame.maxX - panel.frame.width - Self.edgeInset,
                y: screen.visibleFrame.maxY - panel.frame.height - Self.edgeInset))
        }
        panel.delegate = self
        return panel
    }

    func windowDidMove(_ notification: Notification) {
        guard !self.changingFrame, self.panel?.isVisible == true else { return }
        self.settleMove?.cancel()
        self.settleMove = Task { @MainActor [weak self] in
            repeat {
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
            } while NSEvent.pressedMouseButtons & 1 != 0
            guard let self else {
                return
            }
            self.constrainPosition(snap: true)
        }
    }

    @objc private func displayConfigurationChanged() {
        self.constrainPosition(snap: false)
    }

    private func constrainPosition(snap: Bool) {
        let providers = Set(self.store.enabledProvidersForDisplay())
            .subtracting(self.settings.tokenLedger.options.hiddenProviders)
        self.reposition(visibleProviders: providers.count, snap: snap)
    }

    private func reposition(visibleProviders: Int, snap: Bool) {
        guard let panel = self.panel, let screen = Self.closestScreen(to: panel.frame) else { return }
        let bounds = screen.visibleFrame
        let desiredWidth = min(430, max(280, 34 + CGFloat(visibleProviders) * 57))
        var frame = panel.frame
        frame.size = NSSize(width: min(desiredWidth, bounds.width), height: min(Self.height, bounds.height))
        let minX = bounds.minX
        let maxX = bounds.maxX - frame.width
        let minY = bounds.minY
        let maxY = bounds.maxY - frame.height
        frame.origin.x = Self.constrain(frame.minX, to: minX...maxX, snap: snap)
        frame.origin.y = Self.constrain(frame.minY, to: minY...maxY, snap: snap)

        if panel.frame != frame {
            self.changingFrame = true
            panel.setFrame(frame, display: true)
            self.changingFrame = false
        }
        if snap || self.settings.userDefaults.string(forKey: Self.frameKey) == nil {
            self.settings.userDefaults.set(NSStringFromRect(panel.frame), forKey: Self.frameKey)
        }
    }

    static func constrain(_ coordinate: CGFloat, to bounds: ClosedRange<CGFloat>, snap: Bool) -> CGFloat {
        let clamped = min(bounds.upperBound, max(bounds.lowerBound, coordinate))
        guard snap else { return clamped }
        let inset = min(self.edgeInset, (bounds.upperBound - bounds.lowerBound) / 2)
        if clamped - bounds.lowerBound <= self.snapDistance { return bounds.lowerBound + inset }
        if bounds.upperBound - clamped <= self.snapDistance { return bounds.upperBound - inset }
        return clamped
    }

    private static func closestScreen(to frame: NSRect) -> NSScreen? {
        let screens = NSScreen.screens
        return screens.max { left, right in
            func score(_ screen: NSScreen) -> (CGFloat, CGFloat) {
                let intersection = screen.frame.intersection(frame)
                let dx = screen.frame.midX - frame.midX
                let dy = screen.frame.midY - frame.midY
                return (intersection.width * intersection.height, -(dx * dx + dy * dy))
            }
            return score(left) < score(right)
        }
    }
}
