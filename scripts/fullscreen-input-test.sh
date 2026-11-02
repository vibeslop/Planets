#!/bin/zsh
# Measures how soon a full-screen window takes input again when you go back to it. A
# Fixture window stands in for a full-screen app on workspace 4: the only window of its app,
# raised to the screen saver's level, its main thread busy BUSY ms a frame like a game's or
# a video player's. Another Fixture holds workspace 1. Each round goes to workspace 1, then
# back to 4 while F13 is pressed every 30 ms; the full-screen Fixture logs every press it
# gets and how late. The same trip by Mission Control's ⌃→ alone, with Planets stopped,
# is the floor: what macOS itself takes.
#
# AX_DELAY=30 makes the full-screen Fixture spend that many milliseconds of its main
# thread on every Accessibility question, as an app slow to answer them does; every
# question Planets asks it on the way back then holds up its input that long.
#
# For the VM: scripts/vm.sh run 'AX_DELAY=30 ./scripts/fullscreen-input-test.sh'
set -u
cd "$(dirname "$0")/.."
OUT=${OUT:-/tmp/planets-fullscreen}
BUSY=${BUSY:-8}
AX_DELAY=${AX_DELAY:-0}
ROUNDS=${ROUNDS:-3}
rm -rf "$OUT"; mkdir -p "$OUT/support"
export PLANETS_SOCKET="$OUT/planet.sock" PLANETS_CONFIG="$OUT/config.toml" PLANETS_SUPPORT="$OUT/support"
printf '[general]\nmod = "hyper"\nonly = ["dev.levelorbit.planets.fixture"]\n[appearance]\nworkspace_hud = false\n' > "$PLANETS_CONFIG"
cleanup() {
  pkill -f "build/Planets.app/Contents/MacOS/Planets" 2>/dev/null
  pkill -f "build/Fixture.app/Contents/MacOS/Fixture" 2>/dev/null
}
trap cleanup EXIT
T=./build/planet
start_wm() {
  PLANETS_DEBUG=1 ./build/Planets.app/Contents/MacOS/Planets >> "$OUT/app.log" 2>&1 &
  sleep 2.5
}
start_wm
$T workspace 1 >/dev/null; sleep 0.3
open --env FIXTURE_WINDOWS=1 --env FIXTURE_INPUT_LOG="$OUT/desktop.log" -n build/Fixture.app; sleep 1.5
$T workspace 4 >/dev/null; sleep 0.3
open --env FIXTURE_WINDOWS=1 --env FIXTURE_COLOR_OFFSET=2 --env FIXTURE_FULLSCREEN_LEVEL=1000 --env FIXTURE_BUSY=$BUSY --env FIXTURE_AX_DELAY=$AX_DELAY --env FIXTURE_INPUT_LOG="$OUT/fullscreen.log" -n build/Fixture.app; sleep 1.5
FULL=$(pgrep -nf "build/Fixture.app/Contents/MacOS/Fixture")
./build/fixture-ctl fullscreen $FULL; sleep 2.5
$T query windows

for i in $(seq 1 $ROUNDS); do
  $T workspace 1 >/dev/null; sleep 2.5
  echo "== planets $i" >> "$OUT/fullscreen.log"
  echo "== planets $i" >> "$OUT/ticks.txt"
  ./build/ticker --every 0.03 --for 3 -- $T workspace 4 >> "$OUT/ticks.txt"; sleep 1
done
screencapture -x "$OUT/arrived.png"

# The window in front must still be found when it leaves full screen, and go back to its tile.
fs() { $T query windows --json | python3 -c "import json,sys; print(sum(1 for w in json.load(sys.stdin) if w['workspace'] == '4' and w['full-screen'] == $1))"; }
./build/fixture-ctl fullscreen $FULL; sleep 3
[[ $(fs False) == 1 && $(fs True) == 0 ]] && echo "ok   leaving full screen puts it back in its tile" || { echo "FAIL leaving full screen"; $T query windows; }
./build/fixture-ctl fullscreen $FULL; sleep 3
[[ $(fs True) == 1 && $(fs False) == 0 ]] && echo "ok   going full screen again keeps it on workspace 4" || { echo "FAIL going full screen again"; $T query windows; }

# The floor: Planets stopped, the Spaces changed by the shortcut alone.
pkill -f "build/Planets.app/Contents/MacOS/Planets"; sleep 1.5
for i in $(seq 1 $ROUNDS); do
  ./build/ticker --for 0 -- ctrl-left >/dev/null; sleep 2.5
  echo "== macos $i" >> "$OUT/fullscreen.log"
  echo "== macos $i" >> "$OUT/ticks.txt"
  ./build/ticker --every 0.03 --for 3 -- ctrl-right >> "$OUT/ticks.txt"; sleep 1
done

python3 - "$OUT" <<'PY'
import sys, re
out = sys.argv[1]
def rounds(path):
    result, name = {}, None
    for line in open(path):
        if line.startswith("== "):
            name = line[3:].strip(); result[name] = []
        elif name:
            result[name].append(line.split())
    return result
ticks, got = rounds(f"{out}/ticks.txt"), rounds(f"{out}/fullscreen.log")
# Late presses are listed as when they were made, from the start of the round, and how late.
print(f"{'round':<14}{'first press in':>15}{'worst wait':>12}{'late > 50 ms':>14}{'presses got':>13}  late presses (ms in + ms late)")
for name, lines in ticks.items():
    start = float(lines[0][1]); presses = [float(l[1]) for l in lines[1:]]
    keys = [(float(l[4]), float(l[6])) for l in got.get(name, []) if len(l) > 6 and l[1] == "key"]
    if not keys:
        print(f"{name:<14}{'never':>15}"); continue
    first = min(made for made, late in keys) - start
    worst = max(late for made, late in keys)
    slow = [f"{(made - start) * 1000:.0f}+{late:.0f}" for made, late in keys if late > 50]
    print(f"{name:<14}{first*1000:>12.0f} ms{worst:>9.0f} ms{len(slow):>14}{len(keys):>7}/{len(presses)}  {' '.join(slow)}")
PY
