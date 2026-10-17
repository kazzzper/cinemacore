# Cinemacore — Consolidated Plan (v1)

> Supersedes `mov/cinemacore/plan.md` + `mov/cinemacore/plan-ios.md` (folded here, tightened).
> Status: **plan only**. No code written. Build starts when the user switches out of plan mode.

---

## 1. Product

One movie product, one backend core, four surfaces:

| Surface | Stack | Role |
|---|---|---|
| **core** | Go 1.27 (pure, no cgo) | signing, sessions, providers, catalog, cache, downloads |
| **server** | Go stdlib `net/http` | REST API; source of truth + provider gateway |
| **android** | Kotlin + Compose | native app (Genga-World lineage) |
| **ios** | Swift 6.4 + SwiftUI | native app; UI folded from Genga-World |
| **tui** | Rust (retained) | terminal client; logic ported into `core` |

**Prime directive:** provider / signing / cache / download / history logic exists **once**, in `core`. Surfaces are thin.

---

## 2. Locked decisions

| Area | Decision |
|---|---|
| API language | **Go 1.27** (installed) |
| HTTP router | stdlib `net/http` + Go 1.22+ `ServeMux`; `oapi-codegen` `chi-server` if we adopt chi |
| API role | **Source of truth + adapters**, *and* gateway: own catalog/cache/store, pluggable providers; one wraps `moviebox-internal-api` |
| Contract | **OpenAPI 3.1 first** in `contracts/openapi.yaml`; all clients generated |
| On-device HTTP | **swift-nio `NIOHTTP1`** (Hummingbird on top); never hand-roll HTTP |
| Connectivity | native-first → embedded core → loopback proxy → remote server |
| iOS path | `cinemacore/mobile/ios/` |
| iOS deployment | **iOS 17+** (device range iOS 17–27; simulator only on macOS) |
| Module path | `github.com/solo12345689/cinemacore` (changeable) |
| IDs | Android `com.cinemacore.app` · iOS bundle `com.cinemacore.app` |
| Progress tracking | `tasks/` file board + `registry.json` + harness-agnostic Node CLI |

---

## 3. Architecture — one core, N surfaces

```
        ┌────────────────────── cinemacore/core (Go, pure) ──────────────────────┐
        │ sign · session · provider{moviebox,bdix,addons,tv} · catalog           │
        │ store{cache,library} · fetch{download,proxy} · models                  │
        └───────────────────────────────────────────────────────────────────────┘
             │ wraps            │ gomobile bind            │ port            │ contract
             ▼                  ▼                          ▼                  ▼
        server/ (HTTP)      mobile/{android,ios}      tools/tui (Rust)   generated clients
             ▲                  ▲
             └── remote HTTP ───┴── embedded core ──┘
```

Rule enforced by CI: `core` imports nothing from `server`, `mobile`, or `tools`.

---

## 4. Repo layout

```
cinemacore/
├── plan.md                     # this file (copy)
├── AGENTS.md  CLAUDE.md  README.md  .editorconfig  .gitignore
├── contracts/openapi.yaml      # source of truth
├── core/                       # Go module
│   ├── sign/ session/ provider/{moviebox,bdix,addons,tv}/ catalog/
│   ├── store/{cache,library}/  fetch/  models/
│   └── testdata/vectors/       # golden signing vectors
├── server/  cmd/cinemacore/main.go
├── mobile/
│   ├── gobind/                 # gomobile facade (JSON in/out)
│   ├── android/                # Gradle + Kotlin + Compose
│   └── ios/                    # SwiftPM + SwiftUI (+ xtool.yml)
├── tools/tui/                  # Rust TUI
├── rules/  tasks/  docs/{ARCHITECTURE,DESIGN_DIRECTION}.md  docs/adr/
└── ci/
```

---

## 5. The signing contract (no-loss crux)

Independently implemented in **Python** (`moviebox_api/utils.py`) and **Rust** (`moviebox-tui/.../crypto.rs`) and they agree. Port verbatim to Go, then Swift/Kotlin reuse `core` or the vectors.

```
X-Client-Token = "<ts_ms>,<md5(reverse(ts_ms))>"

canonical = METHOD "\n" Accept "\n" Content-Type "\n" Content-Length "\n"
            ts_ms "\n" md5(body[:102400]) "\n" path "?" sorted_query
x-tr-signature = ts_ms "|2|" base64( HMAC-MD5(secret, canonical) )
secret = base64decode("76iRl07s0xSN9jqmEWAt79EBJZulIQIsV64FZr2O")   # == Rust DEFAULT_SECRET_BYTES
X-Gslb-Sign = sha256(package_name + sha256(device_id))
login password = md5(password)
```

**Gate:** golden vectors (GET/POST, query ordering, empty body, >100 KB body, unicode) must pass in Go **and** Swift **and** Kotlin before any UI work. One byte off = 403/440 everywhere.

---

## 6. Contract-first toolchain (researched 2026)

