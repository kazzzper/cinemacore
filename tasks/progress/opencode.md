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
