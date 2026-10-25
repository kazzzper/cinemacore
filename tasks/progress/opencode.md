# opencode — progress

## T-008 · Embedded Go gateway in the iOS app (in-app HTTP server + Settings source picker)

**Status:** plan phase, awaiting approval. Scope changed from the original wording: the user
wants the **real Go gateway embedded as a full REST facade**, not a `swift-nio` proxy.

### Recon evidence (all verified on this Linux host, 2026-10-17)

| Question | Verdict | Evidence |
|---|---|---|
| Can Go cross-build for iOS here? | **Yes** | `GOOS=ios GOARCH=arm64 CGO_ENABLED=1 go build -buildmode=c-archive` produced a 3.5 MB `libprobe.a`; first object magic `cffa edfe` = Mach-O 64-bit arm64; `libprobe.h` generated with `extern GoInt CinemacoreProbe(void);` |
| Is `gomobile` needed? | **No** | We built a c-archive directly. `gomobile`/`xcrun` are absent, and `plan.md` §14 + ADR-0002 assumed gomobile ⇒ macOS. That assumption is now false. |
| Is the toolchain present? | **Yes** | clang 21 (`swiftly`), `ld64.lld`, `lld`, Swift 6.4.1, Go 1.27, Darwin SDK at `~/.swiftpm/swift-sdks/darwin.artifactbundle/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk` |
| Are `core` + `server` iOS-clean? | **Yes** | pure Go, no cgo; only the *executable* link fails (expected) |
| Does the server need the spec file at startup? | **No** | `SpecPath` is read lazily inside `GET /openapi.json` (`server/server.go:65`); omit or bundle it |

### Why this is small: the seam already exists

`RemoteCatalogRepository` already speaks the exact `/v1/*` contract over HTTP, and every screen
depends only on the `CatalogRepository` protocol. Embedding the gateway is therefore a **producer
swap** — start the server on `127.0.0.1:<port>` and hand `RemoteCatalogRepository(baseURL:)` the
loopback URL. **No screen or view-model changes.**

### Decision to ratify (needs ADR-0006)

1. **Embedded scope = full Go REST facade**, overriding `plan.md` §7's ladder ("loopback proxy …
   only for what 1–3 can't do") and open decision #1 ("proxy-only (recommended)").
2. **Supersedes the gomobile-rejection clause of ADR-0002.** The rejection rested on "unproven on
   Linux with the xtool toolchain" — now disproven. The signing argument in ADR-0002 stands and is
   untouched (Swift `Signing` stays; it is already off the request path).
3. **Default source = embedded**, external gateway as the fallback/option. `plan.md` §8 already
   names the API: `backendPolicy` (`nativeOnly` / `nativeThenFallback` / `requireRemote`) +
   `enableEmbeddedServer` + `remoteServerURL`.

### Design

**Go side — new `mobile/gobind/` (`package main`, keeps `core/` pure):**
```go
//export StartGateway
func StartGateway() *C.char   // starts server.New(...) on 127.0.0.1:0, returns JSON {port,err}
//export StopGateway
func StopGateway()
```
Thread the bound port back out — `server.ListenAndServe(addr)` does not report the ephemeral port,
so the bridge listens with `net.Listen("tcp", "127.0.0.1:0")` and calls `http.Serve`.

**Build — `ci/build-ios-gobind.sh`:**
`go build -buildmode=c-archive` → hand-assembled `CinemacoreGobind.xcframework` (`ios-arm64`,
`Headers/` + `module.modulemap`) → SwiftPM `.binaryTarget` in the **app** package only, so
`CinemacoreCore` stays Linux-testable and cannot import the framework.

**Swift side:**
- `GatewayHost` protocol in `CinemacoreCore` (injectable; fake-able in tests).
- `EmbeddedGateway` in the `Cinemacore` app target (the only thing importing the framework).
- `AppModel.bootstrap()`: policy → start embedded → `RemoteCatalogRepository(loopback)` →
  else external URL → else fixtures.
- Settings: source picker + `enableEmbeddedServer` toggle (gateway URL field already exists).

### Risks

| Risk | Level | Mitigation |
|---|---|---|
| Linking the Go c-archive into the xtool/SwiftPM build (link flags, modulemap) | **HIGH** | **Gate P6.0:** link a toy archive into the real app and call it from Swift on device before any feature work |
| SwiftPM `.binaryTarget` may not be accepted by xtool on Linux | MED | fall back to `.systemLibrary` + `unsafeFlags(["-L…","-l…"])` |
| App size (+Go runtime) | LOW | measure; ~8–12 MB expected |
| Loopback listener / ATS | LOW | `127.0.0.1` only; `NSAllowsLocalNetworking` already set |
| Rule conflict: `core` is "pure, no cgo" | LOW | cgo lives only in `mobile/gobind/`; `core` unchanged |
| ADR-0002 conflict | MED | ADR-0006 supersedes the gomobile clause explicitly |

