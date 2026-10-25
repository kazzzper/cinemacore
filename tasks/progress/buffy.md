# buffy

- 2026-10-23 — registered (freebuff)
- 2026-10-23 — added + claimed T-022 — StreamHype source: TMDB catalog + web-embed playback
- 2026-10-23 — added + claimed T-023 — captions must not resize the picture; downloads must queue a video rung

## T-027 — a slim picture in landscape, and a 720p pick that went blank

**Reported:** turning the phone sideways squashes the video into a thin band instead of filling the screen;
switching quality mid-episode to 720p gives a blank picture and then "falls to 360p".

### Root causes
1. Fullscreen was the *button's* state alone. Turning the phone rotated the window but left
   `isFullscreen == false`, so the screen kept the portrait stack — a 16:9 box sharing a `VStack` with the
   details scroll. In landscape there is no height left for that box, and the picture was squeezed into
   whatever remained.
2. `PlayerOrientation.supportedOrientations` narrowed the mask to `.landscape` while fullscreen, so once a
   rotation had happened the app could not turn portrait again. Turning the phone back was refused, which is
   the other way to end up with a player that will not sit right.
3. A quality pick can select a **DASH** rendition. The gateway builds `index.mpd` whenever its signed prefix
   is a `/dash/` tree (`core/provider/moviebox/recovery.go`), and the Go core keeps that rung for the
   terminal client, which renders it through mpv. iOS has no DASH support: the item fails after it is
   already on screen, the picture goes blank, and recovery moves on to the next URL — the HLS rung, usually
   a lower label. That is the "720p blank, falls to 360p" sequence.

### Changes
- `PlayerScreen` watches `verticalSizeClass` (with `initial: true`, so a player opened sideways starts wide)
  and calls `setFullscreen(_, requestRotation: false)` — the phone has already turned, and asking again is
  how a rotation ends up half-applied. Turning back to portrait leaves fullscreen again, but only when the
  rotation is what entered it; the button clears that flag so an explicit pick is not undone.
- `PlayerOrientation` returns `.allButUpsideDown` in both modes. The geometry request is what turns the
  picture, not the mask, and a mask that forbids portrait traps the app sideways. The stored `isFullscreen`
  and the `setNeedsUpdateOfSupportedInterfaceOrientations` call went with it: neither had a job left.
- `PlaybackSourcePolicy.isUnplayableContainer(url:)` drops `.mpd` at both gates — the provider-side
  `isVideoStream` and `isVideoCapable` — so a DASH rung never reaches the quality sheet, the preferred
  source, or the fallback ladder.
- `PlayerModel.bitrateHint` only caps an HLS ladder. The gateway repeats one URL under every label, so a
  pick on a progressive file was a `preferredPeakBitRate` ceiling above the file's own bitrate, which is a
  stall rather than a quality change.

### Also fixed
- `streamhype.Health` reported "TMDB request error" for a refused key: `get` returns an error for every
  non-200, so the 401 branch below it was unreachable. The status is now inspected first.

### Verification
- `go build ./... && go test ./... -race`: green (`streamhype` 401 test asserts the note, not the dump).
- `swift test`: **411 tests / 62 suites green** (new: a DASH manifest is never a candidate, never preferred,
  never reached through fallback, and is rejected at the provider gate).
- `xtool dev build`: **BUILD OK, no warnings**.
- **Not device-verified.** The rotation behaviour and the 720p rung are only settleable on a phone; the DASH
  filter is exercised by tests but whether *this* episode's 720p was the DASH tree is inferred from the
  provider's construction, not from a captured URL.

## T-026 — captions saved with a download, edge-swipe levels, and a way into the season

**Asked:** downloaded episodes should come with their subtitles; the volume slider belongs on the right of
the picture (auto-hiding, raised by swiping up) with brightness on the left; tapping a downloaded episode
should open its season so more can be queued.

### Captions with the download
- `SubtitleArchive` fetches each provider track with the media cookie, converts it to WebVTT through the
existing cache and writes it beside the media file; `DownloadedSubtitle` records language + file name +
release label on the row. Best effort per track, capped at twelve: a dead caption host costs the subtitles,
never the episode that finished.
- `DownloadItem.subtitles` decodes tolerantly (an older queue has none). The engine takes an injected caption
  provider (`setCaptionProvider`), runs it after the media completes, re-emits the row so the tracks appear
  without a relaunch, and deletes the files with the episode on remove / remove-completed.
