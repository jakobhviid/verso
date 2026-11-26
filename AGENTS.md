# AGENTS.md

Instructions for any AI coding agent (Claude Code, opencode, and others) and for humans. Read this first.
`CLAUDE.md` is a symlink to this file, so there is exactly one copy of the rules. Edit `AGENTS.md`, never the link.

This repository is Verso's: Verso for Immich, a native gallery for an Immich library with its drive, Verso Drive, on
Linux (GNOME) and the Mac. It follows the maintainer's house style for Rust command-line tools,
`rust-cli-guidelines` (a private guide: governance, code style, CLI patterns, release). Where those guidelines assume
a pure CLI, the adaptation is written down in ARCHITECTURE.md, "Note for the house guidelines".

## Hard rules

- **Never add AI attribution** to commits or pull requests: no `Co-Authored-By` trailer for an assistant, no
  "Generated with" line. Author every commit as the repository owner. AI use is disclosed once, in the README's
  "AI disclosure" section.
- **No em-dashes** in anything written here: docs, code comments, commit messages. Use a hyphen, comma, colon or
  parentheses, or rewrite the sentence.
- **Do not commit or push unless the maintainer asks.** Use Conventional Commit prefixes when you do (see
  Versioning).
- **Keep the credit.** Verso Drive, the service and the Immich API layer come from
  [Immich Mount](https://github.com/jakobhviid/immich-mount), which is inspired by
  [Kartax/immich-desktop-app](https://github.com/Kartax/immich-desktop-app). Verso on the Mac starts from
  [Immich Gallery](https://github.com/IGOLz/ImmichGallery) by Alessandro Craciun, with contributions by the maintainer.
  Immich Gallery is credited the same way everywhere: Alessandro Craciun first, then Jakob Hviid, with a link to its
  repository; never with shares of who wrote what.
  - Every project we take ideas or code from is credited in the README's credits section and in
    [CREDITS.md](CREDITS.md), the way open-source projects usually credit: a line on what it is and what it gave
    us, not an inventory. No per-file headers.
  - MIT-licensed code may be copied and adapted freely; keep its notice once, in `THIRD-PARTY-NOTICES.md`.
  - Code, text or graphics without a license (Kartax's app, for one) are never copied, only learned from. Its app
    icon, logo and screenshots are never used, nor anything drawn after them.
  - Never remove or dilute the credit.
- **Say that we are unofficial.** The non-affiliation notice (SPEC.md) appears in the README, the About window on
  every platform, and every AppStream file and package description. The Immich logo is never our icon or branding;
  our icons (`linux/packaging/icons/`, and the Mac's drawn from them) take Immich's colours, never its shapes.
- **Keep the core portable.** No FUSE, D-Bus, GTK or OS-specific code in `immich-api` or `verso-core`
  (`shared/`). Platform specifics go in adapters, behind traits.
- **Keep a future Flatpak possible.** Verso's Flatpak is a test build without Verso Drive, which needs access
  outside the sandbox (ARCHITECTURE.md, "Verso as a Flatpak"). Every design change states its Flatpak impact against
  the readiness rules in ARCHITECTURE.md.

## The docs, and which one to change

The docs are load-bearing. They are embedded into `verso-service --llm`, and a behaviour change ships with its doc
change in the same commit. When code and docs disagree, the code wins and the doc is the bug.

| File | Holds | Change it when |
|---|---|---|
| [README.md](README.md) | The landing page: what Verso is, keywords, install, credits, AI disclosure | The pitch, the install story or the credits change |
| [WORKFLOWS.md](WORKFLOWS.md) | What you run: install, sign in, status, doctor, settings, troubleshooting, JSON shapes | A command, a flag, an output or a recipe changes |
| [SPEC.md](SPEC.md) | The contract, what Verso does: vocabulary, Verso Drive's layout, names and attributes, content, thumbnails, uploads, sign-in, config keys, the `verso-service` command, D-Bus, files, errors | Observable behaviour changes |
| [ARCHITECTURE.md](ARCHITECTURE.md) | The model and every design decision with its reason, plus the alternatives that lost where a question tends to recur | A design decision is made or changed |
| [PRINCIPLES.md](PRINCIPLES.md) | The invariants, and what earned them | Rarely: only after discussing it with the maintainer |
| [DESIGN.md](DESIGN.md) | The look: the icon family on each platform, the colours, type and words, screenshots, and the apps' interfaces | An icon or the apps' look changes |
| [ROADMAP.md](ROADMAP.md) | What is not built: the milestones' open steps, open questions, ideas parked on purpose, and a line for each finished milestone | Plans change, a question opens or closes, something is deferred, or a step is finished (it shrinks to a line) |
| [CREDITS.md](CREDITS.md) | Who we learned from or copied from, with licenses | We take anything from another project |
| [SECURITY.md](SECURITY.md) | How to report a vulnerability, and what Verso holds, sends and changes | What Verso keeps, where it connects or what it changes on the server changes |
| `.claude/skills/` | Procedures for agents: the lab environments, how to drive them, their traps, and where a check's result is recorded | A lab procedure or trap changes |

Decisions live inline in ARCHITECTURE.md (or SPEC.md, for behaviour), never in separate decision-record files. Open
questions live in ROADMAP.md.

**Describe the current state, not the change.** A doc that says what *used to* be true misleads the next reader.
Before committing, grep your own doc diff for: "now", "no longer", "used to", "previously", "was changed",
"reopened", "superseded", "instead of the old". The before and after belong in the commit message.

**The docs are not a log.** They hold what Verso is and does, each decision with its reason, and what is not built
yet. How something was found, tried, checked or measured, and what it did before, goes in the commit message. A
check's result stays in a doc only where it supports a decision or a documented claim, and then as the fact it
shows ("idle connections go after 4 s, before the server's 5 s"), not as the run that showed it. A finished
milestone keeps a line in ROADMAP.md; its story is in the history. "Not chosen" keeps only the alternatives someone
would propose again. A date stays only where the date is itself the fact.

## Versioning

A release is cut by a signed tag (`v0.72.0`), one version line for every platform, and its version is the tag's.
`ci/version.sh` numbers any tree from the tags: at a tag, the tag's version; after one, the last tag with one bump,
by the largest kind among the commit subjects since it, which is what the next release would be. Nobody edits
`version` by hand: Cargo.toml stays at 0.0.0, which a build of one's own shows.

| Subjects since the last tag | Bump |
|---|---|
| any `type!: ...` (breaking) | major; the minor while the major is 0 |
| else any `feat: ...` | minor |
| else anything (`fix:`, `docs:`, `chore:`, ...) | patch |
| none | none: the tag's own version |

The bump is a suggestion: the maintainer tags it, or another number after the last. A `BREAKING CHANGE` footer is
not scanned; mark breaking changes with `!` in the subject. Subjects stay Conventional Commits, because they make the
release notes (`ci/release-notes.sh`: `feat` under New, `fix` under Fixed). A pre-release is a tag such as
`v1.0.0-beta.1`, published as a pre-release and kept out of the cask; the tree after it numbers itself as the release
it leads to (1.0.0). Verso stays at 0.x until its public launch; 1.0.0 is that launch. A checkout without the tags
has no version: `ci/version.sh` stops and asks for them.

**A push releases nothing.** The maintainer cuts a release with `ci/release.sh`, on the Linux workstation; `--dry-run`
on any step shows what it would do and changes nothing outside the checkout:
1. `ci/release.sh` suggests the next version and prints its notes.
2. `ci/release.sh tag [VERSION]` tags a clean HEAD that is on `origin/main`, signed, and pushes the tag.
3. `ci/release.sh build TAG` builds Linux's files from the tag in a worktree of its own (the tarball and the AppImage
   in the toolbox, the rpm and the deb each in a container of its distribution, with podman, the Flatpak's source,
   and the Flatpak where `flatpak-builder` is) into `target/dist/TAG`, and makes a draft release
   of them, "Verso 0.72.0 (Linux)", here, which Homebrew's `verso` cask and Verso's page download from. The release
   workflow
   (`.github/workflows/release.yml`) runs this step on every pushed tag, the Flatpak included, and adds the Mac's disk
   image, signed and notarized, once the Mac's secrets are set (its `macos` job names them); so after `tag`, this
   step is the workflow's, not the workstation's. By hand, the workflow rehearses a tag with `--dry-run`. On the
   workstation, which has no flatpak, the Flatpak is built in the GNOME VM from the source archive, as the step
   prints.
4. The maintainer checks the draft, installed in the lab's desktop VMs, and `ci/release.sh publish TAG` publishes both
   drafts and bumps the cask in `jakobhviid/homebrew-tap`.

The builds take the version from `ci/version.sh` and build it in (`VERSO_VERSION`, read as
`verso_core::product::VERSION`; the Flatpak's source carries it in `VERSION`, as it has no history), so the About
window, `--version` and the user agent say it. The Mac's and iOS's build number is the build's UTC time to the minute
(`20261122.1435`, written by `mac/build-rust.sh`), so it rises with every build, as TestFlight and Sparkle need. Every
release is kept.

The one version line serves Verso on Linux, macOS and iOS, and a version names a tag, not a release of every platform
at once (ARCHITECTURE.md, "Verso's releases"):
- Every release carries Linux, also one whose commits touch only the Apple editions.
- An Apple build is made on the Mac, never on the Linux workstation, and ships only after the maintainer has
  checked it there. It goes on the GitHub release of the tag it was built from, whose title then names macOS
  beside Linux ("Verso 3.9.0 (Linux and macOS)"), with a macOS section in its notes since the previous Mac release.
  `mac/release.sh` builds its disk image, signed with Developer ID and notarized, in a Terminal window on the Mac;
  `ci/sign-mac-update.sh` signs it for Sparkle on the workstation, and both are attached to the tag's drafts.
- iOS ships through TestFlight and the App Store, never on GitHub: the release workflow's `ios` job uploads the
  iPhone's and the iPad's build and the Apple TV's (`ios/release.sh`, `--tvos`) once their secrets are set, as
  `ios/release.sh` does on the Mac. `ios/appstore.py push` fills the App Store listing and TestFlight's texts from
  `ios/AppStore/`; sending a version to review is the maintainer's.
- There is no rolling "latest" release: each platform's newest is found on its own; the cask follows GitHub's Latest
  here.

## The green gate

Before every push, run in the toolbox:

```sh
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
cargo check -p immich-api -p verso-core --no-default-features --target aarch64-apple-darwin   # the core stays portable
```

CI (`.github/workflows/ci.yml`) runs the first two lines with `--exclude verso` on Ubuntu, and checks Verso's window
separately in a `fedora:44` container, because it needs GTK 4.18, libadwaita 1.8 and `blueprint-compiler`, and builds
the Files extension there. It also checks the translations against the sources (`python3 po/i18n.py check`) and runs
`immich-api`'s contract tests against Immich in Docker. CI runs on every push to `main` and on pull requests, a newer
push cancelling an older run; the local gate still comes first, before every push. The toolbox has every library,
so the local gate covers the whole workspace.

The macOS side (`mac/`, and the bridge built for macOS) has no gate on Linux. CI's `macos` job builds the app and its
extensions unsigned and runs `mac/Verso/check.py` on a Mac runner, with the newest Xcode GitHub has (older than the
Mac's: what both compile is what CI checks); a change to it is still built and checked on the Mac (the `mac-dev`
skill).

There is deliberately no `cargo fmt` gate. Readability is a review concern; readable names are required (no
single-letter bindings), per the house style.

Before a milestone closes, especially uploads (M3) and every release, an independent agent runs an adversarial
review covering safety, correctness, and docs against behaviour.

## Reference material

- **Immich Mount** (MIT), where Verso Drive, the service and the Immich API layer come from, and whose account Verso
  offers to take over: its own repository, `jakobhviid/immich-mount`, checked out next to this one
  (`../immich-mount`).
- **Kartax's macOS app** (read-only reference, no license, so nothing is copied): `git clone --depth 1
  https://github.com/Kartax/immich-desktop-app /tmp/immich-ref/src` if missing. The most useful files are
  `Shared/ImmichClient.swift`, `Shared/AssetUpload.swift`, `FileProviderExt/ItemEnumerator.swift` and `Tests/`.
- **immich-rs** (MIT), the source of our API layer: https://github.com/boul2gom/immich-rs at commit `60d1eb3`.
- **Immich Gallery** (MIT, Alessandro Craciun), where Verso's Mac edition starts (ROADMAP, "Verso on the Mac"): the
  maintainer's fork, `jakobhviid/ImmichGallery`, checked out next to this repository (`../ImmichGallery`), with the
  original as its `upstream` remote (`IGOLz/ImmichGallery`). Its `integration` branch, upstream's main with the
  maintainer's pull requests merged in, is the one to take from. Its code may be adapted here, with its notice kept
  once in THIRD-PARTY-NOTICES.md. Contributions back to the original go as an issue and a pull request whose text the
  maintainer reads before anything is posted.
- **The Immich API:** the server serves its OpenAPI spec at `/api/spec.json`; the immich repository has it at
  `open-api/immich-openapi-specs.json`.

## Development environment

The repository is sorted by where the code runs: `shared/` (`immich-api`, `verso-core`, `verso-bridge`), `linux/`
(the window `verso`, `verso-desktop`, `verso-linux`, `verso-service`, `files-extension`, `packaging`) and `mac/`
(ROADMAP.md, M9, has the layout). Translations are in `po/`, for Linux and the Mac alike.

Build on Fedora 44, or in a Fedora 44 toolbox (the easy way on an immutable host such as Silverblue or CoreOS:
`toolbox create -r 44 verso`).
- **Packages:** `gcc`, `cargo`, `rust`, `clippy` and `rustfmt`. The window also needs `gtk4-devel`,
  `libadwaita-devel`, `libshumate-devel` (the map) and `blueprint-compiler`, and the Files extension
  `nautilus-devel` (in a toolbox it installs only with `dnf install --allowerasing`, which swaps
  `systemd-standalone-tmpfiles` for systemd). The icons' pictures need `librsvg2-tools`
  (`linux/packaging/icons/linux-app-icon.py`). The AppImage (`linux/packaging/verso-appimage.sh`) needs `curl` and
  `binutils` for what it packs with, which it downloads itself, and `zsync` for the update file beside it.
- **Mounting** Verso Drive needs `/dev/fuse` and a setuid `fusermount3` (package `fuse3`). The service can mount it
  and be tested on the development host directly.
- **A global cargo linker the toolbox lacks** (zig through `cargo-zigbuild`, say, on a host without a C toolchain)
  is overridden with the environment, rather than by editing the global config:

  ```sh
  toolbox run -c verso bash -c 'export CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER=cc \
    CC_x86_64_unknown_linux_gnu=cc CXX_x86_64_unknown_linux_gnu=c++ AR_x86_64_unknown_linux_gnu=ar; \
    cargo clippy --workspace --all-targets -- -D warnings && cargo test --workspace'
  ```

- **The rpm and the deb** are built on the host, not in the toolbox, with podman (or docker): each in a fresh container
  of its distribution (`linux/packaging/verso-packages.sh`; ARCHITECTURE.md, "The rpm and the deb").
- **The portability check** (`--target aarch64-apple-darwin`) runs in CI; Fedora's Rust has no `rustup` to add
  targets. It runs with `--no-default-features`, which leaves out TLS: ring's C code does not cross-compile for
  macOS on Linux.
- **Anything that needs a desktop session** is tested in a VM (below).
- **Verso on the Mac** (`mac/`; ARCHITECTURE.md, "Verso on the Mac") builds only on a Mac with Xcode. `mac/Verso/`
  is the Xcode project (the app, its widget and the checks), `mac/FileProvider/` Verso Drive's extension and
  `mac/Shared/` what both use. There: `brew install xcodegen`, `rustup target add aarch64-apple-darwin
  x86_64-apple-darwin`, then `mac/build-rust.sh` (the bridge, `shared/verso-bridge`, into `mac/build/`) and
  `xcodegen` in `mac/Verso` (`Verso.xcodeproj`, git-ignored). A development build is signed with the developer's own
  team, set in the git-ignored `mac/Config/Local.xcconfig` (`DEVELOPMENT_TEAM = ...`); a free Personal Team is
  enough. Its checks run there too: `mac/Verso/check.py` (Immich Gallery's offline checks) and
  `mac/Verso/check-core.sh` (the endpoint calls through the core, live; Immich's demo server unless `IMMICH_URL` says
  otherwise).
  - A Debug build is **Verso Dev** (`dev.hviid.Verso.Dev`): an identity of its own (bundle identifier, App Group,
    Keychain group, URL schemes, settings, Finder location), and its app icon is the release's but for its turned
    corner, blue with DEV on it, so it runs beside an installed release. The small icons (Finder's sidebar symbol,
    the menu bar icon, Messages' icon) are the release's lens.
    `mac/Verso/dev-app.sh` builds it signed, installs it as `/Applications/Verso Dev.app` and starts it;
    `mac/Verso/dev-app.sh --remove` quits and deletes it. It signs in and out from launch arguments
    (`-signInServer` with `-signInAPIKey`, or with `-signInEmail` and `-signInPassword`; `-signOut`), as the
    `mac-dev` skill shows.
  - The Mac's copy of it comes from Linux with `rsync`, work not yet pushed included, as the `mac-dev` skill says.
- **Verso on iOS** (`ios/`; ROADMAP.md, M10) builds on the same Mac, from the same bridge (`mac/build-rust.sh debug
  --ios`) and `xcodegen` in `ios/`. Its Simulator build needs no signing and runs over SSH; the UI tests in
  `ios/VersoUITests` walk the app against Immich's demo with launch arguments and keep a screenshot of each place.
  - Verso Dev on a real iPhone or iPad: `ios/dev-iphone.sh` builds it signed with the developer's team, installs it
    on the first paired device and starts it. Signing needs the login keychain, so from SSH it runs in a Terminal
    window in the developer's session (`open -g -a Terminal ios/dev-iphone.command`).
  - Once per device: paired with the Mac (a cable, Trust This Computer) and in Developer Mode (Settings, Privacy &
    Security). Once per Mac: Xcode signed in to the team's Apple account (Settings, Accounts), or the build stops at
    "No Accounts"; Xcode then registers the device and makes its profiles itself.
- **No macOS virtual machines on Erebus:** Apple's license allows macOS VMs only on Apple hardware. The
  maintainer's Mac is a laptop in daily use, so Mac work comes in sessions; between them, CI's macOS job is the Mac,
  once Actions is on. The `mac-dev` skill covers building, running and debugging on it over SSH, and the rules that
  keep it a laptop.

## Testing on Erebus

**Erebus** is the maintainer's Incus host, for disposable VMs and containers. Its setup lives in a private
repository, `erebus`, checked out next to this one; `EREBUS_DIR` points elsewhere. On another Incus host, give
`EREBUS_DIR` a directory with what the `lab/` scripts use from it:
- `bin/incus`: the `incus` client, already pointed at the host
- `lib/erebus.sh`, sourced from bash, defining `inc` (runs `bin/incus`), `step` (prints a timed progress line), `die`
  (prints and exits 1), `state <project> <instance>` (the instance's status), `wait_for <project> <instance> <what>
  <command...>` (waits until the command succeeds in the instance) and `wait_cloud_init <project> <instance>`

On Erebus itself:
- Read the `erebus` repository's `AGENTS.md` and `docs/traps.md` before the first call.
- Always use its `bin/incus` wrapper, and give calls that should not read stdin `</dev/null`.
- Check access with `$EREBUS_DIR/bin/incus info </dev/null | grep auth:`; it should print `auth: trusted`.

The procedures are skills in `.claude/skills/`; agents that do not load skills read the `SKILL.md` directly.

| Environment | What it gives you | Skill |
|---|---|---|
| `lab/immich-server/` | A disposable Immich server (Docker CE in a nested Debian 13 container, no machine learning), seeded with 50 Creative Commons photos and edge cases, a full-access and a read-only API key, and optionally Dex for OIDC sign-in | `lab-immich-server` |
| `lab/gnome-vm/` | A Fedora 44 VM with a headless GNOME 50 session and Files, that you can drive, screenshot and trace | `lab-desktop-vm` |
| `lab/bazzite-vm/` | A stock Bazzite VM, GNOME or KDE edition, booted from a kept base disk built from the published bootc images: Bazzite's own Homebrew, `/home` a link to `/var/home`, SELinux enforcing, and a headless session and input helpers as in the GNOME VM | `lab-bazzite-vm` |
| `lab/packaging/` | The packaging matrix: Verso's rpm and deb, built here or from a release, installed on Fedora 44 and 43, Ubuntu 26.04 and Debian 14 in throwaway containers at once, checked (the version, the files, the libraries, the window starting, Verso Drive mounted against a lab server's checksums) and removed, and refused on Ubuntu 24.04, where the launcher says why | `lab-packaging-matrix` |

Verso's packages have the packaging matrix; Verso has no scripted release check yet (ROADMAP.md, M9, step 6), to be
built after Immich Mount's (`lab/check/` and `lab/mac/check.sh` in its own repository, `../immich-mount`). Until then
a Verso change is checked by hand, in the VMs of the `lab-desktop-vm` and `lab-bazzite-vm` skills and on the Mac
(`mac-dev`).

Rules:
- **Lab instances are disposable, and stay warm for a working session.** A VM or server may stay up between checks
  and is deleted when the session ends. Any `ind-` instance found at the start of a session may be destroyed and
  created again at will, unless it is kept (`user.keep=true`) or another agent of this session is using it. Warm is
  not dirty: snapshot an instance once it is set up, and restore that snapshot before each check, so no check passes
  on what an earlier one left. Give each instance `user.expires` (a UTC time, at most 12 hours ahead); a session
  starts by deleting the expired ones, so an abandoned session leaves nothing for long. Never run the Erebus
  teardown script with `--delete`: other projects' instances run there too.
- **Prefix instance names with `ind-`,** and work in the `lab` project. Agents that run at the same time use a name
  suffix of their own (`ind-gnome-2`), and leave each other's instances alone.
- **Kept things** need `user.keep=true` and a note to the maintainer: the Bazzite base disks are kept.
- **Fixtures are Creative Commons or public domain,** and never upload personal photos to a test server.
- **Test credentials are throwaway,** generated per deployment into a gitignored `.env.local`.
- **Wait on conditions, never on bare sleeps,** with `wait_for` and `wait_cloud_init` from `lib/erebus.sh`. Incus
  reports `RUNNING` even when a VM is stuck in boot. Source the helpers from **bash**, not zsh.
- **No lab notes in git.** A check that settles a claim changes the doc where the claim lives, as the fact it shows
  (ARCHITECTURE.md for a design reason, SPEC.md for behaviour, a code comment for a quirk); the run itself, what was
  tried, when and on which machine, goes in the commit message ("The docs are not a log"). Logs and screenshots of a
  run stay out of git (`lab/**/evidence/` and `lab/**/screenshots/` are ignored); README pictures live in
  `docs/screenshots/`.
- **New traps:** Incus ones go into the Erebus repository's `docs/traps.md`, lab ones into the skill that covers
  the environment.
