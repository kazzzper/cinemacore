SHELL := bash
.DEFAULT_GOAL := help

IOS := mobile/ios/Cinemacore
ANDROID := mobile/android
RELEASE_DIR := $(CURDIR)/release

.PHONY: help version check tag build test test-go test-swift test-android \
	dev-ios dev-android \
	ios-xtool ios-ipa ios-xcode ios-release android android-apk android-release \
	tag-release release release-dry-run web

help:
	@printf '%s\n' \
	  'Cinemacore builds (artifacts land in release/, gitignored)' \
	  '' \
	  '  make version                 generate iOS xcconfig + CI plist from VERSION' \
	  '  make check                   validate VERSION and tag format' \
	  '  make tag                     tag the current commit with VERSION (local)' \
	  '  make build                   versioned Go build + versioned debug APK' \
	  '  make test                    Go race suite + Swift core tests + Android tests' \
	  '' \
	  'Devices' \
	  '  make dev-ios ARGS="--usb"    build, install and run on a connected iPhone' \
	  '  make dev-android             build and install the debug APK on a device/emulator' \
	  '' \
	  'iOS' \
	  '  make ios-xtool ARGS="..."    xtool build with the real version embedded' \
	  '  make ios-ipa ARGS="..."      unsigned device .ipa via xtool -> release/' \
	  '  make ios-xcode               unsigned simulator build via xcodebuild' \
	  '  make ios-test                iOS unit tests on a simulator' \
	  '  make ios-release             exact CI pipeline: unsigned .ipa + simulator .app.zip' \
	  '' \
	  'Android' \
	  '  make android                 debug APK' \
	  '  make android-apk             debug APK alias' \
	  '  make android-release         installable release APK (debug-signed without a keystore)' \
	  '' \
	  'Releases' \
	  '  make release-dry-run ARGS="patch --channel beta"' \
	  '  make release ARGS="patch --channel beta"' \
	  '' \
	  'Docs: docs/BUILDING.md, RELEASING.md, docs/IOS-CI.md'

version:
	./scripts/generate-version

check:
	./scripts/version --check

# Tag the version already in VERSION; `make release` bumps and tags in one go.
tag:
	./scripts/tag

build: version
	go build ./...
	$(MAKE) android

test: test-go test-swift test-android

test-go:
	go test ./... -race

test-swift:
	cd mobile/ios/CinemacoreCore && swift test

test-android:
	cd $(ANDROID) && ./gradlew --no-daemon :app:testDebugUnitTest

dev-ios:
	./scripts/xtool dev run $(ARGS)

dev-android:
	@set -a; source <(./scripts/version --env); set +a; \
	cd $(ANDROID) && ./gradlew --no-daemon :app:installDebug

# xtool cannot expand $(BUILD_SETTINGS); the wrapper swaps in a concrete
# Info.plist for the build and restores the committed dev fallback afterwards.
ios-xtool:
	./scripts/xtool dev build $(ARGS)

ios-ipa:
	@set -a; source <(./scripts/version --env); set +a; \
	./scripts/xtool dev build --configuration release --ipa $(ARGS) && \
	mkdir -p $(RELEASE_DIR) && \
	cp $(IOS)/xtool/Cinemacore.ipa $(RELEASE_DIR)/Cinemacore-$$APP_TAG-unsigned.ipa

# Committed project, Xcode only. Ad-hoc signing for the simulator: an unsigned
# arm64 simulator app is not launchable.
ios-xcode:
	cd $(IOS) && xcodebuild \
	  -project Cinemacore.xcodeproj \
	  -scheme $${IOS_SCHEME:-Cinemacore} \
	  -configuration Release \
	  -destination 'generic/platform=iOS Simulator' \
	  -derivedDataPath .build/DerivedData \
	  CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="-" \
	  build

# The Darwin lane: the same tests, on a simulator, against the iOS SDK. CI runs
# this on tags only; `make test-swift` is the gate.
ios-test:
	./scripts/ios-test

ios-release:
	./scripts/ios-build

android android-apk:
	@set -a; source <(./scripts/version --env); set +a; \
	cd $(ANDROID) && ./gradlew --no-daemon :app:assembleDebug && \
	mkdir -p $(RELEASE_DIR) && \
	cp app/build/outputs/apk/debug/app-debug.apk \
	  $(RELEASE_DIR)/Cinemacore-$$APP_TAG-debug.apk

# Without CINEMACORE_KEYSTORE* Gradle signs with the debug key so the APK
# installs; set those vars for a real production signature.
android-release:
	@set -a; source <(./scripts/version --env); set +a; \
	cd $(ANDROID) && ./gradlew --no-daemon :app:assembleRelease && \
	mkdir -p $(RELEASE_DIR) && \
	cp app/build/outputs/apk/release/app-release.apk \
	  $(RELEASE_DIR)/Cinemacore-$$APP_TAG.apk

release-dry-run:
	./scripts/release $(ARGS) --dry-run

release:
	./scripts/release $(ARGS)

web:
	@echo "No web app yet. Future web surfaces live in web/ — see web/README.md."
