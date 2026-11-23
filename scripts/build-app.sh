#!/bin/zsh
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
xcrun actool Support/AppIcon.icon --compile "$APP/Contents/Resources" --platform macosx \
  --minimum-deployment-target 26.0 --app-icon AppIcon \
  --output-partial-info-plist build/icon-partial.plist >/dev/null

cp LICENSE THIRD_PARTY_LICENSES.md "$APP/Contents/Resources/"

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
