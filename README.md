# Cinemacore

One movie product: a single Go core, a REST API, and native clients.

The gateway logic — signing, sessions, providers, catalog, caching, downloads — lives **once**, in
`core/`. Every surface is thin. The iOS app talks to the same contract the TUI will.

---

## Status

| Surface | State | Verified by |
|---|---|---|
| `core/` + `server/` | Builds, tests green. **The live catalog works** — home, search, seasons and play all return real gateway data. | `go build ./... && go test ./...`, then `curl localhost:8080/v1/home` |
| `mobile/ios/` | **Builds to `Cinemacore.app`.** Five tabs, detail/history/settings, real AVPlayer, PiP, direct progressive downloads. See [`mobile/ios/README.md`](mobile/ios/README.md). | `swift test` (411 tests / 62 suites) + `xtool dev build` |
| `mobile/android/` | **Port in progress.** Kotlin/Compose client with the toolchain green. See [`mobile/android/README.md`](mobile/android/README.md). | `./gradlew :app:assembleDebug` + `:app:testDebugUnitTest` |
| `tools/tui/` | Placeholder (`README.md` only). | — |

Two honest caveats, because they are easy to mistake for working features:

- **The iOS app has never run on a device.** No iPhone was ever attached, so `xtool dev run` has never
  executed and the `.app` is unsigned. `xtool dev build` type-checks and links it against the iOS 27.1
  SDK; that is the strongest evidence available without hardware.
- **Playback is wired but has never been executed on hardware.** Live `/v1/play` returns real
  progressive-MP4 URLs, so the media path is viable. The downloader handles direct progressive files
  through `URLSession`; HLS/DASH downloaders are explicitly refused. The *bundled* demo catalog — used
  when no gateway answers — points at the reserved `.test` TLD and cannot play. Player controls,
  selection sheets, captions, resume and PiP are implemented but unexercised on a device.

---

## Layout

```
core/                    Go, pure — imports nothing from server/, mobile/ or tools/
  sign/                  Gateway signing (HMAC-MD5 canonical string), pinned by golden vectors
  session/               Signed HTTP client: host failover, guest token, response cache
  provider/moviebox/     MovieBox adapter
  catalog/               Catalog assembly
  store/cache/           Response cache
  store/library/         Watchlist + history (not implemented yet)
  fetch/                 Segmented download (not implemented yet)
server/                  REST API over the core
cmd/cinemacore/          Server entry point
contracts/
  openapi.yaml           Single source of truth for the wire API
  signing-vectors.json   Single source of truth for signing — Go AND Swift load this
mobile/ios/
  CinemacoreCore/        Pure Foundation package. No SwiftUI/UIKit/AVFoundation — unit-tested on Linux.
  Cinemacore/            SwiftUI app, built by xtool against the Darwin SDK.
mobile/android/          Kotlin/Compose client. Generated OpenAPI types + Media3. See its README.
tools/tui/               Rust terminal client (placeholder)
tasks/                   Harness-agnostic work board (Node)
rules/                   Coding rules, enforced by review
docs/                    Architecture + design direction + ADRs
```

Why iOS is two packages: there is no iOS Simulator on Linux, and `swift test` in a single package
tries to build the SwiftUI target and dies with `no such module 'SwiftUI'`. Splitting them makes the
boundary compiler-enforced — `CinemacoreCore` cannot import SwiftUI even by accident — so models,
signing, networking and view models stay testable on the host. See `docs/adr/0004`.

---

## Requirements

