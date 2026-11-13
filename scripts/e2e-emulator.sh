#!/bin/sh
# Pairs the Android emulator with a throwaway demo instance of the Mac app, end to end.
#
#   scripts/e2e-emulator.sh [workdir]
#
# Needs: build/Apnum.app (scripts/bundle.sh), android/app/build/outputs/apk/debug/app-debug.apk
# (cd android && ./gradlew assembleDebug) and a running emulator (adb devices).
# Leaves the Mac instance running; its data is in <workdir>/home (audit.jsonl shows the phone's calls).
set -eu
cd "$(dirname "$0")/.."
W="${1:-$(mktemp -d)}"
mkdir -p "$W/home"
rm -f "$W/home/pairing-uri.txt"
rm -rf "$W/Apnum.app"; cp -R build/Apnum.app "$W/Apnum.app"
pkill -f "$W/Apnum.app/Contents/MacOS/Apnum" 2>/dev/null || true
open -g -n "$W/Apnum.app" --env APNUM_DEMO=1 --env APNUM_LINK=1 --env APNUM_LINK_AUTOPAIR=1 \
  --env APNUM_HOME="$W/home" --env APNUM_SECTION=phone
for _ in $(seq 1 30); do [ -f "$W/home/pairing-uri.txt" ] && break; sleep 1; done
[ -f "$W/home/pairing-uri.txt" ] || { echo "the Mac app did not open a pairing"; exit 1; }
# The emulator reaches the host Mac at 10.0.2.2.
URI="$(sed -E 's/host=[^&]*/host=10.0.2.2/' "$W/home/pairing-uri.txt")"
adb install -r android/app/build/outputs/apk/debug/app-debug.apk >/dev/null
adb shell pm clear dev.apnum.android >/dev/null
adb shell pm grant dev.apnum.android android.permission.ACCESS_LOCAL_NETWORK 2>/dev/null || true
adb shell pm grant dev.apnum.android android.permission.POST_NOTIFICATIONS 2>/dev/null || true
adb shell am start -a android.intent.action.VIEW -d "'$URI'" >/dev/null
for _ in $(seq 1 60); do grep -q paired "$W/home/link.json" 2>/dev/null && break; sleep 2; done
if grep -q paired "$W/home/link.json" 2>/dev/null; then
  echo "paired. workdir: $W"
else
  echo "not paired after 2 minutes. workdir: $W"; exit 1
fi
