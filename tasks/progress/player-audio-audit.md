# Player audio and source-resolution audit

**Date:** 2026-10-20
**Scope:** read-only audit of the iOS player and MovieBox data paths behind three reported symptoms:

1. audio sounds nonsensical or overly reverberant;
2. some movies play audio with no picture;
3. multi-source videos have no working source picker.

**Repository:** `/home/sammy/Desktop/Projects/mov/cinemacore` (all paths below are relative to this root).
**Tree audited:** working tree, `main`, HEAD `ae97986`, with substantial uncommitted in-flight work. Where the
committed build and the working tree differ, both are called out explicitly. `PlayerModel.swift` was still being
edited during this audit (mtime 20:43); its line numbers below are from that snapshot, so re-grep function names
if the file moves again.
**No production, test, task-state, or contract files were changed.** This report is the only new file.
**No commit was made.**

---

## 1. Verdict in one screen

| Reported symptom | Most likely cause | Status in working tree | Confidence |
|---|---|---|---|
| Reverberant / "nonsensical" audio | Committed build used `AVAudioTimePitchAlgorithm.timeDomain`; the app persists a non-1.0 playback speed across launches, so every title is pitch-shifted with the cheap resampler. | **Fixed in working tree** (`.spectral`, `PlayerModel.swift:592`), but not committed or built. | **High** that this produces exactly this artifact at speeds ≠ 1.0; **medium** that it is the user's exact trigger (depends on the saved speed). |
| Audio-only on some movies | Several provider renditions are HEVC with an `hev1` sample entry (e.g. The Odyssey 1080, Dune 720/480/360). AVFoundation's HEVC path is built around `hvc1`; `hev1` commonly renders no video while AAC audio still plays. The player only checks that a video *track exists*, not that it is decodable. | **Not fixed** — `SourceInspection` checks track presence only. | **High** on the `hvc1`/`hev1` platform behaviour; **medium-high** that it explains the reported titles. |
| No source picker for multi-source videos | The sheet labelled "Source" lists `resourceDetectors`, which are **mirror/upload hosts**, not languages. Selecting one re-resolves the *same* request because `resourceId` is dropped at every layer. The real language/dub list (`dubs[]`, with a distinct `subjectId` per dub) is never modelled. | **Not fixed** — picker is cosmetic. | **High** (confirmed in code and live data). |

A second, independent audio-only path is also present: a DASH `.mpd` can be handed to `AVPlayer`, which has no
native DASH support. A third is a resource listing that is not filtered by season/episode. Both are lower in the
ranking because the sampled live titles returned MP4 URLs, not manifests.

---

## 2. Method and evidence

### 2.1 Code read

- `mobile/ios/Cinemacore/Sources/Cinemacore/Player/PlayerModel.swift`
- `mobile/ios/Cinemacore/Sources/Cinemacore/Player/PlayerOptionsSheet.swift`
- `mobile/ios/Cinemacore/Sources/Cinemacore/Navigation/Route.swift`
- `mobile/ios/Cinemacore/Sources/Cinemacore/Screens/DetailScreen.swift`
- `mobile/ios/CinemacoreCore/Sources/CinemacoreCore/Models.swift`
- `mobile/ios/CinemacoreCore/Sources/CinemacoreCore/MovieBoxRepository.swift`
- `mobile/ios/CinemacoreCore/Sources/CinemacoreCore/MovieBoxWire.swift`
- `mobile/ios/CinemacoreCore/Sources/CinemacoreCore/StreamRecovery.swift`
- `mobile/ios/CinemacoreCore/Sources/CinemacoreCore/PlaybackSourcePolicy.swift`
- `mobile/ios/CinemacoreCore/Sources/CinemacoreCore/CatalogRepository.swift`
- `core/provider/moviebox/moviebox.go`, `core/provider/moviebox/recovery.go`
- `core/catalog/catalog.go`, `core/models`, `server/server.go`, `contracts/openapi.yaml`
- Android reference: `Genga-World/.../LocalMovieBoxServer.kt`, `MovieViewModel.kt`
- `moviebox-internal-api/OFFICIAL_API_DOCUMENTATION.md` §13

