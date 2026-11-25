# web/

No web app exists yet. Every future web surface lives here — not at the repo
root and not in `public/` (which only holds shared static art).

## Version contract

The release identity comes from the same `VERSION` file and tag as the native
apps. A web build must inject it at build time; never hardcode a release number:

| Define | Example | Local fallback |
|---|---|---|
| `__APP_VERSION__` | `0.0.1-beta.1` | `0.0.0-dev` |
| `__BUILD_NUMBER__` | `131` | `1` |
| `__APP_COMMIT__` | `abc1234` | `local` |

`scripts/version --env` prints the values CI uses. The first web app must add an
About/Settings screen showing `v<version> (<build>) <commit>` with tap-to-copy,
matching iOS and Android.
