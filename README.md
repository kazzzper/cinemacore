<div align="center">

# 🎬 Cinemacore

**One movie product. One Go core. Native clients everywhere.**

[![Go](https://img.shields.io/badge/Go-1.27-00ADD8?logo=go&logoColor=white)](https://go.dev)
[![Swift](https://img.shields.io/badge/Swift-6.4-F05138?logo=swift&logoColor=white)](https://swift.org)
[![Kotlin](https://img.shields.io/badge/Kotlin-Compose-7F52FF?logo=kotlin&logoColor=white)](https://kotlinlang.org)
[![OpenAPI](https://img.shields.io/badge/OpenAPI-3.1-6BA539?logo=openapiinitiative&logoColor=white)](contracts/openapi.yaml)
[![License](https://img.shields.io/badge/License-TBD-lightgrey)](#license)

The gateway logic — signing, sessions, providers, catalog, caching, downloads — lives **once**, in `core/`.
Every surface is thin. The iOS app talks to the same contract the TUI will.

[Quickstart](#quickstart) · [Architecture](#architecture) · [Status](#status) · [Contributing](#contributing)

</div>

---

## ✨ Features

- **Single source of truth** — `contracts/openapi.yaml` drives every client; a generated Kotlin client ships with the Android app.
- **Signed upstream access** — HMAC-MD5 canonical-string signing, pinned by golden vectors tested in **both** Go and Swift.
- **Real catalog, real playback** — home, search, seasons and play return live gateway data; progressive-MP4 URLs, subtitles, resume, PiP.
- **Offline-first downloads** — direct progressive files, captions saved beside them, resumable.
- **Native everywhere** — SwiftUI + AVPlayer on iOS, Jetpack Compose + Media3 on Android, Rust TUI on the roadmap.
- **Testable on Linux** — pure Foundation core for iOS; 411 Swift tests + Go race suite run on the host.
- **Contract-first** — provider / signing / cache / download logic exists once, in `core/`. Surfaces stay thin.

## 📸 Preview

> Screenshots and a demo GIF land here once a device build ships. Builds and tests are the current evidence.

| iOS (xtool) | Android (Compose) |
|---|---|
| `xtool/Cinemacore.app` | `:app:assembleDebug` |

---

## 🏗️ Architecture

```
core/                    Go, pure — imports nothing from server/, mobile/ or tools/
  sign/                  Gateway signing (HMAC-MD5 canonical string), golden-vector pinned
  session/               Signed HTTP client: host failover, guest token, response cache
  provider/moviebox/     MovieBox adapter
  catalog/               Catalog assembly
  store/cache/           Response cache
server/                  REST API over the core
cmd/cinemacore/          Server entry point
contracts/               openapi.yaml (wire API) · signing-vectors.json (signing)
mobile/ios/              CinemacoreCore (pure) + Cinemacore (SwiftUI app)
mobile/android/          Kotlin/Compose client · generated OpenAPI types · Media3
tools/tui/               Rust terminal client (placeholder)
tasks/                   Harness-agnostic work board (Node)
```

Why iOS is two packages: there is no iOS Simulator on Linux, and `swift test` in a single package
tries to build the SwiftUI target and dies with `no such module 'SwiftUI'`. Splitting them makes the
boundary compiler-enforced — `CinemacoreCore` cannot import SwiftUI even by accident — so models,
signing, networking and view models stay testable on the host. See `docs/adr/0004`.

---

## 📊 Status

| Surface | State | Verified by |
|---|---|---|
| `core/` + `server/` | ✅ Builds, tests green. Live catalog works. | `go build ./... && go test ./...` |
| `mobile/ios/` | ✅ Builds to `Cinemacore.app`. 5 tabs, AVPlayer, PiP, downloads. | `swift test` (411 tests) + `xtool dev build` |
| `mobile/android/` | 🚧 Port in progress. Toolchain green. | `./gradlew :app:assembleDebug` + `:app:testDebugUnitTest` |
| `tools/tui/` | 📋 Placeholder | — |

**Honest caveats:** neither mobile app has ever run on a device. Builds and tests are the evidence.

---

## 🚀 Quickstart

### Go core + API

```bash
go build ./...
go test ./...
go run ./cmd/cinemacore                 # :8080
curl -s localhost:8080/health
```

The gateway serves MovieBox by default. `CINEMACORE_PROVIDER` selects the source: `moviebox`,
`streamhype` (TMDB catalog, needs `TMDB_API_KEY`) or `all` (merged search).

### iOS (testable logic on Linux)

```bash
cd mobile/ios/CinemacoreCore && swift test
```

### iOS (the app)

```bash
cd mobile/ios/Cinemacore
xtool dev build                         # -> xtool/Cinemacore.app
xtool dev build -c release --ipa        # -> .ipa
```

### Android

```bash
cd mobile/android
./gradlew :app:assembleDebug
./gradlew :app:testDebugUnitTest
```

See [`ANDROID.md`](ANDROID.md) for one-time toolchain setup.

---

## 🧪 Testing

```bash
go test ./... -race
cd mobile/ios/CinemacoreCore && swift test
cd mobile/android && ./gradlew :app:testDebugUnitTest
```

The signing contract is verified in **two languages**: both Go (`core/sign`) and Swift load
`contracts/signing-vectors.json`, including 53 `resourceVectors` cases generated from the Go reference.

---

## 📡 Wire API

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

---

## 🤝 Contributing

Read [`AGENTS.md`](AGENTS.md) first — it is the operating contract for every harness. Then:

- [`rules/00-senior-doctrine.md`](rules/00-senior-doctrine.md) — smallest correct change, no loss.
- [`rules/08-comments.md`](rules/08-comments.md) — comment the *why*, never the *what*.
- [`rules/07-git-commits.md`](rules/07-git-commits.md) — Conventional Commits (enforced by hook).

Enable the commit hook once per clone:

```bash
git config core.hooksPath .githooks
```

---

## 🗺️ Known gaps

- No device verification on either mobile surface yet.
- Downloads are **direct progressive files only** (HLS/DASH refused).
- `core/store/library` is empty — watchlist/history live only in each app's store.
- iOS still uses hand-written request paths; Android uses the generated OpenAPI client.

---

## 📄 License

Not yet specified. Third-party components keep their own licences; Apple's Developer Program
License Agreement governs where the Apple SDKs may be used.

<div align="center">

Made with ☕ by the Cinemacore team.

</div>