- `AppModel` injects the resolver (current catalog → captions → archive); the player seeds its picker from
  the row and reads `file:` URLs directly, because URLSession will not serve them and the whole point is to
  avoid a round trip. New `SubtitleSource.downloaded` names it honestly in the picker.

### Player levels
- The volume slider is gone from the bottom bar. A vertical drag on the right third sets volume, the left
  third sets screen brightness, and the middle keeps the downward fullscreen-exit swipe. Each shows a small
  rail on its own edge that hides itself 700 ms after the finger lifts.
- `PlayerModel.setBrightness` remembers what the display was set to and `stop()` puts it back, so the phone
  is not left dimmed after the film. Volume gained `revealsControls: false` so a level swipe does not flash
  the whole chrome over the picture it is adjusting.

### Downloads → season catalogue
- A row's poster and text are a `NavigationLink` to `Route.catalog(subject, season:)`, which opens
  `DetailScreen` at that season. `DetailViewModel` now keeps an explicitly requested season through the
  load instead of resetting to the first one; only a season the title does not have falls back.
- Rows with saved captions show a caption count, so the feature is visible before playback.

### Verification
- `swift test`: **409 tests / 62 suites green** (new: archive conversion, partial failure, headers, dedupe
  and cap, empty body; engine stores captions after completion and removes them with the episode; a row
  without the `subtitles` key still decodes).
- `xtool dev build`: **BUILD OK, no warnings**.
- **Not device-verified.** The gesture zones and the HUD's feel need a phone; the archive, engine and season
  selection are covered by tests.

## T-025 — a completed download would not play, and "offline" was the wrong reason

**Reported:** the episode shows as downloaded/completed, but playing it says the connection is offline.

### Root cause
A finished download is tried first, so the network is not what stopped it. When the copy is rejected —
the track probe finds no video, or the picture watchdog sees sound without a frame —
`recoverFromInvalidSource` deliberately abandons it and re-enters `load()` with the local paths skipped.
Offline, that request is the one that fails, and `playStream`'s catch reported *that* error. The file on
disk never appeared in the message. Two separate defects sit behind the symptom:
1. the local copy was rejected, and the provider fallback turned that into "you appear to be offline";
2. the local copy had no way to be repaired. The `hev1` → `hvc1` fix existed for remote streams only, and
the provider serves HEVC in that layout, so a downloaded copy this device will not draw had no path back.

### Changes
- `HEVCRewrite.repairInPlace(at:)`: patches a file already on disk. The `moov` is located by walking the
top-level boxes with seeks (the media data is never read), and only the sample-entry fourccs are written —
the box keeps its size, so nothing moves and the file is not re-fetched. It reads the `moov` back before
reporting success, refuses a file whose parameter sets are in band (`hvcC` check), and returns `false`
leaving the file byte-for-byte untouched otherwise. Unlike the fetch path it works with the index after
`mdat`, which is a property of editing in place.
- `PlayerModel.repairLocalHEVCSource()` runs that repair before abandoning a rejected download, then
reopens the same file at the same clock. One attempt per file.
- `PlayerModel.localRejection` remembers why the copy was abandoned, and `playStream`'s catch prefers it
over a transport failure — "the downloaded copy has no video" / "could not be drawn" instead of "offline".
- A copy the queue row itself declined (a soundtrack queued by an older build) is named too, instead of the
network that was never the problem.

### Verification
- `swift test`: **401 tests / 60 suites green** (new suite `HEVC rewrite on disk`: patches in place with no
  size change, is idempotent, patches an index behind `mdat`, leaves `hvc1`/in-band/`avc1` and non-MP4
  files untouched).
- `xtool dev build`: **BUILD OK, no warnings**.
- **Not device-verified.** Whether this specific episode was `hev1`, a soundtrack, or truncated cannot be
  settled off-device; the player now repairs the first case, and names the other two instead of the network.

## T-024 — a play failure printed an NSError dump and offered no retry

**Reported:** on-device play of Black-ish S1E1 fails with a "Something went wrong" screen whose body is a
whole `NSError` description — `Error Domain=NSURLErrorDomain Code=-1009 … _NSURLErrorNWPathKey=unsatisfied`
— and the only controls are "Back" and "Back to details".

### Root causes
1. `MovieBoxSession.attempt` caught every thrown error on the wire and stored it as
   `.http(status: -1, body: String(describing: error))`. A transport failure became a fake HTTP response
   whose "body" was the NSError dump.
