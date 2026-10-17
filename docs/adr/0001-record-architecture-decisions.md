# ADR 0001 — Record architecture decisions

- **Status:** accepted
- **Date:** 2026-10-17

## Context

Cinemacore spans Go, Swift, Kotlin, and Rust with a shared signing contract and a contract-first API. Decisions made now constrain four codebases and a reverse-engineered wire format.

## Decision

Record every non-trivial, hard-to-reverse decision as a numbered Markdown file in `docs/adr/`, with context, options considered, the decision, and consequences. Link the ADR from the relevant code and from `tasks/`.

## Consequences

- Decisions are reviewable without archaeology.
- Signing/contract changes are explicit and versioned.
- Cost: one short file per decision — acceptable.
