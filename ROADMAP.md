# ROADMAP

The single home for what is not built: milestones, open questions, and ideas parked on purpose. There is no
TODO.md and there are no stray TODO comments. Every milestone ends with an end-to-end check on Erebus (AGENTS.md,
"Testing on Erebus"). A finished milestone keeps a short entry: what it delivered, and where SPEC.md and
ARCHITECTURE.md describe it.

## M0. Design and spikes

Done: the docs with their credits, and the spikes in the GNOME VM and on the lab's Immich server that settled
thumbnail seeding, range reads, change tracking, the v3.2.0 floor and the drive's names (ARCHITECTURE, "Thumbnails",
"The Immich API layer" and "Version policy"; SPEC, "Verso Drive").

## M1. Read-only mount

Done: the core (`immich-api`, `verso-core`), the Linux adapter and the command line: the tree with its names and
attributes, membership from Immich's timeline, the metadata store with freshness windows, the block content cache with
range reads, the user service, and CI's gate with the core's portability check (SPEC, "Verso Drive" and "Content";
ARCHITECTURE, "Freshness").

## M2. Thumbnails, sign-in and live changes

Done: thumbnail seeding with the search-crawl rule and the safety net; the block cache's read-ahead, eviction and
offline behaviour; browser and password sign-in, kept in the keyring; changes from the sync stream; and Dex beside the
lab server for sign-in tests (`lab/immich-server/oidc.sh`) (SPEC, "Thumbnails", "Content" and "Signing in and
credentials"; ARCHITECTURE, "Thumbnails" and "Freshness"). Left: Pocket ID (passkeys) beside Dex, for a sign-in
checked by hand.

## M3. Uploads

Done: staging, upload on close, receipts, temporary names, duplicates and trashed duplicates, the errors programs see,
notifications, and folders copied into Upload with their albums, on Linux and the Mac, each through an adversarial
review (SPEC, "Uploads" and "Folders copied into Upload"; ARCHITECTURE, "Uploads" and "Folders copied into Upload").
Left to see:
- a Cancel in Files' progress popover, by hand
- what macOS does with a copied folder the extension deletes while it still holds a file it has not handed over (the
  pending set is read first to avoid it)

## M4. The GNOME app

Done, as Immich Mount's settings app: first run, sign-in by all three methods, the settings from the shared settings
table, status, About with the notice, and start at login. Its pages live on as Verso's Preferences (ARCHITECTURE, "One
layout for every settings window").

## M5. First release

Done, for Immich Mount: rpm and deb packages, Homebrew's cask and headless formula, the install matrix, README
screenshots, AppStream metadata, its download page, and a public repository whose history is one commit. Immich
Mount's releases, and the lab checks of them, go on in its own repository; Verso's are M9, step 6.

## M6. KDE edition

Done, for Immich Mount: a Kirigami app, and the drive in Dolphin with its previews and KWallet. KDE left this
repository with Immich Mount (M9); the drive's Plasma integration lives in Immich Mount's repository, for a native KDE
frontend to take ("Parked on purpose").

## M7. macOS edition

Done, for Immich Mount: Finder through Apple's File Provider on the same core, with live changes, sign-in and settings
as on Linux, uploads, and a notarized disk image that updates itself and installs with Homebrew (ARCHITECTURE, "Verso
Drive on the Mac"). Verso Drive on the Mac is the same extension (M8, "Verso on the Mac").

Open:
- **Apple silicon only:** build the Mac app for `arm64` alone, without `x86_64-apple-darwin` in the bridge
  (`mac/build-rust.sh`), the archive and the disk image, and have the cask's macOS part depend on `arm64`. macOS 26
  is the last release for Intel Macs (Apple, WWDC 2025), so macOS 27 runs on Apple silicon only, and no one the
  maintainer knows uses an Intel Mac; meanwhile every release compiles the bridge a second time on the Mac runner, the
  slowest job of the release workflow. Easily added back, should an Intel user ask.
- **The Local Network prompt,** with a server on the LAN: macOS asks only before an app reaches a local address, so
  a server whose address is public never brings it.
- **How Finder shows a refused upload,** and **signing out with a file waiting in Upload** (removed with
  `preserveDirtyUserData`: where macOS keeps the file, and that Finder opens that folder).
- **Three points the milestone's review could not check without a Mac:** that a location the system paused after
  "server unreachable" resumes once the app reports the server back (`signalErrorResolved`); what macOS does with
  files waiting in Upload when `uploads.enabled` is turned off; and that a reimport after a settings change, which
  matches items by name, never keeps an old file's bytes under a name that moved to another Asset.
- **A new item format without a reimport** (ARCHITECTURE, "Verso Drive on the Mac", "Content"): the reimport leaves
  items unmatched until macOS runs a deferred import. Expiring the change anchor would have the system enumerate
  again without dropping its database; whether that refreshes the items it holds outside the working set is to be
  tried before the next format change.
- **Partial content** (`NSFileProviderPartialContentFetching`): a video that plays before it is fully downloaded,
  with the block cache back in use. Worth it once whole downloads are measured on a slow link.
- **What the poll cannot see** (a swap that keeps a month's count): on Linux the freshness windows catch it at the
  next visit, but the system revisits nothing it holds. Listing held folders again in the background, slowly?
- **A command line on macOS** (`status`, `doctor`), or none: the sandbox keeps the store and the credential out of
  reach of a plain program.

## M8. Verso

One app with a gallery, the drive and the tray, as Immich Gallery is on the Mac, on the same crates (ARCHITECTURE,
"Verso"). Built in the private `verso` repository, whose source goes public with the first public release. Until then
the releases are test builds for the maintainer's own testing, made by hand on the Linux workstation and published
from the public `jakobhviid/verso-releases`, which Homebrew's `verso` cask downloads from.

Built on Linux: the gallery's window with Immich Gallery's pages (ARCHITECTURE, "Verso's window"), and Verso's service
with the tray and the drive, off until switched on; named apart from Immich Mount so both can be installed, and taking
Immich Mount's account over on request (SPEC, "Signing in and credentials"). Not yet checked against a server:
resolving duplicates (which needs the lab server built with machine learning, `up.sh --ml`), stacking similar photos,
the import panel, Change Password and the profile picture.

1. **On a real GNOME desktop** (`lab/gnome-vm/`), still to see: Open With's chooser (the lab session has no
   `xdg-desktop-portal`), a sign-in by single sign-on (the `app.immich` redirect, which Verso and Immich Mount's app
   both claim), drag and drop to and from Files, and how the grid scrolls through a large library.
2. **What Immich Gallery has on the Mac and Verso lacks:** tabs (several accounts are left out on both: Verso
   signs in to one). Check `edited=true` on thumbnails against Immich v3.2.0, the floor (the spec check,
   `tests/contract_spec.rs`).
3. **A native KDE frontend,** parked (below).
4. **Partners' photos** show in the Library (`withPartners` on the gallery's own scope, so the drive's stays as it
   is); a partner's photo there is theirs, and changing it is refused by Immich, not yet kept from the menus.
5. **Translations** of the gallery's texts, once they settle (`po/i18n.py`; the crates are not in its sources yet).
6. **Packages:** Verso's tarball and cask are there (`linux/packaging/verso-tarball.sh`), and the Flatpak's manifest
   (`linux/packaging/flatpak/`), built by hand in the GNOME VM; Fedora and Ubuntu packages and AppStream data are not.
7. **On macOS, then iOS,** named Verso there too, on the same crates and the one version line (ARCHITECTURE,
   "Verso's releases"). The Mac edition comes first, from the maintainer's fork of Immich Gallery ("Verso on the
   Mac", below).
8. **Going public,** with the first public release. Before it:
   - a Mac edition at parity with Linux ("Verso on the Mac", below)
   - a map tile service that allows the traffic (ARCHITECTURE, "Verso's window")
   - every release built by the release workflow (`.github/workflows/release.yml`), as Immich Mount's are, in place
     of the builds on the workstation: Actions is switched off in this repository. It builds the tarball and the
     Flatpak; the packages on Linux and the Mac's disk image, signed and notarized on GitHub's Mac runner, join it
     (M9, step 6)
   - `jakobhviid/verso-releases` retired: the releases come from `jakobhviid/verso`, so the cask's `url` and
     `homepage`, and Preferences' "Installing Verso with Homebrew" link (`preferences.rs`), point there
   - decided with the maintainer:
     - **The history:** cleaned into one commit at the public launch, as Immich Mount's was (M5), tagged `v1.0.0`;
       every earlier tag goes, with this repository's releases. Before the history is rewritten, all of it (every
       branch and tag) is kept as a git bundle on the workstation's disk (`~/developer/Backups/verso/`, with every
       release's files), for a while after. Only the one commit's tree goes public: right before the squash it is
       scanned for keys, credentials, private addresses and personal photos. Prepared on a branch; `main` is
       overwritten on the maintainer's word at that moment.
     - **The releases before the launch:** evaluation builds the maintainer alone uses, so `verso-releases` is retired
       at the launch with them, and this repository's tags and releases go with its history.
     - **The license:** MIT, as today (`LICENSE`, the workspace's `Cargo.toml`), with the notices of the code taken
       from others in THIRD-PARTY-NOTICES.md, so anyone, Immich's own apps first, may take any idea, design or code
       from Verso (README, "License").
     - **How Verso is paid for:** free, on every platform. Donations may come later, not now.

### Verso on the Mac

Verso on the Mac starts from the maintainer's fork of [Immich Gallery](https://github.com/IGOLz/ImmichGallery),
Alessandro Craciun's native Mac client for Immich (MIT), and is adapted to this repository's way, not the other way
round. Alessandro gets the credit: CREDITS.md and the README's credits link to his repository and say the Mac edition
is built from his app, and its MIT notice stays in THIRD-PARTY-NOTICES.md, which names the Mac edition beside
`verso-desktop`.

**Where it starts:** the fork's `integration` branch (`jakobhviid/ImmichGallery`, checked out at `../ImmichGallery`),
upstream's main with the maintainer's pull requests merged in, taken at `50bb4c3` (CREDITS.md records it).

**The first version** is built (ARCHITECTURE, "Verso on the Mac"):
1. **Copied** into `mac/Verso/`: the app and its widget, with Immich Gallery's offline checks (`check.py`), and Verso
   Drive in place of its Finder extension.
2. **Immich through our Rust crates:** the views' endpoint calls go through the core's client (`check-core.sh` checks
   each), and what the views need and the crates lack is added to the crates, so Linux has it too. Next, checked on
   the Mac:
   - finding the server and browser sign-in through the core's sign-in, as Immich Mount's Mac app does (a password
     sign-in and signing out go through it): first settle whether the core reads `/.well-known/immich` and tries
     `http://` after `https://` for an address typed without a scheme, as the Mac's discovery does and the core's
     does not, and check browser sign-in through the lab's Dex from the Mac
   - uploads and downloads through the core's upload and download calls, as Verso Drive's uploads go
   - pictures through the core, once it keeps a cache for them on the Mac
3. **Immich 3.2 and newer only,** as on Linux. What tells 3.2 from 3.3 (people filtered on the server) stays while 3.2
   is supported.
4. **No trace of the old name** but the credit. The About panel carries the credits, the AI disclosure and the
   non-affiliation notice.
5. **No updates from Immich Gallery:** Sparkle is left out; Verso's own feed and key come with Verso's first Mac
   release.
6. **Verso's identifiers** are in the project: `dev.hviid.Verso` and `dev.hviid.Verso.Dev`, each with `.FileProvider`
   and `.Widget`, and an App Group of its own. The developer portal does not have them yet: the maintainer makes the
   App IDs, the App Groups and the Developer ID provisioning profiles. The team's Developer ID certificate signs
   Verso too. Verso Dev is built signed with automatic signing, which registered its development App IDs.
7. **Verso's icons,** drawn by `mac/Verso/make-icons.py` (DESIGN.md, "The icon family") and approved by the
   maintainer; the Icon Composer documents' glass, tinted and clear appearances are unseen.

**Immich Gallery's design notes** (`docs/` in the fork at `50bb4c3`: the account, the Finder extension, the widget
and the rest), which the copied code cites, go into ARCHITECTURE.md and SPEC.md, and the comments then cite those.