### Phases

- **P6.0** Spike: link toy `libprobe.a` into the app, call `CinemacoreProbe()` from Swift, run on
  device. *Gate — do not start P6.1 until green.*
- **P6.1** `mobile/gobind/` bridge + `ci/build-ios-gobind.sh`.
- **P6.2** Swift `GatewayHost` + `EmbeddedGateway` + `AppModel` wiring.
- **P6.3** Settings source picker + `LibrarySettings` fields (tolerant decode already added, so no
  migration break).
- **P6.4** Tests (`swift test` unchanged; bridge covered by a Go test), ADR-0006, docs, DoD.

### Open questions

1. Should the embedded server bind **loopback only** (safe, app-only) or also `0.0.0.0` so Android/TUI
   can use the phone as a gateway? T-008's title mentions "TUI repoint".
2. Is the swift-nio proxy dropped entirely, or kept for the HLS-cookie case `plan.md` §7 describes?
3. CI: is a Mac ever in the loop, or is Linux-only the permanent target? (Only affects whether we
   keep gomobile as an alternative.)
- 2026-10-20T10:26:11.028Z — registered (opencode)
- 2026-10-20T10:27:44.585Z — claimed T-009 — P0: download container model, persistence, decoy and manifest correctness

## T-009 · P0 container model, persistence, decoy and manifest correctness

**Status:** implementation complete; tests and app build green. Commit deferred because the tree also
contains uncommitted built-in-provider work that must not be swept into a task commit.

### Landed

- `MediaContainer` classifies MP4 / HLS / DASH / unknown by content type first, then extension; a
  manifest is never a direct download.
- `DownloadItem` persists `container` and a one-time `layoutVersion`; old documents decode
  tolerantly (`container` inferred from the URL, layout `1`).
- Legacy completed manifest rows are repaired on load: playlist bytes dropped, row paused, user
  metadata kept. A manifest URL is rejected with HTTP 415 before any `.part` is created.
- `StreamRendition.container` exposes the same classification for enqueue-time gating.
- Both signed `signCookie` decoys and CloudFront `Resource` decoys are rejected in Swift and Go;
  `notice.mp4` and the `macdn.aoneroom.com/other/` shape remain covered.
- `fileSize` recurses into directory assets, so HLS/DASH working trees will account correctly.
- `CatalogResolver` gained an injectable reachability probe; the resolver tests no longer need a
  live gateway, and production still uses the four-second probe.
- The two catalog test suites are nested under one serialized suite so they cannot reset each
  other's stub routes.

### Verification

- `swift test` — **234 tests, 39 suites, 0 failures**.
- `go build ./... && go test ./... -race` — green.
- `xtool dev build` — `Build complete!`, app written to `xtool/Cinemacore.app`.

## T-010 · P1 background URLSession transfer engine

**Status:** implementation complete; tests and app build green. Commit deferred because the tree also
contains uncommitted built-in-provider work that must not be swept into a task commit.

### Landed

- One stable background session (`com.cinemacore.app.downloads`) with `sessionSendsLaunchEvents`,
  a serial delegate queue, and an app-delegate completion-handler handoff.
- `.part` stays the contiguous committed prefix; daemon bodies land in
  `.staging/<item>/<epoch>/chunk-N`. Absolute chunk indices survive relaunch, and a launch drains
  every contiguous staged chunk before re-enqueueing only missing ranges.
- A 10 GB item fits the default 32 MB × 512-task window, so suspension does not leave most of the
  file without a daemon task. The session's six-connection limit bounds actual network concurrency.
- Launch reconciliation reattaches only rows a process death demoted; user pauses cancel their
  stale task, orphan tasks are cancelled, and rows whose daemon work vanished stay paused.
- Pause keeps the epoch and staged bytes. Cancel rotates the epoch, cancels tasks, and deletes
  staging. Success and terminal failure also stop daemon work; terminal failure keeps staging for a
  later retry.
- Range-ignoring servers restart from zero and fall back to one whole-file daemon task. Short bodies,
  wrong `Content-Range`, non-2xx bodies, and cancelled tasks never enter the committed prefix.
- 258 Swift tests and the full Go suite are green; `xtool dev build` writes the device app.

### Remaining risk

- The daemon contract is exercised against fakes, not a live suspended device. T-017 owns the
  on-device suspend/relaunch/force-quit proof.
- HLS/DASH segment ingestion still belongs to T-012/T-014; this task provides the container-agnostic
  request/staging seam they will use.
