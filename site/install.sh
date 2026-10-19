#!/bin/bash
# Beam installer — https://prasad-kumkar.github.io/beam-cast/
#
#   curl -fsSL https://prasad-kumkar.github.io/beam-cast/install.sh | bash
#
# Downloads the latest Beam release from GitHub, installs it to /Applications
# and opens it. Re-run it any time to update. To remove Beam:
#
#   curl -fsSL https://prasad-kumkar.github.io/beam-cast/install.sh | bash -s -- --uninstall
#
# Add --purge to also delete Beam's settings (resume positions, last TV, subtitle style).
#
# Set BEAM_INSTALL_DIR to install somewhere other than /Applications.
set -euo pipefail

REPO="prasad-kumkar/beam-cast"
INSTALL_DIR="${BEAM_INSTALL_DIR:-/Applications}"
APP="$INSTALL_DIR/Beam.app"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
fail() { printf '\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }

# Use sudo only when the install folder isn't writable by this user.
as_needed() {
    if [[ -w "$INSTALL_DIR" ]]; then "$@"; else sudo "$@"; fi
}

[[ "$(uname -s)" == "Darwin" ]] || fail "Beam is a macOS app."
macos_major="$(sw_vers -productVersion | cut -d. -f1)"
(( macos_major >= 13 )) || fail "Beam needs macOS 13 or later (you have $(sw_vers -productVersion))."

if [[ "${1:-}" == "--uninstall" ]]; then
    osascript -e 'quit app "Beam"' >/dev/null 2>&1 || true
    if [[ -d "$APP" ]]; then as_needed rm -rf "$APP"; fi
    rm -rf "$HOME/Library/Caches/Beam"
    if [[ "${2:-}" == "--purge" ]]; then
        defaults delete com.prasad.beam >/dev/null 2>&1 || true
        bold "Beam and its settings have been removed."
    else
        bold "Beam has been removed. Your settings were kept; add --purge to delete them too."
    fi
    exit 0
fi

bold "Finding the latest Beam release…"
release_json="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest")" \
    || fail "Couldn't reach GitHub. Check your internet connection."
dmg_url="$(printf '%s' "$release_json" | grep -o '"browser_download_url": *"[^"]*\.dmg"' | head -1 | sed 's/.*"\(https[^"]*\)"/\1/')"
version="$(printf '%s' "$release_json" | grep -o '"tag_name": *"[^"]*"' | head -1 | sed 's/.*"v\{0,1\}\([^"]*\)"/\1/')"
[[ -n "$dmg_url" ]] || fail "No disk image found in the latest release."

workdir="$(mktemp -d)"
mountpoint=""
cleanup() {
    [[ -n "$mountpoint" ]] && hdiutil detach -quiet "$mountpoint" 2>/dev/null || true
    rm -rf "$workdir"
}
trap cleanup EXIT

bold "Downloading Beam $version…"
curl -fL --progress-bar -o "$workdir/Beam.dmg" "$dmg_url" || fail "Download failed."

mountpoint="$workdir/mount"
mkdir -p "$mountpoint"
hdiutil attach -nobrowse -readonly -quiet -mountpoint "$mountpoint" "$workdir/Beam.dmg" \
    || fail "Couldn't open the disk image."
[[ -d "$mountpoint/Beam.app" ]] || fail "The disk image doesn't contain Beam.app."

bold "Installing to $INSTALL_DIR…"
osascript -e 'quit app "Beam"' >/dev/null 2>&1 || true
mkdir -p "$INSTALL_DIR" 2>/dev/null || as_needed mkdir -p "$INSTALL_DIR"
as_needed rm -rf "$APP"
as_needed ditto "$mountpoint/Beam.app" "$APP"
# Downloads made with curl aren't quarantined, but clear the flag in case an
# older copy was installed from a browser download.
as_needed xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

installed="$(defaults read "$APP/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "$version")"
bold "Beam $installed is installed."
if ! command -v ffmpeg >/dev/null 2>&1 && [[ ! -x /opt/homebrew/bin/ffmpeg && ! -x /usr/local/bin/ffmpeg ]]; then
    echo "Tip: 'brew install ffmpeg' adds poster frames, embedded subtitles and audio track switching."
fi
[[ -n "${BEAM_NO_OPEN:-}" ]] || open "$APP"
