#!/usr/bin/env bash
# Releases cut by a tag (AGENTS.md, "Versioning"; ARCHITECTURE.md, "Verso's releases"). The maintainer starts each
# step; the release workflow (.github/workflows/release.yml), started by hand, is the backup that runs `build` the same
# way on GitHub.
#
#   ci/release.sh                  the version the next release would take (ci/version.sh) and its notes
#   ci/release.sh tag [VERSION]    tag HEAD, clean and on origin/main, as vVERSION (the suggested one when not given),
#                                  signed, and push the tag
#   ci/release.sh build TAG        build Linux's files from the tag, in a worktree of its own (the tarball, the AppImage,
#                                  the rpm and the deb, the Flatpak's source and the Flatpak, with flatpak-builder or
#                                  in a container of its own), into target/dist/TAG, and make a draft release of them
#                                  here
#   ci/release.sh publish TAG      publish the draft, then bump the tap's `verso` cask (not for a pre-release)
#
# --dry-run, anywhere on the line, changes nothing outside this checkout: every tag, push, release and cask change is
# printed in place of being made. `build` still builds, and where the tag is not there yet it builds HEAD as tagging it
# would number it, so a release can be rehearsed whole.
set -euo pipefail
cd "$(dirname "$0")/.."
root=$PWD

repository=jakobhviid/verso
tap=jakobhviid/homebrew-tap
cask=Casks/verso.rb
tarball=verso-x86_64.tar.gz
flatpak=verso-x86_64.flatpak
appimage=verso-x86_64.AppImage
# The packages, named by the release's version (linux/packaging/verso-packages.sh).
rpm_of() { echo "verso-$1.x86_64.rpm"; }
deb_of() { echo "verso_$1_amd64.deb"; }
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
# (whose runtime the tree's manifest names) and the AppImage.
release_text() {
  local version=$1 previous=$2 end=$3 tree=$4 notes runtime upgrade
  notes=$(ci/release-notes.sh "$previous" "$end")
  runtime=$(sed -n "s/^runtime-version: '\(.*\)'$/\1/p" "$tree/linux/packaging/flatpak/dev.hviid.Verso.yml")
  upgrade='Upgrade with `brew upgrade verso`.'
  is_prerelease "$version" && upgrade="A pre-release: Homebrew's cask stays at the last release."
  printf "Evaluation build for x86_64 Linux. Needs GNOME 49's libraries or newer, libadwaita 1.8 and GTK 4.18 "
  printf '(Fedora 43 and newer, Ubuntu 25.10 and 26.04 LTS, Debian 14, Arch); on an older system Verso says so as it '
  printf 'starts, and the AppImage and the Flatpak below run there, without Verso Drive. From the tarball, which Homebrew installs, '
  printf 'Verso Drive needs FUSE 3, and its menu in Files nautilus-python. %s\n\n' "$upgrade"
  printf '**Packages:** `%s` for Fedora 43 and newer (`sudo dnf install ./%s`), and `%s` for Ubuntu 26.04 and ' \
    "$(rpm_of "$version")" "$(rpm_of "$version")" "$(deb_of "$version")"
  printf 'newer and Debian 14 (`sudo apt install ./%s`): Verso with Verso Drive and its menu in Files, which your ' \
    "$(deb_of "$version")"
  printf 'package manager installs with what it needs, and refuses on an older system.\n\n'
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
  printf '`flatpak run dev.hviid.Verso`. With no keyring in the session, it keeps the sign-in in its own file.\n\n'
  printf '**AppImage:** `%s` is the same Verso, without Verso Drive, for the systems the Flatpak is for, with the ' "$appimage"
  printf 'libraries it needs inside it, the C library included, so it runs on systems as old as Ubuntu 24.04. Make it '
  printf 'executable and run it (`chmod +x %s && ./%s`); it needs FUSE 3 (`fusermount3`, which Ubuntu 24.04 has), or run ' \
    "$appimage" "$appimage"
  printf 'it with `--appimage-extract-and-run`. Videos that need an H.264 or H.265 decoder do not play in it. '
  printf 'AppImage updaters (AppImageUpdate) take its zsync file, `%s.zsync`.\n' "$appimage"
}

