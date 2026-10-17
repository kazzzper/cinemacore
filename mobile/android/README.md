# mobile/android

Kotlin + Jetpack Compose client.

## Prerequisites (not installed on this machine yet)

- **JDK 17+**
- **Android SDK** (`ANDROID_HOME` / `local.properties`)
- Gradle wrapper — generate once with `gradle wrapper` (or open in Android Studio)

Until those exist, `./gradlew assembleDebug` cannot run. Tracked as `T-006`.

## Layout

```
app/                          # entry point + DI wiring
  src/main/java/com/cinemacore/app/
    MainActivity.kt           # Compose entry
    ui/theme/Theme.kt         # design tokens (see docs/DESIGN_DIRECTION.md)
```

Planned (per `docs/ARCHITECTURE.md`): `domain/` (pure Kotlin), `data/` (Retrofit + Room), `presentation/`.

## Conventions

Follow `rules/02-kotlin-android.md`. Views come from the generated OpenAPI contract types — do not hand-write DTOs.
