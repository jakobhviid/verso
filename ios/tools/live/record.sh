#!/bin/bash
# From Linux: runs one UI test of ios/VersoUITests on the Mac's iPhone 17 Pro Max Simulator while the Mac records its
# screen, then brings the test's screenshots back and prints its step marks (REFERENCE lines) with the recording's start,
# to read the recording against them with track.swift (ARCHITECTURE.md, "Live Photos"):
#   ios/tools/live/record.sh <TestClass[/method]>
#   ssh "$MAC_HOST" 'cd ~/Developer/Private/verso/ios/build/live && ./track ../recordings/<recording>.mov <motion.MOV> <still.JPG> <rest s> <from s> <to s>'
# The repository is copied to the Mac's checkout first. Walks against a lab server get its address and full key from
# lab/immich-server/.env.<instance>.local over SSH's standard input into the test run's environment (TEST_RUNNER_),
# never on a command line and never printed; the result bundle and the log are removed from the Mac once read.
# Env: MAC_HOST (user@address; private, never written into the repository), MAC_SSH_OPTIONS (such as
# "-i ~/.ssh/<key> -o IdentitiesOnly=yes"), IMMICH_INSTANCE (default ind-immich-show), LIVE_LABEL (which Live Photo
# PhotosReferenceTests opens: words of its label, such as a date), LIVE_PHOTO_ID (which of the demo's Live Photos
# LiveRealWalkTests opens), SIMULATOR (the Simulator device's name, default iPhone 17 Pro Max).
set -uo pipefail
filter=${1:?test}
host=${MAC_HOST:?MAC_HOST, user@address of the Mac}
read -r -a ssh_options <<< "${MAC_SSH_OPTIONS:-}"
repo=$(cd "$(dirname "$0")/../../.." && pwd)
env_file=$repo/lab/immich-server/.env.${IMMICH_INSTANCE:-ind-immich-show}.local
simulator=${SIMULATOR:-iPhone 17 Pro Max}
run=$(date +%H%M%S)
name=$(echo "$filter" | tr '/' '-')-$run
out=${TMPDIR:-/tmp}/verso-recordings/$run

rsync -a -e "ssh ${ssh_options[*]}" --exclude /target/ --exclude /mac/build/ --exclude /ios/build/ \
  --exclude /mac/Verso/build/ --exclude '*.xcodeproj/' --exclude '.env*.local' --exclude __pycache__ \
  --exclude '/lab/**/evidence/' --exclude '/lab/**/screenshots/' --exclude '/lab/**/cache/' \
  "$repo/" "$host:Developer/Private/verso/" || exit 1

url='' key=''
if [[ -f $env_file ]]; then
  url=$(bash -c 'set -a; . "$1"; printf %s "$IMMICH_MAC_URL"' _ "$env_file")
  key=$(bash -c 'set -a; . "$1"; printf %s "$IMMICH_API_KEY_FULL"' _ "$env_file")
fi

printf '%s\n%s\n%s\n%s\n' "$url" "$key" "${LIVE_LABEL:-}" "${LIVE_PHOTO_ID:-}" | ssh "${ssh_options[@]}" "$host" "zsh -lc '
read -r url; read -r key; read -r label; read -r photo
export TEST_RUNNER_LIVE_LABEL=\$label
[[ -n \$photo ]] && export TEST_RUNNER_LIVE_PHOTO_ID=\$photo
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
[[ -n \$url ]] && export TEST_RUNNER_IMMICH_URL=\$url TEST_RUNNER_IMMICH_API_KEY=\$key
device=\$(xcrun simctl list devices available | sed -nE \"s/^ *$simulator \\(([0-9A-F-]+)\\).*/\\1/p\" | head -1)
[[ -n \$device ]] || { echo no $simulator Simulator; exit 1; }
xcrun simctl boot \$device 2>/dev/null
cd ~/Developer/Private/verso/ios && xcodegen > /dev/null 2>&1 || { echo xcodegen failed; exit 1; }
mkdir -p build/recordings build/live && cp tools/live/*.swift build/live/
(cd build/live && for tool in track against frames compare-key; do [[ ! -e \$tool || \$tool.swift -nt \$tool ]] && xcrun swiftc -O \$tool.swift -o \$tool 2>/dev/null; done)
xcrun simctl io \$device recordVideo --codec=h264 --force build/recordings/$name.mov > /dev/null 2>&1 &
recorder=\$!
echo recording started at \$(perl -MTime::HiRes=time -e \"printf q(%.3f), time\")
xcodebuild test -project Verso.xcodeproj -scheme Verso -destination id=\$device -only-testing:VersoUITests/$filter \
  -derivedDataPath build/SimulatorData -resultBundlePath build/$name.xcresult \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= > build/$name.log 2>&1
echo test exit \$?
kill -INT \$recorder; wait \$recorder 2>/dev/null
grep -E \"error:|: (error|warning):|Test Case .*(passed|failed|skipped)|REFERENCE|RESULT\" build/$name.log | grep -v \"ld: warning\" | sed -E \"s|^/Users/[^/]+/Developer/Private/verso/||\" | head -60
xcrun xcresulttool export attachments --path build/$name.xcresult --output-path build/$name > /dev/null 2>&1
rm -rf build/$name.xcresult build/$name.log
echo recording: ios/build/recordings/$name.mov
'"
mkdir -p "$out"
scp -q -r "${ssh_options[@]}" "$host:Developer/Private/verso/ios/build/$name/." "$out/" 2>/dev/null && \
  ssh "${ssh_options[@]}" "$host" "rm -rf ~/Developer/Private/verso/ios/build/$name" && echo "screenshots: $out"
