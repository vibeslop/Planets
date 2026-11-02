#!/bin/zsh
# Live test of Planets against the Fixture app, for a machine nobody is using.
#
# Runs Planets restricted to Fixture's windows (your own windows are never touched),
# drives it through `planet`, checks real window frames, and saves a few cropped captures
# to $OUT. Aborts as soon as there's keyboard or mouse input, and cleans up either way.
set -u
cd "$(dirname "$0")/.."
OUT=${OUT:-/tmp/planets-live}
MIN_IDLE=${MIN_IDLE:-90}
rm -rf "$OUT"; mkdir -p "$OUT"
export PLANETS_SOCKET="$OUT/planet.sock"
export PLANETS_CONFIG="$OUT/config.toml"
export PLANETS_SUPPORT="$OUT/support"
cat > "$PLANETS_CONFIG" <<TOML
[general]
mod = "hyper"
only = ["dev.levelorbit.planets.fixture"]
TOML

idle() { ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}'; }
cleanup() {
  pkill -f "build/Planets.app/Contents/MacOS/Planets" 2>/dev/null
  pkill -f "build/Fixture.app/Contents/MacOS/Fixture" 2>/dev/null
}
trap cleanup EXIT
START_IDLE=$(idle)
guard() {
  local now=$(idle)
  if (( now < 5 )); then echo "ABORT: input detected"; exit 3; fi
}
if (( START_IDLE < MIN_IDLE )); then echo "SKIP: idle only ${START_IDLE}s"; exit 2; fi

T=./build/planet
note() { ./build/fixture-ctl "$1"; }
pass=0; fail=0
check() { if eval "$2"; then echo "ok   $1"; pass=$((pass+1)); else echo "FAIL $1"; fail=$((fail+1)); fi }
# True once $2 holds, asked every half second for up to $1 seconds: for what settles at the
# app's pace and the VM's, not at a fixed time.
soon() { local i; for (( i = 0; i < $1 * 2; i++ )); do eval "$2" && return 0; sleep 0.5; done; return 1; }
frames() { $T query windows --json | python3 -c 'import json,sys; [print(w["title"], int(w["frame"]["x"]), int(w["frame"]["y"]), int(w["frame"]["width"]), int(w["frame"]["height"]), w["workspace"], "hidden" if w["hidden"] else "shown", "focused" if w["focused"] else "") for w in sorted(json.load(sys.stdin), key=lambda w: w["title"])]'; }
count() { $T query windows --json | python3 -c "import json,sys; print(sum(1 for w in json.load(sys.stdin) if $1))"; }

open --env FIXTURE_WINDOWS=3 -n build/Fixture.app; sleep 1.5
PLANETS_DEBUG=1 ./build/Planets.app/Contents/MacOS/Planets > "$OUT/app.log" 2>&1 &
sleep 2.5; guard
# Where tiles go: the main display's visible frame, below the menu bar and beside the Dock,
# inside the default 10-point gaps. A Dock that stays on screen makes it smaller.
read X Y W H <<< $($T query monitors --json | python3 -c 'import json,sys; f=next(m for m in json.load(sys.stdin) if m["main"])["visible-frame"]; print(int(f["x"])+10, int(f["y"])+10, int(f["width"])-20, int(f["height"])-20)')
HALF=$(( (W - 10) / 2 ))
frames > "$OUT/1-dwindle.txt"; cat "$OUT/1-dwindle.txt"
check "three windows managed" '[[ $(count "True") == 3 ]]'
check "dwindle: one window fills the left half" 'grep -qE "^Fixture [0-9]+ $X $Y $HALF $H " "$OUT/1-dwindle.txt"'
screencapture -x "$OUT/1-dwindle.png"; guard

$T workspace 2; sleep 0.4; guard
check "switching away parks every window" '[[ $(count "w[\"hidden\"]") == 3 ]]'
$T workspace 1; sleep 0.4
check "switching back shows them again" '[[ $(count "not w[\"hidden\"]") == 3 ]]'
frames > "$OUT/2-back.txt"
check "frames survive the round trip" 'diff -q <(cut -d" " -f1-6 "$OUT/1-dwindle.txt") <(cut -d" " -f1-6 "$OUT/2-back.txt") >/dev/null'
guard

