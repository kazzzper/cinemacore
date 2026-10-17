# 08 — Comments

Source: Google style guides ("comment the why, not the what"), Clean Code, Go Code Review Comments.

**Comment the *why*, never the *what*.** If a comment restates the line beneath it, delete it. Code
should be readable without narration; a comment earns its place only by adding information the code
cannot express.

## Do

- Explain a **non-obvious decision, constraint, or workaround** ("the gateway truncates at 102400
  bytes, so we must too").
- Record a **hidden invariant** or coupling ("must stay in lockstep with `core/sign`").
- Warn about **consequences** ("changing this invalidates the golden vectors").
- Doc-comment **public / exported API** where the language expects it — Go exported identifiers,
  Swift `public`, Rust `pub`. This is convention, not verbosity.

## Don't

- **Narrate.** `// loop over items`, `// increment i`, `// return the result`.
- **Restate the signature** in prose ("this function takes a string and returns an error").
- **Section banners** that add nothing — `// MARK: - Helpers` in a 40-line file.
- **Essay headers** on a small file. A paragraph of prose above five lines of code is a smell.
- Keep a comment that has **drifted** from the code. A wrong comment is worse than no comment.

## Per language

| Language | Rule |
|---|---|
| Go | Doc comment on every exported identifier (required). Inside functions, only for *why*. |
| Swift | `///` on public API. No step-by-step narration, no decorative `MARK` scaffolding. |
| Kotlin | KDoc on public API. No narrative comments in composables. |
| Rust | `///` on `pub` items. `//` only for non-obvious reasoning, never for restating the next line. |

## Test

For every comment ask: **does the code already say this?** If yes, delete it. If the code can't say
it, the comment stays.

## Enforcement

Reviewers reject narration comments. Do **not** bulk-delete comments as part of an unrelated
refactor — comment cleanup is its own `refactor` commit (see `07-git-commits.md`).
