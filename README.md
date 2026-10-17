# Cinemacore

One movie product, one Go core, native clients.

| Surface | Stack |
|---|---|
| `core/` + `server/` | Go 1.27 — signing, providers, catalog, cache, download, REST API |
| `mobile/ios/` | Swift 6.4 · SwiftUI · SwiftData · swift-nio |
| `mobile/android/` | Kotlin · Jetpack Compose · Retrofit · Room |
| `tools/tui/` | Rust terminal client |

## Quickstart

```bash
go build ./... && go test ./...
go run ./cmd/cinemacore          # :8080, GET /health
node tasks/bin/tasks.mjs status  # work board
```

See [`AGENTS.md`](AGENTS.md) for the full bootstrap and the agent workflow, [`rules/`](rules/README.md) for coding rules, and [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the design.

## Signing

All MovieBox gateway requests are signed in `core/sign` (HMAC-MD5 canonical string). The contract is pinned by golden vectors generated from the reference Python implementation; see `core/sign/sign_test.go`.
