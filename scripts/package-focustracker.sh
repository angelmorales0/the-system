#!/bin/bash
# Builds FocusTracker.dmg for a Mac that has no Xcode (for example a work Mac):
# signed with your Developer ID, notarized by Apple, and stapled, so it installs like Notion.
#
# One-time setup (you run these yourself; they ask for your Apple ID details):
#   1. Xcode → Settings → Accounts: sign in with your Apple Developer account.
#   2. Store a notarization login in the keychain:
#        xcrun notarytool store-credentials the-system-notary --apple-id <you@example.com> --team-id <TEAMID>
#      It asks for an app-specific password (appleid.apple.com → Sign-In and Security → App-Specific Passwords).
#
# Run:
#   TEAM_ID=<TEAMID> scripts/package-focustracker.sh
# Output: build/FocusTracker.dmg

set -euo pipefail
: "${TEAM_ID:?Set TEAM_ID to your 10-character Apple Developer Team ID}"
NOTARY_PROFILE="${NOTARY_PROFILE:-the-system-notary}"
ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
OUT="$ROOT/build/focustracker"
rm -rf "$OUT"
mkdir -p "$OUT"
cd "$ROOT"

echo "== Archive (Release)"
xcodebuild -project system.xcodeproj -scheme FocusTracker -configuration Release \
    -destination 'generic/platform=macOS' -archivePath "$OUT/FocusTracker.xcarchive" \
    DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates \
    archive > "$OUT/archive.log" 2>&1 || { tail -30 "$OUT/archive.log"; exit 1; }

echo "== Export with Developer ID"
cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>teamID</key><string>$TEAM_ID</string>
    <key>signingStyle</key><string>automatic</string>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -archivePath "$OUT/FocusTracker.xcarchive" -exportPath "$OUT/export" \
    -exportOptionsPlist "$OUT/ExportOptions.plist" -allowProvisioningUpdates \
    > "$OUT/export.log" 2>&1 || { tail -30 "$OUT/export.log"; exit 1; }

echo "== Make the disk image"
mkdir -p "$OUT/dmg"
cp -R "$OUT/export/FocusTracker.app" "$OUT/dmg/"
ln -s /Applications "$OUT/dmg/Applications"
hdiutil create -volname FocusTracker -srcfolder "$OUT/dmg" -ov -format UDZO "$ROOT/build/FocusTracker.dmg" > /dev/null

echo "== Notarize (takes a few minutes)"
xcrun notarytool submit "$ROOT/build/FocusTracker.dmg" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$ROOT/build/FocusTracker.dmg"
spctl --assess --type open --context context:primary-signature -v "$ROOT/build/FocusTracker.dmg"

echo "Done: $ROOT/build/FocusTracker.dmg"
echo "Copy it to the other Mac, open it, and drag FocusTracker to Applications."
