#!/bin/bash
# Builds PenBoard.app: `swift build -c release`, assembles a standard app bundle
# under macos/build/, then code-signs it.
#
# This is the ONLY supported way to run/test BLE on this machine: TCC's
# Bluetooth prompt (driven by NSBluetoothAlwaysUsageDescription) only fires for
# a real .app bundle with an Info.plist — `swift run` never triggers it.
#
# Signing identity (risk R5): if the one-time self-signed "PenBoard Dev"
# certificate (see scripts/make-signing-cert.sh) is present in the keychain,
# sign with it so the app has a stable designated requirement and TCC grants
# (Bluetooth, Accessibility) survive rebuilds. Otherwise fall back to ad-hoc
# signing (`codesign --sign -`), which works for local use but invalidates
# prior TCC grants on every rebuild.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MACOS_DIR="$(dirname "$SCRIPT_DIR")"
cd "$MACOS_DIR"

APP_NAME="PenBoard"
BUNDLE_ID="it.aisma.penboard.mac"
SIGNING_IDENTITY_NAME="PenBoard Dev"

BUILD_DIR="$MACOS_DIR/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_BIN_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "==> swift build -c release"
swift build -c release

BIN_PATH_DIR="$(swift build -c release --show-bin-path)"
BUILT_BINARY="$BIN_PATH_DIR/$APP_NAME"
if [ ! -x "$BUILT_BINARY" ]; then
	echo "error: built binary not found at $BUILT_BINARY" >&2
	exit 1
fi

echo "==> assembling $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_BIN_DIR" "$RESOURCES_DIR"

cp "$BUILT_BINARY" "$MACOS_BIN_DIR/$APP_NAME"
cp "$MACOS_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
if [ -d "$MACOS_DIR/Resources" ]; then
	# Copy any other bundled resources (icons, etc.) alongside Info.plist,
	# without re-copying Info.plist itself.
	find "$MACOS_DIR/Resources" -mindepth 1 -maxdepth 1 ! -name "Info.plist" -exec cp -R {} "$RESOURCES_DIR/" \;
fi

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGNING_IDENTITY_NAME"; then
	SIGN_IDENTITY="$SIGNING_IDENTITY_NAME"
	echo "==> codesign --sign \"$SIGN_IDENTITY\" (stable identity, R5)"
else
	SIGN_IDENTITY="-"
	echo "==> codesign --sign - (ad-hoc; run scripts/make-signing-cert.sh once for a stable identity)"
fi

codesign --force --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" "$APP_BUNDLE"

echo "==> done: $APP_BUNDLE"
codesign -dv "$APP_BUNDLE"
