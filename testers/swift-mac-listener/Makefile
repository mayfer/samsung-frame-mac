SHELL := /bin/bash

SLEEP_DEFAULT := printf "%s sleep\n" "$$(date -Iseconds)" >> /tmp/test.txt
WAKE_DEFAULT := printf "%s wake\n" "$$(date -Iseconds)" >> /tmp/test.txt

ON_SLEEP ?= $(SLEEP_DEFAULT)
ON_WAKE ?= $(WAKE_DEFAULT)

FRAME_IP ?= 192.168.1.48

.PHONY: help clean clean-all run run-frame-sleep

help:
	@echo "Targets:"
	@echo "  make clean             Clear local SwiftPM build cache (.build)"
	@echo "  make clean-all         Clear local cache + Xcode module cache"
	@echo "  make run               Run with ON_SLEEP/ON_WAKE variables"
	@echo "  make run-frame-sleep   Run frame-tv-control power --long on sleep"
	@echo ""
	@echo "Variables:"
	@echo "  ON_SLEEP='<command>'"
	@echo "  ON_WAKE='<command>'"
	@echo "  FRAME_IP=192.168.1.48"

clean:
	swift package clean

clean-all: clean
	rm -rf ~/Library/Developer/Xcode/DerivedData/ModuleCache.noindex

run:
	swift run sleep-wake-detector --on-sleep '$(ON_SLEEP)' --on-wake '$(ON_WAKE)'

run-frame-sleep:
	swift run sleep-wake-detector \
		--on-sleep './bin/frame-tv-control --ip $(FRAME_IP) power --long' \
		--on-wake ''
