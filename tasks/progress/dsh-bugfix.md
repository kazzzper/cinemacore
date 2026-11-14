# dsh-bugfix

- 2026-10-30T19:48:15.810Z — registered (codex)
- 2026-10-31T08:16:17.092Z — updated T-029 -> review: iOS subtitle fix committed: per-episode resourceId keying (442 core tests green, app builds); feature tracking shipped; provider switching fixed. Android port on hold per user.
- 2026-10-31T08:16:17.171Z — updated T-030 -> review: iOS: episode subtitles now keyed by own resource id; community-English default for episodes; per-episode download buttons; player back button; scrubber; provider switch without re-bootstrap. 442 tests pass, xtool build clean.
- 2026-11-14T06:37:10.810Z — claimed T-031 — StreamHype player must have an exit on iOS
- 2026-11-14T06:37:10.886Z — updated T-031 -> review: back button overlay on the web-embed branch; xtool dev build green (461s)
- 2026-11-14T06:37:16.651Z — claimed T-020 — Subtitle pipeline: correct episode keying + source picker
- 2026-11-14T06:37:16.818Z — updated T-020 -> doing: Go core ported and green (go build/vet/test -race); Android data layer keyed per episode; UI: per-episode download button, feature tracker/screen
- 2026-11-14T06:41:44.170Z — done T-031: web-embed branch overlays a visible labelled Back button on a scrim; native chrome untouched; xtool dev build green; committed 0976c84
- 2026-11-14T06:41:44.279Z — updated T-020 -> doing: Go port committed ef61851 (build/vet/tests green; per-episode resourceId keying + season in the signature). Android sources ported in the shared tree: DirectMovieBoxRepository caption keying, episode-scoped SubtitleCache keys, per-episode download button, FeatureTracker + FeatureTrackingScreen + Settings entry, playback/download/PiP events. Gradle verification and the Android commit are delegated to the agent that owns the build, per instruction — the tree also holds that agent's uncommitted work.
- 2026-11-14T07:02:18.443Z — claimed T-033 — iOS: download quality picker, progressive readiness, hev1 repair on failure, StreamHype resume
- 2026-11-14T07:02:24.529Z — updated T-033 -> review: iOS: download quality sheet resolves the ladder before queueing; ProgressiveAssetStore.availableBytes no longer clamps to an unknown total (play-while-downloading restored); hev1 repaired before a .failed item is reported; StreamHype embed injects a seek/report script and stores its position. swift test 443 green, xtool build green.
- 2026-11-14T09:30:19.857Z — updated T-034 -> review: Android StreamHype resume ported: injected seek/report script re-asserts the target until the page's clock reaches it, startAtMs wired from the stored resume point, webProgress writes the same ResumePoint rows as native. key(webGeneration) rebuilds the web view when a second episode resolves to the same URL. compileDebugKotlin + testDebugUnitTest green (231 tests).
- 2026-11-14T09:33:32.433Z — updated T-035 -> review: downloadedCopy() in PlayerViewModel.load: a completed direct file for this episode now plays immediately instead of waiting on play-info and failing offline.
- 2026-11-14T09:33:32.498Z — updated T-033 -> done: iOS download quality + web resume; seek re-asserted across media events and polls so embed players cannot overwrite it, cross-episode clock reset, webPlaybackGeneration rebuild. swift test 443 green, xtool dev build green.

## StreamHype resume + instant start

- iOS seek was a single `loadedmetadata` shot, which embed players overwrite when they create or
  reload their `<video>`; it is now re-asserted on every media event and by a 400 ms poll until the
  page's own clock reaches the target, and it re-arms when the element is replaced.
- iOS no longer carries the previous episode's clock or write throttle into the web branch (which
  returns before `rebuild`), and `webPlaybackGeneration` keys the web view so a second episode on
  the same embed URL still reloads and seeks.
- Android: same script logic, `startAtMs` from the stored resume point, `webProgress` writing the
  same `ResumePoint` rows as the native player, `key(webGeneration)` rebuild on URL reuse.
- Android: a finished download now opens before `repository.play`, so a downloaded episode starts
  instantly and works offline. iOS already did.
- Verified: `swift test` 443 green · `xtool dev build` green · `:app:compileDebugKotlin` green ·
  `:app:testDebugUnitTest` 231 green.
