# iOS CI

The app is a SwiftPM/xtool project, not a committed `.xcodeproj`. Local builds
still use `xtool dev build` and are unchanged. CI uses the normal Xcode pipeline:
it generates an Xcode project with xtool, then drives `xcodebuild` directly with
signing disabled.

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
(`-sdk iphoneos` and `-sdk iphonesimulator`) with `Generated/Version.xcconfig`,
`INFOPLIST_FILE=Generated/Info.plist`, `GENERATE_INFOPLIST_FILE=NO`,
`INFOPLIST_EXPAND_BUILD_SETTINGS=YES` and
`CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO`. The job then:

1. reads `AppFullVersion`, `CFBundleVersion`, `AppCommit` and
   `CFBundleShortVersionString` from both built apps and fails if any differs
   from the tag;
2. packages the device app as `Cinemacore-<tag>-unsigned.ipa`
   (`Payload/` + zip);
3. packages the simulator app as `Cinemacore-<tag>-simulator.app.zip` with
   `ditto`;
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

- **`Cinemacore.xcodeproj` or scheme not found** — run
  `xtool dev generate-xcode-project` locally (macOS) and `xcodebuild -list`;
  adjust the scheme in the workflow.
- **`.app` not under the expected path** — the workflow finds any `*.app` in the
  Release build products directory, so product-name changes are tolerated.
- **Version check fails** — confirm `INFOPLIST_FILE=Generated/Info.plist` and
  `-xcconfig Generated/Version.xcconfig` are both present. A stale generated
  plist is the usual cause.

## TODO: signed uploads later

Do not enable any of this without an Apple Developer account. When one exists:

- [ ] Add `APPLE_TEAM_ID`, `APPLE_API_KEY_ID`, `APPLE_API_ISSUER_ID` and
      `APPLE_API_PRIVATE_KEY` as GitHub Secrets.
- [ ] Add a distribution certificate + App Store provisioning profile (or move
      to Fastlane match) and a keychain-import step.
- [ ] Replace `CODE_SIGNING_ALLOWED=NO` with archive/export
      (`-exportArchive`, `method=app-store-connect`) in a separate gated job.
- [ ] Upload with `xcrun altool`/`notarytool` or `fastlane pilot` on `rc`/stable
      only, behind a protected `release` environment and manual approval.
- [ ] Keep the unsigned IPA + simulator zip artifacts regardless.
