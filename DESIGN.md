# DESIGN.md

How Verso looks: one identity, drawn natively on each platform. This guide says how to use the icons, the colours,
the type and words, and the screenshots. ARCHITECTURE.md, "Verso's window" and "Verso on the Mac", keeps the reasons behind
each icon and how it is built; the platforms' own guidelines (GNOME's, Apple's) govern everything else.

## Principles

1. **Native first.** Each edition looks like its platform's own apps: libadwaita on GNOME, AppKit and SwiftUI on the
   Mac. The identity comes from the icon, never from restyling the platform's controls, colours or fonts.
2. **The lens is the brand, the print is the body.** Verso is the other side of a photo: every icon is a print with
   the lens and its ring of five segments in its picture and its corner turned over; its shape follows the platform:
   edge to edge on Linux, in Apple's rounded square on the Mac.
3. **Immich's colours, never its shapes** (AGENTS.md, "Hard rules"). The five colours stay accents: the print and
   the lens carry the identity, so nothing looks like an official Immich page or app.
4. **Say we are unofficial** wherever the project presents itself (SPEC.md, "The non-affiliation notice").
5. **Measured, not guessed:** every surface works in light and dark, and contrast is checked against WCAG AA
   wherever we choose the colours.

## The icon family

| Where | What | Source |
|---|---|---|
| Linux: the launcher, About, the window | The app icon: a print as the square, edge to edge as Linux shows app icons, the lens with its five-colour ring in its picture, Verso written by hand on its strip, its corner turned over to show the back. It is Mist on Day paper with its lens in colour, the first of the picture's looks (below), or the looks chosen in Preferences for the light and the dark style | `linux/packaging/icons/dev.hviid.Verso.svg`, drawn by `linux/packaging/icons/sources/app-icon.py`, made into `dev.hviid.Verso.png` and `hicolor/<size>/dev.hviid.Verso.png` by `linux/packaging/icons/linux-app-icon.py`; the other looks `dev.hviid.Verso-<look>.svg`, by the same script |
| Linux: Verso Drive on its folder, in a dock and in other apps' Show in | The app icon with a drive's badge in its corner, so the drive is not taken for the app | `hicolor/<size>/dev.hviid.Verso.Drive.png` (`linux-app-icon.py`) |
| Linux: the top bar, notifications, Verso Drive in Files' sidebar and in Preferences | The app icon's lens alone, as the Mac's menu bar icon and Finder's sidebar symbol are: its ring in five segments with the gap at the top, and the glass's rim with its light, in one colour (symbolic). In the top bar it shows the state as the sync apps do: faded and struck through while the server cannot be reached, faded with a key while signed out, a pause badge while the drive is unmounted; in one colour by default, or in colour (`tray.colour`: the lens's five colours, lost while faded) | `linux/packaging/icons/dev.hviid.Verso-symbolic.svg`, `dev.hviid.Verso-<state>-symbolic.svg`, `dev.hviid.Verso-tray[-<state>].svg`, drawn by `linux/packaging/icons/sources/symbolic.py` and `states.py` |
| Linux: the window's own symbols | Where Adwaita has none, or none that fits: the date scroller, a favorite's heart, a memory's keep, a Live Photo, Add Photos, sharing's reach (private, people, a link with a password, a public link) and the others named `verso-*` | `linux/packaging/icons/verso-*-symbolic.svg`; the heart, the keep, the Live Photo, Add Photos and sharing's reach but the public link drawn by the scripts in `linux/packaging/icons/sources/`, the others by hand |
| Apple TV: the Home Screen and its Top Shelf | tvOS's layered icon in four layers, which the remote's focus tilts apart as Apple's own do: Mist at the back; a print's back, cream, with Verso written on it by hand as on an old photo's back; a print's front over it, turned the other way, its paper and turned corner with the strip left blank, so Verso is written once; and its lens alone at the front. tvOS shows one icon in light and dark alike, so the app's is the Day one, on Mist; Night, the same on a night sky, is drawn as its alternate icon, for Settings on the TV to offer once the App Store takes it (ROADMAP.md). The static Top Shelf images are the Day picture, flat and wider, behind the shelf's memories and photos (`ios/TV/make-tv-icons.py`, from the Linux master, which also draws the print edge to edge, by day and by night, kept as alternatives) |
| Mac: Dock, Finder, System Settings, About | Verso's print in Apple's rounded square, on Apple's grid (the square 824 wide on a 1024 canvas): the picture's corners rounder, to follow the square's; the square's corner beyond the fold grey (what the print lies on; macOS 26 fills the whole square), darker in the dark appearance; the turned corner's tip rounded by half the square's corner; at 16 and 32 px the word in a broader pen. On macOS 26 and later an Icon Composer document: the paper as the background, its light appearance Mist's Day look and its dark appearance Mist's Night look, the lens's glass a glass layer, tinted and clear the system's. The Dev build's icon is the release's in every colour but the turned corner's back, which is blue with DEV stamped on it in white (the maintainer's choice); the grey beneath the corner stays the release's, as a shadow does. The looks chosen in Settings, General, for light and for dark mode are the icon in the Dock and the app switcher while Verso runs, as the drawing for macOS 15 has them | `mac/Verso/Verso/AppIcon.icon`, `AppIconDev.icon`, and `Assets.xcassets/AppIcon.appiconset` and `AppIconDev.appiconset` for macOS 15, in Mist (`mac/Verso/make-icons.py`, `--dev` for the Dev build's); the other looks `Assets.xcassets/AppIcon-<Look>.appiconset` and `AppIconDev-<Look>.appiconset` (`AppIcon-SandNightGraphite`; `--design <design>`, `--graphite`) |
| Mac: the menu bar item | The app icon's lens alone (the maintainer's choice). By default in one colour, as menu bar icons are: a template image, which macOS draws in the menu bar's black or white, the lens as Finder's sidebar symbol draws it. In colour where Settings, General, says so (Show the Menu Bar Icon in Color, off by default, as Linux's `tray.colour`): its five colours round its glass. The Linux top bar's states as their own images: a pause badge while the drive is unmounted, faded (in colour, the colours gone) and struck through while the server cannot be reached, faded with a key badge while signed out. What a state adds is cut clear of the lens; in colour it is mid-grey with white on it, so it shows on a light menu bar and a dark one. The same in the Dev build: its app icon and name tell the two apart | `Assets.xcassets/MenuBarIcon[<Unmounted, Offline, SignedOut>].imageset`, and the same names with `Colour` after them in colour; PNGs at 1x and 2x (`mac/Verso/make-menu-bar-icon.py`, run by `make-icons.py`) |
| Mac: Verso Drive in Finder's sidebar, and the Verso Drive tab in Settings | The lens as a symbol: its ring in five segments with a gap at the top, and inside it the glass's rim with the light on it (the maintainer's choice). Each segment is a layer that asks for its colour (red, pink, yellow, blue and green, the system's nearest the ring's; the glass the accent) where macOS draws a symbol in colour; Finder's sidebar draws its locations in one colour, where it is the same shape. The same in the Dev build | `Assets.xcassets/SidebarSymbol.symbolset` (`mac/Verso/make-symbol.py`, run by `make-icons.py`) |
| iPhone and iPad: the Home Screen, Spotlight and Settings, and the picture of the icon on the sign-in page, in About and in App Icon | The Mac's icon, from the same Icon Composer documents. Another design or the graphite lens chosen in App Icon is an alternate icon: the print edge to edge as one picture, its Day look as its light appearance and its Night look as its dark one, which iOS rounds and makes its tinted and clear looks from. The picture in the app is the icon's square, Day and Night, of the design and lens in use, as reading an app icon back is no API and can fail inside UIKit | `mac/Verso/Verso/AppIcon.icon`, `AppIconDev.icon`; `ios/Verso/Assets.xcassets/AppIcon-<Design>[Graphite].appiconset` and `AppIconDev-<Design>[Graphite].appiconset`; `AppIconImage.imageset`, `AppIconDevImage.imageset` and the same with `-<Design>[Graphite]` before `Image` (`mac/Verso/make-icons.py`, `--design <design>` and `--graphite` for another's) |
| iPhone and iPad: Messages' list of apps | The lens alone, its five colours round its glass, filling the circle Messages shows its apps' icons in, on the barrel's own dark (the maintainer's choice); 4:3 where Messages asks, square where Settings and the App Store do; opaque, its corners the system's. The same in the Dev build | `ios/Messages/Assets.xcassets/MessagesIcon.stickersiconset` (`mac/Verso/make-icons.py`) |
| iPhone and iPad: backing up's Live Activity, on the Lock Screen and in the Dynamic Island | The lens alone, its five colours round its glass, without the barrel's dark rim (the Dynamic Island's black would swallow it), a point inside a ring of the activity's own that fills as the run goes. The same in the Dev build | `ios/Widgets/Assets.xcassets/Lens.imageset` (`mac/Verso/make-icons.py`, or `--lens` for it alone) |

**Why the Finder sidebar's symbol looks different:** Finder draws every location in its sidebar as a one-colour
outline that follows the sidebar's text colour, as iCloud Drive's, OneDrive's and Nextcloud's are. A coloured icon
there would stand out from its neighbours as foreign, so ours is the Mac's app icon traced as a symbol: the print as
Apple's rounded square with its corner turned over, the lens as a ring of five segments with its centre, and the word
as a line of writing.

**The Mac icons were approved by the maintainer** from `make-icons.py`'s preview, and changes to them need the
maintainer.

### The picture's designs

The print's picture comes in seven designs, all kept (the maintainer's choice, 2026-11-22), and each design in four
looks: on **Day** or **Night** paper, with its lens in **Colour** or in **Graphite** (the maintainer's choice), 28 in
all. **Mist** on Day paper in colour is the app icon on every platform, and Mist on Night paper its dark appearance
where the platform's icon has one; the others are drawn beside it, as
`linux/packaging/icons/dev.hviid.Verso-<look>.svg`, the look named by its design with `-night` and `-graphite` after
it as they apply (`sand`, `sand-night`, `sand-graphite`, `sand-night-graphite`). Where they are offered:
- **Linux:** Preferences, General, **App Icon**: a look for the desktop's light style and one for its dark style, each
  any of the 28 (`app.icon`, `app.icon_dark`), for the launcher, the dash, the window, About and the sign-in page;
  Mist in Day and Night by default.
- **The Mac:** Settings, General, **App Icon**: a look for light mode and one for dark mode, each any of the 28, for
  the Dock and the app switcher while Verso runs.
- **The iPhone and the iPad:** **App Icon** in the account's sheet: a design and a lens, its Day look as its light
  appearance and its Night look as its dark one, as an iOS icon set holds one picture for each; the Home Screen shows
  the dark one where its icons are set to Dark (its Customize menu, always or in dark mode).
- Verso Dev offers its own drawings of them, with the blue DEV corner. Verso Drive's icon and the top bar icon stay
  as they are.

**Day** is the white print. Each picture is a gradient, top to bottom. A light picture has a line one unit wide just
inside its edge, which holds it apart from the paper, and its lens's barrel lightened, so the barrel is not the
heaviest thing on it; a dark picture keeps the lens's own dark barrel.

| Design | Day picture | The line inside its edge | Lens barrel |
|---|---|---|---|
| Mist (the app icon) | `#e6edf5` to `#c4d0de` | `#000000` at 0.08 | Lightened |
| Sand | `#f0e8d8` to `#d9cbb0` | `#000000` at 0.08 | Lightened |
| Dark | `#34384f` to `#17161f` | None | Its own |
| Paper | `#ebe8e2` to `#d5d1c8` | `#000000` at 0.10 | Lightened |
| Frame | `#f8f7f4` to `#ebe9e4` | `#8f8a80` at 0.55 | Lightened |
| Slate | `#727b92` to `#4a5165` | None | Its own |
| Sky | `#d3e3f3` to `#9db5ce` | `#000000` at 0.08 | Lightened |

**Night** is the print in the dark: its paper charcoal, the word a light grey, the back of its turned corner a dark
warm grey, and its picture a darker shade of the design's own, so Mist is a deep blue-grey, Sand a dark umber, Slate
an indigo and Sky a deep blue. Where the picture is close to the paper, a light line inside its edge holds it apart.
Every Night picture is dark, so its lens keeps its own barrel.

| Design | Night picture | The line inside its edge |
|---|---|---|
| Mist (the app icon's dark appearance) | `#414d5c` to `#262d37` | `#ffffff` at 0.08 |
| Sand | `#574a39` to `#382e22` | `#ffffff` at 0.08 |
| Dark | `#2c3044` to `#141319` | None |
| Paper | `#38363a` to `#262528` | `#ffffff` at 0.10 |
| Frame | `#403f43` to `#353438` | `#a39e94` at 0.55 |
| Slate | `#454a66` to `#272a3d` | None |
| Sky | `#2f4a66` to `#1b2b40` | `#ffffff` at 0.08 |

| Paper | Face, top to bottom | Back of the turned corner | Ink | The print's edge |
|---|---|---|---|---|
| Day | `#ffffff` to `#e6e4e0` | `#f6efdf` to `#d8ccb0` | `#6f7486` | `#000000` at 0.08 |
| Night | `#4a4a4f` to `#2f2f33` | `#6f6858` to `#4b4539` | `#c4c8d4` | `#ffffff` at 0.12, so it holds on a dark background |

**Colour** is the lens as it is: Immich's five colours round a blue glass. **Graphite** is a monochrome lens, for
those who want no colour: the ring's five segments in five greys, in the order of the colours' own lightness (amber
the lightest, then pink, green, blue and red), lighter on Night paper so the ring still reads against the dark; the
glass a neutral dark grey with its highlight; the barrel a neutral grey. The picture keeps its design's colour.

| Lens | Barrel, rim and inside (lightened on a light picture) | Glass, centre to edge | The ring, clockwise from the top |
|---|---|---|---|
| Colour | `#3d3846`, `#241f31` (`#5d5867`, `#45405a`) | `#2d5c9e`, `#18294a`, `#0f0d16` | `#fa2921`, `#ed79b5`, `#ffb400`, `#1e83f7`, `#18c249` |
| Graphite | `#3c3c3f`, `#232325` (`#5c5c60`, `#444448`) | `#5b5d63`, `#2c2d31`, `#121214` | Day `#76767b`, `#d0d0d3`, `#efeff0`, `#909095`, `#b2b2b6`; Night `#8c8c91`, `#dadadd`, `#f4f4f5`, `#a6a6ab`, `#c4c4c8` |

`python3 linux/packaging/icons/linux-app-icon.py --sheet <file.png>` draws the 28 side by side, large and at 48 and
16 pixels, on a light and a dark background, for looking at a change to them.

Rules:
- **A platform's icon only where that platform is meant:** its download, its screenshots, its entry in a list of
  platforms.
- **Never one platform's icon on another's desktop:** no rounded square on Linux, no print edge to edge as the Mac's
  app icon.
- **Change an icon at its source** and run its generator: a script in `linux/packaging/icons/sources/` for the app
  icon's drawing (`app-icon.py`) and the symbols it draws (each writes its icons into the folder given,
  `linux/packaging/icons`; most need Shapely), `linux/packaging/icons/linux-app-icon.py` for the Linux app icon's and
  Verso Drive's PNGs (it needs Pillow), `mac/Verso/make-icons.py` for the Mac's and the iPhone's (`--all` for every
  look of both builds after a change to the drawing; `--dev` for the Dev build's, `--design` and `--graphite` for
  another design and lens), which runs `make-symbol.py` and `make-menu-bar-icon.py`. Never edit exported PNGs, nor a
  drawn icon by hand.
- **The small icons are the lens alone,** taken from the app icon's drawing on a dark picture (the `lens` group in
  `linux/packaging/icons/dev.hviid.Verso-dark.svg`), its barrel the lens's own dark, since a light picture lightens it
  only against itself: the Mac's menu bar icons and sidebar symbol, Messages' icon, and the lens in backing up's Live
  Activity on the iPhone (`ios/Widgets/Assets.xcassets/Lens.imageset`, on nothing, at the largest size it is drawn, as a
  Live Activity's images may be no larger). A change to the lens changes them all; a menu bar state follows the Linux
  tray's colour icon of that state (`dev.hviid.Verso-tray-<state>.svg`). They are the same for every look, and only
  the app icon has a Dev variant.

## Colours

The palette is the app icon's own, by part (`linux/packaging/icons/dev.hviid.Verso.svg`):

| Token | Hex | Part of the icon |
|---|---|---|
| Paper | `#ffffff` to `#e6e4e0` | The print's face, top to bottom |
| Back | `#f6efdf` to `#d8ccb0` | The turned corner, the back of the print |
| Picture | `#e6edf5` to `#c4d0de` | The photo on the print, top to bottom: Mist on Day paper (the other looks in "The picture's designs") |
| Ink | `#6f7486` | The word on the strip |
| Lens rim, lens, lens deep | `#3d3846`, `#241f31`, `#0f0d16` | The lens barrel, its own; on a light picture the rim and lens are `#5d5867` and `#45405a` |
| Glass, glass mid | `#2d5c9e`, `#18294a` | The lens glass, darkening to lens deep at its edge |
| The ring, clockwise from the top | `#fa2921`, `#ed79b5`, `#ffb400`, `#1e83f7`, `#18c249` | Immich's five colours |

The Night look has a paper, back and ink of its own, the dark appearance of the Mac's and the iPhone's icon, and the
Graphite lens greys of its own ("The picture's designs"); the Dev build has a blue turned corner (`DEV_BACK` in
`mac/Verso/make-icons.py`).

Rules:
- **The ring's colours together and in order** (red, pink, amber, blue, green, clockwise from the top), or one at
  a time as a small accent. Never as a background or as text.
- **The apps use none of this.** They take their toolkit's accent and colours; only the icons bring ours in.

## Type and words

- **The apps** use their platform's fonts and sizes, untouched.
- **An ellipsis** ends a menu item or a help text whose command asks for more before it acts (Assign Location…,
  Edit Link…), as the Mac's do; a toolbar button and a header's control are named with the plain verb or state
  (Assign Location, Edit), as Photos', Mail's and Finder's toolbars are.
- **The name** is Verso, in prose and in the app grid; "Verso for Immich" where the name needs Immich beside it (the
  README's title, the cask's name). Its drive is **Verso Drive**, and in Immich Crosslink it takes part as **Verso
  Gallery** and **Verso Drive**. "Immich" alone names the server only.
- **Menu items in the file managers** are **Open in Immich** and **Copy Immich Link**, the same in Files and Finder:
  "Immich" there is the server's web app, where the link goes. Their switch reads **Open in Immich and Copy Immich
  Link**, under **Immich Web App**, captioned "Open photos, albums, people and places in Immich's web app in your
  browser, or copy their address."
- **"Immich Crosslink"** is the protocol's name, in English in every language: its switch reads **Immich
  Crosslink**, with a link to the protocol's page whose address is not shown: **Learn more…** at the end of the
  switch's description on the Mac, as System Settings ends a description, and a **Learn More** button beside the
  switch on GNOME. A message about a link another app sent says "a link from another app", not the protocol's name.
  Each app that takes part is a row of its icon, its name and its switch, the switch last; one not found reads **Not
  found** and has **Forget** before the switch. With none, a link to the protocol's list of the apps that take part
  (**Find Apps That Take Part** on GNOME, **See the apps that take part…** on the Mac), rather than any one app being
  recommended.
- **Show in on the Mac** is one Finder item, **Show in Another App…**, which shows the item in the one app there is,
  or asks which; on Linux each app that takes part has its own **Show in _app_** (Verso's Flatpak, which cannot list
  them, has **Show in Another App…**).
- **Buttons and titles in title case** in English, as GNOME's and Apple's guidelines ask; labels and descriptions in
  sentence case. Translations follow their language's own conventions.
- **No em-dashes** anywhere (AGENTS.md).

## The website

Verso's page, at `jakob.hviid.phd/verso` and for the top of `jakob.hviid.phd/software`, is built from `site/`
(ROADMAP.md, M9, step 7).
- **A table of prints.** Verso is the back of a photo, so every card on the page is the app icon's print: paper, Day
  or Night with the page, its bottom right corner turned over to show the back, laid on Mist's calm light blue-grey
  (`#e8edf3`, and `#1a1d23` in the dark). The first is one large print: the pictures in its picture, on Mist's
  gradient, and the words on its strip, where "Verso" is written in the icon's own hand (the strip's path, in its
  ink).
- **Verso's app icon is the brand** in the bar and the footer: its design, Mist on Day paper, which people know
  from their system. The lens (`site/mark.svg`, the small icons' lens) marks the tight places: the tab, and the
  drive's folders. Each platform's own icon stands beside that platform alone, on Day paper in both appearances.
- **A privacy page** (`privacy.html`, from `site/build.py`) in the photos' page's form, linked from the footer: what
  Verso connects to and keeps, for the App Store, TestFlight and everyone, standing on SECURITY.md.
- **Light or dark** as the system says, until the switch in the bar chooses; the choice is kept for the next visit,
  and the pictures with a dark version follow it.
- **The ring's colours** mark each section's heading together and in order, and one at a time as a small dot (a
  feature, a platform's state). The one dark band, backing up, is the lens's glass.
- **Light and dark** follow the system, and so do the pictures: each has a dark twin, taken in Verso's dark style.
- **Measured:** text keeps 4.5:1 on its ground in both; a caption's ink is a shade darker than the icon's
  (`#5f6477`), which the handwriting keeps.
- **Fast and private:** one HTML file and one stylesheet, the system's fonts, no framework, nothing loaded from
  elsewhere, no cookies and no counting; the pictures are WebP, those below the first screen loaded as they come near.
- **Built for the releases there are** by `site/build.py` (`site/build-latest.sh` gathers them), and built again by
  `ci/release.sh publish` for every release and beta, so each channel's version follows by itself.
  - **Two paths on every card:** each platform's card has its stable channel, the default (a green dot, Stable, its
    version and day, how to install it), and beneath it, past a dashed rule and in quieter type, its beta (a blue
    dot): the newest beta's version, day and command where one came out after the stable release, and else that the
    beta channel follows stable until the next beta; each beta says it takes every beta and every stable release, and
    how to go back to stable. The iPhone's card has the App Store as coming (an amber dot) and TestFlight as the way
    in, at full strength, until the App Store's link is given; TestFlight shows no version, as its builds come from
    develop between betas. Two blocks rather than a switch between channels: both paths stay in view, without script.
  - The line under the heading names the stable version, and the beta's where one is ahead; Linux's downloads (its
    rpm and deb where the release carries them, each with the command that installs it) and the Mac's disk image come
    from each channel's newest release that carries them, the Mac's stable as "Coming" without one.
  - `latest.json` and `beta.json` for the update check of the rpm and the deb, each channel's, and `photos.html`, the
    credits of the showcase server's photos. A picture not taken yet is a place marked for it, and the build lists those.
- **The shared link's card** is `site/social-preview.html`, rendered at 1280 by 640 as `site/social-preview.png`.

## Screenshots

- **Lab data only:** the lab server's credited fixtures, never a personal library (AGENTS.md, "Testing on Erebus").
- **Linux** in the lab VMs, cut to the boxes the `lab-desktop-vm` skill lists. **The Mac** on the maintainer's Mac
  against the lab server, through the `mac-dev` skill's tunnels, each window taken with ⌘⇧4 and Space, which keeps
  macOS's own shadow.
- **Names** start with `verso-` and say what they show: `verso-library.png`, `verso-viewer.png`, `verso-map.png`,
  `verso-files-album.png` (an album in Files, through Verso Drive).
- **Retaken** when the interface they show changes; keep the file name, so the README needs no change.
- **The website's** are in `site/screenshots/`, and the README's top shows one of each platform's from there; named by
  platform and place (`linux-library`, `iphone-backup`), each
  with a `-dark` twin, as WebP: Linux's at the README's sizes, Files' window with its corners clear; the iPhone's and
  the iPad's as the device takes them; the Mac's as above. They show the showcase server's library (the
  `lab-immich-server` skill), whose photos the page credits; `site/build.py` names those still to take.
- **The iPhone's and the iPad's** in the Simulator (an iPhone 17 Pro Max, an iPad Pro 13-inch in landscape), at the
  device's own resolution, whole: the page draws the device round each. The status bar reads 9:41 with full bars and
  battery, and the app is named Verso, as a release is. The phone's own library holds showcase photos only: two trips
  as Immich holds them, so they count as in Immich and fill Free Up Space's review, and four new ones on their way
  (the `mac-dev` skill, "The website's pictures").

## The App Store listing

One App Store record, "Verso for Immich" (`dev.hviid.Verso`), holds the iPhone and the iPad (one version, `IOS`) and
the Apple TV (its own version, `TV_OS`). Its words are in `ios/AppStore/en-US/` (the TV's own beside them in `tvos/`,
where they differ), and `ios/appstore.py push` sends them, with the screenshots, the review notes and TestFlight's
texts, into the version being prepared (ARCHITECTURE.md, "Verso's releases"). Each field, and what goes in it:
- **Name,** "Verso for Immich": the app's name and what it works with, which is what people search for. Immich is in the
  name as the server it describes, never as our brand (the non-affiliation notice closes the description).
- **Subtitle,** "Self-hosted photos & backup": the two reasons to look, in the words people search with; App Store
  search reads the name, the subtitle and the keywords, so none repeats another.
- **Promotional text** (170 characters, changed without a review): what is new and worth a look now, the newest
  platform or feature; the iPhone's names the Apple TV, the TV's what it does.
- **Description:** one sentence of what Verso is, one of what Immich is (many will meet the word here first), then
  sections in capitals as App Store descriptions have them, each a few lines that each say one thing a person can do:
  the whole library, search, organise and share, backing up (with Start and Free Up Space's review, the two promises
  that make people trust it), Verso Drive, the iPad, the Apple TV, privacy; then free and open source with the server
  it needs, and the non-affiliation notice whole. Nothing it does not do, and no comparison with other apps or
  services. The TV's leads with the big screen and says how it is set up.
- **Keywords** (100 bytes): words a person searching for a self-hosted gallery uses that the name and subtitle leave
  out (`gallery`, `nas`, `homelab`, `open source`); never another product's name.
- **What's New:** the release's own notes, from the tag's Conventional Commits (`ci/release-notes.sh`), the Apple
  editions' parts; the first version has none.
- **Links:** Verso's page for marketing, its privacy policy (`privacy.html`, which `site/build.py` writes, standing on
  SECURITY.md), and the issue tracker for support.
