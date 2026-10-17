# Architecture

## Shape

```
core/ (Go, pure)  ──►  server/ (HTTP)   ──►  remote clients (iOS, TUI)
```

**Dependency rule (CI-enforced):** `core/` imports nothing from `server/`, `mobile/`, or `tools/`. Everything flows inward to `core/`.

Clients reach the core over HTTP. There is deliberately **no `gobind`/embedded-core path**: the iOS app
signs natively in Swift (`mobile/ios/CinemacoreCore/Sources/CinemacoreCore/Signing.swift`), so no cgo or
macOS toolchain is required and the algorithm has exactly one implementation per language, pinned by
`contracts/signing-vectors.json`. See `adr/0002`.

## Packages

| Package | Responsibility |
|---|---|
| `core/sign` | Gateway signing: `X-Client-Token`, `x-tr-signature`, `X-Gslb-Sign`. Frozen by golden vectors. |
| `core/session` | Signed HTTP client: host failover, guest token, GET response cache. |
| `core/provider` | `Provider` interface + adapters (`moviebox`, later `bdix`, `addons`, `tv`). |
| `core/catalog` | Aggregation over providers: merge/dedupe search, fall through on failure. |
| `core/store/cache` | LRU + TTL cache. |
| `core/store/library` | Watchlist, history, resume position. *(planned — T-005)* |
| `core/fetch` | Segmented download with range resume, media proxy. *(planned — T-005)* |
| `server` | HTTP transport only: routing, JSON, error envelope. |
| `cmd/cinemacore` | Wiring, config, graceful shutdown. |

## Signing

All gateway requests are signed in `core/sign`. The contract was implemented independently in the Python reference (`moviebox_api/utils.py`) and the Rust TUI (`crypto.rs`) and both agree; the Go port is pinned to golden vectors generated from the Python reference (`core/sign/sign_test.go`). Never change signing without a new vector and a versioned decision.

## Connectivity ladder (clients)

1. Direct signed request to the remote server (default).
2. Loopback HTTP proxy (swift-nio on iOS, Kotlin on Android) only when 1 cannot work.

Media and subtitle requests are **not** routed through either: the CDN expects only a `User-Agent` and
the per-rendition `Cookie`, so they are fetched directly with header fields. The loopback proxy exists
for signing-sensitive API flows, not for playback.

## Further reading

- Consolidated plan: `plan.md`
- Rules: `../rules/`
- Work board: `../tasks/`
