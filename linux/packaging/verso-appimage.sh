#!/bin/bash
# Build Verso's AppImage for x86_64 Linux into OUT_DIR (ARCHITECTURE.md, "Verso as an AppImage"): the window and the
# service built with the `appimage` feature, which leaves out Verso Drive as the Flatpak does, and every library they
# need, the C library and its loader included, so it runs on systems older than the Fedora 44 it is built on, down to
# Ubuntu 24.04. The graphics drivers stay the system's. Run in the Fedora 44 toolbox, from the repository's root, as the
# tarball is (linux/packaging/verso-tarball.sh):
#
#   linux/packaging/verso-appimage.sh OUT_DIR
#
# Makes OUT_DIR/verso-x86_64.AppImage, and beside it verso-x86_64.AppImage.zsync for AppImage updaters (AppImageUpdate)
# where `zsyncmake` is installed (Fedora's `zsync`). The two tools it packs with are downloaded once into a cache
# outside the repository (VERSO_TOOLS, else ~/.cache/verso-appimage), at the versions and checksums pinned below.
set -euo pipefail
out=${1:?usage: linux/packaging/verso-appimage.sh OUT_DIR}

# appimagetool, the AppImage project's, which packs an AppDir; its runtime, which the AppImage starts with and which
# mounts it through the system's FUSE 3 (`fusermount3`, the one Ubuntu 24.04 has), or runs it unpacked
# (`--appimage-extract-and-run`) where there is no FUSE.
tool_version=1.9.1
tool_sha256=ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0
runtime_version=20251108
runtime_sha256=2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d
# Where an updater finds the next one: the latest release's zsync file.
update_information='gh-releases-zsync|jakobhviid|verso|latest|verso-x86_64.AppImage.zsync'

# The libraries the system provides, which a bundled copy would only get in the way of: the graphics stack, whose
# drivers (Mesa's, NVIDIA's) are the system's and are loaded through these.
excluded='^(libGL|libGLX|libGLdispatch|libEGL|libOpenGL|libGLESv1_CM|libGLESv2|libgbm|libdrm|libvulkan|libnvidia|libcuda|libglapi)[.-]'

# GStreamer's plugins for the viewer's video, from the distribution's own (VP8 and VP9, AV1 and the open containers:
# nothing patent-encumbered, such as H.264, which Fedora does not carry).
plugins=(coreelements playback typefindfunctions app audioconvert audioresample audioparsers volume videoconvertscale
    videorate videofilter videobox opengl isomp4 matroska ogg vorbis opus theora vpx flac mpg123 id3demux wavparse
    autodetect pulseaudio gdkpixbuf)

die() {
    echo "verso-appimage.sh: $*" >&2
    exit 1
}

tools=${VERSO_TOOLS:-${XDG_CACHE_HOME:-$HOME/.cache}/verso-appimage}

# Fetch URL into the cache as NAME, once, and only as the checksum says it is.
fetch() {
    local url=$1 sha256=$2 name=$3
    mkdir -p "$tools"
    if [ ! -f "$tools/$name" ] || [ "$(sha256sum "$tools/$name" | cut -d' ' -f1)" != "$sha256" ]; then
        echo "Fetching $name"
        curl -fsSL --retry 3 -o "$tools/$name.part" "$url"
        [ "$(sha256sum "$tools/$name.part" | cut -d' ' -f1)" = "$sha256" ] || die "$name from $url is not the one pinned here"
        mv "$tools/$name.part" "$tools/$name"
    fi
    chmod +x "$tools/$name"
}
fetch "https://github.com/AppImage/appimagetool/releases/download/$tool_version/appimagetool-x86_64.AppImage" \
    "$tool_sha256" "appimagetool-$tool_version-x86_64.AppImage"
fetch "https://github.com/AppImage/type2-runtime/releases/download/$runtime_version/runtime-x86_64" \
    "$runtime_sha256" "runtime-$runtime_version-x86_64"

# The version it is released as, built in (`verso_core::product::VERSION`).
VERSO_VERSION=$(ci/version.sh)
export VERSO_VERSION
# The programs a release built once for Fedora's files (VERSO_BINARIES, a folder with verso and verso-service;
# ARCHITECTURE.md, "One build for Fedora's files"), which tell they are the AppImage's from where they run; else built here.
if [ -n "${VERSO_BINARIES:-}" ]; then
    target=$(mktemp -d)
    mkdir -p "$target/release"
    cp "$VERSO_BINARIES/verso" "$VERSO_BINARIES/verso-service" "$target/release/"
else
    target=${VERSO_TARGET_ROOT:-$PWD/target}/appimage
    CARGO_TARGET_DIR=$target cargo build --release --locked -p verso -p verso-service
fi

