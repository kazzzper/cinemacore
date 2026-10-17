# ADR 0002 — Signing lives in one place per language, pinned by shared golden vectors

- **Status:** accepted
- **Date:** 2026-10-17

## Context

Every MovieBox gateway call is signed. The contract was reverse-engineered and now exists four times:
the Python reference (`moviebox-internal-api/moviebox_api/utils.py`), the Go core (`core/sign/sign.go`),
the Rust TUI (`moviebox-tui/src/crypto.rs`), and — new — the iOS app. It has to be **byte-identical**
across all four, because the server compares one HMAC and one MD5 chain: a single differing byte
breaks every request with no useful error.

The four inputs are narrow but unforgiving: the canonical string
`METHOD \n Accept \n Content-Type \n Content-Length \n ts_ms \n bodyMD5 \n path?sorted_query`, the
base64 gateway secret, the `0x19000` (102400-byte) body truncation, and the query canonicalisation
(URL-decode pairs, stable-sort by key, do **not** re-encode). `core/sign` is frozen and versioned by
the vectors in `core/sign/sign_test.go`.

## Decision

Implement signing natively in Swift at
[`mobile/ios/CinemacoreCore/Sources/CinemacoreCore/Signing.swift`](../../mobile/ios/CinemacoreCore/Sources/CinemacoreCore/Signing.swift),
and pin it to the same vectors as the Go implementation.

- No gomobile, no cgo, no process spawn. `public enum Signing` is pure Foundation plus
  [`swift-crypto`](https://github.com/apple/swift-crypto) — Apple's own cross-platform build of the
  CryptoKit API. `CryptoKit` itself is not importable on Linux, and `swift test` on the Linux host is
  the only automated coverage this repo has.
- The secret is a single `static let gatewaySecret` in that one file, isolated exactly as
  `core/sign` keeps it in Go. It is not referenced from any view, model, or view model.
- Go's failure semantics are reproduced deliberately: `queryUnescape` returns `""` for a malformed
  escape (the Go call site discards the error), the sort is stable on key only, and an un-decodable
  secret is a fail-closed `preconditionFailure` rather than a throw.
- Validation is
  [`Tests/CinemacoreCoreTests/SigningTests.swift`](../../mobile/ios/CinemacoreCore/Tests/CinemacoreCoreTests/SigningTests.swift),
  whose five golden cases are copied verbatim from `core/sign/sign_test.go`, plus the boundary cases
  (exactly/one byte over the truncation limit, duplicate and blank query keys, lower-case methods).

## Consequences

- The app builds and signs with no macOS toolchain dependency; `xtool dev build` on Linux is enough.
- Drift is caught by tests, not by a 403 at runtime: both implementations assert the same five
  literal signatures. The vectors are the contract.
- The secret constant stays in exactly one place per language — `core/sign` in Go, `Signing.swift` in
  Swift. It is still not a secret in the cryptographic sense: it is extractable from the shipped
  binary, which is a property of the upstream contract, not of this decision.
- **Cost:** the frozen contract now has a fourth implementation to keep in lockstep. Any change to
  `core/sign` must add vectors in `core/sign/sign_test.go` *and* mirror them in `SigningTests.swift`
  in the same change, or the two silently diverge on the cases only one of them tests.
- **Cost:** `swift-crypto` is an external dependency pinned by
  `mobile/ios/CinemacoreCore/Package.resolved`, used for MD5/HMAC/SHA-256. `Insecure.MD5` is required
  by the gateway; the name is accurate and intentional.

## Alternatives considered

- **gomobile binding of the Go core.** Rejected: unproven on Linux with the xtool toolchain, and it
  would drag the Go runtime and cgo into the app bundle — a large, unverifiable dependency in the
  exact layer that must stay byte-exact. It also would not have made the signing logic testable on
  Linux, which the current split already achieves.
- **Shelling out to a Go helper binary.** Rejected: iOS does not let an app spawn child processes, and
  the offline/signing-sensitive path this would have served is precisely the path that must work
  without a server.
- **Port to CryptoKit instead of swift-crypto.** Rejected: `CryptoKit` is Apple-only, so `swift test`
  on Linux could not compile the module, and the vector tests would stop existing.
