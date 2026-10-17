# Architecture

## Shape

```
core/ (Go, pure)  ──►  server/ (HTTP)   ──►  remote clients
        │
        ├──►  mobile/gobind  ──►  mobile/{ios,android} (embedded core)
        └──►  tools/tui (Rust client)
```

**Dependency rule (CI-enforced):** `core/` imports nothing from `server/`, `mobile/`, or `tools/`. Everything flows inward to `core/`.

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
2. Embedded Go core via `gobind` for offline / signing-sensitive flows.
3. Loopback HTTP proxy (swift-nio on iOS, Kotlin on Android) only when 1–2 cannot work.

## Further reading

- Consolidated plan: `plan.md`
- Rules: `../rules/`
- Work board: `../tasks/`
