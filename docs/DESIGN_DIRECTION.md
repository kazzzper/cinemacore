# Design Direction — Cinemacore mobile

Folded from Genga-World; one spec implemented twice (Compose + SwiftUI).

## Tone

Cinematic, dark, content-first. Dense but scannable rails. Posters lead; chrome recedes. No decorative gradients competing with artwork.

## Tokens

- **Color:** near-black surfaces, elevated charcoal cards, one accent; hero art carries the color. Contrast ≥ 4.5:1 for text.
- **Type:** a single strong display face for titles, system face for body. Respect Dynamic Type; never disable scaling.
- **Spacing:** 4/8 scale. Rails 12–16 gutter. Stable rail/toolbar heights so labels never shift layout.
- **Radius/elevation:** consistent card radius; elevation only to separate interactive layers.

## Components (reused from Genga-World)

- Shimmer skeleton loaders (poster aspect ratio locked).
- Gesture-driven player overlay: tap to toggle chrome, horizontal scrub, vertical brightness/volume.
- Dual-mode bottom sheets: quality · audio dub · subtitles · speed.
- Canvas-rendered subtitles: centered, outlined for legibility over any frame.
- Search: auto-collapsing keyboard, suggestion chips, recent queries.

## Required states (every screen)

Loading · Empty · Error · Partial · Success · Permission.

## Accessibility

- Icon-only controls have labels.
- Targets ≥ 44pt (iOS) / 48dp (Android).
- Focus order matches visual order; reduced-motion respected.
- Screen-reader labels name the content, not the control.
