#!/usr/bin/env python3
"""Local-only Samsung Frame TV power control.

- Sleep/Art Mode: Samsung LAN remote websocket API (wss://TV_IP:8002)
- Power ON: Wake-on-LAN magic packet

Tested logic is written for Samsung Frame 2022 models.
"""

from __future__ import annotations

import argparse
import asyncio
import base64
import json
import re
import socket
import ssl
import subprocess
import sys
from pathlib import Path
from typing import Any

TOKEN_FILE = Path(".samsung_tv_tokens.json")
DEFAULT_APP_NAME = "frame-mac-local"


class SamsungTVError(RuntimeError):
    pass


def load_tokens() -> dict[str, str]:
    if not TOKEN_FILE.exists():
        return {}
    try:
        return json.loads(TOKEN_FILE.read_text())
    except Exception:
        return {}


def save_tokens(tokens: dict[str, str]) -> None:
    TOKEN_FILE.write_text(json.dumps(tokens, indent=2, sort_keys=True))


def get_saved_token(ip: str) -> str | None:
    return load_tokens().get(ip)


def set_saved_token(ip: str, token: str) -> None:
    tokens = load_tokens()
    tokens[ip] = token
    save_tokens(tokens)


def parse_mac(value: str) -> bytes:
    clean = re.sub(r"[^0-9A-Fa-f]", "", value)
    if len(clean) != 12:
        raise SamsungTVError(f"Invalid MAC address: {value}")
    return bytes.fromhex(clean)


def discover_mac_from_arp(ip: str) -> str | None:
    try:
        out = subprocess.check_output(["arp", "-n", ip], text=True, stderr=subprocess.STDOUT)
    except Exception:
        return None
    match = re.search(r"(([0-9a-fA-F]{2}[:-]){5}[0-9a-fA-F]{2})", out)
    return match.group(1) if match else None


def infer_subnet_broadcast(ip: str) -> str:
    parts = ip.split(".")
    if len(parts) != 4:
        return "255.255.255.255"
    return ".".join(parts[:3] + ["255"])


def send_wol(mac: str, ip: str, port: int = 9) -> None:
    mac_bytes = parse_mac(mac)
    packet = b"\xff" * 6 + mac_bytes * 16
    targets = ["255.255.255.255", infer_subnet_broadcast(ip)]

    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        for target in targets:
            sock.sendto(packet, (target, port))


def _extract_token(message: dict[str, Any]) -> str | None:
    data = message.get("data")
    if not isinstance(data, dict):
        return None
    token = data.get("token")
    if token is None:
        return None
    return str(token)


async def _wait_for_connect_and_store_token(ws: Any, ip: str, timeout: float = 8.0) -> None:
    deadline = asyncio.get_running_loop().time() + timeout
    while True:
        remaining = deadline - asyncio.get_running_loop().time()
        if remaining <= 0:
            return
        try:
            raw = await asyncio.wait_for(ws.recv(), timeout=remaining)
        except asyncio.TimeoutError:
            return
        try:
            msg: dict[str, Any] = json.loads(raw)
        except json.JSONDecodeError:
            continue
        token = _extract_token(msg)
        if token:
            set_saved_token(ip, token)
        if msg.get("event") == "ms.channel.connect":
            return


async def send_remote_keys(ip: str, keys: list[str], app_name: str = DEFAULT_APP_NAME) -> None:
    try:
        import websockets  # type: ignore
    except ImportError as exc:
        raise SamsungTVError(
            "Missing dependency 'websockets'. Use: uv run frame_tv_control.py ..."
        ) from exc

    name_b64 = base64.b64encode(app_name.encode("utf-8")).decode("ascii")
    token = get_saved_token(ip)

    url = f"wss://{ip}:8002/api/v2/channels/samsung.remote.control?name={name_b64}"
    if token:
        url += f"&token={token}"

    ssl_ctx = ssl.create_default_context()
    ssl_ctx.check_hostname = False
    ssl_ctx.verify_mode = ssl.CERT_NONE

    try:
        async with websockets.connect(url, ssl=ssl_ctx, open_timeout=6, close_timeout=2) as ws:
            # After user accepts TV prompt, the usable state arrives as ms.channel.connect.
            await _wait_for_connect_and_store_token(ws, ip)
            for key in keys:
                payload = {
                    "method": "ms.remote.control",
                    "params": {
                        "Cmd": "Click",
                        "DataOfCmd": key,
                        "Option": "false",
                        "TypeOfRemote": "SendRemoteKey",
                    },
                }
                await ws.send(json.dumps(payload))
                await asyncio.sleep(0.25)
    except OSError as exc:
        raise SamsungTVError(
            f"Could not connect to TV at {ip}:8002. Ensure TV is ON and on same LAN. ({exc})"
        ) from exc


