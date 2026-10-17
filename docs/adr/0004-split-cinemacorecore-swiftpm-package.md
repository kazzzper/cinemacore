# ADR 0004 — Split `CinemacoreCore` into its own SwiftPM package so logic is testable on Linux

- **Status:** accepted
- **Date:** 2026-10-17

## Context

There is no iOS Simulator on Linux. The only way to execute app code on this machine is
`swift test` on the host, against the Linux Swift toolchain (6.4.1, via swiftly). In a single SwiftPM
package that contains both the SwiftUI app target and the logic, `swift test` builds the app target
too and dies with `no such module 'SwiftUI'` — the SwiftUI module simply does not exist in the Linux
toolchain. That is not an incremental problem to work around; it means no test of any kind can run.

The app is built by `xtool`, which needs exactly one library product, and that product is the app.

## Decision

Two packages, with a one-way local-path dependency between them.

- [`mobile/ios/CinemacoreCore`](../../mobile/ios/CinemacoreCore/Package.swift) — pure Foundation
  (plus `swift-crypto`) and `Observation`. Owns `Models`, `Models+Decoding`, `Signing`, `APIClient`,
  `CatalogRepository`, `FixtureCatalog`, `LibraryStore`, `LoadState`, `ViewModels`, `Subtitles`,
  `DesignTokens`. This is where rules that can be checked without a screen live, and
  `swift test` runs on the Linux host.
- [`mobile/ios/Cinemacore`](../../mobile/ios/Cinemacore/Package.swift) — SwiftUI only, built by
  `xtool dev build` against the Darwin iOS SDK (`xtool.yml`, bundle id `com.cinemacore.app`). It
  declares `.package(path: "../CinemacoreCore")` and nothing else.
- The boundary is therefore structural: `CinemacoreCore` cannot import SwiftUI or UIKit by accident,
  because `swift test` on Linux would fail immediately. View models live in Core precisely so their
  state machines are covered by tests rather than by tapping a device.
- Core also cannot use `SwiftUI.Color`, which is why `RGB` in `DesignTokens.swift` is a plain sRGB
  value and the app target owns the `RGB` → `Color` mapping.

## Consequences

- `swift test` works, and it works on the machine every agent actually has. Models, decoding,
  signing, subtitles, the library store and the view models are all covered (4 test files at the time
  of writing, plus the golden signing vectors).
- `CinemacoreCore` is reusable by any future Darwin surface without dragging the app with it.
- **Cost:** two `Package.swift` files, two `Package.resolved` files, and a rule every agent has to
  remember: `swift test` only works inside `mobile/ios/CinemacoreCore`. Running it in
  `mobile/ios/Cinemacore` fails, by design.
- **Cost:** the UI has no automated verification at all. A broken view compiles or does not; it is
  never executed by CI. Every visual and interaction claim about the app is device-verified only, and
  at the time of writing no device has been attached — `xtool dev build` produces the `.app`, but
  `xtool dev run` has not been exercised.
- **Cost:** anything Core wants from Apple's UI or crypto stack has to come through a cross-platform
  shim (`swift-crypto`) or be pushed up into the app target.

## Alternatives considered

- **`#if canImport(SwiftUI)` guards in every app file.** Rejected: it is boilerplate on every file,
  it makes the app target compile to nothing on Linux rather than failing honestly, and it creates no
  real boundary — a Core file could still reach for a UI framework and only discover the mistake on
  Darwin.
- **One package containing app + core + tests.** Rejected: `swift test` builds the SwiftUI target on
  Linux and fails with `no such module 'SwiftUI'`, which removes all automated coverage. It also
  conflicts with xtool's requirement of exactly one library product, which must be the app.
