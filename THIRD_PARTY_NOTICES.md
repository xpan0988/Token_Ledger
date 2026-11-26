# Source attribution

Token Ledger retains code from CodexBar, copyright (c) 2026 Peter Steinberger, under the MIT License in
[LICENSE](LICENSE).

Derived components include the original Token Ledger panel and settings, quota and accounting projections,
Claude terminal rendering, the atomic file writer, and some fallback pricing data.
The standalone app uses system SQLite and Apple frameworks. It bundles no vendor CLI or third-party Swift package.

The app refreshes public prices from [model-prices](https://github.com/wakamex/model-prices) and uses
[models.dev](https://models.dev/) as a fallback.