def cmd_on(args: argparse.Namespace) -> int:
    mac = args.mac or discover_mac_from_arp(args.ip)
    if not mac:
        raise SamsungTVError(
            "MAC address required for power on. Pass --mac (example: AA:BB:CC:DD:EE:FF) "
            "or run once while TV is on so ARP can discover it."
        )
    send_wol(mac, args.ip, args.wol_port)
    print(f"Sent Wake-on-LAN packet to {mac} for TV {args.ip}")
    return 0


def cmd_sleep(args: argparse.Namespace) -> int:
    # Frame behavior: KEY_POWER toggles active TV <-> Art Mode.
    asyncio.run(send_remote_keys(args.ip, ["KEY_POWER"], args.app_name))
    print("Sent sleep command (KEY_POWER)")
    return 0


def cmd_pair(args: argparse.Namespace) -> int:
    asyncio.run(send_remote_keys(args.ip, ["KEY_HOME"], args.app_name))
    print("Pair/connect command sent. Approve this app on TV if prompted.")
    return 0


def cmd_wake(args: argparse.Namespace) -> int:
    # Confirmed on this TV: KEY_POWER exits Art Mode into active TV UI.
    asyncio.run(send_remote_keys(args.ip, ["KEY_POWER"], args.app_name))
    print("Sent wake command (KEY_POWER)")
    return 0


def cmd_to_hdmi(args: argparse.Namespace) -> int:
    # Confirmed on this TV: Art menu -> HDMI via SOURCE, RIGHT, ENTER.
    asyncio.run(send_remote_keys(args.ip, ["KEY_SOURCE", "KEY_RIGHT", "KEY_ENTER"], args.app_name))
    print("Sent Art-to-HDMI sequence (KEY_SOURCE, KEY_RIGHT, KEY_ENTER)")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Local Samsung Frame TV power control (no cloud integration)."
    )
    parser.add_argument("--ip", default="192.168.1.48", help="TV IP address")
    parser.add_argument("--app-name", default=DEFAULT_APP_NAME, help="Client name shown on TV")

    sub = parser.add_subparsers(dest="command", required=True)

    on_p = sub.add_parser("on", help="Power on TV via Wake-on-LAN")
    on_p.add_argument("--mac", help="TV MAC address (AA:BB:CC:DD:EE:FF)")
    on_p.add_argument("--wol-port", default=9, type=int, help="Wake-on-LAN UDP port")
    on_p.set_defaults(func=cmd_on)

    sleep_p = sub.add_parser("sleep", help="Put TV into Art Mode (KEY_POWER)")
    sleep_p.set_defaults(func=cmd_sleep)

    # Backward-compatible alias.
    off_p = sub.add_parser("off", help="Alias for sleep")
    off_p.set_defaults(func=cmd_sleep)

    pair_p = sub.add_parser("pair", help="Create/refresh local token while TV is on")
    pair_p.set_defaults(func=cmd_pair)

    wake_p = sub.add_parser("wake", help="Wake from Art Mode/ambient state (KEY_POWER)")
    wake_p.set_defaults(func=cmd_wake)

    hdmi_p = sub.add_parser("to-hdmi", help="Switch from Art menu to HDMI (saved sequence)")
    hdmi_p.set_defaults(func=cmd_to_hdmi)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    try:
        return args.func(args)
    except SamsungTVError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
