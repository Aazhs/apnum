#!/bin/sh
# Builds build/Apnum.app from the Swift package.
#
#   scripts/bundle.sh            release build
#   scripts/bundle.sh debug      debug build
#
# Signing: set APNUM_SIGN_IDENTITY to a code-signing identity name to keep
# macOS permission grants (Calendar, Reminders) across rebuilds. Without it the
# app is signed ad hoc and macOS may ask for permissions again after each build.
set -eu

cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
: "${DEVELOPER_DIR:=/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR

swift build -c "$CONFIG" --product Apnum
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Apnum"

APP=build/Apnum.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Apnum"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$APP/Contents/Resources/"; fi

codesign --force --sign "${APNUM_SIGN_IDENTITY:--}" --timestamp=none "$APP"
echo "Built $APP"