### 2.2 Live probe

The Go gateway was run locally (`go run ./cmd/cinemacore`, `127.0.0.1:8971/8972`) with the exact `ClientInfo`
from `cmd/cinemacore/main.go`. Live endpoints used: `/v1/search`, `/v1/detail`, `/v1/play`.

Captured evidence in `/tmp/opencode/`:

| File | What it is |
|---|---|
| `detail_dune.json` | Live `/subject-api/get` for Dune (1984), `subjectId=9048868765454191080` |
| `detail_partone.json` | Live `/subject-api/get` for Dune: Part One, `subjectId=6673847377281310728` |
| `play.json` | `/v1/play` for Dune (1984): four MP4 renditions |
| `play_1511967966181605720.json` | `/v1/play` for the Hindi dub subject of Dune: Part One |
| `play_2413592258760133680.json` | `/v1/play` for The Odyssey |
| `play_2488344488972799784.json` | A title where every rung failed (`stream_unavailable`) |
| `probe_mp4b.py` | Inline MP4 `moov` parser used because `ffprobe`/`ffmpeg` are not installed |

### 2.3 MP4 track probe (no whole-title download)

Only the `ftyp` + `moov` prefix of each file was fetched with HTTP `Range`; no media payload was downloaded.
Results:

| Title / rendition | Video | Audio |
|---|---|---|
| Dune 1984 1080 | `avc1` 1920×816 | 1× `mp4a`, stereo, 48 kHz |
| Dune 1984 720 | `hev1` 1280×544 | 1× `mp4a`, stereo, 48 kHz |
| Dune 1984 480 | `hev1` 1130×480 | 1× `mp4a`, stereo, 48 kHz |
| Dune 1984 360 | `hev1` 850×360 | 1× `mp4a`, stereo, 48 kHz |
| Dune: Part One Hindi dub 1080 | `avc1` 1920×804 | 1× `mp4a`, stereo, 48 kHz |
| Dune: Part One Hindi dub 480 | `hev1` 1280×536 | 1× `mp4a`, stereo, 48 kHz |
| The Odyssey 1080 | `hev1` 1920×1000 | 1× `mp4a`, stereo, 48 kHz |
| The Odyssey 480 | `hev1` 920×480 | 1× `mp4a`, stereo, 48 kHz |
| The Odyssey 360 | `hev1` 690×360 | 1× `mp4a`, stereo, 48 kHz |

**Every sampled file has exactly one video track and one stereo AAC track. None is genuinely audio-only.**
The Hindi 1080 URL lives under `/tran-audio/`, but it still contains AVC video; the path name is misleading.

### 2.4 Limitations

- The recorded HLS/DASH manifests (`sbcdn3.hakunaymatata.com/.../index.mpd` and `.../index.m3u8`) returned
  **HTTP 403 ACCESS DENIED**: their signed-cookie timestamps (`t=1789908742`, `t=1791308037`) had expired.
  They could not be re-fetched or probed.
- `ffprobe`/`ffmpeg` are unavailable, so the probe is an inline box parser, not a decoder. It proves track
  presence, codec fourcc, dimensions, channel count and sample rate; it cannot prove audio language or
  perceptual quality.
- Live `play-info` returned the 23-second decoy for every captured request, including requests that included a
  `resourceId`. Playback therefore came from rungs 3/4 (UGC/resource recovery), not from the signed manifest.
- No live title with **multiple** `resourceDetectors` was found. Both Dune titles have exactly one detector,
  so the multi-source UI was assessed from the data model and the Android reference, not from a live multi-mirror
  playback.

---

## 3. Findings

### F1 — `timeDomain` is the documented cause of reverberant audio (committed build)

The committed HEAD used:

```swift
item.audioTimePitchAlgorithm = .timeDomain
```

`PlayerModel.swift` at HEAD, line 454. The working tree changes it to `.spectral` and documents why:

