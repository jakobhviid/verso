#!/bin/sh
# In a throwaway container, as root: run the Verso AppImage in /root/packages on this system (Ubuntu 24.04, whose GNOME
# libraries are too old for the tarball and the packages, which the AppImage carries its own of), check it, and leave
# nothing to remove: an AppImage installs nothing. The last line is the verdict; the exit code is the result.
#
#   Checked: it says its version and is built as the AppImage's Verso (no drive, no look for a release); `doctor
#   --json` answers; the window starts and keeps running under a headless Wayland compositor, which loads the bundled
#   GTK and libadwaita over the system's older ones; the service starts as an AppImage of its own and takes the
#   session bus name; the programs run from inside the AppImage (`usr/bin/verso-service`) through its loader; and,
#   with /root/server.env (IMMICH_URL and IMMICH_KEY, a read-only API key), it signs in, keeps the sign-in in the
#   session's keyring (GNOME Keyring, the Secret Service), has the window start the service and name the file in the
#   autostart entry where it is now, and signs out, which takes the sign-in and the entry away.
#   The AppImage runs unpacked (`APPIMAGE_EXTRACT_AND_RUN`): the container has no FUSE.
set -u
. /etc/os-release
fail() { echo "FAIL: $*"; exit 1; }
cd /root/packages || fail "no /root/packages"
image=/root/packages/verso-x86_64.AppImage
[ -f "$image" ] || fail "no verso-x86_64.AppImage in /root/packages"
chmod +x "$image"
export APPIMAGE_EXTRACT_AND_RUN=1 HOME=/root
verso() { "$image" "$@"; }

export DEBIAN_FRONTEND=noninteractive
apt-get -qq update >/dev/null
# What a GNOME desktop has and a bare container lacks: a compositor, a session bus, and a keyring.
apt-get -y -qq install weston dbus-daemon dbus-user-session gnome-keyring libsecret-tools libglib2.0-bin procps >/tmp/apt.log 2>&1 ||
  fail "could not install weston and the keyring: $(tail -1 /tmp/apt.log)"
# An older system than the build's: the libraries the AppImage must bring are not here.
glibc=$(ldd --version | head -n 1 | grep -o '[0-9]*\.[0-9]*$')
[ "$glibc" = 2.39 ] || echo "note: glibc $glibc here, not Ubuntu 24.04's 2.39"

version=$(verso verso-service --version 2>/tmp/version.err | awk '{print $2}')
[ -n "$version" ] || fail "verso-service --version printed nothing: $(tail -1 /tmp/version.err)"
[ "$(verso verso-service configure get updates.check 2>/dev/null)" = false ] || fail "updates.check is not off"
[ "$(verso verso-service configure get mount.enabled 2>/dev/null)" = false ] || fail "mount.enabled is not off"
verso verso-service doctor --json 2>/dev/null | head -c 1 | grep -q '{' || fail "doctor --json printed no JSON"

# Unpacked, to see what it holds: the programs, run through the loader it carries, and its own libraries.
(cd /root && "$image" --appimage-extract >/dev/null 2>&1) || fail "could not unpack the AppImage"
appdir=/root/squashfs-root
[ -x "$appdir/usr/bin/verso-service" ] || fail "no usr/bin/verso-service"
"$appdir/usr/bin/verso-service" --version >/dev/null 2>&1 || fail "usr/bin/verso-service does not run on its own"
[ -f "$appdir/usr/lib/ld-linux-x86-64.so.2" ] || fail "no bundled loader"
[ -f "$appdir/usr/lib/libgtk-4.so.1" ] || fail "no bundled GTK"
[ ! -e "$appdir/usr/lib/libGL.so.1" ] && [ ! -e "$appdir/usr/lib/libEGL.so.1" ] || fail "the graphics libraries are bundled"
size=$(du -sm "$image" | cut -f1)

mkdir -p /tmp/runtime && chmod 700 /tmp/runtime
export XDG_RUNTIME_DIR=/tmp/runtime
weston --backend=headless --socket=wayland-test >/tmp/weston.log 2>&1 &
weston=$!
for attempt in $(seq 20); do [ -S /tmp/runtime/wayland-test ] && break; sleep 0.5; done
[ -S /tmp/runtime/wayland-test ] || fail "no headless compositor: $(tail -1 /tmp/weston.log)"
export WAYLAND_DISPLAY=wayland-test