# The GitHub repositories a release goes to: this one, which Homebrew's cask and Verso's page download from.
release_repositories() {
  echo "$repository"
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
  echo "Next: ci/release.sh build $tag (or, with this machine away, gh workflow run release.yml -f tag=$tag)"
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
  # The AppImage, from the same toolbox: its libraries are Fedora 44's, and it carries them.
  (cd "$work/verso" && in_build_environment linux/packaging/verso-appimage.sh "$out")
  # The rpm and the deb, each in a container of its distribution, with podman or docker here.
  (cd "$work/verso" && linux/packaging/verso-packages.sh "$out")
  (cd "$work/verso" && linux/packaging/flatpak/source-archive.sh "$out")
  files=("$out/$tarball" "$out/$appimage" "$out/$(rpm_of "$version")" "$out/$(deb_of "$version")")
  # Where zsyncmake was here, AppImage updaters have their file to read.
  [ ! -e "$out/$appimage.zsync" ] || files+=("$out/$appimage.zsync")
  if command -v flatpak-builder >/dev/null; then
    mkdir "$out/flatpak"
    cp "$work/verso/linux/packaging/flatpak/dev.hviid.Verso.yml" "$out/verso-source.tar.gz" "$out/flatpak/"
    (
      cd "$out/flatpak"
      flatpak remote-add --user --if-not-exists flathub "$flathub"
      # A state directory kept between builds (VERSO_FLATPAK_STATE, the release workflow's cache) builds only what
      # changed; without one, everything is built afresh.
      if [ -n "${VERSO_FLATPAK_STATE:-}" ]; then
        cache=(--state-dir="$VERSO_FLATPAK_STATE")
      else
        cache=(--disable-cache)
      fi
      flatpak-builder --user --install-deps-from=flathub --force-clean "${cache[@]}" --repo=repo build \
        dev.hviid.Verso.yml
      flatpak build-bundle repo "$out/$flatpak" dev.hviid.Verso --runtime-repo="$flathub"
    )
    files+=("$out/$flatpak")
  elif command -v podman >/dev/null || command -v docker >/dev/null; then
    # Without flatpak-builder here, in a container of its own, its runtime and state kept between releases.
    (cd "$work/verso" && linux/packaging/verso-flatpak.sh "$out")
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
    echo "No flatpak-builder, podman or docker here, so no Flatpak: build it with linux/packaging/verso-flatpak.sh"
    echo "where podman is, then attach it to every draft before publishing:"
    for release in "${repositories[@]}"; do
      echo "  gh release upload $tag $flatpak --repo $release"
    done
  fi
  echo
  echo "Next: check the draft, installed in the lab's desktop VMs, then ci/release.sh publish $tag"
}

# The cask from stdin with version $2 and sha256 $3 in its `on_$1` part (linux: the tarball; macos: the disk image).
# Each part has a version of its own, as a release carries the Mac only when it was built for it.
cask_at() {
  awk -v part="  on_$1 do" -v version="$2" -v sha="$3" '
    $0 == part { inside = 1 }
    inside && $0 == "  end" { inside = 0 }
    inside && /^    version "[^"]*"$/ { $0 = "    version \"" version "\"" }
    inside && /^    sha256 "[0-9a-f]+"$/ { $0 = "    sha256 \"" sha "\"" }
    { print }'
}

# The cask at version $1 with the tarball's sha256 $2, and the disk image's $3 when the release carries one.
cask_for() {
  if [ -n "$3" ]; then cask_at linux "$1" "$2" | cask_at macos "$1" "$3"; else cask_at linux "$1" "$2"; fi
}

