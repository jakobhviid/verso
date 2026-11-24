#!/bin/sh
# Install Verso's icons (ARCHITECTURE.md, "Packaging"), for the tarball (verso-tarball.sh) and the rpm and deb packages
# (verso-packages.sh) alike: the icon theme's into THEME, a hicolor folder, and the app's own into OWN, where its
# programs look for them (`verso_linux::app_icon::icon_folders`). Run from the repository's root:
# linux/packaging/icons.sh THEME OWN
set -eu
theme=${1:?usage: linux/packaging/icons.sh THEME OWN}
own=${2:?usage: linux/packaging/icons.sh THEME OWN}
icons=linux/packaging/icons
# Verso's icon, the print, at the sizes the icon theme wants, edge to edge as Linux shows icons
# (`linux/packaging/icons/linux-app-icon.py` makes them from `dev.hviid.Verso.svg`), Verso Drive's with its badge, and the
# symbolic one, with the top bar's states.
for size in 16 32 64 128 256 512; do
    for icon in dev.hviid.Verso dev.hviid.Verso.Drive; do
        install -D -m 0644 "$icons/hicolor/$size/$icon.png" "$theme/${size}x${size}/apps/$icon.png"
    done
done
install -D -m 0644 "$icons/dev.hviid.Verso-symbolic.svg" "$theme/symbolic/apps/dev.hviid.Verso-symbolic.svg"
# The top bar icon's states: in the desktop's one colour, and in colour (`tray.colour`).
for state in unmounted offline signed-out; do
    install -D -m 0644 "$icons/dev.hviid.Verso-$state-symbolic.svg" "$theme/symbolic/apps/dev.hviid.Verso-$state-symbolic.svg"
done
for icon in dev.hviid.Verso-tray dev.hviid.Verso-tray-unmounted dev.hviid.Verso-tray-offline dev.hviid.Verso-tray-signed-out; do
    install -D -m 0644 "$icons/$icon.svg" "$theme/scalable/apps/$icon.svg"
done
# The app's own icons: its own, its mark (Verso Drive's page in Preferences), the app icon for its windows wherever the
# theme has none, and the app icon's 27 other looks (`app.icon`, `app.icon_dark`), which the windows show and the
# launcher's entry names a copy of (`verso_linux::app_icon`).
mkdir -p "$own"
for icon in "$icons"/verso-*-symbolic.svg "$icons/dev.hviid.Verso-symbolic.svg" "$icons/dev.hviid.Verso.png"; do
    install -m 0644 "$icon" "$own/"
done
for design in mist sand dark paper frame slate sky; do
    for look in "$design" "$design-night" "$design-graphite" "$design-night-graphite"; do
        if [ "$look" != mist ]; then
            install -m 0644 "$icons/dev.hviid.Verso-$look.svg" "$own/"
        fi
    done
done
test "$(ls "$own"/dev.hviid.Verso-*.svg | grep -cv symbolic)" -eq 27
