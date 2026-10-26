# Android platform notes

**Purpose.** This is the Android implementation's checklist of correct, current
APIs and the traps that have already shaped this app. It is not a tutorial and it
does not replace the code. Every item below was checked against the Android
developer documentation linked at the bottom (fetched 2026-10-25) and the
versions pinned in `gradle/libs.versions.toml`.

Read this before changing edge-to-edge layout, the player, PiP, downloads,
permissions, insets, or the Compose theme.

---

## Version facts that are easy to get wrong

| Item | This app | Consequence |
|---|---|---|
| `compileSdk` | **37** | Compose 1.12 / BOM `2026.08.00` is compiled against API 37. |
| `targetSdk` | **36** (Android 16) | Platform enforcement below applies to this app now, not "one day". |
| `minSdk` | 24 | Every API-level branch must be guarded. |
| Compose BOM | `2026.08.00` | Resolves Compose UI/foundation **1.12.0**, Material3 **1.4.0**. |
| Kotlin / AGP | **2.2.10** / **9.1.1** | Compose compiler is the Kotlin plugin; do not add `kotlinCompilerExtensionVersion`. |
| Activity Compose | 1.10.1 | `enableEdgeToEdge()` and `rememberLauncherForActivityResult` are available. |
| Media3 | **1.11.1** | `PlayerView`, MediaSession, HLS/DASH, OkHttp datasource. |
| JDK | **17** for the Gradle launcher | The daemon is pinned to Java 25 by `gradle/gradle-daemon-jvm.properties`. |
| Android Studio | Open `mobile/android` directly | The repo root is not an Android project. |

Do not "fix" a dependency by mixing Compose BOM versions. Do not change
`targetSdk` without re-reading the behavior-change sections for that API level.

---

## Edge-to-edge is mandatory, not cosmetic

Android 15 enforced edge-to-edge for apps targeting API 35+. For apps targeting
**API 36**, `R.attr.windowOptOutEdgeToEdgeEnforcement` is deprecated and disabled;
there is no opt-out. The app must draw behind the system bars and consume insets
itself.

Correct pattern used by `MainActivity`:

```kotlin
enableEdgeToEdge()
WindowCompat.getInsetsController(window, window.decorView).apply {
    isAppearanceLightStatusBars = false
    isAppearanceLightNavigationBars = false
}
```

Then:

- Use `Scaffold`'s insets (the default is the safe drawing inset) for tabbed
  content. Do **not** also add `statusBarsPadding()`/`navigationBarsPadding()`
  around the same content; that double-pads it.
- Use `WindowInsets.safeDrawing` (or `safeContent`) for full-screen manual
  layouts.
- Inside `LazyColumn`, apply insets as `contentPadding`, not as a parent
  `padding`, so the last row can scroll clear of the navigation bar.
- Use `imePadding()` on forms and sheets, and consume it if a child already
  handles the keyboard (`Modifier.consumeWindowInsets(WindowInsets.ime)`).
- A `ModalBottomSheet` adds its own navigation-bar inset; do not add another.
  In Material3 1.4, keep `sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)`
  for player options so a drag does not leave the sheet half-open over video.
- Draw the app background edge-to-edge, but keep tappable chrome inside safe
  insets. This is the same rule the iOS player uses: the video canvas can bleed,
  the buttons cannot.

**Player-specific:** fullscreen hides `WindowInsetsCompat.Type.systemBars()` with
`WindowCompat.getInsetsController(...).hide(...)`. Restore them on exit. Do not
use `window.setDecorFitsSystemWindows(false)` as a substitute for Compose insets;
it only controls whether the framework decor fits, not what your composables pad.

---

## Predictive back (target API 36)

For apps targeting API 36, predictive back animations are on by default and
`onBackPressed()` is not called. Use the supported back APIs:

