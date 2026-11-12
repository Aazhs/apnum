#!/bin/sh
# Captures apnum's main window in demo mode without activating it or touching real data.
#
#   scripts/snapshot.sh <section> <out.png> [light|dark] [width] [height]
#
# section: today, alarms, timers, calendar, reminders, notes, activity
set -eu
cd "$(dirname "$0")/.."
SECTION="${1:-today}"; OUT="${2:-build/snapshot.png}"; LOOK="${3:-light}"
W="${4:-1100}"; H="${5:-740}"
: "${DEVELOPER_DIR:=/Applications/Xcode.app/Contents/Developer}"; export DEVELOPER_DIR

scripts/bundle.sh debug >/dev/null
HOME_DIR="$(mktemp -d)/apnum-demo"
mkdir -p "$HOME_DIR"
# A copy of the bundle per run so parallel snapshots do not collide.
RUN_APP="$(dirname "$HOME_DIR")/Apnum.app"
cp -R build/Apnum.app "$RUN_APP"
# Default window size for this run.
defaults write dev.apnum.mac "NSWindow Frame main" "100 100 $W $H 0 0 3000 2000" 2>/dev/null || true

open -g -n -F "$RUN_APP" --env APNUM_DEMO=1 --env APNUM_HOME="$HOME_DIR" --env APNUM_SECTION="$SECTION" --env APNUM_APPEARANCE="$LOOK"
PID=""
for _ in $(seq 1 40); do
  PID="$(pgrep -n -f "$RUN_APP/Contents/MacOS/Apnum" || true)"
  [ -n "$PID" ] && break; sleep 0.25
done
[ -n "$PID" ] || { echo "app did not start"; exit 1; }
sleep 3
WID="$(swift scripts/window-id.swift "$PID")"
mkdir -p "$(dirname "$OUT")"
screencapture -x -o -l "$WID" "$OUT"
kill "$PID" 2>/dev/null || true
rm -rf "$(dirname "$HOME_DIR")"
echo "$OUT"
