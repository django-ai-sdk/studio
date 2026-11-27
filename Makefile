APP := build/Studio.app

.PHONY: run app clean ios-project ios-build ios-run

# iOS (XcodeGen project in iOS/, compiles the same Sources/).
IOS_PROJECT := iOS/StudioiOS.xcodeproj
IOS_DERIVED := build/ios
IOS_SIM ?= iPhone 17
IOS_BUNDLE_ID := nl.django-ai-sdk.studio.ios
IOS_APP := $(IOS_DERIVED)/Build/Products/Debug-iphonesimulator/Studio.app

run:
	swift run

app:
	swift build -c release
	rm -rf $(APP) && mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp .build/release/Studio $(APP)/Contents/MacOS/
	cp Info.plist $(APP)/Contents/
	cp Resources/AppIcon.icns $(APP)/Contents/Resources/
	# SwiftPM resource bundles of dependencies (Textual's syntax highlighting, math fonts).
	cp -R .build/release/*.bundle $(APP)/Contents/Resources/
	codesign --force --sign - $(APP)
	@echo "Built $(APP)"

ios-project:
	cd iOS && xcodegen generate

ios-build: ios-project
	xcodebuild -project $(IOS_PROJECT) -scheme Studio -configuration Debug \
		-destination 'generic/platform=iOS Simulator' -derivedDataPath $(IOS_DERIVED) \
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
