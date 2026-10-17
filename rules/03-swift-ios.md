# 03 — Swift / iOS

Scope: `mobile/ios/`. Source: Swift API Design Guidelines, Apple HIG, Airbnb Swift Style.

## Language
- Value types by default (`struct`/`enum`); `class` only for identity or reference semantics.
- No force unwrap/try (`!`, `try!`) in production. `guard let ... else { return }`.
- `let` over `var`. Exhaustive `switch`; no `default` that hides new cases.
- Concurrency: `async/await`, `actor` for shared mutable state, `Sendable` models. No `DispatchQueue` in new code.
- Swift 6.4 language mode; resolve all concurrency warnings.

## API design
- Clarity at the call site. `remove(_:at:)` not `remove(_:_:)`. Omit needless words.
- Document exported API with `///`—summarize, then parameters only when non-obvious.
- Errors: typed `Error` enums. No stringly-typed errors.

## SwiftUI
- State: `@State` local, `@Observable`/`@State` for models, environment for cross-cutting. No logic in `body`.
- Views are value types; extract subviews instead of computed-var soup.
- Cover all six states: loading, empty, error, partial, success, permission.
- Accessibility: labels on icon-only controls, ≥44pt targets, Dynamic Type, contrast ≥ 4.5, respect reduced motion.

## Data
- SwiftData with `VersionedSchema` + `SchemaMigrationPlan` from day one. Additive changes; never mutate a shipped schema in place.
- Secrets/tokens in **Keychain**, never `UserDefaults`/SwiftData.

## Networking & media
- Contract-first: use the generated OpenAPI client. No hand-built request shapes.
- Media: `AVURLAssetHTTPHeaderFieldsKey`/`CookiesKey` first; loopback `swift-nio` proxy only when the ladder requires it. **Never hand-roll HTTP.**

## Quality
- `swift-format` / SwiftLint clean. Snapshot-test key screens. Verify on physical device (no simulator on Linux).
