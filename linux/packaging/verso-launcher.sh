#!/bin/sh
# Verso's launcher, `verso` in the tarball and /usr/bin/verso in the rpm and deb packages (ARCHITECTURE.md,
# "Packaging"). The window, libexec/verso beside it (the tarball) or above it (/usr/libexec/verso), needs GNOME 49's
# libraries, libadwaita 1.8 and GTK 4.18, and binds every symbol as it loads, so on an older system the loader stops it
# before it can say anything, and someone who opened it from the app grid sees nothing. This looks at the libadwaita
# the loader would take first: older or missing, it says why on stderr and, to someone without a terminal, in a dialog
# or a notification, and exits with 1. Otherwise it becomes the window, with the arguments as given (the browser
# sign-in's app.immich: redirect and crosslinks come as the desktop entry's %u).

# Where the requirements are, for someone on an older system.
address=https://github.com/jakobhviid/verso#requirements

# The install's folder, through links: Homebrew links its bin/verso to this file in the Caskroom. The window is in its
# libexec, or, from /usr/bin, in /usr/libexec.
here=$(dirname "$(readlink -f "$0" 2>/dev/null || printf '%s\n' "$0")")
window=$here/libexec/verso
if [ ! -f "$window" ]; then
    window=$(dirname "$here")/libexec/verso
fi

# The library in the first of the folders on standard input, one a line, that holds it.
holding() {
    while IFS= read -r folder; do
        if [ -n "$folder" ] && [ -f "$folder/libadwaita-1.so.0" ]; then
            printf '%s\n' "$folder/libadwaita-1.so.0"
            return
        fi
    done
}

# The libadwaita the loader takes: the first in LD_LIBRARY_PATH, else the one in the loader's cache (ldconfig, which
# may not be on a user's PATH), else one in the usual folders.
library=$(printf '%s\n' "${LD_LIBRARY_PATH-}" | tr ':' '\n' | holding)
if [ -z "$library" ]; then
    for ldconfig in ldconfig /sbin/ldconfig /usr/sbin/ldconfig; do
        if cache=$("$ldconfig" -p 2>/dev/null); then
            library=$(printf '%s\n' "$cache" | sed -n 's/^[[:space:]]*libadwaita-1\.so\.0 (.*x86-64.*) => //p' |
                head -n 1)
            break
        fi
    done
fi
if [ -z "$library" ]; then
    library=$(printf '%s\n' /usr/lib64 /usr/lib/x86_64-linux-gnu /lib64 /lib/x86_64-linux-gnu /usr/lib /lib | holding)
fi

# New enough: it has a function libadwaita 1.8 added, whose name is a string in the library's table of symbols.
if [ -n "$library" ] && LC_ALL=C grep -q adw_shortcuts_dialog_new "$library" 2>/dev/null; then
    exec "$window" "$@"
fi

needs="Verso needs GNOME 49 or newer (libadwaita 1.8 and GTK 4.18)"
if [ -n "$library" ]; then
    reason="$needs, and this system's libraries are older."
else
    reason="$needs, and this system has no libadwaita."
fi
systems="New enough: Fedora 43 and newer, Ubuntu 25.10 and 26.04 LTS, Debian 14, Arch and other rolling distributions."
flatpak="Verso's Flatpak (verso-x86_64.flatpak) and its AppImage (verso-x86_64.AppImage), on its releases page, run on this system, without Verso Drive."
printf 'error: %s\n%s\n%s\nSee %s\n' "$reason" "$systems" "$flatpak" "$address" >&2
if [ -n "$library" ]; then
    printf 'The libadwaita it would load: %s\n' "$library" >&2
fi

# Opened without a terminal (the app grid, a launcher), stderr goes unseen: a dialog where zenity is, which returns 0
# or 1 once closed, else a notification that stays until dismissed.
if [ ! -t 2 ] && [ -n "${WAYLAND_DISPLAY-}${DISPLAY-}" ]; then
    title="Verso cannot start"
    body=$(printf '%s\n\n%s\n\n%s\n\n%s' "$reason" "$systems" "$flatpak" "$address")
    shown=127
    if command -v zenity >/dev/null 2>&1; then
        zenity --error --title="$title" --width=480 --text="$body" 2>/dev/null
        shown=$?
    fi
    if [ "$shown" -gt 1 ]; then
        notify-send --app-name=Verso --icon=dev.hviid.Verso --urgency=critical "$title" "$body" 2>/dev/null ||
            gdbus call --session --dest=org.freedesktop.Notifications --object-path=/org/freedesktop/Notifications \
                --method=org.freedesktop.Notifications.Notify '"Verso"' 0 '"dev.hviid.Verso"' "\"$title\"" \
                "\"$body\"" '[]' "{'urgency': <byte 2>}" 0 >/dev/null 2>&1
    fi
fi
exit 1
