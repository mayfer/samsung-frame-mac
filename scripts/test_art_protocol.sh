#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
build_dir=$(mktemp -d /tmp/frame-art-tests.XXXXXX)
trap 'rm -rf "$build_dir"' EXIT
swiftc -module-cache-path "$build_dir/module-cache" \
    SamsungFrameRemote/Sources/ArtModeConnection.swift \
    SamsungFrameRemote/Sources/ArtWakePreparation.swift \
    SamsungFrameRemote/Sources/SamsungTVController.swift \
    Tests/ArtModeConnectionTests.swift -o "$build_dir/art-tests"
"$build_dir/art-tests"
