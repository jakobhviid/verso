#!/bin/bash
# The source a test Flatpak is built from (`verso-source.tar.gz` beside dev.hviid.Verso.yml): this tree without its
# build output and history, and the version it is built as (`ci/version.sh`) in `VERSION`, as the build has no history
# to count. Run from the repository's root: linux/packaging/flatpak/source-archive.sh OUT_DIR
set -euo pipefail
out=${1:?usage: linux/packaging/flatpak/source-archive.sh OUT_DIR}
version=$(ci/version.sh)
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
mkdir "$stage/verso"
printf '%s\n' "$version" > "$stage/verso/VERSION"
here=$(basename "$PWD")
tar -czf "$out/verso-source.tar.gz" --exclude="$here/target" --exclude="$here/.git" --exclude="$here/.claude" \
    --transform "s,^$here/,verso/," -C .. "$here" -C "$stage" verso/VERSION
echo "Verso $version"
