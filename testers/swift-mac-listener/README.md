# swift-mac-listener

Simple macOS sleep/wake listener CLI built with Swift.

## What it does

It listens for macOS sleep and wake notifications and runs shell commands:

- `--on-sleep "<command>"`
- `--on-wake "<command>"`

## Quick start

```bash
swift run sleep-wake-detector \
  --on-sleep './bin/frame-tv-control --ip 192.168.1.48 power --long' \
  --on-wake ''
```

## Make commands

- `make run-frame-sleep` runs the listener with `frame-tv-control` on sleep.
- `make run` runs the listener with configurable variables.
- `make clean` clears local SwiftPM build cache.
- `make clean-all` clears local cache and Xcode module cache.
- `make help` prints available targets.

### Variables for `make run`

- `ON_SLEEP` (default: append timestamp to `/tmp/test.txt`)
- `ON_WAKE` (default: append timestamp to `/tmp/test.txt`)

Example:

```bash
make run ON_SLEEP='./bin/frame-tv-control --ip 192.168.1.48 power --long' ON_WAKE=''
```

## If you see a PCH/module cache path error

If the repo path changed (for example folder rename/move), run:

```bash
make clean-all
make run
```
