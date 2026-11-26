# Releasing

`VERSION` at the repo root is the single source of truth. Git tags are
`v<version>`; GitHub Releases are created from those tags. The Go server is
**not** version-synced: its `/version` constant is independent and unchanged by
a release.

## Scheme

SemVer with prerelease channels:

```
0.0.1-alpha.1 -> 0.0.1-beta.1 -> 0.0.1-rc.1 -> 0.0.1
```

- `VERSION` holds the plain version (`0.0.1`) for stable releases.
- Tags always carry the `v` prefix (`v0.0.1-beta.1`).
- iOS `CFBundleShortVersionString` must stay numeric, so the full prerelease
  string lives in the custom `AppFullVersion` Info.plist key.
- Android `versionName` is the full SemVer string, including the channel.

## Build numbers

`CURRENT_PROJECT_VERSION` (iOS) and `versionCode` (Android) come from the same
deterministic formula:

```
build = MAJOR*1_000_000 + MINOR*10_000 + PATCH*100 + channelOffset + N
```

| Channel | Offset | N |
|---|---|---|
| alpha | 10 | prerelease number |
| beta | 30 | prerelease number |
| rc | 60 | prerelease number |
| stable | 99 | 0 |

Examples:

| Version | Build |
|---|---|
| `0.0.1-alpha.1` | `111` |
| `0.0.1-beta.1` | `131` |
| `0.0.1-rc.1` | `161` |
| `0.0.1` | `199` |
| `0.0.2-alpha.1` | `211` |
| `0.1.0` | `10099` |

The `*100` patch step keeps `0.0.2` above `0.0.1`'s stable build, and the channel
offset keeps alpha < beta < rc < stable for one base version. Prerelease numbers
are limited to 1-9 because the formula reserves one digit; `scripts/release`
refuses to overflow. Do not hand-edit build numbers.

## Embedding

One shared step derives everything from the tag and commit:

```bash
node scripts/version --env        # APP_FULL_VERSION, MARKETING_VERSION, APP_BUILD_NUMBER, APP_COMMIT, APP_TAG
node scripts/generate-version     # writes mobile/ios/Cinemacore/Generated/*
```

| Surface | Source at build time | Local fallback |
|---|---|---|
| iOS | concrete plist written into the app target's `Info.plist` from `VERSION` | `0.0.0-dev`, build `0`, commit `local` |
| Android | `APP_FULL_VERSION`, `APP_BUILD_NUMBER`, `APP_COMMIT` env -> Gradle | `0.0.0-dev`, build `1`, commit `local` |
| Web | `__APP_VERSION__`, `__BUILD_NUMBER__`, `__APP_COMMIT__` defines | same dev fallbacks |

`Generated/` is gitignored. Local `xtool dev build` reads the concrete fallbacks
in `mobile/ios/Cinemacore/Info.plist`; xtool does not expand `$(BUILD_SETTINGS)`.
`make ios-release` and CI run `scripts/ios-build`, which builds the committed
`mobile/ios/Cinemacore/Cinemacore.xcodeproj` with `xcodebuild` only — xtool is
not part of a release — and writes the concrete version into the target's
`Info.plist` for the lifetime of the build.

The About/Settings screen on iOS and Android shows
`vX.Y.Z[-channel.N] (build) commit`; tap it to copy. The first web app must do
the same.

## Cut a release

Run on `main`, with a clean tracked tree:

```bash
git checkout main
git pull
make changelog                                        # what the next section records
make release-dry-run ARGS="patch --channel beta"      # inspect first
make release ARGS="patch --channel beta"
git push origin main
git push origin v0.0.1-beta.2                         # triggers .github/workflows/release.yml
```

`make changelog` is read-only: it prints the section `scripts/release` would
prepend, from the Conventional Commits since the last reachable tag. `--range`
names that previous tag and means "since"; an explicit `a..b` range is also
accepted. `CHANGELOG.md` is written only by a real release.

`make release` is a thin wrapper around `scripts/release`. The same script is
what CI assumes when it builds and verifies the artifacts.

