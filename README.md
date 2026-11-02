# Planets

A tiling window manager for macOS 26 and later, on Macs with Apple silicon.

## Install

Paste this into Terminal:

```sh
curl -fsSL https://raw.githubusercontent.com/vibeslop/Planets/main/install.sh | sh
```

The script installs Planets in `/Applications`, links the `planet` command into a folder on your `PATH`, and starts Planets in the menu bar. Run it again to update.

Planets is not notarized, so macOS blocks a copy downloaded in a browser. The script downloads it with curl, which macOS doesn't block.

Planets asks for Accessibility, the permission macOS requires before an app can move other apps' windows.

### From source

Building needs Xcode, not only the Command Line Tools: its `actool` renders the app icon.

```sh
./scripts/build-app.sh
cp -R build/Planets.app /Applications/
ln -s /Applications/Planets.app/Contents/Helpers/planet /usr/local/bin/planet
open -a Planets
```

macOS ties the Accessibility permission to the certificate a build is signed with. `./scripts/make-signing-cert.sh` creates a certificate of your own once, so the permission survives rebuilds.

## Use

- ⌥1–9: go to a workspace. ⌥⇧1–9: send the window there.
- ⌥H J K L: move focus.
- ⌥B: open the menu, which lists every shortcut.

Settings live in `~/.config/planets/planets.toml` and apply on save. `planet config check` checks the file without applying it, and `planet help` lists every command.

## If something goes wrong

Planets hides the windows of other workspaces in a corner of the screen and puts them back when it quits.

- **If Planets crashes,** it opens again by itself and puts each window back on its workspace. If it crashes within 15 seconds of starting, it stays closed. Open it again, then choose **Quit Planets** from its menu to put every window back on screen.
- **If you turn off Accessibility while Planets runs,** it stops and can't move windows until you turn the permission back on. Then it starts again by itself.
- **If you force quit Planets,** windows stay where they are. Open it again, then quit it from its menu.

## License

Planets is licensed under the [MIT License](LICENSE). [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md) credits the projects it builds on.
