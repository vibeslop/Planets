#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")/.."
keychain="$HOME/Library/Keychains/login.keychain-db"
pin_file=scripts/release-certificate.sha1
environment=release
openssl=/usr/bin/openssl

fail() {
    print -u2 -- "$1"
    exit 1
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# SAFETY: Exit traps must run on signals so temporary private keys are deleted.
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

make_certificate() {
    cat >"$work/cert.cnf" <<CONF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $1
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CONF
    $openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -config "$work/cert.cnf" \
        -keyout "$work/key.pem" -out "$work/cert.pem" 2>"$work/openssl.log" ||
        fail "openssl could not create the certificate: $(<"$work/openssl.log")"
}

export_p12() {
    $openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" -name "$2" \
        -passout env:PLANETS_P12_PASSWORD -out "$1" 2>"$work/openssl.log" ||
        fail "openssl could not write $1: $(<"$work/openssl.log")"
}

fingerprint() {
    $openssl x509 -in "$1" -outform DER | shasum -a 1 | awk '{ print toupper($1) }'
}

identities=$(security find-identity -p codesigning "$keychain")
trusted=$(security find-identity -v -p codesigning "$keychain")

trust() {
    security add-trusted-cert -p codeSign -k "$keychain" "$work/cert.pem"
}

case "${1:-}" in
    "")
        if [[ "$trusted" == *'"Planets Code Signing"'* ]]; then
            print -- "Your 'Planets Code Signing' certificate is already in the login keychain."
            exit 0
        elif [[ "$identities" == *'"Planets Code Signing"'* ]]; then
            fail "Your 'Planets Code Signing' certificate is not trusted for code signing, so builds
pass it over. Delete it in Keychain Access and run this again."
        fi
        make_certificate "Planets Code Signing"
        password=$($openssl rand -hex 16)
        export PLANETS_P12_PASSWORD=$password
        export_p12 "$work/personal.p12" "Planets Code Signing"
        security import "$work/personal.p12" -k "$keychain" -f pkcs12 -P "$password" \
            -T /usr/bin/codesign >/dev/null
        trust
        print -- "Created your 'Planets Code Signing' certificate. scripts/build-app.sh signs with"
        print -- "it, so macOS keeps Planets's Accessibility permission across your builds. If a build asks"
        print -- "whether codesign may use the key, choose Always Allow."
        ;;

    --release)
        if [[ -f "$pin_file" ]]; then
            fail "$pin_file already pins the release certificate, and its backup is in
vibeslop/release-signing. A new one would make every user grant Accessibility again."
        fi
        backup=$HOME/Planets-Release-Certificate.p12
        [[ ! -e "$backup" ]] || fail "$backup already exists; move it away first."
        command -v gh >/dev/null || fail "The GitHub CLI stores the certificate: brew install gh"
        repo=${PLANETS_REPO:-vibeslop/Planets}
        gh api "repos/$repo" >/dev/null 2>&1 ||
            fail "gh cannot see $repo; sign in with gh auth login."
        gh api "repos/$repo/environments/$environment" >/dev/null 2>&1 ||
            fail "$repo has no '$environment' environment for the certificate to go to."

        print -- "The backup at $backup is encrypted with a password; it protects the private key."
        read -rs "password?Backup password: "
        print
        read -rs "again?Backup password again: "
        print
        [[ -n "$password" ]] || fail "The password is empty."
        [[ "$password" == "$again" ]] || fail "The passwords differ."
        export PLANETS_P12_PASSWORD=$password

        make_certificate "Planets Release"
        export_p12 "$backup" "Planets Release"
        chmod 600 "$backup"
        release=$(fingerprint "$work/cert.pem")
        print -- "$release" >"$pin_file"
        print -- ""
        print -- "Created the release certificate $release."
        print -- "  $pin_file pins it: commit that file."
        if base64 -i "$backup" |
            gh secret set MACOS_RELEASE_CERTIFICATE --env "$environment" --repo "$repo" &&
            print -rn -- "$password" |
            gh secret set MACOS_RELEASE_CERTIFICATE_PASSWORD --env "$environment" --repo "$repo"
        then
            print -- "  The '$environment' environment of $repo holds it for the release workflow."
        else
            print -- "  It did not reach the '$environment' environment. Store it by hand:"
            print -- "    base64 -i $backup | gh secret set MACOS_RELEASE_CERTIFICATE --env $environment"
            print -- "    gh secret set MACOS_RELEASE_CERTIFICATE_PASSWORD --env $environment"
        fi
        print -- "  $backup is its backup: store it and its password in"
        print -- "  vibeslop/release-signing as its README says, then delete it here."
        ;;

    --import)
        backup=${2:-}
        [[ -f "$backup" ]] || fail "Usage: $0 --import <backup.p12>"
        [[ -f "$pin_file" ]] || fail "$pin_file pins no release certificate yet."
        release=$(<"$pin_file")
        if [[ "$trusted" == *"$release"* ]]; then
            print -- "The release certificate is already in the login keychain."
            exit 0
        elif [[ "$identities" == *"$release"* ]]; then
            fail "The release certificate is in the login keychain but not trusted for code signing.
Delete it in Keychain Access and run this again."
        fi
        read -rs "password?Password of $backup: "
        print
        export PLANETS_P12_PASSWORD=$password
        $openssl pkcs12 -in "$backup" -clcerts -nokeys -passin env:PLANETS_P12_PASSWORD \
            -out "$work/cert.pem" 2>"$work/openssl.log" ||
            fail "Could not open $backup; is the password right? $(<"$work/openssl.log")"
        found=$(fingerprint "$work/cert.pem")
        [[ "$found" == "$release" ]] ||
            fail "$backup holds certificate $found, not the release certificate $release."
        security import "$backup" -k "$keychain" -f pkcs12 -P "$password" -T /usr/bin/codesign \
            >/dev/null
        trust
        print -- "The release certificate is in the login keychain; scripts/build-app.sh and"
        print -- "scripts/package.sh sign with it."
        ;;

    *)
        fail "Usage: $0 [--release | --import <backup.p12>]"
        ;;
esac
