# ADR 0005 — A bundled fixture catalog ships alongside the live gateway

- **Status:** accepted
- **Date:** 2026-10-17

## Context

The Go provider layer is unfinished (T-003 session/provider, T-004 server endpoints) and the gateway
answers `/v1/home` with `502 upstream_error`. The iOS client cannot be exercised end-to-end against
real data, and it will not be able to for some time: T-003 and T-004 have no owner yet, and T-007 (the
iOS app) depends on T-004.

Blocking the UI on the provider would serialize the entire project behind the least predictable part
of it — a reverse-engineered upstream that fails with opaque 502s.

## Decision

`CatalogRepository` is a protocol with two interchangeable implementations, and the app picks one at
launch.

- [`CatalogRepository.swift`](../../mobile/ios/CinemacoreCore/Sources/CinemacoreCore/CatalogRepository.swift)
  defines the boundary: `home`, `search`, `detail`, `seasons`, `playInfo`, `suggestions`, plus
  `sourceName` and `isLive`. Screens never know which side they are talking to.
- `RemoteCatalogRepository` is contract-first HTTP over `APIClient`: `/v1/home`, `/v1/search`,
  `/v1/detail/{id}`, `/v1/detail/{id}/seasons`, `/v1/play`, `/v1/search/suggestions` — the paths added
  to `contracts/openapi.yaml` in the same change.
- [`FixtureCatalog.swift`](../../mobile/ios/CinemacoreCore/Sources/CinemacoreCore/FixtureCatalog.swift)
  is the bundled catalog: **50 titles (42 films, 8 series)**, **7 home rails**, and **8 series with
  full season/episode trees (17 seasons, 132 episodes)**, plus a deterministic playback ladder per
  title (480p/720p/1080p, plus 4K only above an 8.9 rating) and English/Hindi/Spanish subtitle tracks.
- `CatalogResolver` resolves once at launch: a 4-second `/health` probe chooses the live gateway when
  it answers, and falls back otherwise, returning a human-readable note ("Live · host", "Gateway
  unreachable — showing the bundled catalog", "Bundled catalog").
- The UI states which source is in use: `sourceName`/`isLive` are surfaced in Settings and on the
  demo banner. The lookup contract is also honest about failure — only `detail(id:)` and `playInfo`
  throw, and only for an id the catalog does not carry.

## Consequences

- The whole UI is buildable, navigable and demonstrable on a device today, with no gateway running.
- Flipping to live data is a configuration change (`LibrarySettings.gatewayURL`, default
  `http://127.0.0.1:8080`), not a rewrite: the screens already speak to the protocol.
- Every screen renders against real shapes — rails, posters, episode trees, renditions, subtitle
  tracks — so integration problems surface now instead of on the day the provider lands.
- **Cost:** the demo path must never be mistaken for live data. That is why `isLive` exists and why
  the source is labelled in the UI, rather than being an implicit build flag.
- **Cost:** the fixture data is hand-written and can drift from what the provider actually returns.
  Nothing enforces that the two agree; only the shared `Subject`/`Season`/`PlayInfo` types do, and
  they are permissive (`decodeIfPresent` with defaults in `Models+Decoding.swift`), so a real payload
  with different key names could decode "successfully" into empty rails.
- **Cost:** the fixtures are not playable media. Posters are seeded `picsum.photos` URLs (the one
  remote fetch the demo path really makes); streams point at `cdn.cinemacore.test`, a reserved domain
  that is never fetched. So the fixture path proves the UI, and proves nothing about the player.

## Alternatives considered

- **Block UI work until the provider lands.** Rejected: it serializes the whole project behind T-003
  and T-004, which are unowned, and leaves the largest surface with no way to be checked.
- **Stub the UI with placeholder text.** Rejected: it hides exactly the integration problems the port
  exists to find (rail shapes, poster aspect handling, episode trees, rendition ranking), and it would
  have to be thrown away when the provider arrives.