- **Category** Photo & Video; **age rating** 4+: Verso shows a person's own library, from their own server, and what
  the people they share albums with add (photos, comments, likes); no public content, no strangers, no chat of its
  own, no advertising, no web browsing.
- **App Review:** Immich's public demo as the demo account, with notes on entering a server's address (a reviewer
  meets a sign-in that asks for one), why backing up is not offered there, and how the Apple TV is set up from the
  iPhone. The contact is the maintainer's, from the git-ignored `ios/AppStore/contact.local`.
- **TestFlight:** a short beta description, the same review notes, and each build's What to Test
  (`ios/AppStore/what_to_test.txt`): what changed, said as what to try.

**Screenshots,** in the Simulators against the showcase server, as DESIGN's other screenshots ("Screenshots" above),
whole and without frames or captions, so each is the app as it is: the iPhone 17 Pro Max's 1320 × 2868 for
App Store Connect's "iPhone with Dynamic Island, large display", and the same scaled to 1206 × 2622 for its "medium
display", which it asks for and shows in the listing's header and search results (`ios/appstore.py medium`; the two
screens' shapes differ by a tenth of a percent), the iPad Pro 13-inch's 2752 × 2064, and the Apple TV's
3840 × 2160, light on the iPhone and the iPad and dark on the TV, as each is mostly seen. In the order a person meets
Verso, the first three being what a search result shows: the Library, a photo, its details, Memories, Albums, Places,
Search, the Backup page, Free Up Space on the iPhone; the Library, a photo, Albums, Places and People on the iPad; and
the Library by year, Memories, Places, a photo and an album on the TV; and Verso in Messages, its grid and a photo in
the message field, for the iMessage App section, on the iPhone and the iPad. They are kept in the git-ignored
`ios/AppStore/screenshots/<iphone|ipad|tv|imessage-iphone|imessage-ipad>/`, named `NN-place.png` in their order.

