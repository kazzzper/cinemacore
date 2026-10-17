# rules/

Guidelines every agent and human follows in this repo. `AGENTS.md` links here; if a change violates a rule, the change is rejected unless the rule is first amended (with a reason in the PR).

## Index

| File | Scope |
|---|---|
| [`00-senior-doctrine.md`](00-senior-doctrine.md) | **King rule** — minimal diffs, no loss, code over prose |
| [`01-go.md`](01-go.md) | Go (`core/`, `server/`, `cmd/`) |
| [`02-kotlin-android.md`](02-kotlin-android.md) | Kotlin / Jetpack Compose |
| [`03-swift-ios.md`](03-swift-ios.md) | Swift / SwiftUI / SwiftData |
| [`04-rust-tui.md`](04-rust-tui.md) | Rust TUI |
| [`05-api-contract.md`](05-api-contract.md) | Contract-first API |
| [`06-testing.md`](06-testing.md) | Tests, golden vectors |
| [`07-git-commits.md`](07-git-commits.md) | Commits & history |
| [`sources.md`](sources.md) | Provenance for every rule above |

## Precedence

1. `00-senior-doctrine.md` — always applies, overrides style preferences.
2. Language rules — apply per directory.
3. Contract rule — applies to anything touching `contracts/` or the wire API.

Rules are **sourced, not invented**: see `sources.md`. When official upstream guidance disagrees with a rule here, upstream wins for that language — open a PR to fix the rule.