**What the Mac takes from the iPhone:** the iPhone app, built after the Mac's, found how to make a grid, a pinch, Live
Photos and sharing feel native, and the Mac follows it where that applies; backing up, Free Up Space and the iPhone's
video bar stay the iPhone's (the Mac's floating video controls are its own native look). In order:
1. **The photo grid on AppKit's collection view** (`NSCollectionView` with a layout of Verso's own): built
   (ARCHITECTURE, "The photo grid on the Mac"). Left: photos taken out sliding into their new places.
2. **The pinch as the iPhone's,** on that grid: built (ARCHITECTURE, "Pinching between sizes").
3. **Live Photos as the iPhone's:** built (ARCHITECTURE, "Verso on the Mac", "Live Photos move as the iPhone's").
   Left, with the maintainer at the Mac: the glimpse starting with the step as the arrow keys, the side arrows and a
   swipe bring a Live Photo, moving on the slide, the neighbours' motions ready ahead and a quick run of steps; the
   badge's place and look under the toolbar, in the light and dark appearances; ⌥Space and the toolbar's Live, with
   sound.
4. **Share opens the system's picker at once:** built (ARCHITECTURE, "Verso on the Mac", "Share opens the system's
   share picker at once"; SPEC, "Sharing from the Mac").
5. **Card pages pinch and keep their place:** built (ARCHITECTURE, "Verso on the Mac", "A pinch goes through the card
   sizes"). Left: the iPhone's motion, the cards zooming as one grid with the fingers, once the cards are on the photo
   grid's collection view (steps 1 and 2); and, with the maintainer at the Mac, the pinch on each page and the place
   kept, at the top, the middle and the foot of a long page, and every step of − and +, ⌘− and ⌘+ and the pinch
   changing the cards, − or + off at the ends, in a narrow and a wide window.
6. **Notifications:** Clear All in a section of more than one, and the bell orange while one needs a look, built
   (ARCHITECTURE, "Verso on the Mac", "An import shows at the foot of the sidebar"). Left, with the maintainer at the
   Mac: the orange bell in the light and dark sidebars, and Clear All of the server's notifications on a server that
   has several.
7. **The date scroller ticks** on a Force Touch trackpad at each month a drag crosses: built (ARCHITECTURE, "The date
   scroller"). Left, with the maintainer at the Mac: feeling it on the trackpad, months apart and close together.
8. **The details under a photo settle at two stops,** the photo alone or the details at rest, once measured against
   Photos on the Mac; the maintainer finds the plain scroll fine, so it comes last.

**Next, with the maintainer at the Mac:** the library and the viewer as they look, the widget, the icons as macOS
draws them, and the pages built after Linux's designs (ARCHITECTURE, "Verso on the Mac", "Pages after Linux's
designs"), which build and pass the checks but nobody has looked at yet: a link's page and the photo picker, the Share
sheet and the sharing icon, memory cards, the banner when the server cannot be reached, album covers and cards with −
and +, cities with their names, people as rounded squares, Shared Links as cards, and Search's people. On each, that a
small button on a card (an album's sharing chip, a memory's bookmark) takes its own click. The map under the toolbar
and the sidebar (ARCHITECTURE, "Verso on the Mac", "The map goes under the toolbar"): its top's blur beside the other
pages', in the light and dark appearances, MapKit's controls and Legal label, and the map fitted to the photos as it
first shows.

**Face boxes on an edited photo:** none show (`PhotoFaces.swift`), as on Linux: Immich measures faces on the unedited
photo, and the viewer shows the edited one. Showing them needs each box carried through the photo's edits (its crop,
turns and mirrors).

**Verso Drive** is Immich Mount's drive, as on Linux (ARCHITECTURE, "Verso on the Mac"): built, switched on from the
app, its location added with the gallery's account. Next:
- the location as Finder shows it (its root and sections are served): browsing into the folders, opening,
  thumbnails, uploads (Immich Mount's Finder check, `lab/mac/check.sh` in its repository, shows what to check)
- Finder's Show in Another App…, and the question about folders copied into Upload, as Immich Mount's app has them
  (its SPEC.md, "In Finder": with several apps, **Show in Which App?**, a button for each and **Cancel**, Return for
  the app chosen last, a list once there are more than six)
- unmounting that only unmounts, as on Linux: the location disconnected (`NSFileProviderManager.disconnect`) with the
  switch left on
- starting at login while signed in, as Verso's service does on Linux, so changes keep reaching Finder
- **Settings as a sidebar,** as the Mac's System Settings and Verso's Preferences on Linux have it, with its icons at
  the side: easier to navigate, to group into categories and to hide pages in. (Immich Mount's Settings on the Mac
  switch their panes from the toolbar.) Its look is the maintainer's to settle. Verso Drive's switch then shows two more
  entries, its Status and its settings, as Verso's Preferences do on Linux

**Building and releasing:** on the Mac, or by GitHub's Mac runner once the release pipeline builds Verso; never on the
Linux workstation, which cannot. Before the first Mac release, the release steps the one version line needs
(ARCHITECTURE, "Verso's releases"):
- titles that name the release's platforms ("Verso 3.9.1 (Linux)")
- a step that puts a checked Mac build (the disk image and its update file) on its commit's release, names macOS in
  the title and adds the macOS section to the notes
- Linux's notes without the Apple editions' commits
- the Mac update window's notes from those macOS sections alone: `site/build.py` takes the notes of the latest six
  releases, Linux-only ones included
- Verso's cask with a version per system, checked against Homebrew first: its audit refuses a `sha256` inside
  `on_macos` and `on_linux`, and whether it takes a `version` there is not known

## M9. The repository becomes Verso's alone

Immich Mount lives on in its own repository and has left this one, and nothing here keeps its name. KDE left with it:
without a maintainer who uses KDE every day, it is not kept.

**Sorted by where it runs: shared, then Linux, then the Mac, then iOS.** One rule decides: what more than one
platform uses goes in `shared/`, what one platform alone uses goes in its folder. `shared/` over `libraries/`, as the
maintainer asked and Kotlin Multiplatform lays its projects out (`shared/` beside an app per platform): it answers the
same question its neighbours do (where it runs), where "libraries" says what kind of code it is, and Linux holds
libraries too. What is in it is named by what it does, never "common" or "utils", so it does not become a drawer.

```
shared/             used by more than one platform
  immich-api/       the Immich client and models
  verso-core/       the portable core: the library as a model, naming, membership, the store, uploads, links, the
                    sign-in flow, the settings table, the product's names
  verso-bridge/     the uniffi bridge Swift calls on the Mac; the Swift it generates is built, not kept
linux/
  verso/            the GTK window, with Verso Drive's settings pages
  verso-desktop/    what the window does, without a toolkit: sign-in, the drive's switch, the library's sections,
                    the grid's layout, imports, notifications
  verso-linux/      FUSE, the keyring, D-Bus, thumbnails, the tray: what the service and the window share on Linux
  verso-service/    the drive's daemon, the tray and the command line
  files-extension/  the Files extension (Nautilus)
  packaging/        the Flatpak, the tarball, the desktop entry, the service unit, the icons; rpm and deb come with
                    step 6
mac/                Verso/ (the Xcode project: the app, the widget, the checks), FileProvider/ (Verso Drive's
                    extension), Shared/, build-rust.sh (the bridge for Xcode)
ios/                the iPhone and iPad app (M10)
lab/                the GNOME and Bazzite VMs, the Immich server, the Mac's helpers
```

Translations stay in `po/` at the root, where gettext's tools look, and serve Linux and the Mac alike.

**Two crates where the first sketch had one:** `verso-linux` stays free of GTK, so the service never links it; the
drive's settings pages, which are GTK, live in the window (`verso`), and what the window does without a toolkit is
`verso-desktop`, from Immich Mount's desktop crate and the gallery's together. Later, an area at a time (step 8): the
library as files leaves `verso-core` for a `verso-drive`, what is portable in `verso-desktop` moves into
`verso-core`, and `VersoKit/`, the Swift the Mac and iOS share with the bridge's bindings, comes with iOS (M10, "How
it is built").

**What still names Immich Mount,** on purpose: the credit to Kartax's app (Verso's drive comes from Immich Mount),
Immich Crosslink, the protocol between apps, and the takeover of Immich Mount's account.

**The order:**
1. The Linux and the Mac work under way committed. Done.
2. What leaves removed in one commit: the Immich Mount apps, the Mac's Immich Mount app, KDE whole, and Immich Mount's
   package names, desktop entry, metainfo, Homebrew template and download page (`site/`). Done.
3. One commit moves and renames, changing no behaviour. Done.
4. The product switch keeps Verso alone, and the names inside the code are Verso's, on Linux and the Mac. Done.
5. The docs are Verso's alone. Done. The principles stand as written, KDE's among them, for the native KDE frontend
   that may come, which takes the drive's Plasma integration from Immich Mount's repository ("Parked on purpose").
6. Releases cut by a tag, Linux and the Mac together (below). Built: `ci/release.sh` with every step and `--dry-run`,
   `ci/version.sh`, the Mac's and iOS's build number as the build's UTC time, and `.github/workflows/release.yml`
   building Linux's files (written, not yet run: Actions is off) (AGENTS.md, "Versioning"). Left: the rpm and deb
   packages; `mac/release.sh` and `ios/release.sh`; the Flatpak on the workstation, which has no flatpak (the GNOME VM
   builds it from the source archive `build` leaves in `target/dist/`, and it is attached to the drafts by hand);
   Verso's release check and packaging matrix, for the check of a draft, built after Immich Mount's (`lab/check/`,
   `lab/packaging/` and `lab/mac/check.sh` in its repository); publishing's rebuild of the page (step 7);
   and the first release cut with it.
7. Verso's page at `jakob.hviid.phd/verso`, presented at the top of `jakob.hviid.phd/software`, with a design of its
   own rather than a list: Verso on each platform in pictures from the lab's showcase server, a download for each
   (the Flatpak, the tarball, Homebrew, the Mac's disk image, the App Store), what Verso Drive is, the non-affiliation
   notice and the credits. Designed and shown to the maintainer before it goes live.
8. Next after the releases (the maintainer: very near), an area at a time: what the Mac does in Swift and Linux in
   Rust moves into `verso-core`, the Mac and the iPhone call it through the bridge (`arrangements`, or a module of the
   area's own, as the date scroller's `rail`), and the Swift twin goes (ARCHITECTURE.md, "Verso on the Mac", "What the
   gallery arranges comes from the core"). Each area keeps its behaviour, the Swift checks' cases in the core's and
   the bridge's tests.
   - Done: the Library's Years and Months (`verso_core::overview`), the map's clusters (`verso_core::map`),
     duplicates' order and shared links' filter (`verso_core::duplicates`, `verso_core::shared_links`), people's
     filter (`verso_core::people`) and the date scroller (`verso_core::rail`; ARCHITECTURE.md, "The date scroller").
     Left: the Mac's rail and Linux's scrubber, tried by hand.
   - Next, in this order, the easiest and most shared first (the Swift files in `mac/Verso/Verso/App/`):
     1. Places: `PlacesArrangement.swift` (by country or not, by visit or name) and `places.rs` (by country only):
        the sorting by visit joins the core.
     2. A photo page's view options: `GridArrangement.swift` and `arrangement.rs`, into the timeline's query.
     3. The albums' view settings: `AlbumsArrangement.swift` and `CollapsedGroups.swift` against `albums.rs`.
     4. The sidebar's layout: `SidebarLayout.swift` (the Mac's sidebar and the iPhone's Collections) and
        `sidebar.rs`, which remember it differently, so the move carries the layouts kept.
     5. Recent searches and Verso's own notifications: `SearchHistory.swift` and `VersoNotifications.swift` against
        `search.rs` and `notifications.rs`, with what they keep per account.
     6. How far an album or a link reaches: the Mac's `SharingReach.swift` (its links' expiry in Swift, checked by
        `check.py`) and the iPhone's `AlbumsShareReach`, against the window's `sharing.rs` (`Audience`).
     7. Imports: `UploadQueue.swift` and `uploads.rs`, the largest, around each platform's file access.
     8. The Immich client's calls: the typed calls (ARCHITECTURE.md, "Typed calls") bring immich-api's models, and
        the Swift models and `ImmichClient` go as the views take the bridge's records.

**Releases are cut by a tag** (AGENTS.md, "Versioning", has how; ARCHITECTURE, "Verso's releases", why). Not built
yet, beside step 6's list:
- `ci/release.sh build` making the rpm and deb packages, beside the tarball and the Flatpak, checked in a packaging
  matrix of containers still to be built (step 6).
- Until Actions is on, the Mac's disk image built on the Mac (`mac/release.sh` in the maintainer's session, notarized
  with the API key file) and attached to the draft, and the iPhone app sent to TestFlight from the Mac
  (`ios/release.sh`, with an App Store Connect API key).
- `ci/release.sh publish` rebuilding Verso's page, once the maintainer has checked the draft (installed in the lab's
  desktop VMs, and the Mac build).
