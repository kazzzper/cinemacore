# Building

`make` is the supported entry point. Every target that produces an app embeds
the version from `VERSION` (and the current commit); nothing in app code
hardcodes a release number. Run `make help` for the short list.

```bash
make help
make check                 # validate VERSION
make build                 # Go build + Android debug APK
make test                  # Go race, Swift core, Android unit tests
```

## iOS with xtool

```bash
make ios-xtool ARGS="--configuration release --ipa"
# equivalent to: scripts/xtool dev build --configuration release --ipa
```

xtool does not expand `$(BUILD_SETTINGS)` in Info.plist. The committed
`Info.plist` is therefore the `0.0.0-dev` / `local` fallback, and
`scripts/xtool` swaps in a concrete plist with the real version for the build,
restoring it on exit (even on failure). Use the wrapper, not raw
`xtool dev build`, when you need the version embedded.

## iOS with Xcode

```bash
make version               # Generated/Version.xcconfig + Generated/Info.plist
make ios-xcode             # generated Xcode project, unsigned simulator build
make ios-release           # exact CI pipeline: unsigned .ipa + simulator .app.zip
```

`make ios-release` calls `scripts/ios-build`, the same script the tag workflow
runs. It builds device and simulator with `CODE_SIGNING_ALLOWED=NO`, verifies
`AppFullVersion`, `CFBundleVersion`, `AppCommit` and `CFBundleShortVersionString`
inside both apps, and writes `dist/`. It requires macOS and Xcode 27; there is no
signing and no Apple account. See [`IOS-CI.md`](IOS-CI.md) for sideloading.

The generated `.xcodeproj` and `Generated/` are gitignored.

## Android

```bash
make android               # ./gradlew :app:assembleDebug
```

`make android` exports `APP_FULL_VERSION`, `APP_BUILD_NUMBER` and `APP_COMMIT`
from `scripts/version`, so Gradle writes the tag version into `versionName`,
`versionCode` and `BuildConfig.GIT_COMMIT`. A raw Gradle build stays on the
`0.0.0-dev` / build `1` / `local` fallbacks.

## Web

There is no web app yet. Future web build systems must inject
`__APP_VERSION__`, `__BUILD_NUMBER__` and `__APP_COMMIT__` from
`scripts/version --env`; see [`../web/README.md`](../web/README.md).

## Versions at a glance

| Build path | Version source |
|---|---|
| `make ios-xtool` / `scripts/xtool` | concrete plist generated from `VERSION` |
| `make ios-xcode` / `make ios-release` / CI | `Generated/Version.xcconfig` |
| `make android` / CI | `APP_*` env into Gradle + `BuildConfig` |
| raw local build without make/wrapper | `0.0.0-dev`, build `0`/`1`, `local` |
