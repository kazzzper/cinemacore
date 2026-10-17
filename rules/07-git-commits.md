# 07 — Git & Commits

Source: Conventional Commits, Google Engineering Practices.

## Format
```
<type>(<scope>): <summary>

<body — why, not what>
```
Types: `feat` `fix` `refactor` `perf` `test` `docs` `build` `ci` `chore`.
Scopes: `core` `sign` `session` `provider` `catalog` `store` `fetch` `server` `ios` `android` `tui` `contracts` `tasks` `rules`.

## Rules
- One logical change per commit. Never mix refactor with behaviour change.
- Summary in imperative mood, ≤72 chars, no trailing period.
- Reference the task: `Refs T-001`.
- Small diffs. If a commit needs "and" in the summary, split it.

## History
- Keep it linear; rebase and tidy before merge.
- Never force-push a shared branch.
- Never commit secrets, tokens, `*.jks`, `*.keystore`, or `.env`.

## PRs
- Describe: what, why, and the contract/behaviour impact.
- Green build + tests + regenerated contract required.
- Review against `rules/00-senior-doctrine.md`.
