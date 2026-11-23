#!/bin/zsh
set -u
cd "$(dirname "$0")/.."
source scripts/guard-host.sh
require_idle
TRIALS=${TRIALS:-15}
T=./build/planet
APP=/Applications/Planets.app
PROFILE=/tmp/planets-bench-chromium
CHROMIUM=${CHROMIUM:-"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"}

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
