#!/bin/zsh
# Benchmarks ⌘` the way a person feels it: key press to new pixels on screen, measured by
# build/bench, against a real Chromium app (a throwaway instance of a Chromium browser with
# its own profile, so your own browsing is never touched): Google Chrome, unless CHROMIUM
# names another browser's executable. Runs on workspace 9 and only when nobody has
# used the machine for MIN_IDLE seconds.
#
#   NATIVE=1  also measures macOS's own ⌘` with Planets quit, as the baseline.
#             Planets restarts afterwards and puts every window back.
set -u
cd "$(dirname "$0")/.."
MIN_IDLE=${MIN_IDLE:-90}
TRIALS=${TRIALS:-15}
T=./build/planet
APP=/Applications/Planets.app
PROFILE=/tmp/planets-bench-chromium
CHROMIUM=${CHROMIUM:-"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"}
idle() { ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}'; }
(( $(idle) >= MIN_IDLE )) || { echo "SKIP: idle only $(idle)s"; exit 2; }

ORIG=$($T query workspaces | awk '$1 ~ /\*$/ {sub(/\*/,"",$1); print $1}')
cleanup() {
  pkill -f "user-data-dir=$PROFILE" 2>/dev/null
  sleep 1
  rm -rf "$PROFILE"
  pgrep -x Planets >/dev/null || { open "$APP"; sleep 4; }
  $T workspace "$ORIG" >/dev/null
}
trap cleanup EXIT

$T workspace 9 >/dev/null; sleep 0.5
rm -rf "$PROFILE"
"$CHROMIUM" --user-data-dir="$PROFILE" --no-first-run --no-default-browser-check --new-window about:blank >/dev/null 2>&1 &
sleep 5
"$CHROMIUM" --user-data-dir="$PROFILE" --new-window about:blank >/dev/null 2>&1 &
sleep 3
echo "workspace 9: $($T query windows | awk '$2 == "9"' | wc -l | tr -d ' ') windows"

./build/bench cmd+grave --region 0,40,1920,1040 --trials $TRIALS --gap 0.8 --label "⌘\` with Planets"

if [[ -n ${NATIVE:-} ]]; then
  pkill -TERM -x Planets
  for i in {1..40}; do pgrep -x Planets >/dev/null || break; sleep 0.25; done
  sleep 1
  ./build/bench cmd+grave --region 0,40,1920,1040 --trials $TRIALS --gap 0.8 --label "⌘\` native macOS"
  open "$APP"; sleep 5
fi