- The workflow running the same steps on a pushed tag once Actions is switched on and holds the signing secrets; the
  scripts are what it calls, so the two never differ.
- The look for a newer release (`updates.check`, off and hidden in Verso; `linux/verso-service/src/updates.rs`) reads
  Immich Mount's page. With Verso's page (step 7) it reads Verso's `latest.json`, and is on for the rpm and deb
  packages, which nothing else updates.

## M10. Verso on iOS

Verso on iPhone and iPad, native, in Liquid Glass, on the same crates and Swift as the Mac, and on the one version line
(ARCHITECTURE, "Verso's releases").

**What it is beside Immich's own app.** Immich's app is cross-platform and backup first. Verso on iOS is the gallery:
native SwiftUI in iOS's own design, the library laid out as on the Mac and Linux (the same sections, pages, edits and
links), Verso Drive in the Files app, and one design from the phone to the Mac. It backs the iPhone up too (below).

**The floor: iOS and iPadOS 26.1,** Liquid Glass's first release with `tabViewBottomAccessory(isEnabled:)`, which
switches the tab bar's capsule on and off without the empty capsule 26.0 leaves (iPhone 11 and later), built with Xcode
27's SDK. iOS 27's refinements, the Liquid Glass slider from clear to opaque among them, reach the system's own
components without our code, which is the main reason to build on them. Nothing in Photos' iOS 26 design needs 27.

