#!/bin/bash
# Build Verso's evaluation tarball for x86_64 Linux into OUT_DIR: the launcher (`verso`, from verso-launcher.sh), which
# runs the window (`libexec/verso`), or says why not on a system whose GNOME libraries are too old; the window, which
# finds the libraries a desktop may lack (libshumate, libprotobuf-c) beside it in libexec/lib/; the tray and the drive
# (`verso-service`); the icons; and the desktop entry made from the template, so the browser sign-in's redirect and
# crosslink links reach the app. Run in the Fedora toolbox, from the repository's root:
# linux/packaging/verso-tarball.sh OUT_DIR
set -euo pipefail
out=${1:?usage: linux/packaging/verso-tarball.sh OUT_DIR}
# The version it is released as, built in (`verso_core::product::VERSION`).
VERSO_VERSION=$(ci/version.sh)
export VERSO_VERSION
# A fixed place for the build where one is given (VERSO_TARGET_ROOT, the release workflow's cache), else the tree's.
target=${VERSO_TARGET_ROOT:-$PWD/target}/package
CARGO_TARGET_DIR=$target RUSTFLAGS='-C link-arg=-Wl,--disable-new-dtags,-rpath,$ORIGIN/lib' \
    cargo build --release -p verso -p verso-service
stage=$out/verso
rm -rf "$stage"
mkdir -p "$stage/libexec/lib"
# The window behind its launcher, under its own name, so its process is named `verso`; its run path, `$ORIGIN/lib`, is
# its own folder's lib/.
cp "$target/release/verso" "$stage/libexec/verso"
install -m 0755 linux/packaging/verso-launcher.sh "$stage/verso"
cp "$target/release/verso-service" "$stage/verso-service"
strip "$stage/libexec/verso" "$stage/verso-service"
cp -L /usr/lib64/libshumate-1.0.so.1 /usr/lib64/libprotobuf-c.so.1 "$stage/libexec/lib/"
# The icon theme's icons in hicolor/, and the app's own, with the app icon's 27 other looks, in icons/, which the
# programs find in the install's folder.
linux/packaging/icons.sh "$stage/hicolor" "$stage/icons"
# The service's, the top bar's and Preferences' texts in the person's language: the catalogs compiled where the
# programs look for them, `share/locale` beside them (`verso_linux::i18n::locale_directory`).
python3 po/i18n.py mo "$stage/share/locale"
test -f "$stage/share/locale/da/LC_MESSAGES/verso.mo"
# Exec by name: the cask writes its own path in, keeping the %u that hands the app the link it was opened with.
sed 's|@BINDIR@/||' linux/packaging/desktop/dev.hviid.Verso.desktop.in > "$stage/dev.hviid.Verso.desktop"
grep -qx 'Exec=verso %u' "$stage/dev.hviid.Verso.desktop"
grep -q '^MimeType=x-scheme-handler/app.immich;' "$stage/dev.hviid.Verso.desktop"
for program in libexec/verso verso-service; do
    if ldd "$stage/$program" | grep -E 'not found'; then
        exit 1
    fi
done
# Verso Drive's menu in Files (Open in Immich, Copy Immich Link, Show in *app*), which nautilus-python loads.
cp linux/files-extension/verso-nautilus.py "$stage/verso-nautilus.py"
# Our notices for code taken from others, then every crate the two programs link, with its license (CREDITS.md).
python3 linux/packaging/third-party-licenses.py "$stage/THIRD-PARTY-LICENSES.md" verso verso-service
cd "$out"
tar czf verso-x86_64.tar.gz verso
echo "Verso $VERSO_VERSION"
sha256sum verso-x86_64.tar.gz
