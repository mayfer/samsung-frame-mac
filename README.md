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
