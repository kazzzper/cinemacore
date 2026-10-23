# dsh-subs — subtitle pipeline (T-020)

## Proven root causes
1. **Addon returns wrong-episode entries, unfiltered.** Live OpenSubtitles v3 listings contain
   files naming another episode (`tt0944947:1:1` → an S08E02 file + `lycan-gots1e0`;
   `tt0944947:2:5` → S04E07 + a *Secret Circle* file; `tt6468322:3:5` → S02E05). 2/448
   per-language first tracks across 15 lookups named a different episode, and in one case it
   was the **first** track for its language — i.e. what `tracks.first` auto-selects.
   Fixed by `FreeSubtitles.namesRequestedEpisode` (drops only entries whose name spells a
   different S/E; unmarked entries kept).
2. **Nil season/episode silently defaulted to S1E1.** `addonURL` did `max(season ?? 1, 1)`, so a
   series with no number asked for S1E1 specifically. Pinned in a tested helper.
3. **Provider caption call omitted `se`.** Documented param + Kotlin sends it; iOS sent only
   `episode`. Correct by reference only — api6 returns 441 from this sandbox, unverifiable live.

## Ruled out (do not re-investigate)
- **Off-by-one / absolute-vs-season-relative episode index**: NOT a bug. 1-based end to end
  (Go `episodeNumbers` → Swift `WireSeason.episodeNumbers` → `Episode.number`).
- **`resourceDetectors.first` wrong for a dub/show**: NOT a bug. Every live detail payload has
  exactly **1** detector (series and movie). A dub is a different `subjectId`, and
  `playbackSubjectID` already re-points to it. The `resourceID:` parameter I added was removed
  per 00-senior-doctrine ("a case that cannot occur").

## Hardened with tests (not observed firing)
- `hydrateProviderMetadata` replaced the subtitle list wholesale → dropped community tracks out
  of the picker while one was playing. `hydrateFreeSubtitles` required an empty list → could
  never add a second source. Now `SubtitleTracks.merging` / `defaultTrack` in core.
- `subtitleChosen` guard logic was already correct and is unchanged.

## Files
- core: `FreeSubtitles.swift`, `Models.swift` (SubtitleSource + SubtitleTrack.source/provider),
  `Models+Decoding.swift`, `Subtitles.swift` (SubtitleTracks), `MovieBoxRepository.swift`.
- app: `PlayerModel.swift` (my regions only), `PlayerOptionsSheet.swift` (source sections).

## Verification
- `.tools/tmp/subs-verify`: 375 tests / 58 suites green (real package minus the third writer's
  `StreamHypeRepository.swift` + its 18 tests; `contracts/` symlinked for signing vectors).
- App build blocked by `Player/WebStreamView.swift:55` (`webView` method/name collision) — a
  third writer's file, not mine.
