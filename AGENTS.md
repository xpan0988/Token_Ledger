# Token Ledger repository guidelines

- Keep the V3 panel compact and preserve recorded usage across collection, visibility, account, and log changes.
- Build with SwiftPM and test with `./Scripts/test.sh`. Run `./Scripts/lint.sh` after installing SwiftFormat and SwiftLint.
- Package locally with `./Scripts/package.sh debug` or `./Scripts/package.sh release`.
- Prefer synthetic transcripts and provider responses. Never log credentials, account identifiers, or provider transcripts.
  Use real provider probes only when requested, and keep their results local unless publication is authorized.
- Keep macOS GUI, persistence, provider collectors, and build tooling independently testable.
