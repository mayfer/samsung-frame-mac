APP_NAME := FrameMacApp
BUILD_DIR := build
APP_DIR := $(BUILD_DIR)/$(APP_NAME).app
BIN_DIR := .build/release
BIN_PATH := $(BIN_DIR)/$(APP_NAME)

.PHONY: app run clean

app:
	swift build -c release --product $(APP_NAME)
	rm -rf $(APP_DIR)
	mkdir -p $(APP_DIR)/Contents/MacOS
	mkdir -p $(APP_DIR)/Contents/Resources
	cp $(BIN_PATH) $(APP_DIR)/Contents/MacOS/$(APP_NAME)
	printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
	'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
	'<plist version="1.0">' \
	'<dict>' \
	'  <key>CFBundleName</key><string>$(APP_NAME)</string>' \
	'  <key>CFBundleIdentifier</key><string>local.frame.mac.app</string>' \
	'  <key>CFBundleExecutable</key><string>$(APP_NAME)</string>' \
	'  <key>CFBundlePackageType</key><string>APPL</string>' \
	'  <key>CFBundleVersion</key><string>1</string>' \
	'  <key>CFBundleShortVersionString</key><string>1.0</string>' \
	'  <key>LSMinimumSystemVersion</key><string>13.0</string>' \
	'  <key>NSPrincipalClass</key><string>NSApplication</string>' \
	'</dict>' \
	'</plist>' > $(APP_DIR)/Contents/Info.plist
	@echo "Built app bundle: $(APP_DIR)"

run:
	swift run FrameMacApp

clean:
	rm -rf .build $(BUILD_DIR)
