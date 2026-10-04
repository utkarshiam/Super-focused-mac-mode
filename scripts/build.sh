#!/usr/bin/env bash
# Builds Docket.app as a universal binary (Apple Silicon + Intel) and packages it as a DMG and a ZIP.
#
#   scripts/build.sh                 # ad-hoc signed (fine for your own Macs)
#
# For distribution without Gatekeeper warnings, set a Developer ID identity and a notarytool profile:
#   SIGN_IDENTITY="Developer ID Application: Your Company (TEAMID)" \
#   NOTARY_PROFILE="docket-notary" scripts/build.sh
#   (create the profile once: xcrun notarytool store-credentials docket-notary --apple-id you@x.com --team-id TEAMID)
#
# Optional: VERSION=1.2.0 BUNDLE_ID=com.yourco.docket
set -euo pipefail

APP_NAME="Docket"
BUNDLE_ID="${BUNDLE_ID:-com.docketapp.Docket}"
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
MIN_MACOS="13.0"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
ASSETS="$ROOT/build/assets"
APP="$DIST/$APP_NAME.app"
cd "$ROOT"

step() { printf "\n\033[1;34m==> %s\033[0m\n" "$1"; }

step "Generating icon and alarm sound"
if [[ ! -f "$ASSETS/AppIcon.icns" || ! -f "$ASSETS/DocketAlarm.wav" || "$ROOT/scripts/make-assets.swift" -nt "$ASSETS/AppIcon.icns" ]]; then
  swift scripts/make-assets.swift "$ASSETS"
else
  echo "up to date"
fi

step "Running tests"
mkdir -p "$ROOT/build"
TEST_LOG="$ROOT/build/test.log"
if ! swift test > "$TEST_LOG" 2>&1; then
  grep -E "error:|failed" "$TEST_LOG" | head -20
  echo "Tests failed. Full log: $TEST_LOG"
  exit 1
fi
grep -E "Executed [0-9]+ tests" "$TEST_LOG" | tail -1 || true

step "Compiling universal release binary (arm64 + x86_64)"
swift build -c release --arch arm64 --arch x86_64 --product "$APP_NAME"
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
lipo -info "$BIN_DIR/$APP_NAME"

step "Assembling $APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/Sounds"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp "$ASSETS/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ASSETS/DocketAlarm.wav" "$APP/Contents/Resources/DocketAlarm.wav"
# Notification sounds are looked up in Contents/Library/Sounds.
cp "$ASSETS/DocketAlarm.wav" "$APP/Contents/Library/Sounds/DocketAlarm.wav"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSSupportsSuddenTermination</key><false/>
  <key>NSHumanReadableCopyright</key><string>© $(date +%Y) Docket</string>
  <key>NSCalendarsUsageDescription</key><string>Docket reads today's meetings to work out how much free time you have for your tasks.</string>
  <key>NSCalendarsFullAccessUsageDescription</key><string>Docket reads today's meetings to work out how much free time you have for your tasks.</string>
</dict>
</plist>
PLIST
printf "APPL????" > "$APP/Contents/PkgInfo"

step "Code signing"
ENTITLEMENTS="$ROOT/build/Docket.entitlements"
cat > "$ENTITLEMENTS" <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.personal-information.calendars</key><true/>
</dict>
</plist>
ENT
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$APP"
else
  echo "No SIGN_IDENTITY set — using an ad-hoc signature (see README for opening it on another Mac)."
  codesign --force --sign - "$APP"
fi
codesign --verify --deep --strict "$APP" && echo "signature OK"

step "Packaging"
DMG="$DIST/$APP_NAME-$VERSION.dmg"
ZIP="$DIST/$APP_NAME-$VERSION.zip"
STAGE="$ROOT/build/dmg"
rm -rf "$STAGE" "$DMG" "$ZIP"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
# Build read-write first so the mounted volume can get Docket's icon, then compress.
RW_DMG="$ROOT/build/$APP_NAME-rw.dmg"
rm -f "$RW_DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDRW "$RW_DMG" >/dev/null
MOUNT_DIR="$(hdiutil attach -readwrite -noverify -noautoopen -nobrowse "$RW_DMG" | awk -F'\t' '/\/Volumes\// {print $NF}')"
cp "$ASSETS/AppIcon.icns" "$MOUNT_DIR/.VolumeIcon.icns"
SetFile -a C "$MOUNT_DIR"
hdiutil detach "$MOUNT_DIR" -quiet
hdiutil convert "$RW_DMG" -format UDZO -o "$DMG" >/dev/null
rm -rf "$STAGE" "$RW_DMG"
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
fi

if [[ -n "${SIGN_IDENTITY:-}" && -n "${NOTARY_PROFILE:-}" ]]; then
  step "Notarizing (this takes a few minutes)"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler staple "$APP"
fi

ditto -c -k --keepParent "$APP" "$ZIP"
touch "$APP"  # nudge Finder to refresh its icon cache

step "Done"
echo "App: $APP"
echo "DMG: $DMG ($(du -h "$DMG" | cut -f1))"
echo "ZIP: $ZIP ($(du -h "$ZIP" | cut -f1))"
