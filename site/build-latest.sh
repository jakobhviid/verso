#!/bin/sh
# Build Verso's page for the releases there are (site/build.py) into OUTPUT: Linux's files from the latest release
# that carries them, the Mac's from the newest with a disk image. Needs `gh` signed in; reads, changes nothing.
#
#   site/build-latest.sh OUTPUT [--app-store URL] [--testflight URL]
set -eu
output=$1
shift
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
gh api 'repos/jakobhviid/verso-releases/releases?per_page=30' > "$work/releases.json"
python3 site/build.py "$work/releases.json" "$output" "$@"
