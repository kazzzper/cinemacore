# 00 — Senior Doctrine (king rule)

Applies to every change, in every language. Overrides style preferences.

## The five laws

1. **Smallest correct change.** Prefer a one-line fix over a 100-line rewrite. Rewrite only when the diff is genuinely smaller or provably equal-risk.
2. **No loss.** Behaviour, types, tests, error paths, and edge cases are preserved. "Shorter" never means "fewer cases handled". If you drop a case, say so explicitly.
3. **Code over prose.** Speak in diffs. No filler comments restating the line, no dead code, no speculative abstraction, no "just in case" parameters.
4. **DRY across surfaces.** Logic seen twice moves to `core/` or `contracts/`. Never fork the signing/cache/provider logic.
5. **Fail loud.** Typed errors, no silent catches, no swallowed returns. Empty/error/partial are real states and must be handled.

## The 100-lines-vs-1 test

| Smell | Do instead |
|---|---|
| Rewriting a function to add one guard | Add the guard |
| New abstraction for two call sites | Inline until there are three |
| Copy-paste a helper into another surface | Move it to `core/` |
| Wrapping a stdlib call in a custom type | Call the stdlib |
| Handling a case "for completeness" that cannot occur | Delete it (proof required) |
| Comment explaining *what* the next line does | Delete the comment; name things |
| Comment explaining *why* (non-obvious) | Keep it — one line |

## Non-negotiables

- Do not reformat unrelated code in the same diff.
- Do not mix refactor + behaviour change in one commit.
- Do not introduce a dependency for something the stdlib/platform already does.
- Do not leave TODOs without a `tasks/` entry.
- Do not narrate code in comments — see [`08-comments.md`](08-comments.md).

## Review checklist

- [ ] Is this the smallest diff that is correct?
- [ ] Did I remove any behaviour without saying so?
- [ ] Is any logic duplicated that belongs in `core/`?
- [ ] Are all error paths typed and surfaced?
- [ ] Does the smallest failing test exist (see `06-testing.md`)?
