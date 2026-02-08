# Samsung Frame TV (2022) Local Power Control

This project sends local-only power commands to a Samsung Frame TV:

- `sleep`: puts TV into Art Mode using local `KEY_POWER`
- `on`: Wake-on-LAN magic packet (no Samsung cloud)
- `wake`: exits Art Mode using local `KEY_POWER` (your confirmed working path)
- `to-hdmi`: exits Art UI and selects HDMI using your confirmed sequence

## 1) Pair once (TV ON)

```bash
uv run frame_tv_control.py --ip 192.168.1.48 pair
```

Approve the app prompt on the TV. This stores a local token in `.samsung_tv_tokens.json`.

## 2) Sleep (to Art Mode)

```bash
uv run frame_tv_control.py --ip 192.168.1.48 sleep
```

## 3) Wake from Art Mode

```bash
uv run frame_tv_control.py --ip 192.168.1.48 wake
```

## 4) Power on from real off (Wake-on-LAN)

If ARP already knows the TV MAC:

```bash
uv run frame_tv_control.py --ip 192.168.1.48 on
```

Or specify MAC directly:

```bash
uv run frame_tv_control.py --ip 192.168.1.48 on --mac AA:BB:CC:DD:EE:FF
```

## 5) From Art Mode/Menu to HDMI

```bash
uv run frame_tv_control.py --ip 192.168.1.48 to-hdmi
```

## Notes

- This is LAN-only and does not use Samsung cloud APIs.
- No manual install step: `uv run` resolves dependencies from `pyproject.toml`.
- If `sleep` fails, make sure the TV is on and connected to the same network.
- For `on`, Wake-on-LAN must be allowed by TV/network settings.
- In your setup, use `wake` for Art Mode and `on` only for true power-off wake.
