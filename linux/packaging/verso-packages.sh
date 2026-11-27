#!/bin/bash
# Build Verso's rpm and deb packages for x86_64 into OUT_DIR (ARCHITECTURE.md, "Packaging"):
#   verso-VERSION.x86_64.rpm   built in Fedora 44, for Fedora 43 and newer
#   verso_VERSION_amd64.deb    built in Ubuntu 26.04 LTS, the older of the two it is for, for it and Debian 14
# Each is built in a fresh container of its distribution's builder image (podman, else docker; the distribution with
# its build packages, made once, builder_image), from this tree, with that
# distribution's Rust, libraries and Nautilus, so the Files extension in C is built against the Nautilus it loads in and
# the dependencies are the ones its own tools find. Run from the repository's root:
#
#   linux/packaging/verso-packages.sh OUT_DIR [rpm] [deb]     (both when neither is named)
#
# The version (ci/version.sh) and the time every file in the packages is given (SOURCE_DATE_EPOCH, the commit's) come
# from this checkout's history, which the container does not see. The crates come from this account's cargo cache
# (the registry and the checkouts in CARGO_HOME, else ~/.cargo, without its configuration), fetched into it where
# missing; the build output stays in target/package-rpm and target/package-deb. In the container the script runs
# itself again: verso-packages.sh --inside FORMAT OUT_DIR.
set -euo pipefail
umask 022

fedora_image=${VERSO_FEDORA_IMAGE:-registry.fedoraproject.org/fedora:44}
ubuntu_image=${VERSO_UBUNTU_IMAGE:-docker.io/library/ubuntu:26.04}

die() {
    echo "verso-packages.sh: $*" >&2
    exit 1
}

# The builder's image for a package: its distribution's image with what the package is built with, made once and named
# for the list (this script's build_packages) and the base, so a change to either makes a new one, and a later build
# starts at once rather than installing some 500 packages. VERSO_REFRESH_BUILDERS=1 makes it again, for the
# distribution's updates.
builder_image() {
    local engine=$1 format=$2 base=$3 tag context
    tag=$( (printf '%s\n' "$base"; declare -f build_packages) | sha256sum | cut -c1-12)
    if [ "${VERSO_REFRESH_BUILDERS:-}" != 1 ] && "$engine" image inspect "localhost/verso-$format-builder:$tag" >/dev/null 2>&1; then
        echo "localhost/verso-$format-builder:$tag"
        return
    fi
    context=$(mktemp -d)
    cp "$0" "$context/verso-packages.sh"
    printf 'FROM %s\nCOPY verso-packages.sh /verso-packages.sh\nRUN bash /verso-packages.sh --builder %s\n' "$base" "$format" \
        > "$context/Containerfile"
    "$engine" build -q --pull=newer -t "localhost/verso-$format-builder:$tag" "$context" >&2
    rm -rf "$context"
    echo "localhost/verso-$format-builder:$tag"
}

# On the build machine: one container for each package.
outside() {
    local out=${1:?usage: linux/packaging/verso-packages.sh OUT_DIR [rpm] [deb]} engine version epoch cargo_home
    shift
    local formats=("$@") format image
    [ ${#formats[@]} -gt 0 ] || formats=(rpm deb)
    for format in "${formats[@]}"; do
        case $format in rpm | deb) ;; *) die "no package format $format (rpm, deb)" ;; esac
    done
    engine=$(command -v podman || command -v docker) || die "podman or docker builds the packages; neither is here"
    version=$(ci/version.sh)
    epoch=$(git log -1 --format=%ct HEAD)
    cargo_home=${CARGO_HOME:-$HOME/.cargo}
    # The builds' place: the tree's, or a fixed one where it is given (VERSO_TARGET_ROOT, the release workflow's cache).
    target_root=${VERSO_TARGET_ROOT:-$PWD/target}
    mkdir -p "$out" "$cargo_home/registry" "$cargo_home/git" "$target_root"
    out=$(cd "$out" && pwd)
    for format in "${formats[@]}"; do
        image=$fedora_image
        [ "$format" = deb ] && image=$ubuntu_image
        image=$(builder_image "$engine" "$format" "$image")
        echo "Verso $version: the $format, in $image"
        # The tree at a fixed path, so the build is the same wherever the checkout is; not relabelled for SELinux.
        "$engine" run --rm --security-opt label=disable \
            -v "$PWD:/src" -v "$out:/out" -v "$cargo_home/registry:/cargo/registry" -v "$cargo_home/git:/cargo/git" \
            -v "$target_root:/target" \
            -w /src \
            -e VERSO_VERSION="$version" -e SOURCE_DATE_EPOCH="$epoch" -e CARGO_HOME=/cargo \
            "$image" linux/packaging/verso-packages.sh --inside "$format" /out
    done
}

