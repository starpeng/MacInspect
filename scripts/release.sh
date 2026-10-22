#!/bin/bash
# MacInspect release: Release build → arch check → sign → DMG → notarize → staple.
#
# Usage:
#   ./scripts/release.sh                # default: universal (arm64 + x86_64)
#   ./scripts/release.sh intel          # Intel / x86_64 only
#   ./scripts/release.sh apple-silicon  # Apple Silicon / arm64 only
#   ./scripts/release.sh universal      # arm64 + x86_64
#
# Outputs (under repo-root artifacts/, gitignored):
#   artifacts/build/release-<arch>/     Release DerivedData
#   ${MACINSPECT_OUTPUT_DIR:-artifacts/dist}/MacInspect-<version>-<arch>.dmg
#   e.g. artifacts/dist/MacInspect-1.0-universal.dmg
#
# One-time setup for public distribution:
#   1. Paid Apple Developer account
#   2. Developer ID Application certificate in Keychain
#   3. Store notarytool credentials:
#        xcrun notarytool store-credentials "macinspect-notary" \
#          --apple-id "you@example.com" \
#          --team-id "TEAMID10CH" \
#          --password "app-specific-password"
#
# Without a Developer ID cert, signing/notarization are skipped and an ad-hoc DMG is produced.
set -euo pipefail

cd "$(dirname "$0")/.."
PROJECT="MacInspect.xcodeproj"
SCHEME="MacInspect"
APP_NAME="MacInspect"
ARTIFACTS_DIR="artifacts"

ARCH_INPUT="${1:-universal}"
case "$ARCH_INPUT" in
  intel|x86_64)
    BUILD_ARCHS="x86_64"
    ARCH_LABEL="intel"
    ;;
  apple-silicon|arm64|as)
    BUILD_ARCHS="arm64"
    ARCH_LABEL="apple-silicon"
    ;;
  universal|both)
    BUILD_ARCHS="arm64 x86_64"
    ARCH_LABEL="universal"
    ;;
  *)
    echo "Usage: $0 [intel|apple-silicon|universal]" >&2
    exit 1
    ;;
esac

BUILD_DIR="${ARTIFACTS_DIR}/build/release-${ARCH_LABEL}"
OUTPUT_DIR="${MACINSPECT_OUTPUT_DIR:-${MACCHECK_OUTPUT_DIR:-${ARTIFACTS_DIR}/dist}}"
SIGN_ID="${MACINSPECT_SIGN_ID:-${MACCHECK_SIGN_ID:-Developer ID Application}}"
NOTARY_PROFILE="${MACINSPECT_NOTARY_PROFILE:-${MACCHECK_NOTARY_PROFILE:-macinspect-notary}}"

echo "▸ Generate Xcode project"
command -v xcodegen >/dev/null && xcodegen generate

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" src/App/Info.plist 2>/dev/null || echo "0.0.0")
mkdir -p "$OUTPUT_DIR"
DMG_OUT="$OUTPUT_DIR/${APP_NAME}-${VERSION}-${ARCH_LABEL}.dmg"

echo "▸ Release build (ARCHS=${BUILD_ARCHS}) → $BUILD_DIR"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
LOG=$(mktemp)
if ! xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
  ARCHS="$BUILD_ARCHS" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO build > "$LOG" 2>&1; then
  echo "❌ Build failed; last 60 lines:" >&2
  tail -60 "$LOG" >&2
  rm -f "$LOG"
  exit 1
fi
tail -1 "$LOG"
rm -f "$LOG"

APP="$BUILD_DIR/Build/Products/Release/${APP_NAME}.app"
if [ ! -d "$APP" ]; then
  echo "❌ Build product not found: $APP" >&2
  exit 1
fi

echo "▸ Architecture check"
BIN_INFO=$(lipo -info "$APP/Contents/MacOS/${APP_NAME}")
echo "  $BIN_INFO"
case "$ARCH_LABEL" in
  intel)
    echo "$BIN_INFO" | grep -q "x86_64" || { echo "❌ Product is not Intel x86_64" >&2; exit 1; }
    ;;
  apple-silicon)
    echo "$BIN_INFO" | grep -q "arm64" || { echo "❌ Product is not Apple Silicon arm64" >&2; exit 1; }
    ;;
  universal)
    if ! { echo "$BIN_INFO" | grep -q "x86_64" && echo "$BIN_INFO" | grep -q "arm64"; }; then
      echo "❌ Product is not a universal (arm64 + x86_64) binary" >&2
      exit 1
    fi
    ;;
esac

HAS_CERT=$(security find-identity -v -p codesigning 2>/dev/null | grep -c "Developer ID Application" || true)
if [ "$HAS_CERT" -gt 0 ]; then
  echo "▸ Developer ID sign (hardened runtime)"
  # Entitlements must be passed explicitly or camera/mic fail under hardened runtime.
  codesign --force --options runtime --timestamp \
    --entitlements src/App/MacInspect.entitlements \
    --sign "$SIGN_ID" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
  SIGNED=1
else
  echo "⚠ No Developer ID certificate; skipping sign/notarize. Ad-hoc DMG only (local use; others need right-click Open)."
  SIGNED=0
fi

echo "▸ Create DMG (${ARCH_LABEL})"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG_OUT"
hdiutil create -volname "${APP_NAME}" -srcfolder "$STAGE" -ov -format UDZO "$DMG_OUT" | tail -1
rm -rf "$STAGE"

if [ "$SIGNED" -eq 1 ]; then
  echo "▸ Notarize DMG (Apple; usually a few minutes)"
  xcrun notarytool submit "$DMG_OUT" --keychain-profile "$NOTARY_PROFILE" --wait
  echo "▸ Staple notarization ticket"
  xcrun stapler staple "$DMG_OUT"
  xcrun stapler validate "$DMG_OUT"
  echo "✅ ${ARCH_LABEL}: signed + notarized + stapled → $DMG_OUT"
else
  echo "✅ ${ARCH_LABEL}: ad-hoc DMG → $DMG_OUT"
fi
