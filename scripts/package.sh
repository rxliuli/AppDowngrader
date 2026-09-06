#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="AppDowngrader"
VERSION=$(plutil -extract CFBundleShortVersionString raw Info.plist)
BUILD_DIR=".build/release"
APP_BUNDLE="dist/${APP_NAME}.app"
CONTENTS="${APP_BUNDLE}/Contents"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
DMG_PATH="dist/${DMG_NAME}"

# Signing identity — set via env or auto-detect
SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/' || echo "")}"

if [ -z "$SIGN_ID" ]; then
    echo "Error: No 'Developer ID Application' certificate found."
    echo "Set SIGN_ID env var or install a Developer ID certificate."
    exit 1
fi
echo "==> Using identity: ${SIGN_ID}"

echo "==> Building release..."
swift build -c release 2>&1 | grep -E "Build complete|error:"

echo "==> Creating app bundle..."
rm -rf dist
mkdir -p "${CONTENTS}/MacOS"
mkdir -p "${CONTENTS}/Resources"

cp "${BUILD_DIR}/${APP_NAME}" "${CONTENTS}/MacOS/"
cp -R "${BUILD_DIR}/${APP_NAME}_${APP_NAME}.bundle" "${CONTENTS}/Resources/"
cp Info.plist "${CONTENTS}/"
cp Sources/AppIcon.png "${CONTENTS}/Resources/"

echo "==> Signing app with hardened runtime..."
# Sign bundled binaries first (innermost → outermost)
for bin in "${CONTENTS}/Resources/${APP_NAME}_${APP_NAME}.bundle/bin/"*; do
    codesign --force --sign "${SIGN_ID}" --options runtime --entitlements AppDowngrader.entitlements "$bin"
done
codesign --force --sign "${SIGN_ID}" --options runtime --entitlements AppDowngrader.entitlements "${APP_BUNDLE}"

echo "==> Verifying signature..."
codesign --verify --verbose "${APP_BUNDLE}"

echo "==> Creating DMG..."
DMG_STAGING="dist/dmg-staging"
rm -rf "${DMG_STAGING}"
mkdir -p "${DMG_STAGING}"
cp -R "${APP_BUNDLE}" "${DMG_STAGING}/"
ln -s /Applications "${DMG_STAGING}/Applications"
hdiutil create -volname "${APP_NAME}" -srcfolder "${DMG_STAGING}" -ov -format UDZO "${DMG_PATH}"
rm -rf "${DMG_STAGING}"

echo "==> Signing DMG..."
codesign --force --sign "${SIGN_ID}" "${DMG_PATH}"

echo "==> Submitting for notarization..."
xcrun notarytool submit "${DMG_PATH}" --keychain-profile "notarytool" --wait

echo "==> Stapling notarization ticket..."
xcrun stapler staple "${DMG_PATH}"

echo ""
echo "Done! ${DMG_PATH}"
echo "Size: $(du -sh "${DMG_PATH}" | cut -f1)"
