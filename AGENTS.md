# Agents

## Test in the VM

Anything that moves windows, presses keys or records the screen runs in the Tart VM, not on this Mac. Build here, run there:

```sh
./scripts/build-app.sh && ./scripts/build-fixture.sh
./scripts/vm.sh up
./scripts/vm.sh run 'MIN_IDLE=0 ./scripts/live-test.sh'
./scripts/vm.sh shot        # then look at /tmp/planets-vm/shot.png
./scripts/vm.sh down
```

The VM sees the project through a read-only share that keeps a folder deleted and made again as it was, and the build scripts do exactly that. After rebuilding, run `./scripts/vm.sh down && ./scripts/vm.sh up` before testing, or the VM runs the old build or finds an empty bundle.

The VM keeps macOS's default settings on purpose, so don't change them to match this Mac. Run `./scripts/vm.sh reset` after anything that changes them. `./scripts/vm.sh` with no arguments lists the rest. Drive apps there with `build/input` (keys, clicks, drags), not AppleScript's System Events: it waits on a permission prompt nobody sees.

`./scripts/flicker-test.sh` records workspace switches frame by frame and counts the frames where the desktop shows through or both workspaces show at once; run it in the VM or, on this Mac, through `./scripts/when-idle.sh`. `./scripts/fullscreen-input-test.sh` times how soon a full-screen window takes keys again after its workspace's key.

`./scripts/switch-bench.sh` times workspace switches with a quick app and a slow one; given another build's app, CLI and environment prefix, it times that one the same way, for comparing two builds in the VM. Timings that should mean something on a real display need real hardware: they run on this Mac, only once the user has been idle. `./scripts/bench-cycle.sh` is one, ⌘` from key press to pixels against a throwaway Chromium browser.
