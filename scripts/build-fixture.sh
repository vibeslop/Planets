#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
APP=build/Fixture.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -target arm64-apple-macos26.0 -o "$APP/Contents/MacOS/Fixture" Tools/Fixture/main.swift
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Fixture</string>
<key>CFBundleIdentifier</key><string>dev.levelorbit.planets.fixture</string>
<key>CFBundleName</key><string>Fixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
swiftc -O -target arm64-apple-macos26.0 -o build/fixture-ctl Tools/FixtureControl/main.swift
swiftc -O -target arm64-apple-macos26.0 -o build/bench Tools/Bench/main.swift
swiftc -O -target arm64-apple-macos26.0 -o build/flicker Tools/Flicker/main.swift
swiftc -O -target arm64-apple-macos26.0 -o build/backdrop Tools/Backdrop/main.swift
swiftc -O -target arm64-apple-macos26.0 -o build/ticker Tools/Ticker/main.swift
swiftc -O -target arm64-apple-macos26.0 -o build/input Tools/Input/main.swift
echo "Built $APP, build/fixture-ctl, build/bench, build/flicker, build/backdrop, build/ticker and build/input"
