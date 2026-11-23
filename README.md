# Planets

Tiling window manager for macOS 26+ on Apple silicon.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/vibeslop/Planets/main/install.sh | sh
```

Installs to `/Applications`, symlinks `planet` onto `PATH`, and launches in the menu bar. Requires Accessibility permission. Not notarized (curl avoids browser quarantine).

Checks for updates daily and restarts when idle for 60s, preserving layout. Set `auto_update = false` to disable. Re-run the install script to update manually.

### From source

Requires Xcode (`actool` compiles the app icon).

```sh
./scripts/build-app.sh
cp -R build/Planets.app /Applications/
ln -s /Applications/Planets.app/Contents/Helpers/planet /usr/local/bin/planet
open -a Planets
```

Run `./scripts/make-signing-cert.sh` once to create a local certificate so Accessibility permissions persist across rebuilds.

## Use

- `⌥1–9`: switch workspace
- `⌥⇧1–9`: move window to workspace
- `⌥H J K L`: move focus
- `⌥B`: open menu (lists all shortcuts)

Config: `~/.config/planets/planets.toml` (reloads on save). Run `planet config check` to validate and `planet help` for CLI commands.

## Recovery

Hidden workspace windows park off-screen and restore on quit.

- **Crash**: auto-restarts and restores layout (disabled if it crashes within 15s of launch. Reopen and choose **Quit Planets** to restore windows).
- **Accessibility revoked**: pauses until re-enabled, then resumes automatically.
- **Force quit**: reopen Planets, then choose **Quit Planets** from the menu.

## License

[MIT](LICENSE). See [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).
