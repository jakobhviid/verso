---
name: lab-desktop-vm
description: Use to check Verso on a real GNOME desktop - its window, Verso Drive in Files, the top bar icon, thumbnails, sign-in in a browser, uploads by copy and move, keyrings, the tarball or the Flatpak - or to take README screenshots. Brings up a disposable Fedora 44 VM with a headless GNOME 50 session on the Incus lab host (lab/gnome-vm/), and covers putting Verso in, driving it, looking at it, tracing what reads the drive, and recording the result.
---

# The GNOME VM

Read AGENTS.md, "Testing on Erebus", first: its rules apply to everything here. Most checks also need the test
server (the `lab-immich-server` skill; NAT mode, `http://ind-immich-srv.incus:2283` from the VM).

What you get: a Fedora 44 VM (`GNOME_VM`, default `ind-gnome-1`) with GNOME Shell 50, Files and the tracing tools
(bpftrace, strace, inotify-tools), the user `tester` with linger, and nothing of Verso's. The session is
`session.sh [WxH]`, 1280x800 by default; input is `exp/input.sh`, synthetic clicks, keys, drags and touchpad
scrolls by coordinates. KDE Plasma has no window of Verso's, and there is no Plasma VM (ARCHITECTURE.md, "What Verso
is"); the `lab-bazzite-vm` skill has a stock Bazzite, GNOME edition, with Homebrew.

## The loop

```sh
lab/gnome-vm/up.sh && lab/gnome-vm/session.sh              # warm: about 14 s, then 4 s; built: about 115 s
lab/gnome-vm/run-in-session.sh -d /opt/verso/verso          # -d: a GUI app, detached (once Verso is in, below)
lab/gnome-vm/run-in-session.sh -d nautilus /home/tester/Verso
lab/gnome-vm/shot.sh /tmp/verso.png                         # then look at it with the Read tool
lab/gnome-vm/down.sh                                        # when the working session ends
```

**Warm VMs** (AGENTS.md, "Testing on Erebus"): `up.sh` restores a VM that has its `fresh` snapshot, taken once it
was built and stopped, so each check starts clean; without one, or with `--fresh`, it builds the VM (deleting one in
the way) and takes the snapshot. Each start renews `user.expires` and deletes the project's expired `ind-` instances
(`lab/warm.sh`). Run `up.sh` before every check, not only the first: it is what puts the VM back, Verso's install
included. Helpers (`exp/` at `/opt/exp`, `in-session`) are pushed on every start.

`run-in-session.sh` runs as `tester` with the session's bus and Wayland display; single-quote `~` and `$HOME` so they
expand inside the VM.

## Putting Verso in

**The tarball, the usual way:** build it in the toolbox from the repository's root, push it, and unpack it to
`/opt/verso`. There `/opt/verso/verso` is the launcher, which checks the system's libadwaita and runs the window,
`/opt/verso/libexec/verso`; the window finds `verso-service` in the folder above its own and its libraries in
`libexec/lib/`:

```sh
toolbox run -c verso bash -c 'export CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER=cc \
  CC_x86_64_unknown_linux_gnu=cc CXX_x86_64_unknown_linux_gnu=c++ AR_x86_64_unknown_linux_gnu=ar; \
  linux/packaging/verso-tarball.sh target/lab'                     # prints "Verso <version>"
"$EREBUS_DIR/bin/incus" file push --project lab target/lab/verso-x86_64.tar.gz \
  ind-gnome-1/root/verso-x86_64.tar.gz </dev/null
"$EREBUS_DIR/bin/incus" exec --project lab ind-gnome-1 -- \
  sh -c 'rm -rf /opt/verso && tar -xzf /root/verso-x86_64.tar.gz -C /opt' </dev/null
lab/gnome-vm/run-in-session.sh -d /opt/verso/verso
```