$T zoom on; sleep 0.4; frames > "$OUT/3-zoom.txt"
check "zoom: the focused window fills the screen" '[[ $(grep -c " $X $Y $W $H " "$OUT/3-zoom.txt") == 1 ]]'
$T zoom off; sleep 0.4
check "and goes back to its tile" 'diff -q <(cut -d" " -f1-6 "$OUT/1-dwindle.txt") <(frames | cut -d" " -f1-6) >/dev/null'
$T toggle-split; sleep 0.4; frames > "$OUT/4-split.txt"
check "toggle-split turns the focused split" '! diff -q <(cut -d" " -f1-6 "$OUT/1-dwindle.txt") <(cut -d" " -f1-6 "$OUT/4-split.txt") >/dev/null'
$T toggle-split; sleep 0.4; guard

$T move-to-workspace 3; sleep 0.4
check "a window moved to workspace 3" '[[ $(count "w[\"workspace\"] == \"3\"") == 1 ]]'
$T workspace 3; sleep 0.3; $T move-to-workspace 1 --follow; sleep 0.4
check "and came back with --follow" '[[ $(count "w[\"workspace\"] == \"1\"") == 3 ]]'
guard

note open; sleep 0.8
check "a new window joins the layout" '[[ $(count "True") == 4 ]]'
note close; sleep 0.8
check "closing it reflows" '[[ $(count "True") == 3 ]]'
note tab; sleep 0.8
frames > "$OUT/6-tab.txt"; cat "$OUT/6-tab.txt"
check "a native tab shares its sibling's tile" '[[ $(count "True") == 3 ]]'
note close; sleep 0.8
check "closing the tab keeps three tiles" '[[ $(count "True") == 3 ]]'
guard

# Closing the front tab of three or more: macOS brings one of the others forward, and the
# group keeps its tile whichever it is. Each round adds two tabs, resizes the tile, which
# leaves the background tabs at their old size, and closes the tab in front.
tiles() { frames | cut -d" " -f3-6 | sort; }
kept=0
for round in 1 2 3 4; do
  note tab; sleep 0.5; note tab; sleep 0.8
  $T resize width $(( round % 2 ? 80 : -80 )); sleep 0.8
  LAYOUT=$(tiles)
  note close; sleep 1
  [[ $(count "True") == 3 && "$(tiles)" == "$LAYOUT" ]] && kept=$((kept + 1))
done
check "closing the front tab of a resized group keeps its tile ($kept of 4)" '[[ $kept == 4 ]]'
for extra in 1 2 3 4; do note close; sleep 0.5; done
sleep 0.5
check "and closing the rest leaves the layout as it was" '[[ $(count "True") == 3 && "$(tiles)" == "$LAYOUT" ]]'
guard

