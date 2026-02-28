SWIFTC := swiftc
SRC := Sources/frame_tv_control.swift
BIN_DIR := bin
BIN := $(BIN_DIR)/frame-tv-control

.PHONY: all build run clean

all: build

build:
	mkdir -p $(BIN_DIR)
	$(SWIFTC) -parse-as-library -O -o $(BIN) $(SRC)

run: build
	./$(BIN)

clean:
	rm -rf $(BIN_DIR)
