#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")/.."
pin_file=scripts/release-certificate.sha1
if [[ ! -f "$pin_file" ]]; then
  print -u2 -- "$pin_file pins no release certificate yet. Create it once with"
  print -u2 -- "  scripts/make-signing-cert.sh --release"
  exit 1
fi
release=$(<"$pin_file")
SIGN_IDENTITY= scripts/build-app.sh

app=build/Planets.app
codesign --verify --deep --strict "$app"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
codesign -d --extract-certificates="$work/certificate" "$app" 2>/dev/null || true
fingerprint=
if [[ -s "$work/certificate0" ]]; then
  fingerprint=$(shasum -a 1 <"$work/certificate0" | awk '{ print toupper($1) }')
fi
if [[ "$fingerprint" != "$release" ]]; then
  print -u2 -- "$app is not signed with the release certificate:"
  print -u2 -- "  this build  ${fingerprint:-ad hoc}"
  print -u2 -- "  releases    $release  ($pin_file)"
  print -u2 -- "A release with another certificate makes every user grant Accessibility again."
  print -u2 -- "Push the version tag to have the release workflow build it, or import the"
  print -u2 -- "certificate from its backup in vibeslop/release-signing (see its README):"
  print -u2 -- "  scripts/make-signing-cert.sh --import <backup.p12>"
  exit 1
fi

version=$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")
archive=build/Planets-$version-macos.zip
rm -f "$archive"
ditto -c -k --keepParent "$app" "$archive"
print -- "Packaged $archive for the v$version release"
shasum -a 256 "$archive"
