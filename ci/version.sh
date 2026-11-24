#!/bin/sh
# The version (AGENTS.md, "Versioning"): the last release's tag, the newest `v` tag reachable from HEAD (`v0.72.2`),
# with one bump for the commits since it, by the largest their subjects ask for: a breaking `type!:` the major, a
# `feat:` the minor, anything else the patch. At a tag it is the tag's own version, whatever number the maintainer
# gave it; after a pre-release's tag (`v1.0.0-beta.1`) it is the version that leads to (1.0.0). `ci/release.sh`
# suggests it for the next tag, and every build takes it from here (`linux/packaging/verso-tarball.sh`, the Flatpak's
# source, `mac/build-rust.sh`), so the tag, the About window and `--version` agree.
#
# While the major version is 0, as until the public launch, a breaking change bumps the minor, as semantic versioning
# has it for 0.x. A checkout without the tags (a shallow clone) has nothing to count from, and stops.
#
#   ci/version.sh            print the version, such as 0.72.0
#   ci/version.sh --stamp    also write it into Cargo.toml, for a build that reads it there (Verso's set VERSO_VERSION)
set -eu
cd "$(dirname "$0")/.."

if last=$(git describe --tags --abbrev=0 --match 'v[0-9]*' HEAD 2>/dev/null); then
  tagged=${last#v}
  echo "$tagged" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$' ||
    { echo "ci/version.sh: the tag $last is not a version (vMAJOR.MINOR.PATCH, or with -PRERELEASE)" >&2; exit 1; }
  if [ "$(git rev-list --count "$last..HEAD")" -eq 0 ]; then
    version=$tagged
  elif [ "${tagged%%-*}" != "$tagged" ]; then
    version=${tagged%%-*}
  else
    subjects=$(git log --format=%s "$last..HEAD")
    if printf '%s\n' "$subjects" | grep -Eq '^[A-Za-z]+(\([^)]*\))?!:'; then
      bump=major
      [ "${tagged%%.*}" = 0 ] && bump=minor
    elif printf '%s\n' "$subjects" | grep -Eq '^feat(\([^)]*\))?:'; then
      bump=minor
    else
      bump=patch
    fi
    version=$(echo "$tagged" | awk -F. -v bump="$bump" '{
      if (bump == "major") print ($1 + 1) ".0.0"
      else if (bump == "minor") print $1 "." ($2 + 1) ".0"
      else print $1 "." $2 "." ($3 + 1)
    }')
  fi
else
  echo "ci/version.sh: no v tag in this checkout's history; fetch the tags (git fetch --tags)" >&2
  exit 1
fi

if [ "${1:-}" = --stamp ]; then
  stamped=$(mktemp)
  sed -E "s/^version = \"[^\"]*\"/version = \"$version\"/" Cargo.toml > "$stamped" && mv "$stamped" Cargo.toml
fi
echo "$version"
