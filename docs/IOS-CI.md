# iOS CI

The app is a normal Xcode project: `mobile/ios/Cinemacore/Cinemacore.xcodeproj`,
with a shared `Cinemacore` scheme and a `Cinemacore` app target. The target
compiles `Sources/Cinemacore` through a synchronized folder group (every `.swift`
file in that folder is a member automatically) and links the local
`CinemacoreCore` package as a product dependency.

The project is checked in. Release CI therefore needs **Xcode and nothing else**:
no xtool, no XcodeGen, no `brew install`. xtool stays the local build and device
driver (`make dev-ios`, `make ios-ipa`) and is not part of a release.

App targets are not a SwiftPM product type, so `xcodebuild` cannot produce an
`.app` from `Package.swift` alone; a project with an app target is the only way
to build one with Xcode. That is why the project is committed rather than
generated on the runner.

## Runner

Xcode work is `runs-on: xcode-27` — the GitHub-hosted image that tracks one
Xcode major version: macOS 27 (arm64 only), Xcode 27.1 by default (27.0 and
27.2 also installed), Swift 6.4, iOS 27 SDK. `Package.swift` declares
`swift-tools-version: 6.4`, which that toolchain reads.

The unit-test job is `runs-on: ubuntu-24.04`, pinned for its preinstalled Swift
6.4. The 26.04 image ships no Swift toolchain and installing one costs a 3.5 GB
download per run.

Three jobs touch iOS code:

| Trigger | Job | Runner | Does | Publishes |
|---|---|---|---|---|
| every run | `ios-core` | `ubuntu-24.04` | `swift test` | — |
| tag `v*` | `ios` | `xcode-27` | tests + build | yes, into the GitHub Release |
| push to `main`, PR, dispatch | `ios-verify` | `xcode-27` | build only | no, kept 7 days |

## Where the tests run

`mobile/ios/CinemacoreCore` is pure Foundation on purpose, so its 443 tests run
anywhere a Swift 6.4 toolchain does. That makes the split below possible.

- **`ios-core`, Linux, every run — the gate.** Seconds against a local 7 s
  run, free minutes, the same command as `make test-swift`, and the platform
  this project is developed and debugged on. `publish` depends on it, so a tag
  cannot release with a failing suite.
- **`ios`, macOS Simulator, tags only — the Darwin lane.** The only place
  `#if os(iOS)` / `#if canImport(Darwin)` code runs against the SDK the
  artifact ships with, so it stays; but it runs on the tag whose build it is
  validating, not on every push. `IOS_RESULT_BUNDLE` makes `scripts/ios-test`
  write an `.xcresult`, which the job uploads when the suite fails — the next
  red run is readable instead of guessed at.
- **`ios-verify`, macOS, every non-tag run — compile proof.** Builds the app
  but does not re-run the suite. Xcode's job here is to prove the committed
  project still compiles and bundles; a second copy of the tests on a paid
  runner adds cost, not signal.

### Why not xtool for tests