| Tool | Version | Notes |
|---|---|---|
| Go | 1.27+ | `core/` and `server/` |
| Swift | 6.4 | via [swiftly](https://www.swift.org/swiftly/); **not on `PATH` by default** |
| xtool | 1.22+ | cross-platform build/sign/install for iOS |
| Xcode SDK | 27.x | `xtool sdk install` needs the Apple SDK; nothing ships in this repo |
| JDK | 17 | Android build; AGP 9.1 needs 17+ |
| Android CLI | 1.1+ | SDK packages via `android sdk`; see [`ANDROID.md`](ANDROID.md) |
| Gradle | 9.1+ | Android build; the wrapper is checked in |
| Node | 20+ | only for the `tasks/` CLI |
| Rust | 1.8x | only for the TUI (not started) |

---

## Quickstart

### Go core + API

```bash
go build ./...
go test ./...
go run ./cmd/cinemacore                 # :8080
CINEMACORE_ADDR=:8971 go run ./cmd/cinemacore
curl -s localhost:8080/health
```

The gateway serves MovieBox by default. `CINEMACORE_PROVIDER` selects the source: `moviebox`,
`streamhype` (TMDB catalog, web-embed playback — needs `TMDB_API_KEY` for the gateway) or `all`
(merged search). The Android app can also talk to StreamHype directly with its public fallback key.
See `docs/adr/0007`.

### iOS — testable logic (works on Linux)

```bash
cd mobile/ios/CinemacoreCore
swift test
```

### iOS — the app

```bash
cd mobile/ios/Cinemacore
xtool dev build                         # -> xtool/Cinemacore.app
xtool dev build -c release --ipa        # -> .ipa
xtool dev run                           # requires a connected iPhone
```

First run on a device needs Developer Mode enabled on the phone (iOS 16+) and `xtool auth login`.
Free provisioning expires after **7 days**, so `xtool dev run` has to be re-run.

**StreamHype source.** Settings → Data source can switch the app to StreamHype (TMDB + the in-app web
player). It uses StreamHype's published TMDB client key by default, so it works without setup. To use
your own quota, paste a key from [themoviedb.org](https://www.themoviedb.org/settings/api) into
`TMDBAPIKey` in `mobile/ios/Cinemacore/Info.plist`, or set `TMDB_API_KEY` in the environment.
Downloads and offline play are not offered on this source.

**Pointing the app at a gateway.** On launch the app probes `http://127.0.0.1:8080/health`, and falls
back to the bundled demo catalog if nothing answers — a banner on Home says which source is live. On a
physical iPhone `127.0.0.1` is the *phone itself*, so set your machine's LAN address under
**Settings → Gateway URL** (for example `http://192.168.1.20:8080`); the server binds all interfaces by
default. Applying it reconnects and rebuilds every screen.

### Android

One-time toolchain setup (JDK 17, Android CLI, SDK platform 37.0) is in [`ANDROID.md`](ANDROID.md).
`android sdk` replaces the deprecated `sdkmanager`.

```bash
cd mobile/android
./gradlew :app:assembleDebug
./gradlew :app:testDebugUnitTest
```

Open `mobile/android` directly in Android Studio. The stable CLI launcher is `studio` (installed at
`~/.local/bin/studio`). See [`mobile/android/README.md`](mobile/android/README.md) for the data/player
architecture and known limits.

### TUI

Not implemented. See `tools/tui/README.md`.

---

## iOS on Linux — the non-obvious parts

These bite every time, so set them up once:

```bash
# 1. Swift is installed by swiftly but is not on PATH.
export PATH="$HOME/.local/share/swiftly/bin:$PATH"

# 2. xtool ships as an AppImage. On a host without FUSE it cannot mount, so
#    extract it once and use the extracted binary:
#      xtool --appimage-extract        # -> squashfs-root/usr/bin/xtool
export XTOOL="$PWD/squashfs-root/usr/bin/xtool"

# 3. SwiftPM and xtool want writable temp/cache dirs. If $HOME is read-only
#    (containers, sandboxes), redirect them, or xtool fails with
#    "Could not create temporary directory in '/home/<user>/.cache/xtool'":
export XTL_TMPDIR="$PWD/.tmp" TMPDIR="$PWD/.tmp" XDG_CACHE_HOME="$PWD/.cache"

# 4. Go's build cache is also under $HOME:
export GOCACHE="$PWD/.gocache" GOPATH="$PWD/.gopath"
```

Silencing two harmless warnings: SwiftPM prints
`~/.swiftpm/configuration is not accessible or not writable` when `$HOME` is read-only. They are not
compiler diagnostics. Passing `--cache-path/--config-path/--security-path` removes them.

### Never share one `.build` between concurrent builds

SwiftBuild keeps a single `build.db`, and `xtool dev build -c release --ipa` runs **several build tasks
in parallel against it**. Any other build touching the same `.build` produces:

```
error: unable to attach DB: ... build.db: database is locked
```

Worse, a build that starts while a source file is being written compiles a **half-written snapshot**,
so the errors point at line numbers that do not exist in the file — a cascade of nonsense like
*"cannot find 'url' in scope"* or *"class declaration cannot close over value 'self'"*. That is a
concurrency artifact, not a bug in your code: re-read the file before believing the error.

`swift test` isolates cleanly with `--scratch-path .build-<name>`. `xtool` has no equivalent flag, so if
another build might be running, snapshot the sources into a private directory first and build there —
this is also the fastest way to get a trustworthy answer about whether the tree really compiles:

```bash
snap=$(mktemp -d)/ios && mkdir -p "$snap"
cd mobile/ios
tar -cf - --exclude='.build*' --exclude=xtool --exclude=.bsp CinemacoreCore Cinemacore \
  | (cd "$snap" && tar -xf -)
cd "$snap/Cinemacore" && xtool dev build -c release --ipa
```

A clean release build from a private snapshot takes roughly 90 s and produces `xtool/Cinemacore.ipa`.
Without `--sign` the IPA is unsigned; it needs re-signing by the installer (AltStore/Sideloadly) or a
`--sign` build with a provisioning profile.

Fresh machine, no SDK yet:

```bash
xtool sdk install --sdk-version <ios-sdk>    # needs Xcode.xip
xtool sdk status
xtool auth login
xtool devices                                # --no-wait to list without blocking
```

---

## Testing

```bash
go test ./... -race                    # Go core + server
cd mobile/ios/CinemacoreCore && swift test   # 411 tests, runs on Linux
cd mobile/android && ./gradlew :app:testDebugUnitTest
```

### The signing contract is tested in two languages

`contracts/signing-vectors.json` is the single source of truth for request signing. **Both** suites
load that one file:

- Go — `core/sign/sign_test.go`
- Swift — `mobile/ios/CinemacoreCore/Tests/CinemacoreCoreTests/SigningTests.swift`

It carries the client-token, TR-signature, GSLB and password vectors, plus 53 `resourceVectors` cases
that were generated **from the Go reference** and pin the canonical string for query decoding, stable
sorting and path escaping. One byte of drift here breaks every signed request, so this is a release
gate rather than a smoke test. Changing the fixture requires a source and a timestamp.

---

## The wire API

`contracts/openapi.yaml` is the source of truth. iOS still uses a hand-written Swift client
(`RemoteCatalogRepository.swift`). Android uses a committed generated Kotlin client under
`mobile/android/app/src/main/java/com/cinemacore/app/data/api/`; regenerate it with
`mobile/android/openapi/generate.sh`.

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/health` | Liveness |
| `GET` | `/version` | Build version |
| `GET` | `/openapi.json` | The contract itself |
| `GET` | `/v1/home` | Landing rails |
| `GET` | `/v1/search?q=` | Free-text search |
| `GET` | `/v1/search/suggestions?q=` | Type-ahead |
| `GET` | `/v1/detail/{id}` | One title |
| `GET` | `/v1/detail/{id}/seasons` | Season/episode tree |
| `GET` | `/v1/play?subjectId=&season=&episode=` | Resolved streams + subtitles |

---

## Work tracking

Every agent and human uses the same board; `tasks/registry.json` is never edited by hand.

```bash
node tasks/bin/tasks.mjs status
node tasks/bin/tasks.mjs claim T-007 --agent <name>
node tasks/bin/tasks.mjs update T-007 -m "player landed" --agent <name>
node tasks/bin/tasks.mjs done T-007 --agent <name>
node tasks/bin/tasks.mjs board            # regenerates BOARD.md
```

Enable the commit-message hook once per clone (Conventional Commits are enforced):

```bash
git config core.hooksPath .githooks
```

---

## Contributing

Read [`AGENTS.md`](AGENTS.md) first — it is the operating contract for every harness. Then:

- [`rules/00-senior-doctrine.md`](rules/00-senior-doctrine.md) — the king rule: smallest correct
  change, no loss.
- [`rules/08-comments.md`](rules/08-comments.md) — comment the *why*, never the *what*.
- [`rules/03-swift-ios.md`](rules/03-swift-ios.md) — Swift/SwiftUI.
- [`rules/07-git-commits.md`](rules/07-git-commits.md) — Conventional Commits.

Definition of done: it builds, tests are green (including the signing vectors), the contract is
updated if the wire API changed, `tasks` is updated, and the diff is reviewed against the doctrine.

---

## Known gaps

- **No device verification on either mobile surface.** iOS has never run on an iPhone; Android has no
  AVD or attached device in this environment yet. Builds and JVM/Swift tests are the evidence.
- Downloads are **direct progressive files only**. HLS/DASH downloaders are refused on both clients.
  There is no 10 GB cap, 5 GB warning, 2 GB block, or automatic deletion.
- `core/store/library` is empty, so watchlist and history live only in each app's own store. The two
  stores do not sync.
- Liquid Glass appears only via `.buttonStyle(.glass)` on buttons — `GlassEffectContainer`, a floating
  tab bar and `ToolbarSpacer` are not used.
- No iPad size-class layout, even though the Info.plist declares `UIDeviceFamily [1,2]`.
- iOS still uses hand-written request paths in `RemoteCatalogRepository`. Android uses the generated
  OpenAPI client.
- The gateway is inconsistent about `Subject.kind` — the contract documents `1`/`2`, live responses
  send `"series"`. Clients accept both, but the contract should be tightened.
- Native Swift signing is not on the request path for the gateway mode: the app calls this Go gateway,
  which signs upstream. `Signing.trSignature` is exercised by its test suite and the direct built-in
  source, but not by gateway mode.
- Android does not port the direct MovieBox signing/session/stream-recovery path. It uses the gateway
  for MovieBox. StreamHype is available directly, with the public TMDB fallback.
- Android downloads/player are not verified on a device. The emulator/AVD still needs to be created.

---

## License

Not yet specified. Third-party components keep their own licences; note that Apple's Developer Program
License Agreement governs where the Apple SDKs may be used.