```swift
// `.timeDomain` is the cheap resampler: at pitch-preserved speeds it
// smears transients and makes music sound reverberant. `.spectral` is
// the algorithm AVPlayer uses for movies and the one that keeps
// dialogue intelligible at 1.25x and 0.5x.
item.audioTimePitchAlgorithm = .spectral
```

`PlayerModel.swift:588-592`.

The speed is **persisted** (`LibrarySettings.playbackSpeed`, `LibraryStore.swift:46-47, 81, 95`) and restored on
every player construction (`PlayerModel.swift:182-183`). `play()` reapplies it (`PlayerModel.swift:894-899`).
So a single past selection of 1.25×/1.5×/2.0× makes every later title start at that rate, with the cheap
resampler in the committed build. At rate 1.0 the algorithm has no effect; the symptom therefore implies a
non-1.0 saved speed or a build older than the working-tree fix.

**Confidence:** high for the mechanism; medium for the user's exact trigger.
**Fix status:** working tree only; not committed, not necessarily in the installed build.

### F2 — The "Source" sheet is mislabelled and cosmetically inert

`PlayerOptionsSheet.swift:44-66` renders a `Section` titled **"Source"**, with footer
"Provider languages and dubs. Switching reloads the stream from the same position." Each row is a
`ResourceDetector`:

```swift
choiceRow(
    language.name,
    detail: language.isDub ? "Dubbed" : "Original",
    selected: language == model.selectedLanguage
) { Task { await model.selectLanguage(language) } }
```

But live `ResourceDetector.name` is a **mirror host**, not a language. `MovieBoxWire.swift:63-69` maps
`detector.source` into `name`; the live Dune payload has:

- Dune (1984): one detector, `source = "fzmovies.net"`, `resourceId = 5771906885452461240`;
- Dune: Part One: one detector, `source = "fzmovies.cms"`, `resourceId = 1768483404560980816`.

`ResourceDetector.isDub` (`Models.swift:133-137`) returns true only when the id starts with `dub_` or the name
contains "dub". Neither live detector does, so every row reads **"Original"**. The section is a one-row list of
host names for both titles.

Worse, selecting a row cannot change the bytes. `selectLanguage` stores the id in `PlaybackRequest`
(`PlayerModel.swift:1120-1134`), but `playStream` calls:

```swift
let info = try await app.repository.playInfo(
    subjectID: request.subject.id,
    season: request.season,
    episode: request.episode?.number
)
```

`PlayerModel.swift:373-379`. `resourceId` is never passed. The protocol has no such parameter
(`CatalogRepository.swift:19`), the remote implementation sends only `subjectId/season/episode`
(`CatalogRepository.swift:68-77`), the Go server reads only those three (`server/server.go:118-140`), and the
OpenAPI contract documents only those three (`contracts/openapi.yaml:148-160`). The built-in repository also has
no `resourceId` parameter (`MovieBoxRepository.swift:95-102`).

**Result:** the picker is cosmetic at four independent layers: UI model, `PlaybackRequest`, repository protocol,
and upstream request.

**Confidence:** high, confirmed by code and live payloads.

### F3 — The real language/dub list is discarded; `isDub` can never be true for live data

The live `dubs[]` entries are language objects:

```json
{"lanCode":"hi","lanName":"Hindi dub","original":false,"subjectId":"6077290422534030680","type":0}
```

Dune (1984) has 4 entries; Dune: Part One has 5. Each non-original entry has a **distinct `subjectId`**.
Cinemacore reduces this to `[String]` in both implementations:

- Swift: `WireDub` declares only `lanName` (`MovieBoxWire.swift:147-149`); `Subject.dubs` is `[String]`
  (`Models.swift:23`); the decoder keeps only `lanName` (`MovieBoxWire.swift:53-56`).
- Go: `wireDub` declares only `LanName` (`core/provider/moviebox/moviebox.go:332-334`); `toSubject` appends only
  the name (`moviebox.go:402-406`).

