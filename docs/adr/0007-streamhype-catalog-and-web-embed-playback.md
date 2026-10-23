# ADR 0007 — StreamHype as a second source: TMDB catalog, web-embed playback

- **Status:** accepted
- **Date:** 2026-10-23

## Context

StreamHype is the second catalog source this product wants after MovieBox. Its shape, measured in
`docs/streamhype-network-map.md`, splits cleanly in two:

1. **Catalog** — the SPA holds no metadata of its own. Every rail, search row and detail page is a
   TMDB query (`api.themoviedb.org/3`), and posters come from `image.tmdb.org`. A clean REST API, no
   scraping.
2. **Playback** — delegated to embedded third-party players (five chains; the vidsrc family is the
   default). Each chain protects its files with single-use IP-bound tokens, per-window WASM response
   crypto and rotating file hosts, and wraps the player in an ad/tracker stack that also carries
   anti-devtools and sandbox-cage scripts (§3.1, §7).

So one half is the easiest integration in the project and the other is the hardest. The question this ADR
settles is what playback is allowed to be.

## Decision

1. **`core/provider/streamhype` serves the catalog from TMDB.** Home, search, suggestions, detail and the
   episode tree are REST calls. Subject ids are namespaced `tmdb-movie-<id>` / `tmdb-tv-<id>`, so the media
   type is recoverable from the id alone and ids can never collide with another provider's subjects in
   merged search.
2. **Playback answers a browser embed, marked `kind: "web"`.** `Stream()` builds the embed URL StreamHype's
   own Play button opens and returns it as a rendition whose `kind` is `web`. The client opens it in a web
   view. The marker is carried through `core/catalog` into `PlayInfo`, because it is the only thing
   standing between an HTML player page and the media stack — the failure mode otherwise is a black
   `AVPlayer` surface plus a download that saves an HTML shell.
3. **Native protocol replay is not attempted.** Re-deriving the token mint, WASM decrypt and host rotation
   is a permanent maintenance liability against a backend that rotates to break exactly that, and the
   embed is the path StreamHype itself keeps working.
4. **The TMDB key is configuration, never a committed default.** The gateway reads `TMDB_API_KEY`
   (`CINEMACORE_PROVIDER=streamhype` fails fast without it); the iOS app reads `TMDB_API_KEY` from the
   environment, then `TMDBAPIKey` in `Info.plist`, and reports the missing key in Settings instead of
   serving an empty catalog. A key checked into source cannot be rotated without a release, and it would
   be the registering account's key, not the user's.
5. **The provider is opt-in.** `CINEMACORE_PROVIDER` selects `moviebox` (default), `streamhype` or `all`;
   the app's source switch gains a `streamHype` mode. The deployed gateway's shape does not change
   unintentionally, and merging sources stays a deliberate act.

## Alternatives considered

| Option | Cost | Verdict |
|---|---|---|
| **A. TMDB catalog + web-embed playback** (shipped) | ~1 provider adapter, one `WKWebView` view, one wire field | **Chosen.** Both halves are stable on their own side: the catalog is a documented API, the player is maintained by the party being wrapped. |
| **B. Replay the vidsrc chain natively** (token mint + WASM + file hosts) | Large, and decays whenever the backend rotates; every client re-implements it | **Rejected.** The map documents rotations that exist to defeat this; a native path would be rewritten repeatedly for no extra capability. |
| **C. Scrape the SPA's HTML/JS for catalog data** | Fragile HTML/JSON scraping | **Rejected.** The SPA is a thin client over TMDB; scraping it would add fragility with no information gain. |
| **D. Ship StreamHype's published TMDB key as a bundled default** | Zero setup | **Rejected.** Third-party credential in the binary, unrotatable, revocable from under every installed copy. |
| **E. Expose only the catalog and refuse playback** | Cheap | **Rejected as the end state.** A catalog that cannot play is not a source; the embed is the working playback path. |

## Consequences

- StreamHype titles play, but with the embed's own chrome and behaviour. The app does not get the native
  player's clock, so:
  - **no download and no offline playback** — `AppModel` refuses a `web`-kind rendition and says why;
  - **no resume point** — the embed never reports a position, so offering "resume" would lie;
  - **no caption or speed control** — the embed owns both. `Subtitles()` returns none rather than
    advertising tracks the web player does not consume.
- The app's web view is hardened: ad/tracker domains from the map are denied by a `WKContentRuleList`, pop-under
  entry points are stubbed at document start, and the anti-devtools/cage scripts are blocked. The rule list
  is a literal so it stays reviewable; rotating pop-under subdomains are why the user-script stubs exist as a
  second layer.
- Two implementations, one behaviour: `core/provider/streamhype` and
  `CinemacoreCore/StreamHypeRepository` are ports of each other (ids, embed URL, title preference, season
  handling). A change to one is a change to both.
- TMDB requires attribution; the app's About screen and Settings footer are where that belongs if this ships
  publicly.
- The bundled demo catalog still stands in when the key is missing, so the app never looks broken — Settings
  says exactly what is missing.
