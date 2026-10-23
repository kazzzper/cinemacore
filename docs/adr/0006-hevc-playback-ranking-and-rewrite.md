# ADR 0006 — HEVC playback: rank, never reject; rewrite `hev1` only as a last resort

- **Status:** accepted
- **Date:** 2026-10-21

## Context

The player reported "sources uses HEVC, which cannot be rendered on this device" and offered no way out.

Two questions had to be separated:

1. **Can iOS stream HEVC at all?** Yes. Apple's HLS authoring spec requires HEVC in fMP4 for its HEVC
   variants, and every A9-and-later device decodes HEVC in hardware. HEVC is not the problem.
2. **Which HEVC *sample entry* does the provider serve?** The audit found `hev1` on Dune 720/480/360, The
   Odyssey 1080/480/360, and the Hindi Dune 480. Apple's spec is explicit about why that matters:

   > 1.10. You SHOULD use video formats in which the parameter sets are stored in the sample descriptions,
   > rather than the samples. (That is, use `'avc1'`, `'hvc1'`, or `'dvh1'` rather than `'avc3'`, `'hev1'`,
   > or `'dvhe'`.)
   >
   > — [HLS authoring specification for Apple devices](https://developer.apple.com/documentation/http-live-streaming/hls-authoring-specification-for-apple-devices)

So `hev1` is Apple's *discouraged* layout, not an unsupported codec. AVFoundation is built around `hvc1`
(parameter sets in the sample description) and frequently renders nothing for `hev1`, while the AAC track
plays normally. That is exactly "audio with a black picture".

### What the live probe could and could not establish

A probe against the gateway was run to answer the question that decides the fix: **do the provider's files
carry their parameter sets in `hvcC`?** If they do, the fix is a one-field rename. If not, the parameter
sets are in-band and the file must be remuxed.

**Measured on 2026-10-21 (this supersedes the open question below).** Three genuine `hev1` files from
`/ugc/video/download` were range-read through their `moov` (which sits at the **front** of every sample,
5.8–8.8 MB):

| File | Sample entry | `hvcC` | Arrays |
|---|---|---|---|
| Dune 360 (`bt/0808…`) | `hev1` | 2486 B | VPS 1, SPS 1, PPS 1, SEI 1 |
| Dune 480 (`resource/h265/deb0…`) | `hev1` | 2489 B | VPS 1, SPS 1, PPS 1, SEI 1 |
| Dune 720 (`resource/h265/b747…`) | `hev1` | 2448 B | VPS 1, SPS 1, PPS 1, SEI 1 |
| Dune 1080 (`extto/2616…`) | `avc1` | — | — |

**Conclusion: the parameter sets are in the sample description, so `hev1` → `hvc1` is a four-byte rename.**
Option B is valid and cheap; option C (remux) is not needed. **Option B is implemented** in
`CinemacoreCore/HEVCSampleEntry.swift` and verified against a captured 8.8 MB provider `moov`
(`HEVCSampleEntryLiveTests`), not only against a synthetic fixture. The earlier inconclusive probe follows, kept
because it documents how the decoy misled it.

The first probe did **not** produce a usable answer, and this ADR records why rather than guessing:

- `/subject-api/play-info` currently returns the **decoy** for these titles — `macdn.aoneroom.com/other/…`,
  `duration: 23`, `size: 824720`, `title: "The Odyssey_360P"`, declaring `codecName: "hevc"`. That is the
  anti-piracy placeholder `StreamRecovery.isDecoy` already rejects.
- `/subject-api/resource` returns the same decoy URL for every rendition of every title probed.
- Fetching it shows a real `avc1`/`avcC` sample entry — **the decoy declares `hevc` and is H.264.** So the
  declared codec is unreliable at the placeholder, and cannot be used to rank on its own.

The genuine `hev1` files the earlier audit sampled were not reachable during this probe, so the
`hvcC`-versus-in-band question is **open**. It needs one genuine `hev1` URL and a 256 KB range read.

### Consequence for the ranking that was just added

`StreamRendition.codec` is populated from `codecName`, and `PlaybackSourcePolicy.ranked` promotes a
"known decodable" codec above HEVC. The probe shows `codecName` is **wrong on the decoy and absent on two of
the three real rungs** (UGC and resource listings pass `nil`). That makes it a weak signal:

- it is useful when it is right (a real `h264` label beside a real `hevc` one);
- it is actively misleading when the label disagrees with the bytes.

It is kept because it only ever reorders candidates that are all still offered, so a wrong label costs a
fallback, never a dead end. But it must not be promoted to a **rejection** rule, and the plan below does not
depend on it.

## Decision

1. **Never reject a source for HEVC.** `hev1` is not proof of an unplayable file. The track probe rejects
   only a missing video track or undecodable audio; the `isReadyForDisplay` watchdog decides the rest, after
   the layer has had its say.
2. **`codecName` is a ranking hint, not a verdict.** It may reorder candidates. It may never drop one.
3. **Try to render the bytes as served first.** Only when a source is *measured* to produce no frame does
   the player fall back — another rendition, then another language version.
4. **The `hev1` → `hvc1` rewrite is a last resort, not the default path.** It is only worth building if the
   parameter sets are in `hvcC`, and only for sources the layer has already failed to draw.

## Why "render HEVC anyway" is not a viable exception

Asked directly, and checked against the **iOS SDK headers on this machine**
(`iPhoneOS.sdk`, Xcode 27 toolchain) rather than documentation prose:

- `CMFormatDescription.h:651` — `kCMVideoCodecType_HEVC = 'hvc1'`. **HEVC *is* `hvc1`** to CoreMedia.
- `AVVideoSettings.h:43` — `AVVideoCodecTypeHEVC /* @"hvc1" */`.
- **The string `hev1` does not appear anywhere in the entire iOS SDK** — not in headers, not in
  `.swiftinterface`, not in the `.tbd` stubs. `hvc1` appears; `hev1` does not.

So `hev1` is not a "HEVC variant iOS refuses"; it is a sample entry with **no codec type at all**. There is
nothing to opt into, because the platform has no identifier for it. An "exception for HEVC" would be an
exception for a fourcc that no Apple API names.

Three escape hatches exist, and each is costed:

| Workaround | Does it render `hev1` as served? | Cost |
|---|---|---|
| **Patch the sample entry** (`hev1`→`hvc1`, shipped) | **Yes**, when `hvcC` carries the parameter sets — which every sampled file does | ~150 lines, done |
| **Custom renderer** (`AVSampleBufferDisplayLayer` + `VTDecompressionSession`) | Yes — build a `CMFormatDescription` via `CMVideoFormatDescriptionCreateFromHEVCParameterSets` (iOS 11+), feed NALs from the `mdat` | Replaces the whole player: demux, A/V sync, seek, PiP, captions, AirPlay. **Weeks.** Rejected: it reimplements what `AVPlayer` already does, to avoid a 4-byte patch |
| **Transcode / remux server-side** | Yes | New infrastructure; no provider endpoint exists. Rejected |

The first option is not a compromise — it produces a file that is *already* what Apple asks for
(HLS authoring rule 1.10: "use `hvc1` … rather than `hev1`"). It is the same bytes with the label the
platform recognises.

## Options considered

| Option | Cost | Verdict |
|---|---|---|
| **A. Rank decodable codecs first, never reject** (shipped) | ~0, pure Swift | **Chosen.** Fixes the dead end. Does not make `hev1` render. |
| **B. Rename `hev1` → `hvc1` in the sample entry** | ~150 lines of MP4 box walking; only valid if `hvcC` carries the parameter sets | **Deferred** behind a measurement. Cheap and lossless if valid. |
| **C. Remux `hev1` → `hvc1` with in-band parameter sets** | Needs an H.265 parser; either write it in Swift or ship a static ffmpeg | **Rejected as the default.** Large, and unnecessary if the device renders the file as served. |
| **D. Server-side transcode to H.264** | New infra, storage, and the reverse-engineered gateway offers no such endpoint | **Rejected.** Out of scope for the client. |
| **E. Drop HEVC sources entirely** | Trivial | **Rejected.** Would hide titles that play perfectly, and removes the only fallback. |

## The follow-up, in order

### F1 — Measure the sample entry (blocking, ~30 min)
Get one genuine `hev1` URL (the audit's Dune 720 / Odyssey 1080 are the candidates). Range-read the first
256 KB and parse `moov/trak/mdia/minf/stbl/stsd/hev1`. Read `hvcC.numOfArrays` at byte 22 of the box body.

- `numOfArrays > 0` → parameter sets are in the sample description → **B is a one-field rename.**
- `numOfArrays == 0` → in-band → **C**, or stop and accept F2/F3.

The probe harness for this already exists (`.tools/tmpcheck/hevcprobe`); it only needs a URL that is not
the decoy.

### F2 — Surface the real failure to the viewer (no new code)
Already shipped. A source that never draws now says so, in a sentence that does not blame a codec it did
not measure, and the screen has a way back. If F1 proves the rewrite is not cheap, **this is the honest
end state**: the viewer is told the title cannot be drawn and is not trapped.

### F3 — Prefer `hvc1`/`avc1` when the gateway will say (cheap)
`resourceDetectors[].resolutionList` and the UGC resources carry per-rendition `codecName`; the two rungs
that currently pass `nil` (UGC, resource listing) could pass it. Worth doing only after F1, because the
decoy proves the field can lie.

### F4 — Rewrite the sample entry, if F1 says it is a rename (~150 lines)
Only for a source the layer already failed to draw, never as the default path:
1. Fetch the `moov` (the file's `moov` is at the front in every sample seen — `moov` before `mdat`).
2. Locate `stsd/hev1`; patch the four-character code to `hvc1` (4 bytes).
3. If `hvcC.numOfArrays == 0`, also lift the parameter sets out of the first sample's NAL units and rebuild
   `hvcC` — this is where the cheap version becomes a real remux, and where it should stop.
4. Serve the patched prefix through `ProgressiveAssetServer`; `mdat` is untouched, so a range request can
   pass straight through to the CDN.

Steps 1–2 are safe and lossless. Step 3 is the expensive half and should be its own decision.

## Consequences

- The dead end is fixed today, without waiting on the measurement.
- The `hev1` hypothesis is documented as *unconfirmed on device*, with the exact measurement that would
  settle it — rather than asserted from a container parse, which is what produced the original bad
  behaviour.
- The ranking added in T-018 is recorded as a hint with a known failure mode, so nobody later promotes
  `codecName` to a gate.
- If F1 shows in-band parameter sets, the honest answer is that these files cannot be made to render
  without a real remux, and F2 is the product answer.