| Output | Tool | Notes |
|---|---|---|
| Go server + models | **`oapi-codegen` v2.8.x**, `chi-server` or stdlib, `strict-server: true` | Go 1.24+; generates `ServerInterface` to implement |
| Swift client | **`apple/swift-openapi-generator`** | SwiftPM build-time plugin → types + client + `URLSessionTransport` |
| Kotlin client | **`OpenAPI Generator`** `kotlin` generator, `library=multiplatform` (Ktor + kotlinx.serialization) — or `kroegerama/openapi-kmp-gen` (KMP, Arrow, ktor, kotlinx-datetime) | generate **models once** into a shared module; `generate=api` on consumers |

Pin generator versions in `ci/`; regenerate in CI and fail on diff (no drift).

---

## 7. Connectivity & HTTP reliability

**Ladder (fewest moving parts first):**
1. Direct signed `URLSession`/OkHttp → BFF or remote server (JSON). No local server.
2. `AVURLAssetHTTPHeaderFieldsKey` + `AVURLAssetHTTPCookiesKey` for playback headers.
3. `AVAssetResourceLoaderDelegate` for simple custom-scheme interception.
4. **Loopback proxy** on `127.0.0.1` (ephemeral port) — **only** for what 1–3 can't do: `urlprefix=` dummy bypass, SRT→VTT, strict per-segment HLS cookies.

**Engine decision:** **swift-nio (`NIOHTTP1`)**, optionally Hummingbird. Verified `HummingbirdCore.Server` is `@available(iOS 17, *)` — runs on iOS. Network.framework rejected: TCP/TLS only, so HTTP framing would be hand-rolled (the failure source you want to avoid). Apple docs confirm HLS issues requests to *different paths/hosts* where cookies don't automatically apply → a proxy is the robust path.

Android mirrors this with its existing Kotlin `LocalMovieBoxServer` pattern delegating to the `gobind` facade.

---

## 8. iOS app

**Backend policy (single enum, Settings + `UserDefaults`):**
- `.nativeOnly` *(default)* — direct signed BFF; no server.
- `.nativeThenFallback` — native first; on failure embedded loopback, then `remoteServerURL`.
- `.requireRemote` — remote only; explicit error if unreachable (never silent downgrade).

Plus `enableEmbeddedServer: Bool`, `remoteServerURL: URL?`.

**Targets:** `CinemacoreApp` · `CinemacoreCore` (CryptoKit MD5/HMAC-MD5, Signing, Session, API, Models, Provider) · `CinemacoreData` (SwiftData + Keychain) · `CinemacoreUI` · `CinemacoreServer` (swift-nio proxy).

**Local data:** SwiftData with **`VersionedSchema` + `SchemaMigrationPlan`** from day one (`MigrationStage.lightweight`/`.custom`); `WatchProgress` keyed `subjectId_s{season}_e{episode}`; `WatchlistItem`; `CachedSection`. **Tokens in Keychain only.**

**Playback:** stream ranking (m3u8 > mpd > mp4, prefer non-HEVC), `urlprefix=` bypass, `subTitleList` + `get-ext-captions`, SRT→VTT, resume seek, dual-mode quality/dub/subtitle sheet.

**Build:** SwiftPM tools 6.4, `platforms [.iOS(.v17)]`, `swiftLanguageModes [.v6]`; `xtool.yml` bundleID; build via **xtool** (Darwin SDK present). No simulator on Linux → verify on physical iPhone.

---

## 9. Android app

Kotlin 2.4.x · AGP 9.1.x (built-in Kotlin) · Compose BOM 2026.08.00 · Material 3 · minSdk 24 / compile+target SDK 36.

Clean Architecture module split (`app` / `core` / `domain` / `data` / `presentation` / `design-system`); `domain` is pure Kotlin. Retrofit/OkHttp or Ktor, Room for library, Media3 for playback. Local loopback server delegating to `gobind` when the ladder calls for it. Compose rules: stable keys, `remember`/`derivedStateOf`, no work in composition.

---

## 10. TUI

Keep Rust TUI as a first-class client. Its modules are the **source patterns** for `core`: provider abstraction, LRU+disk cache, segmented downloader with range resume, host pool, history/favorites. Either repoint it at the Go server or embed the core; do not fork logic.

---

## 11. Project OS — AGENTS.md · rules/ · tasks/

**`AGENTS.md`** (bootstrap): project map; per-surface bootstrap commands (`go test ./...`, Android Gradle, xtool build); env/ports; agent+harness workflow; DoD; verification gates; harness notes (Claude Code reads `CLAUDE.md`, OpenCode/Cursor read `AGENTS.md`).

**`rules/`** (curated, with `sources.md` provenance):
```
00-senior-doctrine.md  01-go.md  02-kotlin-android.md  03-swift-ios.md
04-rust-tui.md  05-api-contract.md  06-testing.md  07-git-commits.md  sources.md
```
Sources: Effective Go / Go Code Review Comments / Uber Go · Kotlin conventions + nowinandroid + Compose API guidelines · Swift API Design Guidelines + Apple HIG + Airbnb Swift · Rust API Guidelines · Conventional Commits · ECC rules.

