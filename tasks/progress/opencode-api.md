# opencode-api

- 2026-10-17T19:59:46.586Z — registered (opencode)
- 2026-10-17T19:59:52.240Z — claimed T-004 — Go server: auth/browse/search/title + contract conformance
- 2026-10-17T20:13:22.278Z — updated T-004: all 8 contract paths routed; conformance+behavior tests green; live :8099 smoke: /health,/version 200, content paths 502 upstream, validation 400
- 2026-10-17T20:13:22.332Z — done T-004: gofmt/vet/build clean; go test ./... -race green; serves :8080 (smoke :8099)
- 2026-10-17T20:20:11.135Z — registered (opencode)
- 2026-10-17T20:20:11.201Z — claimed T-003 — Go session (guest bootstrap, host pool) + provider/moviebox
- 2026-10-17T20:34:27.634Z — updated T-003: session: host param + app headers + x-user/guest bootstrap + 441 re-auth; provider: live endpoints and gateway->domain mapping
- 2026-10-17T20:34:27.692Z — done T-003: live verified: /v1/home,/v1/search,/v1/detail,/v1/detail/{id}/seasons,/v1/play,/v1/search/suggestions return real data; go test ./... -race green
