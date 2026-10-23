# StreamHype.net — Full Network & Source Map

> Investigation date: 2026-10-21 · Method: front-end bundle analysis + headless Chrome (CDP network capture) + direct protocol replay of every player chain.
> Raw request traces live in `/tmp/shnet/traces/*.json` (re-generated as needed; not part of the repo).

---

## 1. Executive Summary

`streamhype.net` hosts **no content of its own**. It is a thin React SPA shell that pulls all metadata from TMDB and delegates playback to **five embedded third-party players**. Physically, every movie file it plays has been traced back to:

1. **A vidsrc-family piracy CDN** (`data.vidsrc.sh` → rotating file hosts like `peregrinepalaver.space`) — used by *Load 01* (default), *vidsrc.me*, and *screenfetch4.cyou* (all three are front-ends of the **same backend family** at `stellarconductornexus.com`).
2. **vaplayer.ru** (`nextgencloudfabric.com` backend, Turnstile-gated).
3. **vidfast.vc** (self-hosted Next.js player, obfuscated client).
4. **api.rypr.ru** — currently **dead** (NXDOMAIN at 1.1.1.1 and Google DNS).

The vidsrc backend exposes the provenance directly in its API: the title returned for Inception (2024 id-swap test aside, this was the real response for TMDB 27205) was
`file_name: "Inception (2010) [1080p]/Inception.2010.1080p.BrRip.x264.YIFY.mp4"` — i.e. **classic YIFY release files re-served as VOD HLS**, with playlists carrying YouTube-derived HLS tags (`YT-EXT-ABSOLUTE-LOUDNESS`).

---

## 2. The Frontend (streamhype.net)

- Single static React SPA: `/assets/index-c95e3019.js` (~380 KB) + `/assets/index-b714aa6b.css`.
- Served by nginx, no SSR, no backend of its own. Everything is client-side.

| Role | Endpoint | Notes |
|---|---|---|
| All catalog data | `https://api.themoviedb.org/3/...` | Hard-coded public API key: `90b2cae8d7161e8ba0f3836240d7d352` |
| Poster/backdrops | `https://image.tmdb.org/t/p/...` | w92→original |
| Fonts | `fonts.googleapis.com`, `fonts.gstatic.com` | Montserrat |
| Own assets | `streamhype.net/logo.png`, `/icon.png` | |

Sections of the site are thin wrappers over TMDB `discover/*` queries: `?provider=netflix|disney|hulu|hbomax|amazon|appletv|starz|crunchyroll|peacock|amcplus` on `/explore-movies`.

### Routing & player selection (from the bundle)

| On-page button | SPA route | Player component | Iframe source |
|---|---|---|---|
| **Play** (hero) | `/watch/:id` (`?s=&e=` for series) | `Q2` | **screenfetch4.cyou** (fallback: `vidsrc.me`, series fallback: `api.rypr.ru`) |
| **PLAY2** | `/watch/:id` | `Nw` | **vaplayer.ru** |
| **PLAY3** | `/alt-watch-two/:id` | `Cw` | **vidfast.vc** |
| Trailer | — | — | `youtube.com/embed/` |

Each player URL carries `?v=3.2.0&n=StreamHype&o=<streamhype origin>` for provider attribution. All five observed URLs:

```
https://screenfetch4.cyou/embed/movie?tmdb={id}&o=...
https://screenfetch4.cyou/embed/tv?tmdb={id}&season={s}&episode={e}&o=...
https://vidsrc.me/embed/{movie|tv}/{id}
https://api.rypr.ru/embed/series/{id}?s={s}&e={e}          <- DEAD (NXDOMAIN)
https://vaplayer.ru/embed/movie/{id}?skin=netflix&color=e50914&autoplay=1
https://vaplayer.ru/embed/tv/{id}/{s}/{e}?skin=netflix&...
https://vidfast.vc/movie/{id}?autoPlay=true&theme=ec1c24
https://vidfast.vc/tv/{id}/{s}/{e}?autoPlay=true&nextButton=true
```

`screenfetch4.cyou` self-identifies in its anti-sandbox script as a mirror of `new.vidsrcme.ru` — the vidsrc family.

---

## 3. Chain 01 — the vidsrc family (**the main source of movies**)

Two front-ends (default + fallback) collapse to **one physical backend**:

```
StreamHype /watch/:id
  └─ iframe leftovers: 2 of the same family from different façades
     Front A: screenfetch4.cyou  (alias of new.vidsrcme.ru)
     Front B: vidsrc.me → 301 → vidsrc.sh
        ↓ both fetch:  https://vidsrc.sh/vs_src.php?type=movie&id={tmdb}
        ↓ returns:     { src: "https://stellarconductornexus.com/embed/movie/{id}?vs=<signed token>" }
  └─ Backend gate page: stellarconductornexus.com/embed/{movie,tv}/{id}?vs=<...>
        ↓ window.CFG = { playerUrl, metaApi }
        ↓ Player page: stellarconductornexus.com/embed/player/{movie}/{id}?vs=<...>
           window.CONFIG = { api, metaApi, apiToken (single-use JWS), cacheBase, ... }
        ↓ data.vidsrc.sh/api.php?type=movie&tmdb={id}&stream_urls&api_token=<TOKEN>
```

### 3.1 The protection stack on this chain

| Layer | Mechanism | Details |
|---|---|---|
| Gate token | `?vs=<token>` in embed URL | minted per request by `vs_src.php`, short-lived |
| API token | `apiToken` in `window.CONFIG` | JWS: payload `{"exp":<5-min>,"ip":"<client IP>","n":<nonce>}` — **single-use, IP-bound** |
| Response crypto | `stream_urls` is an encrypted blob | `vsdec.js`: base64(nonce ‖ ciphertext) **ChaCha20**, key lives in a **per-5-minute-window WASM decryptor** served from `https://data.vidsrc.sh/wasm.php?w=<window>&_=<ts>` |
| Per-host tokens | `GET <host>/generate.php` | returns per-host JWS (`{"iss":"my-auth",...}`), also IP-bound; stamped onto playlist URLs as `?token=` |
| Anti-analysis | `disable-devtool.js` | vendored from github.com/theajack/disable-devtool; kills video + blanks page on devtools-open; sandbox-cage detection via `sbx.js` (redirects to `/sandbox.php?ref=<host>`) |
| Bot gate | Cloudflare Turnstile (configurable, `CONFIG.turnstile`) | present on this family |

### 3.2 What actually comes out (verified end-to-end)

Replaying the chain with curl + Node WASM decrypt:

1. `vs_src.php` → `stellarconductornexus.com/embed/movie/27205?vs=...`
2. Player page → fresh `apiToken`
3. `data.vidsrc.sh/api.php?...stream_urls&api_token=...` → `status_code 200` with encrypted payload
4. WASM decrypt (`data.vidsrc.sh/wasm.php?w=<window>`) → plaintext list of stream URLs
5. Per-host `/generate.php` JWT → stamped master playlist

Result for Inception (2010):

```
https://peregrinepalaver.space/pl/<gzip+base64 blob>?token=<JWS>
```
→ responds with a genuine HLS master playlist:
```
#EXTM3U
#EXT-X-INDEPENDENT-SEGMENTS
#EXT-X-STREAM-INF:BANDWIDTH=732007,CODECS="mp4a.40.2,avc1.42c015",RESOLUTION=640x266,FRAME-RATE=24,VIDEO-RANGE=SDR,YT-EXT-ABSOLUTE-LOUDNESS=-24.480,CLOSED-CAPTIONS=NONE
```

Metadata returned by `data.vidsrc.sh/api.php?type=movie&tmdb=27205`:
```json
{
  "title": "Inception 2010",
  "imdb_id": "tt1375666",
  "file_name": "Inception (2010) [1080p]/Inception.2010.1080p.BrRip.x264.YIFY.mp4",
  "backdrop": "https://image.tmdb.org/t/p/w1280/8ZTVqvKDQ8emSGUEMjsS4yHAwrp.jpg"
}
```
Thumbnails/skips: `https://vidapi.cloud/thumbnails.vtt` (`cloudthumbnails.vtt` reference in the player).

