# ADR 0003 — Dark-only brand; Liquid Glass on chrome only

- **Status:** accepted
- **Date:** 2026-10-17

## Context

The iOS app is a port of the Genga-World Android app, and the porting source ships one palette,
"Cinematic Obsidian" (`app/src/main/java/com/example/ui/theme/Color.kt`). In that source the *light*
colour scheme is byte-identical to the dark scheme — both set `background = #090A10`, and the
surfaces, brand red `#E50914`, crimson `#B81D24` and amber `#FF8C00` are shared. There is no light
design to port; there is a light *scheme name* wrapping the dark values.

`docs/DESIGN_DIRECTION.md` already fixes the tone: cinematic, dark, content-first, posters lead and
chrome recedes, contrast ≥ 4.5:1.

## Decision

Ship a single dark theme and lock the interface to dark.

- The palette is one set of literals in
  [`DesignTokens.swift`](../../mobile/ios/CinemacoreCore/Sources/CinemacoreCore/DesignTokens.swift)
  (`CinematicObsidian`), resolved through semantic roles (`Theme.cinematic`: `background`, `surface`,
  `brand`, `accent`, `separator`, …). Screens reference roles, never palette entries.
- There is exactly one `Theme`. No light variant is synthesised, and no screen branches on colour
  scheme.
- Adopt iOS 26/27 **Liquid Glass for navigation and control chrome only** — tab bars, navigation
  bars, toolbars, sheets, the player overlay. The content layer (posters, rails, episode lists, the
  detail header art) keeps standard materials and plain fills; glass never sits over artwork.
- Contrast is enforced by test, not by eye: `DesignTokensTests` asserts text/surface ratios meet
  WCAG AA (`>= 4.5:1`) and that the separator is a derived lift off the card rather than a new colour.

## Consequences

- One palette to maintain, shared verbatim with the Android surface, so the two stay visually
  identical by construction.
- Chrome feels native on current iOS instead of looking like a hand-drawn toolbar.
- No fake light mode, and no screen that renders half-broken when the system is in light appearance.
- **Cost:** users who prefer light appearance get a dark app, with no setting to change it. That is
  the upstream product decision, and this ADR records it as a deliberate limitation, not an oversight.
- **Cost:** Liquid Glass is an iOS 26/27 API while `mobile/ios/CinemacoreCore/Package.swift` declares
  a `.iOS(.v17)` floor. Chrome therefore needs availability handling with a material fallback on older
  systems — extra branches on every chrome surface, and the only way to check them is a device,
  because there is no simulator on Linux.

## Alternatives considered

- **Derive a light theme algorithmically.** Rejected: nobody designed it, so every derived value is
  an invention that diverges from the source app, and it would need its own contrast review and its
  own test suite for a mode the product does not ask for.
- **Port the source's "light" scheme as a second theme.** Rejected: it contains the same `#090A10`
  background as the dark scheme, so it would be a toggle that changes a name and nothing else.
- **Glass everywhere, including over posters.** Rejected: it puts a translucent layer between the user
  and the artwork that is the product, and it breaks the contrast gate on unknown poster content.