2. `CinemacoreError.userMessage` repeated `.http`'s `message` verbatim and `.upstream`'s detail verbatim, so
   that dump was rendered as the reason, URL and task id included.
3. `isRetryable` treats a status outside 408/429/5xx as permanent, so status `-1` — "no response at all" —
   was classed as unfixable and the retry button was suppressed.

### Changes
- `SessionError.transport(code: URLError.Code)`; the session classifies the code instead of stringifying the
  error (cancellation returns immediately rather than rotating hosts). `MovieBoxRepository.map` forwards it.
- `CinemacoreError.transport(_:)` (code or `any Error`) → `.offline` for a lost route/DNS, `.timedOut`,
  `.cancelled`, otherwise a fixed "couldn't reach the provider" sentence — never `describing:` output.
  The download engine's two remaining `String(describing: error)` catch-alls use it too.
- `userMessage` gained `isPresentable(_:)`: short, single-line, no `domain=`/`nserror`/`nwpath` markers,
  and not a raw JSON envelope (`.http` keeps a provider body verbatim). Anything that fails it is replaced
  with "The provider is unavailable right now.", and a status below 100 is reported that way instead of
  `An error (-1)`.
- `isRetryable` treats a status below 100 as transient, so the -1009 case offers "Try Again".

### Verification
- `swift test`: **397 tests / 59 suites green** (new: raw dump is not a message; transport classification;
  a dead route through the real repository is `.offline` and retryable).
- `xtool dev build`: **BUILD OK, no warnings**.
- **Not device-verified.** Whether the phone had no route or only failing DNS for the provider hosts is a
  runtime fact only the device can settle; the screen now names neither, and offers a retry either way.

## T-023 — captions resizing the player, and downloads that would not play

**Reported:** subtitles "mess up the player"; a long cue makes the picture overshoot its frame; a downloaded
Black-ish S1E1 reports "the internet connection appears to be off" / "no playback source".

### Root causes
1. `PlayerScreen` had the caption as a **sibling** of `surfaceCanvas` in the player `ZStack`. A `Text` that
   wraps into more lines than the 16:9 box is tall returns that taller height, a `ZStack` takes the union of
   its children, and `.aspectRatio(16:9, .fit)` reports what the child returned — so the picture's box grew
   with the cue. The `controlsVisible ? 96 : …` bottom padding made it worse: every chrome toggle changed
   the caption's height and therefore the player's size.
2. `AppModel.enqueueDownload(subject:targets:)` queued `info.preferredStream`, which takes the first `Auto`
   entry on the wire with **no video-capability check**. The provider lists a title's soundtracks beside its
   video, so a download could be an audio-only rung: it completes, it plays sound over a black surface, the
   track probe rejects it, and the player falls through to the network — offline, that is the connectivity
   error the user saw.
3. `playStream` never cleared `isPlayingLocal`/`isPlayingProgressive`, so after a rejected local copy the
   player kept the "Downloaded" badge, blamed the download in errors, and `retry()` (which sets
   `ignoresDownload = isPlayingLocal`) stopped trying the file for the rest of the session.

### Changes
- Captions are now `.overlay(alignment: .bottom)` on the surface canvas: an overlay is measured against the
  picture and cannot change its size. Capped at six lines so a malformed cue cannot paint the frame.
- Both enqueue paths use `PlaybackSourcePolicy` (video-capable) instead of `preferredStream`. That
  convenience now delegates to `PlaybackSourcePolicy.preferred(_:)` itself, so it cannot pick a soundtrack
  either.
- `downloadedItem()` ignores a completed row whose rendition is not video-capable (a queue written by the
  previous build can hold one).
- `playStream` clears the local flags on entry, and its failure path takes one last look at the download
  queue before reporting the provider unreachable.

