---
name: mac-dev
description: Use to build, run, test or debug Verso on the Mac (mac/ - the app, its widget and Verso Drive's File Provider extension - and the bridge, shared/verso-bridge) on the maintainer's Mac over SSH from Linux - copying the checkout over with rsync, building the bridge and the Xcode project, the offline and live checks (check.py, check-core.sh), Verso Dev built signed in the maintainer's session and driven with launch arguments, reaching the lab server through tunnels, reading the unified log and the system's File Provider state, and cleaning up. The Mac is the maintainer's everyday laptop; the rules here keep it that way.
---

# The Mac: building and testing Verso

ARCHITECTURE.md, "Verso on the Mac" and "Verso Drive on the Mac", has the design; ROADMAP.md, M8, "Verso on the
Mac", the steps. There are no macOS VMs (AGENTS.md, "Development environment"): the Mac is the maintainer's laptop,
available in sessions.

## Rules

The Mac is a personal laptop the maintainer carries and uses every day, not a lab machine:
- **Only build, test and debug there.** Never change its settings or state: no System Settings, no `sudo`, no
  `xcode-select -s`, no edits to shell profiles, no global installs or uninstalls, no `defaults write` outside our
  own app. Anything like that is the maintainer's to do, after asking.
- **Stay inside the checkout** (`~/Developer/Private/verso` there) and its git-ignored `mac/build/` and
  `mac/Verso/build/`.
- **Do on Linux what Linux can do:** Rust builds and tests, the bridge's lab tests, docs. The Mac is for the bridge's
  Mac build, Xcode builds, `check.py` and `check-core.sh`, running the app and its extensions, Finder and logs. CI's
  `macos` job builds the Swift side unsigned, but GitHub Actions is off in this repository, so a change to `mac/` is
  built and checked on the Mac.
- **It may be asleep or away:** start with a short SSH command, and never assume it is there.
- **Test with Verso Dev, never a release build:** the Debug build has an identity of its own (AGENTS.md,
  "Development environment"), so signing it out and in, its settings and its Finder location leave an installed
  Verso and its sign-in alone. Quit only what runs from `Verso Dev.app`, by its path (`pkill -f "Verso
  Dev.app/Contents/"` for the app and its extensions, `.../Contents/MacOS` for the app alone): its extensions'
  processes, `VersoDrive` and `VersoWidget`, have a release's names.
- **No `osascript` over SSH, ever** (Traps, below), and **never write the Mac's address into the repository.**
- **Clean up what a check leaves:** sign Verso Dev out with the launch argument below (its account, its cache and
  Verso Drive's location go), unless the maintainer keeps using it; delete what a failed `check-core.sh` made; close
  the tunnels.

## Reaching it

`MAC_HOST` (`user@address`; private, never written into the repository) with the SSH key the maintainer
authorized. Homebrew's tools are on the PATH only in a login shell, so every command goes through zsh:

```sh
ssh "$MAC_HOST" 'zsh -lc "cd ~/Developer/Private/verso && ..."'
```

**The checkout comes from Linux.** The repository is private and GitHub refuses the Mac's SSH key ("Permission
denied (publickey)"), so `rsync` copies the working tree over from the repository's root on
Linux, `.git` included (`ci/version.sh`, which `mac/build-rust.sh` runs, reads the history and its tags), without
`--delete`, so what only the Mac has stays (its `mac/Config/Local.xcconfig` among it). A file deleted on Linux is
deleted on the Mac by hand.
The lab's credentials (`.env.local`, and the server's `lab/immich-server/.env.<instance>.local`) never go: a sync
that excluded only `.env.local` would put the lab server's file on the Mac, so exclude `.env*.local`.

```sh
rsync -a -e "ssh <options>" --exclude /target/ --exclude /mac/build/ --exclude /mac/Verso/build/ \
  --exclude '/mac/Verso/*.xcodeproj/' --exclude '.env*.local' --exclude __pycache__ \
  ./ "$MAC_HOST:Developer/Private/verso/"
```

## Build

Through zsh as above, in the checkout, with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (Traps):

```sh
mac/build-rust.sh debug                         # the bridge for both architectures, its Swift bindings, the xcframework, the texts
cd mac/Verso && xcodegen                        # Verso.xcodeproj, git-ignored
xcodebuild -project Verso.xcodeproj -scheme Verso -configuration Debug -destination platform=macOS \
  -derivedDataPath build/UnsignedData CODE_SIGNING_ALLOWED=NO build
python3 check.py                                # Immich Gallery's offline checks, about a minute; those of Swift that
                                                # calls the core link it from the bridge built above
./check-core.sh                                 # the endpoint calls through the core, against Immich's demo
```

All of it runs over SSH, unsigned. `-derivedDataPath` keeps the build inside the checkout, and a path of its own
keeps it from replacing the signed app in `build/DevData`.

`check-core.sh` against the lab server, with its changes (a lab server only: it makes and deletes albums, people,
links, accounts, a library, and changes a queue and the admin's own photos, putting each back), through the tunnel
below and with the lab's admin from its `.env.<instance>.local`, passed on the command line, never printed:

```sh
IMMICH_URL=http://127.0.0.1:<port> IMMICH_EMAIL=<admin email> IMMICH_PASSWORD=<admin password> IMMICH_WRITES=1 ./check-core.sh
```

A run that fails part-way leaves what it made (an album or a link named `Verso check...`, an account
`verso-check-...@example.com`); delete them with the lab's full key before the next run, or the lists compared differ.

`check-core.sh` holds the typed calls to the requests they replace: it asks each typed source both ways and compares
the answers field by field (the months, albums, people, a photo's details, searches page by page, Explore's and the
account's reads), and with `IMMICH_WRITES=1` makes each change typed and reads it back as a request. Dismissing and
resolving duplicates are not checked live: neither the demo nor the lab server has any. `check.py` also renders the
sidebar's import row in every state to `build/import-design/`, the bell's list, light and dark, to
`build/notifications-design/`, and App Icon in Settings, General, with the default looks and with two others chosen,
to `build/app-icon-design/`: look at them after changing one.

**Verso Dev, signed, in the maintainer's session.** Running needs a signed build (the extensions' entitlements), and
signing cannot happen over SSH: there the login keychain is locked ("User interaction is not allowed"), so codesign
cannot reach the key. `open -g -a Terminal mac/Verso/dev-app.command` from SSH runs `mac/Verso/dev-app.sh` in a
Terminal window of the maintainer's session (`-g` leaves it behind whatever the maintainer has in front): it builds
the bridge and the project, signed with `-allowProvisioningUpdates` (the free Personal Team then provisions the App
IDs, the App Group and the Keychain group), installs Verso Dev as `/Applications/Verso Dev.app` and starts it.
`mac/Verso/build/dev-app.log` has its output, ending in `exit <status>`, read over SSH. The team comes from the git-ignored `mac/Config/Local.xcconfig`
(`DEVELOPMENT_TEAM = <team>`); the team ID is the OU of the signing certificate: `security find-certificate -c "Apple
Development" -p | openssl x509 -noout -subject`. Another signed build goes the same way: a script of its own in
`mac/Verso/build/`, started with `open -g -a Terminal mac/Verso/build/<name>.command`, its log written beside it.

The first signed build stops at a keychain dialog ("codesign wants to sign using key ..."), which waits for the
maintainer's login password and **Always Allow**, once per key; later signed builds need nothing (verified). The
script's Terminal window stays open after the build; the maintainer closes it. `mac/Verso/dev-app.sh --remove`
quits Verso Dev, unregisters it and deletes it: sign it out first (Traps).

**The release chain** (Developer ID signing, notarization, the disk image) comes with ROADMAP.md, M9, step 6; no Mac
release of Verso has gone out. What the drive's earlier Mac releases settled is in ARCHITECTURE.md, "Verso Drive on
the Mac" ("Signing for release"). One trap carries over: notarytool's keychain profile is not found while the screen
is locked ("No Keychain password item found", with the maintainer away, two hours after it worked; seen on macOS
27.0.1), though the login keychain's signing key still is, so an unattended build notarizes with the API key file
(`--key <.p8> --key-id <ID> --issuer <issuer>`).

Traps of the build (macOS 27 with Xcode 27.2):
- **A Debug build's code is in `<name>.debug.dylib`,** beside a stub executable in `Contents/MacOS`, so `nm` on
  the executable finds none of the bridge's symbols; look in the `.debug.dylib`.
- **XcodeGen's `optional: true` still adds the file's reference** when the file is missing, and the build then
  fails on it (for an Icon Composer document: "Failed to create a catalog from the Icon Studio document").
- **A target that does not link `AppIntents.framework` by name** has its Shortcuts actions' metadata skipped
  ("Metadata extraction skipped, no AppIntents.framework dependency found"): the app lists it in `project.yml`.

## Run and drive

Verso Dev takes launch arguments as it starts (`AppModel.followLaunchArguments`, DEBUG only), so a script signs it
in and out without typing into the window; each outcome is logged (`category == "app"`, at info level). `open -n`
starts another instance beside one that runs: quit the running one first, each time.

```sh
app="/Applications/Verso Dev.app"
pkill -f "Verso Dev.app/Contents/MacOS"           # quit it; no Apple events, so no Automation prompt
open -n "$app" --args -signInServer http://127.0.0.1:2283 -signInAPIKey <key>
open -n "$app" --args -signInServer https://demo.immich.app -signInEmail demo@immich.app -signInPassword demo
open -n "$app" --args -versoDrive on              # Verso Drive's switch, as in Settings (or off)
open -n "$app" --args -signOut YES                # its account, its cache and Verso Drive's location go
open -a "$app" 'immich-crosslink-dev:///albums/<id>?server=http%3A%2F%2F127.0.0.1%3A2283'   # a link, to Verso Dev alone
/usr/bin/log show --last 2m --info --predicate 'subsystem == "dev.hviid.Verso" && category == "app"'
xcrun swift lab/mac/windows.swift Verso           # its windows, without Screen Recording
```

`open` from SSH starts the app in the maintainer's session, where the Keychain and File Provider work (verified:
Verso Dev signed in to Immich's demo, and to the lab server through the tunnel). Verso Dev takes crosslinks on a
scheme of its own, `immich-crosslink-dev:` (`mac/Verso/Verso/App/Crosslink.swift`), so it never takes or sends a
release's links.

- **On iOS, `-versoDrive on`** (or `off`) switches Verso Drive in a Debug build too, before a sign-in by launch
  arguments when both are given (`ios/VersoUITests/DriveWalkTests.swift`).

Verso Drive serves Finder only once the maintainer has switched it on, once per app: Enable at the top of the
location's Finder window, or its switch in System Settings, General, Login Items & Extensions, File Providers. Until
then fileproviderd logs "TCC access check failed for domain dev.hviid.Verso.Dev.Drive/library" and the extension does
not start. No command can do it for them.

## The server

The lab server in NAT mode (the `lab-immich-server` skill; LAN mode is never left up unattended), forwarded to the
Mac's loopback through Linux. For the showcase server (`ind-immich-show`, the one with photos for the iPhone Simulator
and screenshots), `lab/immich-server/tunnel.sh open --mac` opens both tunnels and checks them (`http://127.0.0.1:2290`
on the Mac and here), and `tunnel.sh close` closes them; by hand, for the plain server:

```sh
socat TCP-LISTEN:2283,bind=127.0.0.1,reuseaddr,fork \
  EXEC:"$EREBUS_DIR/bin/incus exec ind-immich-srv -- socat STDIO TCP\:127.0.0.1\:2283" &
ssh -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -R 127.0.0.1:2283:127.0.0.1:2283 "$MAC_HOST" &
```

The `incus exec` side needs `socat` in the server's container (`apt-get install -y socat` there, the
`lab-immich-server` skill); without it each connection ends at once ("Command not found" in socat's output, an empty
reply on the Mac). On the Mac the server is then `http://127.0.0.1:2283` (verified). Background jobs end after two
hours, the tunnels with them. The tunnel starts an `incus exec` per connection, which is slow when many open at
once: a request that times out makes the extension take the server as offline for 45 seconds ("the server was
unreachable moments ago"), as Linux does, so run checks one at a time. Loopback is not the local network, so macOS's
Local Network prompt never comes up; checking that prompt itself needs a LAN-mode server and the maintainer at the
Mac. The bridge's lab tests run on the Mac too, against the tunnel: `IMMICH_URL=http://127.0.0.1:2283
IMMICH_API_KEY_READONLY=<key> cargo test -p verso-bridge --test lab -- --ignored` (passed on macOS 27), with
rustup's cargo first on the PATH (Traps).

## Check

Verso Drive in Finder has no scripted check yet: Verso Dev's drive is checked by hand, with the maintainer at Finder,
through "Look" below. Verso's check of it comes with ROADMAP.md, M9, step 6, built after Immich Mount's Finder check
(`lab/mac/check.sh` in its own repository, `../immich-mount`).

**Measuring a motion against Photos** (Live Photos, the viewer, the grid's pinch), on the iPhone Simulator:
`ios/tools/live/make-pair.swift` makes a Live Photo as the Camera writes one from a lab video; `xcrun simctl
addmedia` adds it, or a demo original, to the Simulator's Photos, and it is uploaded to the lab server.
`ios/tools/live/record.sh <TestClass[/method]>` runs a UI test (`PhotosReferenceTests`, `LiveWalkTests`,
`LiveRealWalkTests`) while the Mac records the Simulator's screen, and `track.swift` matches each recorded frame to
the moment of the motion it shows (the script's header has the steps). Photos ignores the closing pinches XCUITest
makes, so its zoom outward cannot be measured that way.

## Look

- **Our log** (the app, Verso Drive's extension and the bridge): `/usr/bin/log show --last 10m --predicate
  'subsystem == "dev.hviid.Verso"'`, by category `app`, `drive` (the app's side of Verso Drive) and `extension`; the
  system's side: `subsystem == "com.apple.FileProvider"`.
- **The system's state:** `fileproviderctl dump` (domains, whether ours is enabled, its items); whether the
  extension is switched on: `fileproviderctl dump | grep -A4 '^domain: dev.hviid' | grep enabled`. macOS 27's
  `fileproviderctl` also has `diagnose`, `evaluate` and `check`.
- **The location on disk:** `~/Library/CloudStorage/VersoDev-Verso` for Verso Dev (named after the app and the
  drive), which SSH could list and read on macOS 27.0.1, and may not on 27.2 (Traps).
- **Thumbnails as Finder asks for them:** `xcrun swift lab/mac/thumbnail.swift <file>` (QLThumbnailGenerator).
  `qlmanage -t` reads the file itself, which downloads the original: no test of the extension's thumbnails.
- **Finder's actions on an item** (Open in Immich, Copy Immich Link): `cd` into the location and run
  `fileproviderctl evaluate <path>`; it prints the item as the system holds it (its `userInfo` among it) and each
  action's activation rule with YES or NO, which is what Finder's menu offers. Only for items the system already knows
  (a folder Finder or an enumeration listed); a path it does not know is "Couldn't find a file". It takes one path,
  so a rule about several selected items is not evaluated there. Each action the extension performs logs the address
  it opened or copied (`category == "extension"`), and `pbpaste` over SSH reads the session's pasteboard, so a copy
  can be checked (and replaces whatever the maintainer had copied).
- **Info-level lines** (downloads, listings, the launch arguments' outcomes) show only with `/usr/bin/log show
  --info`. A typed call through the core logs one (`typed: the months of LibraryStacked: 12`), so they show whether a
  page's reads went typed or as requests.
- **The app's windows,** when one "does not appear": `xcrun swift lab/mac/windows.swift Verso` lists each window of
  Verso and Verso Dev with its layer, bounds and whether it is on screen, without Screen Recording permission (it
  reads no names or images). A window on screen that the maintainer cannot see is behind another app's; `sample <pid>
  1` then shows whether the main thread waits in a modal alert (verified on macOS 27).
- **A known system error:** the same photo copied into Upload twice under two names makes `fileproviderd` log
  `itemChangedDuringPropagation` for `asset|upload|...` while it merges the two into one item. It passes; the photo
  reaches the server once and leaves Upload.

## Traps

Verified on macOS 27.0.1 with Xcode 27.2, unless a line says otherwise:
- **`xcode-select` may point at the Command Line Tools,** where `xcodebuild` refuses to run. Set
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` on our own commands (`dev-app.sh` and `check-core.sh`
  set it themselves); never change `xcode-select`.
- **Homebrew's `rust` formula beside rustup** puts a cargo without the x86_64 standard library first on the PATH.
  `mac/build-rust.sh` puts rustup's first for itself; other cargo commands need
  `PATH=$(brew --prefix rustup)/bin:$PATH`.
- **In zsh, `log` is a builtin:** call `/usr/bin/log`.
- **macOS caches an app's icon by its path.** A build at a path macOS saw without an icon keeps showing the blank
  placeholder (also in the app's own window, through `applicationIconImage`). `touch` the built `.app` and start it
  again, as `dev-app.sh` does; a fresh copy elsewhere shows the icon at once (verified on macOS 27).
- **fileproviderd keeps the extension's launch job at the path it first ran from.** After that build is deleted, a
  copy elsewhere (a build in `/Applications`) never starts: launchd logs "Attempt to re-bootstrap service from
  different path, will use existing" and "Missing executable detected", and Finder says the provider "encountered an
  error". `killall fileproviderd` (it runs as the user, and launchd starts it again at once) clears the job, and the
  next request starts the extension from the new path. Before deleting a build, unregister it: `lsregister -u <app>`
  (in LaunchServices.framework's `Support/`), as `dev-app.sh --remove` does for both copies.
- **Deleting the Dev app leaves its Finder location** in the sidebar: macOS keeps a provider's location until the app
  removes it (by signing out, or turning Verso Drive off), and serves it from any copy it still knows of (seen on
  macOS 27.2: deleted from Applications, the drive's earlier Dev app ran on from its build folder). Sign Verso Dev
  out first (`-signOut YES`), then `mac/Verso/dev-app.sh --remove`, which quits it, unregisters both copies (the
  installed one and `mac/Verso/build/DevData/`'s) and deletes them.
- **A keychain dialog left open waits for the maintainer,** and what waits behind it with it: Xcode's package
  downloads waited for over an hour behind one. `pgrep -x SecurityAgent` shows one is open; it is the maintainer's to
  answer, or, with their leave, stopping SecurityAgent cancels it.
- **No `osascript` over SSH, ever.** Apple events from an SSH session (to System Events, or `tell application … to
  quit`) make macOS ask the maintainer whether `sshd-keygen-wrapper`, the program that starts SSH sessions, may
  control that app, and accepting widens what every SSH session may do: a laptop setting this skill must not touch.
  Quit Verso Dev with `pkill -f "Verso Dev.app/Contents/MacOS"` (a signal needs no permission; macOS cuts process
  names at 15 characters, so `pkill -x` misses it), and ask the maintainer what is on screen.
- **SSH may not read the location or the App Group:** on macOS 27.2, `ls` of
  `~/Library/CloudStorage/<location>` and of `~/Library/Group Containers/<group>` from SSH answers "Operation not
  permitted", for every app's location, so nothing over SSH can list a folder, read a file there or leave a file for
  the extension. Granting sshd access is a laptop setting: not ours. `fileproviderctl evaluate <path>` (Look) still
  works on items the system already knows, and the unified log shows what the extension did.
- **`dev-app.sh` starts the app,** which shows its sign-in window on the maintainer's screen when nobody is signed in;
  `open -n ... -signInServer` then starts a second instance beside it. Quit the first (`pkill -f "Verso
  Dev.app/Contents/MacOS"`) before signing in with launch arguments, or the window stays up for anyone at the Mac to
  sign in with.
- **`open <link>` goes to the scheme's default handler,** which may be another app that takes the scheme (Immich
  Gallery Dev, for one), or a build left in `mac/Verso/build/`. Send a link to Verso Dev alone
  with `open -a "/Applications/Verso Dev.app" <link>`; choosing the default handler is the maintainer's setting,
  never ours.
- **Settings cannot be written from SSH** (the App Group is closed to it, above): Verso Dev's Settings window writes
  them, at the maintainer's hands, and `-versoDrive on` or `off` switches Verso Drive. A change of Verso Drive's
  settings has the system read every item again, and for a few seconds after, `getUserVisibleURL` may fail with
  "database is locked" (`SqliteErrorDomain` 5; seen on macOS 27.2).
- **A sandboxed app reads another app's Info.plist only in /Applications:** `Bundle(url:)` of an app in
  `~/Applications` or a build folder gives nothing (seen on macOS 27.2), so Verso finds an app that takes crosslinks
  only there. Verso Dev looks for apps that take `immich-crosslink-dev:`; `lab/mac/crosslink-app.sh` makes a test
  participant for the public scheme, `immich-crosslink`, which a release looks for. A test participant goes into
  /Applications for the check and out again with `--remove` right after; nothing else of ours is installed there but
  Verso Dev.
- **No command performs a Finder action:** `fileproviderctl evaluate` shows whether Finder offers one, and the log
  shows what the extension did, but the click is the maintainer's.
- **After `reimportItems`, the items of a folder carry no `userInfo`** until the folder is listed again (Finder
  visiting it, or a received link shown there): `fileproviderctl evaluate` then offers no action on them, not even
  Open in Immich (seen on macOS 27.2). Check the actions after Finder has listed the folder.
- **zsh aborts a command whose glob matches nothing** ("no matches found"), and the rest of an SSH command line with
  it. Run cleanup scripts through `bash -s`.
- **The Mac can read Verso Dev's own folder on a paired iPhone, never its App Group container** (iOS 27):
  `xcrun devicectl device copy from --domain-type appGroupDataContainer` is refused ("outside the
  directories the container access policy allows"), so backing up's store cannot be copied. Verso Dev writes what
  backing up waits for into its Documents (`backup-diagnostics-launch.txt` at launch, before the first pass changes
  anything, and `backup-diagnostics.txt` after each pass; BackupDiagnostics.swift), which `--domain-type
  appDataContainer --domain-identifier dev.hviid.Verso.Dev --source Documents/<file>` copies. Identifiers and states
  only; delete the copy once read.
- **The iOS Simulator cannot make Verso Drive's read-only folders:** its file provider daemon refuses to set their
  metadata (`cannotSetMetadata`), so only Upload shows at the root there, though it honours an ad hoc build's
  simulated App Group and Keychain group. To check the sections, a month's photos and an original's preview in the
  Files app there, make every item writable for the check.
- **The command line's `xcodebuild` may say "No Accounts" while Xcode shows one** (Xcode 27.2): a new extension's
  provisioning profile is then made only by Xcode itself, once, by opening the project and the target's Signing &
  Capabilities; later builds from the command line find it.

## Record

A check that settles a claim changes the doc where the claim lives, as the fact it shows (AGENTS.md, "No lab notes
in git"): ARCHITECTURE.md, "Verso on the Mac" and "Verso Drive on the Mac", for a reason; SPEC.md for behaviour; a
finished step in ROADMAP.md, M8, "Verso on the Mac", shrinks to a line. The run itself goes in the commit message. New
traps of the Mac go here.
