# mobile/ios

The native iOS client. SwiftUI app + a platform-free Swift package that holds models, networking,
state machines and playback policy.

This README is the **iOS source of truth**. If code and this file disagree, the code is wrong or this
file needs updating in the same change. Do not describe planned work as shipped.

---

## Status (verified 2026-10-25)

| Check | Result |
|---|---|
| `swift test` in `CinemacoreCore` | **411 tests / 62 suites pass on Linux** |
| `xtool dev build` | Type-checks and links the unsigned `.app` against the iOS SDK |
| Device run | **Never verified.** No iPhone has been attached; `xtool dev run` has never run. |
| Playback | Wired, including progressive MP4, HLS/DASH manifests, PiP and captions. **Never executed on hardware.** |
| Downloads | Direct progressive files download in the background and play offline. HLS/DASH downloaders are deliberately refused. |

The app targets **iOS 17+** and is dark-only. The brand's "light" palette is byte-identical to its
dark palette, so no light theme exists.

---

## Architecture

```
CinemacoreCore/                 Swift package. No SwiftUI, UIKit or AVFoundation.
  Sources/CinemacoreCore/
    Models.swift                Domain models. Wire fields + presentation extensions.
    APIClient.swift             Gateway HTTP client, typed errors, timeouts.
    CatalogRepository.swift     Repository boundary used by every screen.
    RemoteCatalogRepository...  Gateway-backed repository (`/v1/*`).
    MovieBoxRepository.swift    Direct MovieBox source (native signing/session/stream recovery).
    StreamHypeRepository.swift  Direct TMDB catalog + `kind: web` embed playback.
    CatalogResolver.swift       Source selection + fallback to the bundled fixture.
    FixtureCatalogRepository    Offline bundled demo catalog (non-playable `.test` URLs).
    ViewModels.swift            Screen state holders (Observable, no SwiftUI).
    Downloads.swift             Queue model, limits and engine.
    BackgroundTransfer.swift    Background `URLSession` transport.
    ProgressiveDownloads.swift  Loopback server for files still downloading.
    Subtitles.swift             Provider/community caption handling.
    LibraryStore.swift          Watchlist, history and settings on disk.
    PlaybackSourcePolicy.swift  Ranked source selection + audio codec rules.
    HEVC*.swift                 MP4 sample-entry rewrite for HEVC compatibility.
    DesignTokens.swift          Palette, spacing, type roles (testable on Linux).

Cinemacore/                     SwiftUI app target, built by xtool.
  Sources/Cinemacore/
    CinemacoreApp.swift         App entry, splash, scene phase.
    Navigation/                 Root tabs, routes, shared AppModel.
    Screens/                    Home, Search, Detail, Watchlist, Downloads, History, Settings, ...
    Player/                     AVPlayer surface, controls, options sheet, PiP, web player.
    Downloads/                  Background URLSession wiring + progressive server integration.
    Components/                 Rails, posters, chips, state views, selection sheets.
    Theme/                      Maps Core tokens to SwiftUI.
```

Why two packages: there is no iOS Simulator on Linux, and `swift test` in a single package tries to
build the SwiftUI target and fails with `no such module 'SwiftUI'`. Splitting them makes the boundary
compiler-enforced. See `docs/adr/0004`.

---

## Data sources

Settings → Data source chooses one of three:

1. **Built-in (direct)** — `MovieBoxRepository`, talking to MovieBox directly with native signing,
   session recovery and stream recovery. No gateway required.
2. **StreamHype (web)** — TMDB supplies the catalog; playback is the provider's `kind: web` embed.
   The embed is opened in an in-app `WKWebView`, never handed to `AVPlayer`.
3. **Gateway server** — the Go gateway in this repository. The app probes `/health` and falls back to
   the bundled demo catalog when nothing answers.

TMDB key precedence for StreamHype is, in order:

1. `TMDB_API_KEY` environment variable
2. `TMDBAPIKey` in `Info.plist`
3. StreamHype's published client key (`90b2cae8d7161e8ba0f3836240d7d352`)

The public fallback is why StreamHype works without setup. A user/deployment key still wins. See
`core/provider/streamhype/streamhype.go` and `docs/streamhype-network-map.md`.

Downloads and offline play are not offered for StreamHype (`kind: web`) titles. Native protocol replay
is forbidden by ADR 0007.

---

## Playback contract

- `StreamRendition.kind == "web"` **must** go to `WebStreamView`. It must never reach `AVPlayer` or the
  download queue.
- Direct media may be progressive MP4, HLS (`.m3u8`) or DASH (`.mpd`). Classify with
  `MediaContainer`, not just the URL extension.
- Source ranking and audio-codec rejection live in `PlaybackSourcePolicy`. Do not re-rank in a view.
- The player surface is **one stable `AVPlayerLayer` hierarchy** (`PlayerBoxLayout`). Toggling the HUD
  or fullscreen must not rebuild or resize the player. Hiding controls reveals picture; it never slims
  or letterboxes the video differently.
- The player owns six selection surfaces: language/dub, quality, audio track, subtitles, speed, and
  episodes. Changing a language re-resolves the separate provider subject id.
- PiP is supported. Background playback and the Now Playing bridge are wired.
- Resume position, watch history and auto-play-next are persisted locally.

**HEVC caveat:** the direct MovieBox path may return HEVC in MP4. The iOS app inspects the moov/sample
entry and may rewrite the sample entry for playable HEVC. Android/Media3 does not need that iOS
workaround; do not port it.

---

## Downloads: exact behaviour

Implemented:

- Direct progressive assets only (`mp4`, `m4v`, `mov`, or unknown treated as a direct file).
- Background `URLSession` transfer; the queue survives app suspension.
- Pause, resume, retry, cancel, remove, resume all, pause all, remove completed.
- Files land in the app sandbox. Completed files play offline.
- In-progress direct downloads can be played through a loopback HTTP server while bytes grow.
- Provider captions are stored beside a finished download when available.

Not implemented / deliberately refused:

- HLS and DASH downloads are refused with an explicit "downloader is not enabled in this build"
  message. A manifest is a recipe, not a file.
- There is **no 10 GB cap, 5 GB warning or 2 GB block** in the current iOS build. Do not claim one.
- There is no automatic deletion or eviction policy.
- StreamHype web titles cannot be downloaded.

---

## Local state

`FileLibraryStore` owns watchlist, history and settings as JSON in the app sandbox. History is capped
at 300 entries. Settings include source mode, gateway URL, preferred language, hidden rails, category
order, playback speed, auto-play-next and download sort/grouping.

---

## Commands

```bash
# Logic tests (Linux, no simulator)
cd mobile/ios/CinemacoreCore
swift test

# App build (needs xtool + Apple SDK)
cd mobile/ios/Cinemacore
xtool dev build
xtool dev build -c release --ipa

# Device run (needs a connected iPhone, Developer Mode, xtool auth)
xtool dev run
```

Point a physical device at a gateway with Settings → Gateway URL, e.g. `http://192.168.1.20:8080`.
`127.0.0.1` on the phone is the phone itself.

---

## Rules for agents

- **Do not invent features.** If it is not in this README and not in code, it is not shipped.
- Do not add a light theme, a download cap, HLS/DASH downloading, or direct native protocol replay
  without a decision record and tests.
- Keep `CinemacoreCore` free of SwiftUI/UIKit/AVFoundation imports.
- Add a failing test for every behaviour change; the suite runs on Linux and must stay green.
- Never put a `kind: web` URL into `AVPlayer`.
- Keep the player surface stable when the HUD or fullscreen changes.
- Update this README in the same change when a feature, limit or source rule changes.