The player never reads `Subject.dubs` at all: `PlayerModel.languages` is `request.subject.resourceDetectors`
(`PlayerModel.swift:194`). The detail screen uses `dubs` only as genre chips (`DetailScreen.swift:194`). So the
user can see "Hindi dub" / "Telugu dub" on the title page but has no way to select them in playback.

`ResourceDetector.isDub` (`Models.swift:133-137`) was written against a synthetic convention that the live
decoder never produces. The Android reference does produce it: its local proxy rewrites `dubs[]` into
`resourceDetectors` with `resourceId = "dub_<subjectId>"` and real mirrors into `"res_<resourceId>"`
(`Genga-World/.../LocalMovieBoxServer.kt:648-665`). On playback it strips the prefix and, for a dub, replaces the
**subject id** rather than passing a resource id (`LocalMovieBoxServer.kt:806-825`). The iOS port copied the
`dub_` test but not the synthetic id generation, so the test suite passes (`DecodingTests.swift:83-88`) while
live data never matches.

**Confidence:** high.

### F4 — The data model already shows why "multiple sources" is ambiguous

There are four different axes in the live payloads, and only two are exposed:

| Axis | Live field | Example | What it selects | Current UI |
|---|---|---|---|---|
| Mirror / upload | `resourceDetectors[]` → `resourceId`, `source`, `resolutionList[]` | Dune: one `fzmovies.net` detector with 4 resolutions | An upload/mirror. Must be sent as `resourceId` to `play-info`. | "Source" rows (mislabelled, inert) |
| Language / dub | `dubs[]` → `lanName`, `lanCode`, `original`, `subjectId` | Dune: 4; Dune: Part One: 5 | A separate language subject. Resolve with `subjectId = dub.subjectId`. | Not exposed; chips on Detail only |
| Quality / rendition | `PlayInfo.streams[]` (`StreamRendition`) | Dune: 1080/720/480/360 with four **distinct** URLs | A file/bitrate. Rungs 3/4 have distinct URLs; rungs 1/2 share one manifest URL. | "Quality" rows |
| Container audio track | `AVMediaSelectionGroup.audible` | Sampled files: one stereo AAC | An audio track inside one file | "Audio Track" rows when >1 |

"Multiple sources" in the user's report most likely means **languages/dubs** (the visible chips) or **mirror
uploads** (the hidden detector list), not quality rungs. Both need distinct UI:

- **Source / Mirror** — show `resourceDetectors` as sources, labelled by `source` host (and, when available,
  uploader/title from `resolutionList`), and send `resourceId` on re-resolve.
- **Language / Dub** — show `dubs` as languages, labelled by `lanName`/`lanCode` and "Original", and re-resolve
  with the dub's `subjectId`.
- **Quality** — show per-URL renditions; do not dedupe by label.

Note that rungs 1/2 expand one manifest URL into one `StreamRendition` per advertised label
(`StreamRecovery.swift:143-152`), so all labels share a URL. Rungs 3/4 produce distinct URLs
(`MovieBoxRepository.swift:222-269`). `selectQuality` now handles both: same URL → bitrate hint; different URL →
rebuild (`PlayerModel.swift:1154-1163`). This part is correct in the working tree (the committed build only set
`preferredPeakBitRate`).

### F5 — Quality dedupe by label hides distinct sources

`PlaybackSourcePolicy.videoOptions` dedupes the quality sheet by lowercased **label**:

```swift
public static func videoOptions(_ streams: [StreamRendition]) -> [StreamRendition] {
    ranked(streams, dedupeKey: { $0.quality...lowercased() })
}
```

`PlaybackSourcePolicy.swift:57-59`.

`ResourceStream` (rung 4) walks every `ResourceItem` across all uploads and produces one `StreamRendition` per
`(resolution, resourceLink)` pair (`MovieBoxRepository.swift:250-269`). If two uploads both offer "1080", the
sheet shows only the first.

