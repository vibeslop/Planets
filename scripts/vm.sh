#!/bin/zsh
set -u
cd "$(dirname "$0")/.."
VM=${PLANETS_VM:-dev}
IMAGE=ghcr.io/cirruslabs/macos-golden-gate-base@sha256:5302a9ea6cd68c059d00fa253fe75c8ebdf4e0dc8c45d4e136ecc6e7a4c02b70
OUT=/tmp/planets-vm
SHARE="/Volumes/My Shared Files"

guest() { tart exec "$VM" "$@"; }
ready() { guest test -d "$SHARE/planets" 2>/dev/null; }

start_vm() {
  mkdir -p "$OUT"
  tart stop "$VM" >/dev/null 2>&1
  nohup tart run --no-graphics --no-audio --dir="planets:${PWD}:ro" --dir="out:${OUT}" "$VM" \
    > "$OUT/tart.log" 2>&1 &!
  for i in {1..90}; do ready && break; sleep 2; done
  ready || { echo "$VM didn't answer within 3 minutes; see $OUT/tart.log"; exit 1; }
  guest /bin/zsh -c 'screencapture -x /tmp/warmup.png; sleep 2; killall UserNotificationCenter; rm /tmp/warmup.png' 2>/dev/null
}

build_signature() {
  local root=$1
  local rel files=(
    build/Planets.app/Contents/MacOS/Planets
    build/planet
    build/Fixture.app/Contents/MacOS/Fixture
  )
  local out=""
  for rel in "${files[@]}"; do
    if [[ -f "$root/$rel" ]]; then
      out+="$(shasum -a 256 "$root/$rel" | awk '{print $1}') $rel"$'\n'
    else
      out+="missing $rel"$'\n'
    fi
  done
  printf '%s' "$out"
}

sync_build() {
  local host_sig guest_sig
  host_sig=$(build_signature "$PWD")
  guest_sig=$(guest /bin/zsh -c '
    root="$1"
    for rel in build/Planets.app/Contents/MacOS/Planets build/planet build/Fixture.app/Contents/MacOS/Fixture; do
      if [[ -f "$root/$rel" ]]; then
        shasum -a 256 "$root/$rel" | awk -v r="$rel" "{print \$1, r}"
      else
        print -- "missing $rel"
      fi
    done
  ' _ "$SHARE/planets" 2>/dev/null)
  if [[ "$host_sig" != "$guest_sig" ]]; then
    echo "build changed since VM mount; restarting $VM" >&2
    start_vm
  fi
}

usage() {
  cat <<'EOF'
Usage: scripts/vm.sh <command>
  create        clone the pinned image and size the VM
  up            start the VM headless and wait until ready
  run 'cmd'     run cmd in the project folder inside the VM (restarts if build changed)
  shot [file]   capture the VM screen (default /tmp/planets-vm/shot.png)
  view          open Screen Sharing (admin / admin)
  shell         open an interactive shell in the VM
  down          stop the VM
  reset         delete and recreate the VM from the pinned image
EOF
}

case ${1:-} in
  create)
    tart clone "$IMAGE" "$VM" && tart set "$VM" --cpu 4 --memory 8192 --display 1920x1080px ;;
  up)
    mkdir -p "$OUT"
    ready && exit 0
    start_vm
    echo "$VM is up" ;;
  run)
    shift
    ready || start_vm
    sync_build
    guest /bin/zsh -lc "export PLANETS_IN_VM=1 MIN_IDLE=0 VMOUT='$SHARE/out'; cd '$SHARE/planets' && $*" ;;
  shot)
    guest screencapture -x "$SHARE/out/shot.png" || exit 1
    [[ -n ${2:-} ]] && mv "$OUT/shot.png" "$2"
    echo "${2:-$OUT/shot.png}" ;;
  view)
    open "vnc://admin:admin@$(tart ip "$VM")" ;;
  shell)
    tart exec -i -t "$VM" /bin/zsh -l ;;
  down)
    tart stop "$VM" ;;
  reset)
    tart stop "$VM" >/dev/null 2>&1; tart delete "$VM" && "$0" create && "$0" up ;;
  *)
    usage; exit 2 ;;
esac
