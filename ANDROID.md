# Android toolchain

Setup of record for `mobile/android/`. Last verified **2026-10-25** against Android CLI
`1.1.16717390`, JDK `17.0.20.1`, and Android SDK at `$HOME/Android/Sdk`.

Google has **deprecated `sdkmanager`**. The replacement is the Android CLI:

```bash
android sdk [install|list|update|remove]
```

Official sources:

- [Android CLI overview](https://developer.android.com/tools/agents/android-cli)
- [Android CLI downloads](https://developer.android.com/tools/agents/android-cli/download)
- [`android sdk` reference](https://developer.android.com/tools/agents/android-cli/commands/sdk)
- [`sdkmanager` deprecation notice](https://developer.android.com/tools/sdkmanager)

Android Studio still works and its SDK Manager is fine, but the CLI is what makes a fresh
machine reproducible.

---

## 1. JDK 17

The app compiles to Java 17, and AGP `9.1.1` requires JDK 17+.

```bash
sudo apt install openjdk-17-jdk
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
export PATH="$JAVA_HOME/bin:$PATH"
java -version
```

Put the two exports in your shell profile if you switch JDKs often.

## 2. Install Android CLI

Local install (recommended):

```bash
curl -fsSL https://dl.google.com/android/cli/latest/linux_x86_64/install.sh | bash
source ~/.bashrc
command -v android
android update
android -V
```

The installer writes `~/.local/bin/android` and adds that directory to `PATH`. Other install
methods (apt, Homebrew, global install) are on the
[download page](https://developer.android.com/tools/agents/android-cli/download).

Optional, for AI agents:

```bash
android init    # installs the android-cli skill for detected agents
```

## 3. Point Android CLI at the SDK

The default SDK in this repo's environment is `$HOME/Android/Sdk`.

```bash
export ANDROID_HOME="$HOME/Android/Sdk"
export PATH="$ANDROID_HOME/platform-tools:$PATH"
android info
```

If you keep the SDK somewhere else, either pass the path per command:

```bash
android --sdk=/path/to/android-sdk sdk list
```

or make it the default in `~/.androidrc`:

```text
--sdk=/path/to/android-sdk
```

## 4. Install the packages this project needs

```bash
android sdk install \
  platforms/android-37.0 \
  build-tools/36.0.0 \
  platform-tools
```

Verify:

```bash
android sdk list
android sdk list --all 'platforms/*'
```

`app/build.gradle.kts` pins `compileSdk = 37`, `targetSdk = 36`, `minSdk = 24`, and the build
tools are the `36.0.0` line. Compose `1.12` (BOM `2026.08.00`) requires compiling against API 37.
An older `platforms/android-36` is not enough; install `platforms/android-37.0`.

Package paths use slashes now. Old guides use semicolons, for example
`"platforms;android-36"`; that form is still accepted, but quote it.

The CLI records accepted SDK licenses in the format Gradle expects. If a Gradle sync still
reports unaccepted licenses, open Android Studio's **SDK Manager** once. Do not install
`cmdline-tools` only to run the legacy `sdkmanager --licenses`.

## 5. Build

AGP `9.1.1` needs Gradle `9.1+`. The wrapper **is checked in** (`gradlew`, `gradlew.bat`, and
`gradle/wrapper/`), so no generation step is needed:

```bash
cd mobile/android
./gradlew :app:assembleDebug
./gradlew :app:testDebugUnitTest
```

The APK lands at `app/build/outputs/apk/debug/app-debug.apk`.

Install it on a connected device or emulator:

```bash
./gradlew :app:installDebug
adb shell am start -n com.cinemacore.app/.MainActivity
```

The Android client is a behavioural port of the iOS app. Its architecture (generated OpenAPI client,
Media3 playback, foreground download service, exact feature limits) is documented in
[`mobile/android/README.md`](mobile/android/README.md). Do not describe planned work as shipped.

### Android Studio

Open **`mobile/android`** directly, not the repository root:

```bash
cd mobile/android
studio .
```

The stable launcher is `~/.local/bin/studio -> /home/sammy/android-studio/bin/studio`. Gradle sync
uses the checked-in wrapper and JDK 17.

## 6. Gateway address

- **Emulator:** `http://10.0.2.2:8080`
- **Physical device:** `http://<host-LAN-IP>:8080`

Start the Go gateway from the repo root with `go run ./cmd/cinemacore`. It binds all interfaces
by default.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `android: command not found` | `source ~/.bashrc` or add `$HOME/.local/bin` to `PATH` |
| `SDK location not found` | Export `ANDROID_HOME`, or write `sdk.dir=/path/to/android-sdk` to `mobile/android/local.properties` |
| `Failed to find target with hash string 'android-37'` | `android sdk install platforms/android-37.0` |
| Gradle uses the wrong Java | Point `JAVA_HOME` at JDK 17 and re-run `./gradlew --version` |
| `sdkmanager: command not found` | Do not chase it; use `android sdk`. It is deprecated. |

For the old command shape:

```bash
# deprecated
sdkmanager "platforms;android-37.0" "build-tools;36.0.0"

# current
android sdk install platforms/android-37.0 build-tools/36.0.0
```