xtool builds a SwiftPM package into an iOS app, signs and installs it, and it
stays the local build and device driver (`make dev-ios`, `make ios-ipa`). It
cannot run tests: that needs the iOS Simulator, which exists only on macOS
([xtool#177](https://github.com/xtool-org/xtool/issues/177); xtool's own answer
is to keep testable logic in a cross-platform target and test it on Linux —
which is exactly what this repository already does). So xtool is the wrong tool
for this job, Xcode is the only tool for the simulator lane, and neither
replaces the Linux gate.

### Why not `swift test` on the macOS host

It builds for macOS, a platform the app never ships on: it would exercise
Darwin Foundation, but not the iOS SDK, and still needs a macOS runner. The
Linux gate covers the logic; the simulator covers the SDK.

## Pipeline

`.github/workflows/release.yml`:

1. `ios-core`: `swift --version`, then `swift test` in the package.
2. `ios` (tag): `xcodebuild -version`, `xcrun --find swift`, `swift --version`,
   `xcodebuild -showsdks` — so a toolchain problem is visible in the log — then
   `./scripts/ios-test`, then `./scripts/ios-build` (unsigned device `.ipa` +
   ad-hoc-signed simulator app), then the artifacts into the GitHub Release.
3. `ios-verify` (everything else): `xcodebuild -list` / `-showdestinations`,
   then `./scripts/ios-build`, and uploads the result.

### The simulator lane

`scripts/ios-test` runs `xcodebuild test` against the `CinemacoreCore` package
with an iOS Simulator destination. The scheme name is discovered from
`xcodebuild -list -json` (Xcode derives `<package>-Package` plus one scheme per
product) and the simulator is the first available iPhone from
`xcrun simctl list devices available`, so a runtime change in the runner image
does not break the job. Set `IOS_RESULT_BUNDLE=/path/to/x.xcresult` to keep the
bundle (CI sets it and uploads it on failure).

### Signing

| Artifact | Signing | Why |
|---|---|---|
| `release/Cinemacore-<tag>-unsigned.ipa` | none (`CODE_SIGNING_ALLOWED=NO`) | it is re-signed when sideloaded |
| `release/Cinemacore-<tag>-simulator.app.zip` | ad-hoc (`CODE_SIGN_IDENTITY=-`) | an unsigned arm64 simulator app does not launch, and loses its Keychain identity |

No certificate, provisioning profile, Apple ID, App Store Connect key, Fastlane
match, or team ID is used. There are no signing secrets to configure.

## Version inputs

`scripts/ios-build` derives `APP_FULL_VERSION`, `APP_BUILD_NUMBER`,
`APP_COMMIT` and `MARKETING_VERSION` with `scripts/version --env`, then writes
them into the committed `mobile/ios/Cinemacore/Info.plist` that the target's
`INFOPLIST_FILE` points at, and restores the file on exit (even on failure). The
committed plist keeps concrete `0.0.0-dev` / `0` / `local` fallbacks for local
xtool and Xcode builds.

It does **not** pass `INFOPLIST_FILE`, `GENERATE_INFOPLIST_FILE` or
`INFOPLIST_EXPAND_BUILD_SETTINGS` on the command line: those settings apply to
every target in the build, including SwiftPM's dependency bundles, whose own
`Info.plist` generation then fails (`Build input file cannot be found:
.../swift-nio/Generated/Info.plist`).

After the build the app plist is read back and the job fails unless
`AppFullVersion`, `CFBundleVersion`, `AppCommit`, `CFBundleShortVersionString`
and `CFBundleIdentifier` match the tag and `CFBundleExecutable` names a binary
that actually exists in the bundle.

## Regenerating the project

Only needed when the target shape changes (new embed phase, new build setting,
new dependency):

```bash
cd mobile/ios/Cinemacore
xtool dev generate-xcode-project   # writes xtool/.xtool-tmp/Cinemacore.xcodeproj
open Cinemacore.xcodeproj          # port the change, or diff against the generated one
```

The committed project is the one CI builds. Everything xtool writes stays
gitignored.

## Installing the artifact

The `.ipa` is unsigned and must be re-signed. Use AltStore or Sideloadly with a
free Apple ID; the signature lasts 7 days, then re-sideload. See
[`RELEASING.md`](../RELEASING.md#sideloading-the-unsigned-ios-build).

## Troubleshooting

- **`xcodebuild: error: The project ... does not contain a scheme named
  "Cinemacore"`** — the shared scheme was deleted or renamed; it must live at
  `Cinemacore.xcodeproj/xcshareddata/xcschemes/Cinemacore.xcscheme`.
- **`Could not resolve package dependencies`** — the runner needs to fetch
  `swift-nio` and `swift-crypto`; check network access, then re-run.
- **`no available iPhone simulator`** — the image's installed runtimes changed;
  `xcrun simctl list devices available` shows what is there.
- **The simulator suite is red on a tag** — download the `ios-tests-xcresult`
  artifact and open it (`xcodebuild -resultBundlePath` output), or read the
  failing `@Test` lines from the log. Do not widen timeouts to make it green:
  a Darwin-only failure in the download / progressive-server suites has been a
  real bug before (`URL.resourceValues` caches per instance on Apple platforms,
  so a grown partial file kept reporting its old size).
- **Version check fails** — the plist was not rewritten; confirm
  `scripts/ios-build` ran `scripts/generate-version --concrete` and that the
  target still has `INFOPLIST_FILE = Info.plist`.
- **`Multiple commands produce ... Info.plist`** — a plist override leaked onto
  the command line again; see "Version inputs" above.

## TODO: signed uploads later

Do not enable any of this without an Apple Developer account. When one exists:

- [ ] Add `APPLE_TEAM_ID`, `APPLE_API_KEY_ID`, `APPLE_API_ISSUER_ID` and
      `APPLE_API_PRIVATE_KEY` as GitHub Secrets.
- [ ] Add a distribution certificate + App Store provisioning profile (or move
      to Fastlane match) and a keychain-import step.
- [ ] Sign the device build (`xcodebuild archive` + `-exportArchive`) in a
      separate gated job.
- [ ] Upload with `xcrun altool`/`notarytool` or `fastlane pilot` on `rc`/stable
      only, behind a protected `release` environment and manual approval.
- [ ] Keep the unsigned IPA + simulator zip artifacts regardless.
