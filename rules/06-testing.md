# 06 — Testing

Source: TDD practice, Go testing, XCTest/Swift Testing, JUnit5/Kotest.

## Discipline
- **Test first** where practical: write the smallest failing test, make it pass, then refactor.
- Every behaviour change ships the **smallest test that fails without it**.
- A bug fix ships a regression test that reproduces the bug.
- No flaky tests. No `sleep`-based synchronisation; use virtual time / polling with a bound.

## Golden vectors (non-negotiable)
- `core/sign` is pinned by golden vectors generated from the reference Python implementation and cross-checked against Rust. Both `ClientToken` and `TRSignature` (incl. the 102400-byte truncation and duplicate/blank query keys) must match byte-for-byte.
- Adding a vector requires the exact source and timestamp so anyone can reproduce it.
- If a vector changes, the signing contract changed — that is a breaking event, not a test edit.

## Per language
- **Go:** table-driven + subtests (`t.Run`); `go test ./... -race` in CI; prefer stdlib `testing`.
- **Kotlin:** JUnit5/Kotest; ViewModels with `StandardTestDispatcher`; Turbine for Flow; Compose UI test for states.
- **Swift:** Swift Testing / XCTest; snapshot key screens; test migration plans.
- **Rust:** unit tests in-module, integration in `tests/`, `cargo test` clean.

## Coverage
- Gate: ≥80% on `core/`; sign/session/provider are the priority.
- Coverage is a floor, not a goal — a covered-but-untested branch is not done.

## Naming
- `TestSubject_Scenario_Expected` is acceptable; clarity beats brevity.
