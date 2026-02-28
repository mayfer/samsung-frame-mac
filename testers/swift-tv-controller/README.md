# Swift Samsung Frame CLI

Swift clone of `python/frame_tv_control.py` with matching commands:

- `pair`
- `state` (prints current `power`/`art` state when detectable)
- `power` (sends `KEY_POWER`; toggles power/art state)
- `power --medium` (~1.5s hold; screen black behavior on many models)
- `power --long` (~3.2s hold; hard power toggle on many models)
- `off` (state-aware: only sends `KEY_POWER` when TV is active)
- `to-hdmi`
- `on` (state-aware: WOL if off, `KEY_POWER` if in Art Mode)

## Build (from `swift/`)

```bash
make
```

Binary path:

```bash
./bin/frame-tv-control
```

## Examples

```bash
./bin/frame-tv-control --ip 192.168.1.48 pair
./bin/frame-tv-control --ip 192.168.1.48 state
./bin/frame-tv-control --ip 192.168.1.48 power
./bin/frame-tv-control --ip 192.168.1.48 power --medium
./bin/frame-tv-control --ip 192.168.1.48 power --long
./bin/frame-tv-control --ip 192.168.1.48 off
./bin/frame-tv-control --ip 192.168.1.48 to-hdmi
./bin/frame-tv-control --ip 192.168.1.48 on --mac AA:BB:CC:DD:EE:FF
```

If `--mac` is omitted for `on`, the tool tries `arp -n <ip>` to discover it.