The current working tree makes this worse: `videoCandidates` now delegates to `videoOptions` and *then* dedupes by
URL (`PlaybackSourcePolicy.swift:65-68`), so a second URL sharing the "1080" label is dropped from **both** the
sheet and the automatic fallback. Earlier in the day `videoCandidates` deduped by URL directly, which at least
kept the second URL as a fallback. For source selection, dedupe by URL first, then group labels for display.

The row detail is only `rendition.size` (`PlayerOptionsSheet.swift:70-84`). `ResourceItem` does not decode
`sourceUrl`, `uploadBy`, `title`, or `codecName` (`MovieBoxWire.swift:313-323`), and `WireDetector` does not
decode the nested `resolutionList` at all (`MovieBoxWire.swift:151-155`). So even if the UI wanted to label
"fzmovies.net · 1080", the data is already gone.

**Confidence:** high for the dedupe/label loss; medium for how often a live title has multiple uploads at the
same resolution (not sampled).

### F6 — Audio-only playback: `hev1` is the strongest concrete cause

The player's post-ready inspection asks only whether a video track exists:

```swift
video = try await asset.loadTracks(withMediaType: .video)
...
guard !video.isEmpty else { return SourceInspection(hasVideo: false, ...) }
```

`PlayerModel.swift:734-823`. It checks an **audio** codec denylist (`undecodableAudioCodecs`,
`PlayerModel.swift:8-11`) and rejects audio with more than 8 channels (`PlayerModel.swift:825-840`), but has no
video-codec check.

Live evidence shows that the provider freely serves HEVC in an `hev1` sample entry:

- Dune 1984: 1080 `avc1`, 720/480/360 `hev1`;
- The Odyssey: 1080/480/360 all `hev1`;
- Hindi Dune: 1080 `avc1`, 480 `hev1`.

AVFoundation's HEVC support is built around `hvc1`; `hev1` sample entries are commonly not rendered by
`AVPlayer` (the audio track still plays). This produces exactly "audio with a black picture on some movies,
but not all", because it depends on which rendition/title the provider encoded as `hev1`.

The app defaults to the highest resolution for rungs 3/4 (`resetSelections`, `PlayerModel.swift:554-560`), so a
title whose 1080 is `avc1` looks fine, while a title whose 1080 (or whose only surviving rendition) is `hev1`
plays audio only. The current `SourceInspection` returns `hasVideo: true` for both, so it never falls back.

**Confidence:** high on the platform behaviour; medium-high on the exact titles. This should be confirmed on
device with one `hev1` URL and one `hvc1`/`avc1` URL.

### F7 — DASH `.mpd` is handed to `AVPlayer`

`StreamRecovery.manifest` prefers DASH over HLS:

```swift
if let mpd = dashManifest(decoded) { return mpd }
if let hls = hlsManifest(decoded) { return hls }
```

`StreamRecovery.swift:64-67`. The CloudFront branch only tries `dashManifest` (`StreamRecovery.swift:74-76`), so
an HLS CloudFront resource is dropped entirely.

`MovieBoxRepository.primaryStreams` accepts that result as the target (`MovieBoxRepository.swift:148-150`), and
`PlaybackSourcePolicy` does not reject `.dash` (`PlaybackSourcePolicy.swift:39-42`). `AVPlayer` has no native
MPEG-DASH support. The recorded fixture `core/provider/moviebox/testdata/play-info-signed-cookie.json` is exactly
this shape (`/dash/...` signed cookie → `index.mpd`). The iOS port inherited the Android/TUI ladder, where
ExoPlayer/Media3 supports DASH.

**Impact:** any title that only exposes a `/dash/` signed cookie cannot play on iOS at all; this is a hard
failure, not audio-only. Fix by preferring HLS on iOS (`hlsManifest` first, and try HLS in the CloudFront branch),
or by routing DASH through the planned local HLS bridge (T-014) and never handing `.mpd` to `AVPlayer`.

**Confidence:** high.

### F8 — Rung 4 does not filter the resource listing by season/episode

