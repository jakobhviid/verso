#!/bin/sh
# In a throwaway container, as root: install the Verso package in /root/packages that fits this system (the rpm with
# dnf, the deb with apt), check it, and remove it again. On a system too old for it (SPEC.md, "Supported versions") the
# package must be refused, and its launcher, unpacked, must say why. The last line is the verdict; the exit code is the
# result.
#
#   Checked where it installs: `verso-service --version` says the package's version; every file is in its place; the
#   window and the service find every library, and the launcher hands on to the window (`verso --probe`); the window
#   starts and keeps running under a headless Wayland compositor; `doctor --json` answers; it removes cleanly.
#   With /root/server.env (IMMICH_URL and IMMICH_KEY, a read-only API key), it also signs in, switches Verso Drive on,
#   mounts it as root, and checks originals read through it against Immich's own checksums.
set -u
. /etc/os-release
fail() { echo "FAIL: $*"; exit 1; }
cd /root/packages || fail "no /root/packages"
if command -v dnf >/dev/null; then
  package=$(ls verso-*.x86_64.rpm 2>/dev/null | head -n 1)
  expected=$(printf '%s\n' "$package" | sed 's/^verso-\(.*\)\.x86_64\.rpm$/\1/')
  install_quietly() { dnf -y -q install "$@" >/dev/null 2>&1; }
  install_package() { dnf -y install "./$package" >/tmp/install.log 2>&1; }
  remove_package() { dnf -y -q remove verso >/tmp/remove.log 2>&1; }
  unpack() { install_quietly cpio && mkdir -p "$1" && rpm2cpio "$package" | (cd "$1" && cpio -idm --quiet); }
  installed() { rpm -q verso >/dev/null 2>&1; }
elif command -v apt-get >/dev/null; then
  package=$(ls verso_*_amd64.deb 2>/dev/null | head -n 1)
  expected=$(printf '%s\n' "$package" | sed 's/^verso_\(.*\)_amd64\.deb$/\1/')
  export DEBIAN_FRONTEND=noninteractive
  apt-get -qq update >/dev/null
  install_quietly() { apt-get -y -qq install "$@" >/dev/null 2>&1; }
  install_package() { apt-get -y install "./$package" >/tmp/install.log 2>&1; }
  remove_package() { apt-get -y -qq purge verso >/tmp/remove.log 2>&1; }
  unpack() { dpkg-deb -x "$package" "$1"; }
  installed() { dpkg-query -W -f='${Status}' verso 2>/dev/null | grep -q 'install ok installed'; }
else
  fail "no dnf or apt-get"
fi
[ -n "$package" ] || fail "no package for this system in /root/packages"

# Too old: GNOME 48's libraries or older, where the package must not install.
case "$ID/${VERSION_ID:-}" in
  ubuntu/24.04 | ubuntu/24.10 | ubuntu/25.04 | debian/13 | fedora/42) too_old=yes ;;
  *) too_old= ;;
esac
needs="Verso needs GNOME 49 or newer (libadwaita 1.8 and GTK 4.18)"
if [ -n "$too_old" ]; then
  install_package && fail "it installed on $PRETTY_NAME"
  installed && fail "the refused package is installed all the same"
  grep -q 'libadwaita' /tmp/install.log || fail "refused, but not for libadwaita: $(tail -3 /tmp/install.log | tr '\n' ' ')"
  # Its launcher, unpacked: without libadwaita, then with this system's.
  unpack /tmp/unpacked || fail "could not unpack $package"
  /tmp/unpacked/usr/bin/verso >/tmp/launcher.out 2>/tmp/launcher.err
  [ $? = 1 ] || fail "the launcher did not exit with 1 without libadwaita"
  grep -qx "error: $needs, and this system has no libadwaita." /tmp/launcher.err || fail "the launcher said: $(head -1 /tmp/launcher.err)"
  if command -v dnf >/dev/null; then install_quietly libadwaita; else install_quietly libadwaita-1-0; fi ||
    fail "could not install this system's libadwaita"
  /tmp/unpacked/usr/bin/verso >/tmp/launcher.out 2>/tmp/launcher.err
  [ $? = 1 ] || fail "the launcher did not exit with 1 on this system's libadwaita"
  grep -qx "error: $needs, and this system's libraries are older." /tmp/launcher.err ||
    fail "the launcher said: $(head -1 /tmp/launcher.err)"
  found=$(sed -n 's/^The libadwaita it would load: //p' /tmp/launcher.err)
  echo "ok: $expected refused (needs libadwaita 1.8), and its launcher says why ($found)"
  exit 0
fi

install_package || fail "install: $(tail -3 /tmp/install.log | tr '\n' ' ')"
installed || fail "installed, but the package database does not list it"
version=$(verso-service --version | awk '{print $2}')
[ "$version" = "$expected" ] || fail "--version says $version, the package $expected"

# Every file in its place.
for file in /usr/bin/verso /usr/bin/verso-service /usr/libexec/verso; do
  [ -x "$file" ] || fail "no $file"
