#!/usr/bin/env bash
# Releases cut by a tag (AGENTS.md, "Versioning"; ARCHITECTURE.md, "Verso's releases"). The maintainer starts each
# step; the release workflow (.github/workflows/release.yml) runs `build` the same way on a pushed tag.
#
#   ci/release.sh                  the version the next release would take (ci/version.sh) and its notes
#   ci/release.sh tag [VERSION]    tag HEAD, clean and on origin/main, as vVERSION (the suggested one when not given),
#                                  signed, and push the tag
#   ci/release.sh build TAG        build Linux's files from the tag, in a worktree of its own (the tarball, the
#                                  Flatpak's source and, where flatpak-builder is, the Flatpak), into target/dist/TAG,
#                                  and make a draft release of them here and in jakobhviid/verso-releases
#   ci/release.sh publish TAG      publish both drafts, then bump the tap's `verso` cask (not for a pre-release)
#
# --dry-run, anywhere on the line, changes nothing outside this checkout: every tag, push, release and cask change is
# printed in place of being made. `build` still builds, and where the tag is not there yet it builds HEAD as tagging it
# would number it, so a release can be rehearsed whole.
set -euo pipefail
cd "$(dirname "$0")/.."
root=$PWD

repository=jakobhviid/verso
# The public repository the releases are mirrored to, which Homebrew's cask downloads from until Verso goes public
# (ROADMAP.md, M8, "Going public"); left out once it is gone.
mirror=jakobhviid/verso-releases
tap=jakobhviid/homebrew-tap
cask=Casks/verso.rb
tarball=verso-x86_64.tar.gz
flatpak=verso-x86_64.flatpak
flathub=https://dl.flathub.org/repo/flathub.flatpakrepo
version_pattern='^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$'

usage() {
  echo "usage: ci/release.sh [tag [VERSION] | build TAG | publish TAG] [--dry-run]" >&2
  exit 2
}

dry_run=no
arguments=()
for argument in "$@"; do
  case "$argument" in
    --dry-run) dry_run=yes ;;
    -h | --help) sed -n '2,/^set /{/^set /d;s/^# \{0,1\}//;p}' "$0"; exit 0 ;;
    -*) usage ;;
    *) arguments+=("$argument") ;;
  esac
done
set -- ${arguments[@]+"${arguments[@]}"}

die() {
  echo "ci/release.sh: $*" >&2
  exit 1
}

# Stop at what a release must not go past; a dry run says so and goes on, to show the rest.
refuse() {
  [ "$dry_run" = yes ] || die "$*"
  echo "dry run: a real run stops here: $*"
}

