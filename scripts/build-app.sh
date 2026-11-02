#!/bin/zsh
# Builds Planets.app and the planet CLI into ./build.
#
# A stable signature matters: macOS ties the Accessibility permission to the certificate,
# so an ad-hoc signed build would lose the permission on every rebuild. In order, it signs
# with SIGN_IDENTITY, the release certificate pinned in scripts/release-certificate.sha1,
# a personal "Planets Code Signing" certificate (scripts/make-signing-cert.sh creates
# either), an Apple Development identity, and ad hoc only when there is none of them.
# PLANETS_KEYCHAIN names a keychain outside the search list to take them from, as the
# release workflow does.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIGURATION=${CONFIGURATION:-release}
swift build -c "$CONFIGURATION" --product Planets
swift build -c "$CONFIGURATION" --product planet
BIN=$(swift build -c "$CONFIGURATION" --show-bin-path)

APP=build/Planets.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp "$BIN/Planets" "$APP/Contents/MacOS/Planets"
cp "$BIN/planet" "$APP/Contents/Helpers/planet"
cp "$BIN/planet" build/planet
# The icon is an Icon Composer document; actool renders it for every size and appearance.
xcrun actool Support/AppIcon.icon --compile "$APP/Contents/Resources" --platform macosx \
  --minimum-deployment-target 26.0 --app-icon AppIcon \
  --output-partial-info-plist build/icon-partial.plist >/dev/null

# The notices ship inside the bundle because the bundle is all that an install keeps.
cp LICENSE THIRD_PARTY_LICENSES.md "$APP/Contents/Resources/"

# codesign offers only certificates trusted for code signing, at least on macOS 26, so an
# untrusted one is passed over here rather than failing in codesign.
keychain=()
codesign_keychain=()
if [[ -n "${PLANETS_KEYCHAIN:-}" ]]; then
  keychain=("$PLANETS_KEYCHAIN")
  codesign_keychain=(--keychain "$PLANETS_KEYCHAIN")
fi
identities=$(security find-identity -v -p codesigning "${keychain[@]}" 2>/dev/null) || identities=
PIN=scripts/release-certificate.sha1
IDENTITY=${SIGN_IDENTITY:-}
if [[ -z "$IDENTITY" && -f "$PIN" && "$identities" == *"$(<"$PIN")"* ]]; then
  IDENTITY=$(<"$PIN")
fi
for name in "Planets Code Signing" "Apple Development" "Developer ID Application"; do
  [[ -n "$IDENTITY" ]] && break
  for line in "${(@f)identities}"; do
    if [[ "$line" == *"\"$name"* ]]; then
      # "  1) <SHA-1> "Planets Code Signing" (...)"
      IDENTITY=${${line##*\) }%% *}
      break
    fi
  done
done
if [[ -n "$IDENTITY" ]]; then
  for target in "$APP/Contents/Helpers/planet" "$APP" build/planet; do
    codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "${codesign_keychain[@]}" "$target"
  done
  echo "Signed with: $(codesign -dvv "$APP" 2>&1 | awk -F= '/^Authority=/ { print $2; exit }')"
else
  codesign --force --sign - "$APP"
  echo "No signing identity found; signed ad hoc. Run scripts/make-signing-cert.sh once to keep Accessibility across builds."
fi
echo "Built $APP"
