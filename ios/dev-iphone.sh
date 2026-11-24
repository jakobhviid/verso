#!/usr/bin/env bash
# Verso Dev on a connected iPhone or iPad: the Debug build of Verso on iOS, signed with the developer's own team
# (mac/Config/Local.xcconfig), installed on the device and started. It has an identity of its own (dev.hviid.Verso.Dev,
# its App Group, settings and an icon with its turned corner blue), so it lives beside a release. The device is paired
# with this Mac and in Developer Mode (AGENTS.md, "Development environment"); Xcode registers it with the team on the
# first build.
#
#   ios/dev-iphone.sh [launch arguments...]   build, install and start, with the launch arguments a script signs in
#                                             with (-signInServer ..., as in the Simulator)
#   ios/dev-iphone.sh --remove                delete it from the device
#
# The device is the first connected physical one, or VERSO_DEVICE (its identifier, `xcrun devicectl list devices`).
# Signing needs the login keychain, which an SSH session cannot reach: from SSH, run ios/dev-iphone.command in the
# developer's session (`open -g -a Terminal ios/dev-iphone.command`, the mac-dev skill), and read
# ios/build/dev-iphone.log.
set -euo pipefail
cd "$(dirname "$0")"
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
bundle=dev.hviid.Verso.Dev
built="build/DeviceData/Build/Products/Debug-iphoneos/Verso Dev.app"

device=${VERSO_DEVICE:-}
if [ -z "$device" ]; then
    listing=$(mktemp)
    xcrun devicectl list devices --json-output "$listing" > /dev/null
    device=$(python3 -c '
import json, sys
devices = json.load(open(sys.argv[1]))["result"]["devices"]
for found in devices:
    hardware, connection = found.get("hardwareProperties", {}), found.get("connectionProperties", {})
    if hardware.get("reality") == "physical" and hardware.get("platform") == "iOS" \
            and connection.get("pairingState") == "paired":
        print(found["hardwareProperties"]["udid"])
        break
' "$listing")
    rm -f "$listing"
fi
if [ -z "$device" ]; then
    echo "no paired iPhone or iPad: connect one, trust this Mac, and turn on Developer Mode" >&2
    exit 1
fi

if [ "${1:-}" = "--remove" ]; then
    xcrun devicectl device uninstall app --device "$device" "$bundle"
    echo "removed Verso Dev from the device"
    exit 0
fi
../mac/build-rust.sh debug --ios
xcodegen -q
xcodebuild -project Verso.xcodeproj -scheme Verso -configuration Debug -destination "id=$device" \
  -derivedDataPath build/DeviceData -allowProvisioningUpdates -allowProvisioningDeviceRegistration build -quiet
xcrun devicectl device install app --device "$device" "$built"
xcrun devicectl device process launch --device "$device" --terminate-existing "$bundle" "$@"
echo "installed and started Verso Dev on the device"
