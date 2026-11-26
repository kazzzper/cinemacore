# Changelog

## [0.0.1-beta.3] - 2026-11-26

### Bug Fixes

- **release:** record only the commits since the last tag
- **ios:** keep captions on stored-row playbacks and in downloads
- **ios:** put the bundle identity in Info.plist for xcodebuild
- **ios:** stat file sizes so a grown partial is seen

### CI

- **ios:** let a manual dispatch run the simulator suite
- **ios:** test the package on linux and keep the simulator for tags
- **release:** verify the iOS build on every non-tag run
- **ios:** build releases with Xcode only
## [0.0.1-beta.2] - 2026-11-25

### Bug Fixes

- **ios:** build release artifacts with xcodebuild only
- **release:** mark beta releases as prereleases and stop force-moving channel tags

### Build

- **ci:** test iOS in the release workflow instead of repeating Go checks

## [0.0.1-beta.1] - 2026-11-25

### Features

- **android:** port subtitles, feature tracking, splash and icons
- **ios:** pick download quality and resume web playback
- **android:** port Kotlin/Compose client with generated OpenAPI types
- **ios:** play, save and switch sources from the app shell
- **ios-core:** fetch and keep captions for saved episodes
- **ios-core:** resumable downloads, with captions saved beside them
- **ios-core:** repair hev1 HEVC in flight and on disk
- **ios-core:** keep captions attached and offer a keyless fallback
- **ios-core:** reach MovieBox directly with a signed session
- **core:** add StreamHype as a second catalog source
- batch land in-flight core, server, docs, and iOS work
- **ios:** land Cinemacore iOS app with iOS 27 modernization and fixes
- **server:** implement remaining contract endpoints
- **ios:** add app icon and splash assets
- **ios:** add CinemacoreCore models, decoding, API and view models
- **contracts:** add seasons, play and search-suggestion endpoints
- **ui:** bootstrapping designn tokens and generating app screens

### Bug Fixes

- **android:** resume StreamHype embeds and open downloads instantly
- **ios:** keep the StreamHype resume seek from being overwritten
- **core:** key series subtitles by the playing episode's resource id
- **ios:** give the StreamHype web player a way out
- **ios:** key series subtitles by the playing episode's resource id
- **ios:** keep the fullscreen picture size when chrome hides
- **ios:** keep landscape playback and default StreamHype to TMDB
- **ios-core:** open a series at the season the caller asked for
- **ios-core:** never show a raw NSError as the reason
- **provider:** resolve the requested episode instead of the first one
- **provider:** resolve live MovieBox content via signed guest session

### Documentation

- **readme:** add configuration, docs map; gitignore kotlin cache
- **readme:** add toolchain prerequisites and setup instructions
- **readme:** simplify to scannable, badge-free structure
- **readme:** marketing-style rewrite with badges and sections
- refresh README/AGENTS for Android toolchain and status
- record the StreamHype map, the playback ADRs, and the architecture
- **repo:** add project banner image

### Build

- **ios:** pin swift-crypto resolution

### Tests

- **ios:** add model and subtitle tests, fix signing closure

### Other

- **gitignore:** restore gradle cache ignore
- **contract:** tighten error and subject schema
- **repo:** ignore build scratch, enforce conventional commits
- **repo:** bootstrap cinemacore monorepo