`scripts/release` refuses a dirty tracked tree, a non-`main` branch, or an
existing tag. It updates `VERSION`, regenerates `CHANGELOG.md`, commits
`chore(release): vX.Y.Z[-channel.N]`, and creates an annotated tag locally. It
never pushes.

Bump/channel behaviour:

- `--channel beta` from `0.0.1-beta.1` -> `0.0.1-beta.2`.
- `--channel rc` from `0.0.1-beta.2` -> `0.0.1-rc.1` (same base).
- `--channel stable` from `0.0.1-rc.1` -> `0.0.1` (promotion; bump is ignored).
- `--channel stable` from `0.0.1` with `patch` -> `0.0.2`.
- A prerelease from a stable base applies the bump: `0.0.1` + `minor --channel beta`
  -> `0.1.0-beta.1`.
- Moving backward (rc -> beta) starts a new base; use it deliberately.

## CI and artifacts

`.github/workflows/release.yml` runs on `v*` tags and:

1. verifies the tag matches `VERSION`, runs the Go race suite and build;
2. builds Android (`debug.apk` + release `.aab`) and verifies
   `versionName`/`versionCode` inside the APK;
3. builds iOS on the `xcode-27` runner with signing disabled, verifies
   `AppFullVersion`/`CFBundleVersion`/`AppCommit` inside both apps, and packages
   an unsigned `.ipa` plus a simulator `.app.zip`;
4. publishes the GitHub Release, marks `-alpha/-beta/-rc` as **prerelease**, and
   attaches every artifact;
5. force-updates the moving `stable` tag for a stable release, or `beta` for any
   prerelease.

Locally, `make tag` tags the version already in `VERSION`, `make build` produces
versioned artifacts, and everything lands in the gitignored `release/` folder —
`make android`, `make android-release`, `make dev-ios`, `make dev-android`,
`make ios-release`.

There are **no store uploads** and **no signing secrets**. See
[`docs/IOS-CI.md`](docs/IOS-CI.md) for the iOS pipeline and the future signed
upload TODO block.

`stable` and `beta` are the only moving tags. Never force-push a version tag.

## Pin, follow, roll back

```bash
git fetch --tags --force
git checkout v0.0.1-beta.1     # exact release
git checkout stable            # newest stable
git checkout beta              # newest prerelease (alpha/beta/rc)
```

Install a pinned build by downloading that Release's artifacts rather than
rebuilding from `main`. `beta` intentionally follows the newest prerelease, so
pin an exact `v...` tag when reproducibility matters.

Rollback means cutting a new patch release; release tags are immutable. Do not
delete or retag a published version.

## Hotfix

```bash
git checkout -b release/0.0 v0.0.1
# cherry-pick the fix
node scripts/release patch --channel stable
git push origin release/0.0
git push origin v0.0.2
```

Merge the hotfix back to `main` so it is not lost.

## Baseline and migration

This repo had no tags. The migration commit is `0.0.1-beta.1`; after it lands on
`main`, create the baseline tag:

```bash
git tag -a v0.0.1-beta.1 -m v0.0.1-beta.1
git push origin v0.0.1-beta.1
```

The tag workflow creates the matching GitHub Release. No older releases can be
backfilled: there are no prior tags and the history begins 2026-10-17.

## Sideloading the unsigned iOS build

The `.ipa` is unsigned. It cannot be installed as-is and is not a TestFlight
build.

- **AltStore** or **Sideloadly** re-sign it with a free Apple ID and install it.
- Free Apple IDs expire the signature after **7 days**; re-sideload weekly.
- Free accounts are limited to a few active apps and do not get push
  notifications or other paid entitlements.
- After installing, trust the developer under
  **Settings > General > VPN & Device Management** if iOS asks.
- The simulator `.app.zip` is for inspection/simulator use, not a device.

## Commit and changelog convention

Conventional Commits are enforced by `.githooks/commit-msg` and the PR-title CI
job. `scripts/changelog` groups `feat`, `fix`, `perf`, `refactor`, `docs`,
`build`, `ci`, `test` and `style`, and skips `chore(tasks)` / `chore(release)`.
Use `!` or a `BREAKING CHANGE:` footer for breaking notes.
