#!/usr/bin/env bash
# Verso Dev: the Debug build of Verso's Mac app, signed with the developer's own team (mac/Config/Local.xcconfig),
# installed as /Applications/Verso Dev.app and started. It has an identity of its own (dev.hviid.Verso.Dev, its App
# Group, settings and Finder location) and an icon with its turned corner blue, so it lives beside an installed
# release.
#
#   mac/Verso/dev-app.sh            build, install and start
#   mac/Verso/dev-app.sh --remove   quit it, and delete it
#
# Signing needs the login keychain, which an SSH session cannot reach: from SSH, run mac/Verso/dev-app.command in
# the developer's session (`open -a Terminal mac/Verso/dev-app.command`, the mac-dev skill), and read
# mac/Verso/build/dev-app.log.
set -euo pipefail
cd "$(dirname "$0")"
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
built="build/DevData/Build/Products/Debug/Verso Dev.app"
installed="/Applications/Verso Dev.app"
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
if [ "${1:-}" = "--remove" ]; then
    pkill -f "Verso Dev.app/Contents/" || true
    for app in "$installed" "$built"; do
        if [ -d "$app" ]; then "$lsregister" -u "$app"; fi
    done
    rm -rf "$installed" build/DevData
    echo "removed Verso Dev"
    exit 0
fi
# The bridge is one framework for every Apple target: where this Mac builds the iPhone's slices, they stay in it, so
# the iOS project (ios/) keeps building from the same mac/build/.
if rustup target list --installed 2>/dev/null | grep -q '^aarch64-apple-ios-sim$'; then
    ../build-rust.sh debug --ios
else
    ../build-rust.sh debug
fi
xcodegen -q
xcodebuild -project Verso.xcodeproj -scheme Verso -configuration Debug -destination platform=macOS \
  -derivedDataPath build/DevData -allowProvisioningUpdates build -quiet
# Only the Dev app and its extensions stop, matched by their path; a release keeps running.
pkill -f "Verso Dev.app/Contents/" || true
ditto "$built" "$installed.new"
rm -rf "$installed"
mv "$installed.new" "$installed"
touch "$installed"  # macOS caches an app's icon by its path (the mac-dev skill)
open "$installed"
echo "installed and started $installed"