- **Signing in without clicking:** in the session, `printf '%s\n%s\n' <email> <password> |
  /opt/verso/verso-service login --server http://ind-immich-srv.incus:2283 --password` (or `printf '%s' <key> |
  ... --api-key`), with the lab's throwaway login from `.env.local`. Storing the first credential brings up "Choose
  password for new keyring": answer it with `exp/input.sh type` (twice, `key Tab` between, then `key Return`), or
  first `/opt/verso/verso-service configure set credential.file ~/.config/verso/credential`, the headless path, which
  asks nothing.
- **Verso Drive is off until switched on:** `/opt/verso/verso-service configure set mount.enabled true`, then
  `/opt/verso/verso-service mount`, which writes the user unit (`~/.config/systemd/user/verso.service`, its
  `ExecStart` the program that wrote it), starts it, and waits for the drive at `~/Verso`, "Verso" in Files'
  sidebar. Preferences, Verso Drive, Status, has the same switch.
- **What unpacking does not install:** the desktop entry (the launcher and the `app.immich` scheme the browser
  sign-in returns through), the theme's icons, which the top bar icon is looked up in (its `IconThemePath` is
  empty; the tarball's `hicolor/` holds them, for `~/.local/share/icons/hicolor/`), and Verso's menu in Files,
  `/opt/verso/verso-nautilus.py`, which nautilus-python loads from `~/.local/share/nautilus-python/extensions/`.
  The cask installs all three (the `lab-bazzite-vm` skill).
- **A missing library:** `ldd /opt/verso/libexec/verso | grep 'not found'` in the VM (`/opt/verso/verso` is a
  script); the tarball carries libshumate and libprotobuf-c, and the VM's GNOME packages carry GTK 4 and libadwaita.
- **A new build over a running one:** replace `/opt/verso` whole, as above, within two minutes: the service and an
  open window look at their program's inode (the window, at the launcher's) every 5 seconds and restart into the new
  one, as after `brew upgrade` (WORKFLOWS.md, "1. Install", "Upgrades"); a program gone for two minutes counts as
  uninstalled, and the service turns itself off. Pushing a file over a running program fails with "text file busy".
