#!/usr/bin/env bash
# Releases cut by a tag (AGENTS.md, "Versioning"; ARCHITECTURE.md, "Verso's releases"). The maintainer starts each
# step; the release workflow (.github/workflows/release.yml), started by hand, is the backup that runs `build` the same
# way on GitHub.
#
#   ci/release.sh                  the version the next release would take (ci/version.sh) and its notes
#   ci/release.sh check [REF]      check REF (HEAD when not given) from a clean worktree of it, as a release needs:
#                                  clippy, the tests and the translations in the toolbox; the portable crates for
#                                  macOS in a container with rustup; Immich's contract tests against a lab server of
#                                  each supported version on Erebus (the lab-immich-server skill). A commit that
#                                  passes is noted in target/release-checks, which `tag` asks for
#   ci/release.sh tag [VERSION]    tag HEAD, clean, checked and on origin/main (a beta's on origin/develop), as vVERSION
#                                  (the suggested one when not given), signed, and push the tag
#   ci/release.sh build TAG        build Linux's files from the tag, in a worktree of its own (the tarball, the AppImage,
#                                  the rpm and the deb, the Flatpak's source and the Flatpak, with flatpak-builder or
#                                  in a container of its own), into target/dist/TAG, and make a draft release of them
#                                  here
#   ci/release.sh mac TAG DMG BUILD  the Mac's disk image (mac/release.sh's, BUILD its app's build number), signed for
#                                  Sparkle with VERSO_SPARKLE_KEY (default ~/.config/verso-release/sparkle-ed25519.pem)
#                                  and attached to the draft, whose title and notes then name macOS
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
# The two channels' casks (AGENTS.md, "Versioning"): stable's from main's releases, beta's from develop's betas too.
cask=Casks/verso.rb
beta_cask=Casks/verso@beta.rb
tarball=verso-x86_64.tar.gz
flatpak=verso-x86_64.flatpak
appimage=verso-x86_64.AppImage
# The packages, named by the release's version (linux/packaging/verso-packages.sh).
rpm_of() { echo "verso-$1.x86_64.rpm"; }
deb_of() { echo "verso_$1_amd64.deb"; }
flathub=https://dl.flathub.org/repo/flathub.flatpakrepo
version_pattern='^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$'
# The Immich versions a release's contract tests run against: the oldest Verso supports (SPEC.md, "Supported
# versions") and the newest the lab is made for. CI's weekly run adds Immich's newest release.
contract_versions=(v3.2.0 v3.3.6)
# Commits that passed `check`, one file each, named by the commit.
checked_dir=$root/target/release-checks

usage() {
  echo "usage: ci/release.sh [check [REF] | tag [VERSION] | build TAG | mac TAG DMG BUILD | publish TAG] [--dry-run]" >&2
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
  is_prerelease "$version" &&
    upgrade='A beta, from the beta channel: `brew install --cask jakobhviid/tap/verso@beta` takes it, and `verso` stays at the last stable release.'
  printf "Verso for x86_64 Linux. Needs GNOME 49's libraries or newer, libadwaita 1.8 and GTK 4.18 "
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
      VERSO_TARGET_ROOT="${VERSO_TARGET_ROOT:-}" VERSO_BINARIES="${VERSO_BINARIES:-}" \
      CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER=cc CC_x86_64_unknown_linux_gnu=cc \
      CXX_x86_64_unknown_linux_gnu=c++ AR_x86_64_unknown_linux_gnu=ar \
      bash -c 'cd "$1" && shift && exec "$@"' _ "$PWD" "$@"
  fi
}

# Run a command holding one of the build slots (VERSO_BUILD_SLOTS, 2 by default): an optimised build of Verso holds
# 3 to 4.5 GB in each of its two links, and three at once ran the workstation, with a desktop beside them, out of
# memory. A lane waits here for a slot; the slots are lock files the kernel frees with the process that held one.
with_build_slot() {
  local slots=${VERSO_BUILD_SLOTS:-2} slot handle status=0
  while :; do
    for slot in $(seq 1 "$slots"); do
      exec {handle}>"$slot_dir/slot-$slot.lock"
      if flock -n "$handle"; then
        "$@" || status=$?
        exec {handle}>&-
        return "$status"
      fi
      exec {handle}>&-
    done
    sleep 5
  done
}

