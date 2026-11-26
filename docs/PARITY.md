# Platform parity — iOS ⇄ Android

The live matrix behind [rule 09](../rules/09-platform-parity.md). Every user-visible feature gets a
row; a change to a feature updates its row in the same commit.

Legend: **✅** shipped · **🟡** partial / different behaviour · **⬜** missing (parity task linked)

| Feature | iOS | Android | Notes |
|---|---|---|---|
| Splash + app icon | ✅ | ✅ | Android: `SplashScreen` + Android 12 attrs, iOS icon densities ported |
| Source picker (Built-in / StreamHype / Gateway / Demo) | ✅ | ✅ | Android keeps the previous catalogue on screen while switching |
| Provider switch keeps navigation | ✅ | ✅ | Screens re-key on `repositoryGeneration` |
| Home rails + featured | ✅ | ✅ | |
| Home: Continue Watching rail | ✅ | ✅ | App-owned: built from the device's resume points, newest first, one row per title, and resumable only. A provider session cannot remove it. Listed as a flag in Manage categories, so it can be hidden and re-enabled |
| Home rail order + hidden rails | ✅ | ✅ | The saved Manage categories order now applies on Home on both platforms (it used to be stored but ignored) |
| Home pull-to-refresh | ✅ | ✅ | iOS `.refreshable`; Android `PullToRefreshBox` — the reload icon is gone |
| Search + suggestions | ✅ | ✅ | |
| Detail: seasons, episodes, dub switch, download | ✅ | ✅ | Per-episode download button on both |
| Downloads: queue, pause/resume, local playback | ✅ | ✅ | Android `DownloadService` (foreground dataSync) |
| Downloads: library, seasons, and episodes | ✅ | ✅ | A series is one row that opens its seasons and episodes, Netflix-style; iOS shows a flat title library with an inline season picker, Android keeps its grouping menu. An old stored "ungrouped" default is migrated once. |
| Progressive playback of an in-progress download | ✅ | ⬜ | iOS: loopback range server over `.part`; readiness no longer depends on a known total size; Android plays only finished files — T-032 |
| A finished download starts without a provider round trip | ✅ | ✅ | Both check the queue first and open the file; Android used to ask the provider first, so a downloaded episode waited and failed offline |
| Download quality choice before queueing | ✅ | ✅ | iOS resolves the episode's ladder and shows it in a sheet; Android `DownloadQualityDialog` |
| StreamHype resume position | ✅ | ✅ | Both inject a seek/report script into the embed and store the position with native resume rows. The seek is re-asserted on every media event and by a short poll, because embed players create or reload their `<video>` and overwrite a single `loadedmetadata` seek |
| `hev1` container repaired before a failed item is blamed | ✅ | n/a | Media3 reads `hev1` as served, so Android needs no rename |
| History | ✅ | ✅ | |
| Watchlist | ✅ | ✅ | |
| Manage categories | ✅ | ✅ | |
| Settings (source, TMDB key, playback prefs, about) | ✅ | ✅ | Version row: copying shows a transient "Copied" checkmark for 1.5s instead of replacing the version forever |
| Local feature flags gate the app | ✅ | ✅ | Feature tracking switches are preferences: turning off Search/Watchlist/Downloads removes the tab, History/Manage Categories leaves Settings, and downloads leaves the detail screen. A tab whose feature is switched off while open falls back to Home |
| Screen re-entry keeps loaded content | ✅ | ✅ | Detail / Watchlist / History load once per holder and only refresh on pull, so leaving and returning no longer blanks the page behind a spinner |
| Docs | ✅ | ✅ | |
| Lab: gate previews + gateway version probe | ✅ | ✅ | |
| Feature tracking (local registry + screen) | ✅ | ✅ | Same feature ids on both |
| Native playback (Media3 / AVPlayer) | ✅ | ✅ | |
| Quality, audio/dub and speed selection | ✅ | ✅ | |
| Resume position | ✅ | ✅ | |
| Picture in picture | ✅ | ✅ | Android: PiP from Playback Options; Back never enters PiP |
| Fullscreen chrome geometry (no resize on hide) | ✅ | ✅ | |
| Edge scrubbing for brightness / volume | ✅ | ✅ | |
| Double-tap seek + skip pill | ✅ | ✅ | |
| Lock (controls hidden, timed unlock) | ✅ | ✅ | |
| HTML5 fullscreen host for web streams | ✅ | ✅ | |
| StreamHype web playback | ✅ | ✅ | Android pins the embed's root height to the measured viewport (WebView reports a 0 CSS viewport height) |
| Tap toggles the web player chrome | ✅ | ✅ | Own touch listener observes without consuming |
| Provider subtitles | ✅ | ✅ | |
| Community subtitles (keyless, OpenSubtitles v3) | ✅ | ✅ | Ported with the same fixtures: Cinemeta id lookup, episode-marker guard, ranking |
| Community captions on a playback opened from History | ✅ | ✅ | iOS stores the show title (not the composed player title) and resolves the catalog subject for the year; Android already records the detail subject |
| Downloads carry their captions | ✅ | 🟡 | iOS archives provider tracks, else the community ones the player would show, scoped per episode, and backfills after a background completion; Android archives provider tracks only — T-039 |
| Series subtitles keyed by the playing episode's resource id | ✅ | ✅ | |
| Episode-scoped subtitle cache | ✅ | ✅ | `SubtitleCache` scope `season:episode` |
| Default subtitle on start (English; community first on an episode) | ✅ | ✅ | |

## Open parity work

| Gap | Task | Note |
|---|---|---|
| Progressive playback of an in-progress download on Android | T-032 | Needs the range-capable loopback surface or a Media3 equivalent; iOS already ships it |
| Community caption fallback when bundling a download on Android | T-039 | Provider-less titles download with an empty subtitle sheet offline |

## How to update this file

1. Change a feature on either platform.
2. Update its row here (status + note) in the same commit as the code.
3. If the other platform does not have it, register a parity task (`node tasks/bin/tasks.mjs add`)
   and leave the row **⬜** with the id.
4. On-device verification belongs in `tasks/progress/<agent>.md`; a row is not a substitute for it.
