---
name: lab-packaging-matrix
description: Use before or after a release, or after changing how Verso is packaged (linux/packaging/verso-packages.sh, the rpm spec, the deb control file, the launcher, the icons, the Files extension, what the window finds where), to check that Verso's rpm and deb install, work and remove cleanly on Fedora 44 and 43, Ubuntu 26.04 and Debian 14 at once, and that Ubuntu 24.04 refuses the deb with its launcher saying why, in throwaway containers on the Incus lab host (lab/packaging/).
---

# The packaging matrix

Read AGENTS.md, "Testing on Erebus", first: its rules apply here too. From a worktree of this repository, set
`EREBUS_DIR` (the scripts look for `erebus` beside the checkout, which a worktree is not).

```sh
linux/packaging/verso-packages.sh /tmp/verso-out              # the rpm and the deb from this tree (podman, on the host)
lab/packaging/matrix.sh --packages /tmp/verso-out             # those, on every distribution
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
- **With a lab server** (`IMMICH_ENV`, the server's `.env` file; default `lab/immich-server/.env.local`, the
  showcase server's is `.env.ind-immich-show.local`), each system where the package installs also signs in with the
  read-only key, switches Verso Drive on, mounts it as root at `/root/Verso`, and checks five originals under Photos
  against Immich's own checksums, then unmounts and stops the service. The server must be on NAT, reachable from the
  containers (`IMMICH_URL`); the key goes to them in a 0600 file and is never printed. Bring a server up first (the
  `lab-immich-server` skill) when a change touches reading or mounting.
- **A release's packages** come from `jakobhviid/verso`'s GitHub release through `gh`, so the tag must be there.

When a row fails, rerun just that distribution, then look inside a kept container: launch one without `--ephemeral`
(with a `user.expires`), push the packages and `install-test.sh` as `matrix.sh` does, run it by hand, and delete the
container after.