# Minimised and hidden windows stay on their workspace, listed there, and come back to their
# tile however they're brought back. Fixture 1, 2 and 3 are left, on workspace 1.
PID=$(pgrep -nf "build/Fixture.app/Contents/MacOS/Fixture")
field() { $T query windows --json | python3 -c "import json,sys; print(next((w['$2'] for w in json.load(sys.stdin) if w['title'] == 'Fixture $1'), 'gone'))"; }
focusedws() { $T query workspaces --json | python3 -c 'import json,sys; print(next(w["name"] for w in json.load(sys.stdin) if w["focused"]))'; }
tile() { frames | awk -v t="Fixture $1" '$1" "$2 == t {print $3, $4, $5, $6}'; }
$T workspace 1 >/dev/null; sleep 0.4
BEFORE=$(tile 2)
./build/fixture-ctl minimize $PID 2; sleep 1
check "a minimised window stays on its workspace" '[[ $(field 2 workspace) == 1 && $(field 2 minimized) == True ]]'
check "the other two fill its place" '[[ $(count "not w[\"minimized\"]") == 2 ]]'
$T workspace 3 >/dev/null; sleep 0.4
./build/fixture-ctl unminimize $PID 2; sleep 1.2
check "back from the Dock, it shows its workspace" '[[ $(focusedws) == 1 && $(field 2 focused) == True ]]'
check "and its tile" '[[ "$(tile 2)" == "$BEFORE" ]]'
./build/fixture-ctl minimize $PID 2; sleep 1
$T workspace 3 >/dev/null; sleep 0.4
$T restore >/dev/null; sleep 1.2
check "planet restore brings back the last one minimised, in its tile" '[[ $(focusedws) == 1 && $(field 2 minimized) == False && $(field 2 focused) == True && "$(tile 2)" == "$BEFORE" ]]'
./build/fixture-ctl minimize $PID 2; sleep 1
pkill -f "build/Planets.app/Contents/MacOS/Planets"; sleep 1.5
PLANETS_DEBUG=1 ./build/Planets.app/Contents/MacOS/Planets >> "$OUT/app.log" 2>&1 &
sleep 2.5
$T restore >/dev/null; sleep 1.2
check "and after Planets restarts too" '[[ $(field 2 minimized) == False && "$(tile 2)" == "$BEFORE" ]]'
guard
./build/fixture-ctl hideapp $PID; sleep 1
check "a hidden app's windows stay on their workspace" '[[ $(count "w[\"app-hidden\"] and w[\"workspace\"] == \"1\"") == 3 ]]'
$T workspace 2 >/dev/null; sleep 0.4
$T restore $(field 1 id) >/dev/null; sleep 1.5
check "restoring one shows the app again, on its workspace" '[[ $(count "w[\"app-hidden\"]") == 0 && $(focusedws) == 1 && $(field 1 focused) == True ]]'
guard
./build/fixture-ctl minimize $PID 3; sleep 1
$T menubar >/dev/null; sleep 0.6; screencapture -x -R1400,0,520,420 "$OUT/10-menu-away.png"; $T menubar >/dev/null; sleep 0.4
$T restore $(field 3 id) >/dev/null; sleep 1.2
check "all three are tiles again" '[[ $(count "not w[\"minimized\"] and not w[\"app-hidden\"]") == 3 ]]'
guard

$T float toggle; sleep 0.4; frames > "$OUT/7-float.txt"
$T float toggle; sleep 0.4
guard

