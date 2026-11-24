#!/bin/sh
# The version (AGENTS.md, "Versioning"): the last release's tag, the newest `v` tag reachable from HEAD (`v0.41.1`),
# with one bump for the commits since it, by the largest their subjects ask for: a breaking `type!:` the major, a
# `feat:` the minor, anything else the patch. At a tag it is the tag's own version, whatever number the maintainer
# gave it; after a pre-release's tag (`v1.0.0-beta.1`) it is the version that leads to (1.0.0). `ci/release.sh`
# suggests it for the next tag, and every build takes it from here (`linux/packaging/verso-tarball.sh`, the Flatpak's
# source, `mac/build-rust.sh`), so the tag, the About window and `--version` agree.
#
# Until the first tag cut this way, Verso counted a bump for every commit, from 0.5.19 at b4440a9, and reached 0.71.1 at
# 3662c11, past its last tag (v0.41.1), which builds since then have said: where the last tag is older than that
# commit, it stands for the last tag, so the numbers never go back. While the major version is 0, as until the public
# launch, a breaking change bumps the minor, as semantic versioning has it for 0.x.
#
# A history without the tags counts from 0.5.19 at b4440a9, a bump for every commit since, and says so; without that
# commit either, it stops.
#
#   ci/version.sh            print the version, such as 0.72.0
#   ci/version.sh --stamp    also write it into Cargo.toml, for a build that reads it there (Verso's set VERSO_VERSION)
set -eu
cd "$(dirname "$0")/.."

# Where per-commit counting ended, and what it had reached.
counted=3662c11eba7d7b825d93ee0a5f8bef0d745fb163
counted_version=0.71.1

if last=$(git describe --tags --abbrev=0 --match 'v[0-9]*' HEAD 2>/dev/null); then
  tagged=${last#v}
  if git cat-file -e "$counted^{commit}" 2>/dev/null && git merge-base --is-ancestor "$last" "$counted" &&
    git merge-base --is-ancestor "$counted" HEAD; then
    last=$counted
    tagged=$counted_version
  fi
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
  base=b4440a9d8d618b4d0c1bae49f21da1cb65d8b337
  git cat-file -e "$base^{commit}" 2>/dev/null ||
    { echo "ci/version.sh: no v tag in this checkout's history, nor $base, which it counts from without" >&2; exit 1; }
  echo "ci/version.sh: no v tag in this checkout's history (fetch the tags); counting from 0.5.19 at b4440a9" >&2
  version=$(git log --reverse --format='%s' "$base..HEAD" | awk '
    BEGIN { major = 0; minor = 5; patch = 19 }
    /^[A-Za-z]+(\([^)]*\))?!:/ { major++; minor = 0; patch = 0; next }
    /^feat(\([^)]*\))?:/ { minor++; patch = 0; next }
    { patch++ }
    END { print major "." minor "." patch }')
fi

if [ "${1:-}" = --stamp ]; then
  stamped=$(mktemp)
  sed -E "s/^version = \"[^\"]*\"/version = \"$version\"/" Cargo.toml > "$stamped" && mv "$stamped" Cargo.toml
fi
echo "$version"
