# mobile/android

Kotlin + Jetpack Compose client. The Android implementation is a behavioural port of the iOS app, not
a line-by-line translation: Android uses Media3/ExoPlayer, a gateway-first data layer, and Android
background-download rules.

This README is the **Android source of truth**. Do not document a feature here until it exists in
`app/src/main`.

---

## Status (verified 2026-10-25)

| Check | Result |
|---|---|
| `./gradlew :app:assembleDebug` | Builds the debug APK |
| Android Studio | Opens this directory directly; Gradle sync succeeds |
| Unit tests | `./gradlew :app:testDebugUnitTest` |
| Device/emulator run | Blocked until an AVD or device exists |
| Gateway integration | Gateway at `10.0.2.2:8080` from the emulator |

Toolchain setup of record is [`ANDROID.md`](../../ANDROID.md): JDK 17, Android CLI, SDK platform
**37.0**, build-tools 36.0.0. Use `android sdk`; `sdkmanager` is deprecated. The Gradle wrapper **is
checked in**; do not regenerate it.

```bash
cd mobile/android
./gradlew :app:assembleDebug
./gradlew :app:installDebug
adb shell am start -n com.cinemacore.app/.MainActivity
```

Open `mobile/android` (not the repository root) in Android Studio. CLI launcher:
`studio /home/sammy/Desktop/Projects/mov/cinemacore/mobile/android` or simply `studio .` from this
directory.

Before changing insets, PiP, the player surface, foreground downloads, or the Compose theme, read
[`PLATFORM_NOTES.md`](PLATFORM_NOTES.md). It records the current Android 15/16 enforcement rules and
the APIs this app relies on, with official sources.

---

## Architecture

```
app/src/main/java/com/cinemacore/app/
  CinemacoreApp.kt              Application + composition root (AppContainer)
  MainActivity.kt               Edge-to-edge Compose entry; notification permission
  AppContainer.kt               Manual constructor DI at the app boundary
  data/
    api/                        GENERATED OpenAPI client (do not edit)
    GatewayCatalogRepository.kt Gateway-backed CatalogRepository
    StreamHypeCatalogRepository.kt Direct TMDB catalog + web-embed playback
    DemoCatalogRepository.kt    Offline fallback catalog
    CatalogResolver.kt          Source selection + fallback + source note
    SettingsStore.kt            JSON settings on disk (DataStore-free, mirrors iOS)
    LibraryStore.kt             Watchlist, history, resume points as JSON
    DownloadEngine.kt           Direct-progressive download queue
    DownloadService.kt          Foreground service that keeps the queue alive
    SubtitleCache.kt            Caption fetch/cache + SRT typing
  domain/
    CatalogRepository.kt        Boundary every screen talks to
    Models.kt                   Android-only state models (library/download/settings)
    PlaybackPolicy.kt           Rendition ranking + container classification
    LoadState.kt                Idle/Loading/Loaded/Empty/Failed/Locked
  ui/
    AppRoot.kt                  Five-tab shell, detail route, back handling
    theme/                      Cinematic Obsidian tokens, Material 3 mapping
    components/                 Rails, posters, chips, state views, bottom sheets
    home/ search/ detail/       Catalog screens + ViewModels
    library/ downloads/         Watchlist, history, offline queue
    settings/ manage/ docs/     Source setup, rails, diagnostics
    player/                     PlayerActivity, Media3 surface, controls, PiP
```

### Data layer rules

- `contracts/openapi.yaml` is the wire source of truth.
- **`data/api/` is generated. Never hand-edit it.** Regenerate with:

  ```bash
  cd mobile/android
  ./openapi/generate.sh
  ```

  The script uses OpenAPI Generator's Kotlin `jvm-retrofit2` target with
  `kotlinx.serialization`, package `com.cinemacore.app.data.api`. Generated models keep the contract's
  field names. If the contract changes, regenerate and fix mapping/tests in the same change.
- Screen code never consumes generated Retrofit models directly. `CatalogRepository` maps them to
  domain types and returns typed `CinemacoreError`s.
- Android uses the **gateway** for the MovieBox catalog. The iOS direct native signing/session/stream
  recovery path is not ported; do not reimplement provider protocol replay in Kotlin.
- StreamHype is the exception: Android talks to TMDB directly and opens `kind: web` embeds in a
  WebView. Key precedence is the same as iOS: user setting > `TMDB_API_KEY` build/env value >
  StreamHype's published client key. It works without setup.
- A user-entered TMDB key overrides the public fallback.
- `kind: web` must never reach ExoPlayer or the download queue.

### Playback rules

- Media3/ExoPlayer handles progressive MP4, HLS and DASH. Do not port the iOS HEVC sample-entry
  rewrite; Media3 handles codec selection on Android.
- The player surface is one `PlayerView`/`SurfaceView` hierarchy. Hiding the HUD must not resize,
  crop, or re-create the video surface.
- Fullscreen hides system bars and may rotate; it does not swap the player surface.
- PiP uses the activity's PiP mode. Playback state survives entering/leaving PiP.
- Quality is a provider list of URLs, not an ExoPlayer track group. Selecting a quality re-prepares
  the player and seeks back to the previous position.
- Language/dub entries are separate provider subject ids; selecting one re-resolves playback.
- Subtitles are fetched to the app cache, SRT is handed to Media3 with the correct MIME type, and the
  player re-prepares with the chosen side-loaded track.
- Resume points and history are written locally; auto-play-next respects the setting.

### Download rules

The Android build ports the **current iOS behaviour**, not an aspirational version:

- Direct progressive files only. HLS/DASH downloaders are refused with an explicit message.
- Queue persists as JSON. Pause, resume, retry, cancel, remove, remove-completed.
- A foreground service keeps active transfers alive. Android may still stop work under system
  pressure; the queue resumes on the next launch.
- Completed files play from `filesDir/downloads`.
- There is **no 10 GB cap, 5 GB warning or 2 GB block**. Do not invent one.
- No automatic deletion.
- StreamHype web titles cannot be downloaded.

---

## Local state

`SettingsStore` and `LibraryStore` write JSON to the app's `filesDir`. This mirrors the iOS
`FileLibraryStore` and keeps the data inspectable. History is capped at 300 entries. The stores are
injected through `AppContainer`; no feature reaches a global singleton.

Data kept locally:

- source mode, gateway URL, TMDB key, preferred language
- hidden rails + rail order
- playback speed, auto-play-next
- watchlist entries
- history + resume points
- download queue

---

## Build and test

```bash
cd mobile/android

./gradlew :app:assembleDebug          # APK: app/build/outputs/apk/debug/app-debug.apk
./gradlew :app:testDebugUnitTest      # JVM tests
./gradlew :app:lintDebug              # Android lint
```

Gateway:

```bash
# repo root
go run ./cmd/cinemacore
```

- Emulator → `http://10.0.2.2:8080`
- Physical device → `http://<host-LAN-IP>:8080`

The app falls back to the bundled demo catalog when the gateway does not answer and labels the active
source on Home and in Settings.

---

## Conventions

Follow `rules/02-kotlin-android.md` plus the rules above:

- `val` by default, immutable state, no `!!`, no `GlobalScope`.
- State flows down, events flow up. Composables take state + lambdas, not ViewModels.
- Every screen renders loading, empty, error, partial and success states.
- No hardcoded user-facing strings in composables; use `strings.xml`. No raw brand colors outside
  `ui/theme`.
- Every `LazyRow`/`LazyColumn` item has a stable `key`.
- A behaviour change ships a JVM test (policy, store, queue, mapping) where the platform is not
  required.
- If it is not in this README and not in code, it is not shipped.
