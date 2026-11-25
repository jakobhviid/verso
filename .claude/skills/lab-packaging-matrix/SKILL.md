---
name: lab-packaging-matrix
description: Use before or after a release, or after changing how Verso is packaged (linux/packaging/verso-packages.sh, linux/packaging/verso-appimage.sh, the rpm spec, the deb control file, the launcher, AppRun, the icons, the Files extension, what the window finds where), to check that Verso's rpm and deb install, work and remove cleanly on Fedora 44 and 43, Ubuntu 26.04 and Debian 14 at once, that Ubuntu 24.04 refuses the deb with its launcher saying why, and that the AppImage starts and signs in on Ubuntu 24.04, in throwaway containers on the Incus lab host (lab/packaging/).
---

# The packaging matrix

Read AGENTS.md, "Testing on Erebus", first: its rules apply here too. From a worktree of this repository, set
`EREBUS_DIR` (the scripts look for `erebus` beside the checkout, which a worktree is not).

```sh
linux/packaging/verso-packages.sh /tmp/verso-out              # the rpm and the deb from this tree (podman, on the host)
toolbox run -c verso linux/packaging/verso-appimage.sh /tmp/verso-out    # the AppImage from this tree (the Fedora 44 toolbox)
lab/packaging/matrix.sh --packages /tmp/verso-out             # those, on every distribution
lab/packaging/matrix.sh --packages /tmp/verso-out appimage:ubuntu/24.04    # the AppImage alone
lab/packaging/matrix.sh                                       # the latest release's, from jakobhviid/verso
lab/packaging/matrix.sh v0.73.0 fedora/44 ubuntu/24.04        # one tag, chosen distributions
```

- **Building:** `verso-packages.sh` runs a fresh container of each distribution (Fedora 44 for the rpm, Ubuntu 26.04
  for the deb), installs its build dependencies, builds both programs (about 5 minutes each with LTO; the build stays
  in `target/package-rpm` and `target/package-deb`, so the next one only packages) and the Files extension, and lays
  the package out. It takes the version from `ci/version.sh`, so a tree after the last tag builds as the next
  release would be numbered. It mounts only the registry and the checkouts of `~/.cargo`: its `config.toml` may name
  a linker the containers lack.
- **One row per distribution,** each from an ephemeral container named `ind-pkg-<distribution><LAB_SUFFIX>`, with a
  `user.expires` three hours ahead, deleted when it stops at the end. Give `LAB_SUFFIX` (`-2`) when another agent runs
  the matrix at the same time. The exit code fails when any row fails; each row's log is in `/tmp/verso-matrix.*/`.
- **What is checked** is decided per distribution by `install-test.sh`, which says so in its header:
  - Fedora 44 and 43 (the rpm), Ubuntu 26.04 and Debian 14 (the deb): it installs with the distribution's package
    manager, `verso-service --version` says the package's version, `updates.check` is on (only the packages' build
    has it on), every file is in its place (the 27 other looks of
    the app icon among them), the window, the service and the Files extension find every library, `verso --probe`
    goes through the launcher into the window, the window keeps running for 10 seconds under a headless weston with a
    session bus, `doctor --json` answers, and it removes, leaving none of its files.
  - Ubuntu 24.04 (too old): apt refuses the deb, naming libadwaita; unpacked, its launcher says it has no libadwaita,
    then, with 24.04's libadwaita 1.5 installed, that the system's libraries are older, and exits with 1.
  - `appimage:ubuntu/24.04` (`appimage-test.sh`, the AppImage, which the other rows never get): the file says its version
    and is the AppImage's build (`updates.check` and `mount.enabled` off), `doctor --json` answers, its `usr/bin`
    links run, the graphics libraries are not in it, the window keeps running for 10 seconds under headless weston
    (GTK 4.22 and libadwaita 1.9 loaded on a system with GTK 4.14), and, with a lab server, the read-only key signs in
    with GNOME Keyring unlocked on the session bus (the sign-in is in the keyring, not a file), the window starts the
    service as an AppImage of its own, and `logout` removes the sign-in. The container has no FUSE, so the file runs
    unpacked (`APPIMAGE_EXTRACT_AND_RUN`, which its own children inherit); `weston-screenshooter` shows nothing on the
    headless backend, so for a picture run the window under `Xvfb` with `GDK_BACKEND=x11` and `import -window root`
    in a kept container (the signed-in library showed with its thumbnails and icons).
- **With a lab server** (`IMMICH_ENV`, the server's `.env` file; default `lab/immich-server/.env.local`, the
  showcase server's is `.env.ind-immich-show.local`), each system where the package installs also signs in with the
  read-only key, switches Verso Drive on, mounts it as root at `/root/Verso`, and checks five originals under Photos
  against Immich's own checksums, then unmounts and stops the service. The server must be on NAT, reachable from the
  containers (`IMMICH_URL`); the key goes to them in a 0600 file and is never printed. Bring a server up first (the
  `lab-immich-server` skill) when a change touches reading or mounting.
- **A release's packages** and its AppImage come from `jakobhviid/verso`'s GitHub release through `gh`, so the tag
  must be there.
- **The AppImage's build** takes about 6 minutes from nothing (the build with LTO is most of it; `target/appimage`
  keeps it for the next). It downloads appimagetool 1.9.1 and the type 2 runtime once into `~/.cache/verso-appimage`,
  each by its pinned SHA-256; `zsyncmake` (Fedora's `zsync`) in the toolbox makes the `.zsync` beside it.

When a row fails, rerun just that distribution, then look inside a kept container: launch one without `--ephemeral`
(with a `user.expires`), push the packages and `install-test.sh` as `matrix.sh` does, run it by hand, and delete the
container after.
