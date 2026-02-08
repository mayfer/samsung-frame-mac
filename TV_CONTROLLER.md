# TV Controller Logic

This document describes the current Samsung Frame TV control behavior implemented by `FrameMacApp`.

## Scope

The app combines:
- TV discovery (`NetService` + Bonjour)
- TV command transport (Samsung remote WebSocket + art WebSocket + WOL)
- Mac sleep/wake automation
- Manual command/test actions from UI

## Core Endpoints and Channels

- Device status endpoint:
  - `http://<TV_IP>:8001/api/v2/`
- Remote key channel:
  - `wss://<TV_IP>:8002/api/v2/channels/samsung.remote.control?name=<base64_app_name>[&token=...]`
- Art app channel:
  - `wss://<TV_IP>:8002/api/v2/channels/com.samsung.art-app?name=<base64_app_name>`

## App Identity / Token

- App name used for remote/art WebSocket: `frame-mac-local`
- Token file: `~/.samsung_tv_tokens.json`

## Discovery and Selection

- On launch:
  - If saved IP exists: app does **not** auto-scan.
  - If no saved IP: app auto-scans.
- Discovery dedupes by IP and prefers entries that include MAC.
- MAC is sourced from:
  1. Discovery result
  2. Per-IP MAC cache
  3. Manual MAC input
- Per-IP MAC cache file:
  - `~/Library/Application Support/FrameMacApp/mac_cache.json`

## Global Timeout Behavior

- UI command execution path has a 3-second timeout watchdog.
- If a command does not complete within 3s, UI reports timeout.

## Sleep/Wake Automation

User selects one mode:
- `TV controller off`
- `Sleep: power (short)`
- `Sleep: power (medium)`
- `Sleep: power (long)`

Behavior:
- On Mac sleep:
  - Sends selected power press variant.
- On Mac wake:
  - Uses `on --mac` semantics:
    - If TV online + standby -> short power
    - If TV offline -> WOL using MAC

## Manual Commands

Available manual actions include:
- `State` (online/offline only)
- `Pair`
- `To HDMI`
- `Art Mode On`
- `Art Mode Off`
- `Power` (short)
- `Power Medium`
- `Power Long`
- `On (WOL/state)`
- `Wake (WOL only)`
- `Off (power --long)`
- `KEY_POWEROFF`

### Notes

- `State` is intentionally simplified to online/offline reachability via `/api/v2/`.
- `On` / `Wake` require MAC when TV is offline.

## Testers Section

`Testers > On`:
- Reads `device.PowerState` from `/api/v2/`.
- If online and `standby`: short power.
- If offline: WOL with MAC.
- If online and not standby: no-op.

`Testers > Off`:
- Reads `device.PowerState` from `/api/v2/`.
- If offline: no-op.
- If `standby`: no-op.
- If `on`/`active`/unknown: short power.
- Any other explicit state: no-op.

## Reset Behavior

`Reset Saved Data` clears:
- Saved IP
- Saved MAC in user defaults
- Per-IP MAC cache in Application Support
- Saved Samsung tokens file (`~/.samsung_tv_tokens.json`)
