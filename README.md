# Samsung Frame Remote

macOS app for local Samsung Frame TV power control, plus AppleScript `On` / `Off` commands for automation.

## Build + Sign + Notarize

Primary command:

```bash
./scripts/sign_and_notarize.sh
```

What it does:
- Builds the app automatically if `build/Samsung Frame Remote.app` is missing
- Codesigns app binary + bundle
- Submits for notarization
- Staples notarization ticket
- Runs Gatekeeper validation

Defaults used by the script:
- `APP_PATH=build/Samsung Frame Remote.app`
- `SIGN_IDENTITY=Developer ID Application: Murat Ayfer (2463KXRFPH)`
- `TEAM_ID=2463KXRFPH`
- `NOTARY_PROFILE=GOATREMOTE_NOTARY`

Override example:

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
TEAM_ID="TEAMID" \
NOTARY_PROFILE="YOUR_NOTARY_PROFILE" \
./scripts/sign_and_notarize.sh
```

Build only (no signing/notarization):

```bash
make app-universal SKIP_SIGN=1
```

## AppleScript

Supported commands (from other apps or Script Editor):

```applescript
tell application "Samsung Frame Remote" to On
tell application "Samsung Frame Remote" to Off
```

Notes:
- Launch the app at least once and select/save a TV in the UI first.
- `On` uses state-aware on logic (`WOL` when needed).
- `Off` uses the app's off path (long power press behavior).

## App organization

- **TV:** discover/select a TV, pair, or save its IP and Wake-on-LAN MAC address.
- **Shortcuts:** choose **Power mode** or **Art mode**, record global shortcuts, and configure launch at login and independent Mac sleep/wake automation.
- **Test & Debug:** run the actual shortcut actions, read reachability/Art state, expand advanced remote commands, and copy the session activity log.

The mode selection persists and keeps existing key combinations. In Power mode,
shortcuts retain the existing Power On/Off behavior. In Art mode, the same slots
become Enter Art/Exit Art. Assign the same combination to both slots for a toggle;
Art toggling reads the TV's reported state first. Failed state reads do not send a
toggle. Shortcut failures appear in the activity log.

Art control follows `../screensaver-tv/SamsungFrameAPI`: connect to the local
Art WebSocket on port 8001, wait for channel readiness, and correlate requests
with fresh UUIDs. Enter Art reads and reselects the current artwork with
`show: true`. Exit Art first confirms Art is on, then sends one short `KEY_POWER`
click to use the TV's normal resume path. It does not send the Art API off setter
or `KEY_EXIT`: both left the user in the Art Store. Already-off requests send no
power command, and failed state reads never cause a blind toggle. Both Art
transitions are verified by reading Art state; this cannot verify which input is
visible. Remote pairing must be approved for exit.
Sleep/wake automation and AppleScript commands remain independent power controls.

### Protocol checks

```sh
sh scripts/test_art_protocol.sh
```

These use a simulated Art transport to check message format, response matching,
artwork preservation, entry without a setter acknowledgement, state-guarded remote exit,
already-selected state, and error handling. They do not verify a physical TV's
WebSocket handshake or display output.

Art commands and Art status reads automatically retry once after a transient
network failure, with a 750 ms delay and a fresh connection. Art toggles retain
the original target across that retry and re-read the TV state before sending
another command, so a lost response does not toggle the TV back. TV rejections,
invalid responses, and task cancellation are not retried. Raw remote button
commands are not automatically replayed.

### Waking an offline TV from Art shortcuts

Art commands immediately send Wake-on-LAN when a MAC address is saved, before
waiting for any network response. The status bar reports the packet send, checks,
wake countdown, Art connection, transition, verification and any retry. If the
first probe reports standby or cannot reach the TV, the app waits up to about
30 seconds for readiness. Without a saved MAC, it checks reachability and explains
how to enable wake if the TV is unavailable.
An unreachable TV is not assumed to be definitely powered off; network outages
produce a clear wake timeout rather than a blind power-button press.

- **Exit Art:** wake if needed, read Art state, and send a short power click only
  if Art is on. If the TV wakes directly into viewing, no power click is sent.
- **Shared Art toggle:** when offline/standby, wake into viewing mode. When already
  awake, toggle normally. The target stays fixed across a network retry.
- **Enter Art:** wake if needed, then display the existing artwork.

Save the TV's MAC under **TV → Connection details**. The TV must remain plugged
in and connected to a network that supports waking it. Missing MAC addresses,
failed packet sends and wake timeouts are reported in the activity log.

Art WebSocket sends and receives each have a six-second transport timeout;
cancellation closes the socket so a stalled operation releases the command UI.

### Idle timer

In **Shortcuts → When your Mac is idle**, enable the checkbox and choose 1–240
minutes (default: 5). The setting follows the selected Power/Art mode:

- **Art:** display the current artwork after inactivity.
- **Power:** send a long power press to fully turn off the TV, including from Art.

The app checks system-wide keyboard/mouse idle time once per second using
[Apple's input inactivity API](https://developer.apple.com/documentation/coregraphics/cgeventsource/secondssincelasteventtype(_:eventtype:)).
Each idle period triggers only once. Commands wait while another command or TV
scan is running. Changing the mode, timer or selected TV starts a fresh interval;
Mac wake also restarts it. The app must remain running and the Mac must be awake
for the timer to fire. Watching video without keyboard/mouse input counts as idle.

**Return to viewing when activity resumes** is enabled by default and can be
unchecked. It wakes the TV if needed and exits Art mode after an idle action.
Manual TV commands cancel a pending automatic return. Idle automation is off by
default, persists across launches, and is independent of Mac sleep/wake automation.
