APP := build/Studio.app

# Release version. VERSION is the full tag without the "v" (0.1.0-alpha.1), BUILD the CI run number.
# CFBundleShortVersionString / MARKETING_VERSION get only the numeric part (0.1.0).
VERSION ?= 0.0.0
BUILD ?= 0
SHORT_VERSION = $(firstword $(subst -, ,$(subst +, ,$(VERSION))))
DMG = build/Studio-$(VERSION).dmg

# Universal (arm64 + x86_64) release build. The output folder differs per SwiftPM version
# (.build/apple/Products/Release or .build/out/Products/Release), so ask SwiftPM for it.
SWIFT_RELEASE := swift build -c release --arch arm64 --arch x86_64
BIN = $(shell $(SWIFT_RELEASE) --show-bin-path)

.PHONY: run app dmg clean ios-project ios-build ios-run

# iOS (XcodeGen project in iOS/, compiles the same Sources/).
IOS_PROJECT := iOS/StudioiOS.xcodeproj
IOS_DERIVED := build/ios
IOS_SIM ?= iPhone 17
IOS_BUNDLE_ID := nl.django-ai-sdk.studio.ios
IOS_APP := $(IOS_DERIVED)/Build/Products/Debug-iphonesimulator/Studio.app

run:
	swift run

app:
	$(SWIFT_RELEASE)
	rm -rf $(APP) && mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	# SwiftPM records the deployment target (15.0) as the SDK version; macOS uses that to decide
	# whether the app gets the current (Liquid Glass) look, so record the real SDK, as Xcode does.
	vtool -set-build-version macos 15.0 $$(xcrun --show-sdk-version) -replace \
		-output $(APP)/Contents/MacOS/Studio "$(BIN)/Studio"
	cp Info.plist $(APP)/Contents/
	# Versions go into the copy only; the repo's Info.plist stays unchanged.
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(SHORT_VERSION)" $(APP)/Contents/Info.plist
	/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $(BUILD)" $(APP)/Contents/Info.plist
	cp Resources/AppIcon.icns $(APP)/Contents/Resources/
	# SwiftPM resource bundles of dependencies (Textual's syntax highlighting, math fonts).
	cp -R "$(BIN)"/*.bundle $(APP)/Contents/Resources/
	codesign --force --sign - $(APP)
	@echo "Built $(APP) $(SHORT_VERSION) ($(BUILD)), $$(lipo -archs $(APP)/Contents/MacOS/Studio)"

# Drag-to-install disk image: Studio.app next to an /Applications link.
dmg: app
	rm -rf build/dmg $(DMG) && mkdir -p build/dmg
	cp -R $(APP) build/dmg/
	ln -s /Applications build/dmg/Applications
	hdiutil create -volname Studio -srcfolder build/dmg -ov -format UDZO $(DMG)
	rm -rf build/dmg
	@echo "Built $(DMG)"

ios-project:
	cd iOS && xcodegen generate

ios-build: ios-project
	xcodebuild -project $(IOS_PROJECT) -scheme Studio -configuration Debug \
		-destination 'generic/platform=iOS Simulator' -derivedDataPath $(IOS_DERIVED) \
		MARKETING_VERSION=$(SHORT_VERSION) CURRENT_PROJECT_VERSION=$(BUILD) \
		CODE_SIGNING_ALLOWED=NO build

# Boots the simulator (IOS_SIM="iPad Pro 13-inch (M5)" for iPad), installs and launches the app.
ios-run: ios-build
	xcrun simctl boot "$(IOS_SIM)" 2>/dev/null || true
	# Xcode 27 replaced Simulator.app with Device Hub; fall back to Simulator on older Xcodes.
	open -b com.apple.dt.Devices 2>/dev/null || open -a Simulator 2>/dev/null || true
	xcrun simctl install "$(IOS_SIM)" $(IOS_APP)
	xcrun simctl launch "$(IOS_SIM)" $(IOS_BUNDLE_ID)

clean:
	rm -rf .build build
