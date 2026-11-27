# PRINCIPLES

The invariants Verso upholds, and where known, what earned them. A change that would break one is discussed
first, and ARCHITECTURE.md is updated with the reason.

1. **Never hang the desktop.** A stuck FUSE call freezes Files, every file dialog, and any shell that touches the
   mount. Every filesystem operation answers within a bounded time, from cache or with a fast error. Nothing waits on
   the network without a deadline. The upload on close is the one deliberate wait, and it has its own limit.

2. **Never download what nobody opened.** Listings, thumbnails, content sniffing and indexing never pull originals.
   The library is never mirrored or synced (libraries run to 300 GB and more). The only originals kept beyond the
   cache are albums the user explicitly pins.
   *Earned by:* the GNOME spike, where opening one folder made Nautilus read every original in it to the end,
   visible or not.

3. **Originals stay byte-identical, both ways.** No transcoding, resizing, metadata stripping or date rewriting.
   No program is ever handed different bytes for the same path.

4. **Immich is the source of truth.** The mount is a view with a cache, not a sync client. Folder membership is what
   Immich says, never recomputed from dates. Existing Assets cannot be edited, renamed, moved or deleted through the
   mount; additions go only through Photos.
   *Earned by:* the month-boundary case, where search (UTC) and the timeline (local time) disagree.

5. **Mutations are explicit and honest.** An outcome that cannot be confirmed is reported as uncertain and checked,
   never replayed blindly.

6. **A move never loses a photo.** A file moved into Upload is uploaded before `close()` returns success, so a
   program that checks it removes the source only after the server has the file. A program that does not (Dolphin's
   KIO deletes the source anyway) still loses nothing: a file that was not uploaded is kept, never deleted.
   *Earned by:* a failed move in Dolphin, which deleted its source while the upload had been refused.

7. **Least privilege where the user wants it.** An API key with read-only permissions is enough to browse and open
   files. Uploads need the server's permission, and the app's own switches gate them.

8. **A path means one thing.** As long as an Appearance exists, its path refers to the same Asset. Name clashes are
   never resolved by moving a name onto a different Asset.

9. **Native on every platform.** Each edition looks, reads and behaves like a first-party app of its platform, and
   integrates through the platform's own mechanisms. On GNOME:
   - the GNOME HIG and libadwaita
   - the Files sidebar, file dialogs and the thumbnail cache
   - the keyring, notifications, and the system browser for sign-in

   KDE and macOS follow their own guidelines the same way. Platform conventions win over consistency between
   editions. There is no cross-platform UI toolkit, no custom theming, and no second file manager.

10. **Measure, don't guess.** Behaviour that depends on Files, GLib, the kernel or the Immich server is verified on
    real machines (Erebus) before a design rests on it. Unverified claims are marked as such.

11. **Immich comes first.** This is a feature for Immich, not a brand. The drive is "Verso" (or the name the user
    chose, `mount.name`), and so is our own interface. It never pretends to be official: the non-affiliation
    notice is always shown.

12. **Credit where credit is due.** Verso Drive comes from Immich Mount, which is inspired by
    [Kartax/immich-desktop-app](https://github.com/Kartax/immich-desktop-app); Verso on the Mac starts from
    [Immich Gallery](https://github.com/IGOLz/ImmichGallery); and the API layer started from
    [immich-rs](https://github.com/boul2gom/immich-rs). The README's credits section and CREDITS.md stay true.

13. **Compatibility before size.** A package installs and runs the same on every distribution and version it is
    offered for, and there are many beyond Fedora and Ubuntu. It declares what it needs rather than counting on
    what a desktop happens to ship, even when that makes it larger: one package with both interfaces and both
    toolkits, about 100 MB more where the other toolkit is missing, beats a smaller one that fails to start
    somewhere (the maintainer's choice, 2026-11; ROADMAP.md, "Package repositories").

14. **No platform left behind.** Verso is one app on three kinds of device: mobile (the iPhone and the iPad), the
    living room (the Apple TV) and the desktop (the Mac and Linux). A feature added to one app of a group is built for
    the others of its group in the same piece of work, or gets a line in ROADMAP.md's parity table saying why not yet
    and when; one that would fit another group is weighed there too, on purpose rather than by accident. Where a
    group goes without a feature for good, the table says why: backing up and Free Up Space are mobile's, as the
    phone is where photos are taken; the Apple TV has no Verso Drive, as tvOS has no Files. Every `feat:` commit says
    which apps it reached (the maintainer's choice, 2026-11).

15. **Stable is what beta tested.** Two channels, one version line: beta, from `develop`, to TestFlight, the
    `verso@beta` cask and Sparkle's beta channel; stable, from `main`, to the App Store, the `verso` cask, Sparkle's
    default channel and GitHub's Latest. A stable release promotes what its beta tested, the same commit and, where a
    store allows it, the same build: the App Store gets the TestFlight build that testers had. A version number says
    nothing about a channel; 1.0 is a version like any other (the maintainer's choice, 2026-11; AGENTS.md,
    "Versioning").
