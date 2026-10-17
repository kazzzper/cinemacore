# AGENTS.md — Cinemacore

Operating contract for **every** agent and harness (Claude Code, OpenCode, Codex, Cursor). Read this first.
Rules live in [`rules/`](rules/README.md). Work is tracked in [`tasks/`](tasks/README.md). Architecture in [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## 0. Repository map

| Path | What | Stack |
|---|---|---|
| `core/` | Shared logic: signing, sessions, providers, catalog, cache, download | Go 1.27 (pure, no cgo) |
| `server/` `cmd/cinemacore/` | REST API — source of truth + provider gateway | Go stdlib `net/http` |
| `mobile/ios/` | iOS app | Swift 6.4 · SwiftUI · SwiftData · swift-nio |
| `mobile/android/` | Android app | Kotlin · Compose · Retrofit · Room |
| `tools/tui/` | Terminal client | Rust |
| `contracts/openapi.yaml` | **Single source of truth** for the wire API | OpenAPI 3.1 |
| `rules/` | Coding + process rules (follow these) | Markdown |
| `tasks/` | Board, registry, harness-agnostic CLI | Node |

**Prime directive:** provider / signing / cache / download / history logic exists **once**, in `core/`. Surfaces are thin. `core/` imports nothing from `server/`, `mobile/`, or `tools/`.

## 1. Bootstrap (run these)

```bash
# Go core + server (works now)
go build ./... && go test ./... -race
go run ./cmd/cinemacore                      # :8080; override with CINEMACORE_ADDR=:8971

# iOS app (Swift 6.4 + xtool; no simulator on Linux -> device only)
cd mobile/ios/Cinemacore && xtool dev build

# Android app (requires JDK 17+, Android SDK, ANDROID_HOME set)
cd mobile/android && ./gradlew assembleDebug

# Work tracking (any harness)
node tasks/bin/tasks.mjs status
```

Missing toolchain? `go` ✅ · `swift` ✅ (6.4.1) · `xtool` ✅ · JDK/Gradle/Android SDK ❌ (needed for Android).

## 2. Agent + harness workflow (required)

Every agent registers and tracks its own work. Never edit `tasks/registry.json` by hand.

```bash
node tasks/bin/tasks.mjs register --agent <name> --harness <claude-code|opencode|codex|cursor>
node tasks/bin/tasks.mjs claim T-001
node tasks/bin/tasks.mjs update T-001 -m "signing golden vectors green"
node tasks/bin/tasks.mjs done T-001
node tasks/bin/tasks.mjs board            # regenerate BOARD.md
```

- Register **before** claiming. One owner per task.
- Update on every meaningful step. `done` requires the DoD (§5).
- Cross-harness handoff: leave state in `tasks/progress/<agent>.md`, not in your head.

## 3. Rules (follow or the change is rejected)

| File | Domain |
|---|---|
| [`rules/00-senior-doctrine.md`](rules/00-senior-doctrine.md) | **King rule** — minimal diffs, no loss |
| [`rules/01-go.md`](rules/01-go.md) | Go |
| [`rules/02-kotlin-android.md`](rules/02-kotlin-android.md) | Kotlin / Compose |
| [`rules/03-swift-ios.md`](rules/03-swift-ios.md) | Swift / SwiftUI |
| [`rules/04-rust-tui.md`](rules/04-rust-tui.md) | Rust TUI |
| [`rules/05-api-contract.md`](rules/05-api-contract.md) | Contract-first API |
| [`rules/06-testing.md`](rules/06-testing.md) | Tests, golden vectors |
| [`rules/07-git-commits.md`](rules/07-git-commits.md) | Conventional Commits |

Provenance for every rule: [`rules/sources.md`](rules/sources.md).

## 4. Style in one breath

Smallest correct change. **One-line fix beats a 100-line rewrite.** Code over prose. No dead code, no filler comments, no speculative abstraction. **No loss** — behaviour, types, tests, and error paths preserved; shorter never means fewer cases handled.

## 5. Definition of done

1. Builds (`go build ./...`, app target compiles).
2. Tests green, including the signing **golden vectors** (`core/sign`).
3. Contract updated + clients regenerated if the wire API changed.
4. `tasks` updated (`done`).
5. Diff reviewed against `rules/00-senior-doctrine.md`.

## 6. Guardrails

- Never hand-roll HTTP. Use stdlib/`swift-nio`/Ktor.
- Never commit secrets, tokens, or `release-key.jks`.
- Never edit generated code (`*.gen.go`, generated clients) by hand.
- Never weaken the signing contract; `core/sign` is versioned and frozen.
- Keep the reverse-engineered signing constant isolated in `core/sign` only.