done
grep -qx 'ExecStart=/usr/bin/verso-service daemon' /usr/lib/systemd/user/verso.service || fail "no user unit running /usr/bin/verso-service"
grep -qx 'Exec=/usr/bin/verso %u' /usr/share/applications/dev.hviid.Verso.desktop || fail "no desktop entry running /usr/bin/verso"
[ -f /usr/share/icons/hicolor/512x512/apps/dev.hviid.Verso.png ] || fail "no app icon in the icon theme"
[ -f /usr/share/icons/hicolor/symbolic/apps/dev.hviid.Verso-offline-symbolic.svg ] || fail "no top bar icon"
looks=$(ls /usr/share/verso/icons/dev.hviid.Verso-*.svg 2>/dev/null | grep -cv symbolic)
[ "$looks" = 27 ] || fail "$looks of the app icon's 27 other looks"
[ -f /usr/share/locale/da/LC_MESSAGES/verso.mo ] || fail "no translations"
extension=$(find /usr/lib /usr/lib64 -path '*/nautilus/extensions-4/libverso-nautilus.so' 2>/dev/null | head -n 1)
[ -n "$extension" ] || fail "no Files extension"
grep -q "x-scheme-handler/app.immich" /usr/share/applications/mimeinfo.cache 2>/dev/null || fail "app.immich is not registered"
for license in /usr/share/licenses/verso/THIRD-PARTY-LICENSES.md /usr/share/doc/verso/THIRD-PARTY-LICENSES.md; do
  [ -f "$license" ] && break
done
[ -f "$license" ] || fail "no third-party licenses"

# Every library found, and the launcher hands on to the window: the loader binds every symbol of the window before
# its main, which then leaves at once.
for program in /usr/libexec/verso /usr/bin/verso-service "$extension"; do
  missing=$(ldd "$program" | grep -c "not found")
  [ "$missing" = 0 ] || fail "$program misses $missing libraries"
done
verso --probe >/tmp/probe.log 2>&1 || fail "the launcher or the window stopped: $(tail -1 /tmp/probe.log)"
verso-service doctor --json 2>/dev/null | head -c 1 | grep -q '{' || fail "doctor --json printed no JSON"

# The window starts under a headless Wayland compositor with a session bus, and is still running after 10 seconds:
# its interface and libraries loaded.
if command -v dnf >/dev/null; then install_quietly weston dbus-daemon; else install_quietly weston dbus-daemon; fi ||
  fail "could not install weston"
mkdir -p /tmp/runtime && chmod 700 /tmp/runtime
XDG_RUNTIME_DIR=/tmp/runtime weston --backend=headless --socket=wayland-test >/tmp/weston.log 2>&1 &
weston=$!
for attempt in $(seq 20); do [ -S /tmp/runtime/wayland-test ] && break; sleep 0.5; done
XDG_RUNTIME_DIR=/tmp/runtime WAYLAND_DISPLAY=wayland-test dbus-run-session -- timeout 10 verso >/tmp/window.log 2>&1
[ $? = 124 ] || fail "the window stopped at once: $(tail -1 /tmp/window.log)"
kill "$weston" 2>/dev/null

mounted=
if [ -f /root/server.env ]; then
  . /root/server.env
  export HOME=/root
  command -v curl >/dev/null || install_quietly curl
  printf '%s' "$IMMICH_KEY" | verso-service login --server "$IMMICH_URL" --api-key >/tmp/login.log 2>&1 ||
    fail "login: $(tail -1 /tmp/login.log)"
  mkdir -p /root/Verso
  verso-service configure set mount.path /root/Verso >/dev/null || fail "configure mount.path"
  verso-service configure set mount.enabled true >/dev/null || fail "configure mount.enabled"
  verso-service daemon >/tmp/daemon.log 2>&1 &
  daemon=$!
  for attempt in $(seq 30); do grep -q " /root/Verso fuse" /proc/mounts && break; sleep 1; done
  grep -q " /root/Verso fuse" /proc/mounts || fail "not mounted: $(tail -2 /tmp/daemon.log | tr '\n' ' ')"
  # Immich's SHA-1 of every original, from base64 to hex.
  curl -s -m 30 -H "x-api-key: $IMMICH_KEY" -H "content-type: application/json" -d '{"size":1000}' \
    "$IMMICH_URL/api/search/metadata" | grep -o '"checksum":"[^"]*"' | cut -d'"' -f4 |
    while read -r checksum; do printf '%s' "$checksum" | base64 -d | od -An -tx1 | tr -d ' \n'; echo; done >/tmp/checksums
  [ -s /tmp/checksums ] || fail "no checksums from the server"
  find /root/Verso/Photos -type f | head -n 5 >/tmp/files
  checked=0
  while IFS= read -r file; do
    grep -qx "$(sha1sum "$file" | cut -d' ' -f1)" /tmp/checksums || fail "$file does not match any original on the server"
    checked=$((checked + 1))
  done </tmp/files
  [ "$checked" -gt 0 ] || fail "no file under Photos"
  verso-service unmount >/tmp/unmount.log 2>&1 || fail "unmount: $(tail -1 /tmp/unmount.log)"
  grep -q " /root/Verso fuse" /proc/mounts && fail "still mounted after unmount"
  # Unmounted, the service goes on without the drive; it stops as a logout stops it.
  kill -TERM "$daemon" 2>/dev/null
  wait "$daemon"
  mounted=", mounted with $checked originals matching Immich's checksums"
fi

remove_package || fail "remove: $(tail -3 /tmp/remove.log | tr '\n' ' ')"
installed && fail "removed, but the package database still lists it"
for file in /usr/bin/verso /usr/bin/verso-service /usr/libexec/verso /usr/share/verso /usr/lib/systemd/user/verso.service \
  /usr/share/applications/dev.hviid.Verso.desktop "$extension"; do
  [ ! -e "$file" ] || fail "$file left after removal"
done
echo "ok: $version installed, window started, doctor answered${mounted}, removed"
