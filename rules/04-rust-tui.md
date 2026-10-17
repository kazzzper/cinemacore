# 04 — Rust TUI

Scope: `tools/tui/`. Source: Rust API Guidelines, Clippy.

- `cargo fmt` + `cargo clippy -- -D warnings`. Edition 2024.
- `Result` everywhere; no `unwrap`/`expect` outside tests and proven-infallible init.
- Errors: `thiserror` for library types; add context at boundaries.
- Ownership first: borrow before cloning. No `Arc<Mutex<_>>` unless shared mutable state is real.
- Async: `tokio`; cancellation-aware; no blocking calls on the runtime thread.
- Naming mirrors std: `iter`, `into_*`, `as_*`, `to_*` with correct cost semantics.
- The TUI is a **client**: keep provider/cache/download logic in `core/` (Go) and consume it; do not fork the signing code.