- 2026-10-20T11:10:42.329Z — updated T-009: container model + manifest gates + signed-decoy fix; swift test 234 green, go test -race green, xtool build green
- 2026-10-20T11:10:42.378Z — done T-009
- 2026-10-20T11:11:56.608Z — claimed T-010 — P1: background URLSession transfer engine for MP4/HLS/DASH
- 2026-10-20T11:53:36.197Z — updated T-010: background URLSession engine, staged chunk resume, reattach reconciliation, app delegate wiring; 258 Swift tests green, Go suite green, xtool build green
- 2026-10-20T11:53:36.249Z — done T-010
- 2026-10-20T11:53:57.009Z — claimed T-011 — P1: progressive local asset server and play-while-downloading for MP4

## T-011 · P1 progressive local asset server

**Status:** implementation in progress. Three workers own disjoint files:

- loopback NIO server + range responses + socket tests (`ProgressiveAssetServer.swift`,
  `ProgressiveAsset.swift`, `ProgressiveAssetServerTests.swift`);
- MP4 box parser and bounded `moov` prefetch (`MP4Progressive.swift`,
  `MP4ProgressiveTests.swift`);
- app wiring: progressive asset registry, player source, background pause/PiP, minimal Downloads
  play gating (`ProgressiveDownloads.swift`, player/app screens).

The server is a real HTTP/1.1 endpoint bound to `127.0.0.1:0` with an unguessable path token. It
serves the growing `.part` as a clamped `206` prefix, retries a not-yet-written range with `503`,
and serves a prefetched `moov` from a separate cache file when the atom sits at the end of the MP4.
The player starts once the committed prefix reaches the readiness threshold; until then it streams
remotely while the background download continues. Leaving the foreground pauses playback unless PiP
is already active.

SwiftNIO 2.104 was added to `CinemacoreCore`; the stub API builds on Linux and the Darwin app.
- 2026-10-21T09:21:33.437Z — claimed T-021 — Player fullscreen surface stability and controls declutter
- 2026-10-21T09:21:33.493Z — done T-021: Stable single-surface fullscreen; safe-area chrome; orientation policy helper; options sheet declutter; xtool build green (21.09s); 352/354 Swift tests pass, 2 pre-existing HEVC failures

## T-021 · Player fullscreen surface stability and controls declutter

**Status:** implementation complete; `xtool dev build` green. On-device rotation, safe-area bleed and
PiP behaviour remain unverified because this host has no simulator or device.

### Landed

- `PlayerScreen` keeps one `VStack` with `playerBox` first and conditionally hides the details, so
  toggling fullscreen no longer moves `PlayerLayerView` in the view tree or rebuilds its
  `AVPlayerLayer` / PiP controller.
- `surfaceCanvas` owns `.ignoresSafeArea()`; the chrome stays in the safe-area-sized stage, so
  fullscreen fills the display without putting controls under the notch or home indicator.
- `PlayerOrientation` centralises the iOS 16+ path: the `AppDelegate` mask reads
  `supportedOrientations`, `setNeedsUpdateOfSupportedInterfaceOrientations()` refreshes it, and
  `requestGeometryUpdate` asks for landscape/portrait. No `UIDevice.setValue` anywhere.
- `PlayerModel.enterTerminalState` resets fullscreen and orientation for `.empty`, `.failed` and
  `.locked`, so an error screen never stays sideways.
- Display, Output (PiP/AirPlay) and Download moved into `PlayerOptionsSheet`; transport and
  fullscreen stay on the picture. Download runs from the sheet's `onDismiss` to avoid presenting an
  alert over a sheet.

### Verification

- `xtool dev build` — `Build complete! (21.09 secs)`, app written to `xtool/Cinemacore.app`.
- `swift test` — 354 tests / 55 suites; 352 passed. The two failures are the pre-existing
  `HEVCRewriteTests.swift` HTTP cases at lines 134 and 164, unrelated to this task.
- 2026-10-25T08:14:28.507Z — registered (opencode)
- 2026-10-25T08:17:59.955Z — claimed T-028 — StreamHype works without a hand-pasted TMDB key
- 2026-10-25T08:18:00.031Z — updated T-028 -> review: TMDB_API_KEY > Info.plist > StreamHype public key; Settings/README/ADR updated; 411 Swift tests, go test, xtool build green; live /configuration returns 200; device not available
- 2026-10-25T08:18:54.409Z — done T-028: TMDB_API_KEY > Info.plist > StreamHype public key; Settings/README/ADR updated; live /configuration 200; 411 Swift tests, go test, xtool build green; device catalog load unverified
- 2026-10-25T09:33:14.425Z — claimed T-029 — Hiding the player chrome must not resize the landscape picture
- 2026-10-25T09:33:14.467Z — updated T-029 -> review: player box now uses a custom Layout: fullscreen takes the whole proposal, portrait stays 16:9, and overlays can no longer drive the surface's ideal ratio; xtool build green; device tap test pending