`resources()` passes `se`/`ep` to the endpoint (`MovieBoxRepository.swift:273-286`), but the live listing is
documented as unfiltered, and `resourceStream` iterates **all** returned items without checking `item.se` /
`item.ep` (`MovieBoxRepository.swift:250-262`; Go equivalent `core/provider/moviebox/recovery.go:337-360`).
For a series, the first episode's 1080/720/… entries can win and the viewer gets the wrong episode's file.

This is not the reported audio symptom, but it is a real data-path bug in the same ladder, and it becomes more
visible once the player can select sources. Filter `it.Se`/`it.Ep` (0/0 for movies, requested values for series)
before building renditions.

**Confidence:** high from code; the live `/resource` endpoint was not exhaustively sampled for series.

### F9 — Subtitles are keyed to the first detector, not the selected source

`MovieBoxRepository.subtitleTracks` hard-codes `detail.data?.resourceDetectors?.first?.resourceId`
(`MovieBoxRepository.swift:307-316`); the Go provider does the same (`moviebox.go:107-116`). With a real
source/dub switch, captions would still come from the first mirror/original. `resetSelections` also uses
`(selectedLanguage?.isDub ?? false)` to turn captions off for a dub (`PlayerModel.swift:560`), which is always
false for live data.

**Confidence:** high.

### F10 — Multi-track auto-selection was a plausible reverb/narration cause (fixed in working tree)

The committed `loadAudioTracks` exposed every audible option and left automatic media-selection criteria on, so
the system could choose a commentary or descriptive track. The working tree now:

- filters to main-program audio and excludes descriptive/commentary/auxiliary tracks
  (`PlayerModel.swift:1227-1268`);
- explicitly selects the chosen option and disables automatic criteria (`PlayerModel.swift:1251-1262, 1183`);
- prefers a track matching the selected language (`PlayerModel.swift:1284-1294`).

One residual issue: `preferredAudioOption` is passed `selectedLanguage`, which is a **mirror host** such as
`fzmovies.net`. Its token match can never match an audio track, so it always falls back to the first main track.
That is harmless today (sampled files have one track), but it becomes wrong once dubs are modelled. Pass the
dub's `lanCode`/`lanName`, not the detector name.

**Confidence:** high for the committed-build risk; low for it being the user's specific cause (no multi-track
sample was found).

---

## 4. What "multiple sources" should mean, precisely

Use three separate concepts; do not overload `resourceDetectors`.

### 4.1 Source / mirror

A `resourceDetectors[]` entry. Live shape (from `detail_dune.json`):

```json
{
  "resourceId": "5771906885452461240",
  "source": "fzmovies.net",
  "codecName": "hevc",
  "firstSize": "395561224",
  "resolutionList": [
    {"resolution": 1080, "resourceId": "...", "resourceLink": "https://...mp4", "codecName": "hevc", "size": "..."}
  ]
}
```

- UI label: `source` host, plus `resolutionList[].title`/`uploadBy` if decoded.
- Re-resolve identifier: `resourceId` on `/wefeed-mobile-bff/subject-api/play-info`
  (`OFFICIAL_API_DOCUMENTATION.md:573-581`). On the Cinemacore contract this requires a new optional
  `resourceId` query parameter on `/v1/play`, a new `CatalogRepository` parameter, and a provider signature
  change.
- Do **not** treat this as a language.

### 4.2 Language / dub

A `dubs[]` entry. Live shape:

```json
{"lanCode":"hi","lanName":"Hindi dub","original":false,"subjectId":"6077290422534030680","type":0}
```

- UI label: `lanName` (+ `lanCode`), with "Original" for `original: true`.
- Re-resolve identifier: **`subjectId = dub.subjectId`** (the dub is a separate subject), optionally with that
  subject's own detector `resourceId`. The Android proxy does exactly this
  (`LocalMovieBoxServer.kt:806-825`, `MovieViewModel.kt:1065-1100`).
- This is the axis the current UI is missing.

### 4.3 Quality / rendition

A `StreamRendition` (`Models.swift:277-315`).

