# Cinemacore

A single Go core, a REST API, and native clients for one movie product. Signing, sessions, providers, catalog, caching and downloads live once in `core/`; every surface is thin, and each client talks to the same contract.

## What it does

- **Gateway** — `server/` exposes a REST API over `core/`: home rails, search, detail, seasons, play (resolved streams + subtitles).
- **Signing** — HMAC-MD5 canonical-string request signing, pinned by golden vectors tested in both Go and Swift.
- **Native clients** — SwiftUI + AVPlayer on iOS, Jetpack Compose + Media3 on Android, Rust TUI planned.
- **Offline** — direct progressive downloads with captions saved beside them, resumable.
- **Testable on Linux** — iOS logic ships as a pure Foundation package; 411 Swift tests + the Go race suite run on the host.

## Quick start

```bash
go build ./... && go test ./...
go run ./cmd/cinemacore                 # :8080
curl -s localhost:8080/health
```

```bash
cd mobile/ios/CinemacoreCore && swift test
cd mobile/android && ./gradlew :app:assembleDebug
```

The gateway serves MovieBox by default. `CINEMACORE_PROVIDER` selects the source: `moviebox`,
`streamhype` (TMDB catalog, needs `TMDB_API_KEY`) or `all` (merged search).

## Status

| Surface | State | Verified by |
|---|---|---|
| `core/` + `server/` | Builds, tests green. Live catalog works. | `go build ./... && go test ./...` |
| `mobile/ios/` | Builds to `Cinemacore.app`. 5 tabs, AVPlayer, PiP, downloads. | `swift test` (411 tests) + `xtool dev build` |
| `mobile/android/` | Port in progress. Toolchain green. | `./gradlew :app:assembleDebug` + `:app:testDebugUnitTest` |
| `tools/tui/` | Placeholder | — |

Neither mobile app has run on a device yet. Builds and tests are the evidence.

## Architecture

```
core/        Go, pure — imports nothing from server/, mobile/ or tools/
server/      REST API over the core
contracts/   openapi.yaml (wire API) · signing-vectors.json (signing)
mobile/ios/  CinemacoreCore (pure) + Cinemacore (SwiftUI app)
mobile/android/  Kotlin/Compose · generated OpenAPI types · Media3
```

iOS is split into two packages because there is no iOS Simulator on Linux: a single
package's `swift test` tries to build the SwiftUI target and fails. Splitting makes the
boundary compiler-enforced, so models, signing, networking and view models stay testable
on the host. See `docs/adr/0004`.

## Wire API

`contracts/openapi.yaml` is the source of truth.

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/health` | Liveness |
| `GET` | `/version` | Build version |
| `GET` | `/v1/home` | Landing rails |
| `GET` | `/v1/search?q=` | Free-text search |
| `GET` | `/v1/detail/{id}` | One title |
| `GET` | `/v1/detail/{id}/seasons` | Season/episode tree |
| `GET` | `/v1/play?subjectId=&season=&episode=` | Resolved streams + subtitles |

## Testing

```bash
go test ./... -race
cd mobile/ios/CinemacoreCore && swift test
cd mobile/android && ./gradlew :app:testDebugUnitTest
```

Both Go (`core/sign`) and Swift load `contracts/signing-vectors.json`, including 53
`resourceVectors` cases generated from the Go reference.

## Contributing

Read [`AGENTS.md`](AGENTS.md) first. Then [`rules/00-senior-doctrine.md`](rules/00-senior-doctrine.md)
and [`rules/07-git-commits.md`](rules/07-git-commits.md). Enable the commit hook once per clone:

```bash
git config core.hooksPath .githooks
```

## Known gaps

- No device verification on either mobile surface.
- Downloads are direct progressive files only (HLS/DASH refused).
- `core/store/library` is empty — watchlist/history live only in each app's store.
- iOS uses hand-written request paths; Android uses the generated OpenAPI client.
- `Subject.kind` is inconsistent between contract (`1`/`2`) and live responses (`"series"`).

## License

Not yet specified. Third-party components keep their own licences; Apple's Developer Program
License Agreement governs where the Apple SDKs may be used.