- **A stale program wins silently:** with an earlier install on the PATH (a cask's, say), check `command -v verso
  verso-service` in the VM, and the unit's `ExecStart`, when a result looks old.

**The Flatpak** (a test build without Verso Drive; ARCHITECTURE.md, "Verso as a Flatpak") is built in the VM, as the
workstation has no flatpak: `linux/packaging/flatpak/source-archive.sh <dir>` writes `verso-source.tar.gz`; push it and
`linux/packaging/flatpak/dev.hviid.Verso.yml` into one folder in the VM, install `flatpak-builder` there, and run the
two commands in the manifest's header (`--disable-cache`: flatpak-builder takes a changed local archive for the one it
built before). It needs the GNOME SDK and the Rust extension the manifest names, from Flathub. Then as `tester`:
`flatpak install --user verso-x86_64.flatpak` and `flatpak run dev.hviid.Verso` (WORKFLOWS.md, "1. Install").

**An atomic desktop's home** (Bazzite, Silverblue: `HOME=/home/tester` while the folder is `/var/home/tester`) is
what a real Bazzite VM gives as it is (the `lab-bazzite-vm` skill). To imitate it in this Fedora VM instead,
between `up.sh` and `session.sh`, as root in the VM:
`loginctl disable-linger tester; systemctl stop user@<uid>.service; mv /home /var/home; ln -s var/home /home;
loginctl enable-linger tester`. **Homebrew as a user installs it:** pre-create `/home/linuxbrew/.linuxbrew` owned
by `tester`, then run Homebrew's installer with `NONINTERACTIVE=1` as `tester` (it needs `git`, `procps-ng`,
`file`, `curl` and `gcc`). Source the lab helpers from bash: under zsh, `inc` looks for `bin/incus` in the wrong
place.

**Driving GNOME:** `exp/input.sh` runs as root in the VM (`"$EREBUS_DIR/bin/incus" exec --project lab ind-gnome-1
-- /opt/exp/input.sh key Return`), not through `run-in-session.sh`, and reaches the session by itself. It has
`click`, `rclick`, `drag`, `type`, `key`, `repeat` (one key pressed and released at an interval, as a held key),
`scroll` (a touchpad's two-finger scroll, then the gesture's end, so GTK scrolls on kinetically) and `swipe` (the
same sideways); its header says each one's arguments. It often drops the first event it sends, so check typed text
on a screenshot. The overview is hidden in the lab session; `org.gnome.Shell.Eval` with `Main.overview.showApps()`
shows the app grid.

## Looking at what reads the drive

This is the measurement that matters most: opening a folder must read no originals.
- **`fatrace` sees nothing** through a FUSE mount without `allow_other`. Use the bpftrace probe instead:
  `lab/gnome-vm/exp/fuse-opens.bt` prints every open and read on any FUSE mount, with the process and its parent.
- **To see FUSE request types** (CREATE, WRITE, FLUSH, SETATTR), put an `fentry` probe on the fuse module's
  `__fuse_simple_request`; a plain kprobe cannot resolve `struct fuse_args`.
- **The content cache** (`~/.cache/verso/<account>/content/`) shows what the service fetched: an empty cache after
  browsing means no original was read. `verso-service status --json` counts it as `fetched`.
- **Thumbnails** are in `~/.cache/thumbnails/{normal,large,x-large,xx-large}/`, failures in `fail/`.
- **How long Files is busy** after opening a folder: `/opt/exp/files-freeze.sh <folder>` in the session, with Files
  running, samples its main thread over D-Bus (`lab/bazzite-vm/freeze.sh` starts Files fresh around it on Bazzite,
  where rom-properties made this matter). It takes the folder under `~/Immich` and reads the fetched bytes from
  `immich-mount status --json`, Immich Mount's names: for Verso Drive, `~/Verso` and `verso-service`.
- **The service's log:** `systemctl --user set-environment VERSO_LOG=debug` and restart it (`systemctl --user restart
  verso`); `journalctl --user -u verso` in the session. At `debug` every folder is logged with what took its time.
- **Failure cases:** throttle the VM (`tc qdisc add dev eth0 root tbf ...`, or `netem delay`; `tbf rate 6mbit` makes
  an import slow enough to watch) and stop the server mid-operation (`docker stop immich_server` in the server's
  container).

`lab/gnome-vm/experiment.sh` reproduces the original thumbnail experiments with a `bindfs` mount over generated
JPEGs: `fixtures`, then `open <name> <dir>` (cold cache, settle, screenshot, who opened what).

## Traps

- **A click to focus a Preferences window can toggle a switch:** once the page has scrolled, a group's heading may
  sit where an `AdwSwitchRow` was, and the click flips it (Immich Crosslink went off this way, in the drive's
  preferences pages Verso carries). Focus the window through its title bar, and read the settings back with
  `verso-service configure list` after driving it.
- **Fedora cloud VMs hang after their first kernel update** unless the boot entry is fixed. The image has no
  `grubby`, so `up.sh` fixes `/etc/kernel/cmdline` with `sed`.
- **`incus file push` takes `<instance>/<path>`,** with `--project lab` as a flag.
- **The user manager's environment must be set,** because D-Bus-activated apps inherit it: the session scripts set
  `WAYLAND_DISPLAY`, `XDG_SESSION_TYPE`, `XDG_CURRENT_DESKTOP` and `XDG_SESSION_CLASS=user` (without the last,
  `localsearch` never starts).
- **Nothing a login starts runs** (no display manager, no PAM): no keyring unlocked at login, no XDG autostart. That
  is useful, since it shows what happens on installs without them, but remember it when something "should" be
  running.
- **GNOME's Eval** (`exp/input.sh`) has no `Clutter` global (use `imports.gi`), and drops clicks unless they use
  `Clutter.CURRENT_TIME`, one Eval per event, with hot corners off.
- **A key combination by Eval** (Ctrl+L, Alt+Left) takes one Eval per press and per release, and each Eval is slow
  enough for the key to repeat: turn repeat off first (`gsettings set org.gnome.desktop.peripherals.keyboard repeat
  false` in the session), or Files fills its search with the key. A key whose release was lost stays held; send its
  release alone. Files' grid view swallows Alt+Up; its bottom bar's back and forward buttons, clicked, always work.
- **Files' context menu:** a right click through the shell's virtual pointer (`exp/input.sh rclick`) selects the item
  but opens no menu in Files (seen on Bazzite, the `lab-bazzite-vm` skill). With the item selected (`nautilus
  --select <path>`, which selects one file however many are given), `input.sh key Escape` then `key Menu` opens it
  (the Escape takes the dropped first event). Resize the window to the screen first, or a menu opened upward is cut
  off. A second item joins the selection by a Ctrl+click: one Eval each for `Clutter.KEY_Control_L` pressed, the
  button pressed and released, and the key released.
- **Dragging from Files into Verso** works with `exp/input.sh drag <x> <y> <x2> <y2>` once both windows show side by
  side: an Eval of `meta_window.move_resize_frame(true, x, y, width, height)` on each places them. A file or a
  folder dragged that way arrives as a real drop (a `gdk::FileList`), so imports by drag and drop can be checked.
- **Hovers need real pointer motion:** a tooltip or a hover note shows only after the pointer moves there. `click`
  moves it before it clicks; to move it alone, an Eval of `global._labPointer.notify_absolute_motion(
  Clutter.CURRENT_TIME, x, y)`, once an `input.sh` call has made that virtual pointer.
- **A mouse wheel's steps** are not in `exp/input.sh` (its `scroll` is a touchpad's): an Eval sending Clutter's
  `notify_discrete_scroll` gives them.
- **There is no browser:** to see the address something opens, make a `.desktop` entry whose `Exec` appends `%u` to
  a file, and `gio mime x-scheme-handler/http <entry>.desktop` (and `https`). The clipboard reads back through the
  shell: an Eval of `St.Clipboard.get_default().get_text(St.ClipboardType.CLIPBOARD, (c, text) => { global._clip =
  text; })`, then a second Eval of `global._clip`.
- **`gio info` hides `filesystem::*`** unless given `-f`.
- **gvfs coalesces a quick unmount and remount,** keeping the old volume and its name. Wait until the drive is gone
  from `gio mount -l` before mounting again.
- **Files keeps a recorded thumbnail failure** until it is started again, F5 included; restart Files between runs
  that test thumbnails.
- **Files keeps the extension it loaded** until it starts again: after a new `verso-nautilus.py`, restart Files.
- **Notifications:** GNOME drops a notification whose `desktop-entry` hint names an app it did not come from, and
  shows no banner for the app that has focus; its message list (click the clock) shows what arrived. A test
  notification from a script: `gdbus call ... Notify ... "int32 -1"` (a bare `-1` reads as an option). To read what
  was sent, run `dbus-monitor --session "interface=org.freedesktop.Notifications,member=Notify"` into a file from a
  `systemd-run --user` unit: each notification shows twice, as sent and as the shell passes it on (count those whose
  destination is `org.freedesktop.Notifications`), and a log emptied while it runs reads as binary (`grep -a`).
- **`pkill -f <name>` inside `in-session sh -c`** kills its own shell, whose command line holds the name; match the
  process name instead: `pkill -x verso` (the window), `pkill -x verso-service`.
- **The VM runs under `LANG=C.UTF-8`,** where gettext's rules ignore `LANGUAGE`, so `LANGUAGE=da` shows English. To
  see Verso in another language: `dnf install glibc-langpack-da` as root, then start it with `LANG=da_DK.UTF-8`; for
  the service, `systemctl --user set-environment LANG=da_DK.UTF-8` and restart `verso`. Without the langpack GTK
  falls back to C and shows its Blueprint texts in English while the rest is translated.
- **The top bar icon** (ARCHITECTURE.md, "The tray") needs the AppIndicator extension, as Ubuntu and Bazzite ship
  it: `dnf install -y gnome-shell-extension-appindicator` as root, then in the session `gsettings set
  org.gnome.shell enabled-extensions "['appindicatorsupport@rgcjonas.gmail.com']"` and `session.sh` again; the
  service registers once the watcher appears. `exp/input.sh click` on the icon often does not open its menu; opening it through the shell does: an Eval of
  `Main.panel.statusArea['appindicator-<bus>@/StatusNotifierItem'].menu.open()`, its key listed by
  `Object.keys(Main.panel.statusArea)`. Its lines are also on D-Bus (`gdbus call --session --dest
  dev.hviid.Verso.Daemon --object-path /MenuBar --method com.canonical.dbusmenu.GetLayout -- 0 -1 "[]"`), and
  `Event` clicks one (`-- 4 clicked "<int32 0>" 0`).
- **`run-in-session.sh` without `-d` lacks the user manager's environment** (`XDG_CURRENT_DESKTOP` among it, which
  `session.sh` set there), so `xdg-open` there does not know the desktop and takes its generic path (seen on Plasma,
  where it skipped `kde-open`). Open links as an app of the session would: `run-in-session.sh -d xdg-open <link>`.
- **A dialog opened from a menu may show late,** and a picture taken at once misses it (seen with Immich Mount's GTK
  app). Activate the window's action instead: `gdbus call --session --dest dev.hviid.Verso --object-path
  /dev/hviid/Verso --method org.gtk.Actions.Activate preferences '[]' '{}'` (also `about`, `shortcuts`,
  `new-window`).
- **Harmless noise:** "Error registering session with GDM", and `xdg-desktop-portal` failing because
  `graphical-session.target` is inactive.
- **The light and dark style need the portal,** which does not start there: without it libadwaita does not follow
  `gsettings set org.gnome.desktop.interface color-scheme prefer-dark`, and Verso's service hears no change of colour
  scheme (`app.icon_dark`). Start it by hand in the session, `run-in-session.sh -d
  /usr/libexec/xdg-desktop-portal-gnome` then `run-in-session.sh -d /usr/libexec/xdg-desktop-portal --replace`, before
  Verso; a window started earlier keeps its style.

## README screenshots

`docs/screenshots/verso-*.png` are the README's pictures (DESIGN.md, "Screenshots"), taken in this VM against the
seeded server, so every photo in them is a credited fixture. Retake one at the same size, check it for anything that
is not test data, and keep the file name so the README needs no change. Take the whole session with `shot.sh` and
cut the window out with `lab/crop-png.py`. Put the window in place first with the shell's Eval, since the top bar
moves where windows open (`gdbus call --session --dest org.gnome.Shell --object-path /org/gnome/Shell --method
org.gnome.Shell.Eval "global.display.focus_window.move_resize_frame(false, x, y, width, height)"`):

| Picture | What | Size |
|---|---|---|
| `verso-library`, `verso-viewer`, `verso-places`, `verso-map` | Verso's window filling the screen under the top bar: box (x0 y0 x1 y1) 0 32 1280 800 | 1280 by 768 |
| `verso-files-album` | Files on an album in Verso Drive, the window alone with its rounded corners | 900 by 430 |

- **Signed out:** `verso-service logout`, and `verso-service configure unset server.url` for an empty address
  field.
- **The login keyring without its prompt:** `printf <password> | gnome-keyring-daemon --replace --unlock
  --components=secrets`, in the session. Typing with `exp/input.sh` did not reach the fields of Immich Mount's GTK 4
  window (the shell's own keyring prompt takes it); sign in from the command line, as above.
- **Single sign-on** shows on the sign-in page once `lab/immich-server/oidc.sh` has run; it restarts Immich, so the
  service may tell of a moment offline, a banner GNOME keeps until someone is active: dismiss it before a picture.

## Recording the result

A check's outcome goes where its claim lives: a design reason in ARCHITECTURE.md, observable behaviour in SPEC.md,
a quirk in the code comment that handles it, with the platform it applies to ("on GNOME 50"), as the fact it shows,
not the run that showed it (AGENTS.md, "The docs are not a log"): the run goes in the commit message. Lab notes, logs
and screenshots of a run stay out of git: `evidence/` and `screenshots/` under `lab/` are ignored. New Incus traps go to the Erebus repository's `docs/traps.md`, and new
lab traps into the skill that covers them.
