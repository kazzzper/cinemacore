# dsh-player

- 2026-10-21T07:36:10.894Z — registered (codex)
- 2026-10-21T07:36:31.233Z — claimed T-018 — P1: HEVC (hev1) playback — codec-aware source ranking + error-screen return
- 2026-10-21T07:47:47.976Z — updated T-018: hev1 no longer rejected at inspection (device may decode it); layer watchdog decides. Codec now carried on StreamRendition and ranked ahead of HEVC. Error screen gains Return. swift test 329 green, xtool build OK

## T-018 — HEVC (hev1) sources and the error-screen dead end

**Symptom reported:** "Something went wrong … sources uses HEVC, which cannot be rendered on this device",
with no way off the screen.

### What was wrong
1. `PlayerModel.sourceInspected` treated a `hev1` *sample entry* as proof the source was unplayable and
   abandoned it before the layer ever reported a frame. The device may well decode HEVC, so this turned a
   working title into a hard failure, and it fired before any evidence of a black picture existed.
2. The provider's `codecName` was decoded (`WireStream.codecName`) and then thrown away — no rendition
   carried it, so nothing could rank a decodable copy ahead of HEVC.
3. The player hides the navigation bar and owns every exit (`navigationBarBackButtonHidden(true)`), so the
   failure screen had **no exit**: the only control was "Try Again", which cannot fix a codec or an empty
   payload. Same dead end in the `.empty` and `.locked` states.

### What changed
- `StreamRendition` gained `codec` (optional, defaulted — no call site breaks). `StreamRecovery.renditions`
  and the three repository rungs now carry `codecName` through.
- `PlaybackSourcePolicy`: `isKnownDecodableVideo` / `isHEVC`, and `ranked` sorts **Auto → known-decodable →
  resolution desc → provider order**. HEVC is demoted, never dropped: it is still offered, still the
  fallback, still selectable.
- `PlayerModel`: `hev1` no longer rejects. Only a missing video track or audio no codec can render does.
  The existing `isReadyForDisplay` watchdog is what catches a real black picture, and it now reuses the
  measured inspection (`measuredInspection`) so the message names the codec that actually failed.
- `invalidSourceMessage` names HEVC only when the probe measured it, and has a separate sentence for
  "video track exists but never drew".
- `StateView` gained `returnTitle` / `returnAction`, rendered in `.failed`, `.empty` and `.locked`.
  `PlayerScreen` passes `"Back to details"` → `dismiss()`.

### Verification
- `swift test` (CinemacoreCore): **329 tests / 51 suites green**, incl. new `PlaybackCodecRankingTests` (8).
- `xtool dev build`: **BUILD OK**.
- `go build ./... && go test ./core/...`: green (no Go touched).
- **Not device-verified.** The `hev1`-does-not-render hypothesis still needs a physical device: the parser
  proves the sample entry, not what AVFoundation draws.

### Incidental fix
`FreeSubtitles.displayName` returned `"POB"` for Brazilian Portuguese because Foundation has no name for
the legacy code. Added a small alias table for the deprecated codes seen in real listings. Two pre-existing
`FreeSubtitlesTests` failures went green with it.

### Follow-up (not done)
- Remux `hev1` → `hvc1` (sample-entry rewrite only) in `ProgressiveAssetServer` would make the bytes
  themselves playable. That is a real MP4 rewrite, not a patch, and wants its own task.

## Follow-up research — can HEVC be streamed at all?

**Yes.** Apple's HLS authoring spec requires HEVC in fMP4 for HEVC variants; A9+ decodes it in hardware.
The blocker is the **sample entry**, not the codec: Apple rule 1.10 says use `hvc1` rather than `hev1`
(parameter sets in the sample description vs in-band). `hev1` is Apple's discouraged layout, not an
unsupported one.

**Probe result (inconclusive, and that matters):**
- `/subject-api/play-info` returns the **decoy** for the audited titles (`macdn…/other/`, duration 23,
  size 824720, title `"The Odyssey_360P"`) — and it declares `codecName: "hevc"` while the bytes are
  `avc1`/`avcC`. **The decoy lies about its codec.**
- `/subject-api/resource` returns the same decoy URL for every rendition of every title probed.
- The genuine `hev1` files were not reachable, so `hvcC.numOfArrays` (parameter sets in the sample
  description or in-band) is still **unmeasured**.

**Consequence for T-018's ranking:** `codecName` is a weak signal — wrong on the decoy, absent on the UGC
and resource rungs. It is safe *only* because it reorders candidates that are all still offered. Do not
promote it to a rejection rule.

Written up as `docs/adr/0006-hevc-playback-ranking-and-rewrite.md`, with the measurement that would settle
`hev1` → `hvc1` and the four options (rank / rename / remux / transcode) costed.
- 2026-10-21T08:06:05.230Z — updated T-019 -> doing: MEASURED: 3/3 genuine hev1 files carry VPS+SPS+PPS in hvcC (numOfArrays=4). Rename hev1->hvc1 is valid; no remux needed. moov is at front (5.8-8.8MB).

## T-019 — MEASURED, and the fix is built

**Measurement (genuine files, not the decoy):** three `hev1` files from `/ugc/video/download`, `moov` at the
**front** (5.8–8.8 MB, so the earlier 256 KB prefix probe was simply too small):

