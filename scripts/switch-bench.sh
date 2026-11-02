#!/bin/zsh
# Times workspace switches with several apps, one of them slow to answer Accessibility, for
# comparing two builds in the VM. Prints, over 40 switches, the median and 95th percentile of
#   gone:    from the decision until the last window of the old workspace was sent away,
#            which is how long any of it can still show;
#   settled: until the slowest app finished, the `workspace` pass of `query performance`.
# VM timings say how two builds compare, not what a real display shows.
#
#   scripts/switch-bench.sh                                  this build
#   scripts/switch-bench.sh build/old/Planets.app build/old/planet PLANETS   another build
#   SAMPLE=/path scripts/switch-bench.sh                     and sample the app meanwhile
#   MODE=resize scripts/switch-bench.sh                       times ⌥- and ⌥= instead, as `resize`
#   MODE=repeat scripts/switch-bench.sh                       ⌥= held down: 30 resizes a second
set -u
cd "$(dirname "$0")/.."
APP=${1:-build/Planets.app}
CLI=${2:-build/planet}
PREFIX=${3:-PLANETS}
NAME=$(basename "$APP" .app)
OUT=/tmp/switch-bench-$NAME
rm -rf "$OUT"; mkdir -p "$OUT"
export ${PREFIX}_SOCKET="$OUT/s.sock" ${PREFIX}_CONFIG="$OUT/config.toml" ${PREFIX}_SUPPORT="$OUT/support" ${PREFIX}_DEBUG=1
cat > "$OUT/config.toml" <<TOML
[general]
mod = "hyper"
only = ["dev.levelorbit.planets.fixture"]
[appearance]
workspace_hud = false
TOML
cleanup() { pkill -f "$APP/Contents/MacOS/" 2>/dev/null; pkill -f "build/Fixture.app/Contents/MacOS/Fixture" 2>/dev/null; }
trap cleanup EXIT
cleanup; sleep 0.5

"$APP/Contents/MacOS/$NAME" > "$OUT/app.log" 2>&1 &
PID=$!
sleep 2
# Two apps on each workspace: a quick one with two windows, and one that takes 25 ms of its
# main thread to answer each Accessibility request, as some real apps do.
for ws in 1 2; do
  $CLI workspace $ws >/dev/null; sleep 0.3
  open --env FIXTURE_WINDOWS=2 -n build/Fixture.app; sleep 1.5
  open --env FIXTURE_WINDOWS=1 --env FIXTURE_AX_DELAY=25 -n build/Fixture.app; sleep 2.5
done
$CLI workspace 1 >/dev/null; sleep 1
: > "$OUT/app.log"
[[ -n ${SAMPLE:-} ]] && { sample $PID 8 -mayDie -file "$SAMPLE" >/dev/null 2>&1 & }
for i in {1..${ROUNDS:-20}}; do
  if [[ ${MODE:-switch} == repeat ]]; then
    for j in {1..8}; do $CLI resize width +20 >/dev/null; sleep 0.033; done; sleep 0.6
    for j in {1..8}; do $CLI resize width -20 >/dev/null; sleep 0.033; done; sleep 0.6
  elif [[ ${MODE:-switch} == resize ]]; then
    $CLI resize width +60 >/dev/null; sleep 0.4
    $CLI resize width -60 >/dev/null; sleep 0.4
  else
    $CLI workspace 2 >/dev/null; sleep 0.4
    $CLI workspace 1 >/dev/null; sleep 0.4
  fi
done
sleep 0.5
python3 - "$OUT/app.log" "$($CLI query performance --json)" <<'PY'
import json, re, sys
log, perf = open(sys.argv[1]).read(), json.loads(sys.argv[2])
passes = perf["passes"] if isinstance(perf, dict) else perf
# The last "hiding" line of each workspace pass: when the last old window was sent away.
gone = {}
for m in re.finditer(r"pass (\d+) workspace: hiding(?: \d+)? after ([\d.]+) ms", log):
    gone[m.group(1)] = float(m.group(2))
def pct(xs, p):
    xs = sorted(xs); return xs[min(len(xs) - 1, int(p * len(xs)))] if xs else float("nan")
g = list(gone.values())
label = "resize" if __import__("os").environ.get("MODE") in ("resize", "repeat") else "workspace"
w = next((x for x in passes if x["label"] == label), {})
print(f"gone     p50 {pct(g, .5):6.1f} ms   p95 {pct(g, .95):6.1f} ms   ({len(g)} switches)")
print(f"settled  p50 {w.get('p50-ms', float('nan')):6.1f} ms   p95 {w.get('p95-ms', float('nan')):6.1f} ms   ({w.get('count', 0)} passes)")
# Passes that followed on their own: a window put back after its app moved it, or refitted.
print("others   " + ", ".join(f"{x['label']} {x['count']}" for x in passes if x["label"] != label) or "none")
PY