# In the distribution's container, as root, from the tree's root.
# What a package is built with, in its distribution: installed into the builder's image once (builder_image), or into
# the container where it has none.
build_packages() {
    case $1 in
        rpm)
            dnf install -y -q --setopt=install_weak_deps=False gcc cargo rust pkgconf-pkg-config gtk4-devel \
                libadwaita-devel libshumate-devel nautilus-devel blueprint-compiler python3 rpm-build binutils findutils
            dnf clean all
            ;;
        deb)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq
            apt-get install -y -qq --no-install-recommends gcc libc6-dev pkg-config cargo rustc libgtk-4-dev \
                libadwaita-1-dev libshumate-dev libnautilus-extension-dev blueprint-compiler python3 dpkg-dev binutils \
                ca-certificates >/dev/null
            rm -rf /var/lib/apt/lists/*
            ;;
        *) die "no package format $1" ;;
    esac
    touch /etc/verso-builder
}

inside() {
    local format=$1 out=$2 version=${VERSO_VERSION:?} work target root extensions licenses
    [ -e /etc/verso-builder ] || build_packages "$format"
    export VERSO_VERSION
    target=/target/package-$format
    # Built as the packages' Verso, which tells of a newer release (ARCHITECTURE.md, "Updates on Linux").
    CARGO_TARGET_DIR=$target cargo build --release --locked --features package -p verso -p verso-service

    work=$(mktemp -d)
    # Where dpkg-shlibdeps looks for a package's files.
    root=$work/debian/verso
    # The launcher in front of the window (it says why on a system whose libraries are too old, as the tarball's does),
    # and the window in /usr/libexec, under its own name, so its process is named `verso`.
    install -D -m 0755 linux/packaging/verso-launcher.sh "$root/usr/bin/verso"
    install -D -m 0755 "$target/release/verso" "$root/usr/libexec/verso"
    install -D -m 0755 "$target/release/verso-service" "$root/usr/bin/verso-service"
    strip "$root/usr/libexec/verso" "$root/usr/bin/verso-service"
    # The user service, which runs the installed service, and the desktop entry, which runs the launcher.
    mkdir -p "$root/usr/lib/systemd/user" "$root/usr/share/applications"
    sed 's|@BINDIR@|/usr/bin|' linux/packaging/systemd/verso.service.in > "$root/usr/lib/systemd/user/verso.service"
    grep -qx 'ExecStart=/usr/bin/verso-service daemon' "$root/usr/lib/systemd/user/verso.service"
    sed 's|@BINDIR@|/usr/bin|' linux/packaging/desktop/dev.hviid.Verso.desktop.in > "$root/usr/share/applications/dev.hviid.Verso.desktop"
    grep -qx 'Exec=/usr/bin/verso %u' "$root/usr/share/applications/dev.hviid.Verso.desktop"
    # The icon theme's icons, and the app's own, with the app icon's 27 other looks, in /usr/share/verso/icons.
    linux/packaging/icons.sh "$root/usr/share/icons/hicolor" "$root/usr/share/verso/icons"
    # The texts in the person's language, where the programs and the Files extension look.
    python3 po/i18n.py mo "$root/usr/share/locale"
    test -f "$root/usr/share/locale/da/LC_MESSAGES/verso.mo"
    # Verso's menu in Files, in C, built against this distribution's Nautilus, in its folder of extensions.
    extensions=$root$(pkg-config --variable=extensiondir libnautilus-extension-4)
    mkdir -p "$extensions"
    linux/files-extension/build.sh "$extensions/libverso-nautilus.so"
    strip --strip-unneeded "$extensions/libverso-nautilus.so"
    for program in "$root/usr/libexec/verso" "$root/usr/bin/verso-service" "$extensions/libverso-nautilus.so"; do
        if ldd "$program" | grep 'not found'; then
            die "$program does not find every library"
        fi
    done
    # A library is executable in Fedora's packages, and not in Debian's.
    [ "$format" = rpm ] || chmod 0644 "$extensions/libverso-nautilus.so"
    # The license, and every crate the two programs link with its license (CREDITS.md), where each format keeps them.
    if [ "$format" = rpm ]; then
        licenses=$root/usr/share/licenses/verso
        install -D -m 0644 LICENSE "$licenses/LICENSE"
    else
        licenses=$root/usr/share/doc/verso
        install -D -m 0644 LICENSE "$licenses/copyright"
    fi
    CARGO_TARGET_DIR=$target python3 linux/packaging/third-party-licenses.py "$licenses/THIRD-PARTY-LICENSES.md" verso verso-service
    chmod 0644 "$licenses/THIRD-PARTY-LICENSES.md"
    find "$root" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +

    # A pre-release's version sorts before its release's with a tilde, in rpm and dpkg alike (1.0.0~beta.1).
    local package_version=${version/-/\~}
    if [ "$format" = rpm ]; then
        rpmbuild -bb --quiet --define "_topdir $work/rpmbuild" --define "pkg_version $package_version" \
            --define "payload $root" linux/packaging/rpm/verso.spec
        cp "$work"/rpmbuild/RPMS/x86_64/verso-*.x86_64.rpm "$out/verso-$version.x86_64.rpm"
        rpm -qp --requires "$out/verso-$version.x86_64.rpm" | grep -v '^rpmlib('
    else
        local shlibs entry name control size entries=() depends=()
        # GNOME 49's libraries or newer (SPEC.md, "Supported versions"), which keep the package off an older system,
        # whatever their symbols say, and the map's library from the version the map needs.
        local -A floors=([libadwaita-1-0]=1.8 [libgtk-4-1]=4.18 [libshumate-1.0-1]=1.4)
        # The libraries the programs and the extension link, at the versions their symbols need, by dpkg's own
        # tool, which wants a source package's control file; where it names one of the floors, the higher counts.
        echo "Source: verso" > "$work/debian/control"
        shlibs=$(cd "$work" && dpkg-shlibdeps -O -edebian/verso/usr/libexec/verso -edebian/verso/usr/bin/verso-service \
            -e"debian/verso${extensions#"$root"}/libverso-nautilus.so" | sed -n 's/^shlibs:Depends=//p')
        IFS=, read -ra entries <<< "$shlibs"
        for entry in "${entries[@]}"; do
            entry=${entry# }
            if [[ $entry =~ ^([^ ]+)\ \(\>=\ ([^\)]+)\)$ ]] && [ -n "${floors[${BASH_REMATCH[1]}]:-}" ]; then
                name=${BASH_REMATCH[1]}
                if dpkg --compare-versions "${BASH_REMATCH[2]}" gt "${floors[$name]}"; then
                    floors[$name]=${BASH_REMATCH[2]}
                fi
            else
                depends+=("$entry")
            fi
        done
        for name in libshumate-1.0-1 libgtk-4-1 libadwaita-1-0; do
            depends=("$name (>= ${floors[$name]})" "${depends[@]}")
        done
        # Verso Drive's mount.
        depends+=(fuse3)
        size=$(du -sk --apparent-size "$root/usr" | cut -f1)
        control=$(< linux/packaging/deb/control.in)
        control=${control//@VERSION@/$package_version}
        control=${control//@SIZE@/$size}
        control=${control//@DEPENDS@/$(printf '%s, ' "${depends[@]}" | sed 's/, $//')}
        mkdir -p "$root/DEBIAN"
        printf '%s\n' "$control" > "$root/DEBIAN/control"
        touch -h -d "@$SOURCE_DATE_EPOCH" "$root/DEBIAN" "$root/DEBIAN/control"
        dpkg-deb --root-owner-group -Zxz --build "$root" "$out/verso_${version}_amd64.deb" >/dev/null
        dpkg-deb --field "$out/verso_${version}_amd64.deb" Depends
    fi
    rm -rf "$work"
}

if [ "${1:-}" = --inside ]; then
    shift
    inside "$@"
elif [ "${1:-}" = --builder ]; then
    build_packages "${2:?}"
else
    outside "$@"
fi