# Make a change outside this checkout, or with --dry-run print it.
change() {
  if [ "$dry_run" = yes ]; then
    printf 'dry run, would run:'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

is_prerelease() { [[ $1 == *-* ]]; }

# A tag's version, or stop: v, then MAJOR.MINOR.PATCH, perhaps with -PRERELEASE.
version_of() {
  local version=${1#v}
  [[ $1 == v* && $version =~ $version_pattern ]] || die "$1 is not a release tag (v0.72.0, or v1.0.0-beta.1)"
  echo "$version"
}

# Whether version $1 comes after $2: by their numbers, and a release after its own pre-releases.
above() {
  local new=${1%%-*} old=${2%%-*}
  if [ "$new" = "$old" ]; then
    is_prerelease "$2" || return 1
    ! is_prerelease "$1" || [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" = "$1" ]
  else
    [ "$(printf '%s\n%s\n' "$new" "$old" | sort -V | tail -n 1)" = "$new" ]
  fi
}

# The tag a release's notes count from: before a pre-release the tag before it of any kind; before a release the
# release before it, so its notes cover its pre-releases too.
previous_tag() {
  local commit=$1 version=$2 exclude=(--exclude 'v*-*')
  is_prerelease "$version" && exclude=()
  git describe --tags --abbrev=0 --match 'v[0-9]*' ${exclude[@]+"${exclude[@]}"} "$commit^" 2>/dev/null || true
}

# The release's text: what it holds and needs, what changed for users since the previous release, and the Flatpak
# (whose runtime the tree's manifest names).
release_text() {
  local version=$1 previous=$2 end=$3 tree=$4 notes runtime upgrade
  notes=$(ci/release-notes.sh "$previous" "$end")
  runtime=$(sed -n "s/^runtime-version: '\(.*\)'$/\1/p" "$tree/linux/packaging/flatpak/dev.hviid.Verso.yml")
  upgrade='Upgrade with `brew upgrade verso`.'
  is_prerelease "$version" && upgrade="A pre-release: Homebrew's cask stays at the last release."
  printf "Evaluation build for x86_64 Linux. Needs GNOME 49's libraries or newer, libadwaita 1.8 and GTK 4.18 "
  printf '(Fedora 43 and newer, Ubuntu 25.10 and 26.04 LTS, Debian 14, Arch); on an older system Verso says so as it '
  printf 'starts, and the Flatpak below runs there, without Verso Drive. Verso Drive needs FUSE 3, and its menu in '
  printf 'Files nautilus-python. %s\n\n' "$upgrade"
  if [ -z "$previous" ]; then
    printf '%s\n\n' "$notes"
  elif [ -n "$notes" ]; then
    printf '## Since %s\n\n%s\n\n' "${previous#v}" "$notes"
  else
    printf 'Since %s: nothing users see changed.\n\n' "${previous#v}"
  fi
  printf '**Flatpak (test build):** `%s` is this release as a Flatpak, without Verso Drive. Install it with ' "$flatpak"
  printf '`flatpak install --user %s` (it fetches the GNOME %s runtime from Flathub) and run it with ' \
    "$flatpak" "$runtime"
  printf '`flatpak run dev.hviid.Verso`. With no keyring in the session, it keeps the sign-in in its own file.\n'
}

# The GitHub repositories a release goes to: this one, and the mirror while it exists.
release_repositories() {
  echo "$repository"
  if gh api "repos/$mirror" --silent 2>/dev/null; then
    echo "$mirror"
  fi
}

signed_in_to_github() {
  gh auth status >/dev/null 2>&1 || die "gh is not signed in to GitHub (gh auth login, or GH_TOKEN)"
}

# Run a build step in Fedora 44, against the libraries the tarball is made for: in the toolbox `verso` (AGENTS.md,
# "Development environment"; VERSO_TOOLBOX names another), with the linker overrides a global zig linker needs, or
# directly where this already runs in a container (the toolbox itself, the release workflow's).
in_build_environment() {
  if [ -e /run/.containerenv ] || [ -e /.dockerenv ] || ! command -v toolbox >/dev/null; then
    "$@"
  else
    toolbox run --container "${VERSO_TOOLBOX:-verso}" env \
      CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER=cc CC_x86_64_unknown_linux_gnu=cc \
      CXX_x86_64_unknown_linux_gnu=c++ AR_x86_64_unknown_linux_gnu=ar \
      bash -c 'cd "$1" && shift && exec "$@"' _ "$PWD" "$@"
  fi
}

suggest() {
  [ $# -eq 0 ] || usage
  local version tag previous notes
  version=$(ci/version.sh)
  if tag=$(git describe --tags --exact-match --match 'v[0-9]*' HEAD 2>/dev/null); then
    echo "HEAD is $tag already: build it with ci/release.sh build $tag"
    return
  fi
  previous=$(previous_tag HEAD "$version")
  echo "The next release: $version, from $(git log -1 --format='%h %s' HEAD)"
  echo "Tag it with ci/release.sh tag, or ci/release.sh tag VERSION for another number."
  echo
  notes=$(ci/release-notes.sh "$previous" HEAD)
  echo "Its notes, since ${previous:-the first commit}:"
  echo
  printf '%s\n' "${notes:-(nothing users see changed)}"
}

tag_head() {
  [ $# -le 1 ] || usage
  local suggested version tag last released
  [ -z "$(git status --porcelain)" ] || refuse "the checkout has changes; a release is tagged on a clean HEAD"
  git fetch --quiet origin main
  git merge-base --is-ancestor HEAD origin/main ||
    refuse "HEAD ($(git rev-parse --short HEAD)) is not on origin/main; a release is tagged on what main holds"
  suggested=$(ci/version.sh)
  version=${1:-$suggested}
  tag=v${version#v}
  version=$(version_of "$tag")
  ! git rev-parse --quiet --verify "refs/tags/$tag" >/dev/null || refuse "$tag is there already"
  ! git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null || refuse "$tag is on origin already"
  released=$(git tag --points-at HEAD --list 'v[0-9]*' | grep -v -- - || true)
  [ -z "$released" ] || refuse "HEAD is released already, as $released"
  if last=$(git describe --tags --abbrev=0 --match 'v[0-9]*' HEAD 2>/dev/null); then
    above "$version" "${last#v}" || refuse "$version does not come after ${last#v}, the last release's"
  fi
  echo "Tagging $(git log -1 --format='%h %s' HEAD) as $tag"
  [ "$version" = "$suggested" ] || echo "(the suggestion was $suggested)"
  change git tag --sign --message "Verso $version" "$tag" HEAD
  change git push origin "refs/tags/$tag"
  echo "Next: the release workflow builds its draft, or ci/release.sh build $tag"
}

build() {
  [ $# -eq 1 ] || usage
  # `work` is global: the trap that removes it runs after this returns.
  local tag=$1 version commit previous out built title repositories files release prerelease=()
  version=$(version_of "$tag")
  signed_in_to_github
  if commit=$(git rev-parse --quiet --verify "refs/tags/$tag^{commit}"); then
    echo "Building $tag ($(git log -1 --format='%h %s' "$commit"))"
  elif [ "$dry_run" = yes ]; then
    commit=$(git rev-parse HEAD)
    echo "No tag $tag yet: building HEAD ($(git log -1 --format='%h %s' HEAD)) as tagging it would number it"
  else
    die "no tag $tag here: fetch it (git fetch origin tag $tag), or make it (ci/release.sh tag)"
  fi
  mapfile -t repositories < <(release_repositories)
  for release in "${repositories[@]}"; do
    if gh release view "$tag" --repo "$release" >/dev/null 2>&1; then
      refuse "$release has a release $tag already; delete its draft to build it again"
    fi
  done

  # A worktree of the tag of its own, so the files are built from exactly what the tag holds.
  mkdir -p "${XDG_CACHE_HOME:-$HOME/.cache}"
  work=$(mktemp -d "${XDG_CACHE_HOME:-$HOME/.cache}/verso-release.XXXXXX")
  trap 'git -C "$root" worktree remove --force "$work/verso" 2>/dev/null || true; rm -rf "$work"' EXIT
  git worktree add --quiet --detach "$work/verso" "$commit"
  built=$(cd "$work/verso" && ci/version.sh)
  [ "$built" = "$version" ] || die "the tree at $tag numbers itself $built, not $version"

  out=$root/target/dist/$tag
  rm -rf "$out"
  mkdir -p "$out"
  (cd "$work/verso" && in_build_environment linux/packaging/verso-tarball.sh "$out")
  (cd "$work/verso" && linux/packaging/flatpak/source-archive.sh "$out")
  files=("$out/$tarball")
  if command -v flatpak-builder >/dev/null; then
    mkdir "$out/flatpak"
    cp "$work/verso/linux/packaging/flatpak/dev.hviid.Verso.yml" "$out/verso-source.tar.gz" "$out/flatpak/"
    (
      cd "$out/flatpak"
      flatpak remote-add --user --if-not-exists flathub "$flathub"
      flatpak-builder --user --install-deps-from=flathub --force-clean --disable-cache --repo=repo build \
        dev.hviid.Verso.yml
      flatpak build-bundle repo "$out/$flatpak" dev.hviid.Verso --runtime-repo="$flathub"
    )
    files+=("$out/$flatpak")
  fi

  previous=$(previous_tag "$commit" "$version")
  release_text "$version" "$previous" "$commit" "$work/verso" > "$out/notes.md"
  title="Verso $version (Linux)"
  is_prerelease "$version" && prerelease=(--prerelease)
  echo
  echo "Built into $out:"
  (cd "$out" && sha256sum -- "${files[@]##*/}")
  echo
  echo "The draft release, \"$title\":"
  echo
  cat "$out/notes.md"
  echo
  # The tag is GitHub's here; in the mirror, which holds no code, publishing makes it on its main.
  change gh release create "$tag" --repo "$repository" --draft --verify-tag --title "$title" \
    --notes-file "$out/notes.md" ${prerelease[@]+"${prerelease[@]}"} "${files[@]}"
  for release in "${repositories[@]}"; do
    [ "$release" = "$repository" ] && continue
    change gh release create "$tag" --repo "$release" --draft --target main --title "$title" \
      --notes-file "$out/notes.md" ${prerelease[@]+"${prerelease[@]}"} "${files[@]}"
  done
  if [ ! -e "$out/$flatpak" ]; then
    echo
    echo "No flatpak-builder here, so no Flatpak: build it in the GNOME VM from $out/verso-source.tar.gz and the"
    echo "manifest (the lab-desktop-vm skill), then attach it to every draft before publishing:"
    for release in "${repositories[@]}"; do
      echo "  gh release upload $tag $flatpak --repo $release"
    done
  fi
  echo
  echo "Next: check the draft, installed in the lab's desktop VMs, then ci/release.sh publish $tag"
}

# The cask from stdin at version $1, its tarball's sha256 $2.
cask_at() {
  sed -E -e "s/^  version \"[^\"]*\"$/  version \"$1\"/" -e "s/^  sha256 \"[0-9a-f]{64}\"$/  sha256 \"$2\"/"
}

bump_cask() {
  local version=$1 sha=$2 current at updated clone
  current=$(gh api "repos/$tap/contents/$cask" --jq .content | base64 --decode)
  at=$(sed -n 's/^  version "\(.*\)"$/\1/p' <<< "$current")
  updated=$(printf '%s\n' "$current" | cask_at "$version" "$sha")
  if [ "$current" = "$updated" ]; then
    echo "The cask is at $version already."
    return
  elif [ "$at" != "$version" ] && ! above "$version" "$at"; then
    echo "The cask is at $at, after $version: it stays."
    return
  fi
  grep -q "^  sha256 \"$sha\"$" <<< "$updated" || die "$tap's $cask has no single sha256 line to set; bump it by hand"
  echo "The cask's bump, in $tap:"
  diff -u --label "a/$cask" --label "b/$cask" <(printf '%s\n' "$current") <(printf '%s\n' "$updated") || true
  if [ "$dry_run" = yes ]; then
    echo "dry run, would commit it to $tap's main as \"verso $version\" and push it"
    return
  fi
  clone=$(mktemp -d)
  gh repo clone "$tap" "$clone/tap" -- --quiet --depth 1
  cask_at "$version" "$sha" < "$clone/tap/$cask" > "$clone/verso.rb"
  mv "$clone/verso.rb" "$clone/tap/$cask"
  git -C "$clone/tap" commit --quiet --message "verso $version" -- "$cask"
  git -C "$clone/tap" push --quiet origin HEAD
  rm -rf "$clone"
}

publish() {
  [ $# -eq 1 ] || usage
  local tag=$1 version repositories release draft digest flatpaks first_digest="" latest=(--latest)
  version=$(version_of "$tag")
  signed_in_to_github
  mapfile -t repositories < <(release_repositories)
  # Every release goes out whole: the same tarball everywhere, and the Flatpak beside it.
  for release in "${repositories[@]}"; do
    draft=$(gh release view "$tag" --repo "$release" --json isDraft --jq .isDraft 2>/dev/null) ||
      die "$release has no release $tag; build it first (ci/release.sh build $tag)"
    digest=$(gh release view "$tag" --repo "$release" --json assets \
      --jq ".assets[] | select(.name == \"$tarball\") | .digest")
    flatpaks=$(gh release view "$tag" --repo "$release" --json assets \
      --jq "[.assets[] | select(.name == \"$flatpak\")] | length")
    [ -n "$digest" ] || die "$release's $tag has no $tarball"
    [ "$flatpaks" -gt 0 ] || die "$release's $tag has no $flatpak; attach it first (ci/release.sh build says how)"
    [ -z "$first_digest" ] || [ "$digest" = "$first_digest" ] ||
      die "$release's $tarball is not the one in $repository ($digest, $first_digest)"
    first_digest=$digest
    echo "$release: $tag, $([ "$draft" = true ] && echo a draft || echo published), $tarball $digest"
  done
  is_prerelease "$version" && latest=(--prerelease --latest=false)
  for release in "${repositories[@]}"; do
    if [ "$(gh release view "$tag" --repo "$release" --json isDraft --jq .isDraft)" = true ]; then
      change gh release edit "$tag" --repo "$release" --draft=false "${latest[@]}"
    fi
  done
  if is_prerelease "$version"; then
    echo "A pre-release: the cask stays at the last release."
    return
  fi
  bump_cask "$version" "${first_digest#sha256:}"
}

case "${1:-}" in
  "") suggest ;;
  tag) shift; tag_head "$@" ;;
  build) shift; build "$@" ;;
  publish) shift; publish "$@" ;;
  *) usage ;;
esac
