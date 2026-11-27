#!/bin/bash
# Build Verso's test Flatpak (ARCHITECTURE.md, "Verso as a Flatpak") into OUT_DIR as verso-x86_64.flatpak, on a
# machine without flatpak-builder: in a Fedora 44 container (podman, else docker), as the rpm and the deb are built
# (verso-packages.sh). It builds from the source archive and the manifest, as a release does: OUT_DIR's
# verso-source.tar.gz (ci/release.sh's, from a clean worktree of the tag), or, where OUT_DIR has none, one made here from
# what git holds at HEAD, so nothing the tree ignores (credentials, build output, pictures) goes in; and
# flatpak/dev.hviid.Verso.yml.
# Run from the repository's root:
#
#   linux/packaging/verso-flatpak.sh OUT_DIR
#
# The GNOME runtime and SDK, the Rust extension and flatpak-builder's state are kept between builds in
# VERSO_FLATPAK_HOME (default ~/.cache/verso-flatpak), so only what changed is built again; the container's image, Fedora
# with flatpak-builder, is made once as localhost/verso-flatpak-builder. flatpak-builder's sandbox needs the container
# privileged. In the container the script runs itself again: verso-flatpak.sh --inside OUT_DIR.
set -euo pipefail
umask 022

image=localhost/verso-flatpak-builder
fedora_image=${VERSO_FEDORA_IMAGE:-registry.fedoraproject.org/fedora:44}
flathub=https://dl.flathub.org/repo/flathub.flatpakrepo
bundle=verso-x86_64.flatpak

die() {
    echo "verso-flatpak.sh: $*" >&2
    exit 1
}

# The manifest with the source archive's checksum beside its path, so flatpak-builder's cache, kept between releases,
# takes a changed source for a new one: by its path alone, it built the previous release's again.
with_source_checksum() {
    local manifest=$1 archive=$2 sum
    sum=$(sha256sum "$archive" | cut -d' ' -f1)
    sed -i "s|^\( *\)path: verso-source.tar.gz\$|&\n\1sha256: $sum|" "$manifest"
    grep -q "sha256: $sum" "$manifest" || die "no source archive path in $manifest"
}

# The source as HEAD has it, with the version it builds as, in the layout flatpak/source-archive.sh gives.
committed_source() {
    local out=$1 stage
    stage=$(mktemp -d)
    git archive --format=tar --prefix=verso/ HEAD | tar -x -C "$stage"
    ci/version.sh > "$stage/verso/VERSION"
    tar -czf "$out/verso-source.tar.gz" -C "$stage" verso
    rm -rf "$stage"
}

# On the build machine: the image once, then one container for the build.
outside() {
    local out=${1:?usage: linux/packaging/verso-flatpak.sh OUT_DIR} engine home
    engine=$(command -v podman || command -v docker) || die "podman or docker builds the Flatpak; neither is here"
    home=${VERSO_FLATPAK_HOME:-$HOME/.cache/verso-flatpak}
    mkdir -p "$out" "$home"
    out=$(cd "$out" && pwd)
    [ -e "$out/verso-source.tar.gz" ] || committed_source "$out"
    if ! "$engine" image exists "$image" 2>/dev/null && ! "$engine" image inspect "$image" >/dev/null 2>&1; then
        echo "The builder's image, once: $fedora_image with flatpak-builder"
        local context
        context=$(mktemp -d)
        printf 'FROM %s\nRUN dnf install -y -q flatpak flatpak-builder git && dnf clean all\n' "$fedora_image" \
            | "$engine" build -q -t "$image" -f - "$context"
        rmdir "$context"
    fi
    echo "Verso's Flatpak, in $image"
    "$engine" run --rm --privileged --security-opt label=disable \
        -v "$PWD/linux/packaging:/packaging:ro" -v "$out:/out" -v "$home:/home/builder" \
        -e HOME=/home/builder \
        "$image" bash /packaging/verso-flatpak.sh --inside /out
}

# In the container: the runtime from Flathub where it is missing, then the build, then the bundle.
inside() {
    local out=$1 work=/home/builder/work
    rm -rf "$work"
    mkdir -p "$work"
    cp /packaging/flatpak/dev.hviid.Verso.yml "$out/verso-source.tar.gz" "$work/"
    cd "$work"
    with_source_checksum dev.hviid.Verso.yml verso-source.tar.gz
    flatpak remote-add --user --if-not-exists flathub "$flathub"
    flatpak-builder --user --install-deps-from=flathub --force-clean --state-dir=/home/builder/state \
        --repo=/home/builder/repo build dev.hviid.Verso.yml
    flatpak build-bundle /home/builder/repo "$out/$bundle" dev.hviid.Verso --runtime-repo="$flathub"
    rm -rf "$work"
    echo "built $out/$bundle"
}

if [ "${1:-}" = --inside ]; then
    inside "${2:?}"
else
    outside "$@"
fi