# The window, signed out, starts and is still running after 10 seconds: the bundled libraries loaded and its interface
# came up on a system older than the build's.
dbus-run-session -- timeout 10 "$image" >/tmp/window.log 2>&1
[ $? = 124 ] || fail "the window stopped at once: $(grep -v '^$' /tmp/window.log | tail -2 | tr '\n' ' ')"
grep -qi "version .* not found\|cannot open shared object\|symbol lookup error" /tmp/window.log &&
  fail "the window complained of a library: $(grep -i 'not found\|cannot open\|symbol lookup' /tmp/window.log | head -1)"

signed_in=
if [ -f /root/server.env ]; then
  . /root/server.env
  # One session bus with GNOME Keyring unlocked on it, as a desktop login has; the sign-in goes in it, is read back
  # through the service, and goes with the sign-out.
  cat >/tmp/signed-in.sh <<'INNER'
. /root/server.env
image=/root/packages/verso-x86_64.AppImage
eval "$(printf '\n' | gnome-keyring-daemon --unlock --components=secrets 2>/dev/null)"
printf '%s' "$IMMICH_KEY" | "$image" verso-service login --server "$IMMICH_URL" --api-key >/tmp/login.log 2>&1 || { echo "login: $(tail -1 /tmp/login.log)"; exit 1; }
"$image" verso-service status --json >/tmp/status.json 2>&1 || { echo "status: $(tail -1 /tmp/status.json)"; exit 1; }
# The credential is in the keyring (the Secret Service), not in a file.
secret-tool search --all application dev.hviid.Verso >/tmp/secret.log 2>&1
grep -q 'dev.hviid.Verso' /tmp/secret.log || { echo "the sign-in is not in the keyring: $(tail -1 /tmp/secret.log)"; exit 1; }
[ ! -e /root/.config/verso/credential ] || { echo "a credential file was written beside the keyring"; exit 1; }
# An autostart entry written when the file was somewhere else: the window names the file where it is now.
mkdir -p /root/.config/autostart
printf '[Desktop Entry]\nType=Application\nName=Verso\nExec="/old/place/Verso.AppImage" verso-service daemon\n' >/root/.config/autostart/dev.hviid.Verso.Service.desktop
# The window starts the service, which takes its name on the bus, as an AppImage of its own.
timeout 25 "$image" >/tmp/window2.log 2>&1 &
for attempt in $(seq 20); do
  gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus --method org.freedesktop.DBus.NameHasOwner dev.hviid.Verso.Daemon 2>/dev/null | grep -q true && break
  sleep 1
done
gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus --method org.freedesktop.DBus.NameHasOwner dev.hviid.Verso.Daemon | grep -q true || { echo "the window did not start the service: $(tail -2 /tmp/window2.log | tr '\n' ' ')"; exit 1; }
[ "$(pgrep -fc 'verso-service daemon')" -ge 1 ] || { echo "no service process"; exit 1; }
grep -qx "Exec=\"$image\" verso-service daemon" /root/.config/autostart/dev.hviid.Verso.Service.desktop ||
  { echo "the autostart entry does not name the file: $(grep ^Exec= /root/.config/autostart/dev.hviid.Verso.Service.desktop)"; exit 1; }
"$image" verso-service logout >/tmp/logout.log 2>&1 || { echo "logout: $(tail -1 /tmp/logout.log)"; exit 1; }
secret-tool search --all application dev.hviid.Verso 2>&1 | grep -q 'dev.hviid.Verso' && { echo "the sign-in is still in the keyring"; exit 1; }
[ ! -e /root/.config/autostart/dev.hviid.Verso.Service.desktop ] || { echo "the autostart entry is still there after logout"; exit 1; }
exit 0
INNER
  dbus-run-session -- sh /tmp/signed-in.sh >/tmp/signed-in.out 2>&1 || fail "$(tail -2 /tmp/signed-in.out | tr '\n' ' ')"
  signed_in=", signed in to the lab server with the sign-in in the keyring, the service started by the window, the autostart entry kept current, signed out"
fi
kill "$weston" 2>/dev/null
echo "ok: $version on $PRETTY_NAME (glibc $glibc), ${size} MB, window started, doctor answered${signed_in}"
