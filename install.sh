#!/bin/sh
set -eu

repo=vibeslop/Planets

pick_release='
ObjC.import("Foundation");
function run() {
    const input = $.NSFileHandle.fileHandleWithStandardInput.readDataToEndOfFile;
    const text = $.NSString.alloc.initWithDataEncoding(input, $.NSUTF8StringEncoding).js;
    for (const release of JSON.parse(text)) {
        if (release.draft || release.prerelease) continue;
        const name = `Planets-${release.tag_name.replace(/^v/, "")}-macos.zip`;
        const asset = release.assets.find((asset) => asset.name === name);
        if (asset) return `${release.tag_name} ${asset.browser_download_url}`;
    }
    return "";
}'

work=
staged=
previous=
target=

fail() {
    printf 'Planets: %s\n' "$1" >&2
    exit 1
}

certificate() {
    rm -f "$work/certificate0"
    codesign -d --extract-certificates="$work/certificate" "$1" 2>/dev/null || return 0
    [ -s "$work/certificate0" ] || return 0
    shasum -a 1 <"$work/certificate0" | cut -c1-40
}

cleanup() {
    # SAFETY: Restore previous bundle if interrupted between renames.
    if [ -n "$previous" ] && [ -e "$previous" ] && [ ! -e "$target/Planets.app" ]; then
        if ! mv "$previous" "$target/Planets.app"; then
            printf 'Planets: the previous copy is at %s\n' "$previous" >&2
            previous=
        fi
    fi
    [ -z "$previous" ] || rm -rf "$previous"
    [ -z "$staged" ] || rm -rf "$staged"
    [ -z "$work" ] || rm -rf "$work"
}

link_cli() {
    helper=$1/Contents/Helpers/planet
    for dir in /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin"; do
        case ":$PATH:" in *":$dir:"*) ;; *) continue ;; esac
        [ -d "$dir" ] && [ -w "$dir" ] || continue
        if [ -e "$dir/planet" ] && [ ! -L "$dir/planet" ]; then
            printf 'Left %s/planet alone: it is not a link to Planets.\n' "$dir"
            return
        fi
        ln -sfn "$helper" "$dir/planet" && printf 'Linked %s/planet, the command-line tool.\n' "$dir" && return
    done
    printf '%s\n' "To use the planet command, link it into a folder on your PATH:" \
        "  sudo ln -s \"$helper\" /usr/local/bin/planet"
}

main() {
    [ "$(uname -m)" = arm64 ] || fail "Planets runs on Macs with Apple silicon only; this one has an Intel processor."
    macos=$(sw_vers -productVersion)
    if [ "${macos%%.*}" -lt 26 ]; then
        fail "Planets needs macOS 26 or later; this Mac runs macOS $macos."
    fi

    releases=$(curl -fsSL "https://api.github.com/repos/$repo/releases?per_page=30") ||
        fail "could not get the list of releases from GitHub."
    release=$(printf '%s' "$releases" | osascript -l JavaScript -e "$pick_release") ||
        fail "could not read the list of releases from GitHub."
    [ -n "$release" ] || fail "no release has a macOS download yet."
    tag=${release%% *}
    url=${release#* }
    version=${tag#v}

    work=$(mktemp -d)
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    printf 'Downloading Planets %s\n' "$version"
    curl -fL --progress-bar -o "$work/Planets.zip" "$url" || fail "could not download $url."
    ditto -x -k "$work/Planets.zip" "$work" || fail "the download is not a readable archive."
    [ -d "$work/Planets.app" ] || fail "the download holds no Planets.app."
    codesign --verify --deep --strict "$work/Planets.app" ||
        fail "the downloaded Planets.app fails its signature check; nothing was changed."
    new_certificate=$(certificate "$work/Planets.app")
    [ -n "$new_certificate" ] ||
        fail "the downloaded Planets.app is not signed with a certificate; nothing was changed."

    if [ -d /Applications/Planets.app ]; then
        target=/Applications
    elif [ -d "$HOME/Applications/Planets.app" ] || [ ! -w /Applications ]; then
        target=$HOME/Applications
        mkdir -p "$target"
    else
        target=/Applications
    fi
    [ -w "$target" ] ||
        fail "this account cannot replace $target/Planets.app; run the command as an administrator."

    staged=$target/.Planets.app.new
    previous=$target/.Planets.app.old
    if [ -e "$previous" ] && [ ! -e "$target/Planets.app" ]; then
        mv "$previous" "$target/Planets.app"
    fi
    rm -rf "$staged" "$previous"
    ditto "$work/Planets.app" "$staged" || fail "could not copy Planets.app into $target."

    account=$(id -u)
    if pkill -x -U "$account" Planets; then
        tries=0
        while pgrep -x -U "$account" Planets >/dev/null; do
            tries=$((tries + 1))
            [ "$tries" -le 50 ] || fail "the running Planets did not quit."
            sleep 0.1
        done
    fi

    updating=false
    old_certificate=
    if [ -e "$target/Planets.app" ]; then
        updating=true
        old_certificate=$(certificate "$target/Planets.app")
        mv "$target/Planets.app" "$previous"
    fi
    mv "$staged" "$target/Planets.app"
    staged=
    rm -rf "$previous"
    previous=
    open "$target/Planets.app"
    link_cli "$target/Planets.app"

    if $updating; then
        printf 'Updated Planets in %s to %s.\n' "$target" "$version"
        if [ "$old_certificate" != "$new_certificate" ]; then
            printf '%s\n' \
                "The new copy is signed with another certificate than the one it replaced, so" \
                "macOS asks for Accessibility again."
        fi
        return
    fi
    printf 'Installed Planets %s in %s. It runs from the menu bar.\n\n' "$version" "$target"
    printf '%s\n' "Planets now asks for Accessibility, which macOS requires to arrange windows."
}

main
