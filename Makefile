SHELL := bash
.DEFAULT_GOAL := help

IOS := mobile/ios/Cinemacore
ANDROID := mobile/android

.PHONY: help version check build test test-go test-swift test-android \
	ios-xtool ios-ipa ios-xcode ios-release android android-apk \
	release release-dry-run web

help:
	@printf '%s\n' \
	  'Cinemacore builds' \
	  '' \
	  '  make version                 generate iOS xcconfig + CI plist from VERSION' \
	  '  make check                   validate VERSION and tag format' \
	  '  make build                   Go build + Android debug APK' \
	  '  make test                    Go race suite + Swift core tests + Android tests' \
	  '' \
	  'iOS' \
	  '  make ios-xtool ARGS="..."    xtool build with the real version embedded' \
	  '  make ios-ipa ARGS="..."      unsigned device .ipa via xtool' \
	  '  make ios-xcode               unsigned simulator build via xcodebuild' \
	  '  make ios-release             exact CI pipeline: unsigned .ipa + simulator .app.zip' \
	  '' \
	  'Android' \
	  '  make android                 debug APK' \
	  '  make android-apk             debug APK alias' \
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

build:
	go build ./...
	$(MAKE) android

test: test-go test-swift test-android

test-go:
	go test ./... -race

test-swift:
	cd mobile/ios/CinemacoreCore && swift test

test-android:
	cd $(ANDROID) && ./gradlew --no-daemon :app:testDebugUnitTest

# xtool cannot expand $(BUILD_SETTINGS); the wrapper swaps in a concrete
# Info.plist for the build and restores the committed dev fallback afterwards.
ios-xtool:
	./scripts/xtool dev build $(ARGS)

ios-ipa:
	./scripts/xtool dev build --configuration release --ipa $(ARGS)

ios-xcode: version
	cd $(IOS) && xtool dev generate-xcode-project
	cd $(IOS) && xcodebuild \
	  -project Cinemacore.xcodeproj \
	  -scheme $${IOS_SCHEME:-Cinemacore} \
	  -configuration Release \
	  -sdk iphonesimulator \
	  -destination 'generic/platform=iOS Simulator' \
	  -xcconfig Generated/Version.xcconfig \
	  INFOPLIST_FILE=Generated/Info.plist \
	  GENERATE_INFOPLIST_FILE=NO INFOPLIST_EXPAND_BUILD_SETTINGS=YES \
	  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
	  build

ios-release:
	./scripts/ios-build

android android-apk:
	@set -a; source <(./scripts/version --env); set +a; \
	cd $(ANDROID) && ./gradlew --no-daemon :app:assembleDebug

release-dry-run:
	./scripts/release $(ARGS) --dry-run

release:
	./scripts/release $(ARGS)

web:
	@echo "No web app yet. Future web surfaces live in web/ — see web/README.md."