### Verification
- `swift test`: **394 tests / 59 suites green** (new: audio-only `Auto` is never the preferred source).
- `xtool dev build`: **BUILD OK, no warnings**.
- **Not device-verified.** The layout fix is structural (an overlay cannot affect its base's size) but the
  caption's position against real chrome still needs a phone, and the download diagnosis is inferred from
  the reported error chain — if a *completed video* download is still skipped, the next step is to log
  `downloadedItem()`'s predicate values on device.

## T-022 — StreamHype as a second source

**Goal:** make StreamHype selectable on both surfaces without letting its embed pages reach the media
stack. The research is `docs/streamhype-network-map.md`: catalog is all TMDB, playback is third-party
embeds behind single-use tokens, WASM response crypto and host rotation.

### What changed

Go core

- `core/models`: `Stream.Kind`, `Quality.Kind`, `StreamRendition.Kind` + `KindWeb`.
- `core/provider/streamhype` (new): TMDB home rails, multi-search, detail, per-season episode tree, and
  `Stream()` answering the vidsrc-family embed with `kind: web`. Subject ids are `tmdb-movie-<id>` /
  `tmdb-tv-<id>`, so the media type comes back from the id alone and cannot collide in merged search.
- `core/catalog`: `renditions()` carries the kind through the flatten (per-quality, falling back to the
  stream, including the bare-URL branch).
- `cmd/cinemacore`: `CINEMACORE_PROVIDER=moviebox|streamhype|all`; `streamhype` fails fast without
  `TMDB_API_KEY`, `all` degrades to MovieBox with a warning.
- `contracts/openapi.yaml`: `kind` on `Stream`, `Quality` and `StreamRendition` (enum `[web]`).

iOS

- `CinemacoreCore`: `StreamRendition.kind` + `isWebEmbed`; `StreamHypeCatalogRepository` (port of the Go
  adapter: same ids, embed URL, title preference, season handling); `CatalogResolver.SourceMode.streamHype`,
  which reports a missing TMDB key instead of serving an empty catalog.
- App: Settings source picker + footer; `AppModel` refuses a web rendition in both download paths;
  `PlayerModel.webStreamURL` swaps the surface; `WebStreamView` renders the embed with ad/tracker domains
  blocked and pop-under entry points stubbed, and no media chrome on top.

### Verification

- `go build ./... && go test ./... -race`: green (`streamhype`, `catalog`, `server` incl. spec load).
- `swift test` (CinemacoreCore): **393 tests / 59 suites green**, incl. `StreamHypeRepositoryTests`.
- `xtool dev build` (app target): **BUILD OK, no warnings**; `xtool/Cinemacore.app` written.
- Gateway config guards exercised by hand: unknown provider and `streamhype` without a key both exit 1
  with a named error.
- **Not device-verified.** The embed pages, the content rule list and the app-review posture of a
  third-party web player all need a real device and a real TMDB key.

### Decisions worth remembering

- **No bundled TMDB key.** `TMDB_API_KEY` (env) then `TMDBAPIKey` (`Info.plist`); missing → demo catalog
  plus an explicit Settings sentence. A committed key cannot be rotated and is not ours to ship.
- **Web embeds are never media.** The `kind` marker exists so a client cannot hand a player page to
  `AVPlayer` or save it as a download; that is why it is asserted at the catalog, the wire and the
  download queue rather than only in the provider.
- **No native replay of the embed chains** — recorded in `docs/adr/0007`.
- 2026-10-23T08:07:39.715Z — done T-022: provider + iOS source mode green: go test -race, swift test 393, xtool build clean
- 2026-10-23T08:40:33.727Z — claimed T-023 — Player: captions must not resize the picture; downloads must queue a video rung
- 2026-10-23T08:40:33.795Z — updated T-023 -> review: caption overlay is layout-neutral; downloads pick video rungs; player retries local file before blaming network. swift test 394 green, xtool build clean; device check pending
- 2026-10-23T09:17:52.576Z — claimed T-024 — Play failures must show a readable reason and offer a retry
- 2026-10-23T09:17:52.640Z — updated T-024 -> review: transport failures classified at the session; raw NSError never reaches userMessage; -1 sentinel is retryable. swift test 397 green, xtool build clean
- 2026-10-23T09:33:32.133Z — claimed T-025 — A completed download must play offline, and never be reported as a network failure
- 2026-10-23T09:33:48.754Z — updated T-025 -> review: local hev1 repair in place + rejected-copy wording; swift test 401 green, xtool build clean
- 2026-10-23T10:05:04.548Z — claimed T-026 — Downloads carry their captions, and the player's levels live on the edges
- 2026-10-23T10:05:54.237Z — updated T-026 -> review: captions stored with downloads, edge-swipe volume/brightness with auto-hiding readout, download row opens its season. swift test 409 green, xtool build clean
- 2026-10-25T08:12:56.516Z — claimed T-027 — Landscape must play, and a DASH rung must never blank a quality pick
- 2026-10-25T08:12:56.611Z — updated T-027: player takes the wide layout when the phone turns; mask no longer forbids portrait; DASH rungs dropped for AVPlayer; streamhype 401 health fixed
- 2026-10-25T08:12:56.687Z — done T-027