| File | entry | hvcC | arrays |
|---|---|---|---|
| Dune 360 `bt/0808…` | `hev1` | 2486 B | VPS 1, SPS 1, PPS 1, SEI 1 |
| Dune 480 `resource/h265/deb0…` | `hev1` | 2489 B | VPS 1, SPS 1, PPS 1, SEI 1 |
| Dune 720 `resource/h265/b747…` | `hev1` | 2448 B | VPS 1, SPS 1, PPS 1, SEI 1 |
| Dune 1080 `extto/2616…` | `avc1` | — | — |

**`numOfArrays = 4` with VPS/SPS/PPS present → the rename is lossless.** No remux needed.

**Built:** `CinemacoreCore/HEVCSampleEntry.swift` — `inspect(moov:)` and `rewrite(moov:)`. It patches only
the four-character code of a `hev1` video sample entry, never touches `mdat`, and **refuses** when
`hvcC` carries no parameter sets (renaming there would claim a description that does not exist).

Tests: 10 synthetic (incl. audio-track confusion, 64-bit box sizes, truncation, in-band refusal) + 1 against
a captured real `moov`. Full suite **346 tests / 54 suites green**; `xtool dev build` OK.

**Not yet wired into playback.** The rewrite is a pure Core transform; nothing calls it yet. Wiring it means
routing the item through `ProgressiveAssetServer` with a patched `moov` prefix, which is a separate change
with its own risk (range serving, seek, the `.part` path). Deliberately not bundled here.

**Still needs a device** to confirm the premise: that the device fails to draw `hev1` at all. The rewrite is
harmless if it does not (an `hvc1` file plays exactly as `hev1` did), so it is safe to ship ahead of that
confirmation — but the confirmation is what proves the bug was real.

## "Can we render HEVC anyway?" — answered from the SDK

Checked the actual `iPhoneOS.sdk` headers (Xcode 27 toolchain, on this machine) rather than prose docs:

- `CMFormatDescription.h:651` → `kCMVideoCodecType_HEVC = 'hvc1'`. HEVC **is** `hvc1` to CoreMedia.
- `AVVideoSettings.h:43` → `AVVideoCodecTypeHEVC /* @"hvc1" */`.
- **`hev1` appears nowhere in the entire iOS SDK** — headers, `.swiftinterface`, or `.tbd`. `hvc1` does.

So there is no "HEVC exception" to make: `hev1` is a sample entry the platform has no codec type for. An
exception would have to be for a fourcc no Apple API names.

Escape hatches, costed in ADR 0006: patch the sample entry (**done, and it is the same bytes with the label
Apple asks for**), a custom `AVSampleBufferDisplayLayer` + `VTDecompressionSession` renderer (works, but
reimplements the whole player to avoid a 4-byte patch — rejected), or server-side transcode (no endpoint
exists — rejected).

## Henry Danger case — the device confirmed it, and the repair now runs automatically

**Reported:** "Every available source is HEVC which this device cannot render", then a few seconds of sound
and no video.

That is the exact signature: **AVPlayer plays the AAC track, demuxes fine, and never produces a frame.** So
the `hev1` hypothesis is now confirmed on device — no longer "needs device verification".

**What that message used to do wrong:** it blamed HEVC. The device decodes HEVC perfectly; it has no codec
type for `hev1` (`kCMVideoCodecType_HEVC = 'hvc1'`, and `hev1` appears nowhere in the iOS SDK). Wording
corrected.

**What happens now, automatically:**
1. The item becomes ready → sound starts, no picture.
2. `watchForPicture` gives it 1.5 s intervals; audio plays, frame never arrives.
3. `recoverFromInvalidSource` now calls **`repairHEVCSource()` first** — before abandoning the source.
4. That fetches the file's `moov` (range read), patches `hev1`→`hvc1` in place, writes the repaired copy to
   `Caches/HEVCRewrite/`, and rebuilds at the same clock.
5. Only if the repair declines (in-band parameter sets, `moov` after `mdat`, already tried once) does the
   old fallback ladder run and end at the failure screen.

**Guard rails:**
- One repair attempt per URL (`repairedSourceURLs`) — a repaired source that still fails is a different
  failure, so it does not loop.
- Remote streams only. Re-encoding a downloaded `.part` in place would cost a full copy for a fix the CDN
  copy gets free.
- `moovPrecedesMedia` is checked: a patched index can only be spliced in place when the media data follows
  it.
- Range-ignoring servers are handled (the index is sliced out of the full body).
- If the repair does not land, the message no longer claims the device cannot decode HEVC.

**Verification:** 364 tests / 56 suites green (8 new `HEVCRewriteTests` covering whole-file repair, hvc1
passthrough, in-band refusal, range-ignoring servers, non-MP4, `moov`-after-`mdat`, and header
passthrough). `xtool dev build` OK.

**Honest limits:** the repair costs one full download of the title into the cache (the cache path is
`Caches/HEVCRewrite`, so iOS can reclaim it). That is fine for the few titles that need it, and it is why
the repair is lazy — only sources that provably fail to draw pay for it. Not yet run on a device with
Henry Danger itself.
- 2026-10-21T09:30:32.450Z — updated T-018: Device-confirmed: hev1 plays audio, never draws. repairHEVCSource() now patches hev1->hvc1 automatically on a failed source. 364 tests green, build OK.