# Last, as they press the mouse and restart Fixture. An edge dragged leftward: the windows
# beside it slide along while the button is down. Once they slid under the pointer they
# were taken for the window being dragged, and stopped there.
EDGE=$(frames | awk -v x=$X -v h=$H '$3 == x && $6 == h {print $3 + $5}')
./build/input slowdrag $((EDGE + 1)) 500 $((EDGE - 250)) 500 1500 & DRAG=$!
sleep 1.1
screencapture -x "$OUT/12-mid-drag.png"
check "the neighbours follow an edge dragged left" '(( $(frames | awk -v x=$X "\$3 != x {print \$3}" | sort -n | head -1) < EDGE - 20 ))'
wait $DRAG; sleep 1
check "and the edge stays where it was let go" '(( abs = $(frames | awk -v x=$X -v h=$H "\$3 == x && \$6 == h {print \$3 + \$5}") - (EDGE - 250), abs * abs <= 4 ))'
# An app restarting while you're on another workspace gets its windows back where they were.
BEFORE=$(frames | cut -d" " -f1-6 | sort)
$T workspace 3 >/dev/null; sleep 0.4
./build/fixture-ctl quit $PID; sleep 1.5
open --env FIXTURE_WINDOWS=3 -n build/Fixture.app; sleep 3
check "a restarted app's windows go back to their workspace" '[[ $(count "w[\"workspace\"] == \"1\"") == 3 && $(focusedws) == 3 ]]'
$T workspace 1 >/dev/null; sleep 0.8
check "and to their tiles" '[[ "$(frames | cut -d" " -f1-6 | sort)" == "$BEFORE" ]]'
# An app slow to open, opened on one workspace while the user goes on to another before its
# window shows: the window belongs where it was opened, and the user stays where they went.
# Before anything quits: every Fixture shares a bundle, and one opening right after another
# quit would be taken for it restarting.
$T workspace 2 >/dev/null; sleep 0.4
open --env FIXTURE_WINDOWS=1 --env FIXTURE_DELAY=2.5 -n build/Fixture.app
sleep 0.6; $T workspace 3 >/dev/null; sleep 4
check "a slow app's window opens where it was opened" '[[ $(count "w[\"workspace\"] == \"2\"") == 1 && $(focusedws) == 3 ]]'
$T workspace 1 >/dev/null; sleep 0.5
# An app putting back the size it saved as it opens, more than once after it's tiled: taken
# for a window that can't fit, it floated for good, as big as the screen.
open --env FIXTURE_WINDOWS=1 --env FIXTURE_RESTORE=1880x1010 -n build/Fixture.app; sleep 4
check "a window putting back its saved size still tiles" '[[ $(count "not w[\"floating\"]") == 5 ]]'
# Size limits. An app slow to resize (Chromium and Electron resize from their own loop)
# reported its old size until it got there, which was taken for a minimum and a cap: two
# windows ended up one floating, one centred in a third of its tile, zoomed and back.
$T workspace 6 >/dev/null; sleep 0.4
open --env FIXTURE_WINDOWS=2 --env FIXTURE_RESIZE_LAG=1200 -n build/Fixture.app; sleep 6
$T zoom on >/dev/null; sleep 4; $T zoom off >/dev/null; sleep 4
check "a slow resizer gets no size limits it hasn't got" '[[ $(count "w[\"workspace\"] == \"6\" and not w[\"floating\"] and int(w[\"frame\"][\"width\"]) == $HALF") == 2 ]]'
# Limits an app really has are still learned: a cap centres the window in its tile, and
# minimums too wide to sit side by side stack the windows. Learned only once a new window
# has settled (two seconds) and the window server agrees (one and a half more).
$T workspace 7 >/dev/null; sleep 0.4
open --env FIXTURE_WINDOWS=2 --env FIXTURE_MAX=800x600 -n build/Fixture.app
capped() { [[ $(count 'w["workspace"] == "7" and int(w["frame"]["width"]) == 800 and int(w["frame"]["height"]) == 600') == 2 ]]; }
check "a window that can't grow is centred at its cap" 'soon 15 capped'
$T workspace 8 >/dev/null; sleep 0.4
open --env FIXTURE_WINDOWS=2 --env FIXTURE_MIN=1100x300 -n build/Fixture.app
stacked() { [[ $(count "w[\"workspace\"] == \"8\" and not w[\"floating\"] and int(w[\"frame\"][\"width\"]) == $W") == 2 ]]; }
check "windows too wide to sit side by side stack" 'soon 15 stacked'
# A slow resizer moved into a tile narrower than its minimum reports its old width first,
# then settles at the minimum. Its first size was taken for the candidate and the second
# ignored, so the check found neither and it hung off the screen's edge for good.
$T workspace 9 >/dev/null; sleep 0.4
open --env FIXTURE_WINDOWS=1 -n build/Fixture.app; sleep 3
open --env FIXTURE_WINDOWS=1 --env FIXTURE_MIN=900x300 --env FIXTURE_RESIZE_LAG=900 -n build/Fixture.app; sleep 5
# Narrower than its minimum: half the screen less 200 points.
$T resize width -200 >/dev/null
onscreen() { [[ $(count "w[\"workspace\"] == \"9\" and int(w[\"frame\"][\"x\"] + w[\"frame\"][\"width\"]) <= $X + $W") == 2 ]]; }
check "a slow resizer's minimum is learned once it settles" 'soon 15 onscreen'
$T workspace 1 >/dev/null; sleep 0.5

for i in 1 2 3 4 5 6 7 8 9 10; do $T workspace 2 >/dev/null; $T workspace 1 >/dev/null; done; sleep 0.5
$T query performance | tee "$OUT/performance.txt"
echo "passed $pass, failed $fail"
