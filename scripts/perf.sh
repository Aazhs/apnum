#!/bin/bash
# Measures the release app's CPU and memory in each state and checks the budgets in docs/performance.md.
#
#   scripts/perf.sh [seconds-per-state]     default 8; builds build/Apnum.app first unless NO_BUILD=1
#
# Each state runs a throwaway demo copy of the app with its own empty data folder (APNUM_DEMO=1,
# APNUM_HOME=<tmp>), so your real apnum and ~/Library/Application Support/apnum are never touched.
# Only the copies this script starts are ever killed. Exit status is 1 when a budget is exceeded.

cd "$(dirname "$0")/.."
SECONDS_PER_STATE="${1:-8}"
: "${DEVELOPER_DIR:=/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR

if [ "${NO_BUILD:-0}" != "1" ]; then scripts/bundle.sh >/dev/null || { echo "build failed"; exit 2; }
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/apnum-perf.XXXXXX")"
APP="$WORK/Apnum.app"
cp -R build/Apnum.app "$APP"
PIDS=""
cleanup() {
  for p in $PIDS; do kill "$p" 2>/dev/null; done
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

# Budgets: the ```budgets block in docs/performance.md (name value), so the doc and the check never drift.
budget() { awk -v k="$1" '/^```budgets/{on=1;next} /^```/{on=0} on && $1==k {print $2}' docs/performance.md; }

cpu_ticks() {  # cumulative CPU seconds of a pid (user+system), from ps "cputime" (M:SS.xx or H:MM:SS.xx)
  ps -o cputime= -p "$1" 2>/dev/null | awk '{n=split($1,a,":"); s=0; for(i=1;i<=n;i++) s=s*60+a[i]; print s}'
}
footprint_mb() {  # physical footprint in MB
  footprint -p "$1" 2>/dev/null | grep -o 'Footprint: [0-9.]* [KMG]B' | head -1 \
    | awk '{ v=$2; if ($3=="KB") v/=1024; else if ($3=="GB") v*=1024; printf "%.1f", v }'
}

RESULTS=()   # name|cpu|mem|updates
FAIL=0

# measure <name> <section> <extra env words...>; runs one copy for the duration and records CPU %, memory, updates/s.
measure() {
  local name="$1" section="$2"; shift 2
  local home="$WORK/home-$name" log="$WORK/$name.log"
  mkdir -p "$home"
  : > "$log"
  local extra=()
  for kv in "$@"; do extra+=(--env "$kv"); done
  open -g -n "$APP" --stderr "$log" --env APNUM_DEMO=1 --env "APNUM_HOME=$home" --env "APNUM_SECTION=$section" --env APNUM_PERF=1 "${extra[@]}"
  local pid=""
  for _ in $(seq 1 50); do
    pid="$(pgrep -f "$(basename "$WORK")/Apnum.app/Contents/MacOS/Apnum" | head -1)"
    [ -n "$pid" ] && break
    sleep 0.2
  done
  [ -z "$pid" ] && { echo "could not start $name"; FAIL=1; return; }
  PIDS="$PIDS $pid"
  sleep 12  # settle: seeding, first bake, first frames
  if [ "$name" = "hidden" ]; then
    osascript -e "tell application \"System Events\" to set visible of (first process whose unix id is $pid) to false" >/dev/null 2>&1
    sleep 2
  fi
  local c0 c1 t0 t1
  c0="$(cpu_ticks "$pid")"; t0="$(date +%s.%N 2>/dev/null || python3 -c 'import time;print(time.time())')"
  sleep "$SECONDS_PER_STATE"
  c1="$(cpu_ticks "$pid")"; t1="$(date +%s.%N 2>/dev/null || python3 -c 'import time;print(time.time())')"
  local mem cpu upd
  mem="$(footprint_mb "$pid")"
  cpu="$(awk -v a="$c0" -v b="$c1" -v s="$t0" -v e="$t1" 'BEGIN { printf "%.1f", (b-a)/(e-s)*100 }')"
  upd="-"
  if [ "$name" = "scrub" ]; then
    # Scene updates actually applied per second (median of the per-second counter lines).
    upd="$(grep -o 'applied=[0-9]*' "$log" | cut -d= -f2 | sort -n | awk '{a[NR]=$1} END {print (NR ? a[int((NR+1)/2)] : 0)}')"
  fi
  kill "$pid" 2>/dev/null
  RESULTS+=("$name|$cpu|${mem:-?}|$upd")
}

echo "Measuring ($SECONDS_PER_STATE s per state)..."
measure today-idle today APNUM_SKY_ALWAYS=1
measure today-unfocused today
measure other-idle notes
measure scrub today APNUM_SKY_ALWAYS=1 APNUM_SCRUB=1
measure hidden today

check() {  # check <name> <field: cpu|mem|upd> <limit-key> <min|max>
  local row value limit
  for row in "${RESULTS[@]}"; do
    [ "${row%%|*}" = "$1" ] || continue
    case "$2" in cpu) value="$(echo "$row" | cut -d'|' -f2)" ;; mem) value="$(echo "$row" | cut -d'|' -f3)" ;; upd) value="$(echo "$row" | cut -d'|' -f4)" ;; esac
    limit="$(budget "$3")"
    [ -z "$limit" ] && return
    if [ "$4" = "max" ] && awk -v v="$value" -v l="$limit" 'BEGIN { exit !(v+0 > l+0) }'; then
      echo "OVER BUDGET: $1 $2 = $value (max $limit)"; FAIL=1
    elif [ "$4" = "min" ] && awk -v v="$value" -v l="$limit" 'BEGIN { exit !(v+0 < l+0) }'; then
      echo "UNDER BUDGET: $1 $2 = $value (min $limit)"; FAIL=1
    fi
  done
}

echo
printf "%-16s %8s %10s %12s\n" state "CPU %" "MB" "updates/s"
for row in "${RESULTS[@]}"; do
  IFS='|' read -r n c m u <<<"$row"
  printf "%-16s %8s %10s %12s\n" "$n" "$c" "$m" "$u"
done
echo

check today-idle cpu today_idle_cpu max
check today-unfocused cpu today_unfocused_cpu max
check other-idle cpu other_idle_cpu max
check scrub cpu scrub_cpu max
check scrub upd scrub_updates_per_second min
check hidden cpu hidden_cpu max
for n in today-idle other-idle scrub; do check "$n" mem memory_mb max; done

if [ "$FAIL" = 0 ]; then echo "All budgets met."; else echo "Budgets exceeded (see docs/performance.md)."; fi
exit "$FAIL"
