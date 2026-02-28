#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${1:-build/Samsung Frame Remote.app}"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Murat Ayfer (2463KXRFPH)}"
TEAM_ID="${TEAM_ID:-2463KXRFPH}"
NOTARY_PROFILE="${NOTARY_PROFILE:-GOATREMOTE_NOTARY}"
APP_NAME="$(basename "$APP_PATH" .app)"
ARCHIVE_PATH="$(dirname "$APP_PATH")/${APP_NAME}-notarize.zip"
SKIP_BUILD="${SKIP_BUILD:-0}"

if [[ ! -d "$APP_PATH" ]]; then
  if [[ "$SKIP_BUILD" == "1" ]]; then
    echo "App bundle not found: $APP_PATH" >&2
    exit 1
  fi
  echo "App bundle not found. Building with make app-universal..."
  make app-universal SKIP_SIGN=1
fi

if [[ -z "${APP_EXECUTABLE:-}" && -f "$APP_PATH/Contents/Info.plist" ]]; then
  APP_EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)"
fi
APP_EXECUTABLE="${APP_EXECUTABLE:-SamsungFrameRemote}"
APP_BIN="$APP_PATH/Contents/MacOS/$APP_EXECUTABLE"

if [[ ! -x "$APP_BIN" ]]; then
  echo "App executable not found: $APP_BIN" >&2
  exit 1
fi

if ! /usr/bin/security find-identity -v -p codesigning | /usr/bin/grep -F "$SIGN_IDENTITY" >/dev/null; then
  echo "Signing identity not found in keychain: $SIGN_IDENTITY" >&2
  exit 1
fi

echo "Signing app binary with: $SIGN_IDENTITY"
/usr/bin/codesign --force --sign "$SIGN_IDENTITY" --timestamp --options runtime "$APP_BIN"

echo "Signing app bundle with: $SIGN_IDENTITY"
/usr/bin/codesign --force --sign "$SIGN_IDENTITY" --timestamp --options runtime "$APP_PATH"

echo "Verifying signature"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo "Creating notarization archive: $ARCHIVE_PATH"
/bin/rm -f "$ARCHIVE_PATH"
/usr/bin/ditto -c -k --keepParent "$APP_PATH" "$ARCHIVE_PATH"

echo "Submitting for notarization with profile: $NOTARY_PROFILE"
/usr/bin/xcrun notarytool submit "$ARCHIVE_PATH" \
  --keychain-profile "$NOTARY_PROFILE" \
  --team-id "$TEAM_ID" \
  --wait

echo "Stapling notarization ticket"
/usr/bin/xcrun stapler staple -v "$APP_PATH"
/usr/bin/xcrun stapler validate -v "$APP_PATH"

echo "Final Gatekeeper assessment"
/usr/sbin/spctl --assess --type exec --verbose=4 "$APP_PATH"

echo "Done. Signed, notarized, and stapled: $APP_PATH"
