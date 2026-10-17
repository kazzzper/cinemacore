# 05 — API Contract

Applies to anything touching `contracts/` or the wire API. Source: OpenAPI 3.1, Google API Design Guide.

## Source of truth
- `contracts/openapi.yaml` is the contract. Hand-written DTOs that drift from it are forbidden.
- Generate, never hand-write: Go server (`oapi-codegen`), Swift client (`swift-openapi-generator`), Kotlin client (OpenAPI Generator `multiplatform`).
- **Never edit generated files** (`*.gen.go`, generated clients). Regenerate.
- CI regenerates and fails if the output differs from what's committed.

## Compatibility
- **Additive only** for a shipped version. Removing/renaming a field is a breaking change → new major version.
- Every response carries `X-API-Version`. Clients send it; the server may negotiate.
- Unknown fields must be tolerated by clients (don't fail on extra JSON).

## Shape
- Errors return a typed envelope: `{ "code": string, "message": string, "detail"?: object }` with a correct HTTP status.
- Status codes: `200`/`201` success, `400` bad input, `401`/`403` auth, `404` missing, `409` conflict, `429` rate limit, `5xx` server.
- Pagination is explicit and stable (cursor preferred over offset).
- Timestamps are RFC 3339 UTC. IDs are strings. Enums are closed and versioned.

## Process
- Change the contract **first**, then regenerate, then implement.
- Contract changes require a `tasks/` entry and a PR note under "Contract".