**App previews,** once the app is near done, from the walkthrough video's recording (ROADMAP.md, "The walkthrough
video"): up to 30 seconds each, the iPhone's showing a photo opening out of its tile, a memory as a story and backing
up's first run, the TV's a memory playing on the big screen. Not made yet.

**One language,** English, until the listing is translated with the app's own words (`po/`) by people who speak them;
a machine's translation of a store page reads as one.

## The apps' interfaces

Verso is one app on each platform: the gallery's window, Verso Drive, and an icon in the top bar or the menu bar
(ARCHITECTURE.md, "Verso's window" and "Verso on the Mac"). Its layout follows Immich Gallery's on the Mac (the sidebar's
sections, the pages, the viewer's info), drawn with each platform's own toolkit:
- **Status where it can be glanced at:** the top bar icon's menu on Linux, where the desktop has a tray
  (ARCHITECTURE.md, "The tray"), its first line the state and then grey lines, each saying what it is ("Server
  version: ...", "Signed in as: ..."); the menu bar item's menu on the Mac, its first line the state; and Verso
  Drive's Status page in Preferences on Linux.
- **Settings as each platform has them:** on Linux, Preferences is a sidebar of pages, as GNOME Settings has them:
  Account, General, Crosslink and Features, then Verso Drive's Status, Drive and Folders, then Administration for an
  admin. On the Mac, the Settings window's tabs: General, Account, Security, Preferences, Verso Drive and Other Apps
  (a sidebar as on Linux is planned: ROADMAP.md, "Verso on the Mac"). Each page shows only what means something on
  that platform, with short titles, a line under a row where its title says too little, and each kind of setting as
  the platform shows it.
- **App Icon shows each design by its icon and its name,** drawn in the paper and lens around it, as each platform shows
  such a choice; the paper (Day or Night) and the lens (Colour or Graphite) are two-way switches of the platform's own.
  On Linux, in Preferences, General, a row for the light style and one for the dark style, each with the look's icon and
  its name ("Sand, Night, Graphite"), which opens to a combo row of the seven designs with a check on the one chosen,
  and Paper and Lens as toggle groups. On the iPhone and the iPad, a row under On This iPhone in the account's sheet,
  the design and lens in use as its value, opens a page with Color and Graphite as a segmented control over the seven in
  a grid, four to a row on a phone and in the iPad's sheet alike, as Settings shows Light and Dark: the icon at 64
  points with a hairline round it, so a light one keeps its edge on the white row, its name under it, and a circle under
  that, ticked in the accent for the one in use; a line under the grid says where the icon shows and that dark icons on
  the Home Screen show its night version. On the Mac, in Settings, General, under App Icon, a row for Light Mode and one
  for Dark Mode, each the seven side by side at 48 points, the chosen one ringed in the accent round its square as
  System Settings marks its Appearance, its name in the text's colour and the others' in grey, and under them Day and
  Night and Color and Graphite as small segmented controls; under the rows the line that the Dock and the app switcher
  show them while Verso runs and Finder and Launchpad keep Mist.
- **Destructive actions ask first,** in the platform's own alert, with its destructive button style.
- **About** carries the non-affiliation notice, the credits and the AI disclosure.
- **The toolbar's places,** in Verso on every page (the maintainer's rule, after Apple's toolbar
  guidelines): on the left Back; in the middle the page's mode (Years, Months and All Photos; All, My and Shared
  Albums), the Library's zoom just left of its Years, Months and All Photos, as Photos has it; on the right, first
  and in a box of its own, the zoom's − and + on every other page (a photo grid's, or the cards' and tiles'), then the
  page's own items in a box of theirs (sorting, always in the top bar, an album's comments, the page's menu), then
  the view (its shape, the date scroller, view options), the actions on what is selected (Share, the ↑, shares the
  photos through the system; Immich's own sharing of an album or a link is on its page), and search last. The page's
  menu holds what matters less on it (the Album or Link menu, named by its icon, never "…"). A page's main action
  (Assign Location) follows the zoom in a box of its own. Nothing is offered in two places, and no two buttons in one
  place look alike (New Album is a stack with a plus, not the zoom's +).
- **Under the Mac's toolbar, a light blur with no edge** on every page: what scrolls goes under it with the scroll
  view's soft edge effect, and the map, which does not scroll, carries its edges on under the toolbar and the sidebar
  as a mirrored, blurred copy (ARCHITECTURE.md, "Verso on the Mac", "The map goes under the toolbar"), never the hard
  band MapKit draws over its own top.
- **A page header's controls are statuses, not buttons** (as on Linux), in a row under the page's name and details,
  where the eye already is for it, as Music's and Contacts' headers have theirs: each its icon in the accent colour
  and its current state or name in the body's text, lit under the pointer as the Mac's accessory controls are
  (`HeaderStatusStyle`), so it reads as what is so and is known to be clickable, without a button's frame. A status
  names what is so and a click changes it: a person's Favorite or Not a Favorite, Shown or Hidden; an album's Private,
  Shared with 2 people or Shared publicly, which opens its Share sheet, with whom it is shared just beside it; then,
  after a divider, the actions (Add Photos, Edit, Merge…). There are no Hide and Unhide pairs and no "…" in a header.
- **On the iPhone and the iPad,** Photos' places win where the phone has its own (ROADMAP, M10): a page's title is large
  in the bar's own row and stays there as the page scrolls, the line under it saying what matters now; the top bar holds
  the page's View Options and Select, and the cards' and the grid's zoom is a pinch, with Zoom Out and Zoom In in View
  Options, rather than − and + in the bar; a new size is laid out at once, with what was under the fingers kept in place
  and the old layout fading into the new, never sliding. Every page's top, the map's too, is a light blur over what runs
  on under the bars, fading out with no edge. Newest at the Bottom (Photos') or at the Top is one choice in
  every timeline's View Options. A long timeline's date scroller is a glass pill on the trailing edge, a chevron up and
  down and the month at the top in semibold, growing a little while held; held, the years show down the edge on a
  strip of the pill's regular glass, as narrow as a year's figures, each in grey caption figures where the pill's
  middle is at the year's first month, Now at the newest end and the newest photos' year always shown, just past Now
  where it began nearer to it than a label's room, and the strip fades out when the pill is let go (ARCHITECTURE.md, "The photo grid on the iPhone"). A header's statuses wrap onto a second line on a narrow screen, and their divider shows
  only between two that share a line; an album's comments and likes are a status there ("3 comments, 2 likes"). The
  viewer's bottom bar is Share, then Favorite, Info and Edit together, then Delete; for a video, a glass capsule above
  it, in the filmstrip's place and as wide as the bottom bar, holds Play, the video's frames with a white playhead, Mute
  and the route button, all white (the route button too while AirPods or AirPlay take the sound), the time in a small glass bubble over the playhead only while it is dragged, and
  comes and goes with the rest; the route button's sheet and the Lock Screen show the video by its poster and the title
  capsule's title, its place or else its day; a stack's badge sits under "..." at
  the top, and a Live Photo's LIVE badge under Back, one switch for all Live Photos that reads LIVE, on glass tinted
  yellow with dark text as the Camera's Live is yellow when on, or OFF on plain glass, plays nothing, and shows a
  moment's LIVE or LIVE OFF at the top's middle as the Camera does (Photos' is a menu that also has effects Immich has
  none of). The selection's bar is Share, then Add To, Favorite and "..." together, then Delete. One menu of photo
  actions serves a long press, the selection's "..." and the viewer's, in Photos' order (ROADMAP, M10, item 3): a row
  of three along its top (Copy, Save to Photos, Hide), then Share and Favorite, the submenus opening in place, the
  page's own actions, and Delete alone in red at the foot; what does not apply is left out, never dimmed. A photo grows
  alone out of its tile with the system's zoom, the grid darkening behind it, and its controls come once it has
  landed; Back or a drag down shrinks it alone into the tile of the photo shown last. Signing in opens on a welcome (the icon, "Verso for Immich" and its one line, the server's address, a line
  saying Verso needs an Immich server, run by the person or a hosting provider, with Try the Demo, which signs in to
  Immich's public demo, and Continue in a bar at the foot with the non-affiliation notice above it), then a pushed Sign
  In page: the server found, with Immich's version and a tick; single sign-on first and prominent, in the server's own
  words, then "or", email and password, and Use an API Key Instead as a disclosure; errors under what caused them. A
  photo on its way to Immich carries a small white mark in its tile's top trailing corner, with the badges' shadow: a
  ring filling while it uploads, a cloud with an upward arrow while it waits, a clock while the connection holds it
  back, an exclamation mark on orange when it needs a look.
- **On the iPad,** the same pieces where Photos on the iPad has them (ARCHITECTURE.md, "Verso on the iPad"): the tabs
  in iPadOS's floating bar at the top, never a sidebar; a page's title and its line in the navigation bar's row, beside
  its buttons; five photos a row in portrait; Years, Months and All always in a glass capsule at the foot's middle,
  backing up's card under it at a sheet's width. The viewer's buttons are in its top bar, Back, then Share and Favorite
  together, and at the other end Edit, Info, Delete and More together, with the filmstrip alone at the foot and a
  video's bar a sheet's width in its middle; the details are a panel at the trailing side under the top bar, titled
  Info with a close button, in the background colour with rounded corners and a soft shadow, the cards the iPhone's.
  Under the pointer, cards lift and Collections' rows and headers light up. A window narrower than a regular width is
  laid out as an iPhone.
- **On the Apple TV,** the iPhone's pages at a sofa's distance (ROADMAP.md, "Verso on the Apple TV"): the same type,
  colours and cards, each shared from the iPhone's files where tvOS compiles them and drawn after them where it does
  not; a page's title large and bold at the leading edge with its line under it, scrolling away with the page. Focus
  takes the place of a finger as a quiet lift: the focused tile or card grows a little, with a soft shadow beneath and
  its corners rounding, never tvOS's platter with its wide spacing; cards that lie edge to edge in a card (a month's
  mosaic) are ringed in white instead. The Library has Years, Months and All Photos in a menu beside its title (its
  button names the one shown; a segmented control changed the page as the focus crossed it to the Filter menu), opening
  on All Photos: Years are a card for each year, Months each month's name over a mosaic of photos from different days
  with the day on each, and All Photos the grid, square tiles six to a row with eight points between them, each month
  under its name, the newest first (the iPhone's Newest at the Top, as the remote's focus starts at the top). Albums are
  the iPhone's album cards, four to a row, in sections by year with the most recent photo first; People the rounded
  squares with their names on them, in the server's order and without the hidden and the unnamed; Places the iPhone's
  country cards, the most recently visited first, each opening its city cards, which open a city's photos; Memories the
  memory cards, three to a row, playing as a story; Favorites and the Archive the grid under their names. The tile under
  the focus lifts above its neighbours with a thin white outline (UIKit's collection view draws it on top, which a
  SwiftUI grid cannot). On the Apple TV 4K of the 1st and 2nd generation, and the Apple TV HD, the simpler interface:
  the outline without the lift and its shadow, and the viewer without its zoom and slide, the photo there at once
  (`TVDevice`, by model, else by less than 4 GB). A grid's page has a Filter menu beside its title (All Photos',
  Favorites', the Archive's, an album's, a person's, the Locked Folder's): Favorites and Videos, each ticked when on,
  the Filter's icon filled while one is; an album's offers Favorites alone. Favorites are the account's own, without a
  partner's photos. The header is a focus area of its own, so up from any photo of the first row comes to the Filter
  menu. Search is tvOS's own search screen with the iPhone's start page under it: quick filters, people with their
  faces, places and recent searches as glass chips and rows, what matches while typing, and the results as the grid. The
  viewer fills the screen, its photo growing out of its tile as the black comes up, and shrinking back into the tile of
  the photo shown last, as the iPhone's; a click shows or hides the iPhone's title capsule, the place over the day and
  time; left and right slide to the photo beside it, as the iPhone's pages slide; a Live Photo has the Live Photo sign
  small in the top corner, out of the photo's way, and play/pause plays its movie; a video shows its first picture with
  a large play sign and its length; a click (the clickpad's middle), or play/pause, opens it in tvOS's own player, full
  screen, with the remote whole, as Apple's TV app has it (its transport bar, scrubbing, its panels for audio, subtitles
  and the day), and Menu, a layer at a time, comes back to the viewer at the video. Once a video in HDR has put the TV
  in HDR, the TV stays there until the viewer closes, where Match Dynamic Range is on: going back to SDR for each photo,
  and to HDR for the next video, blacks the screen out each time. The accent is the system blue, as the iPhone's, set in
  the TV's asset catalog because tvOS's own is white. Settings, at the sidebar's foot in a section of its own, is laid
  out as tvOS's own Settings: the app's icon large on the left with its name and version, and on the right a list a row
  at a time, each with its value, opening a page where it holds more than a switch. Library: Top Shelf ("Memories,
  Recent", a switch for each row on its page), Show Locked Folder in Collections, Manage Photos (On or Off, its page
  with Turn On with iPhone, or Turn Off). Appearance: App Icon, where the app carries its Night icon (the Day and Night
  icons as cards, each with its name and a tick under the one on the Home Screen). Account: the name, email and server,
  what this Apple TV may do ("Can view", "Can view and change") and Sign Out in red. About Verso, on its page. With
  Manage Photos on, a press and hold on a photo, in a grid or full screen, opens its menu in the iPhone's order:
  Favorite, Add to Album… (the albums in a sheet, in Albums' order and sections, each with its count), Archive (Move to
  Library in the Archive), Move to Locked Folder and Delete in red, the last two asking first; in the Locked Folder,
  Move Out of the Locked Folder and Delete. The Locked Folder, until the iPhone opens it, is a lock over its name, a
  line on how it opens and Unlock with iPhone, the system's picker, as Set Up with iPhone is; open, it is the grid under
  its name, as Favorites. The Top Shelf shows the rows Settings chooses, Memories, Recent, Albums, Favorites and People
  in that order, as rows of wide pictures (People's square), each with its title (the memory's, the album's, the
  person's name, or the day the photo was taken).
- **The Backup page** is backing up's one page on the iPhone and the iPad: a list of iOS's own whose top is the page's
  status, centred, as Settings' feature pages have theirs: a cloud symbol (the accent while it works, and only then
  pulsing with the system's variable colour; green with a tick when backed up; grey while it waits; orange when the
  person is needed), what goes on in bold, and one line in grey, which also explains a stop. Under it one bar for the
  whole library, split as iPhone Storage splits the device: In Immich green, To upload the accent, Needs a look orange,
  Left out grey, To check a lighter grey. Then the moment's one action, a prominent glass button across the width (Turn
  On Backup, Start, Back Up Now, Try Now, or Check Again over Send Them Again and Let Them Go on plain glass), with a
  footnote under it where it helps. What backing up waits for is said in that grey line, never as an error; only what
  the person must act on is orange. Each section under the top has one subject. On This iPhone is the bar's legend:
  its parts as rows in the bar's order, each with a dot of its colour, its count on the right ("69 · 403 MB" for To
  Upload) and its photos a tap away; Left Out opens a page of its own groups. Then On Its Way, Free Up Space as one
  row with what is ready in the accent, Checked with Immich, the options in two sections (Uploading, Included; above On
  This iPhone until the first run's Start) and Turn Off Backup. Free Up Space's page: the period as a menu in its row, Review and Free Up in the accent
  with what it frees under it, Always Keep with what it keeps in grey on the right. The review is a grid of the photos by
  month under pinned month headers, each tile ticked in its corner (unticked dimmed), a small cloud on those only in
  iCloud, and Delete in red across the foot; under its title, what Always Keep keeps beside a heart, with Change in the
  accent, on a quiet rounded ground. Hidden photos are a group on the same quiet ground under a lock, a count and
  size until checked with the PIN, their pictures only after Show; wherever a hidden photo would show its picture
  before that (the Backup page's lists, the photos that stay), a lock in grey stands in its place. Turn Off Backup is in red at the Backup page's foot. The Library's
  number of items at its newest end is followed by "· Backed Up" in grey, or "· 2.3 GB to Free" in the accent. While
  backing up is off, a glass card above the tab bar offers it, with Not Now on glass and Set Up prominent; while it is
  on, the same card says what is ready to free (a drive in the accent, Review prominent), or that the phone is almost
  full (a warning in orange, Free Up Space prominent). Its Live Activity is Verso's lens from the app icon inside a
  ring that fills as the run goes, in the stage's colour (the accent while it works, grey while it waits, green when
  done, orange when the person is needed), with the title in bold and the line in grey beside it; in the Dynamic Island
  the lens in its ring and "34/69".
- **On the Mac,** the card pages show cards at every size, Albums too, as on the iPhone; a pinch, the toolbar's − and
  + and ⌘− and ⌘+ change their size, the new size laid out at once with the card under the fingers (or in the middle)
  kept in place, never sliding. The viewer has a Live Photo's LIVE badge in the photo's top leading corner, under Back,
  as the iPhone's has: the same one switch for every Live Photo, LIVE on glass tinted yellow with dark text or OFF on
  plain glass (on macOS 15, yellow or the window's material), and a moment's LIVE or LIVE OFF at the top's middle as
  it switches.
- **The sidebar's foot** is the account (its picture, name and server, with a chevron pointing up that says it opens
  a menu, upward from the sidebar's foot: the account's settings, Settings, Administration, Sign Out), its
  notifications, and a pencil that edits the sidebar (its pages and sections, a new section, a reset). An import
  shows just above the account and is laid out as its row is, so the two line up: a circle of the account's
  picture's size for how it goes (an arrow on the accent colour, a tick on green, an exclamation mark on orange), the
  title where the name is, a progress bar or a quieter line where the server is. The bell's list is headed by where
  each notification comes from: Verso's own, with Verso's icon and "On this Mac" or "On this computer", and Immich's,
  with a server and its address, never Immich's logo. On the Mac a section of more than one has Clear All at its
  heading's end, and the bell is orange while one asks something of the person, as the iPhone's ring is (below). On the
  iPhone and iPad the account's sheet holds them at its top
  in the same two sections, Verso's headed by its lens (the app icon's, without its barrel) and "On This iPhone"; each
  row has a small × in a grey circle that clears it, and a section of more than one has Clear All in its heading. The
  account's picture, at the top right of every tab's own page on the iPhone (the rightmost of the top bar's buttons,
  stepping aside while selecting) and in Collections' top bar alone on the iPad, wears a ring while any is kept, read or not, in the accent, orange when one asks
  something of the person, and the system's red badge counts the unread.
- **A person is a rounded square, an account a circle,** in Verso on every platform: the shape tells what a picture
  of someone is. A person in the photos (the People page, a person's header, the faces under a photo, Search's
  people, the pickers that choose a person) is a rounded square with the corner of the album and place tiles, and
  opens that person's photos. An account (whom an album is shared with, the sharing dialogs, partners, the signed-in
  account) is a circle, its profile picture or its initials. Photos draws its people round because it has no
  accounts to tell them from; Verso has both. On the People page a person's name sits on the photo, on a fade at its
  foot, and their heart and hidden mark in its corner, as the cards carry theirs.