### The design: the photos are the content, the glass is the controls

- **Glass only on the controls,** never on photos and never glass on glass: the tab bar, toolbars, sheets, menus, and
  a few floating controls of our own. The system's components first (`TabView`, `toolbar`, sheets,
  `.buttonStyle(.glass)` and `.glassProminent`), since each iOS release refines them for us; `.glassEffect` inside a
  `GlassEffectContainer` only for our own floating controls.
- **The grid edge to edge under the glass,** as Photos in iOS 26, and the scroll edge effect keeps the top controls
  readable over photos.
- **The tabs:** Library first, Collections last, Search in the trailing search tab (`Tab(role: .search)`), and between
  them up to two pages of the person's choosing (Albums by default, the maintainer's choice; People, Map, Memories,
  Shared Links, Archive). Two, as the iPhone shows four tabs beside Search and folds a fifth into the system's More tab,
  which Verso never shows. Collections holds every other section, as the Mac's sidebar has them, in the order Edit
  Sidebar keeps, leaving out what the bar holds; each collection with cards is a block of its own (a header, its cards
  beneath), plain rows in grouped boxes. Every tab is a NavigationStack over its own path of `Route` values
  (`ios/Verso/App/Routes.swift`). The Archive in the bar is its photo grid with its own View Options, selection and
  Unarchive, and a tap on its tab goes to its newest photos, as the Library's does.
- **The account lives in Collections,** as Photos keeps its profile there: its picture with the unread count as a
  badge (also on the Collections tab), opening the account's sheet, whose first section is the notifications, Verso's
  and Immich's; beside it "+", for New Album and importing from Photos or Files. No other tab shows the account.
- **The Library's top bar holds View Options and Select alone,** beside a large title whose line says what matters
  now: an import's progress (a tap for its details), the days in view, or the count at the newest end. Every page's
  title stays large in the bar's row (under the back button on a pushed page) and never shrinks, with the photos or
  cards running under it and the soft scroll edge effect. It is the page's own view in a bar over the content
  (`ios/Verso/Grid/PageTitle.swift`), as the system's large title shrinks once the content leaves its top, and a
  timeline opens at its bottom.
- **View Options, as Photos' menu:** the sort (Date Captured, Date Added) as two large buttons on top, then the filter
  (All Items, Favorites, Shared with You, Captured by Me, which is the account's own photos without partners', Not in
  an Album, Media Types), Library View (Mine, or Mine and Partners', Immich's own "Show in timeline" for each partner,
  its choice under its name), and the grid's look (square or aspect ratio, the date scroller). Photos' Edited is left
  out: Immich cannot filter by it. Every photo page has the options that fit it, from the Mac's per-page keys; Order
  only on pages that read down.
- **The bottom, as Photos':** scrolling away from the newest photos (back in time) shrinks the tab bar to the current
  tab, and Years / Months / All stands inside it between that tab and Search, as narrow as its three segments; at the
  newest end the full bar returns and the picker goes. The picker is never the accessory's full width: the accessory is
  switched on only while it reports itself inline (`tabViewBottomAccessoryPlacement`), the one sign of a shrunk bar. In
  Years and Months the whole bar stays, with the picker in a glass capsule of our own above it.
- **Where the Library lands:** its home is the newest photo, at the bottom (or the top, with Newest at the Top), where
  it opens. Whatever replaces what the grid shows (a filter, the sort, Library View, Years or Months back to All) lands
  there, with the full bar and no picker, and so does a tap on the Library tab while it shows (iOS's would go to the
  top, which with Newest at the Bottom is the oldest photo). Only a chosen photo is kept in view: a month or year picked
  in Years or Months, Show in All Photos, and the photo the viewer closed on.
