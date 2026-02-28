BINARY_NAME := detect-tv-ip
BUILD_DIR := .build/release
OUTPUT_DIR := bin

.PHONY: all build run clean

all: build

build:
	swift build -c release
	mkdir -p $(OUTPUT_DIR)
	cp $(BUILD_DIR)/swift-detect-tv-ip $(OUTPUT_DIR)/$(BINARY_NAME)
	chmod +x $(OUTPUT_DIR)/$(BINARY_NAME)
	@echo "Built $(OUTPUT_DIR)/$(BINARY_NAME)"

run: build
	./$(OUTPUT_DIR)/$(BINARY_NAME)

clean:
	rm -rf .build $(OUTPUT_DIR)
