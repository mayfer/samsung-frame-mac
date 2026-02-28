APP_DISPLAY_NAME := Samsung Frame Remote
APP_EXECUTABLE := SamsungFrameRemote
BUILD_DIR := build
APP_DIR := $(BUILD_DIR)/$(APP_DISPLAY_NAME).app
SDEF_SRC := SamsungFrameRemote/Sources/SamsungFrameRemote.sdef
ICON_SRC := icon.png
ICONSET_DIR := $(BUILD_DIR)/AppIcon.iconset
ICON_ICNS := $(BUILD_DIR)/AppIcon.icns
ICON_ICNS_TMP := $(BUILD_DIR)/AppIcon.tmp.icns
ARM64_BUILD_DIR := .build/arm64
X86_64_BUILD_DIR := .build/x86_64
ARM64_BIN_PATH := $(ARM64_BUILD_DIR)/release/$(APP_EXECUTABLE)
X86_64_BIN_PATH := $(X86_64_BUILD_DIR)/release/$(APP_EXECUTABLE)
UNIVERSAL_BIN_PATH := $(BUILD_DIR)/$(APP_EXECUTABLE)-universal
SIGN_SCRIPT := scripts/sign_and_notarize.sh
SIGN_IDENTITY := Developer ID Application: Murat Ayfer (2463KXRFPH)
TEAM_ID := 2463KXRFPH
NOTARY_PROFILE ?= GOATREMOTE_NOTARY
SKIP_SIGN ?= 0

.PHONY: app app-universal icon run clean

app:
	$(MAKE) app-universal

app-universal: icon
	swift build -c release --arch arm64 --product $(APP_EXECUTABLE) --build-path $(ARM64_BUILD_DIR)
	swift build -c release --arch x86_64 --product $(APP_EXECUTABLE) --build-path $(X86_64_BUILD_DIR)
	mkdir -p $(BUILD_DIR)
	lipo -create -output "$(UNIVERSAL_BIN_PATH)" "$(ARM64_BIN_PATH)" "$(X86_64_BIN_PATH)"
	lipo -archs "$(UNIVERSAL_BIN_PATH)"
	rm -rf "$(APP_DIR)"
	mkdir -p "$(APP_DIR)/Contents/MacOS"
	mkdir -p "$(APP_DIR)/Contents/Resources"
	cp "$(UNIVERSAL_BIN_PATH)" "$(APP_DIR)/Contents/MacOS/$(APP_EXECUTABLE)"
	if [ -f "$(ICON_ICNS)" ]; then cp "$(ICON_ICNS)" "$(APP_DIR)/Contents/Resources/AppIcon.icns"; fi
	if [ -f "$(SDEF_SRC)" ]; then cp "$(SDEF_SRC)" "$(APP_DIR)/Contents/Resources/SamsungFrameRemote.sdef"; fi
	printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
	'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
	'<plist version="1.0">' \
	'<dict>' \
	'  <key>CFBundleName</key><string>$(APP_DISPLAY_NAME)</string>' \
	'  <key>CFBundleDisplayName</key><string>$(APP_DISPLAY_NAME)</string>' \
	'  <key>CFBundleIdentifier</key><string>local.samsung.frame.remote</string>' \
	'  <key>CFBundleExecutable</key><string>$(APP_EXECUTABLE)</string>' \
	'  <key>CFBundlePackageType</key><string>APPL</string>' \
	'  <key>CFBundleVersion</key><string>1</string>' \
	'  <key>CFBundleShortVersionString</key><string>1.0</string>' \
	'  <key>CFBundleIconFile</key><string>AppIcon</string>' \
	'  <key>NSScriptingDefinition</key><string>SamsungFrameRemote.sdef</string>' \
	'  <key>NSAppleScriptEnabled</key><true/>' \
	'  <key>LSMinimumSystemVersion</key><string>13.0</string>' \
	'  <key>NSPrincipalClass</key><string>NSApplication</string>' \
	'</dict>' \
	'</plist>' > "$(APP_DIR)/Contents/Info.plist"
	if [ "$(SKIP_SIGN)" != "1" ]; then \
		APP_EXECUTABLE="$(APP_EXECUTABLE)" SIGN_IDENTITY="$(SIGN_IDENTITY)" TEAM_ID="$(TEAM_ID)" NOTARY_PROFILE="$(NOTARY_PROFILE)" ./$(SIGN_SCRIPT) "$(APP_DIR)"; \
	else \
		echo "Skipping sign/notarize (SKIP_SIGN=1)"; \
	fi
	@echo "Built universal app bundle: $(APP_DIR)"

icon:
	rm -rf $(ICONSET_DIR) $(ICON_ICNS_TMP)
	mkdir -p $(ICONSET_DIR)
	sips -z 16 16 $(ICON_SRC) --out $(ICONSET_DIR)/icon_16x16.png
	sips -z 32 32 $(ICON_SRC) --out $(ICONSET_DIR)/icon_16x16@2x.png
	sips -z 32 32 $(ICON_SRC) --out $(ICONSET_DIR)/icon_32x32.png
	sips -z 64 64 $(ICON_SRC) --out $(ICONSET_DIR)/icon_32x32@2x.png
	sips -z 128 128 $(ICON_SRC) --out $(ICONSET_DIR)/icon_128x128.png
	sips -z 256 256 $(ICON_SRC) --out $(ICONSET_DIR)/icon_128x128@2x.png
	sips -z 256 256 $(ICON_SRC) --out $(ICONSET_DIR)/icon_256x256.png
	sips -z 512 512 $(ICON_SRC) --out $(ICONSET_DIR)/icon_256x256@2x.png
	sips -z 512 512 $(ICON_SRC) --out $(ICONSET_DIR)/icon_512x512.png
	sips -z 1024 1024 $(ICON_SRC) --out $(ICONSET_DIR)/icon_512x512@2x.png
	if iconutil -c icns $(ICONSET_DIR) -o $(ICON_ICNS_TMP); then \
		mv $(ICON_ICNS_TMP) $(ICON_ICNS); \
		echo "Updated icon: $(ICON_ICNS)"; \
	else \
		echo "Warning: iconutil failed; continuing without updating AppIcon.icns"; \
	fi

run:
	swift run SamsungFrameRemote

clean:
	rm -rf .build $(BUILD_DIR)