- `BackHandler` from `androidx.activity.compose` (this app's tab/detail stacks).
- `OnBackPressedDispatcher` if you need a non-Compose callback.
- Never override `Activity.onBackPressed()`.
- Do not add `android:enableOnBackInvokedCallback="false"` as a shortcut.

When adding another nested stack, keep the "back closes the top thing first"
order: modal → player options sheet → fullscreen → detail → tab root.

---

## Large screens, rotation, and the player

Android 16 ignores `screenOrientation`, `resizeableActivity`, and aspect-ratio
restrictions on displays whose smallest width is **≥ 600dp**. That includes
tablets, unfolded foldables, and desktop windowing.

Consequences for this app:

- Never assume the player is landscape just because you requested landscape.
- Do not make the video layout depend on `Configuration.orientation` as the only
  signal. Use the available window size (`BoxWithConstraints`) and a user
  fullscreen state.
- `android:resizeableActivity="true"` is correct; the player must survive a
  window resize without recreating the ExoPlayer surface.
- The Activity declares `configChanges` for orientation/screen size so Compose is
  not restarted for a rotation. Do not add `keyboard|navigation` unless the UI
  actually handles them.
- On phones, the player can still request landscape when the user taps the
  fullscreen button, but that request must be treated as a hint. On large
  screens, the system may ignore it and the UI must still fill the window.

---

## Player: keep one surface, one player

Media3 1.11 has two Compose UI paths:

- `media3-ui-compose` (`PlayerSurface`, `ContentFrame`, state holders).
- `media3-ui-compose-material3` (`Player`, `MiniController`).

This app deliberately uses the **View-based `PlayerView` inside one `AndroidView`**
because it needs a stable surface identity and custom controls. That is supported
and is not legacy. The rules:

- Compose the `AndroidView` **once**. Do not put it in an `if (fullscreen)` branch
  or key it on `controlsVisible`: that disposes the View, tears down the surface,
  and reattaches the player. It causes black frames, PiP glitches, and audio
  restarts.
- `PlayerView.useController = false`; draw the app's own controls over it.
- Hiding the HUD changes only the overlay. It must not change the video's
  `Modifier`, aspect ratio, or parent. A controls row measuring inside the same
  `Column` as the video can change the video's height; put chrome in a `Box`
  overlay instead.
- `AspectRatioFrameLayout.RESIZE_MODE_FIT` letterboxes; `RESIZE_MODE_ZOOM` fills
  (crops). Both preserve the same surface. The user's "fill screen" preference
  changes `resizeMode`, not the view hierarchy.
- Quality changes replace the `MediaItem`/`MediaSource` and seek back to the last
  position. They do not add another surface.
- `kind = web` (StreamHype) uses `WebView` only. Never put an embed page URL into
  ExoPlayer or the download queue: it is HTML, not media.
- Side-loaded subtitles: fetch to a file, set
  `MediaItem.SubtitleConfiguration` MIME `text/vtt`, then re-prepare and seek.
  Do not hand ExoPlayer a remote URL that may answer HTML.
- Media3 handles HEVC, HLS, and DASH on Android. Do **not** port the iOS `.mpd`
  filtering or the `hev1` → `hvc1` sample-entry rewrite; that is an AVFoundation
  workaround, not an Android requirement.

### PiP

- Manifest: `android:supportsPictureInPicture="true"` and the activity handles
  layout config changes (both already present).
- API 31+: `PictureInPictureParams.Builder().setAutoEnterEnabled(true)` gives a
  smooth gesture transition. Enable it only while playing; set it false when
  paused. On older APIs, call `enterPictureInPictureMode()` from
  `onUserLeaveHint()`.
- Always set an aspect ratio (16:9 for this player) and, when available, a
  `sourceRectHint` from the video view's global bounds. Android 12+ uses the hint
  for the enter/exit animation.
- Android 15 adds `onPictureInPictureUiStateChanged()`; hide title/next-episode
  chrome as soon as `isTransitioningToPip` is true. Keep using
  `onPictureInPictureModeChanged()` to hide the rest.
- Do not pause playback in `onPause()` blindly. If `isInPictureInPictureMode` is
  true, playback must continue. On leaving the app without PiP, background audio
  is the media session's job.

### Background playback

Use a `MediaSessionService` with `android:foregroundServiceType="mediaPlayback"`
and the `androidx.media3.session.MediaSessionService` intent filter. A plain
`Service` with a notification is not a media session and will not get transport
controls. `MediaSessionService` publishes a MediaStyle notification from the
session automatically. The player and session must outlive the activity; this is
why `AppContainer` owns one `ExoPlayer` per process and `PlayerActivity` only
attaches a view.

---

## Foreground services and downloads (Android 15+)

`dataSync` foreground services may run for a **total of 6 hours in any 24-hour
period**. The limit is shared by every `dataSync` service in the app. When it is
exhausted, the system calls `Service.onTimeout(int, int)`; the service has a few
seconds to call `stopSelf()` or the system throws.

The download service therefore:

- starts only from a user action while the app is foreground;
- uses `FOREGROUND_SERVICE_DATA_SYNC`;
- implements `onTimeout` and pauses the queue before stopping;
- does not auto-resume a timed-out queue in the background.

For work that must survive longer, Android's recommended alternative is a
user-initiated data-transfer job (`JobInfo.Builder.setUserInitiated(true)` with
WorkManager), not an unbounded service. This build deliberately keeps the simple
foreground queue and documents the platform limit.

Also:

- Android 13+ requires `POST_NOTIFICATIONS` for the notification to appear in the
  drawer. The foreground service may still start without it; the user sees it in
  Task Manager instead. Do not make downloads depend on the permission being
  granted.
- Notification channels are immutable after creation; changing importance needs
  a new channel id.
- `FOREGROUND_SERVICE` and the type-specific permission are separate; declaring
  only one crashes `startForeground`.
- Starting a foreground service from the background is restricted. Our start
  points are a tap in Detail/Player/Downloads, which are foreground interactions.

---

## Notifications and permissions

- Runtime permission: `POST_NOTIFICATIONS` (API 33+), requested by
  `MainActivity` with `rememberLauncherForActivityResult`.
- `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_DATA_SYNC`, and
  `FOREGROUND_SERVICE_MEDIA_PLAYBACK` are normal/foreground permissions and must
  match the service types exactly.
- `INTERNET`, `ACCESS_NETWORK_STATE`, and `WAKE_LOCK` are normal permissions.
- `usesCleartextTraffic="true"` is intentional for a LAN gateway
  (`http://10.0.2.2:8080`). It is a development convenience; a release build
  should use a network-security-config allowlist rather than global cleartext.

---

## WebView (StreamHype)

StreamHype is a web embed, not a media URL. The minimum correct setup:

```kotlin
settings.javaScriptEnabled = true
settings.domStorageEnabled = true
settings.mediaPlaybackRequiresUserGesture = false
```

- Hardware acceleration is on by default at the application level. Do not disable
  it for the player activity.
- `setMediaPlaybackRequiresUserGesture(false)` may let the embed autoplay; if the
  embed still requires a tap, show its own UI rather than faking transport
  controls.
- Keep navigation inside the WebView with a `WebViewClient`; do not let an
  arbitrary redirect open an external browser without a user tap.
- The embed owns its own quality/subtitle/clock UI. Do not overlay ExoPlayer
  controls on it.
- Never pass a `WebView` URL to `DownloadEngine` or `ExoPlayer`.

---

## Compose and Material3 gotchas

- **Stable keys:** every `LazyRow`/`LazyColumn`/`LazyVerticalGrid` item has a
  stable `key`. Without one, focus and scroll position jump when the list
  refreshes.
- **State collection:** prefer `collectAsStateWithLifecycle()` for flows that
  should stop outside the foreground (`lifecycle-runtime-compose` is present).
  `collectAsState()` is acceptable for UI-owned state that should keep observing.
- **`rememberSaveable`** for tab selection and user-entered drafts; plain
  `remember` loses them on process death.
- **No `fillMaxSize()` inside a scrolling `Column`**: it measures against the
  infinite constraint and either crashes or collapses. Use `heightIn`/`weight`.
- **`Scaffold` insets:** pass the `PaddingValues` to content exactly once. Nested
  `Scaffold`s are almost always a bug.
- **Material3 1.4:** `HorizontalDivider` (not `Divider`); `ModalBottomSheet` uses
  `sheetState`; `Surface(onClick=...)` is stable and gives a proper touch target.
- **Pull-to-refresh:** `PullToRefreshBox` lives in Material3 1.4. If a screen
  uses it, keep the content scrollable and give the indicator its own inset.
- **Images:** Coil 2.7 `AsyncImage` needs an explicit placeholder/error painter;
  otherwise a slow poster is a black rectangle. Use the shared `RemoteImage`.
- **Text scaling:** use `MaterialTheme.typography` and `sp`, never fixed pixel
  heights for text rows. Test at 200% font scale.
- **Touch targets:** 48dp minimum for icon-only controls (Android, not Apple's
  44pt). `IconButton` already enforces it; custom `Surface` rows do not.
- **Typography:** the theme is dark-only. Do not add a light scheme "for
  completeness"; the source palette has no light variant.
- **Edge swipe conflicts:** in the player, a horizontal drag belongs to the seek
  bar; vertical edge drags for brightness/volume must not steal the system back
  gesture. Use the middle third for fullscreen-exit gestures, as iOS does.

---

## Build, lint, and test traps

- The Gradle wrapper is checked in. Do not regenerate it or switch to the system
  Gradle.
- `compileSdk 37` needs the platform installed; the CLI is `android sdk`, not the
  deprecated `sdkmanager`.
- Android Studio must open `mobile/android`, not the repository root.
- Unit tests run on the JVM with `testOptions.unitTests.isReturnDefaultValues =
  true`; do not call Android framework methods from domain tests.
- `data/api` is generated. Regenerate with `./openapi/generate.sh`; never edit
  generated files by hand.
- 16 KB page-size devices are the Play requirement for native code. This app has
  no native `.so` today, but do not add a native dependency that ships
  unaligned libraries without checking.
- Cleartext HTTP is blocked by default on modern Android except for the
  intentional gateway exception above.

---

## Sources (fetched 2026-10-25)

- Edge-to-edge in Compose: <https://developer.android.com/develop/ui/compose/system/setup-e2e>
- Android 16 behavior changes (edge-to-edge, predictive back, large screens):
  <https://developer.android.com/about/versions/16/behavior-changes-16>
- Foreground service timeouts:
  <https://developer.android.com/develop/background-work/services/fgs/timeout>
- Picture-in-Picture:
  <https://developer.android.com/develop/ui/views/picture-in-picture>
- Media3 Compose UI:
  <https://developer.android.com/media/media3/ui/compose>
- Media3 background playback / MediaSessionService:
  <https://developer.android.com/media/media3/session/background-playback>
- Notification runtime permission:
  <https://developer.android.com/develop/ui/views/notifications/notification-permission>
- `WebSettings.setMediaPlaybackRequiresUserGesture`:
  <https://developer.android.com/reference/android/webkit/WebSettings#setMediaPlaybackRequiresUserGesture(boolean)>
- Predictive back:
  <https://developer.android.com/guide/navigation/custom-back/predictive-back-gesture>
