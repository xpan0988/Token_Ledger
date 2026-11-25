# Token Ledger

Token Ledger is a small, native macOS floating panel for AI usage limits and recorded spending.

| English | 简体中文 |
| --- | --- |
| ![Token Ledger in English](docs/token-ledger-en.png) | ![Token Ledger in Simplified Chinese](docs/token-ledger-zh-Hans.png) |

The screenshots show the running app with sample usage and payments.

## What it shows

- Five-hour and weekly quota rings.
- Recorded lifetime tokens and their provider distribution.
- Estimated API-equivalent cost and cumulative subscription payments.
- AUD by default, with USD, CNY, EUR, and GBP available in Settings.

The Chinese interface uses 万, 亿 and 万亿 for token counts. Monetary amounts use K, M, B and T in both languages.

The panel supports English and Simplified Chinese, multiple displays, and full-screen Spaces where macOS permits.
Use **Control–Option–Command–L** to show or hide it. The menu bar item opens Settings and restores mouse input
when click-through is enabled.

## Supported providers

| Provider | Quotas | Recorded usage |
| --- | --- | --- |
| Codex | Signed-in Codex CLI | Local active and archived Codex rollouts |
| Claude | Signed-in Claude Code CLI | Local first-party Claude Code transcripts |

Sign in to each provider through its CLI. Settings controls panel visibility and collection independently.

## Install and build

Requires macOS 14 or later and Swift 6 with the macOS SDK. Install the app bundle by moving **Token Ledger.app**
to Applications and opening it. The build below creates an ad-hoc signed local bundle.

```sh
./Scripts/package.sh release
open "dist/Token Ledger.app"
./Scripts/test.sh
```

Build requirements and packaging are independent of provider setup. Enable **Launch at Login** in Settings if desired.

## Known limitations

- Local history covers readable logs on this Mac. A new sign-in changes the displayed quotas, while previously
  recorded usage remains part of the machine’s lifetime total.
- Hidden providers remain in aggregate totals. Disabling collection keeps recorded usage and stops new collection.
  Deleting recorded usage clears the local ledger and sets a cutoff so replayed older logs stay excluded.
- Some legacy or forked transcripts and migrated same-day totals cannot be joined exactly. Partial totals are shown
  as lower bounds. Unrecognized prices, uncertain service tiers and unsupported routes may leave cost coverage partial.
- API-equivalent valuation uses the model-prices timeline at the request timestamp. Bundled rates and then
  current models.dev prices cover gaps. The app checks the catalogs daily while running and limits
  additional checks for unknown models to one per hour. The last valid public catalog remains available offline.
- The ledger retains request inputs and recalculates costs when the catalog changes. An older checkpoint is
  replayed once to recover those inputs. Tokens with unavailable originals remain recorded and their cost
  remains unpriced. The API Equivalent tooltip identifies current-price estimates when they contribute.
- Reading unseen compressed Codex archives requires a local `zstd` executable. Quota access can be unavailable when
  the vendor CLI cannot show its usage panel or returns an error. Cached exchange rates remain available offline.
- **Total Paid** is based on manual records in their original currencies. It can include marked estimates.

## License

MIT. [License and copyright](LICENSE) · [Source attribution](THIRD_PARTY_NOTICES.md)
