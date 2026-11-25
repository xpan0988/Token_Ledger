---
summary: "Standalone extraction baseline, runtime closure, and verification."
read_when:
  - Evaluating the standalone extraction
---

# Extraction audit

Baseline `c5fe32687f6d95a35bd972db6e0ab7aac5670922` contained 4,557 tracked files and 71,020,994 bytes of tracked Git blobs. The source count was 3,601 files and 1,001,505 physical lines. Source counts use Swift, C, C++, QML, JavaScript, TypeScript, Python, shell and Rust outside `Resources` and `Fixtures`. Git object storage and build products are excluded. The previous native QA used the same panel design. Its 41 focused tests and resource launch smoke test passed using Command Line Tools compatibility adjustments outside the committed source.

| Needed behavior | Retained closure |
| --- | --- |
| Ambient panel | Existing SwiftUI panels, quota projection, formatting, proportional bar, AppKit window snapping and collection behaviors |
| Lifecycle and recovery | AppKit status item, a settings window, ServiceManagement login registration, Carbon hotkey |
| Codex | Installed Codex CLI, stdio app-server authentication and quota RPC, local active and archived JSONL rollouts |
| Claude | Installed Claude Code CLI and its own authentication, quota display through its local `/usage` command, local first-party JSONL transcripts |
| Token accounting | Dated canonical events, provider-specific counters and deduplication, legacy checkpoint lower bounds |
| Pricing and currency | Extracted bundled list-price tables and cache formulas, last successful USD reference rates, preserved payment currencies |
| Runtime resources | Two native localization tables, the app icon, SwiftPM bundle |
| Migration | Read-only access to the legacy preferences suite and optional JSON checkpoint at its default locations |
| Build | SwiftPM, system Apple frameworks, app packaging script and minimal macOS CI |

Gemini's retained upstream adapter reports daily quotas. It does not establish a five-hour or weekly window and its upstream integration does not establish a suitable local token-history path. Other provider adapters, dynamic JavaScript registration, upstream authentication caches, dashboards, CLI distribution, WidgetKit, Linux integrations, release feeds and upstream workflows are outside the standalone closure.

The baseline Codex parser infers accounting for inherited fork counters, truncated rollouts, typed request mirrors and vendor-specific billing evidence. The standalone importer accepts provable records and signals partial coverage for ambiguous traces. It keeps cache-read and output accounting semantics and preserves the bundled list-price formulas. Account sign-in selects the active quotas. Recorded totals remain machine-wide.