# Fedora's lane: the programs built once, in the toolbox, for the tarball, which then the AppImage and the rpm take, so
# the three carry the same programs, which tell from where they run how they were installed (ARCHITECTURE.md, "One
# build for Fedora's files").
build_fedora() {
  with_build_slot in_build_environment linux/packaging/verso-tarball.sh "$1"
  export VERSO_BINARIES=$VERSO_TARGET_ROOT/package/release
  in_build_environment linux/packaging/verso-appimage.sh "$1"
  linux/packaging/verso-packages.sh "$1" rpm
}

# The Flatpak lane: the source archive, then the Flatpak, with flatpak-builder where it is (the release workflow's
# container), else in a container of its own (linux/packaging/verso-flatpak.sh), else none, which build then says.
build_flatpak() {
  local out=$1 cache
  linux/packaging/flatpak/source-archive.sh "$out"
  if command -v flatpak-builder >/dev/null; then
    mkdir "$out/flatpak"
    cp linux/packaging/flatpak/dev.hviid.Verso.yml "$out/verso-source.tar.gz" "$out/flatpak/"
    cd "$out/flatpak"
    # The archive's checksum beside its path, so the kept state takes a changed source for a new one.
    local sum
    sum=$(sha256sum verso-source.tar.gz | cut -d' ' -f1)
    sed -i "s|^\( *\)path: verso-source.tar.gz\$|&\n\1sha256: $sum|" dev.hviid.Verso.yml
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
  elif command -v podman >/dev/null || command -v docker >/dev/null; then
    linux/packaging/verso-flatpak.sh "$out"
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

# One of check's steps, timed.
check_step() { printf '%6ss  %s\n' "$SECONDS" "$*"; }

# The contract tests against a lab server of one Immich version on Erebus, warm from its snapshot where it is there,
# reached through a tunnel to this host; the server stays up, warm, for the next release (AGENTS.md, "Testing on
# Erebus"). The lab's scripts run from this checkout, which has Erebus beside it; the tests from the worktree.
check_contract() {
  local version=$1 worktree=$2 name env port=2295
  name=ind-immich-contract-${version//./-}
  env=$root/lab/immich-server/.env.$name.local
  check_step "Immich $version: the contract tests, against $name on Erebus"
  IMMICH_VERSION=$version IMMICH_INSTANCE=$name lab/immich-server/up.sh
  [ -f "$env" ] || IMMICH_INSTANCE=$name lab/immich-server/seed.sh
  IMMICH_INSTANCE=$name SHOWCASE_PORT=$port lab/immich-server/tunnel.sh open
  local status=0
  (cd "$worktree" && in_build_environment env CARGO_TARGET_DIR="$root/target/release-cache/check" bash -c \
    'set -a; . "$1"; set +a; IMMICH_URL=http://127.0.0.1:$2 cargo test -q -p immich-api --tests -- --ignored --test-threads=1' \
    _ "$env" "$port") || status=$?
  IMMICH_INSTANCE=$name SHOWCASE_PORT=$port lab/immich-server/tunnel.sh close
  [ "$status" -eq 0 ] || die "the contract tests failed against Immich $version"
}

# What a release is checked by, on this machine, from a clean worktree of the commit: CI's checks, made the release's
# (ARCHITECTURE.md, "Verso's releases"). The Apple side is checked on the Mac as it is built (mac/release.sh).
check() {
  [ $# -le 1 ] || usage
  local commit worktree=${XDG_CACHE_HOME:-$HOME/.cache}/verso-check/verso
  commit=$(git rev-parse --verify --quiet "${1:-HEAD}^{commit}") || die "no commit ${1:-HEAD} here"
  echo "Checking $(git log -1 --format='%h %s' "$commit")"
  git -C "$root" worktree remove --force "$worktree" 2>/dev/null || true
  git -C "$root" worktree prune
  mkdir -p "$(dirname "$worktree")" "$root/target/release-cache/check-darwin" "$root/target/release-cache/check-registry"
  trap 'git -C "$root" worktree remove --force "$worktree" 2>/dev/null || true' EXIT
  git worktree add --quiet --detach "$worktree" "$commit"
  SECONDS=0

  check_step "the gate: clippy (warnings are errors), the tests and the translations, in the toolbox"
  (cd "$worktree" && in_build_environment env CARGO_TARGET_DIR="$root/target/release-cache/check" bash -c \
    'cargo clippy -q --workspace --all-targets -- -D warnings && cargo test -q --workspace && python3 po/i18n.py check') ||
    die "the gate failed"

  # Fedora's Rust has no rustup to add the target, so a container with rustup checks it.
  check_step "the portable crates build for macOS (aarch64-apple-darwin), without TLS, in a container with rustup"
  local engine
  engine=$(command -v podman || command -v docker) || die "podman or docker checks the portable crates for macOS"
  "$engine" run --rm --security-opt label=disable -v "$worktree:/src:ro" -v "$root/target/release-cache/check-darwin:/target" \
    -v "$root/target/release-cache/check-registry:/usr/local/cargo/registry" -w /src docker.io/library/rust:1 bash -c \
    'rustup target add aarch64-apple-darwin >/dev/null 2>&1 && CARGO_TARGET_DIR=/target cargo check -q --locked \
       -p immich-api -p verso-core --no-default-features --target aarch64-apple-darwin' ||
    die "the portable crates do not build for macOS"

  local version
  for version in "${contract_versions[@]}"; do check_contract "$version" "$worktree"; done

  mkdir -p "$checked_dir"
  date -u +%Y-%m-%dT%H:%M:%SZ > "$checked_dir/$commit"
  check_step "$(git log -1 --format=%h "$commit") passed: ci/release.sh tag takes it"
}

tag_head() {
  [ $# -le 1 ] || usage
  local suggested version tag last released branch head
  [ -z "$(git status --porcelain)" ] || refuse "the checkout has changes; a release is tagged on a clean HEAD"
  suggested=$(ci/version.sh)
  version=${1:-$suggested}
  tag=v${version#v}
  version=$(version_of "$tag")
  # A release is tagged on what main holds, a beta on what develop holds (AGENTS.md, "Branches").
  branch=main
  is_prerelease "$version" && branch=develop
  git fetch --quiet origin "$branch"
  git merge-base --is-ancestor HEAD "origin/$branch" ||
    refuse "HEAD ($(git rev-parse --short HEAD)) is not on origin/$branch; $tag is tagged on what $branch holds"
  head=$(git rev-parse HEAD)
  [ -f "$checked_dir/$head" ] ||
    refuse "HEAD ($(git rev-parse --short HEAD)) has not passed the release's checks: ci/release.sh check
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

  # A worktree of the tag of its own, so the files are built from exactly what the tag holds; at the same path every
  # time, so Cargo takes Verso's own crates for the same ones from release to release.
  work=${XDG_CACHE_HOME:-$HOME/.cache}/verso-release
  git -C "$root" worktree remove --force "$work/verso" 2>/dev/null || true
  rm -rf "$work"
  git -C "$root" worktree prune
  mkdir -p "$work"
  trap 'git -C "$root" worktree remove --force "$work/verso" 2>/dev/null || true; rm -rf "$work"' EXIT
  git worktree add --quiet --detach "$work/verso" "$commit"
  # The builds outside the worktree, kept between releases, so Cargo builds again only what changed: each lane's in a
  # folder of its own under target/release-cache (the release workflow gives its cache's instead).
  export VERSO_TARGET_ROOT=${VERSO_TARGET_ROOT:-$root/target/release-cache}
  mkdir -p "$VERSO_TARGET_ROOT"
  built=$(cd "$work/verso" && ci/version.sh)
  [ "$built" = "$version" ] || die "the tree at $tag numbers itself $built, not $version"

  out=$root/target/dist/$tag
  rm -rf "$out"
  mkdir -p "$out"
  # Three lanes at once, each with a build folder of its own and a log in target/dist/TAG.logs: Fedora's, whose one
  # build of the programs the tarball, the AppImage and the rpm carry; the deb's, built in Ubuntu against its
  # libraries; and the Flatpak's, from the source archive in its SDK. Two optimised builds run at once (with_build_slot).
  # A lane that fails stops the release, with its log's end.
  local logs=$out.logs lane names=() pids=() failed=()
  rm -rf "$logs"
  mkdir -p "$logs"
  slot_dir=$logs
  start_lane() {
    local name=$1
    shift
    # Its command on a line of its own, so `set -e` stops the lane at its first failure.
    (
      cd "$work/verso"
      SECONDS=0
      "$@"
      echo "the lane took $((SECONDS / 60))m $((SECONDS % 60))s"
    ) > "$logs/$name.log" 2>&1 &
    names+=("$name")
    pids+=($!)
  }
  start_lane fedora build_fedora "$out"
  start_lane deb with_build_slot linux/packaging/verso-packages.sh "$out" deb
  start_lane flatpak with_build_slot build_flatpak "$out"
  echo "Building in three lanes at once; their logs are in $logs"
  for lane in "${!pids[@]}"; do
    if wait "${pids[$lane]}"; then
      echo "  ${names[$lane]}: built, $(tail -1 "$logs/${names[$lane]}.log" | sed 's/^the lane //')"
    else
      echo "  ${names[$lane]}: failed"
      failed+=("${names[$lane]}")
    fi
  done
  for lane in ${failed[@]+"${failed[@]}"}; do
    echo
    echo "The end of $logs/$lane.log:"
    tail -20 "$logs/$lane.log"
  done
  [ ${#failed[@]} -eq 0 ] || die "${failed[*]} failed"
  files=("$out/$tarball" "$out/$appimage" "$out/$(rpm_of "$version")" "$out/$(deb_of "$version")")
  # Where zsyncmake was here, AppImage updaters have their file to read.
  [ ! -e "$out/$appimage.zsync" ] || files+=("$out/$appimage.zsync")
  [ ! -e "$out/$flatpak" ] || files+=("$out/$flatpak")
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

# A cask's text in the tap; for the beta's, where the tap has none yet, the stable one's made the beta's.
cask_text() {
  local file=$1 text
  if text=$(gh api "repos/$tap/contents/$file" --jq .content 2>/dev/null); then
    printf '%s' "$text" | base64 --decode
  elif [ "$file" = "$beta_cask" ]; then
    gh api "repos/$tap/contents/$cask" --jq .content | base64 --decode | beta_cask_of
  else
    die "$tap has no $file"
  fi
}

# The beta channel's cask from the stable one's (stdin): its own name, the channel in its name and description, and a
# livecheck that takes pre-releases.
beta_cask_of() {
  sed -e 's/^cask "verso" do$/cask "verso@beta" do/' \
    -e 's/^  name "Verso for Immich"$/  name "Verso for Immich (beta)"/' \
    -e 's/^  desc "\(.*\) (unofficial)"$/  desc "\1 (unofficial, beta channel)"/' \
    -e '/^  conflicts_with cask: /d' \
    -e 's/strategy :github_latest/strategy :github_releases/'
}

# Each channel's cask names the other as one it conflicts with, as both install the same app; and neither calls the
# build an evaluation build, which is a channel's word for nothing.
cask_channels() {
  local file=$1 other=verso@beta
  [ "$file" = "$beta_cask" ] && other=verso
  awk -v line="  conflicts_with cask: \"$other\"" '
    $0 == line { have = 1 }
    { lines[NR] = $0 }
    END {
      for (n = 1; n <= NR; n++) {
        if (!have && lines[n] ~ /^  name "/) { print line; print ""; have = 1 }
        print lines[n]
      }
    }' | sed 's/^      An evaluation build\. /      /'
}

bump_cask() {
  local file=$1 version=$2 sha=$3 mac_sha=${4:-} current at updated clone
  current=$(cask_text "$file")
  at=$(printf '%s\n' "$current" | awk '$0 == "  on_linux do" { inside = 1 } inside && /^    version / { gsub(/[^0-9a-z.~-]/, "", $2); print $2; exit }')
  updated=$(printf '%s\n' "$current" | cask_for "$version" "$sha" "$mac_sha" | cask_channels "$file")
  if [ "$current" = "$updated" ]; then
    echo "The cask is at $version already."
    return
  elif [ "$at" != "$version" ] && ! above "$version" "$at"; then
    echo "The cask is at $at, after $version: it stays."
    return
  fi
  grep -q "^    sha256 \"$sha\"$" <<< "$updated" || die "$tap's $file has no on_linux sha256 line to set; bump it by hand"
  echo "$file's bump, in $tap:"
  diff -u --label "a/$file" --label "b/$file" <(printf '%s\n' "$current") <(printf '%s\n' "$updated") || true
  if [ "$dry_run" = yes ]; then
    echo "dry run, would commit it to $tap's main as \"$(basename "$file" .rb) $version\" and push it"
    return
  fi
  clone=$(mktemp -d)
  gh repo clone "$tap" "$clone/tap" -- --quiet --depth 1
  printf '%s\n' "$updated" > "$clone/tap/$file"
  git -C "$clone/tap" add "$file"
  git -C "$clone/tap" commit --quiet --message "$(basename "$file" .rb) $version" -- "$file"
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
  mac_digest=$(gh release view "$tag" --repo "${repositories[-1]}" --json assets \
    --jq ".assets[] | select(.name == \"verso-$version.dmg\") | .digest")
  # A beta reaches the beta channel's cask alone; a stable release reaches both, so the beta channel takes it too.
  if is_prerelease "$version"; then
    echo "A beta: verso@beta takes it, and verso stays at the last stable release."
  else
    bump_cask "$cask" "$version" "${first_digest#sha256:}" "${mac_digest#sha256:}"
  fi
  bump_cask "$beta_cask" "$version" "${first_digest#sha256:}" "${mac_digest#sha256:}"
  # Verso's page, its latest.json and Sparkle's feed follow the release; a beta reaches the feed's beta channel.
  change gh workflow run pages.yml --repo "$repository" --ref main
}

# The Mac's disk image on the tag's draft: signed for Sparkle, attached, and the draft's title and notes naming macOS,
# with a macOS section covering everything since the previous Mac release, whose users skip the Linux-only ones;
# Sparkle's update window shows it (site/build.py). The release workflow runs the same.
mac_release() {
  [ $# -eq 3 ] || usage
  local tag=$1 dmg=$2 build=$3 version key previous notes body title
  version=$(version_of "$tag")
  key=${VERSO_SPARKLE_KEY:-$HOME/.config/verso-release/sparkle-ed25519.pem}
  signed_in_to_github
  [ -f "$dmg" ] || die "no disk image at $dmg"
  [ "$(basename "$dmg")" = "verso-$version.dmg" ] || die "$dmg is not verso-$version.dmg"
  gh release view "$tag" --repo "$repository" >/dev/null 2>&1 || die "no release $tag yet: ci/release.sh build $tag first"
  ci/sign-mac-update.sh "$dmg" "$key" "$build"
  change gh release upload "$tag" "$dmg" "$dmg.update" --repo "$repository" --clobber
  previous=$(gh release list --repo "$repository" --limit 50 --json tagName,isDraft \
    --jq '.[] | select(.isDraft | not) | .tagName' | while read -r earlier; do
      if gh release view "$earlier" --repo "$repository" --json assets --jq '.assets[].name' | grep -q '\.dmg$'; then
        echo "$earlier"
        break
      fi
    done)
  notes=$(ci/release-notes.sh ${previous:+"$previous"} "$tag")
  body=$(gh release view "$tag" --repo "$repository" --json body --jq .body)
  case $body in "## macOS"*) echo "The draft names macOS already."; return ;; esac
  title=$(gh release view "$tag" --repo "$repository" --json name --jq .name | sed 's/ (Linux)$/ (Linux and macOS)/')
  printf '## macOS\n\n`verso-%s.dmg`, for macOS 15 or later, signed and notarized; Verso offers it in Check for Updates…, or `brew upgrade --cask verso`.\n\n%s\n\n## Linux\n\n%s\n' \
    "$version" "$notes" "$body" > "$root/target/dist/$tag.mac-notes.md"
  change gh release edit "$tag" --repo "$repository" --title "$title" --notes-file "$root/target/dist/$tag.mac-notes.md"
  echo "The Mac's disk image is on $tag's draft, \"$title\"."
}

case "${1:-}" in
  "") suggest ;;
  check) shift; check "$@" ;;
  tag) shift; tag_head "$@" ;;
  build) shift; build "$@" ;;
  mac) shift; mac_release "$@" ;;
  publish) shift; publish "$@" ;;
  *) usage ;;
esac
