#!/bin/sh
# Sign a Mac disk image for Sparkle's updates (ARCHITECTURE.md, "Verso on the Mac", "Verso's releases"): an Ed25519
# signature over the whole file, which the app checks against its SUPublicEDKey, and the app's build number, which
# Sparkle compares with the installed one's. Both go beside the disk image as DMG.update, which is attached to the
# release with it; the download page's appcast is made from them.
#
#   ci/sign-mac-update.sh mac/build/release/verso-0.73.0.dmg KEY.pem [BUILD]
#
# BUILD is the build number the disk image's app carries (CFBundleVersion, the build's UTC time, which
# mac/build-rust.sh writes into mac/build/Version.xcconfig); the release job passes the one it built with. Without
# it, the one in mac/build/Version.xcconfig is used, which is right only on the checkout that built the disk image: a
# wrong build number would make Sparkle offer the update wrongly, or never.
set -eu
[ $# -eq 2 ] || [ $# -eq 3 ] || { echo "usage: ci/sign-mac-update.sh DMG KEY.pem [BUILD]" >&2; exit 2; }
dmg=$1
key=$2
version=$(basename "$dmg" .dmg | sed 's/^verso-//')
if [ $# -eq 3 ]; then
  build=$3
else
  build=$(sed -n 's/^CURRENT_PROJECT_VERSION = //p' "$(dirname "$0")/../mac/build/Version.xcconfig" 2>/dev/null) || true
  [ -n "$build" ] || { echo "no mac/build/Version.xcconfig here: give BUILD, the app's build number" >&2; exit 1; }
fi
signature=$(openssl pkeyutl -sign -inkey "$key" -rawin -in "$dmg" | base64 | tr -d '\n')
printf 'build=%s\nsignature=%s\n' "$build" "$signature" > "$dmg.update"
echo "wrote $dmg.update (version $version, build $build)"
