#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$ROOT_DIR/build/DerivedData}"
RELEASE_DIR="$ROOT_DIR/build/release"
APP_NAME="Save the Knowledge"
APP_PATH="$DERIVED_DATA_PATH/Build/Products/Release/${APP_NAME}.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/KnowledgeCache/Info.plist")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT_DIR/KnowledgeCache/Info.plist")"
ARTIFACT_SLUG="save-the-knowledge"
ARTIFACT_BASENAME="${ARTIFACT_SLUG}-macOS-v${VERSION}-b${BUILD_NUMBER}-unsigned"
ZIP_PATH="$RELEASE_DIR/${ARTIFACT_BASENAME}.zip"
DMG_PATH="$RELEASE_DIR/${ARTIFACT_BASENAME}.dmg"
STAGING_DIR="$RELEASE_DIR/dmg-staging"

rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"

echo "[1/4] Building unsigned Release app..."
xcodebuild \
  -project KnowledgeCache.xcodeproj \
  -scheme KnowledgeCache \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build

test -d "$APP_PATH"

echo "[2/4] Creating ZIP artifact..."
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

echo "[3/4] Creating DMG artifact..."
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
cp -R "$APP_PATH" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"
DMG_CREATED="true"
if ! hdiutil create \
  -volname "${APP_NAME}" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"; then
  DMG_CREATED="false"
  echo "WARN: DMG creation failed in this environment; continuing with ZIP artifact."
fi

echo "[4/4] Writing release manifest..."
cat > "$RELEASE_DIR/manifest.txt" <<EOF
app_name=${APP_NAME}
version=${VERSION}
build=${BUILD_NUMBER}
zip=${ZIP_PATH##*/}
dmg_created=${DMG_CREATED}
dmg=${DMG_PATH##*/}
EOF

echo "Artifacts:"
echo " - $ZIP_PATH"
if [ "$DMG_CREATED" = "true" ]; then
  echo " - $DMG_PATH"
fi
echo " - $RELEASE_DIR/manifest.txt"
