#!/usr/bin/env bash
# Build Verso for the iPhone and the iPad as it is released (AGENTS.md, "Versioning": iOS ships through TestFlight and
# the App Store, never on GitHub) and upload it to App Store Connect, where TestFlight takes it once Apple has
# processed it. On the maintainer's Mac in a Terminal window, where the login keychain is open (the mac-dev skill).
#
#   ios/release.sh [--no-upload]
#
# The archive is signed for development by Xcode (the team's account in Xcode's settings); the export signs it again
# for the App Store with the four App Store profiles, made in the developer portal and installed, and uploads it with
# an App Store Connect API key. It reads from the environment:
#   TEAM_ID                     the Apple Developer Program team
#   ASC_KEY_ID, ASC_ISSUER_ID   the API key (App Manager), whose AuthKey_<ASC_KEY_ID>.p8 is in
#                               ~/.appstoreconnect/private_keys/
#
# The version is the release line's (ci/version.sh, which build-rust.sh hands to Xcode); the build number is the
# build's UTC time, so every upload has a new one.
set -euo pipefail
cd "$(dirname "$0")"
upload=yes
case "${1:-}" in
  "") ;;
  --no-upload) upload=no ;;
  *) echo "usage: ios/release.sh [--no-upload]" >&2; exit 2 ;;
esac
: "${TEAM_ID:?TEAM_ID is the Apple Developer Program team}"
if [ "$upload" = yes ]; then
  : "${ASC_KEY_ID:?ASC_KEY_ID is the App Store Connect API key's ID}"
  : "${ASC_ISSUER_ID:?ASC_ISSUER_ID is the API key's issuer}"
  key="$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8"
  [ -f "$key" ] || { echo "no $key" >&2; exit 1; }
fi
out=build/release
archive="$out/Verso.xcarchive"
rm -rf "$out"
mkdir -p "$out"

../mac/build-rust.sh release --ios
xcodegen -q
xcodebuild archive -quiet -project Verso.xcodeproj -scheme Verso -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$archive" -allowProvisioningUpdates DEVELOPMENT_TEAM="$TEAM_ID"

# Each part with its App Store profile: the App Group and the Keychain group they share are entitlements only a
# profile grants.
cat >"$out/export.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>$([ "$upload" = yes ] && echo upload || echo export)</string>
  <key>signingStyle</key><string>manual</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingCertificate</key><string>Apple Distribution</string>
  <key>provisioningProfiles</key>
  <dict>
    <key>dev.hviid.Verso</key><string>Verso App Store Provisioning Profile</string>
    <key>dev.hviid.Verso.Drive</key><string>Verso Drive App Store Provisioning Profile</string>
    <key>dev.hviid.Verso.Messages</key><string>Verso Messages App Store Provisioning Profile</string>
    <key>dev.hviid.Verso.Widgets</key><string>Verso Widgets App Store Provisioning Profile</string>
  </dict>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
PLIST
authentication=()
if [ "$upload" = yes ]; then
  authentication=(-authenticationKeyPath "$key" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi
xcodebuild -exportArchive -archivePath "$archive" -exportPath "$out/export" -exportOptionsPlist "$out/export.plist" \
  ${authentication[@]+"${authentication[@]}"}
if [ "$upload" = yes ]; then
  echo "uploaded Verso $(../ci/version.sh) to App Store Connect: TestFlight has it once Apple has processed it"
else
  echo "exported $out/export"
fi
