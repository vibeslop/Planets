#!/bin/zsh
# Runs Planets in a macOS 27 virtual machine, so live tests, screen captures and
# synthetic key presses move the VM's windows instead of yours. Tart (tart.run) runs the
# VM. Builds stay on this Mac, and the VM sees the project read-only. Its display is
# 1920x1080 at 1x.
#
#   scripts/vm.sh create        download the image (34 GB, about 41 GB on disk) and size the VM
#   scripts/vm.sh up            start it without a window and wait until it answers
#   scripts/vm.sh run 'cmd'     run cmd in the project folder inside the VM
#   scripts/vm.sh shot [file]   save the VM's screen here (default /tmp/planets-vm/shot.png)
#   scripts/vm.sh view          watch and use the VM in Screen Sharing (admin / admin)
#   scripts/vm.sh shell         open a shell inside the VM
#   scripts/vm.sh down          shut it down
#   scripts/vm.sh reset         throw the VM away and start again from the untouched image
#
# The VM keeps macOS's default settings, the Mac a new user has, so it shows what your own
# setup hides. Reset it after a test that changes settings.
#
# Nobody else uses the VM's keyboard, so the scripts' idle guards can be skipped:
#   scripts/vm.sh run 'MIN_IDLE=0 ./scripts/live-test.sh'
# The project is read-only in there; $VMOUT inside the VM is /tmp/planets-vm here, the way
# to bring results back: scripts/vm.sh run 'cp -R /tmp/planets-live "$VMOUT"'
set -u
cd "$(dirname "$0")/.."
VM=${PLANETS_VM:-planets}
# Pinned to the build already downloaded, so a reset copies it locally instead of fetching a
# newer :latest. Moving to a newer macOS means changing this and downloading again.
IMAGE=ghcr.io/cirruslabs/macos-golden-gate-base@sha256:5302a9ea6cd68c059d00fa253fe75c8ebdf4e0dc8c45d4e136ecc6e7a4c02b70
OUT=/tmp/planets-vm
SHARE="/Volumes/My Shared Files"

# The guest agent (`tart exec`) runs in the logged-in session, and the image grants it
# Accessibility, Screen Recording and event posting, so GUI tests work without SSH.
guest() { tart exec "$VM" "$@"; }
ready() { guest test -d "$SHARE/planets" 2>/dev/null; }

case ${1:-} in
  create)
    tart clone "$IMAGE" "$VM" && tart set "$VM" --cpu 4 --memory 8192 --display 1920x1080px ;;
  up)
    mkdir -p "$OUT"
    ready && exit 0
    nohup tart run --no-graphics --no-audio --dir="planets:${PWD}:ro" --dir="out:${OUT}" "$VM" \
      > "$OUT/tart.log" 2>&1 &!
    for i in {1..90}; do ready && break; sleep 2; done
    ready || { echo "$VM didn't answer within 3 minutes; see $OUT/tart.log"; exit 1; }
    # macOS asks every 30 days before a program records the screen without the window
    # picker, in a dialog that would sit in front of every test (and steal focus from it).
    # Seeding its record in advance doesn't stick, so set the question off now and close it.
    guest /bin/zsh -c 'screencapture -x /tmp/warmup.png; sleep 2; killall UserNotificationCenter; rm /tmp/warmup.png' 2>/dev/null
    echo "$VM is up" ;;
  run)
    shift
    guest /bin/zsh -lc "export VMOUT='$SHARE/out'; cd '$SHARE/planets' && $*" ;;
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
    awk 'NR > 1 && !/^#/ {exit} NR > 1 {sub(/^# ?/, ""); print}' "$0"; exit 2 ;;
esac
