# Agents

## Verification

Run deterministic checks before pushing:

```sh
./scripts/check.sh
```

`scripts/lint.sh` enforces:
- No inline comments except `SAFETY:` comments (and shebangs / `swift-tools-version`).
- No AppleScript `System Events` (use `build/input` instead).
- Interactive test scripts source `scripts/guard-host.sh`.
- Shell syntax, `site/index.html` JS/assets, `Info.plist`, and `release-certificate.sha1`.

## VM Testing

Run window/input/recording tests in the Tart VM, not on this Mac:

```sh
./scripts/build-app.sh && ./scripts/build-fixture.sh
./scripts/vm.sh up
./scripts/vm.sh run './scripts/live-test.sh'
./scripts/vm.sh shot
./scripts/vm.sh down
```

- `vm.sh run` exports `PLANETS_IN_VM=1` / `MIN_IDLE=0` and auto-restarts the VM if host binaries are newer than the VirtioFS share.
- Keep macOS defaults in the VM. Run `./scripts/vm.sh reset` after any test that changes system settings.
- Drive UI with `build/input` (keys, clicks, drags).

## Test Scripts

- `./scripts/live-test.sh`: end-to-end window management suite (VM).
- `./scripts/flicker-test.sh`: frame-by-frame workspace switch flicker check (VM or idle host via `./scripts/when-idle.sh`).
- `./scripts/fullscreen-input-test.sh`: full-screen input latency after workspace switch (VM).
- `./scripts/switch-bench.sh [app cli prefix]`: workspace switch benchmark for comparing builds (VM).
- `./scripts/bench-cycle.sh`: real-hardware `⌘\`` key-to-pixel latency benchmark against Chromium (idle host only).
