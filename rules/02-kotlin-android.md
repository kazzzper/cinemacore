# 02 — Kotlin / Android

Scope: `mobile/android/`. Source: Kotlin Coding Conventions, AndroidX Now in Android, Compose API guidelines.

## Language
- `val` by default; `var` only when reassigned. Immutable data classes.
- No platform types leaking: seal on the boundary. `data class` for DTOs/UI state.
- Expression bodies for one-liners. No `!!` in production — `requireNotNull`/safe calls only.
- Coroutines: `suspend` for one-shot, `Flow` for streams. No `GlobalScope`. Cancel with the caller's scope.

## Architecture (Clean)
- `domain/` is **pure Kotlin**, no Android imports. UseCases are `operator fun invoke`.
- `data/` implements repository interfaces from `domain/`. `presentation/` depends on `domain` only.
- One repository per aggregate; expose `Flow<Result<T>>`, never raw network types.

## Compose
- No work in composition: hoist to `ViewModel`, use `remember`/`derivedStateOf`.
- Stable `key` on every `LazyColumn`/`LazyRow` item.
- State flows down, events flow up. Composables take state + lambdas, not ViewModels.
- Preview every state: loading, empty, error, partial, success, permission.
- No hardcoded strings/colors/dimens — use `strings.xml` and the design tokens.

## DI & data
- Hilt (or Koin) at the app boundary; constructor injection everywhere else.
- Room for local, Retrofit/OkHttp (or Ktor) for remote. The API client comes from generated contract types.

## Quality
- `ktlint` + detekt clean. `explicitApi()` on library modules.
- Test ViewModels with `StandardTestDispatcher` (Compose v2 test APIs). See `06-testing.md`.
- Naming: `PascalCase` types, `camelCase` members, `SCREAMING_SNAKE_CASE` consts, `I`-free interfaces.
