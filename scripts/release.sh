#!/usr/bin/env bash
# Ships Docket to people.
#
#   scripts/release.sh ios     Archive the iPhone app, sign it for your team and upload it to TestFlight.
#   scripts/release.sh mac     Build the Mac app signed with your Developer ID, notarise and staple the DMG.
#
# Reads these from the environment or from the git-ignored .env (never printed):
#   APPLE_TEAM_ID   your team's 10-character ID (developer.apple.com → Membership)
#   ASC_KEY_ID      App Store Connect API key ID (Users and Access → Integrations → App Store Connect API)
#   ASC_ISSUER_ID   that page's Issuer ID
#   ASC_KEY_PATH    the key's .p8 file (default ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8)
#   DEVELOPER_ID    mac only: "Developer ID Application: Your Company (TEAMID)" (default: found in your keychain
#                   for APPLE_TEAM_ID)
# Optional: BUILD_NUMBER (default: the current time, yyyyMMddHHmm, always increasing), UPLOAD=0 to stop after
# exporting the .ipa.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Only these keys are read from .env; nothing else in it is touched or shown.
env_value() {
  [[ -f .env ]] || return 0
  { grep -E "^$1=" .env || true; } | tail -1 | cut -d= -f2- | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//"
}
for key in APPLE_TEAM_ID ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_PATH DEVELOPER_ID; do
  if [[ -z "${!key:-}" ]]; then
    value="$(env_value "$key")"
    if [[ -n "$value" ]]; then export "$key=$value"; fi
  fi
done

fail() { echo "error: $*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$1"; }

need_key() {
  [[ -n "${APPLE_TEAM_ID:-}" ]] || fail "Set APPLE_TEAM_ID (in .env or the environment)."
  [[ -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" ]] || fail "Set ASC_KEY_ID and ASC_ISSUER_ID (App Store Connect API key)."
  ASC_KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}"
  ASC_KEY_PATH="${ASC_KEY_PATH/#\~/$HOME}"
  [[ -f "$ASC_KEY_PATH" ]] || fail "No API key file at $ASC_KEY_PATH."
  export ASC_KEY_PATH
  AUTH=(-allowProvisioningUpdates -authenticationKeyPath "$ASC_KEY_PATH"
        -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
}

ios() {
  need_key
  local build="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
  local out="$ROOT/build/ios"
  local archive="$out/DocketPhone.xcarchive"
  rm -rf "$archive" "$out/export"
  mkdir -p "$out"

  step "Archiving the iPhone app (build $build)"
  xcodebuild -project iOS/DocketPhone.xcodeproj -scheme DocketPhone -configuration Release \
    -destination 'generic/platform=iOS' -archivePath "$archive" \
    DEVELOPMENT_TEAM="$APPLE_TEAM_ID" CODE_SIGN_STYLE=Automatic CURRENT_PROJECT_VERSION="$build" \
    "${AUTH[@]}" archive | grep -E "^(\*\*|error:|warning: .*(sign|provision))" || true
  [[ -d "$archive" ]] || fail "The archive failed; run again without the filter to see why: xcodebuild … archive"

  local destination=upload
  [[ "${UPLOAD:-1}" == "0" ]] && destination=export
  cat > "$out/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>$destination</string>
  <key>teamID</key><string>$APPLE_TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
PLIST

  step "$([[ $destination == upload ]] && echo "Uploading to App Store Connect" || echo "Exporting the .ipa")"
  xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$out/ExportOptions.plist" \
    -exportPath "$out/export" "${AUTH[@]}" | grep -E "^(\*\*|error:)|Upload|uploaded" || true
  if [[ $destination == upload ]]; then
    echo "Build $build is on its way. It shows in App Store Connect → TestFlight once Apple has processed it (usually 5–15 minutes)."
  else
    ls "$out/export"/*.ipa >/dev/null 2>&1 || fail "No .ipa was exported."
    echo "IPA: $(ls "$out/export"/*.ipa)"
  fi
}

mac() {
  need_key
  local identity="${DEVELOPER_ID:-}"
  if [[ -z "$identity" ]]; then
    identity="$(security find-identity -v -p codesigning | grep "Developer ID Application" | grep "($APPLE_TEAM_ID)" \
      | head -1 | sed -E 's/.*"(.*)"/\1/')"
  fi
  [[ -n "$identity" ]] || fail "No \"Developer ID Application\" certificate for team $APPLE_TEAM_ID on this Mac. The team's Account Holder creates one in Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application."
  step "Building, signing and notarising the Mac app"
  SIGN_IDENTITY="$identity" scripts/build.sh
}

case "${1:-}" in
  ios) ios ;;
  mac) mac ;;
  *) echo "usage: scripts/release.sh ios|mac" >&2; exit 2 ;;
esac
