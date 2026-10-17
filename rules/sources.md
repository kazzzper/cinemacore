# Rule provenance

Rules are derived, not invented. When upstream guidance changes, update the rule and this file.

| Rule file | Derived from |
|---|---|
| `00-senior-doctrine.md` | Repo owner directive; XP "simplest thing that works"; Google small-CL practice |
| `01-go.md` | Effective Go · Go Code Review Comments · Uber Go Style Guide · Google Go Style Guide |
| `02-kotlin-android.md` | Kotlin Coding Conventions · AndroidX **Now in Android** · Compose API Guidelines · Material 3 |
| `03-swift-ios.md` | Swift API Design Guidelines · Apple Human Interface Guidelines · Airbnb Swift Style Guide · SwiftData docs |
| `04-rust-tui.md` | Rust API Guidelines · Clippy lint set · Rust Style Guide |
| `05-api-contract.md` | OpenAPI 3.1 spec · Google API Design Guide · oapi-codegen / swift-openapi-generator docs |
| `06-testing.md` | TDD (Beck); Go testing docs; JUnit5/Kotest; Swift Testing; test-pyramid practice |
| `07-git-commits.md` | Conventional Commits 1.0.0 · Google Engineering Practices |

## Signing contract references (authoritative)
- `moviebox-internal-api/moviebox_api/utils.py` — reference Python implementation
- `moviebox-tui/src/providers/moviebox/crypto.rs` — independent Rust implementation (used to cross-check)
- `moviebox-internal-api/OFFICIAL_API_DOCUMENTATION.md` — endpoint + anti-piracy notes