- If several labels share one URL, it is one adaptive manifest; the label is a bitrate hint
  (`selectQuality`, `PlayerModel.swift:1154-1163`).
- If labels map to distinct URLs, each is a real file and must rebuild the item.
- Dedupe by **URL**, not label, when the goal is source choice. Keep label-only dedupe only for a manifest
  ladder.

### 4.4 Container audio track

`AVMediaSelectionGroup.audible`. This is not a provider source; it is a track inside one file. It should remain
the "Audio Track" section, shown only when more than one eligible track exists.

---

## 5. Recommendations

### P0 — correctness

1. **Model dubs properly.**
   - Swift: replace `Subject.dubs: [String]` with `[Dub]` where `Dub` carries `subjectId`, `lanName`,
     `lanCode`, `original`.
   - Go: mirror the same struct in `core/models` and `wireDub`.
   - Update `WireSubject`/`toSubject` and the fixture tests. Remove the synthetic `dub_` assumption, or
     generate synthetic ids in the same place the Android proxy does.

2. **Add a real Language/Dub picker.**
   - `PlayerOptionsSheet` gets a "Language" section from `dubs`.
   - Selecting a dub sets `request.subject` (or a new `playbackSubjectID`) to `dub.subjectId` and re-resolves
     at the live clock. Keep `historyKey` on the original title so resume still works.
   - Fetch captions for the active dub subject; turn captions off for a dub only when the dub has no captions.

3. **Make Source mean mirror, or remove it.**
   - Rename the current section to "Source" only if it sends `resourceId`.
   - Thread `resourceId` through: `CatalogRepository.playInfo(..., resourceId:)` →
     `RemoteCatalogRepository` query → `/v1/play` (contract + server) → provider `resolveStream(..., resourceId)`
     → `play-info?...&resourceId=`.
   - If the team does not want a contract change now, remove the inert rows rather than ship a picker that
     does nothing.

4. **Fix audio-only playback caused by `hev1`.**
   - Extend `SourceInspection` to read the video format description and reject sample entries AVFoundation
     cannot render. Prefer `avc1`/`hvc1`; treat `hev1` as unplayable on iOS.
   - Order candidates so `avc1`/`hvc1` outranks `hev1` at the same resolution.
   - Fallback to the next URL on rejection (`PlaybackSourcePolicy.fallback` already exists in the working tree).
   - Longer term: remux `hev1` → `hvc1` (sample-entry change only) in the progressive/local asset server, or
     use the local HLS bridge.

5. **Never hand a DASH manifest to `AVPlayer`.**
   - On iOS, try `hlsManifest` before `dashManifest` in `StreamRecovery.manifest`; add HLS to the CloudFront
     branch.
   - If only DASH exists, surface a clear "DASH is not supported on this build" state or route through the
     planned bridge (T-014).

6. **Keep `.spectral`, and neutralise the persisted-speed trap.**
   - Keep the working-tree change (`PlayerModel.swift:592`).
   - On upgrade, if `playbackSpeed != 1`, either reset it to 1 with a one-time notice or show the speed chip on
     first play. The chip already exists (`PlayerScreen.swift:118, 328`), but only when `speed != 1`.
   - Add a regression test that a fresh item uses `.spectral` and that `setSpeed` does not install
     `.timeDomain`.

### P1 — source/quality UX

7. **Dedupe quality by URL** in `videoOptions` when distinct files exist; keep label dedupe only for a shared
   manifest URL.
8. **Decode and show source metadata**: `WireDetector.resolutionList` (`resolution`, `resourceLink`,
   `codecName`, `title`, `uploadBy`), and `ResourceItem.sourceUrl`/`uploadBy`/`codecName`. A row that says
   "1080 · fzmovies.net · HEVC" is a source picker; a row that says "1080" is not.
9. **Filter rung 4 by `se`/`ep`** before building renditions (F8).
10. **Key subtitles to the selected source/dub** (`MovieBoxRepository.swift:307-316`, `moviebox.go:107-116`).
11. **Pass dub language to `preferredAudioOption`**, not the mirror host name (`PlayerModel.swift:1284-1294`).

