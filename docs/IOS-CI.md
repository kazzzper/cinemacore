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

`runs-on: xcode-27` — the GitHub-hosted image that tracks one Xcode major
version: macOS 27 (arm64 only), Xcode 27.1 by default (27.0 and 27.2 also
installed), Swift 6.4, iOS 27 SDK. `Package.swift` declares
`swift-tools-version: 6.4`, which that toolchain reads.

Only tag pushes run this job. macOS runner minutes are expensive, so PRs and
`main` pushes never build iOS; `ci.yml` keeps the Go checks.

## Pipeline

`.github/workflows/release.yml`, job `ios`:

1. `xcodebuild -version`, `xcrun --find swift`, `swift --version`,
   `xcodebuild -showsdks` — so a toolchain problem is visible in the log.
2. `./scripts/ios-test` — unit tests on an iOS Simulator.
3. `./scripts/ios-build` — unsigned device `.ipa` + ad-hoc-signed simulator app.
4. Upload both to the GitHub Release.

### Tests run on iOS

`scripts/ios-test` runs `xcodebuild test` against the `CinemacoreCore` package
with an iOS Simulator destination. `swift test` on the macOS host builds for
macOS — a platform this app never ships on — and compiles Darwin-only code that
the Linux host compiles out entirely, so the two hosts disagree about what is
even legal. Testing on iOS keeps one compiler, one SDK, and the same
`#if canImport(Darwin)` / `#if os(iOS)` conditionals as the artifact.

The scheme name is discovered from `xcodebuild -list -json` (Xcode derives
`<package>-Package` plus one scheme per product) and the simulator is the first
available iPhone from `xcrun simctl list devices available`, so a runtime change
in the runner image does not break the job.

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