**`tasks/`** (harness-agnostic):
```
README.md  TODO.md  BOARD.md  registry.json  progress/<agent>.md  templates/  bin/tasks.mjs
```
Registry: `agent{id,harness,model,branch,worktree,session,startedAt,lastSeen}` · `task{id,title,status,module,owner,deps,acceptance,updatedAt,links}`.
CLI: `tasks register|claim <id>|update <id> -m|done <id>|status|board|sync` → writes registry, regenerates `BOARD.md`/`TODO.md`, appends `progress/<agent>.md`.

---

## 12. Senior style doctrine (encoded in `rules/00`)

- **Smallest correct change.** One-line fix over a 100-line rewrite; rewrite only if the diff is smaller or provably equal-risk.
- **No loss.** Behaviour, types, tests, error paths preserved. Shorter ≠ fewer cases.
- **Code > prose.** Diffs over filler; no restated comments, dead code, or speculative abstraction.
- **DRY across surfaces.** Logic seen twice moves to `core`/`contracts`.
- **Fail loud.** Typed errors; empty/error/partial are real states; no silent catch.
- **Proof.** Every change ships the smallest test that fails without it.
- **DoD:** builds · tests green · contract regenerated · `tasks` updated · diff reviewed.

---

## 13. Phases & acceptance

| Phase | Deliverable | Acceptance |
|---|---|---|
| **P0** | Skeleton, `AGENTS.md`, `rules/`, `tasks/` + CLI, `contracts/openapi.yaml` | `tasks status` runs; contract lints; empty targets build |
| **P1** | Go `sign` + `session` + models | golden vectors pass in Go & Swift & Kotlin byte-for-byte |
| **P2** | Go `server` (auth/browse/search/title) + moviebox provider | contract-conformance tests green; serves `:8080` |
| **P3** | Go `store` + `library` + `fetch` | resume/interrupt tests; SQLite persistence |
| **P4** | Android app | design spec met; six states covered |
| **P5** | iOS app | parity with Android on same spec; iPad split view |
| **P6** | `gobind` facade + loopback proxy; TUI repointed | offline path works on device (`go test ./... -race` green) |
| **P7** | Hardening | privacy manifest, no `NSAllowsArbitraryLoads`, OSLog privacy, SBOM, Instruments |

Each phase independently shippable.

---

## 14. Researched toolchain facts (Oct 2026)

- **Xcode 27** (14 Sep 2026) ships **Swift 6.4** and **iOS 27** SDK; Xcode 27.1 (5 Oct) current. Device support iOS **17+**. Swift **6.4.1** installed locally.
- **Hummingbird** `Server` available **iOS 17+**; built on swift-nio.
- **gomobile** `golang.org/x/mobile` actively maintained (requires Go 1.26+); builds Android `.aar` (SDK+NDK on Linux) and iOS `.xcframework` (**macOS** required).
- **swift-openapi-generator** = Apple build-time plugin; core client is contract-first.
- **oapi-codegen v2.8.0** (Jul 2026) supports stdlib `net/http` + chi/echo/fiber strict servers.
- **SwiftData** versioning via `VersionedSchema` / `SchemaMigrationPlan` / `MigrationStage` (iOS 17+).
- **Compose BOM 2026.08.00**, Compose compiler ships with Kotlin since 2.0; **AGP 9.0+** has built-in Kotlin.
- Local installs: Go **1.27**, Swift **6.4.1**, xtool **1.22.2**, Darwin SDK present. **Missing:** JDK/Gradle/Android SDK+NDK (needed for P4/P6).

---

## 15. Risks

| Risk | Level | Mitigation |
|---|---|---|
| Signing parity drift | HIGH | golden vectors vs Python+Rust before UI |
| Anti-piracy traps (`urlprefix` dummy, 403/302) | HIGH | port bypass + host failover + loopback proxy |
| HLS cookies on AVPlayer | MED | asset keys first; proxy fallback |
| gomobile needs macOS/NDK | MED | gate P6; iOS is native Swift so not blocked |
| Android toolchain absent locally | MED | install JDK/AGP/SDK before P4 |
| Reverse-engineered secret (ToS/legal) | MED | document; isolate in versioned `core/sign` struct |
| Scope (4 surfaces) | MED | strict phases, each shippable |
| No iOS simulator on Linux | LOW | verify on physical device |

---

## 16. Open decisions

1. Embedded scope: **proxy-only** (recommended) vs full REST facade.
2. Confirm `api5`/`api4` failover hosts — only `api6.aoneroom.com` + `api.inmoviebox.com` verified in-repo.
3. Gateway depth: how much `moviebox-internal-api` to proxy vs re-implement in `core`.
4. Auth model: guest-first vs account-required for library sync.

---

## 17. Non-goals

- No re-implementation of what the gateway already serves.
- No shared UI framework across Android/iOS — shared **spec**, native code.
- No non-Go backend.
- No hand-rolled HTTP anywhere.
