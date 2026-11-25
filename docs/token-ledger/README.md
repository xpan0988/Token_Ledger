---
summary: "Build and validation notes for the Token Ledger macOS floating panel."
read_when:
  - Building or validating Token Ledger
---

# Token Ledger for CodexBar

Token Ledger is an opt-in native floating panel in the existing CodexBar app. AUD and English are the defaults. The panel stays at 280 × 180 pt for the three-provider layout. It widens within the visible screen for additional providers, with horizontal scrolling when needed.

## Install from source

Token Ledger builds on CodexBar commit `a26ca57b518667a659d69524c473af2735069612`. Use the Xcode 27
toolchain specified by that revision and `xcodegen` for CodexBar’s existing widget packaging step.
[CodexBar development guide](../DEVELOPMENT.md)

```bash
git clone https://github.com/xpan0988/Token_Ledger.git
cd Token_Ledger

# On a Mac with multiple Xcode installations, set DEVELOPER_DIR to the Xcode 27 developer directory.
brew install xcodegen
./Scripts/package_app.sh debug
open CodexBar.app
```

Open **CodexBar Settings → Token Ledger** and enable the panel. Enable **Collect CodexBar Token History** if CodexBar’s existing collection is off. Enter payments as needed in **Subscription Records**. The default show/hide shortcut is **Control–Option–Command–L**. The menu bar’s **Token Ledger → Disable Click-through** action restores mouse interaction.

## Architecture

| Area | Implementation and upstream reuse |
| --- | --- |
| Panel | A borderless AppKit `NSPanel` hosts SwiftUI and cannot become key or main. It uses the floating window level and public AppKit Space behaviors. Screen placement uses `NSScreen.visibleFrame`, with edge snapping and position restoration. |
| Quotas and refresh | Reads the existing `UsageStore` provider roster and menu-bar snapshots, including existing account selection, provider adapters, authentication, and scheduling. Only reported windows with five-hour or weekly durations fill the rings. Unsupported windows use dashed tracks. |
| Recorded history | Subscribes to the shared all-time Spend Dashboard publication and uses the published token totals and upstream pricing provenance. Keeps stable source scopes across refreshes. Local checkpoints use reconciled session identities where available, and day-level observations otherwise. The checkpoint sits beside the CodexBar configuration and uses its owner-only atomic writer. |
| Money | API-equivalent figures use eligible CodexBar list-price estimates. Payment records retain their original decimal amounts and currencies, including a confirmed or estimated status. Display totals use the existing ExchangeRate-API cache, with the last successful rates retained offline and missing rates reported separately. |
| Settings and language | Adds a CodexBar settings pane, reuses launch at login and KeyboardShortcuts, and stores Ledger preferences and payment records locally. The English and Simplified Chinese tables use the app’s native Bundle localization infrastructure. |

[AppKit window collection behaviors](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct) · [ExchangeRate-API open endpoint](https://www.exchangerate-api.com/docs/free)

## Validation

Native checks ran on Apple M5 hardware with macOS 26.5.2, a built-in Retina display, and an HP E24u G5. The [English](token-ledger-en.png) and [Simplified Chinese](token-ledger-zh-Hans.png) images are WindowServer captures of the running panel at 2× scale, with isolated usage and payment fixtures.

| Check | Result |
| --- | --- |
| Window size and localization | Both variants fit in the same 280 × 180 pt running window. The labels switched immediately within one process. |
| Non-activation | After a click on the panel, the other app kept its key window and active text field, which received the test keystrokes. |
| Full-screen Space | Verified the panel was onscreen alongside a separate full-screen AppKit app on the built-in display. The global shortcut hid and restored the panel in that Space without changing the foreground app. A separate run launched the witness on the HP and verified the panel onscreen in that display’s full-screen Space. |
| Multi-display placement | Dragged from the Retina display to the HP, observed the edge snap, and verified the same frame after relaunch with a new window ID. Display disconnect and reconnect were outside the hardware checks. |
| Settings and click-through | The gear opened the CodexBar settings pane. A gear click was ignored in click-through mode, and the native menu-bar recovery action restored interaction. |
| Currency | Switching AUD to USD in the running panel rendered converted amounts. Focused tests covered cross-currency totals, unavailable rates, and preservation of original payment amounts. |
| Focused tests | 41 passed across four suites, including nine Token Ledger tests and upstream spend, settings search, and localization regressions. |
| Repository checks | Portable and JavaScript checks and SwiftFormat passed through `make check`. Its SwiftLint invocation could not locate SourceKit under Command Line Tools. Running the pinned SwiftLint directly with the Command Line Tools framework path reported zero violations across 3,268 files. |
| Build and packaging | The app target linked in the local SwiftPM debug build and passed the upstream resource launch smoke check. The installed Command Line Tools lack the SwiftUI macros used by stock upstream and the full XCTest toolchain. The local build used temporary macro expansions and focused Swift Testing ran through a temporary manifest. Both were restored before publishing the source. Standard Xcode packaging and the full suite remain unverified. |

## Data limits

- Recorded lifetime totals depend on accessible upstream data and the active source scopes. Where a feed only provides daily totals, the ledger retains known observations but cannot reconcile every same-day log rotation. Ambiguous coverage is marked as partial.
- List-price coverage varies by source and model. Metered provider bills and mixed-provenance snapshots without a separable list-price total are excluded from the API estimate.
- Cross-currency values use a shared reference rate, with its fetch date available on hover. A cross-currency total is unavailable until the necessary rates exist.
- Provider adapters were exercised through existing publications and isolated fixtures. Live provider authentication and macOS login-item registration were outside the native checks.

## Changed files

| Scope | Files |
| --- | --- |
| App and status menu | `CodexbarApp.swift`, `KeyboardShortcuts+Names.swift`, `StatusItemController+Menu.swift`, `StatusItemController+MenuLocalization.swift` |
| Settings and localization | `PreferencesSelection.swift`, `PreferencesSidebar.swift`, `PreferencesView.swift`, `SettingsStore.swift`, `SettingsStore+MenuObservation.swift`, `SettingsWindowController.swift`, `Localization.swift`, English and Simplified Chinese `TokenLedger.strings` |
| Shared data | `SpendDashboardController.swift`, `CostUsageModels.swift`, `CurrencyExchange.swift` |
| Token Ledger | `TokenLedgerData.swift`, `TokenLedgerFormatting.swift`, `TokenLedgerHistory.swift`, `TokenLedgerPanelController.swift`, `TokenLedgerPanelView.swift`, `TokenLedgerPreferences.swift`, `TokenLedgerQuotaView.swift`, `TokenLedgerSettingsView.swift`, `TokenLedgerStatusMenu.swift` |
| Tests and documentation | `TokenLedgerTests.swift`, `README.md` |
