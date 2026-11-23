#!/bin/zsh
set -u
cd "$(dirname "$0")/.."
source scripts/guard-host.sh
require_idle_or_vm
OUT=${OUT:-/tmp/planets-flicker}
rm -rf "$OUT"; mkdir -p "$OUT/support"
./build/planet query windows > "$OUT/main-before.txt" 2>/dev/null
pkill -TERM -x Planets; for i in {1..40}; do pgrep -x Planets >/dev/null || break; sleep 0.25; done
caffeinate -d -t 120 & AWAKE=$!
./build/backdrop & BACKDROP=$!
finish() {
  [[ -n "${TEST_WM:-}" ]] && kill $TEST_WM 2>/dev/null
  pkill -f "build/Fixture.app/Contents/MacOS/Fixture"; kill $BACKDROP $AWAKE 2>/dev/null
  sleep 1
  unset PLANETS_SOCKET PLANETS_CONFIG PLANETS_SUPPORT
  open /Applications/Planets.app; sleep 6
  ./build/planet query windows > "$OUT/main-after.txt" 2>/dev/null
  cmp -s "$OUT/main-before.txt" "$OUT/main-after.txt" && echo "your Planets is back with the same layout" || echo "your Planets is back; layout differs, see $OUT/main-*.txt"
}
trap finish EXIT
sleep 0.8
export PLANETS_SOCKET="$OUT/planet.sock" PLANETS_CONFIG="$OUT/config.toml" PLANETS_SUPPORT="$OUT/support"
printf '[general]\nmod = "hyper"\nonly = ["dev.levelorbit.planets.fixture"]\n' > "$PLANETS_CONFIG"
open --env FIXTURE_WINDOWS=2 -n build/Fixture.app; sleep 1.5
PLANETS_DEBUG=1 ./build/Planets.app/Contents/MacOS/Planets > "$OUT/app.log" 2>&1 & TEST_WM=$!
sleep 3
./build/planet workspace 2; sleep 0.5
open --env FIXTURE_WINDOWS=1 --env FIXTURE_COLOR_OFFSET=2 -n build/Fixture.app; sleep 2
./build/planet workspace 1; sleep 0.8
./build/flicker 10 "$OUT" & RECORDER=$!
sleep 1.2
for i in {1..10}; do ./build/planet workspace 2; sleep 0.07; ./build/planet workspace 1; sleep 0.07; done
sleep 1.2
for i in {1..4}; do ./build/planet workspace 2; sleep 0.45; ./build/planet workspace 1; sleep 0.45; done
wait $RECORDER