- **Newest at the Bottom or at the Top:** one setting of the device's own, in every timeline's View Options: Newest at
  the Bottom, as Photos, by default, or Newest at the Top. Every grid that opens at its newest photos follows it (the
  Library, Favorites, Videos, the Archive, Recently Deleted, a person's photos): where it opens and lands, which way
  scrolling shrinks the tab bar (away from the newest end), when Years / Months / All shows, the count under the title,
  the date scroller, the viewer's order, and Years and Months. An album keeps its own sort and order, as on the Mac.
  Changing it lands the grid at its newest end.
- **The card pages** (Albums, People, Memories, Places and a country's places, Shared Links) share the Mac's five card
  sizes (`cards.size`), through a pinch or View Options' Zoom Out and Zoom In: Albums shows the Mac's cards (the cover
  beside two more of its photos, on a fade at its foot the name, the count and the years, and whom it is shared with;
  its reach in the corner); people are their faces with their names on them; a shared link is the Mac's card (what it
  shares, on a fade its name, what it is and who may see it, in its corners until when it works and what visitors may
  do), two to a row on an iPhone at the smallest, with Share in the fade's corner at a finger's size and Copy Link,
  Share Link, Edit and Delete in its long press, as the Mac's row of small buttons under a card suits a pointer. Their
  titles stay large in the bar's row. Albums is in sections by year, newest first, by default; its search and All /
  Mine / Shared with Me wait above the page and come with a pull down, as Mail's search. A pinch zooms the cards as one
  grid about the card under the fingers, each card fading to its look at the next size, as the photo grid's pinch
  does, and Zoom Out and Zoom In make the same motion about the middle of the view (ARCHITECTURE.md, "Pinching between
  sizes").
- **An album's page:** its name is the bar's title; above the photos the count and the days, the description written
  in place, and the header's statuses as on the Mac (its reach with the faces it is shared with, comments and likes
  in a sheet, Add Photos); its menu has Sort, Newest First or Oldest First, for anyone (ARCHITECTURE.md, "An album's
  order is its own"), with the page opening at the first photo of its order, then Rename, Choose Cover, Comments and
  Likes, and Delete or Leave. A person's page likewise: the face, the count and the birthday; Favorite, Shown, Merge
  and Rename.
- **iPad:** the iPhone's tabs in iPadOS's floating bar at the top (`.tabViewStyle(.tabBarOnly)`), never a sidebar,
  which made the iPad look like another app (the maintainer's choice), with room for one more chosen page (Albums and
  People by default) and Search apart at the bar's end; drag and drop between apps, several windows. The iPad is the
  iPhone app, with no interface of its own to keep (the maintainer: as little to maintain twice as possible).
- **Motion:** the maintainer's rule holds (motion only for what the person does; nothing animates in as it loads).
  iOS's push and zoom transitions are the platform's answer to a tap, and platform conventions win (PRINCIPLES).

**What makes it fresh, with Liquid Glass:**
1. **The date scroller** as a glass pill on the trailing edge that names the month it points at, and, held, shows the
   years down the edge on a glass strip, scrubbing finer as the finger moves left.
2. **An import goes on in the background** (`BGContinuedProcessingTask`) with the system's own progress, and ends in
   the account's notifications, as on the Mac and Linux.
3. **Selecting morphs:** the Select button becomes the selection toolbar, with the count, and Share, then Add To,
   Favorite and "..." (the menu of photo actions) together, then Delete along the bottom; a sideways drag across the
   tiles selects them.
   - **One menu of photo actions** wherever a photo is acted on: a long press on a tile, the selection bar's "...",
     and the viewer's "..." (`ios/Verso/Grid/PhotoActionsMenu.swift`), from Photos' long-press menu on iOS 26 and in
     its order: Copy, Save to Photos and Hide in a row along the top; Share and Favorite; Add To (Album…, Shared
     Album…, New Album…, New Shared Album…, Tag…), Move To and Adjust Info (Adjust Date & Time, Adjust Location,
     Adjust Description, Rating), opening in place; what only the page offers (Show in All Photos or Show in Archive,
     Use as Album Cover, Stack, Remove from Album in red; in the viewer, Start Slideshow); Delete alone in red at the
     foot. What does not apply is left out, never dimmed, and what a bar beside it holds is left to the bar.
   - **Decided by the photo, not the page:** an archived photo shows in albums, Favorites, people, places and
     searches too, so wherever it shows it has Show in Archive (Verso's counterpart of Show in All Photos, as Photos
     has no archive: the Archive opened at the photo, on its tab or as Collections' page) and Move To the Library;
     the others Show in All Photos and Move To the Archive, as Photos' Move To offers the other library. A selection
     of both is offered both, each photo moving only where it is not already; out of the Locked Folder, both. The
     Mac's viewer follows the same rule for Show in All Photos; the Mac has no reveal in the Archive.
   - **Share is Photos'** (SPEC.md, "Sharing from the iPhone"): the system's share sheet opens at once, each original
     downloaded only when the chosen app asks, under its own name, and beside the apps Create Link… and Add to Link…,
     which download nothing.
   - **Hide** is Photos' word for Immich's Locked Folder, which opens with the PIN or Face ID; once the photos are
     there, the grid says so ("Hidden in the Locked Folder"), naming the place as Collections does.
   - **Save to Photos** puts the originals into the phone's library with add-only access, a Live Photo as both its
     parts, dated and placed as Immich has them; a photo backing up knows is on the phone already is not saved again.
4. **The viewer, as Photos':** it opens out of its tile with UIKit's zoom transition, presented over the grid, the
   shown photo its alignment rect, and Back or a drag down shrinks it into the tile of the photo shown last, which the
   grid keeps in view as the viewer pages (ARCHITECTURE.md, "The viewer on the iPhone"). The photo travels alone: the
   controls come once it has landed, fade before Back's zoom and as a drag begins, and come back if the drag is let
   go, and the system's dimming, in the viewer's background colour, is the only background meanwhile. A drag closes it
   only with the photo fitted and its details down, never sideways; a playing video shows its poster as it closes. A
   tap hides its controls, leaving the photo on black; a capsule with the place and the date at the top, "..." beside
   it, a filmstrip of the neighbouring photos above a bottom bar of Share, Favorite and Info, and Delete. A swipe up
   slides the photo up and scrolls its details beneath it, as cards: the caption, the rating's stars where the account
   has ratings on, the date, the camera, the exposure, the map, then the people, albums and tags. Edit (the sliders,
   beside Favorite and Info) crops and turns the photo through Immich's edit list, changed as Linux changes it; a
   stack's badge under "..." opens its photos (Set as Cover, Remove from Stack, Unstack). Places are named from
   Immich; Apple's names for landmarks and parks only with Look Up Place Names with Apple Maps, a setting of the
   device's own (ARCHITECTURE, "Security and privacy").
5. **Memories full screen,** as stories: progress along the top, glass controls, the next with a tap.
6. **Search's suggestions as glass chips:** people with their faces, places, recent searches; the filters in a sheet.
7. **The Locked Folder behind Face ID,** with Immich's PIN once per session.
8. **The app icon is the Mac's Icon Composer document** (`AppIcon.icon`), which has the clear and tinted looks iOS
   asks for; the picture's six other designs are alternate icons, chosen in App Icon in the account's sheet
   (ARCHITECTURE, "The app icon's designs on the Mac, the iPhone and the iPad").
9. **Places by name lead to photos:** Map | Places, the countries, a country's cities, a city's photos; a cluster on the
   map opens that area's photos. A pinch or a pan that starts on a pin moves the map, and a tap on one opens that area's
   photos.

### How every feature maps

| Verso on the Mac and Linux | Verso on iOS |
|---|---|
| The sidebar: Library, Albums, People, Places, Map, Memories, Favorites, Shared Links, Archive, Trash, Locked Folder, Duplicates, Similar Photos, Explore | Library tab; the rest in Collections, ordered as Edit Sidebar keeps them (the setting both share); on iPad, too, the tab bar, not a sidebar |
| Search, its filters, order and history | The Search tab: suggestions as chips, filters in a sheet |
| The grid: zoom levels, selection, drag | Pinch through the zoom levels; Select and swipe to select; a long press for the menu of photo actions with a preview; drag on iPad |
| The viewer: details, date, place, description, rating, favorite, stacks, Live Photos, video, crop and turn | Shown in place, as on the Mac, the photo flying out of its tile and back (ARCHITECTURE.md, "The viewer on the iPhone"); details pulled up beneath the photo; a Live Photo moving briefly as it is swiped to and played whole while held, its LIVE badge one switch for all of them (ARCHITECTURE.md, "Live Photos"); a video zooming and pinched closed as a photo, with the viewer's own video bar; crop and turn through Immich's edit list, as on Linux; a stack's photos in a sheet |
| Albums as cards, sharing with people and links, Add Photos | The Mac's five card sizes, by pinch; the Mac's cards; an album page with its header's statuses; sharing in a sheet |
| Import by drop and Import… | The photo picker (the camera roll), the Files importer, a share extension (Verso in every share sheet, to the library or an album), drops on iPad; progress in the line under the Library's title |
| The bell: Verso's notifications and Immich's | The account's sheet in Collections, its first section, each with × and a section of several with Clear All, with a ring round the account's picture while any is kept and the unread count on it and the Collections tab; an import's end as a local notification while in the background |
| Verso Drive (FUSE on Linux, a File Provider on the Mac) | Verso Drive in the Files app: the Mac's File Provider extension and the same bridge, off until switched on |
| Immich Crosslink | None for now: Open in Immich and Copy Link, web addresses (ARCHITECTURE.md, Crosslink "Not on the iPhone and the iPad") |
| Widgets (Featured, Favorites, Album, Person, Place, Chosen) and Shortcuts (Search, Open Album, Next Photo) | The same WidgetKit and App Intents code: Home Screen, Lock Screen and StandBy widgets, Shortcuts, Spotlight; a Control Center control that opens Search |
| The menu bar item, the tray | None: iOS has neither |
| Preferences | The account's sheet: the account, its Immich features, Verso Drive, Administration for admins |
| Administration | In the account's sheet, for admins: the server's statistics, jobs and users |
| Sign-in in the browser, with a password, with an API key | A welcome and the server's address, then its ways in: single sign-on through `ASWebAuthenticationSession` (passkeys and password managers work there), a password, an API key; the Keychain group shared with the extensions |
| The slideshow | The memories player for any album or selection; AirPlay |
| Taking Immich Mount's account over | Not on iOS |

**Not in the first version:** several accounts (as on the Mac and Linux), and Show in other apps.

**A photo picker in Messages,** Verso in Messages' list of apps, is built (ARCHITECTURE and SPEC, "Verso in
Messages"); what is left of it is in "The smaller gaps on the iPhone".

### Backing the iPhone up, and Free Up Space (step 8)

**Backing up is built** (ARCHITECTURE, "Backing the iPhone up"; SPEC, "Backing the iPhone up"), and so are hidden
photos, into Immich's Locked Folder while Hidden Photos is on. What is left:
- **Hidden photos on a real iPhone:** the hidden album with Use Face ID off, a hidden Live Photo, the review's PIN and
  Face ID, and an account without a PIN.
- **What only a real iPhone shows:** uploads going on while Verso is suspended and after it is killed; Back Up Now's
  progress and its Stop; runs on its own overnight, with and without Only While Charging; originals only in iCloud, and
  a download that fails; a library of thousands (the listing's time, the store's size, the tally while it checks);
  cellular and Low Data Mode; Live Photos, edits, bursts and RAW+JPEG, with their stacks and pairing in Immich; Quick
  Start to a new iPhone; a full server, a revoked key, an emptied trash, and a server restored from an older backup;
  coming to the foreground after a real suspension; a wake-up for the session's answers topping the uploads up while
  Verso is suspended, so backing up goes on past the first batch; an outage's pause with a server at home and the phone
  away, ending as it comes home; the Live Activity on the Lock Screen and in the Dynamic Island, kept up to date while
  Verso is suspended and taking over after the system's ended; Ready to back up's Start Backup from a locked phone; the
  first run's check four files at a time on an Optimize Storage library. An edited photo arrives as two tiles until its
  stack is made.
- **Immich's own app's iCloud identifiers** are read and written for photos never edited (ARCHITECTURE, "Known by
  Immich's own app's iCloud identifiers"). Edited photos would need the time of the edit, which that app reads through
  a key of PhotoKit's that is not public; a Live Photo's video carries none. Whether it pays on a real library (Verso
  Dev counts the fingerprints so known) is to see on a device.

**Free Up Space is built** (ARCHITECTURE, "Free Up Space"; SPEC, "Free Up Space"). What only a real iPhone shows:
- what Don't Allow on iOS's delete question returns (PhotoKit's user cancelled, taken as no with nothing changed, in the
  Simulator);
- the delete of 48 MP ProRAW photos, in a request of its own with 90 seconds;
- the check of a fingerprint borrowed from Immich, which reads the photo, from iCloud where it is only there;
- the warning when a freed photo leaves Immich within its 30 days;
- the card for a phone short of space, on a phone that is.

**The system's own uploads.** iOS 26.1 has PhotoKit's background upload extension
(`PHBackgroundResourceUploadExtension`): the system schedules the uploads, fetches iCloud originals itself and resumes
them. Immich cannot take its raw request bodies until its resumable uploads are merged (immich-app/immich#22385), and
Apple has a reported bug where the extension never runs while iCloud Photos is on. Verso's transport sits behind a
protocol, so the extension takes over once both are settled and it is shown to cover every case backing up handles
(ARCHITECTURE, "Backing the iPhone up"): the Live Photo's order, stacks, the metadata set after an upload, and the
checks.

**To check:** an upload into the Locked Folder with a session token not unlocked (an API key's needs none).

### How it is built

1. **The bridge for iOS:** built: `VersoBridge.xcframework` has the iOS slices beside the Mac's (`aarch64-apple-ios`,
   `aarch64-apple-ios-sim`; `mac/build-rust.sh --ios`), one framework for every Apple target.
2. **VersoKit** (`shared/VersoKit`; M9's layout): what the Mac's app has that is not AppKit, the API layer (`API/`),
   the core's wrapper (`VersoCore/`), the drive's account (`mac/Shared/`), the widgets' and the intents' code, and the
   models. Shared sources compiled into each Apple app, as `mac/Shared` is, not a Swift package: a package would need
   every type the apps use made public. Most of `App/`'s models import Foundation alone; `AppModel`,
   `AssetGridModel` and `UploadQueue` keep their few AppKit lines (`NSImage`, one `NSEvent`, the open panel) behind
   `#if os(macOS)`, and the Mac-only rest (the menu bar, the viewer's windows, the downloads' panel) stays the Mac's.
   iOS's project compiles them where they are in `mac/` first; once both apps build, they move to `shared/VersoKit`
   in one commit, the paths in the projects, `check.py` and `check-core.sh` with them.
3. **`ios/`,** an XcodeGen project as the Mac's: the app, Verso Drive's File Provider extension (the Mac's code, on the
   replicated File Provider API iOS has too), the Messages app and the widget extension, with Verso Dev beside the
   release, as on the Mac, are built; the widgets themselves and the share extension are not.
4. **iOS's own views** (tabs, sheets, the viewer), with VersoKit's shared pieces where they fit: the thumbnail
   loading, the tile, the cards' layout. Built.
5. **Checks:** VersoKit's tests on the Mac; the app in the Simulator over SSH (`xcodebuild test` with an iOS Simulator
   destination, and `xcrun simctl io booted screenshot` for the design checks, as the Mac's offscreen renders); on a
   phone by the maintainer, through TestFlight.
6. **Release:** TestFlight, then the App Store, on the one version line. It needs the paid Apple Developer Program
   (the team behind the Mac's Developer ID), an App Store Connect record named "Verso for Immich" with the
   non-affiliation notice in its description, the privacy manifests (built: ARCHITECTURE, "Privacy manifests"), and a
   demo server for App Review (Immich's demo).

**The order:**
1. The bridge's iOS slices and the shared models compiling for iOS, then steps 2 to 4 by area in `ios/Verso/`: built,
   in the Simulator against Immich's demo, where the UI tests in `ios/VersoUITests` walk it and keep a screenshot of
   each place. What is left is in "The smaller gaps on the iPhone".
2. The skeleton: sign-in, the three tabs, Library's grid and the viewer with its zoom. Built.
3. Collections and Search; album pages; selecting and its actions. Built.
4. Imports: the photo picker, Files, their progress under the Library's title, going on in the background, and the
   notifications, built; the share extension is not.
5. iPad: the tab bar at the top without a sidebar (built), drag and drop, several windows. Before the first release.
6. Verso Drive in Files (built; SPEC, "In the Files app"); widgets, Shortcuts, Control Center (below, "Verso in the
   system's places").
7. TestFlight, then the App Store, with the walkthrough video (below, "The walkthrough video").
8. Backing the iPhone up and Free Up Space: built; what is left is above ("Backing the iPhone up, and Free Up Space").

### The walkthrough video

Once the iPhone app is near done: one long screen recording of the release build (Verso, not Verso Dev) against the
lab's showcase server and its free photos (backing up is never offered on Immich's demo), for Reddit and to show
Immich's team everything worth taking, which the README invites them to (README, "License"). It walks the main
features in order: backing up switched on from the Library's card, the first run's check and Start, its Live Activity
in the Dynamic Island and on the Lock Screen, the Library's line while it syncs and the Backup page it opens, Free Up
Space; Verso Drive in the Files app; the Library and its zoom levels; albums as cards and an album's page; moving
through photos in the viewer, and the details; memories, people, places, Collections and Search. Recorded on the
Mac's iPhone Simulator, with the Lock Screen and Files shown as iOS draws them, and left in the Mac's home folder.

### Verso in the system's places

Every idea below is a possible choice, none chosen yet:
- **Widgets:** today's memory, opening its story, for the Home Screen and StandBy; an album or a person, chosen in the
  widget's settings, its photos in turn; backing up, the lens in its ring with what is left ("34 to go", "Backed Up",
  "2.1 GB to Free"), small and on the Lock Screen, opening the Backup page.
- **Shortcuts** (App Intents, the Mac's where it has them): Back Up Now and how backing up stands; Find Photos, by text,
  person, place or date, giving photos or files; Upload to Immich, of what a shortcut is given, into an album if asked;
  Add to Album; Share Link, giving its URL; Open an album, a person, a memory or Search; and App Shortcuts, so Siri and
  Spotlight offer "Show my memories in Verso".
- **Control Center and the Lock Screen:** Back Up Now with the run's state, Pause Backing Up for an hour, Open Search,
  Open Memories; through them, the Action button too.
- **Spotlight:** the albums and people indexed, found from the Home Screen's search.

### The smaller gaps on the iPhone

- Selecting by holding a photo and dragging, as Photos does, in a way that leaves the grid's scrolling alone (the
  gesture tried took every touch from it).
- Verso in Messages: On This iPhone, the phone's own newest photos from PhotoKit with those on their way to Immich, and
  videos; and what only a real iPhone shows: its memory, sending, large originals, a server on the local network, and
  the icon.
- Share on an iPhone: Messages, Mail and AirDrop, a large video on a slow network (the sheet shows no progress while an
  original downloads), Save Image, and the phone's own photos.
- Save to Photos for a Live Photo and a video, and the phone's own tiles' menu.
- The viewer on a phone: Live Photos, the Locked Folder and light mode.
- A viewer walk on the lab server; iPad keyboard shortcuts; Verso Drive's settings; editing an external library's
  paths; saving an edit checked against the lab server.
- Verso Drive switched off: the Files app still lists an empty location named after the app, as iOS keeps an
  extension's own default location while its app has none (SPEC, "In the Files app"; ARCHITECTURE, "Verso Drive on
  the iPhone and the iPad"). Whether it can go.

## Next, in order

Agreed with the maintainer; each item's detail is where it points.
1. Releases cut by a tag (M9, step 6), with Linux's rpm and deb packages.
2. The Swift twins into the Rust core (M9, step 8), an area at a time.
3. Hidden photos into the Locked Folder (M10, "Backing the iPhone up"): the checks a real iPhone needs.
4. iPad, before the first release (M10, step 5).
5. Trusting a self-signed server certificate, for homelabs without a private CA in the system store.
6. Linux's map from the Immich server's own map setting (`mapLightStyleUrl`, `mapDarkStyleUrl`; Immich's own
   `tiles.immich.cloud` unless its admin chose another), drawn by libshumate's vector renderer (in Fedora 44's 1.6.3),
   in place of OpenStreetMap's servers, whose usage policy forbids an app's traffic. Apple's systems keep Apple's maps.
7. Verso's page, with its design (M9, step 7).
8. Verso in the system's places, and the smaller gaps on the iPhone (M10).
9. The walkthrough video (M10).
10. The history cleaned at the public launch (M8, "Going public").

## The full Immich API

Done: `immich-api` covers the API a full Immich client needs, each endpoint in the spec check, with contract tests
against the lab server, the machine-learning ones on a server built with `up.sh --ml`, and against Immich in Docker in
CI (`contract` in `.github/workflows/ci.yml`) (ARCHITECTURE.md, "The Immich API layer").

## Open in Immich, and links between apps (Immich Crosslink)

Right-click items in the file manager that open what it shows somewhere else: in Immich's own web app, and in other
Immich apps on the same computer; the other way round, any app can ask Verso to show a photo, album, person or place.
Apps find each other through [Immich Crosslink](https://github.com/jakobhviid/immich-crosslink), a small open protocol
published at <https://jakob.hviid.phd/immich-crosslink/>; Verso implements draft 0.2. When this section and the
protocol differ, the protocol wins and this section is the bug. Neither app signs in for the other: a link carries ids
and the server's address, and works when both apps are signed in to that server. SPEC.md, "Links to Immich", "Links
from other apps" and "Show in other apps", has what Verso does; ARCHITECTURE.md, "Links to Immich", why.

### The item map

Built: one module in `verso-core` (`links.rs`) maps an item's key to its Immich path, the path of Immich's web app for
it, and back, and makes the web address and the crosslink of a path, so the same item gives the same link on every
platform. SPEC.md, "Links to Immich", has the map; the protocol's test links
(`shared/verso-core/tests/crosslink-links.json`) run in its tests.

### The steps

1. **Open in Immich and Copy Immich Link,** in Files, Finder, Verso's window and the terminal: built. Left: a release
   check line for the items, once Verso has a release check (M9, step 6).
2. **Show in Verso, from any app:** built on Linux (Verso Gallery and Verso Drive) and the Mac (Verso's window).
3. **Show in other apps:** built on Linux. Left: for a second or so after the service starts, an item in a folder it
   has not listed yet gets no items; the desktop VMs' check of the settings' rows for the apps (Not found, Forget,
   Learn More); on the Mac, Finder's Show in Another App… (M8, "Verso Drive").
4. **Immich Gallery takes crosslinks** (upstream): merged into IGOLz/ImmichGallery (#47).

### Open, to settle on each desktop
- **Mac (step 3):** how soon Finder offers or drops an action after an app is installed or removed: the menu bar app
  re-reads the items when it sees an app launch, which an install alone does not do.

## Package repositories

The real fix for updates on Linux (ARCHITECTURE.md, "Updates on Linux"): with a repository behind the packages, GNOME
Software and Discover offer each release like any other update, and the daemon's own look can stop for them.
1. **COPR for Fedora** (and Fedora's atomic desktops through `rpm-ostree`), built from the release's rpms or its
   sources. Needs the maintainer's Fedora account and a COPR project.
2. **An apt repository for Ubuntu,** signed, served beside the download page.
3. **Then:** packages from a repository carry a marker the daemon reads, and do not look for releases themselves.
4. **One package on every distribution,** as the tarball is: the window and the service together, one install and
   one version (ARCHITECTURE.md, "One package, two programs"), with the C Files extension built against that
   distribution's Nautilus, the launcher, the service unit, the icons, the translations and the license notices
   (ARCHITECTURE.md, "Packaging"). The system's GTK 4 (4.18 at least), libadwaita (1.8 at least), libshumate and
   fuse3 are real dependencies. Compatibility comes before size: it must install and run the same on every
   distribution and version, never relying on what a desktop happens to ship.

## Watch upstream

- **Blueprint and GTK 5 interface definitions.** The GNOME app's screens are written in Blueprint, which still
  calls itself experimental. Follow its releases, and GTK's GTK 5 planning on how interfaces are defined (an
  intermediate format was floated in April 2026). Pin the Blueprint version in the build, and migrate deliberately
  when the direction settles.
- **zbus 6 and oo7 0.7.** zbus 6 folds `zvariant` and `zbus_names` into itself, and RustSec marks the standalone
  crates unmaintained (RUSTSEC-2026-0370, -0371, -0372; informational, no vulnerability). The keyring goes through
  oo7, whose zbus 6 release (0.7) is in beta; move both together once oo7 0.7 is released, so one zbus is linked.
- **fuser and `FUSE_REQUEST_TIMEOUT`.** Once fuser can set the request timeout in its init reply, the daemon asks
  the kernel for a long one instead of shortening its own waits (ARCHITECTURE.md, "Uploads").

## Open questions

None outside the milestones' own "To settle" and "To check" notes.

## Performance

Where opening a folder stands, measured on Bazzite 44 GNOME against the lab server, a month of 450 photos the daemon
had not seen (`lab/bazzite-vm/freeze.sh`; the second figure with 20 ms added to every request):
- The folder appears in 0.5 s (1.3 s): its listing, then its small thumbnails seeded.
- Files' main thread is busy for 0.4 to 1 s, and responsive again 2 to 2.5 s after the click.
- rom-properties, which Bazzite's Files loads, gets through the folder in 1.5 s (1.9 s); with every file's edges
  already on disk it takes 0.7 s (0.9 s), the most any prefetch of originals could give.

These are the options for when that is not enough on a real server, with what each gains and costs
(ARCHITECTURE, "Content" and "Thumbnails", has the measurements behind them).

| Option | What it gains | What it costs |
|---|---|---|
| **Principle 2 and the edge prefetch** (decide) | Keeping the prefetch keeps rom-properties' pass at 1.5 s (1.9 s); without it, 3.4 s (12.9 s), growing with the files and the round trip | It fetches the start and end of files a program has not opened yet, though it reads them within seconds: the same bytes either way, unless the folder is left early. Amend the principle to allow that, or drop the prefetch |
| **Start the edge prefetch when a folder is listed,** once a program was seen peeking in this session | Most of what is left of rom-properties' pass (1.5 s towards 0.7 s), since the edges come while the folder's thumbnails are seeded; not measured | The same bytes as today, fetched earlier; a folder left at once still gets its edges, up to 80 MB |
| **Edges for counted subfolders** | The best case (0.7 s) on the next click | 80 KB for every file of every subfolder shown: opening a year of 3,000 photos fetches 240 MB, most of it for folders never opened. Against principle 2 |
| **Originals ahead,** a photo's neighbours when one is opened | Little: image viewers load the next and previous photo themselves | 2 to 10 MB a photo, gigabytes a folder: a mirror, against principle 2 |
| **Prefetching thumbnails beyond what file managers list** | Folders two levels down open as fast as the next click does | The folders one level below are seeded ahead already, since Files and Dolphin list them to count their items; going further fetches thumbnails for folders nobody shows, multiplied by People and Places |
| **Thumbhash placeholders** | A folder appears after a short wait whatever the server: Immich sends a thumbhash with every Asset, a blurred image in a few dozen bytes, and a seed made from it where the real one is late records no failure | A new dependency, and blurs instead of thumbnails on the first visit of a slow folder until the next. Seeding takes 0.5 s (1.1 s) for 450 photos |
| **More small-thumbnail fetches at once** (12) | The folder's 0.5 s (1.3 s) on a slow link: the lab server answers 500 small requests a second eight at a time, 145 one at a time | More load on the server, whose limits differ from the lab's |
| **Kept listings at once after a restart** | A folder's first visit after a login answers without waiting for its listing | It would need to know which kept listings changed while the daemon was down: the first sync stream of a run only sets the baseline, and a listing the change poll forgot must never come back from the store |
| **The daemon's copy of Immich's thumbnails in `cache.limit`** | Bounded disk: at 30,000 photos the copy holds 13 GB (17 KB thumbnail and 415 KB preview each), and nothing evicts it before signing out | An evicted preview is fetched again when its folder is seeded again |
| **Sharp thumbnails and GNOME's 512 MB thumbnail cache** | Revisits without seeding again | A sharp seed is 1.1 MB, written twice where home is a symlink: GNOME's housekeeping keeps about 200 photos' worth and deletes the rest, which the daemon writes again on the next visit (CPU, no download). Default PNG compression makes seeds 16% smaller for 30 times the CPU; sharp thumbnails off cuts a photo's seeds to 0.29 MB |

## Parked on purpose

| Idea | Why it waits |
|---|---|
| **Flatpak** | It needs host-command access for FUSE (the Pika Backup pattern), and Flathub acceptance is uncertain. When it comes: our own repository first, then Flathub. The design follows the Flatpak readiness rules in ARCHITECTURE until then |
| **A sealed headless credential** | Without a keyring the credential is a 0600 file, as SSH keys and most CLIs keep theirs. Encrypting it with a key kept beside it would add nothing; `systemd-creds encrypt --user` could seal it to the machine (and its TPM), so disk copies and backups never carry it readable |
| **Partners in Verso Drive** | Partners' photos belong to someone else's timeline; a `Partners/` section, far ahead (the maintainer's choice) |
| **Offline albums** | Pin chosen albums in the cache, showing the size first. Never the whole library |
| **A loopback sign-in redirect** | The RFC 8252 norm, but the admin must register it at the identity provider. An option for servers without mobile sign-in configured |
| **GNOME Shell search provider** | Immich smart search in the Activities overview: a Linux-only extra |
| **A native KDE frontend** | A Kirigami window over `verso-desktop`, as the GTK one is, may come once someone who uses KDE every day can keep it. Until then Verso runs on Plasma as on GNOME, the GTK window and Verso Drive. The drive's Plasma integration (Dolphin's Places, the doctor's check of Dolphin's remote previews, KDE's thumbnail sizes, Plasma's notifications, Klipper for copied links) lives in Immich Mount's repository, verified with its KDE edition: a KDE window takes it from there (ARCHITECTURE.md, "What Verso is") |
| **Nautilus extension, beyond its links** | More menu items in Files, beside Open in Immich and Show in *app* (above) |
| **Several servers or accounts** | The cache already separates accounts, so this is additive |
| **"Move to Trash" mapped to Immich's trash** | It makes a library-wide change one keystroke away in a file manager. Needs careful thought first |
| **Folder names in the user's language** | The interface is translated (ARCHITECTURE, "Translations"), the folders are not: a section's or a month's name is part of the mount's contract (SPEC, "Names"), and a path that changes with the desktop's language breaks scripts, links and bookmarks |
| **A Mac in the lab** | A Mac build server would run the Mac's checks unattended, as the Linux VMs do, and take its README pictures against the lab server, which come from the maintainer's own library until then (DESIGN.md, "Screenshots") |
| **More languages** | Next by reach: Persian, Swahili, Tagalog, Punjabi and Hausa, once someone asks or offers to check them |
| **The websocket for `all` API keys** | Every credential is polled every 10 seconds, so changes show within seconds already; the websocket would shave those seconds for one kind of key, at the price of a socket.io client and a second connection |
| **fanotify pre-content events** | Real placeholder files, the closest Linux match to macOS and Windows. They need root today |