### P2 — hardening

12. Reject `resolution == 0` / label `"0"` and `.dash` URLs in `PlaybackSourcePolicy.isVideoCapable`.
13. Add an on-device matrix test: one `avc1`, one `hvc1`, one `hev1`, one audio-only MP4, one HLS master, one
    DASH manifest. Assert the player either shows video or moves to the next source, never audio-with-black.
14. Add a live-fixture test using `detail_dune.json` (one detector, four dubs) so the decoder cannot regress to
    the synthetic `dub_` shape.

---

## 6. Answers to the three questions implied by the report

1. **Why does audio sound reverberant/nonsensical?**
   The committed build uses `.timeDomain` and restores a persisted non-1.0 speed; that resampler smears
   transients at pitch-preserved speeds. The working tree already switches to `.spectral`. A secondary
   possibility is a commentary/descriptive audio track being auto-selected in the committed build, which the
   working tree now filters. A 5.1/Atmos downmix issue is possible but **not observed**: every sampled file is
   one stereo AAC track. The Hindi `tran-audio` path is a red herring; it still has AVC video.

2. **Why is some playback audio-only?**
   The strongest evidence is `hev1`: three of the four Dune renditions and all three sampled Odyssey renditions
   are HEVC with an `hev1` sample entry, which AVFoundation commonly does not render. The player only checks for
   the existence of a video track, so it never falls back. DASH `.mpd` and a genuinely audio-only resource entry
   are secondary paths.

3. **Why is there no source picker?**
   Because the "Source" section lists mirror hosts (`resourceDetectors`), not languages, and selecting one
   re-resolves the identical request — `resourceId` is dropped at the model, request, repository, and upstream
   layers. The actual language list (`dubs[]` with distinct `subjectId`s) is reduced to strings and never
   reaches the player.

---

## 7. Reproduction notes

- Live detail: `GET /wefeed-mobile-bff/subject-api/get?subjectId=9048868765454191080` (Dune 1984) and
  `...?subjectId=6673847377281310728` (Dune: Part One). Captured in `/tmp/opencode/detail_*.json`.
- Live play: `GET /v1/play?subjectId=9048868765454191080` (four MP4s) and
  `GET /v1/play?subjectId=1511967966181605720` (Hindi dub; different stream set). Captured in
  `/tmp/opencode/play*.json`.
- MP4 probe: `python3 /tmp/opencode/probe_mp4b.py` (reads `/tmp/opencode/play.json`, fetches only `ftyp`+`moov`).
- Manifest probe: `curl` of the recorded `index.mpd`/`index.m3u8` returned `403 ACCESS DENIED`; the signed
  cookie timestamps in `core/provider/moviebox/testdata/play-info-*.json` have expired.
- Device verification is still required for the `hev1` hypothesis; the box parser proves the sample entry, not
  AVFoundation's rendering decision.

---

## 8. Confidence summary

| Claim | Confidence | Basis |
|---|---|---|
| `.timeDomain` causes reverberation at non-1x; committed build uses it | High | Code comment + HEAD source; speed persistence |
| Source picker cannot change streams | High | Four layers inspected; live one-detector payloads |
| `resourceDetectors` are mirror hosts, not dubs | High | Live detail JSON + both wire decoders |
| Dubs have distinct `subjectId`s and are discarded | High | Live detail JSON + `WireDub`/`wireDub` |
| `hev1` explains audio-only on some titles | Medium-high | Track probe + known AVFoundation `hvc1` requirement; needs device confirmation |
| DASH cannot play on iOS | High | Platform limitation + DASH-first manifest selection |
| Rung 4 can return the wrong episode | High (code) | No `se`/`ep` filter in `resourceStream` |
| Multi-upload titles exist at the same resolution | Medium | Not sampled live; model supports it |
| 5.1/Atmos downmix causes the reverb | Low | No multichannel sample found; all sampled tracks stereo |
