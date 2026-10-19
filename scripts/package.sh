#!/bin/zsh
# Packages outputs/Beam.app as a drag-to-install .dmg and an installer .pkg.
#
#   ./scripts/package.sh            # after ./scripts/build-app.sh
#
# Optional signing and notarization (used by the release workflow):
#   INSTALLER_SIGN_IDENTITY  "Developer ID Installer: …" to sign the .pkg
#   NOTARY_PROFILE           a `xcrun notarytool store-credentials` profile name
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="$PROJECT_DIR/outputs"
APP_PATH="$OUTPUT_DIR/Beam.app"
VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP_PATH/Contents/Info.plist")"
DMG_PATH="$OUTPUT_DIR/Beam-$VERSION.dmg"
PKG_PATH="$OUTPUT_DIR/Beam-$VERSION.pkg"

[[ -d "$APP_PATH" ]] || { echo "Build the app first: ./scripts/build-app.sh" >&2; exit 1; }

# Disk image with an Applications shortcut for drag-and-drop install.
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG_PATH"
hdiutil create -volname "Beam $VERSION" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG_PATH" >/dev/null

# Installer package that puts Beam.app in /Applications.
# Bundle relocation is turned off: otherwise Installer "upgrades" any other copy
# of Beam it finds on disk (Downloads, a build folder…) instead of /Applications.
PKG_ROOT="$STAGING/pkgroot"
mkdir -p "$PKG_ROOT"
ditto "$APP_PATH" "$PKG_ROOT/Beam.app"
pkgbuild --analyze --root "$PKG_ROOT" "$STAGING/components.plist" >/dev/null
plutil -replace 0.BundleIsRelocatable -bool NO "$STAGING/components.plist"
pkgbuild --root "$PKG_ROOT" --component-plist "$STAGING/components.plist" \
    --install-location /Applications --identifier com.prasad.beam --version "$VERSION" \
    "$STAGING/Beam-component.pkg" >/dev/null

# Wrap it in a product archive so Installer shows a normal install flow.
rm -f "$PKG_PATH"
PRODUCT_ARGS=(--package "$STAGING/Beam-component.pkg" --identifier com.prasad.beam.installer --version "$VERSION")
if [[ -n "${INSTALLER_SIGN_IDENTITY:-}" ]]; then
    PRODUCT_ARGS+=(--sign "$INSTALLER_SIGN_IDENTITY")
fi
productbuild "${PRODUCT_ARGS[@]}" "$PKG_PATH" >/dev/null

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    for artifact in "$DMG_PATH" "$PKG_PATH"; do
        xcrun notarytool submit "$artifact" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$artifact"
    done
fi

shasum -a 256 "$DMG_PATH" "$PKG_PATH" | sed "s|$OUTPUT_DIR/||" > "$OUTPUT_DIR/SHA256SUMS.txt"
echo "$DMG_PATH"
echo "$PKG_PATH"
