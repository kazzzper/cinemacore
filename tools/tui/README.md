# tools/tui

The Rust terminal client (from `moviebox-tui`) is retained as a first-class surface.

**Direction:** consume the Cinemacore API (`server/`) instead of forking provider/signing logic. Signing, cache, download, and provider behavior belong in `core/` (Go); the TUI is a view.

Until repointed (task `T-008`), the upstream crate stays here unmodified as reference for the `core/` ports: provider abstraction, LRU + disk cache, segmented downloader, host pool, history/favorites.

Do not fork the signing contract into Rust.