mkdir -p "$out"
out=$(cd "$out" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
stage=$work/AppDir
mkdir -p "$stage/usr/bin" "$stage/usr/libexec" "$stage/usr/lib/gio/modules" "$stage/usr/lib/gstreamer-1.0" "$stage/usr/share"
# The programs, in libexec/, run by the bundled loader (AppRun); `usr/bin/verso` and `usr/bin/verso-service` are links
# to AppRun, so a program run from inside the AppImage runs through it too.
cp "$target/release/verso" "$target/release/verso-service" "$stage/usr/libexec/"
strip "$stage/usr/libexec/verso" "$stage/usr/libexec/verso-service"
install -m 0755 linux/packaging/appimage/AppRun "$stage/AppRun"
ln -s ../../AppRun "$stage/usr/bin/verso"
ln -s ../../AppRun "$stage/usr/bin/verso-service"

# The modules GLib loads at run time: the settings backend (the desktop's dark style and the like) and TLS (the map's tiles).
modules=(libdconfsettings.so libgiognutls.so)
for module in "${modules[@]}"; do
    cp -L "/usr/lib64/gio/modules/$module" "$stage/usr/lib/gio/modules/"
done
for plugin in "${plugins[@]}"; do
    cp -L "/usr/lib64/gstreamer-1.0/libgst$plugin.so" "$stage/usr/lib/gstreamer-1.0/"
done

# Every library they link, whole: `ldd` lists a program's libraries with theirs, the loader among them. Each goes in
# under the name the program asks for.
: > "$work/bundled"
for elf in "$stage"/usr/libexec/verso* "$stage"/usr/lib/gio/modules/*.so "$stage"/usr/lib/gstreamer-1.0/*.so; do
    listing=$(ldd "$elf")
    if grep -q 'not found' <<<"$listing"; then
        die "$elf does not find every library: $(grep 'not found' <<<"$listing" | tr -d '\t' | tr '\n' ' ')"
    fi
    while read -r name path; do
        [[ $name =~ $excluded ]] && continue
        [ -e "$stage/usr/lib/$name" ] || { cp -L "$path" "$stage/usr/lib/$name" && echo "$path" >> "$work/bundled"; }
    done < <(awk '$2 == "=>" && $3 ~ /^\// { print $1, $3 } $1 ~ /^\/.*ld-linux/ { n = split($1, parts, "/"); print parts[n], $1 }' <<<"$listing")
done
test -f "$stage/usr/lib/ld-linux-x86-64.so.2"
test -f "$stage/usr/lib/libc.so.6"
for library in "$stage"/usr/lib/*.so* "$stage"/usr/lib/gio/modules/*.so "$stage"/usr/lib/gstreamer-1.0/*.so; do
    case $library in */ld-linux-*) ;; *) strip --strip-unneeded "$library" 2>/dev/null || true ;; esac
done

# The licenses of what is bundled, where the distribution keeps them.
mkdir -p "$stage/usr/share/licenses"
sort -u "$work/bundled" | xargs rpm -qf --qf '%{NAME}\n' | sort -u | while read -r package; do
    if [ -d "/usr/share/licenses/$package" ]; then
        cp -r "/usr/share/licenses/$package" "$stage/usr/share/licenses/"
    fi
done
install -m 0644 LICENSE "$stage/usr/share/licenses/verso-LICENSE"
python3 linux/packaging/third-party-licenses.py "$stage/usr/share/licenses/THIRD-PARTY-LICENSES.md" verso verso-service
cat > "$stage/usr/share/licenses/README" <<EOF
The libraries in this AppImage are Fedora 44's, unchanged, each under the license in its folder here; Fedora's source
packages are at https://src.fedoraproject.org, and Verso's at https://github.com/jakobhviid/verso. THIRD-PARTY-LICENSES.md
lists the Rust crates Verso's programs link.
EOF

# The schemas GTK and libadwaita read, and the icons: Verso's own (the window's, the top bar's), hicolor's index, which
# lets GTK take Verso's icons for the theme's, and Adwaita's, the symbolic ones the interface draws.
mkdir -p "$stage/usr/share/glib-2.0/schemas"
cp /usr/share/glib-2.0/schemas/gschemas.compiled "$stage/usr/share/glib-2.0/schemas/"
linux/packaging/icons.sh "$stage/usr/share/icons/hicolor" "$stage/usr/share/verso/icons"
cp /usr/share/icons/hicolor/index.theme "$stage/usr/share/icons/hicolor/"
mkdir -p "$stage/usr/share/icons/Adwaita"
(cd /usr/share/icons/Adwaita && tar cf - --exclude=./cursors .) | (cd "$stage/usr/share/icons/Adwaita" && tar xf -)
# The service's, the top bar's and Preferences' texts in the person's language.
python3 po/i18n.py mo "$stage/usr/share/locale"
test -f "$stage/usr/share/locale/da/LC_MESSAGES/verso.mo"
# The entry, which AppImage tools read, and its icon.
install -m 0644 linux/packaging/appimage/dev.hviid.Verso.desktop "$stage/dev.hviid.Verso.desktop"
cp linux/packaging/icons/hicolor/256/dev.hviid.Verso.png "$stage/dev.hviid.Verso.png"
ln -s dev.hviid.Verso.png "$stage/.DirIcon"

# Pack it, with the update information and its zsync file where `zsyncmake` is here.
image=$out/verso-x86_64.AppImage
rm -f "$image" "$image.zsync"
packing=(--runtime-file "$tools/runtime-$runtime_version-x86_64" --no-appstream)
if command -v zsyncmake >/dev/null; then
    packing+=(--updateinformation "$update_information")
else
    echo "No zsyncmake here (Fedora's zsync): the AppImage is made without update information"
fi
(cd "$out" && ARCH=x86_64 APPIMAGE_EXTRACT_AND_RUN=1 "$tools/appimagetool-$tool_version-x86_64.AppImage" "${packing[@]}" "$stage" "$image")
test -x "$image"
echo "Verso $VERSO_VERSION"
(cd "$out" && sha256sum verso-x86_64.AppImage*)
