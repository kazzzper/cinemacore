# Building

`make` is the supported entry point. Every target that produces an app embeds
the version from `VERSION` (and the current commit); nothing in app code
hardcodes a release number. Run `make help` for the short list.

```bash
make help
make check                 # validate VERSION
make tag                   # tag the current commit with VERSION
make build                 # versioned Go build + versioned debug APK
make test                  # Go race, Swift core, Android unit tests
```

Every app artifact is written to `release/`, which is gitignored. `make build`
stamps the version from `VERSION` into the generated iOS inputs and into the
Android APK, then leaves `release/Cinemacore-v<version>-debug.apk` behind.

## Run on a device

```bash
make dev-ios ARGS="--usb"  # xtool: build, install and launch on the iPhone
make dev-android           # gradlew :app:installDebug on the attached device
```

`dev-ios` goes through `scripts/xtool`, so the on-device app reports the real
`VERSION` and commit. xtool needs a paired device (and macOS); pass `--udid`,
`--usb`, `--network` or `--all` through `ARGS`. `dev-android` uses `adb`, so
the device must be authorised and visible in `adb devices`.

## iOS with xtool

```bash
make ios-xtool ARGS="--configuration release --ipa"
make ios-ipa               # unsigned device .ipa -> release/Cinemacore-v<version>-unsigned.ipa
```

xtool does not expand `$(BUILD_SETTINGS)` in Info.plist. The committed
`Info.plist` is therefore the `0.0.0-dev` / `local` fallback, and
`scripts/xtool` swaps in a concrete plist with the real version for the build,
restoring it on exit (even on failure). Use the wrapper, not raw
`xtool dev build`, when you need the version embedded. `make ios-ipa` also
copies the result into `release/`, named from `VERSION`, so the tag travels
with the artifact on every build without extra flags.

## iOS release

```bash
make ios-xcode             # simulator build of the committed Xcode project
make ios-test              # iOS unit tests on a simulator
make ios-release           # exact CI pipeline: unsigned .ipa + simulator .app.zip
```

`make ios-release` calls `scripts/ios-build`, the same script the tag workflow
runs. The app target is committed at
`mobile/ios/Cinemacore/Cinemacore.xcodeproj`, so the script is pure
`xcodebuild`: no xtool, no project generation. It builds the device and
simulator app, writes the concrete version into the target's `Info.plist` for
the lifetime of the build, verifies `AppFullVersion`, `CFBundleVersion`,
`AppCommit` and `CFBundleShortVersionString` inside the outputs, and writes
`release/Cinemacore-v<version>-unsigned.ipa` and
`release/Cinemacore-v<version>-simulator.app.zip`. The device app is unsigned;
the simulator app is ad-hoc signed so an arm64 Mac can launch it. There is no
Apple account involved. See [`IOS-CI.md`](IOS-CI.md) for sideloading.

`Generated/` (from `make version`) is only used by the Android/web paths and by
`scripts/xtool`; the Xcode build does not read it.

## Android

```bash
make android               # debug APK -> release/Cinemacore-v<version>-debug.apk
make android-release       # release APK -> release/Cinemacore-v<version>.apk
make dev-android           # install the debug build on a device
```

`make android` and `make android-release` export `APP_FULL_VERSION`,
`APP_BUILD_NUMBER` and `APP_COMMIT` from `scripts/version`, so Gradle writes the
tag version into `versionName`, `versionCode` and `BuildConfig.GIT_COMMIT`. A raw
Gradle build stays on the `0.0.0-dev` / build `1` / `local` fallbacks.

No keystore is committed, so release APKs are signed with the debug key and stay
installable. Set `CINEMACORE_KEYSTORE`, `CINEMACORE_KEYSTORE_PASSWORD`,
`CINEMACORE_KEY_ALIAS` and `CINEMACORE_KEY_PASSWORD` to sign with a real key.

## Web

There is no web app yet. Future web build systems must inject
`__APP_VERSION__`, `__BUILD_NUMBER__` and `__APP_COMMIT__` from
`scripts/version --env`; see [`../web/README.md`](../web/README.md).

## Versions at a glance

| Build path | Version source |
|---|---|
| `make ios-xtool` / `scripts/xtool` | concrete plist generated from `VERSION` |
| `make ios-xcode` / `make ios-release` / CI | concrete plist written from `VERSION` into the app target's `Info.plist` |
| `make android` / `make android-release` / `dev-android` / CI | `APP_*` env into Gradle + `BuildConfig` |
| raw local build without make/wrapper | `0.0.0-dev`, build `0`/`1`, `local` |
