#!/bin/zsh
# Builds a universal (Apple silicon + Intel), ad-hoc signed "Beam.app" in outputs/.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="$PROJECT_DIR/outputs"
BUILD_DIR="$PROJECT_DIR/work/build"
APP_PATH="$OUTPUT_DIR/Beam.app"

mkdir -p "$OUTPUT_DIR" "$BUILD_DIR"
swift build -c release --build-path "$BUILD_DIR" --arch arm64 --arch x86_64

ICONSET="$BUILD_DIR/AppIcon.iconset"
if [[ ! -f "$BUILD_DIR/AppIcon.icns" || "$PROJECT_DIR/scripts/make-icon.swift" -nt "$BUILD_DIR/AppIcon.icns" ]]; then
    rm -rf "$ICONSET" && mkdir -p "$ICONSET"
    swift "$PROJECT_DIR/scripts/make-icon.swift" "$BUILD_DIR/icon-1024.png"
    for px in 16 32 128 256 512; do
        sips -z $px $px "$BUILD_DIR/icon-1024.png" --out "$ICONSET/icon_${px}x${px}.png" >/dev/null
        sips -z $((px * 2)) $((px * 2)) "$BUILD_DIR/icon-1024.png" --out "$ICONSET/icon_${px}x${px}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$BUILD_DIR/AppIcon.icns"
fi

rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BUILD_DIR/apple/Products/Release/Beam" "$APP_PATH/Contents/MacOS/Beam"
cp "$PROJECT_DIR/Sources/Beam/Info.plist" "$APP_PATH/Contents/Info.plist"
# VERSION (e.g. from a git tag "v1.2.0") overrides the version in Info.plist.
if [[ -n "${VERSION:-}" ]]; then
    plutil -replace CFBundleShortVersionString -string "${VERSION#v}" "$APP_PATH/Contents/Info.plist"
    plutil -replace CFBundleVersion -string "${BUILD_NUMBER:-${VERSION#v}}" "$APP_PATH/Contents/Info.plist"
fi
cp "$BUILD_DIR/AppIcon.icns" "$APP_PATH/Contents/Resources/AppIcon.icns"
chmod +x "$APP_PATH/Contents/MacOS/Beam"

# Ad-hoc signature with hardened runtime; set SIGN_IDENTITY to sign with a Developer ID.
SIGN_ARGS=(--force --deep --options runtime --sign "${SIGN_IDENTITY:--}")
if [[ -n "${SIGN_IDENTITY:-}" && "$SIGN_IDENTITY" != "-" ]]; then
    SIGN_ARGS+=(--timestamp)  # required for notarization
fi
codesign "${SIGN_ARGS[@]}" "$APP_PATH"
codesign --verify --strict "$APP_PATH"

echo "$APP_PATH"