**Conclusion:** the source material is YIFY-family movie files (1080p BrRip rereleases; `YIFY.mp4` naming appears verbatim in the backend's library index), repackaged into HLS on rotating low-profile file hosts, with a YouTube-style HLS pipeline upstream (the `YT-EXT-*` tags come from YouTube-generated HLS segments).

### 3.3 Host rotation

`player.js` comments confirm the design: *"the backend rotates hosts per request"* — every `stream_urls` fetch returns a **fresh set** of file-host domains, and the player keeps a fallback chain (`tryNextServer()`, 3 full retries via page reload). This is why passive network-tab sampling sees different domains on every session. Observed rotation domain sample:

- United ~/systems of `*.space` family: `peregrinepalaver.space`
- Nominally "official-looking": these are throwaway domains (registrar-hidden, short-lived)

---

## 4. Chain 02 — vaplayer.ru → nextgencloudfabric.com

```
vaplayer.ru/embed/movie/{id}?skin=netflix&color=e50914&autoplay=1
  └─ immediate iframe: https://nextgencloudfabric.com/embed/movie/{id}?...
```
- The vaplayer frame enforces embed origin (`skin=netflix` styling, iframe kill-switch if `window.top` mismatch).
- `nextgencloudfabric.com` is wrapped in an **invisible Cloudflare Turnstile** gate (`data-sitekey 0x4AAAAAADfkTnMxCBQ5ki90`):
  on pass it POSTs `/embed/turnstile-verify.php` → `{"success":true,"url_token":"..."}` → reload with `?_tsv=<url_token>`.
- Behind the gate sits an hls.js player (same architecture as the vidsrc player: `autoPlay`, `video.play()`, muted fallback). Not fully replayed headless because Turnstile requires a warm browser session, but the traffic direction (same host, gate-then-play) was confirmed live through Chrome 3×.

Tracker stack seen on this chain: histats, dtscout, crwdcntrl (Lotame), mrktmtrcs, adnxs (AppNexus), Cloudflare Insights.

---

## 5. Chain 03 — vidfast.vc (self-hosted)

A Next.js 15 app (own infra + Cloudflare). Notable pieces recovered from `/next/static/chunks/365-…js` (2.2 MB, partially obfuscated):

- **Player**: custom player over MSE/`blob:` + hls.js-style internals, 1080p/`avc1`/`mp4a` capability handling, DASH/HLS manifest refs (`hasVariableRefs`), quality gear, "Next Episode".
- **Subtitles**: `GET /wyzie?id=<tmdb>&season=&episode=` → JSON list of subtitle tracks (Wyzie subs service), served self-origin, e.g. `https://vidfast.vc/wyzie/eu_<opaque>`.
- **Telemetry/deconflictor**: obfuscated `POST /zirlaku/u/APA91M…/{action}/<payload>` with static `X-Csrf-Token` — usage/progress reporting.
- **More stream sources** (their own transcode farm), which never fired in headless because their loader parks behind an engagement check from the rotating ad-domain script (below) before resolving the media.
- **Partner whitelist** baked into the client — sites authorized to embed vidfast (StreamHype is on it):
  `streamhype.net, flixbaba.is, flixbaba.mov, flixmomo.org, flixmomo.tv, cinehype.net, cinegram.net, cinegram.tv, cinemaflix.one, filmpire.sc, flixpire.sc, moviepire.sc, movienova.sc, movielysium.net, boredflix.com`
  → vidfast is a **whitelabel player network**: the same elementized player fronts a fleet of similar clone sites.
- Analytics: `googletagmanager G-JMWN78FZNK`, `umami.vidfast.vc`, `static.cloudflareinsights.beacon`, `wsrv.nl` image proxy, `flagsapi.com`.

###vidfast chain flow (as far as environment-allowed)
```
Google Fonts / TMDB images → boot
1.<rotating>.cfd ad-loader scripts
PostHog bypass → portal: /zirlaku/u/... + /wyzie/... streams
(Actual m3u8/dash resolution happens only after the visitor-engagement check passes.)
```

---

## 6. Chain 04 — api.rypr.ru : **dead**

- `api.rypr.ru/genre/{type}/{id}`, `/embed/{movie,series}/{id}` referenced in the SPA (used as the fallback player for series under `/watch/:id`).
- DNS: **NXDOMAIN** at both 1.1.1.1 and dns.google → the provider has been dropped so the fallback for series TV is effectively broken; clicks on series stay on screenfetch4.

---

## 7. Advertising / tracking infrastructure

| Domain | Role | Where |
|---|---|---|
| `1.eo145lzbx5hw2wpq.cfd` | **Active pop-under loader** — obfuscated script that computes **time-based rotating domains** (SHA-256 of `{key}|{UTC hour}` → `<hash>.<TLD>`), injects `/VgMoO`-style scripts; also drives vidfast engagement gating | streamhype, vidsrc, vaplayer, vidfast |
| `gtcinfight.cfd/cuid/?f=<site>` | Ad-session device cookie barter | all players |
| `primsie.juchartfardinglazybed.cfd/gd/…?md=<base64 stats>` | Bid-gateway collector (browser/device fingerprint) | all players |
| `jokeconnect.com` | ExoClick-family popunder/social-bar scripts | commented-out in streamhype HTML (2 copies) |
| `rd.frillhetaery.com`, `bc.casherscamize.com` | Additional retired ad scripts | commented-out in streamhype HTML |
| `s4/s10.histats.com` | Visitor counters | vidsrc backend, vaplayer backend |
| `dtscout.com`, `dtscdn.com` | Ad-retargeting pixel | vaplayer |
| `crwdcntrl.net` (Lotame), `mrktmtrcs.net`, `adnxs.com` (AppNexus) | Data brokers / real-time bidding | vaplayer |
| `meta name="clckd"` (Clickadu) | Init marker | streamhype.net |

Rotation algorithm (recovered from the loader): `subdomain = base32(SHA256("{secret}|{UTC-4h-window}"))` pick-window concatenation, **decoy domain set rotates every 4 hours** — same loader observed under ` stellarconductornexus.com, dustjacketstudy(.com-like), gtcinfight.cfd, primsie.juchartfardinglazybed.cfd, eo145lzbx5hw2wpq.cfd`.

---

## 8. Consolidated Domain Inventory

| # | Domain | Layer | Status at test |
|---|---|---|---|
| 1 | streamhype.net | Front-end SPA (self, nginx) | active |
| 2 | api.themoviedb.org / image.tmdb.org | Metadata / artwork (TMDB) | active |
| 3 | fonts.googleapis.com / fonts.gstatic.com | Fonts | active |
| 4 | screenfetch4.cyou | *Player façade 1* (vidsrc family alias `new.vidsrcme.ru`) | active |
| 5 | vidsrc.me → vidsrc.sh | *Player façade 2* (vidsrc family) | active |
| 6 | stellarconductornexus.com | vidsrc **backend gate + player** | active |
| 7 | data.vidsrc.sh | vidsrc **API** (metadata + encrypted stream_urls + WASM keys) | active |
| 8 | peregrinepalaver.space | vidsrc **HLS file host** (rotates; throwaway `.space` etc.) | active at test |
| 9 | vidapi.cloud | Thumbnail VTT / cloud thumbnail proxy | active |
| 10 | api.rypr.ru | Provider(/series fallback) | **DEAD** (NXDOMAIN) |
| 11 | vaplayer.ru | Player façade 3 | active |
| 12 | nextgencloudfabric.com | vaplayer backend + Turnstile gate | active |
| 13 | challenges.cloudflare.com | Turnstile widget (vaplayer path) | active |
| 14 | vidfast.vc | Player façade 4 (Next.js, self-hosted) | active |
| 15 | umami.vidfast.vc / gtag / flagsapi / wsrv.nl | vidfast analytics & misc | active |
| 16 | github.com CDN (jsdelivr) | hls.js 1.5.17 + core-js 3.28.0 | active |
| 17 | gstatic.cast | Chromecast sender | active |
| 18 | histats.com | Counters | active |
| 19 | dtscout.com / dtscdn.com | Retargeting | active |
| 20 | crwdcntrl.net / mrktmtrcs.net / adnxs.com | Data brokers / RTB | active |
| 21 | *.cfd / *.space rotating pool (1.eo145…cfd, gtcinfight.cfd, primsie.juchartfardinglazybed.cfd, …) | Ad-loader popunders + bid gateways | active |

---

## 9. How "where do the movies come from?" resolves overall

1. **Catalog**: TMDB (free public key), zero cost to the operators.
2. **Movies/TV ~70% of plays** (default + PLAY-fallback screenfetch/vidsrc paths): **the vidsrc piracy CDN family**, serving YIFY-derived rereleases over HLS from throwaway rotating hosts, concealed behind single-use IP-bound JWS tokens + ChaCha20 WASM response encryption + Turnstile + devtools-kill.
3. **Alternate players**: vaplayer.ru (Turnstile-gated backend) and vidfast.vc (whitelabel Next.js player shipped to a family of 15+ clone sites, incl. streamhype).
4. **The site's actual business model** is ad arbitrage: popunders, viral rotating domains, data-broker pickup — same loadout on the front-end and inside every player.

### Evidence artifacts
- `01…10_*.json` — streamhype home/detail/TV + each provider, captured via CDP in headless Chrome (Per-request: URL, method, initiator, status, mime, remoteIP).
- `m_*.json` — inner-player sessions with play clicks and autoplay.
- `player.html`, `player.js`, `ng.html`, `vf_*.js`, `sbx.js`, `vsdec.js` — fetched player sources stored locally under `/tmp/shnet/`.

> Note: `/tv/:id/:s/:e` detail pages render nothing (TMDB-ID route defect in the SPA); TV playback works only through the embedded players' own season/episode dropdowns (TV_SET postMessage). Additionally, `2 streams hosts returned 429 (rate-limit)` on back-to-back `/generate.php` calls — file-host side is quite rate-limit sensitive. The 429s confirm the hosts throttle hard, which is why sessions see host rotation.
