# Credits

## Inspiration

Verso Drive comes from Immich Mount, which is inspired by
[Immich Desktop](https://github.com/Kartax/immich-desktop-app) by [Kartax](https://github.com/Kartax), a macOS app
that shows an Immich library as a drive in Finder. It showed that the idea works, and the experience shared in its
code and notes shaped the drive's design. No code is shared between the two. Thank you, Kartax.

## Code

- **[Immich Mount](https://github.com/jakobhviid/immich-mount)** by Jakob Hviid (MIT), the drive for Immich that
  Verso grew out of: Verso Drive, the service, the settings and the Immich API layer are its code, carried on here
  under Verso's names.
- **[immich-rs](https://github.com/boul2gom/immich-rs)** by boul2gom (MIT OR Apache-2.0): our Immich API layer
  (`immich-api`) started from parts of it, taken at commit `60d1eb3` and adapted under the MIT license. Its notice
  is in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
- **[ImmichGallery](https://github.com/IGOLz/ImmichGallery)** by Alessandro Craciun, with contributions by Jakob Hviid
  (MIT), a native macOS client for Immich: its API client showed which endpoints a full client needs and the requests
  it sends, which shaped the parts of `immich-api` beyond the drive's own. Verso follows its layout (the sidebar's
  sections, the pages, the viewer's info), its file name and text searches, and ports its ThumbHash decoder and its
  map's clustering. Verso's Mac app (`mac/Verso`) is built from it: taken from the maintainer's fork at `50bb4c3` (its
  `integration` branch, the original's main up to `80c352d` with the maintainer's pull requests), named Verso and
  adapted to send its requests through our Rust core. Its notice is in
  [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
- **[ThumbHash](https://github.com/evanw/thumbhash)** by Evan Wallace (MIT): the placeholders' format; the gallery's
  decoder is a port of its reference implementation, through Immich Gallery's. Its notice is in
  [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
- **[Mimick](https://github.com/nicx17/mimick)** by nicx17 (GPL-3.0), an Immich client for GNOME in Rust: read for
  the further endpoints a Linux client uses (OCR, statistics, places). Nothing is copied: its license differs from
  ours.
- **[Proton Drive for macOS](https://github.com/ProtonDriveApps/mac-drive)** by Proton (GPL-3.0): read for how a
  File Provider app has its location switched on, by opening it in Finder for Finder's own Enable button, which
  Verso Drive on the Mac does too. Nothing is copied: its license differs from ours.
- **[Zephyr](https://github.com/RISCfuture/Zephyr)** by RISCfuture (MIT), a Dropbox client for macOS, and
  **[PermissionFlow](https://github.com/jaywcjlove/PermissionFlow)** by jaywcjlove (MIT): the System Settings
  address that opens its list of file providers, Immich Mount's Mac app's fallback. No code is copied.
- **[Sparkle](https://sparkle-project.org)** (MIT): Verso's updates on the Mac. Its notice, with those of the parts it
  includes, is in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md), which the app carries.
- **The Rust crates we depend on** are listed with their licenses in `THIRD-PARTY-LICENSES.md`, generated from
  `Cargo.lock` (`linux/packaging/third-party-licenses.py`), which the tarball ships; the Flatpak and the rpm and deb
  packages ship it with their release pipeline (ROADMAP.md, M9, step 6).

## Immich

[Immich](https://github.com/immich-app/immich) is a self-hosted photo and video management solution, licensed
AGPL-3.0. Verso is an unofficial, independent client: it talks to the Immich REST API and contains no Immich code.

Open in Immich links to the paths of Immich's web app (`web/src/lib/route.ts` and `web/src/routes/(user)/`), which
its mobile app also takes as deep links (`mobile/lib/services/deep_link.service.dart`). We learned the paths and the
search's JSON from them; nothing is copied.

> Verso is an independent, unofficial project. It is not affiliated with, endorsed by, or sponsored by the Immich
> project or FUTO. "Immich" is used only to describe the server this software works with, and remains the mark of
> its owner.

## Similar projects

Others have put Immich in the file manager too, as Verso Drive does:
- [ImmichDrive](https://github.com/Dynamic-Solutions-Canada/immich-drive): a cloud drive in File Explorer on
  Windows 11.
- [immichfs](https://github.com/Katy248/immichfs) (Go) and [immich-fuse](https://github.com/AlessandroLorenzi/immich-fuse)
  (Python): read-only FUSE filesystems for Linux.

## Test photos

The disposable test server in `lab/immich-server/` is seeded with 50 Creative Commons and public-domain photos from
Wikimedia Commons. They are downloaded when a test server is built, never committed, and credited one by one in
[lab/immich-server/fixtures/ATTRIBUTION.md](lab/immich-server/fixtures/ATTRIBUTION.md). Thanks to the photographers
who share their work.
