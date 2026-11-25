# iOS CI

The app is a SwiftPM/xtool project, not a committed `.xcodeproj`. CI uses Xcode:
xtool generates the project, then `xcodebuild` builds the app target for device
and simulator with signing disabled. The generated project has no shared
schemes, so the script builds `-target Cinemacore-App` instead of `-scheme`.
Nothing is signed.

Only tag pushes run this job. macOS runner minutes are expensive, so PRs and
`main` pushes never build iOS.

## Pipeline

`.github/workflows/release.yml`, job `ios`, on the `xcode-27` runner:

```bash
brew install xtool-org/tap/xtool
./scripts/ios-build
```

`scripts/ios-build` is also `make ios-release`. It runs
`scripts/version --env`, `scripts/generate-version`,
`xtool dev generate-xcode-project`, then two `xcodebuild` commands
(`-sdk iphoneos` and `-sdk iphonesimulator`) with
`Generated/Version.xcconfig`, `INFOPLIST_FILE=Generated/Info.plist`,
`GENERATE_INFOPLIST_FILE=NO`, `INFOPLIST_EXPAND_BUILD_SETTINGS=YES` and
`CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO`. That expands the generated
plist to the concrete `VERSION`, build number and commit. Where `xcodebuild` is
unavailable (Linux), the script uses `scripts/xtool` for the same two artifacts.

The job then:

1. reads `AppFullVersion`, `CFBundleVersion`, `AppCommit` and
   `CFBundleShortVersionString` from the IPA's app and the simulator app, and
   fails if any differs from the tag;
2. writes the device app as `release/Cinemacore-<tag>-unsigned.ipa`;
3. writes the simulator app as `release/Cinemacore-<tag>-simulator.app.zip`;
4. uploads both to the GitHub Release.

No certificate, provisioning profile, Apple ID, App Store Connect key, Fastlane
match, or team ID is used. There are no signing secrets to configure.

## Generated version inputs

`scripts/generate-version` writes, under `mobile/ios/Cinemacore/Generated/`:

`Version.xcconfig`
```
MARKETING_VERSION = 0.0.1
CURRENT_PROJECT_VERSION = 131
APP_FULL_VERSION = 0.0.1-beta.1
APP_COMMIT = abc1234
```

`Info.plist` — a copy of the source plist with the four version keys replaced by
`$(MARKETING_VERSION)`, `$(CURRENT_PROJECT_VERSION)`, `$(APP_FULL_VERSION)` and
`$(APP_COMMIT)`.

`Generated/` is gitignored. The committed `Info.plist` keeps concrete
`0.0.0-dev`/`0`/`local` fallbacks because xtool does not expand build settings.

## Installing the artifact

The `.ipa` is unsigned and must be re-signed. Use AltStore or Sideloadly with a
free Apple ID; the signature lasts 7 days, then re-sideload. See
[`RELEASING.md`](../RELEASING.md#sideloading-the-unsigned-ios-build).

## Troubleshooting

- **`missing .../xtool/Cinemacore.ipa`** — the build did not finish; run
  `make ios-release` locally to see the compiler output.
- **Version check fails** — confirm `-xcconfig Generated/Version.xcconfig` and
  `INFOPLIST_FILE=Generated/Info.plist` are used; a raw `xtool dev build` keeps
  the committed `0.0.0-dev` fallbacks.
- **`xcodebuild: error: The project ... does not contain a target named ...`** —
  set `IOS_TARGET` (and `IOS_PRODUCT` / `xtool.yml` `product`) to match the
  generated target, which xtool names `<product>-App`.

## TODO: signed uploads later

Do not enable any of this without an Apple Developer account. When one exists:

- [ ] Add `APPLE_TEAM_ID`, `APPLE_API_KEY_ID`, `APPLE_API_ISSUER_ID` and
      `APPLE_API_PRIVATE_KEY` as GitHub Secrets.
- [ ] Add a distribution certificate + App Store provisioning profile (or move
      to Fastlane match) and a keychain-import step.
- [ ] Sign the device build (xtool `--sign` or `xcodebuild` archive/export)
      in a separate gated job.
- [ ] Upload with `xcrun altool`/`notarytool` or `fastlane pilot` on `rc`/stable
      only, behind a protected `release` environment and manual approval.
- [ ] Keep the unsigned IPA + simulator zip artifacts regardless.