bump_cask() {
  local version=$1 sha=$2 mac_sha=${3:-} current at updated clone
  current=$(gh api "repos/$tap/contents/$cask" --jq .content | base64 --decode)
  at=$(printf '%s\n' "$current" | awk '$0 == "  on_linux do" { inside = 1 } inside && /^    version / { gsub(/[^0-9a-z.~-]/, "", $2); print $2; exit }')
  updated=$(printf '%s\n' "$current" | cask_for "$version" "$sha" "$mac_sha")
  if [ "$current" = "$updated" ]; then
    echo "The cask is at $version already."
    return
  elif [ "$at" != "$version" ] && ! above "$version" "$at"; then
    echo "The cask is at $at, after $version: it stays."
    return
  fi
  grep -q "^    sha256 \"$sha\"$" <<< "$updated" || die "$tap's $cask has no on_linux sha256 line to set; bump it by hand"
  echo "The cask's bump, in $tap:"
  diff -u --label "a/$cask" --label "b/$cask" <(printf '%s\n' "$current") <(printf '%s\n' "$updated") || true
  if [ "$dry_run" = yes ]; then
    echo "dry run, would commit it to $tap's main as \"verso $version\" and push it"
    return
  fi
  clone=$(mktemp -d)
  gh repo clone "$tap" "$clone/tap" -- --quiet --depth 1
  cask_for "$version" "$sha" "$mac_sha" < "$clone/tap/$cask" > "$clone/verso.rb"
  mv "$clone/verso.rb" "$clone/tap/$cask"
  git -C "$clone/tap" commit --quiet --message "verso $version" -- "$cask"
  git -C "$clone/tap" push --quiet origin HEAD
  rm -rf "$clone"
}

publish() {
  [ $# -eq 1 ] || usage
  local tag=$1 version repositories release draft digest flatpaks appimages packages first_digest="" mac_digest latest=(--latest)
  version=$(version_of "$tag")
  signed_in_to_github
  mapfile -t repositories < <(release_repositories)
  # Every release goes out whole: the same tarball everywhere, the packages, the AppImage and the Flatpak beside it.
  for release in "${repositories[@]}"; do
    draft=$(gh release view "$tag" --repo "$release" --json isDraft --jq .isDraft 2>/dev/null) ||
      die "$release has no release $tag; build it first (ci/release.sh build $tag)"
    digest=$(gh release view "$tag" --repo "$release" --json assets \
      --jq ".assets[] | select(.name == \"$tarball\") | .digest")
    flatpaks=$(gh release view "$tag" --repo "$release" --json assets \
      --jq "[.assets[] | select(.name == \"$flatpak\")] | length")
    appimages=$(gh release view "$tag" --repo "$release" --json assets \
      --jq "[.assets[] | select(.name == \"$appimage\")] | length")
    packages=$(gh release view "$tag" --repo "$release" --json assets --jq "[.assets[] | select(.name ==
      \"$(rpm_of "$version")\" or .name == \"$(deb_of "$version")\")] | length")
    [ -n "$digest" ] || die "$release's $tag has no $tarball"
    [ "$packages" -eq 2 ] || die "$release's $tag lacks $(rpm_of "$version") or $(deb_of "$version")"
    [ "$appimages" -gt 0 ] || die "$release's $tag has no $appimage; build it first (ci/release.sh build $tag)"
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
  mac_digest=$(gh release view "$tag" --repo "${repositories[-1]}" --json assets \
    --jq ".assets[] | select(.name == \"verso-$version.dmg\") | .digest")
  bump_cask "$version" "${first_digest#sha256:}" "${mac_digest#sha256:}"
  # Verso's page, its latest.json and Sparkle's feed follow the release.
  change gh workflow run pages.yml --repo "$repository" --ref main
}

case "${1:-}" in
  "") suggest ;;
  tag) shift; tag_head "$@" ;;
  build) shift; build "$@" ;;
  publish) shift; publish "$@" ;;
  *) usage ;;
esac
