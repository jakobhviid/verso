# SPEC

The contract: what Verso does, as seen from outside. [ARCHITECTURE.md](ARCHITECTURE.md) explains how it does it and
why. When the code and this file disagree, the code wins and this file is the bug.

Where a section says something is not built yet, it describes the system being built.

## Vocabulary

Use these words in code, docs and issues.

- **Asset**: a photo or video in the Immich library. A file in the drive is one Appearance of an Asset. Avoid: item,
  image.
- **Verso**: the app: its window, its service and Verso Drive, with one install, one sign-in and one Preferences.
  It runs on Linux and on the Mac.
- **Window**: the program `verso`, Verso's gallery: sign-in, the library, and Preferences. One instance per session
  (`dev.hviid.Verso`). Closing it stops nothing.
- **Service**: the per-user background process `verso-service daemon` (the daemon), which the user service
  `verso.service` runs from login while signed in. It shows the top bar icon and serves the D-Bus interface, and
  while the drive is on it owns the mount, the caches and the uploads. It runs without a display. On the Mac, the app
  and Verso Drive's File Provider extension share its work.
- **Top bar icon**: the service's tray icon (a StatusNotifierItem) and its menu; on the Mac, the menu bar item.
- **Verso Drive**, the drive: the library as folders in the file manager, off until switched on. On Linux it is the
  **mount**, the FUSE filesystem the service serves, by default at `~/Verso`, which Files shows under the drive's
  name, "Verso" unless `mount.name` chooses "Verso Drive" or "Immich"; the name never changes the mount point. On the
  Mac it is a File Provider location in Finder. Avoid: sync folder (nothing is synchronised).
- **Core**: the portable code (`immich-api`, `verso-core`), which the Mac reaches through `verso-bridge`. It has no OS
  or desktop dependencies.
- **Adapter**: the platform code that presents the Core through one native mechanism: FUSE and freedesktop services
  on Linux, File Provider on the Mac. Avoid: driver, plugin.
- **Section**: a top-level folder of the drive that mirrors an Immich section (the timeline, Albums, People,
  Places, Favorites, Archive). Each one can be switched on or off.
- **Appearance**: one path at which an Asset is visible. An Asset has one Appearance per folder it shows up in
  (its month, each album, each person, its city). Appearances share content, but each has its own path and its own
  thumbnail-cache entry. Avoid: copy, link, duplicate.
- **Date group**: an automatic `Year/MM Month` level inside an album, person or city folder, the favorites or the
  archive.
- **Content cache**: the service's bounded store of original bytes, filled on demand in blocks. Never the only
  copy of anything.
- **Thumbnail seeding**: writing Immich's own thumbnails into the freedesktop thumbnail cache, so the file manager
  never reads originals to draw previews.
- **Upload folder**: the drive's one writable folder, `Upload`: what is copied into it is uploaded, and leaves it
  once Immich has it. Every other folder is a read-only view, its structure built from the library's metadata.
- **Staging file**: a file being written into Upload. It lives in the service's staging area until its upload
  has finished.
- **Receipt**: the entry that stays in Upload for a few seconds after a file's upload, for the copy tools that set
  its times after closing it. It reads back the uploaded bytes, may be deleted (Immich keeps the photo), and is not
  renamed.
- **Asset upload**: transfer of a local photo or video into the existing library, unchanged, without creating
  anything for it in Immich (no album, no folder). Avoid: import, sync.
- **Already in library**: an upload whose content (by checksum) already exists as a non-trashed Asset.
  It counts as success.
- **Trashed duplicate**: an upload whose content matches an Asset in the Immich trash. It is restored from the
  trash and counts as success; where the credential may not restore (`asset.delete`), it fails.
- **Uncertain outcome**: a mutation whose request may or may not have reached the server. It is reported and
  checked, never blindly repeated.

## Verso Drive

### Switching it on

- **Off until switched on** (`mount.enabled`): on Linux with the Verso Drive switch in Preferences, Verso Drive,
  Status; on the Mac in Settings, Verso Drive, or from the menu bar item; or by taking Immich Mount's account over
  ("Signing in and credentials"). On Linux the switch writes the setting and restarts the service.
- **Off,** the service runs without the drive: the top bar icon and the D-Bus interface alone. It takes away the
  bookmark it made for the drive and the drive's folder while empty, the top bar menu offers no way to the drive, and
  Verso Drive is not announced to other apps (Links from other apps).
- **On,** the service mounts the drive as it starts, and so at every login.
- **Unmounting only unmounts.** Files' unmount button, Unmount on the Status page, Unmount Verso Drive in the top bar
  menu and `verso-service unmount` leave the switch on, and the service goes on without the drive, its bookmark and
  folder kept. **Mount** (on the Status page, in the top bar menu, or `verso-service mount`) restarts the service,
  which mounts, and so does the next login.
- **Verso as a Flatpak has no drive:** its sandbox reaches neither FUSE nor Files. **Verso as an AppImage has none
  either:** the drive hangs on files of the install that name its programs (the user unit, Files' menu, the sidebar's
  entry), which a file that may move cannot hold.

### Layout

The sections carry Immich's own labels: Photos, Albums, People, Places, Favorites, Archive. Beside them, `Upload`
takes new files.

```
~/Verso/                                   shown as "Verso" (`mount.name`) in the file manager
├─ Photos/                                 the timeline
│  └─ <Year>/<MM Month>/[<DD>/]<file>
├─ Albums/
│  └─ <Year> - <Album>/[<Year>/<MM Month>/]<file>
├─ People/
│  └─ <Name>/[<Year>/<MM Month>/]<file>
├─ Places/
│  └─ <Country>/<City>/[<Year>/<MM Month>/]<file>
├─ Favorites/                              off until switched on (`sections.favorites`)
│  └─ [<Year>/<MM Month>/]<file>
├─ Archive/                                off until switched on (`sections.archive`)
│  └─ [<Year>/<MM Month>/]<file>
└─ Upload/                                 the only folder that takes new files and folders: copied in, uploaded, then gone
```

- Each section can be switched off; it then disappears from the root. Favorites and Archive are off until
  switched on: many libraries hardly use them, and a folder nobody opens is clutter.
- Month folders are named `MM Month` (`03 March`), and day folders `DD` (`15`), so sorting by name is chronological.
- **Busy months in Photos** are split into day folders by the setting `grouping.photos`:
  - `atLeast500` (the default): only months with 500 or more Assets
  - `always`: every month
  - `never`: no day folders
  Days come from the local capture time, as in Immich's timeline.
- **Album folders** follow the setting `albums.layout`:

  | Layout | Example |
  |---|---|
  | `year-prefix` (default) | `Albums/2023 - Summer trip/` |
  | `year-folders` | `Albums/2023/Summer trip/` |
  | `flat` | `Albums/Summer trip/` |

  - **The year** is the one Immich groups the album under: that of its most recent photo (`endDate`). An album
    with photos from 2018 to 2023 is a 2023 album, and moves to a later year when newer photos are added, as it
    does in Immich. (Immich uses `startDate` only when the user sorts albums by oldest photo, a browser setting
    the drive cannot see.)
  - **An empty album** has no year, and appears without one (`Albums/Summer trip/`, or in `Unknown Year/` with
    `year-folders`).
- **Date groups** inside albums, people, cities, the favorites and the archive follow a per-section mode: `never`,
  `atLeast500` or `always`. With `atLeast500`, a folder with 500 or more Assets is split into years and months. The
  default is `atLeast500`, and `always` for the favorites and the archive: they mostly grow, and with `atLeast500`
  their paths would all change the day they reached 500.

### Membership: Immich decides

A folder holds exactly what Immich puts there. The drive never recomputes membership from dates where Immich
has an answer.

| Folder | Source |
|---|---|
| Photos, its years | `GET /timeline/buckets?visibility=timeline` |
| A month | `GET /timeline/bucket?timeBucket=YYYY-MM-01` (the month's asset ids, grouped by local capture time) |
| A day, in a split month | The month's Assets, by the day of their `localDateTime` (the rule Immich's web timeline uses for its day headers) |
| Albums | `GET /albums`: owned albums, and albums shared with the user. `endDate` gives the year |
| An album | Search by `albumIds`; date groups by each Asset's `localDateTime` |
| People | `GET /people`, without hidden and unnamed persons |
| A person | Search by `personIds`; date groups by each Asset's `localDateTime` |
| Places | `GET /search/suggestions?type=country`, then `type=city&country=` |
| A city | Search by `city` + `country`; date groups by each Asset's `localDateTime` (Immich has no city timeline) |
| Favorites | Search by `isFavorite`, what Immich's Favorites page shows, archived favorites included; date groups by each Asset's `localDateTime` |
| Archive | Search by `visibility: archive`, what Immich's Archive page shows; date groups by each Asset's `localDateTime` |

**Undated Assets.** The API never returns an Asset without a date, because an upload must send one. A file with no
metadata sits wherever its uploader's date put it (the lab's ended up in 1970), and the drive shows it where Immich
does.

### Visibility

| Asset | Shown |
|---|---|
| On the timeline | Yes |
| Archived | Only inside albums, Favorites (when it is a favorite) and Archive |
| Hidden (the video half of a Live Photo) | No; the still is shown |
| In the locked folder | No |
| Trashed | No; it disappears at the next refresh |
| Shared by a partner | No (ROADMAP, "Parked on purpose") |
| Part of a stack | Every Asset of the stack is shown |

### Names

Every name in a folder is unique, and a path keeps meaning the same Asset for as long as it exists.

**File names** follow the setting `files.naming`:

| Naming | Example | Built from |
|---|---|---|
| `date-time` (default) | `2024-03-15 14.32.07.jpg` | The local capture time (`localDateTime`), with dots instead of colons; the extension as in the original |
| `original` | `IMG_1234.JPG` | The original file name |

**Clashes.** Two Assets in one folder can share a name: shots in the same second, or `IMG_0001.JPG` from two
cameras. Clashes are detected case-insensitively, after Unicode NFC normalisation:
- The Asset uploaded first (earliest `createdAt`, then id) keeps the plain name.
- The others get a counter before the extension, in upload order: `2024-03-15 14.32.07-1.jpg`,
  `2024-03-15 14.32.07-2.jpg`, `IMG_0001-1.JPG`.
- **Assigned names are remembered.** A counter never moves to another Asset while the one holding it exists.
  Deleting one leaves a gap rather than renumbering the rest.
- Folders that clash (two albums or two people with the same name) get the same treatment: `Anna`, `Anna-1`.

**Sanitising**, for every name:
- `/` becomes `_`, and NUL is removed
- leading and trailing whitespace is trimmed
- `.` and `..` become `_`
- names over 244 bytes are cut on a UTF-8 boundary, keeping an extension of up to 16 bytes, so a clash counter
  still fits within the 255-byte limit
- a leading `.` is kept (it hides the entry, as its owner named it)

### Attributes

| Attribute | Files | Folders |
|---|---|---|
| `st_size` | The original's exact size (`exifInfo.fileSizeInByte`; if missing, a `HEAD` of the original). A size that stays unknown makes reads fail with `EIO`, never look empty | 0 |
| `st_mtime`, `st_atime`, `st_ctime` | The capture time (`fileCreatedAt`), so sorting by date follows shooting order and copies keep it | The mount time |
| `st_mode` | `0644` | `0755` |
| `access()` | Read; never write | Read and search; write only for Upload, with uploads |
| owner | The mounting user | The mounting user |
| `st_nlink` | 1 (Appearances are separate files, not hard links) | 2 |
| `st_blocks` | `ceil(size / 512)` | 0 |

### Files the mount answers itself

- `/.xdg-volume-info` (`[Volume Info]`, `Name=Verso`, the drive's name from `mount.name`, and
  `Icon=dev.hviid.Verso.Drive`): the display name in the file manager, and GVfs's full-colour icon.
- `/.directory` (`[Desktop Entry]`, `Icon=dev.hviid.Verso.Drive`): the drive's folder icon, for a file manager that
  reads one.
- `/.nomedia` and `/.trackerignore`: hidden; they keep GNOME's indexer out.
- `/CACHEDIR.TAG`: a cache directory tag (<https://bford.info/cachedir/>, its signature line and a comment), so backup
  tools that honour it (restic, borg, tar with `--exclude-caches`) skip the drive rather than download the whole
  library; Immich is where it is backed up.
- `/.hidden` (`CACHEDIR.TAG`): the names Files leaves out of the root, so the tag is out of sight; on the Mac the tag
  carries Finder's hidden flag instead.
- Anything else that tools probe for (`.hidden`, `.directory` below the root, `.Trash-<uid>`, `autorun.inf`, `.DS_Store`, and
  rom-properties' `code`, `title.tik`, `default.xex` and `default.xbe` in their spellings): a fast `ENOENT`, which
  the kernel remembers for a minute (a negative entry), so a folder's next probes never reach the service. Such a
  name never waits for the server: without the folder's listing at hand it is answered absent at once, not
  remembered, and the folder is listed in the background. Only these known names are remembered: any other missing
  name, a dot-name of an album or a file included, may still arrive from Immich.

### What the mount refuses

- The modes are what a copy gets, so a photo copied out is an ordinary file (`0644`) and a copied folder an ordinary
  folder (`0755`). What the mount allows is `access()`'s answer, which file managers read for their read-only
  emblem (GNOME Files' lock), and each operation's own refusal.
- Every folder but Upload and the folders copied into it is a read-only view: write access, rename, delete and
  `setattr` on Assets, and new files or folders, fail with `EROFS`. "Move to Trash" and "Paste" in the file manager
  therefore fail there.
- In Upload, a hidden folder (`mkdir` of a name starting with `.`) fails with `EPERM`, and so do `mknod`, `symlink`
  and `link`. A folder copied into Upload takes the times and modes it is given and keeps none of them, and may be
  removed (`rmdir`) only while empty, else `ENOTEMPTY`; it cannot be renamed (`EPERM`).
- With uploads off (`uploads.enabled = false`), there is no Upload folder and the mount is read-only as a whole
  (`ro`).
- Desktop indexers get `EIO` when they open an original: GNOME's (`localsearch-extractor-3`, `tracker-extract-3`) and
  KDE's Baloo extractor (`baloo_file_extractor`). Always, not a setting: indexing the contents would download the
  library. Their file-name walks are answered as usual.

## Content

- Opening a file never waits for a download. Reads fetch the blocks they need, in 2 MiB blocks with HTTP range
  requests and sequential read-ahead.
- Cached blocks are served offline. An uncached read fails fast with `EIO` while the service is offline: once a
  request finds the server unreachable, every request fails at once for up to 45 seconds, and the change poll's next
  answer from the server ends that early. The first such read of an outage shows one notification naming the file
  ("Verso Drive cannot open “*name*”"), where the program shows only "Input/output error"; the next outage tells
  again.
- A read that makes no progress for 30 seconds fails with `EIO`. No filesystem call waits on the network without
  a deadline.
- A small read near a file's start or end that the cache cannot answer (a peek: a run of reads within 64 KiB)
  fetches the original's first 64 KiB and last 16 KiB together, and keeps them. Once a program has peeked at three
  files of a folder within 10 seconds, the start and end of the folder's other files, up to 1,000 of them, are
  fetched ahead of it, eight files at a time.
- The content cache has a size limit (default 10 GB). It evicts least-recently-used Assets that are not being
  read. It never takes the disk's last tenth: with less than 10% of the disk free, it evicts as if over its limit.
- Originals are byte-identical to the server's.
- The library is never mirrored.

## Thumbnails

- On the first listing of a folder with Assets, every Appearance gets a freedesktop thumbnail:
  - **Where:** `$HOME/.cache/thumbnails/x-large/<md5 of the file URI>.png`, made from Immich's `thumbnail` size
    (a WebP with a short side of 250 px), re-encoded as PNG.
  - **Format:** PNG `tEXt` chunks `Thumb::URI` and `Thumb::MTime`, file mode 0600, written atomically.
  - **Timing:** the listing waits up to 10 seconds for these. After that it answers anyway, and seeding continues
    in the background.
  - **Counts:** a listing of a folder whose parent's listing, or another count in it, ended less than 3 seconds
    before, after a sibling was listed, and which was not listed itself in that time, is taken for a file manager
    counting its items. It answers at once; its small thumbnails are written in the background, behind the folders
    being shown, and it gets no sharp thumbnails. Within a minute of such a listing, the first `access()` on one of
    its files (a file manager showing it after all) waits up to 10 seconds for its thumbnails, sharp ones following
    in the background.
- **Sharp thumbnails** (setting, on by default): each Appearance of a folder shown also gets an `xx-large/` (1024)
  thumbnail, downscaled from Immich's `preview`, in the background.
- **The safety net** (setting, on by default): when a known thumbnailer process opens an original (`glycin-thumbnailer`
  and others), it gets `EIO` instead of the bytes. It never gets substitute bytes.
- Listings made by the file manager's search, or by an indexer walking the tree (`localsearch-3`, `baloo_file`), do
  not trigger seeding.
- Every seeded file is recorded, and removed again when signing out (Sign Out in Verso, or `verso-service logout`).

## Uploads

- Only the Upload folder accepts new files, and only while `uploads.enabled` is on and the credential may upload.
  An uploaded file leaves Upload and shows in Photos under its own date (and in albums, people and places as Immich
  files it); where it was dropped never decides where it appears. With uploads off, there is no Upload folder.
- Only image and video files are uploaded (the server's media types, RAW included), on their own or in folders
  copied into Upload (below). Symlinks, other files, Live Photo pairs and XMP sidecars are not supported.
- **Upload on close:** the upload runs when the writing program closes the file. `close()` returns success only
  after the server has answered. If the upload fails, `close()` fails too, so the program reports the error and a
  move keeps its source, in programs that check `close()` (Files, `mv`, `cp`, rsync).
- **Nothing that failed to upload is thrown away:** the file is kept in `~/.local/share/verso/not-uploaded/`
  under its own name (numbered if the name is taken), and the notification says so. So is what a service that died
  mid-upload left behind, at its next start. Only what the user dropped is deleted: a cancelled copy that ends short, an
  empty file, a file deleted or replaced in Upload.
- **Where the kernel limits one file operation** (`fs.fuse.default_request_timeout`, Linux 6.14 and later), an
  upload, a read and a listing each end a second before that limit: a longer upload fails its `close()` with `EIO`
  and is stopped, with one notification naming the setting, and the mount stays up. Off by default.
- Files are sent unchanged: no resizing, transcoding, metadata stripping or date rewriting. A file copied in alone
  joins no album; folders copied in make albums (below).
- **Outcomes:**
  - A new Asset or **Already in library** counts as success.
  - A **trashed duplicate** is restored from the trash, as it was (its date, albums and faces), and counts as
    success; on Linux a notification says so. Without `asset.delete` it fails, and stays in the trash.
  - Temporary server errors are retried, within a time limit.
- **Temporary names:**
  - A hidden photo (`.IMG_1.JPG`) uploads on close like any photo. Known temporary names (GIO's
    `.goutputstream-*`, rsync's `.<name>.<6 characters>` around a photo's name) are staged, and uploaded once
    renamed to the photo's name. Any other hidden name is refused, and so are macOS's `._` companion files.
  - An empty file is never uploaded: it disappears from Upload when its last handle closes.
  - After an upload, the written name stays in Upload as a **receipt** for about 10 seconds, then disappears; it
    may be deleted before then. The Asset appears in its date folder in Photos. **Already in library** (the same
    bytes are in Immich, a photo copied from the drive itself, say) adds nothing, and a notification says so.
- A desktop notification explains refused files, and reports long uploads and failed ones. Repeated refusals of
  one kind within 20 seconds give one notification.
- **What programs see:**

  | Situation | Error |
  |---|---|
  | A file type Immich does not take, at `create` or on a rename | `ENOTSUP` (Operation not supported) |
  | A name an Asset already has in that folder | `EEXIST` |
  | The same bytes are in the trash, and the credential may not restore them | `EEXIST` on `close()` |
  | The credential may not upload | `EACCES` on `close()` |
  | Server unreachable or busy past the limit | `EIO` on `close()` |
  | A hidden folder, a link or a device node in Upload; renaming a folder there | `EPERM` |
  | Removing a folder in Upload that is not empty | `ENOTEMPTY` |
  | Any change outside Upload | `EROFS` |

### Folders copied into Upload

- **A folder copied into Upload is taken whole,** with the folders inside it: every photo and video in it uploads to
  the timeline as it arrives, exactly as a single file does (on close, with the same outcomes and errors), and other
  files in it are refused as they would be in Upload.
- **Settling:** no program tells that a copy is coming or how big it is, so a copy counts as finished once nothing
  new has arrived in it for 5 seconds and nothing in it is being written or uploaded. It is asked about within a few
  seconds of that.
- **Albums,** once it has settled, as `uploads.folders` says:
  - `ask` (the default): Verso asks, naming the folder, counting what uploaded and what did not, and listing the
    albums it would make, with two buttons: **Make Albums** and **Timeline Only**. Dismissing the question, or no
    answer within a day, is the timeline only. Where nobody can be asked (no desktop session, or notifications
    without buttons), it is the timeline only.
  - `albums`: the albums are made without asking. `timeline`: none, as for single files.
  - A copy with nothing uploaded (an empty folder, or only refused files) makes no album and asks nothing.
  - **Timeline Only is the way out:** nothing more happens, and the photos stay in the timeline. Nothing here takes
    an upload back; a photo uploaded by mistake is deleted in Immich, as any upload is.
  - **A change of mind is another copy:** a copy answered Timeline Only that is copied into Upload again is asked
    about again. Immich recognises the photos it has, so nothing is sent twice, and Make Albums takes them all.
- **Which albums:** one for each folder that directly holds photos or videos that uploaded, holding those (not those
  of the folders inside it). It is named by the folder's path below Upload, joined with ` › `: `Trip`,
  `Trip › Day 1`. A name an album has already (the account's own, or one shared with it, compared ignoring case and
  Unicode form) gets the day's date: `Trip - 2026-11-09`, then `Trip - 2026-11-09 (2)`. A photo Immich had already
  goes into the album too, and so does one restored from its trash.
- **After the albums:** what arrives later in the same copy, while it is remembered (10 minutes after its last
  file), joins its albums, and a new folder in it gets one of its own. A folder of the same name copied after that
  is a new copy. An album made by a copy and deleted since is not made again.
- **Failures:** making albums needs `album.read`, `album.create` and `albumAsset.create`. A server that cannot be
  reached, or is busy, is tried again a minute later, for up to a day; an album made whose answer was lost is found
  again by its name and first photo, never made twice. Any other failure (no permission, signed out, a request the
  server refused) is told in a notification, and the copy stays in the timeline only.
- **The folders leave Upload soon after their copy,** about as soon as their last file has (their files leave as
  single files do):
  - **On Linux** a copy's folders go together, once none of them holds a file and nothing arrived in any of them for
    5 seconds. For 10 minutes after, a gone folder looked up by its path comes back, so a copy that only paused
    (Files stops at a file Immich does not take until Skip or Skip All) goes on into it. A folder of the same name
    copied again within those 10 minutes is that folder: Files asks to merge, and its photos join the earlier copy.
  - **On the Mac** a folder goes 20 seconds after its last file (or as long as macOS takes to bring its list up to
    date, and 10 seconds more), once macOS says it holds nothing the extension has not been handed (Finder may still
    be writing a large file into it). Where macOS does not say, or says its list is full, it stays 10 minutes.
  - An empty one may be removed before then.
- **Files stops at a file it cannot copy** (one Immich does not take) and asks; Skip All goes on with the rest. A
  copy with nothing uploaded yet waits for its first upload before it is asked about.
- **Hidden folders** (a name starting with `.`: a thumbnail cache, a version-control folder) are refused, without a
  notification; a hidden photo still uploads.
- **On Linux** the service asks, as an urgent desktop notification, which stays on screen until a button is
  pressed or it is dismissed; a click on the notification itself answers nothing, and it asks again. It looks for
  the desktop's notifications when a question is due, and a question waits for them, so a service that started
  before the desktop still asks. A restarted service (a settings change) asks again what was being asked, in place
  of the notification it showed before. A file of a copied folder that did not upload is kept under its folder's
  path: `not-uploaded/Trip/Day 1/IMG_1.JPG`.
- **On the Mac** Verso does not ask yet: with `ask`, the question goes unanswered, which is the timeline only
  (`albums` makes them without asking). A file that did not upload stays in its folder in Upload, with its reason,
  and the folder with it; deleting the folder in Finder lets both go.

## Links to Immich

Each item the drive shows that Immich's web app has a page for has a **web address**: the server's address
(`server.url` without a trailing slash and without `/api`) followed by the item's **Immich path**, the path of
Immich's web app for it (`web/src/lib/route.ts` and `web/src/routes/(user)/` in immich-app/immich, which Immich's
mobile app also takes as deep links). A photo keeps the folder it is listed in, so its page opens in that album,
person or place.

| Item | Immich path |
|---|---|
| A photo in Photos (in a month or a day folder) | `/photos/<id>` |
| A photo in an album, directly or in its year and month folders | `/albums/<album>/photos/<id>` |
| A photo in a person, likewise | `/people/<person>/photos/<id>` |
| A photo in Favorites or Archive, likewise | `/favorites/photos/<id>`, `/archive/photos/<id>` |
| A photo in a city, likewise | `/search/photos/<id>?query=<q>` |
| An album, a person, Favorites or Archive, and their year and month folders | `/albums/<album>`, `/people/<person>`, `/favorites`, `/archive` |
| A city, and its year and month folders | `/search?query=<q>`, `q` = `{"city":"<city>","country":"<country>"}` |
| A country | `/search?query=<q>`, `q` = `{"country":"<country>"}` |
| Photos, Albums, People, Places | `/photos`, `/albums`, `/people`, `/places` |
| The drive itself, Photos' year, month and day folders, the year folders above albums, Upload and everything in it | none: Immich has no page for it |

- `q` is the JSON Immich's web app writes for a search: its keys in the order shown, no spaces, encoded as
  JavaScript's `encodeURIComponent` does. City and country names are Immich's own, never the folder's name on disk.
  Immich's Places page searches for a city by its name alone; the country is added so two cities of one name stay
  apart.
- The same item gives the same address on every platform: the map is in the core (`links.rs`).

**Open in Immich** opens the web address in the default browser, and **Copy Immich Link** puts it on the clipboard.
In the drive they are offered on one item at a time, for items with a web address, and nowhere else, while the switch
**Open in Immich and Copy Immich Link** (`web.links`, on by default) is on: on Linux in Preferences, General, under
Immich Web App; on the Mac in Settings, Verso Drive. Verso's window offers them in its own menus too, by the same
switch.
- **In Files:** Verso's Files extension. Homebrew's cask and the tarball carry it as a nautilus-python extension
  (`~/.local/share/nautilus-python/extensions/verso-nautilus.py`; Bazzite ships nautilus-python). Packages are to
  carry it as a native one (`libverso-nautilus.so` in Nautilus's extension folder, built by
  `linux/files-extension/build.sh`; Verso has no packages yet). The Python one offers nothing where the native one is
  installed too, so the items never show twice. Items whose address is not a file (Recent, Starred) have none.
- **In Finder:** two actions of Verso Drive's File Provider extension (In Finder). They work whether Verso runs or
  not.
- **In a terminal:** `verso-service web <path>`, `--copy`, and `--json` (The `verso-service` command).
- **The service** answers `Links` on D-Bus (The daemon's D-Bus interface), which the items in Files ask with a 250 ms
  limit, never starting the service, falling back to `WebLink` against a service without it; after a call that timed
  out, Files does not ask again for 30 seconds. It finds the item from the folder listings it has, so a path the file
  manager shows needs no request to the server. With no service answering, or the drive off, the items are not
  offered.

### Links from other apps (Immich Crosslink)

Verso takes part in [Immich Crosslink](https://jakob.hviid.phd/immich-crosslink/), draft 0.2: other Immich apps on
the computer can ask it to show a photo, album, person or place. On Linux it takes part twice, as two participants:
**Verso Gallery**, which opens the item in Verso's window, and **Verso Drive**, which shows the item's file or folder
in Files, selected.
- **Announcing:** each participant is a desktop entry of its own in `~/.local/share/applications/`
  (`dev.hviid.Verso.Gallery.desktop`, `dev.hviid.Verso.Drive.desktop`), kept out of the app grid (`NoDisplay=true`),
  registering the scheme (`MimeType=x-scheme-handler/immich-crosslink;`) and announcing
  `X-Immich-Crosslink-Version=0.2` and `X-Immich-Crosslink-Shows=asset;album;person;place;page;`. The service writes
  each as it starts while Immich Crosslink (`crosslink.enabled`) and the participant's own switch are on
  (`crosslink.gallery`; `crosslink.drive`, and the drive on), removes it otherwise and at sign-out, and brings the
  folder's MIME cache up to date. The app grid's entry announces nothing. Verso Gallery's entry runs `verso %u`;
  Verso Drive's runs `verso-service app %u`, which hands the link to the service (`ShowLink`) without opening the
  window. Verso as a Flatpak takes part as Verso Gallery alone, through the entry it exports. Verso as an AppImage
  takes part in neither: its service writes no entries, and the entry in the file announces nothing.
- **Reading:** a link is *invalid* (another scheme, a host, no `server` or one that is not an `http` or `https`
  address, an id that is not a UUID, a malformed search), *cannot show* (a path or a search the protocol does not
  define), or names an item. The server must be the signed-in one (scheme, host without case, port, a default port
  the same as none), and the user too where the link names one and the credential may read the account's id.
- **Where Verso Drive shows it:** where the link says: a photo in its album, person, city, Favorites or Archive, in the
  date folders it falls in there; `/photos/<id>` in Photos, in its month (or day) folder, or in Archive when the
  photo is archived and that section is on. A photo whose folder the drive does not show, or whose folder does not
  hold it, shows in that place of its own instead, as the protocol asks. An album, a person, a city (also by its name
  alone, as Immich's Places page links it) and a country show as their folders, a section as its folder at the top.
- **Nothing to show** in Verso Drive gets a notification, and nothing else happens:

  | Result | Notification |
  |---|---|
  | Immich Crosslink off | "Links from other apps are off": turn on Immich Crosslink in Verso's settings |
  | Verso Drive off or unmounted | "Verso Drive is not mounted": switch it on in Verso's Preferences |
  | Invalid | "A link from another app cannot be opened": not a valid Immich link |
  | Cannot show | "Nothing to show": Verso Drive has no place for what it points to |
  | Another server | "Not signed in to *host*" |
  | Another user | "Another Immich account" |
  | Not in the drive (an id the account cannot see, a hidden person, a section that is off) | "Nothing to show": the drive does not show it |
  | The server cannot be reached | "Immich is unreachable" |
  | No service answering | "Verso Drive is not mounted": switch it on in Verso's Preferences, then open the link again |

- **In Verso Gallery,** a link opens the item in Verso's window, and one it cannot show gets a message at the
  window's foot saying why (another server, another account, nothing Verso can show, a link it cannot read). A link
  that arrives before Verso is signed in waits for the sign-in.
- **On the Mac** the app's Info.plist announces the same (`ImmichCrosslink`: `Version` `0.2`, `Shows` the five
  kinds) and declares the scheme (`CFBundleURLTypes`), and a link opens the item in Verso's window. Verso Dev takes
  its own scheme (`immich-crosslink-dev`) and a version no app follows, so it never takes the release's place.
- **Not on the iPhone and the iPad:** Verso on iOS takes no part, and registers no crosslink scheme (ARCHITECTURE.md,
  "Not on the iPhone and the iPad").
- **The default handler:** several apps may take the scheme. Verso never makes itself the default: apps that take
  part send a link to one app by name, and a link opened in a browser or with `xdg-open` or `open` goes to the app the
  system chose, which the user can change (`xdg-mime default dev.hviid.Verso.Gallery.desktop
  x-scheme-handler/immich-crosslink`).
- **Only showing:** any web page can open a link, so a link only ever shows an item. Nothing is fetched but what
  showing it needs (for Verso Drive, the item's folder listings and, for a photo, its details, `GET /assets/{id}`);
  nothing is downloaded, uploaded, changed or deleted, and nothing asks.

### Show in other apps

Beside Open in Immich and Copy Immich Link, **Show in _app_** sends the item's crosslink to another app that takes
part in Immich Crosslink, which shows it there: from Verso Drive's menu in Files, and from Verso's window.
- **In the window's right-click,** on Linux as on the Mac, they are gathered in a **Show In** submenu, each app by its
  name, with **Immich** (the web app) first and **Copy Immich Link** beside the submenu; Linux's grid leaves Info
  out of its right-click, as the Mac's does. On the Mac the submenu also holds **Verso Drive** (while it is on: the
  item selected in Finder, in the drive's location, through the drive's own lookup of the link) and **Widget** for
  photos (checked while they are in the widget's Chosen Photos); on Linux, Verso Drive is one of the apps.
- **The way back, in Finder:** on an item of Verso Drive with a web address, **Show in Verso** beside Open in Immich
  hands the item to Verso itself (its crosslink, in the app's own scheme), which shows it as a received link. One
  app, so this is no link between apps; other apps are reached through Immich Crosslink alone.
- **Which apps:** those whose desktop entry takes the scheme and announces draft 0.2 (`X-Immich-Crosslink-Version`)
  and the item's kind (`X-Immich-Crosslink-Shows`), less the participant asking (Files' menu leaves out Verso Drive,
  the window Verso Gallery, so each offers the other) and the ones switched off in the settings (`crosslink.hidden`).
  A photo's kind is `asset` wherever it is listed; an album's `album`, a person's `person`, a city's or a country's
  `place`, a section's `page`. Each is named and drawn by its desktop entry.
- **Sending:** the crosslink, with the signed-in user's id when known, goes to that app alone (GIO's
  `g_app_info_launch_uris` in Files), never to the scheme's default, and byte for byte as the service wrote it.
  An app whose program is missing (its `TryExec`, where it has one, or the program of its `Exec`) is not offered.
  When sending from Files fails, a notification titled "Immich Crosslink" says "*app* is no longer installed." (its
  desktop entry gone since the menu was made) or "Verso could not open *app*: *the system's reason*", and the next
  menu reads the apps again.
- **Off:** with `crosslink.enabled` off, no Show in items; Open in Immich and Copy Immich Link stay.
- **In the Flatpak,** whose sandbox cannot list the other apps, the window's Show In offers one **Another App…**, which
  has the system ask which app (the OpenURI portal). The AppImage lists the apps as an install does.
- **The settings** (Preferences, Crosslink): the **Immich Crosslink** switch, with **Learn More**, a link to the
  protocol whose address is not shown. Then **Verso Takes Part As**, with a switch each for Verso Gallery and Verso
  Drive. Then **Apps That Take Part**, each by its name and icon with a switch, described as "Apps that take part are
  found by themselves. Turn one off to leave it out of Show in. One not found stays listed for 30 days, so it stays
  off if it comes back; Forget removes it now." With none, "No other app that takes part is installed." and a link to
  the protocol's participants (**Find Apps That Take Part**). An app seen before but not found at the moment (not
  announcing, unreadable, or its program gone) stays listed for 30 days, as **Not found**, by its remembered name and
  a generic icon, with its switch and a **Forget** button. Forgetting it, by hand or after 30 days unseen, drops its
  switch too, so an app that comes back is new and on. An app that is found has no Forget: it would be found again at
  once. What was seen is Verso's state (`~/.local/state/verso/crosslink-seen.json`), not a setting. The menus offer
  only apps that are found. No app is set apart: Verso names and offers no app of its own accord.
- **With web links off,** the menus offer Show in *app* alone.
- Files' menu asks the service's `Links`; against a service without it, it offers Open in Immich and Copy Immich
  Link only.

## Signing in and credentials

| Method | Offered when | Verso's window | Command line | Stored |
|---|---|---|---|---|
| Browser (OIDC) | The server has OAuth (`/server/features` `oauth`) | A button with the server's own text ("Sign in with SSO" when it has none) opens the user's browser; the provider redirects to `app.immich:///oauth-callback` | `verso-service login` prints the URL; the final redirect URL is pasted back | Session token |
| Email and password | The server allows password login (`passwordLogin`) | **Email and Password** | `verso-service login --password`: a terminal prompt, or stdin | Session token; the password is never stored |
| API key | Always, as the advanced option | **Use an API Key Instead** | `verso-service login --api-key` (stdin or a file) | The key |

- The window asks for the **Server Address** first, then offers the methods the server allows.
- **The address:** typed with `http://` or `https://`, it is reached as typed. Typed without, Linux reaches it with
  https (`normalised_address`); the Mac and the iPhone try https first, as Immich's app does, and plain http after a
  failed https only for a server on the local network (a private or link-local address, Tailscale's 100.64.0.0/10,
  this device, a name without a dot, or one under `.local`, `.lan`, `.home`, `.home.arpa`, `.internal` or
  `.localdomain`), never after a certificate's error: a certificate the system refuses is asked about (below), and
  where the server asks for a client certificate, the sign-in says to type `http://` to connect without encryption.
- **A certificate of the server's own** (ARCHITECTURE.md, "A certificate of the server's own"). A certificate the
  system trusts needs nothing. One it does not (self-signed, or from a private authority not in the system's trust
  store) is refused, nothing is sent, and Verso asks:
  - **On Linux**, a question, **Trust This Server's Certificate?**: the certificate the server presented is not one
    this computer trusts; a server at home often has its own, but anyone between Verso and the server could be
    pretending to be it; trust it only if the fingerprint is the server's, which `openssl x509 -noout -fingerprint
    -sha256 -in <its certificate file>` shows on the server. Below, the certificate: **Fingerprint (SHA-256)** in pairs
    (`AB:CD:…`), **Issued To**, **Issued By** (**Itself (self-signed)** for a self-signed one), **Valid From** and
    **Valid Until**, and a sentence when it has expired, is not valid yet, or was made for another name. **Cancel** is
    the default; **Trust This Certificate** (in red) checks the server again trusting that certificate, for that
    address alone, and signing in keeps it with the server (`server.certificate_sha256`).
  - **Another certificate** from a server whose certificate was trusted is refused, never trusted by itself: **The
    Server's Certificate Changed**, saying that a renewed or replaced certificate is expected, that otherwise someone
    may be pretending to be the server, and that Verso sends nothing to it until the person decides, with the new
    fingerprint and the one trusted until now (**Trusted Until Now**), and the same two buttons. While the library
    shows, its banner says "*host*'s certificate is not trusted, so Verso does not connect to it", with **Check
    Certificate…**, and the question comes by itself once per certificate. Trusting it keeps it in place of the old one
    and restarts the service with it.
  - **Preferences, Account** shows **Trusted Certificate (SHA-256)** while one is kept, with **Forget…**, which asks,
    then forgets it and connects again: the question comes again, unless the system trusts the server's certificate
    by then.
  - **The service** tells once, in a notification ("Immich's certificate is not trusted"), and Verso Drive serves what
    it holds, as while the server cannot be reached.
  - **`verso-service login`** shows the same on a terminal and asks "Trust this certificate? [y/N]". `--trust-certificate
    <SHA-256>` trusts it without asking, only when it is the certificate the server presents; without a terminal and
    without the flag, it stops, printing the certificate and the command with its fingerprint. A certificate kept for
    the server is trusted again without asking.
  - An expired certificate may be trusted, and a trusted certificate stays trusted after its end date: it is still the
    certificate the person chose.
  - The Flatpak does the same, keeping the certificate in its own config.
  - **On the Mac, the iPhone and the iPad** the same question, in the same words ("this Mac", "this iPhone", "this
    iPad"), is a sheet over the sign-in, after Continue, with the same details and Cancel and **Trust This
    Certificate** (on the iPhone and the iPad, in red after the details, with the sheet's close button as Cancel too).
    Trust checks the server again trusting that certificate for that address alone, and signing in keeps it with the
    account. While the library shows, a certificate that changed, or one forgotten, is asked about by
    itself once per certificate, as **The Server's Certificate Changed** where another was trusted; the banner across
    the library says "*host*'s certificate is not trusted, so Verso does not connect to it", with **Check
    Certificate…**, and Trust keeps the new one in place of the old one and connects again, Verso Drive with it. The
    account's page (Settings, Account, on the Mac; the account's sheet, Server, on the iPhone and the iPad) shows
    **Trusted Certificate (SHA-256)** while one is kept, with **Forget…** (on iOS **Forget Certificate…**), which
    asks, closes the page and connects again: the question comes again, unless the system trusts the certificate by
    then. Verso Drive serves what it holds meanwhile, as while the server cannot be reached; Verso in Messages says
    "Immich's certificate is not trusted, so Verso does not connect to it. Open Verso to check it." Signing out
    forgets the certificate with the account.
- **Taking Immich Mount's account over.** Where Immich Mount is signed in on the computer (its
  `~/.config/immich-mount/config.toml` names a server, and its keyring item or credential file holds a sign-in), the
  window's first page offers **Use Immich Mount's Account**. Verso then signs in to Immich Mount's server with a
  sign-in of its own: a new session made with Immich Mount's (`POST /sessions`), or Immich Mount's API key as it is,
  so signing out of one leaves the other signed in. It takes Immich Mount's other settings but its drive's place,
  name and switch, its credential file, its start at login and its update check, and switches Verso Drive on, at
  Verso's own place, so the two drives never mount over each other. Immich Mount is left as it is. A sandbox cannot
  read Immich Mount's settings, so the Flatpak offers nothing.
- Credentials live in the keyring (Secret Service), one item per server labelled "Verso: <server>" (attributes
  `application` `dev.hviid.Verso` and `server`). Without a keyring they live in a 0600 file next to the config.
  - The window and `verso-service login` store into a file when `credential.file` is set. Otherwise the window stores
    into the keyring, and into the file only where there is no keyring; `verso-service login` stores into the keyring
    inside a desktop session, and into the file otherwise (over SSH, on a server).
  - Reading prefers a credential file when one exists, then the keyring.
- Signing in happens once. A credential persists across restarts and reboots until Immich or the identity provider
  revokes it, or the user signs out. Signing in in the window starts the service and has it start at every login.
- A locked keyring triggers the system's unlock prompt. If the user dismisses it, the service says so in its log and
  stops cleanly, so it is not restarted into another prompt, and one notification says why. There is no repeated
  prompting, and no silent failure.
- A revoked credential (401) leads to one notification, "Signed out of Immich"; the top bar icon shows it, and its
  menu offers **Sign In…**, which opens Verso. Caches are kept.
- The redirect to `app.immich:///oauth-callback` opens the app that handles the scheme. Verso's desktop entry
  declares it, and Verso makes itself the scheme's default handler (in `~/.config/mimeapps.list`) as it starts a
  browser sign-in. The window is single instance and receives the address in its open window; a redirect for an
  earlier attempt is refused with a message. The Flatpak's exported entry declares the scheme, and the sandbox cannot
  choose the default. The AppImage's entry declares it too, and Verso does not write an entry that names a file that
  may move: the redirect reaches Verso once a tool that adds AppImages to the desktop (Gear Lever, AppImageLauncher)
  has made the entry the system's; signing in with an email and password or an API key needs no entry.
- Immich's password login has no two-factor step. Two-factor comes through the server's OIDC option, and the
  password form says so.
- **On the Mac,** Verso signs in to one account with the same three methods and keeps it in the Keychain; Verso Drive
  uses the same account (In Finder).

## Supported versions

- **Immich:** the current and previous minor release; today v3.3 and v3.2, so the floor is v3.2.0. Below the floor,
  sign-in stops, saying which Immich the server runs and that Verso needs v3.2 or later.
- **GNOME:** the current and previous release; today GNOME 50 and 49. Verso's window needs GNOME 49's libraries or
  newer, libadwaita 1.8 and GTK 4.18: Fedora 43 and newer, Ubuntu 25.10 and 26.04 LTS, Debian 14, Arch and other
  rolling distributions. On an older system (Ubuntu 24.04 LTS and what is built on it, Debian 13, Fedora 42) the rpm
  and the deb do not install, as their dependencies ask for those libraries, and `verso`, the tarball's (or a
  package's forced past its dependencies), does not start the window (ARCHITECTURE.md, "Packaging"): it writes to
  stderr `error: Verso needs
  GNOME 49 or newer (libadwaita 1.8 and GTK 4.18), and this system's libraries are older.` (`this system has no
  libadwaita.` where there is none), the systems new enough, that Verso's Flatpak and AppImage run there without Verso
  Drive, the requirements' address and the library it found; started on a desktop without a terminal, it shows the
  same in zenity's dialog, or else in a notification that stays until dismissed; and it exits with 1. The Flatpak
  brings GNOME's own libraries and runs there; the AppImage brings the libraries it needs, the C library among them,
  and keeps the system's graphics drivers; Ubuntu 24.04 is the oldest system it is checked on.
- **Linux:** a kernel with FUSE protocol 7.31 or later, a setuid `fusermount3`, and access to `/dev/fuse`, for Verso
  Drive.
- **macOS:** 15 or later.

## Configuration

`~/.config/verso/config.toml` (on the Mac, `config.toml` in the App Group container). Unknown keys are ignored on
read, and writes preserve comments. One settings table in the Core drives validation, `verso-service configure`,
Verso's Preferences and the Mac's Settings, where each setting has one place (ARCHITECTURE.md, "One layout for every
settings window"). Verso's Preferences show them on these pages:
- **General:** the app icon in the light style and in the dark style, Open in Immich and Copy Immich Link, the top
  bar icon's double click and colour, and, in the rpm and the deb, Check for Updates.
- **Crosslink:** Immich Crosslink, Verso Gallery and Verso Drive, and the other apps (Show in other apps).
- Under **Verso Drive:** **Status** (the drive's switch), **Drive** (its location and name, a bookmark instead of a
  drive, the cache's size, sharp thumbnails) and **Folders** (each section with its date folders, Upload, album and
  file names).
- No page shows the server (signing in sets it), the certificate trusted for it (signing in sets it, and the Account
  page shows it), the apps left out of Show in (each app's switch sets them), the headless credential file or
  `thumbnails.safety_net`: those are for `config.toml` and `verso-service configure`.

A change to the drive's settings restarts the service when its page is left or Preferences closes. Verso as a Flatpak
and Verso as an AppImage hide the drive's switch, place, name, bookmark, cache size and sharp thumbnails, the check for
a newer release and the app icon's two looks, and read none of them.

| Key | Values | Default | Meaning |
|---|---|---|---|
| `server.url` | URL | none | The Immich server; `/api` is added |
| `server.certificate_sha256` | a SHA-256 fingerprint: 64 hexadecimal digits, in pairs separated by colons or not | none | The certificate trusted for `server.url` where the system does not trust the server's own ("A certificate of the server's own"). Set by Trust This Certificate and by `login`, written or removed whenever signing in sets `server.url`, and removed by Forget… on the Account page; signing out keeps it with the server's address, as it keeps the other settings. Linux only |
| `mount.enabled` | bool | `false` | Verso Drive's switch (Switching it on). Off, the service runs the top bar icon alone |
| `mount.path` | path | `~/Verso` | Where the drive is mounted. Linux only |
| `mount.name` | `verso`, `verso-drive`, `immich` | `verso` | The drive's name: "Verso", "Verso Drive" or "Immich" in Files' sidebar, and the location's name in Finder. The mount point stays `mount.path`. (Immich Mount's `immich-mount` and `immich-drive` are accepted too) |
| `mount.at_login` | bool | `true` | Not used by Verso, whose service starts at every login while signed in: Preferences do not show it, and its value is not read |
| `mount.unmount_button` | bool | `true` | Files' sidebar lists the drive as a drive, with its unmount button; off, GVfs leaves it out and a bookmark takes its place ("Bookmark Instead of Drive" in Preferences). Linux only |
| `sections.photos` / `.albums` / `.people` / `.places` | bool | `true` | Show the section |
| `sections.favorites` / `.archive` | bool | `false` | Show the section |
| `grouping.albums` / `.people` / `.places` | `never`, `atLeast500`, `always` | `atLeast500` | Date groups |
| `grouping.favorites` / `.archive` | `never`, `atLeast500`, `always` | `always` | Date groups |
| `grouping.photos` | `never`, `atLeast500`, `always` | `atLeast500` | Day folders inside months |
| `albums.layout` | `year-prefix`, `year-folders`, `flat` | `year-prefix` | How album folders are named and grouped |
| `files.naming` | `date-time`, `original` | `date-time` | How files are named |
| `cache.limit` | size (`10GB`, `500MB`, or binary units: `10GiB`) | `10GB` | Content cache limit. Preferences offer 5, 10, 25, 50 and 100 GB, and show any other size as "Custom". Linux only |
| `uploads.enabled` | bool | `true` | Show the Upload folder, and upload what is copied into it (also needs the server's upload permission) |
| `uploads.folders` | `ask`, `timeline`, `albums` | `ask` | What a folder copied into Upload becomes besides its uploads: asked each time once the copy has settled, the timeline only, or an album of each folder too ("Folders copied into Upload") |
| `thumbnails.sharp` | bool | `true` | Also seed 1024 px thumbnails from `preview`. Linux only |
| `thumbnails.safety_net` | bool | `true` | Refuse thumbnailer reads of originals. In `config.toml` and `configure` only: off, a thumbnailer may download every original it is shown. Linux only |
| `web.links` | bool | `true` | Open in Immich and Copy Immich Link in Verso's menus, Files' and Finder's (Links to Immich); off, the service gives no web address and the menus offer Show in *app* alone |
| `tray.double_click` | `gallery`, `drive`, `preferences` | `gallery` | What a double click on the top bar icon opens: Verso, Verso Drive in Files (while it is mounted; else Verso), or Preferences ("Double-Click Opens" in Preferences, General). The Flatpak offers `gallery` and `preferences`. Linux only |
| `tray.colour` | bool | `false` | The top bar icon in colour, the lens in its five colours, grey while the server cannot be reached; off, in the desktop's one colour. Linux only |
| `app.icon` | A look: a design (`mist`, `sand`, `dark`, `paper`, `frame`, `slate`, `sky`), with `-night` after it for Night paper and `-graphite` after that for a graphite lens (`sand`, `sand-night`, `sand-graphite`, `sand-night-graphite`): 28 | `mist` | The app icon while the desktop's style is light: the picture on its print, its paper and its lens (DESIGN.md, "The picture's designs"). "Light Style" under App Icon in Preferences, General: a row showing the look's icon and name ("Sand, Night, Graphite"), which opens to Picture (each design by its icon in the row's paper and lens), Paper (Day or Night) and Lens (Colour or Graphite); the group's description says the app grid shows a new icon from the next login. Verso's launcher entry names the look of the desktop's style at once, so the app grid, the dash and the window's place in them show it (Files on disk): on GNOME every icon drawn from then on, the app grid's from the next login. Verso's windows, About and the sign-in page show the look of libadwaita's style, and turn with it while open (set with `configure`, from the window's next start); the picture beside a notification's text is the look of the desktop's style. Verso Drive's icon, the top bar icon and Verso Gallery's Crosslink entry keep theirs. Not in the Flatpak, whose window shows Mist, or Mist Night in the dark style. Linux only: the Mac and the iPhone keep their own choice ("The app icon on the Mac, the iPhone and the iPad") |
| `app.icon_dark` | A look, as `app.icon` | `mist-night` | The app icon while the desktop's style is dark, as `app.icon` is in the light style: "Dark Style" under App Icon in Preferences, General. The service names it in the launcher entry when the desktop's colour scheme turns dark (the portal's `org.freedesktop.appearance` `color-scheme`), and the light style's look when it turns back. Not in the Flatpak. Linux only |
| `crosslink.enabled` | bool | `true` | Immich Crosslink: show what another app links to, and offer Show in *app* (Links from other apps). Off, a link from another app to Verso Drive only gets a notification saying so. Labelled "Immich Crosslink", in English in every language, with a link to the protocol |
| `crosslink.gallery` | bool | `true` | Take part as Verso Gallery, so other apps show items in Verso's window |
| `crosslink.drive` | bool | `true` | Take part as Verso Drive while the drive is on, so other apps show items in Files |
| `crosslink.hidden` | ids separated by `;` | none | The apps left out of Show in *app*, by desktop entry id (`org.example.Photos.desktop`) or bundle id; Preferences show a switch per app found instead |
| `updates.check` | bool | `true` in the rpm and the deb, else `false` | Whether the service looks for a newer release on Verso's page and tells of it, once in a notification and on the top bar menu (ARCHITECTURE.md, "Updates on Linux"). "Check for Updates" in Preferences, General, in the rpm and the deb alone; elsewhere hidden and read as off, whatever is stored, and never under Homebrew or in a Flatpak, which update their own. Linux only |
| `credential.file` | path | none | Headless only: a 0600 file holding the credential |

The config file carries a format version; older files are migrated once on load.

## The `verso-service` command

One program: Verso's service and its command line. The window is `verso`, installed beside it.

| Command | Does |
|---|---|
| `verso-service` | Opens Verso's window where there is a display (as `verso-service app`); prints this help where there is none |
| `verso-service app [link]` | Opens Verso's window (`verso`), handing it what it was given. An `immich-crosslink:` link is shown by Verso Drive instead (`ShowLink`), without opening the window: Verso Drive's participant runs this, and with no service answering, a notification says the drive is not mounted |
| `verso-service daemon` | Runs the service in the foreground (what the user service starts): the top bar icon and the D-Bus interface, and the drive while it is on. Once the program it was started from is replaced by an upgrade and nothing on the drive is open or uploading, it unmounts and exits with status 75, on which the user service starts the new version. Once the program has been gone for two minutes (uninstalled), it unmounts, turns off the service that started it, takes the drive's bookmark out of Files' sidebar, removes the GVfs drop-in, its seeded thumbnails and Verso's Crosslink entries, and exits 0 |
| `verso-service login [--password \| --api-key] [--server URL] [--trust-certificate SHA256]` | Signs in; prompts only on a terminal. A server certificate the system does not trust is asked about, or trusted with `--trust-certificate` when it is the one presented ("A certificate of the server's own"). A running service restarts with the new sign-in, unless a copy into Upload is in flight |
| `verso-service logout` | Ends the session on the server, unmounts, stops the service, then removes the seeded thumbnails, the drive's bookmark and GVfs drop-in, Verso's Crosslink entries, the credential (every keyring item of Verso's, and the credential file) and every cache, the window's included; and turns the user service off. Settings and files not uploaded are kept |
| `verso-service mount` / `unmount` | Mounts: refused while the drive is off; else starts the user service (writing it first where no install brought one, and enabling it), or restarts it where it runs without the drive, and waits up to 15 s for the mount. Unmounts: the service goes on without the drive until Mount or the next login. When something keeps the mount busy, such as a file manager window showing it, `unmount` detaches it lazily (`fusermount3 -uz`), unless a copy into Upload is in flight: then it refuses, naming the file ("… is still uploading") |
| `verso-service status` | Connection state, server and its version, account, credential, mount point, cache usage |
| `verso-service doctor` | A read-only health check (see WORKFLOWS) |
| `verso-service configure list \| keys \| get \| set \| unset` | Reads and writes settings |
| `verso-service show <link>` | Shows in Files, selected, the item an `immich-crosslink:` link or an address of Immich's web app on the signed-in server names (Links to Immich), and prints its path. With `--json` it prints `{"link": …, "result": …, "path": …, "message": …}` and selects nothing. A link it cannot show exits non-zero with the reason. With `crosslink.enabled` off it shows nothing, web addresses included (`off`) |
| `verso-service web [--copy] <path>` | Opens the item at `path` in Immich's web app, in the default browser (`xdg-open`), or with `--copy` puts its web address on the clipboard (Links to Immich). With `--json` it prints `{"path": …, "url": …}` and opens nothing. A path outside the mount, an item Immich has no page for, and a mount that is not running each exit non-zero, saying which. `--copy` hands the address to `wl-copy` on Wayland, or `xclip` or `xsel` on X11, which keep it after the command ends. With `web.links` off it says so and exits non-zero |
| `verso-service completions <shell>` | Shell completions |

Global flags:
- `--json` makes every command write one JSON document to stdout.
- `--llm` (root only) prints the command reference plus this repository's docs.
- `--man` prints the man page.
- `--version` prints Verso's version.

Streams and exit codes:
- Results go to stdout. Progress, warnings and errors go to stderr.
- Exit code 0 means the command completed. A non-zero exit means it could not.
- Problems with individual items do not change the exit code; they show in the output and the JSON.
- Without a terminal, no command prompts. It fails with guidance instead.
- `VERSO_LOG` sets how much the service logs: `error`, `warn`, `info` (the default), `debug` or `trace`. At
  `info` it logs a folder that took longer than a second to open, with what took the time; at `debug`, every folder.

**The window** (`verso`) takes one address on its command line, which reaches the window already open: an
`immich-crosslink:` link or an address of Immich's web app on the signed-in server opens the item (Verso Gallery's
participant runs this); the sign-in redirect (`app.immich:`) finishes a browser sign-in; `verso:settings` opens
Preferences, and `verso:sign-out` the Account page, asking whether to sign out (the top bar menu's Preferences… and
Sign Out…).

## The daemon's D-Bus interface

The window's application ID is `dev.hviid.Verso`. The service owns the bus name `dev.hviid.Verso.Daemon`, object
`/dev/hviid/Verso/Daemon`, interface `dev.hviid.Verso.Daemon1`, with the drive and without it.

| Member | Kind | Meaning |
|---|---|---|
| `State` | property `s` | `online`, `offline` or `signed-out`, from asking the server every 10 seconds, at once on a change of network (the NetworkMonitor portal, and again 3 seconds later), and on `CheckNow` |
| `MountPoint`, `ServerUrl`, `ServerVersion` | properties `s` | What it is connected to; `MountPoint` is empty while the drive is off or unmounted |
| `Account` | property `s` | The signed-in account's email, read at start; empty when the credential may not read it (an API key without `user.read`) |
| `CacheUsage` | property `(tt)` | Bytes used, bytes allowed |
| `Fetched` | property `(tt)` | Bytes of originals fetched from the server since the drive was mounted, and the requests that fetched them |
| `Uploads` | property `a(sst)` | Uploads in flight: name, phase, bytes sent |
| `Refresh(path s)` | method | Read folders from Immich again on their next visit (the whole tree, whatever the path) |
| `ClearCache()` | method | Empty the content cache, except Assets being read |
| `CheckNow()` | method | Ask the server how it is at once, rather than at the next poll (the window's Try Now) |
| `RefreshIcon()` | method | Draw the top bar icon again, after `tray.colour` changed |
| `Quit()` | method | Stop the service, as the top bar menu's Quit does; the Flatpak's and the AppImage's window ask this, having no systemd to stop it |
| `Unmount()` | method | Unmount; the service goes on without the drive |
| `Links(path s) → (web s, crosslink s, kind s, hidden s)` | method | The links of the item at `path` for the menus: its web address, its crosslink (empty while `crosslink.enabled` is off), its kind (`asset`, `album`, `person`, `place`, `page`) and the apps left out (`crosslink.hidden`); all empty where `WebLink` is |
| `ShowLink(link s, select b, notify b) → (result s, detail s)` | method | The item a crosslink or a web address names (Links to Immich): `show` with its path, or `invalid`, `cannot-show`, `other-server` with its host, `other-user`, `not-found`, `off` (Immich Crosslink switched off), `no-drive` (Verso Drive off or unmounted) or `unreachable`. With `select` the file manager shows it selected (`org.freedesktop.FileManager1.ShowItems`); with `notify` a notification says why not. Without the drive, `no-drive` |
| `WebLink(path s) → (url s)` | method | The web address in Immich of the item at `path` (Links to Immich); empty for a path outside the mount or an item Immich has no page for. A path through a symlink to the mount's folder (`/home` on Fedora's atomic desktops) counts |
| `StateChanged(state s, message s)` | signal | Sent when the connection state changes; a desktop notification says the same once, when the server cannot be reached or the sign-in is refused |

The credential itself never crosses D-Bus.

**The top bar icon** (ARCHITECTURE.md, "The tray"): on the same connection, the service serves an
`org.kde.StatusNotifierItem` at `/StatusNotifierItem` (id `verso`, title "Verso") and its `com.canonical.dbusmenu`
menu at `/MenuBar`, and registers the item with `org.kde.StatusNotifierWatcher` whenever one appears. GNOME shows it
where the AppIndicator extension is on; stock GNOME shows none. Its icon shows the state: signed out
first, then the server out of reach, then the drive on and unmounted (`dev.hviid.Verso-signed-out-symbolic`,
`-offline-symbolic`, `-unmounted-symbolic`, else `dev.hviid.Verso-symbolic`; with `tray.colour`,
`dev.hviid.Verso-tray` and `dev.hviid.Verso-tray-<state>`). The menu, top to bottom:

| Line | Kind |
|---|---|
| "Connected to *host*", "*host* is not reachable", "Signed out of Immich" | grey: the state |
| "Verso Drive is unmounted" | grey, while the drive is on and unmounted |
| "Server version: Immich *version*" | grey, when the server said |
| "Signed in as: *email*" | grey, when the credential may read it |
| "Try Again Now" | while the server cannot be reached: asks it at once |
| "Open Verso" | after a separator, where Verso's window is found: the window |
| "Open in Files" | while the drive is mounted: the mount point, in the file manager (`xdg-open`) |
| "Unmount Verso Drive" | while the drive is mounted: `verso-service unmount`; refused while a file is uploading, with a notification saying which |
| "Mount Verso Drive" | while the drive is on and unmounted: `verso-service mount` |
| "Preferences…" | the window on Preferences (`verso verso:settings`) |
| "Check for Updates" | where the install looks for releases (the rpm and the deb, `updates.check`) and none newer is known: looks now, and says so in a notification when Verso is up to date |
| "Get Verso *version*…" | after a separator, once a newer release is known: its page |
| "Sign Out…" | after a separator: the window on its Account page, asking whether to sign out (`verso verso:sign-out`); nothing is signed out without the answer. While signed out, "Sign In…" instead, which opens Verso |
| "Quit Verso" | closes Verso's window, where it is open, and stops the service, which unmounts the drive; the service comes back at the next login, or when Verso is opened |

A click on the icon shows the menu (`ItemIsMenu`), as the Mac's menu bar item does. A double click (`Activate`, as
GNOME's AppIndicator extension sends it) opens what `tray.double_click` says. The tray starts each program in a
systemd scope of its own, so a window it opened outlives the service.

## Files on disk

| What | Where |
|---|---|
| Settings | `~/.config/verso/config.toml` |
| The window's remembered choices (view options, the albums' order, the sidebar's sections) | `~/.config/verso/gallery.json` |
| Credential (headless fallback) | `~/.config/verso/credential`, mode 0600 |
| Metadata store | `~/.cache/verso/<account>/metadata.redb` |
| Content cache | `~/.cache/verso/<account>/content/`: `<id>.bin` (sparse) and its block map `<id>.blocks`, and `<id>.edges`, the original's first 64 KiB and last 16 KiB |
| Upload staging | `~/.cache/verso/<account>/staging/` |
| The folders copied into Upload, followed for their albums | `~/.cache/verso/<account>/folder-copies.json` |
| Server thumbnails | `~/.cache/verso/<account>/server-thumbnails/` (Immich's own, by Asset id) |
| The window's pictures | `~/.cache/verso/gallery/<key>/`, one folder per server and account: thumbnails, previews, played videos and opened originals |
| Files not uploaded | `~/.local/share/verso/not-uploaded/`; `logout` keeps them |
| Seeded thumbnails | `$HOME/.cache/thumbnails/{x-large,xx-large}/`, each URI recorded in `~/.cache/verso/<account>/seeded-thumbnails`; where home is reached through a symlink, under both the resolved and the configured path |
| How it was installed | `/usr/share/verso/channel`, reading `package`, in the release's rpm and deb alone, which makes `updates.check` on by default; read by both programs as they start, beside a Flatpak's sandbox (`FLATPAK_ID`) and an AppImage's mount (`APPIMAGE`, `APPDIR`). `VERSO_INSTALLED` (`tarball`, `package`, `appimage`, `flatpak`) says it outright, for checks (ARCHITECTURE.md, "One build for Fedora's files") |
| The user service | `verso.service`, from the install that brought one (the rpm's and the deb's `/usr/lib/systemd/user/verso.service`), else written by Verso as `~/.config/systemd/user/verso.service` for the `verso-service` it finds (Homebrew's cask, a build of one's own) |
| GVfs's volume monitor's settings, where it is a user service | `~/.config/systemd/user/gvfs-udisks2-volume-monitor.service.d/verso.conf`: `Environment=LIBMOUNT_FSTAB=<the volume monitor's fstab>`, and, where home is reached through a symlink, `Environment=HOME=<resolved home>`; written by the service as it mounts, which then restarts the volume monitor, so Files lists the drive with its icon; removed by `logout` |
| The volume monitor's fstab | `~/.local/state/verso/gvfs-fstab`: `/etc/fstab` as it was when the service started, and, while the drive is mounted, `immich <resolved mount point> fuse.immich noauto,x-gvfs-show,x-gvfs-name=<drive's name>,x-gvfs-icon=dev.hviid.Verso.Drive,x-gvfs-symbolic-icon=dev.hviid.Verso-symbolic 0 0` (`x-gvfs-hide` in place of `x-gvfs-show` with `mount.unmount_button` off); written with that line before the drive mounts, and without it once it stops; removed by `logout` |
| The mount point's folder icon in Files | `metadata::custom-icon-name=dev.hviid.Verso.Drive` on the mount point, in gvfsd-metadata's store (`~/.local/share/gvfs-metadata/`), set by the service as it mounts and once mounted |
| The drive's bookmark in Files' sidebar, with `mount.unmount_button` off | A line `file://<mount point> <drive's name>` in `~/.config/gtk-3.0/bookmarks`: added by the service as it starts after the setting was turned off, taken away after it was turned back on (the last choice noted in `~/.local/state/verso/sidebar-entry`), renamed as it starts when `mount.name` changed (a bookmark the user titled otherwise keeps its title), and removed by `logout` |
| Verso's Crosslink participants | `~/.local/share/applications/dev.hviid.Verso.Gallery.desktop` and `dev.hviid.Verso.Drive.desktop` (Links from other apps) |
| The app icon chosen (`app.icon`, `app.icon_dark`) | The `Icon` line of the launcher entry `dev.hviid.Verso.desktop` in `~/.local/share/applications/` (Homebrew's cask, the tarball and a build of one's own put it there), naming the look of the desktop's style: `dev.hviid.Verso` for Mist's Day look in colour, else the path of a copy of the look's drawing, `~/.local/share/verso/icons/dev.hviid.Verso-<look>.svg`; that folder holds the copies of the two looks chosen and no other (Mist Night's, with the defaults). Set by the window as it starts, when its style changes and when the choice changes, by `configure`, and by the service as it starts and at each change of the desktop's colour scheme, so it is back after an upgrade put the install's entry in place. Where the entry is a package's own (in `$XDG_DATA_DIRS`), Verso writes its own copy of it with that line into `~/.local/share/applications/`, first line `# Written by Verso over the installed entry...`, and removes it while the line would be the package's own (`dev.hviid.Verso`) or once the package's entry is gone |
| The apps seen that take part in Immich Crosslink | `~/.local/state/verso/crosslink-seen.json` |
| The sign-in redirect's handler | `x-scheme-handler/app.immich` in `~/.config/mimeapps.list`, set by Verso as it starts a browser sign-in |
| Verso's menu in Files, Homebrew's cask | `~/.local/share/nautilus-python/extensions/verso-nautilus.py` |
| Logs | journald (`journalctl --user -u verso`) |

**What the rpm and the deb install** (ARCHITECTURE.md, "The rpm and the deb"), and take away again when removed:

| What | Where |
|---|---|
| `verso`, the launcher in front of the window | `/usr/bin/verso` |
| The window | `/usr/libexec/verso` |
| The service and the command line | `/usr/bin/verso-service` |
| The user service | `/usr/lib/systemd/user/verso.service`, running `/usr/bin/verso-service daemon` |
| The launcher entry | `/usr/share/applications/dev.hviid.Verso.desktop`, running `/usr/bin/verso %u` |
| The icons | `/usr/share/icons/hicolor/`: the app's and Verso Drive's at 16 to 512 pixels, the symbolic ones and the top bar's states |
| The app's own icons, the app icon's 27 other looks among them | `/usr/share/verso/icons/` |
| The translations | `/usr/share/locale/<language>/LC_MESSAGES/verso.mo` |
| Verso's menu in Files | `libverso-nautilus.so` in Nautilus's folder of extensions: `/usr/lib64/nautilus/extensions-4/` (Fedora), `/usr/lib/x86_64-linux-gnu/nautilus/extensions-4/` (Debian and Ubuntu) |
| The license and the third-party licenses | `/usr/share/licenses/verso/` (rpm); `/usr/share/doc/verso/`, the license as `copyright` (deb) |

Removing the package leaves the settings, the credential and the caches in the person's home; a running service
takes away what points at the drive once its program is gone (`verso-service daemon`).

`<account>` is the server's host and port (`photos.example.org-443`), readable in a file listing. Signing in again,
with any credential, keeps the caches. Two accounts on one server share the directory only if the user signs in as
another account without signing out first. Cached bytes stay right, because Asset ids are global, but the kept
listings show the first account's folders until each is refreshed (offline, until the server answers again).
Signing out removes every cache, which is the way to switch accounts. Directories are 0700 and files 0600.

Verso as a Flatpak keeps its settings, caches and state in the sandbox's own folders, under
`~/.var/app/dev.hviid.Verso/`. Verso as an AppImage keeps them where an install does, in Verso's own folders, so a
Verso of another channel on the same account reads the same settings and sign-in; it is no sandbox. It writes one file
outside them, while it is signed in and has the service start at login: `~/.config/autostart/dev.hviid.Verso.Service.desktop`,
which runs `"<the AppImage file>" verso-service daemon` (the file where it is: the window writes it again where the
file moved, and sign-out removes it). The service itself is the AppImage file run with `verso-service daemon` as its
first argument, as an instance of its own.

## Verso's window on Linux

What each page of Verso's window (`verso`) offers on GNOME. The pages follow Immich Gallery's on the Mac;
ARCHITECTURE.md, "Verso's window", gives the reasons. A page offers only what applies to what it shows: Recently
Deleted's photos only come back or go for good, a partner's are theirs, to look at and download, and the Locked Folder's
stay out of albums, sharing and tags. What cannot be undone, and moving photos to the trash or the Locked Folder, asks
first.

- **The sidebar:** Search and the main menu in its header. The main menu: New Window (another window on the same
  account), New Album…, Import…, Import Folders…, Edit Sidebar, Preferences, Keyboard Shortcuts and About Verso. The
  pages, in sections: Photos (Library, Favorites, Videos), Explore (Map, Places, Memories, Tags, Folders), Collections
  (Albums, People), Sharing (Shared Links, Partners) and Utilities (Duplicates, Large Files, Assign Location, Archive,
  Recently Deleted, Locked Folder); then My Albums (those not shared) and Shared Albums (those shared, one's own too),
  each listing as many as its heading's menu chooses (all, or 5, 10, 15, 20, 30 or 50; 10 at first) in the order chosen
  there (Title, Item Count, Date Modified, Date Created, Most Recent Photo, Oldest Photo; Date Modified at first), and
  Show All, when there are more, opening the Albums page on them.
- **The sidebar's foot:** an import, while one shows (ARCHITECTURE.md, "Verso's window"); the account (its picture, name
  and server; its menu: the name, email and storage used, Account Settings…, Preferences…, Administration… for an admin,
  Sign Out…); the notifications' bell; and Edit Sidebar's pencil. **Edit Sidebar** shows each page and section with a
  switch that hides or shows it (the Library always shows); a page moves up or down, to another section, or is dragged
  onto another page or a section's heading; a section moves up or down, and the user's own are renamed and deleted,
  their pages going back where they started. New Section… and Reset Sidebar…, which also takes the user's own sections
  away, sit beside Done.
- **A page of photos:** justified rows at the photos' own shapes, or squares, under a heading per month on a timeline.
  Its toolbar: smaller and bigger thumbnails at its start; Info, Square Photos, the Date Scroller (on a grid of months),
  Select, View Options where the page has them, the page's own buttons and More (Select All, Refresh, the page's own
  items) at its end. The size, the squares and the date scroller are one setting for every grid. The date scroller runs
  down the grid's right edge: the years, a dot for each month and a mark where the grid is; pointing at it names the
  month, and a click or a drag goes to the place pointed at.
- **Selecting:** a click selects a photo, Ctrl adds or takes one away, Shift a range, and a click beside the photos
  clears; a double click, Return or Space opens it. While something is selected, its actions show in a bar below:
  Favorite, Add to Album, Archive (Unarchive in the Archive), Download and Move to Trash; an album's page has Remove
  from Album in Archive's place, a link's page Remove from Link and no Move to Trash, Recently Deleted Restore and
  Delete Forever, the Locked Folder Move Out of the Locked Folder, Download and Move to Trash, and a partner's page
  Download alone. Favorite is one switch for the selection: on while every photo selected is a favorite; pressed, they
  all become favorites, or none does when they all are. Info (Ctrl+I, remembered) shows the selected photo's details
  beside the grid, editable there as in the viewer.
- **The photo menu** (a right click): Open, Info, Show in All Photos (not in the Library); Open in Immich, Copy Immich
  Link and Show in *app* ("Show in other apps"); Add to Album…, New Album with Selection…, and on an album's page Remove
  from Album and Use as Album Cover, on a link's page Remove from Link; Favorite, Share (Create Public Link…, Add to
  Public Link…), Stack Together, and, for a stack's photo selected alone, Open Stack and Unstack; Adjust Date and Time…,
  Set the Place…, Rotate Left, Rotate Right and Crop… (for one's own still photos); Tags (Add Tag…, Remove Tag…) and
  Move to the Locked Folder…; Export (Download Originals…, Download as ZIP…); Archive (Unarchive in the Archive) and
  Move to Trash…. Recently Deleted's menu has Open, Info and Show in All Photos, then Restore and Delete Forever…; a
  partner's has Open, Info, the links to Immich and the downloads; the Locked Folder's leaves albums, Share and Tags
  out, and ends with Move Out of the Locked Folder and Move to Trash….
- **View Options** (the Library, Favorites, Videos, Archive, Large Files, the Locked Folder, a person's and a tag's
  photos; remembered for each): All Items or Favorites, Photos and Videos or one of them, Date Taken or Date Added,
  Newest or Oldest First, each page offering only what it can (Large Files is always largest first). The button takes
  the accent colour while something is filtered out.
- **Keys in a grid:** the arrows, Home and End move a focus ring, reading a month not read yet and landing once it is
  here; Shift with an arrow extends the selection. Outside selection mode the ringed photo is the selection, as in
  Files, so a key acts on it; in selection mode Space adds it or takes it out. Return opens it; Ctrl+A selects every
  photo read so far; Escape leaves selection mode; Delete moves the selection to the trash after asking, naming a lone
  photo by when it was taken, and in Recently Deleted's grid deletes them for good, after asking; the period makes the
  selection favorites, or takes them out of Favorites when every photo in it is one, where the selection offers
  Favorite. Keyboard Shortcuts
  lists these and the app's own: New Window (Ctrl+N), Search (Ctrl+F), Refresh (Ctrl+R or F5), Import (Ctrl+Shift+I),
  Info (Ctrl+I), bigger and smaller thumbnails (Ctrl+plus, Ctrl+minus), New Album (Ctrl+Alt+N), Preferences
  (Ctrl+comma), Keyboard Shortcuts (Ctrl+?) and Quit (Ctrl+Q).
- **The viewer:** the photo beside the sidebar, over the page it came from, with Previous and Next at its sides, Live
  (plays a Live Photo) and a stack's count (opens the stack) at its top. It zooms with Ctrl and the wheel, a pinch,
  plus, minus and 0, or a double click. Its header: Favorite, Move to Trash (Restore in Recently Deleted), Face Names
  (Immich's boxes and names on the photo; remembered), Info, and More: Copy Image (Ctrl+C), Copy Original Image and Copy
  as File (not in the Locked Folder); Download Original… and Open With…; the links to Immich; Start Slideshow (F5), Full
  Screen (F11), Rotate View Temporarily Left and Right (until the next photo), Show in All Photos, Manage Faces… (a face
  given to a person or a new one, used as their face photo, or removed, after asking) and Loop Video (remembered); then
  Rotate Left, Rotate Right, Crop…, Add to Album…, on an album's page Use as Album Cover and Comments and Likes…,
  Archive, Move to the Locked Folder…, which give way to Delete Forever… in Recently Deleted and to Move Out of the
  Locked Folder in the Locked Folder, and are left out for a partner's photo. Below the photo, a scroll away (Down, or
  Ctrl+I), are its details: the people in it, a map of where it was taken, when (changed with its button), the file, the
  camera, the place (set with its button), the description and rating (edited in place), its albums and tags. Down goes
  on through the details and Up back to the photo; the period makes it a favorite or not; Delete moves it to the trash
  after asking, but not in Recently Deleted; Space goes back to the grid, or plays and pauses a video; Escape goes back.
- **Full Screen and the slideshow:** the photo on black, with controls that hide after 2.5 seconds without the pointer
  moving: Exit Full Screen, Previous, Play or Pause, Next, Show in All Photos and the slideshow's settings (Interval,
  Shuffle, Fade Transition, Limit Videos to Slide Interval; remembered). The slideshow goes on from the photo shown,
  Space pauses it, and it stops at the last. The sidebar folds away while they run.
- **The Library's Years, Months and All Photos** (a switch in its header): Years shows a card for each year, Months each
  month by one large photo and up to three more from other days. A year opens Months at its first month, a photo opens
  All Photos on it; selecting, the size and the date scroller wait for All Photos.
- **A stack** (its count in the viewer, or Open Stack): its photos, the primary first; its menu: Set as Primary, Remove
  from Stack, Move Others to Recently Deleted… (keeping the photo selected, after asking) and Unstack. The Library shows
  a stack as its primary photo, with a badge.
- **Pages of cards** (Albums, Shared Links, Places, Memories, People): the header's smaller and bigger buttons give
  five sizes, the same for every such page and for the square tiles of faces and cities (remembered); on Places, People
  and Memories, typing filters them by their titles.
- **The Map:** each photo with a place, in clusters, each a pin with a photo and its count, opening its photos. Its
  header's date range (All, 3 Years, 1 Year, 30 Days, 7 Days, 24 Hours) and Map Filters (Favorites Only, Include
  Archived, Include Partners, on at first, and a Custom Range from one day through another) are not remembered.
- **Every map** (the Map, a photo's place in its details, and Set the Place's): the Immich server's own map, from its
  map setting (Immich's light and dark map styles), as Immich's web app shows it, in the light or the dark as the
  desktop's style is, with the credits its tiles ask for at its foot ("© OpenStreetMap" for Immich's own), whose
  links open in the browser. When it cannot be drawn (the server names no map style, the map's host cannot be
  reached, or its style is one Verso cannot draw), the map says so where it would be, "Map Unavailable" with why (a
  line on a photo's small map), and the Map's pins still show and open their photos; the next map opened tries again.
  Tiles that could not be loaded are named along the map's top while one of them is in view.
- **Places:** Cities or Countries (a switch in the header, remembered). A city is a square tile, its photo with its name
  on it (and its country, where cities of several show), opening its photos; a country is a card of three of its places'
  photos, each labelled with its city, with how many places and the years its photos span, its first places named on
  hover, opening its cities.
- **Memories:** every memory Immich has made, newest first, a hundred at a time as the page scrolls, each a card: three
  of its photos, how many years ago, the day, how many photos, where most were taken and who is in them, New until it is
  opened, and a bookmark that keeps it (Immich removes a memory after 30 days unless it is kept). Delete Memory… on a
  right click, after asking; "Memories Are Off" when they are off in the account. A memory plays over the window: its
  photos one by one on black for the account's seconds per memory photo, fading in, with Previous, Play or Pause, Next,
  where it is, and Remove from Memory (the photo leaves the memory, not the library); it pauses at the last. Opening a
  memory marks it seen; the Locked Folder's photos stay out of it.
- **People:** All People, Favorites or Hidden People (a switch in the header, remembered), and Include Hidden People in
  View Options; favorites first, then the named, then the unnamed, each face a rounded square with the name on it. A
  face's right click: Rename…, Favorite or Remove from Favorites, Hide from People or Show in People, Merge With Another
  Person… (after asking), Open in Immich and Copy Immich Link. **A person's page:** a header with the face, the name
  (edited in place, Enter or leaving the field saving), a heart for a favorite, how many photos and videos, and the
  birthday with the age (or Add Birthday); the Person menu: Edit Name and Birthday…, Use as Face Photo (the one photo
  selected), Favorite, Hide from People, Merge With Another Person… and the links to Immich.
- **Albums:** All Albums, My Albums or Shared Albums (a switch in the header), New Album, and View Options (remembered):
  Covers or List; grouped by Year (not while sorting by the albums' own dates), by Owner, or not, each group folding
  away, in either order; sorted by one of the six keys, either way. A card: the cover and two more of its photos, how
  many and the years they span, its description while the pointer or the focus is on it, whom it is shared with (its
  owner first when it is another's, never oneself; four, then +N), and in its corner how far its working links reach
  (the globe, or the globe with a padlock when each has a password), the address on hover, copied with a click. A right
  click offers Open, Share…, and Copy Link and Open Link when it has a link. The list is a table whose headings sort.
  Files dropped on a card are imported into its album.
- **An album's page:** a header with, on the left, its name and description, which its owner edits in place (Enter or
  leaving the field saves, Escape cancels; "Add a description" while it has none), how many photos and the days they
  span; on the right, whom it is shared with, its owner first, each with their picture and their role on hover, and +
  (Share With People…) for its owner; under them, always, how far it reaches named beside its icon (Private, Shared with
  2 people, Shared with a password, Shared publicly), which opens the Share dialog. The Album menu: Add Photos…, Edit
  Album…, Share…, Download Album as ZIP… (numbered archives where Immich splits it); Sort Photos (Oldest First or Newest
  First, kept on the server), Comments and Likes (on or off), Show Comments…; the links to Immich; Delete Album… for its
  owner, Leave Album… for its members. Add Photos is also in its top bar, and on the page while it is empty, for its
  owner and those who may add. Its photos are in the order the album keeps. Linux edits the name and description in
  place; the Mac does so only through Edit Album (ARCHITECTURE.md, "Verso on the Mac").
- **Comments and likes** in a shared album (Show Comments…, or a photo's Comments and Likes… in the viewer): reading
  them, commenting, liking and unliking, and deleting one's own comments, after asking.
- **The Share dialog** (Share…, or the reach under an album's people; the + beside them opens it on People) has two
  pages. **Links**, where it opens: each link to the album with its icon, when it stops working and whether it needs its
  password, Copy Link and Open Link, and Edit Link… and Delete Link… (after asking) for whoever made it; Create Link…
  for the owner. **People:** headed by how far its people take it, each member with their picture, email and role; for
  the owner, a role menu (Can View, Can Edit) and Stop Sharing (after asking), and Add People, the server's other users,
  each added as a viewer. After each change the album's page and the Albums page show its new reach.
- **Shared Links:** the links as cards, with Share Album… (one of one's own albums, into the link editor), Refresh, and
  View Options (All Links, Album Links or Individual Shares, and Hide Expired Links; remembered). A card: some of what
  it shares (an album's cover and a few of its photos, which open the album; a link's chosen photos, which open its
  page), what it is (an album and its count, or how many photos), who may open it (anyone with the link, and its
  password) and whom the album is shared with besides; in its corners the days it has left (Expired, in the warning
  colour), what visitors may do and how far it reaches; along its foot Copy Link, Open Link (the web page, in the
  browser, not the app), Edit and Delete Link… (after asking).
- **The link editor** (Create Public Link… in the photo menu, Create Link… in the Share dialog, Share Album…, a link's
  Edit): Description, Custom URL Slug, a password (one already set kept unless changed, as the server never sends it
  back; empty for none), Expires with its Last Day (the link works to that day's end), and what visitors may do: Show
  Metadata (camera details and places), Allow Download (only with the metadata shown), Allow Upload. A new link is
  copied and shown, with Open Link. **Add to Public Link…** adds the photos to one of the account's links to chosen
  photos.
- **A link to chosen photos** has a page of its own, as an album has: its photos newest first, to look at, select, and
  take out of the link (Remove from Link; never Move to Trash, as they are the library's); a header with its title,
  until when it works and what visitors may do, Copy Link and Open Link beside Add Photos and Edit, and how far it
  reaches named beside its icon (or Expired), which opens the link editor. Its menu: Add Photos…, Edit Link…, Copy Link,
  Open Link, Delete Link… (after asking), which closes the page.
- **Find Similar Photos…** (More, on the Library, Favorites, Archive, Large Files and a person's page): a sheet that
  looks in the photos selected or a period (Last 30 Days, Last 3 Months, Last 12 Months, or a Custom Range), with
  Sensitivity (Strict, Normal, Loose) and Time Between Shots (5, 10 or 30 seconds). It compares, on this computer, the
  account's own still photos on the timeline or in the archive that are in no stack, at most 2000, and offers each group
  of look-alikes with a suggested cover. A click on a photo makes it the cover, × takes it out of its group (Restore
  Removed Photos brings it back), a group's tick leaves it in or out, and Stack Groups… makes the chosen groups stacks,
  the cover on top, after asking. Stop, or closing the sheet, stops what has not been sent. Nothing is deleted.
- **Tags:** a tree, each tag under its parent by name, with its colour as a dot, opening its photos. New Tag takes a
  path (Parent/Child); a tag's menu offers New Tag Inside…, Edit Tag… (its name, without a slash, and its colour or
  none) and Delete Tag… (with the tags inside it, after asking; the photos stay).
- **Partners:** Shared with Me, each partner opening a page of their photos, with a switch that shows them in one's own
  Library too; Sharing My Library With, each with Remove… (after asking); Add Partner…, from the server's other users.
- **Duplicates:** Immich's groups of look-alike photos, the first hundred (the next showing as these are resolved),
  sorted by Default Order, Most Items or Largest Size (View Options, remembered), with Reload. Each photo shows its file
  name and size with Keep, ticked at first on Immich's suggestion, or else on the group's first; Keep Selected, Trash
  Others… and Dismiss Group… (all stay, and Immich stops suggesting them), each after asking.
- **Assign Location:** the photos without a place, or every photo (Location in More; remembered), each with its place on
  it (the city, "GPS" for coordinates without a city, or "No GPS"); Assign Location… in the header sets the place of
  those selected.
- **Folders** lists the server's folders that hold the originals, as Immich's folder view shows them, each opening the
  folders and photos in it (the first 400 of a level). **Large Files** shows the largest first. **Recently Deleted** has
  Restore All, and Empty Trash… after asking, in its menu. **The Locked Folder** opens with the account's PIN (Unlock…),
  and an account without one sets its first, six digits typed twice (Set Up…); it needs a sign-in with a password or
  single sign-on. Lock in its menu, or choosing another page, locks it again.
- **Search** (the sidebar's header, Ctrl+F): words looked for in what photos show (smart search, which needs machine
  learning on the server), file names, descriptions or the text in photos. Filters, in a sheet: People (the first twelve
  in Immich's order with any already picked, Show All for the rest, a name typed finding anyone), Location (Country,
  State, City) and Camera (Make, Model, Lens), each list narrowed by the one above it, Date Taken (After, Before), and
  Display (Media Type, Not in an Album, Archived, Favorites, Rating); the filters chosen show as chips that each take
  theirs away, with Clear Filters, and filters alone search too. Default Order, Newest First or Oldest First (a date
  order sorts smart search's best 250). Recent searches, twenty per account, with Clear History. With nothing to search
  for, a landing page: quick filters (Favorites, Photos, Videos), the recent searches and the places in the library.
- **Notifications** (the bell, with the count of unread beside it): Verso's own, headed Verso, on this computer (what
  each import came to), and Immich's, headed Immich with the server's address (album invitations, failed jobs, the
  admin's messages); a section with nothing is left out. A row has a sign by its level, its title in bold while unread,
  a line, and how long ago; a click marks it read, an import that left files out opens in place to list each with why
  (up to 100, then how many more), and its trash button deletes it. Mark All Read covers both sections; with nothing,
  "No Notifications". ARCHITECTURE.md, "Verso's window", says where they are kept and when Immich's are read.
- **Preferences** (the main menu, Ctrl+comma, the account's menu): a window with a sidebar of pages, each with its icon:
  Account (a person), General (`preferences-system-symbolic`), Crosslink (Immich Crosslink's two linked rings,
  `verso-crosslink-symbolic`) and Features (a puzzle piece); under Verso Drive, Status (Verso's mark,
  `dev.hviid.Verso-symbolic`, as Files and the top bar show the drive), and while the drive is on Drive (a disk) and
  Folders (a folder); under Server, for an admin, Administration (a server, `verso-server-symbolic`). General, Crosslink
  and the drive's pages show the settings ("Configuration"). In a Flatpak or an AppImage, one Verso Drive page says the
  drive is not part of it, and where to get it; the AppImage's Crosslink page lists the apps and takes no part.
  - **Account:** the server, whom it is signed in as and with what (a session or an API key), and the certificate
    trusted for the server, with Forget… ("A certificate of the server's own"); the profile: its picture
    (Choose Picture…, Remove), its name and the storage used; for a session, Change Password… (where the account has a
    password, optionally signing the other devices out), Devices (where the account is signed in, with Sign Out Others…,
    after asking) and API Keys (New Key…, whose secret shows once, and deleting one, after asking); Sign Out….
  - **Status:** Verso Drive's switch and, while it is on, how the drive, the connection, the uploads, the cache and the
    sign-in stand, with Mount, Unmount and Open in Files.
  - **Features:** the account's preferences in Immich, for every app that uses it (memories, ratings, folders, tags,
    people, shared links, the albums' default order, downloads, email notifications and the rest), a row only where the
    server has its value; each change is saved a moment after the last.
  - **Administration:** the server (its Immich version, storage and library), the use by user (with quotas), the job
    queues (Run, and Pause or Resume; read again every five seconds while shown), external libraries (Scan) and the
    users; Open Administration in Immich, where users and the server's settings are changed.

## In Finder (Verso Drive on the Mac)

The same layout, names, attributes and content as the mount, through Apple's File Provider: an extension of Verso's
app (ARCHITECTURE.md, "Verso on the Mac"). Where Finder's way differs:

- **Switching it on:** in Settings, Verso Drive, or with the menu bar item's **Turn On Verso Drive**. On and signed
  in, Verso keeps its account for the extension, in the Keychain group and App Group they share, and adds one
  location (the File Provider domain `library`), named by `mount.name`. A new location waits to be switched on with
  Enable at the top of its Finder window, or in System Settings, General, Login Items & Extensions, File Providers;
  Settings, Verso Drive says so meanwhile. Another account's sign-in replaces the location, its store first removed.
- **Changes reach Finder** while Verso runs: it wakes the extension every ten seconds, and soon after a change made in
  Verso.
- **`CACHEDIR.TAG`** at the location's root, as on Linux ("Files the mount answers itself"), for backup tools that
  honour it. It is the Mac's alone: the Files app on the iPhone and iPad has none.
- **Uploads:** the system hands over a finished file, so there is no staging. A file Immich refuses stays in Upload
  with its reason, and one that has not reached Immich yet stays there while the system tries again; there is no
  `not-uploaded/` folder. An uploaded file leaves Upload after about 10 seconds, as on Linux. Folders copied into
  Upload are taken as on Linux ("Folders copied into Upload").
- **Signing out,** and **Turn Off Verso Drive**, take the location away with what was downloaded, and forget the
  drive's account and store. A file in Upload that has not reached Immich is kept: the system preserves it, and Finder
  opens the folder it is kept in. Signed out, the switch stays on, so the next sign-in brings the location back. The
  session is Verso's: the drive never ends it.
- **Open in Immich and Copy Immich Link** (Links to Immich) are the File Provider extension's own actions
  (`dev.hviid.Verso.open-in-immich` and `dev.hviid.Verso.copy-link`), which Finder offers on one item with a web
  address (the item's `hasWebLink`). The extension opens the address with `NSWorkspace` or puts it on the pasteboard
  itself, so Verso need not run. Their names are translated through the extension's `Localizable.strings`. There is
  no `web` command on the Mac.
- **Show in other apps:** Finder offers no Show in yet.
- **Dates:** a file has its capture time, as on Linux; a folder the time the location was set up, where on Linux it
  has the mount's.
- **Settings** (Settings, Verso Drive): the switch; the status (the server and whether it answers, Immich's version,
  **Show in Finder**); **Folders**, each section with its date folders, and Upload; and **Names and Uploads**: album
  folders, file names, folders copied into Upload, and Open in Immich and Copy Immich Link. A change is written to
  `config.toml`, and the system lists every item again.
- **The menu bar item:** its icon shows the state, as the top bar icon's does (signed out, the server out of reach,
  the location waiting to be switched on in Finder), in the menu bar's one colour, or in colour with **Show the Menu
  Bar Icon in Color** in Settings, General (off by default; an app setting, not `tray.colour`). Its menu: the state
  ("Connected to *host*", "*host* is not reachable", "Signed in to *host*" while the drive is off, "Signed out"),
  **Open Verso**, then, signed in, **Show Verso Drive in Finder** and **Turn Off Verso Drive**, or **Turn On Verso
  Drive**, then **Settings…** and **Quit Verso**.
- **Updates:** Sparkle, from Verso's page's signed feed, on its own schedule and from **Check for Updates…**, for the
  release run from Applications; a beta's build takes the feed's beta channel too (AGENTS.md, "Versioning").
- **Files on disk:**

  | What | Where |
  |---|---|
  | Settings (`config.toml`), the server's address (`server`) and the certificate trusted for it (`certificate`), the account's email (`account`), the drive's metadata store (`Library/`), the extension's status (`status.json`) | The App Group container, `~/Library/Group Containers/<team>.dev.hviid.Verso/` |
  | Verso's sign-in | The data protection Keychain, kept on this Mac, an item labelled "Verso account", service `dev.hviid.Verso`: the server, the credential and the certificate trusted for the server |
  | The drive's credential | The data protection Keychain, kept on this Mac, service `dev.hviid.Verso`, in the access group the app and its extension share |
  | The system's copy of the location: downloaded originals and what waits in Upload | `~/Library/CloudStorage/`, in a folder macOS names after the app and the location (`VersoDev-Verso` for Verso Dev), kept by macOS |

  Signing out removes the drive's part of them but what waits in Upload. Removing the app runs nothing: sign out, or
  turn Verso Drive off, first, or the location stays in Finder without its app.
- **Verso Dev,** a Debug build (`dev.hviid.Verso.Dev`), has an identity of its own (App Group, Keychain group, URL
  schemes, Finder location), so it runs beside an installed Verso.

## In the Files app (Verso Drive on the iPhone and the iPad)

The same layout, names, attributes and content as in Finder, through the same File Provider extension
(ARCHITECTURE.md, "Verso Drive on the iPhone and the iPad"). Where the Files app's way differs from Finder's:

- **Switching it on:** in the account's sheet, On This iPhone, Verso Drive, off until switched on. On and signed in,
  Verso keeps its account for the extension and adds the location `library`, which the Files app names after the app
  ("Verso", or "Verso Dev"), not `mount.name`. A new location waits to be turned on in the Files app (Browse, the
  location, Turn On); the drive's page says so meanwhile.
- **Off,** the Files app still lists a location named after the app, empty, which says Authentication Required and
  offers to open Verso: iOS keeps an extension's own default location while its app has none.
- **Content:** an original is downloaded when it is opened; iOS may remove what was downloaded to free space, and
  does when the original changes on the server.
- **Uploads:** as in Finder.
- **Signing out,** and turning Verso Drive off, remove the location whole, with what was downloaded and what waits in
  Upload, as iOS keeps nothing of a removed location: Verso counts the files not yet uploaded and asks first. Signed
  out, the switch stays on.
- **Changes reach the Files app** while Verso runs, as in Finder.
- **Not on iOS:** Open in Immich, Copy Immich Link and Show in. An extension without a view of its own can neither
  open a web address nor say that it copied one.
- **Settings** (the account's sheet, Verso Drive): the switch; the status (the server and whether it answers,
  Immich's version, **Show in Files**); **Folders**; and **Names and Uploads**: album folders, file names, folders
  copied into Upload.
- **Files on disk:**

  | What | Where |
  |---|---|
  | Settings (`config.toml`), the server's address (`server`) and the certificate trusted for it (`certificate`), the account's email (`account`), the drive's metadata store (`Library/`), the extension's status (`status.json`) | The App Group container, `group.dev.hviid.Verso` |
  | The drive's credential | The Keychain, kept on this device, service `dev.hviid.Verso`, in the access group the app and its extension share |
  | The system's copy of the location: downloaded originals and what waits in Upload | Kept by iOS |

- **Verso Dev** (`dev.hviid.Verso.Dev`, its extension `dev.hviid.Verso.Dev.Drive`, the App Group
  `group.dev.hviid.Verso.Dev`) lists its location as Verso Dev, beside a release's.

## Backing the iPhone up

Verso on the iPhone and the iPad backs the device's photos up to Immich (ARCHITECTURE.md, "Backing the iPhone up").
Its words name the device as Apple's do: "This iPhone" here reads "This iPad" on an iPad ("Back Up This iPad",
"Keep on This iPad", "Free up 2.3 GB on this iPad"), as do the photos on their way elsewhere (`DeviceWords`).
- **One page for all of it,** the Backup page. Every way in opens it: the Library's card and line, the account's
  sheet (a Backup row saying how it stands: "Off", "Checking with Immich…", "Up to Date"), a notification, a Live
  Activity. Backing up is switched on there (**Turn On Backup**, which asks for the whole photo library and for
  notifications, then starts the check on the same page) and off there (**Turn Off Backup**, at its foot, which asks
  first: "Nothing is deleted, on this iPhone or in Immich"). Its options: Use Cellular for Photos and Use Cellular
  for Videos (off), Only While Charging (off, for backing up on its own), Screenshots (on) and Hidden Photos. They are
  this device's own.
- **The Library's card,** while backing up is off on the account's own server: "Back Up This iPhone" above the tab bar,
  by the newest photos, with **Set Up** (the Backup page) and **Not Now**, which hides it on this device for good.
- **What goes:** the photo library's own photos and videos, every burst frame, each with all its parts (the original, a
  Live Photo's video, RAW+JPEG's second file, an edit's rendering). A slow-motion video goes as Photos stores it, at
  its full frame rate, which Immich plays at normal speed. Hidden photos go into Immich's Locked Folder
  (`visibility: locked`), never the timeline, while **Hidden Photos** is on (the default); iOS shows them to Verso
  only while Use Face ID is off for Photos' hidden album (Settings, Apps, Photos), which the option says. A hidden
  photo is done once Immich holds it: its date and place are the file's, and it is not stacked, as Immich lets nothing
  change a locked asset without the account's PIN. A photo hidden after its upload stays where it is in Immich. Its
  picture never shows in the Library or On Its Way; in the Backup page's lists, a lock stands in for it. Not: Shared
  Albums, photos synced from a computer. Never to Immich's public demo, where the setting says why.
- **The first run** reads the library and checks it with Immich before anything is sent, up to four files at a time (an
  original only in iCloud of a photo never edited, which Immich's own app uploaded, is known by its iCloud identifier
  without a download): the page's top says "1,205 of 3,523 checked", with the bar, and **Start** is under it all along
  (photos found in Immich are never sent, and the check goes on during the run); "In Immich in Another Form" (the same
  time taken and file name, other bytes) waits for the person to send or skip. When the check has done what it can, one
  notification says "Ready to back up" (what goes and its size, what Immich has, and what is checked once it starts); a
  tap opens the Backup page, and its **Start Backup** starts. Later, new photos go on their own, and **Back Up Now**
  runs at once.
- **Each upload:** `deviceAssetId` `<local identifier>/<part>`, `deviceId` `verso-ios`, `fileCreatedAt` and
  `fileModifiedAt` from Photos, `filename` (an edit's rendering keeps the original's name with its own extension),
  `isFavorite`, `visibility=hidden` on a Live Photo's video and `livePhotoVideoId` on its still, the header
  `x-immich-checksum`, and with the still or video of a photo never edited, the `metadata` Immich's own app writes
  (`mobile-app`: its iCloud identifier, when it was taken and where), so that app knows the asset. Afterwards, Immich is
  asked whether it holds each asset Verso made under Verso's fingerprint (a part it does not arrived otherwise than it
  was sent, and its photo needs a look), then stacks (an edit with its original, RAW+JPEG, a burst) and, on the assets
  Verso made, the date and place Photos has where the file says otherwise.
- **The Backup page,** each section one subject, what needs the person first:
  - **Its top:** a symbol, what goes on ("Checking with Immich", "Ready to back up", "Backing up", "Backed up") and
    one line on it ("1,205 of 3,523 checked", "69 items · 403 MB to go", "3,454 of 3,523 in Immich", or what it waits
    for); one bar for the whole library, in the colours of the rows under it; and the action of the moment: Turn On
    Backup, Start, Back Up Now, or Try Now. A stop is said there, with what can be done (below), and so is an error
    that has lasted an hour.
  - **Uploading** (Use Cellular for Photos, Use Cellular for Videos, Only While Charging) and **Included**
    (Screenshots, Hidden Photos, and what is never backed up: Shared Albums, photos synced from a computer): under the
    top until the first run's Start, as what is included changes what goes, and near the foot after it.
  - **On This iPhone,** with the number of items backing up covers: the bar's parts as rows, each with its colour and
    count, opening its photos, with Select for several at once. **In Immich**; **To Upload** (Don't Send), before Start
    and after; what needs the person: **Needs a Look** (each with its reason, Retry and Don't Send), **In Immich in
    Another Form** (Send, Skip), **Missing from Immich** (Send Again, Let Go); **Left Out**, on purpose, nothing of it
    uploaded unless the person says so, a page of its own: **In Immich's Trash** (deleted in Immich and in its trash
    for up to 30 days; restored there, not uploaded again, which would undo the deletion), **Deleted in Immich** (Send
    Again), **You Chose Not to Send** (Send), and the screenshots while Screenshots is off; and **To Check** (Don't
    Send), each photo saying what it waits for and when it is tried again.
  - **On Its Way:** the photos waiting or uploading, newest first, from the phone, each with its mark (a ring filling
    while it uploads, a cloud with an upward arrow while it waits, a clock while the connection holds it back, an
    exclamation mark when it needs a look), a tap opening one from the phone to see or share it, and **Show All** when
    there are more.
  - **Free Up Space,** a row with what is ready to free ("2.3 GB to Free"), opening its page (below).
  - **Checked with Immich:** Sent by Verso, and Last Checked with Immich with **Check Again**.
  - **What it waits for,** said calmly, as Verso goes on by itself: "Waiting for Wi-Fi", "Waiting for a connection",
    "Paused for Low Data Mode", "1 waits, trying again at 11:35" ("3 still to check, …"), "Waiting for Immich" (also
    after five uploads in a row failed, with when it tries again, and Try Now), "Needs 1.2 GB free on this iPhone".
  - **The stops,** which only the person can put right, said in the top with their actions: sign in again; "Immich
    doesn't let Verso upload", with Immich's reason and Try Now; "Your Immich server is full", tried daily, and Try
    Now; most of the library gone, with Check Again, Send Them Again and Let Them Go.
- **Needs a Look** is for what Verso could not do by itself: a file Immich refused (with its reason), a part that could
  not be read for three days (five tries at least), an upload that arrived otherwise than it was sent. A read that fails
  is tried again quietly until then, the photo still to check.
- **The line under the Library's title,** while no import shows: "Reading Your Library…", "Checking with Immich…",
  "Ready to Back Up", "Backing Up 3 Items…" ("Backing Up 1 Item…") beside a small cloud, "Waiting for Wi-Fi", "Waiting
  for a Connection", "Paused for Low Data Mode", "Waiting for Immich", "Waiting to Try Again", "Needs Free Space", "3
  Need a Look" ("1 Needs a Look"), "Backup Stopped", "Immich Is Full", "Backup Needs Sign-In", "Backup Not Allowed",
  "Backup Needs All Photos". A tap opens the Backup page.
- **Live Activities:** a run the person starts (Turn On Backup's check, Start, Back Up Now) shows with the system's own
  progress and its Stop, and ends as done once nothing more can be done now, saying what waits ("1 waits, trying again
  at 11:35"); Back Up Now is there again whenever it ends. Backing up on its own has Verso's: for the first run's check,
  and for a run of 5 or more items, started while Verso is open and kept up to date from the background, on the Lock
  Screen (Verso's lens in a ring that fills as the run goes, "Backing up to Immich", "34 to go · 210 MB") and in the
  Dynamic Island (the lens in its ring, and "34/69"). It says what it waits for, and ends with how the run ended
  ("Backed up 69 items", "Ready to back up", "3 need a look"), left on the Lock Screen for 15 minutes. Never beside the
  system's; a tap opens the Backup page (`verso://backup`, Verso Dev's `verso-dev://backup`). A run iOS starts while
  Verso is closed has none, as iOS lets an app start one only while it is open.
- **The Library's new photos:** photos that came to the phone after backing up was switched on for the account (or after
  the first run's Start), and are not in Immich yet, show in the Library's All Items among Immich's photos by when they
  were taken (at its newest end when it is in Date Added's order), from the phone and with their mark; not under a
  filter, nor in Years or Months. When its upload lands, Immich's photo takes the tile's place. While on its way, a
  photo opens in a viewer of its own from the phone, shares the phone's copy, is favourited in Photos (carried with the
  upload as `isFavorite`, or set on Immich's asset afterwards), and is deleted from the phone, which iOS asks about,
  after which it never uploads; Add to Album, Archive and Rating wait, saying "On its way". In a selection it is shared
  and deleted with the rest, and Immich's actions leave it out and say so.
- **Free Up Space:** a page of its own, from its row on the Backup page: **Keep on This iPhone** (Forever, the default; 1
  Month, 3 Months, 6 Months, 1 Year, 2 Years), which asks the first time what deleting means with iCloud Photos and a
  Shared Library, and says what Always Keep keeps; **Review and Free Up 2.3 GB** ("412 items older than 6 months, safe
  in Immich"); **Always Keep** with what it keeps ("Favorites, 2 Albums"): Favorites (on; the favourites as Photos has
  them), Hidden (off; on and dimmed while Hidden Photos is off, as they are not backed up then) and Albums (the albums
  on this iPhone, ticked).
  - **Hidden photos in the review** are a group of their own above the months: their count and size, "safe in Immich's
  Locked Folder", staying until checked. **Enter PIN** (and **Use Face ID** where the PIN is kept behind Face ID,
  as the Locked Folder keeps it) unlocks the session with the account's Locked Folder PIN, and each is checked as the others; **Show** (Face
  ID or the passcode) shows their pictures; Keep All or Free All. With an API key's sign-in, which has no session to
  unlock, they stay, and the group says why. The session is locked again as the review closes.
  - **The review:** the photos by month, newest first, all ticked, each month with Keep All or Free All; above them what
  Always Keep keeps ("Favorites and photos in 2 albums stay.") with Change, after which the photos are read and checked
  again; each checked with Immich as it opens ("Checking each with Immich: 120 of 412"); those that fail stay, listed
  under Staying on This iPhone with why; a cloud on those stored only in iCloud. **Delete 400 items from This iPhone ·
  2.1 GB** asks again where some are only in iCloud, checks once more, and iOS asks; Don't Allow changes nothing.
  Afterwards: "Moved 400 items to Recently Deleted", to empty it in Photos to get the space now, with Open Photos.
  - **The Library's card,** above the tab bar where the offer to back up shows, never while selecting: "2.3 GB Ready to
  Free Up" ("412 items older than 6 months, safe in Immich.") with Not Now and Review, which opens the review itself,
  once a gigabyte or more is ready; after either, again a month later, or sooner once another gigabyte is ready. While
  Keep on This iPhone is Forever and the phone runs short of space (under 5 GB free, or under a tenth of it): "iPhone
  Storage Almost Full" ("8.3 GB of photos and videos older than a year are safe in Immich.") with Not Now and Free Up
  Space, which opens Free Up Space's page, where the same is said, to choose a period; after either, again in three
  months. Verso never chooses a period itself.
  - **The Library's line** at its newest end, while backing up is up to date: "3,525 Items · Backed Up", or "· 2.3 GB to
  Free" in the tint with a period chosen and photos to free; a tap opens the Backup page, or the review where there is
  something to free.
  - **Notifications:** "Free up 2.3 GB on this iPhone", at most once a month and only with a gigabyte or more to gain,
  which opens the review; "3 photos you freed are not in Immich", once, while Recently Deleted can still bring them
  back.
- **New photos first:** when Verso comes to the foreground, and when the library changes while it is open, the new
  photos are checked and sent at once, before any backlog, through the app's own connection while Verso is open.
- **Notifications,** each also in the account's notifications, and each opening the Backup page: the first run's check
  is ready for Start (once, with Start Backup); a run the person started has ended; photos are missing
  from Immich (once for each batch found); most of the library is gone; Immich is full (once); sign in again; Immich
  doesn't let Verso upload (a 403, once, with its reason); backing up paused, for a run the person started, when five
  uploads in a row failed with none landing (Immich down or out of reach), with when Verso tries again: 15 minutes,
  doubling up to 4 hours, or sooner when the connection changes.
- **Signing out** leaves backing up on for when the same account signs in again, and calls back the uploads on their
  way, which go again then; another account starts with it off.
- **Files on disk:** the store, `Backup/backup.sqlite` in the App Group container; upload bodies in `Application
  Support/Backup/Uploads` and iCloud downloads in `Application Support/Backup/Downloads`, removed once sent, within at
  most 2 GB or a tenth of the free space, always leaving 1 GB free; a single file larger than that goes alone, with
  nothing else held and 1 GB still free. `Application Support/Backup` is excluded from the device's own backup. The
  background session is `<bundle>.backup.uploads`,
  and the background tasks `<bundle>.backup.now.<UUID>`, `<bundle>.backup.overnight` and `<bundle>.backup.refresh`.

## Sharing from the iPhone

**Share** (the selection's bar, a photo's long press, the viewer) opens the system's share sheet at once, headed with
how many photos and videos and the first one's picture:
- **To an app** (Messages, Mail, AirDrop, Save to Files, Save Image or Save Video, other apps): each original as it
  was taken, under its own name, downloaded only when the app asks for it. Photos on their way to Immich go from the
  phone, as Photos shows them. The selection ends when the sheet closes.
- **Create Link…**: an Immich link to these photos, with the link form's password, expiry, description and what
  visitors may do; once made, its address in a share sheet to send or copy, and on screen with Copy Link, Share Link
  and Done.
- **Add to Link…**: the account's links to chosen photos (not album links); the photos join the one picked, and its
  address follows as after Create Link….
- The two link actions download nothing. They show for the account's own photos, where the server has shared links,
  and not in the Locked Folder or Recently Deleted.

## On the iPad

Verso on the iPad is the iPhone's app, laid out for the room (ARCHITECTURE.md, "Verso on the iPad"), with a hardware
keyboard, a pointer, drag and drop and several windows.
- **The keyboard.** iPadOS's menu bar, and the list that holding ⌘ shows, have Verso's commands, with the Mac's keys
  where the Mac has the same command:

  | Where | Key | What it does |
  |---|---|---|
  | Anywhere | ⌘, | Settings…: the account's sheet |
  | | ⌘F | Find: Search, its field ready to type in |
  | | ⌘1, ⌘2, ⌘3 | The Library in Years, Months or All |
  | | ⌥⌘N | New Album… |
  | | ⇧⌘I | Import from Files… (Import from Photos… is in File, without a key) |
  | Selecting | ⌘A | Select All |
  | | . | Favorite, or Unfavorite where every photo selected is one |
  | | ⌘⌫ | Delete, asking first as the bar's Delete does |
  | | Esc | Cancel: the selection ends |
  | A photo open | ← → | The photo to the left or right, as a swipe brings it |
  | | Space | Play or pause a video; play a Live Photo whole |
  | | . | Favorite or Unfavorite |
  | | ⌘I | Show or hide the details |
  | | ⌘⌫ | Delete (Delete Permanently in Recently Deleted), asking first |
  | | Esc | Close the photo, back into its tile |

  A field being typed in (Search, a caption) keeps its own keys. A sheet over a page or a photo has the keyboard while
  it shows. iPadOS's text styles (Bold, Italic, Underline) are not in the menu bar: Verso has no styled text.
- **The pointer:** cards (albums, people, memories, places, links, years) lift under it, Collections' rows and
  headers light up, and the system's buttons, menus and tabs answer it as everywhere in iPadOS.
- **Dragging a photo out** of any grid into another app (Files, Mail, Notes, another photo app) gives it the photo's
  original, under its own name and in its own format, downloaded once the app takes it, as dragging out of the Mac's
  grid does. One photo goes with each drag.
- **Dropping photos and videos in** from another app (Photos, Files) imports them as Import from Photos… does: on the
  Library into the library, on an album's page into the library and that album, where the account may add to it
  (an album it may only view takes no drop). A Live Photo arrives as its photo and its video, which Immich pairs.
  Photos dragged within Verso are in Immich already, and no page takes them.
- **Several windows:** each window has its own tabs, pages, selection and viewer over the one account, as each of the
  Mac's windows has. The Backup page opens in the window in front, whichever way it is asked for.

## Sharing from the Mac

**Share** (the toolbar's ↑, for the photos selected or the one open; Share in a photo's right-click menu) opens the
system's share picker at once, at the button or at the pointer, headed with how many photos and videos and the first
one's picture:
- **To a service** (Mail, Messages, AirDrop, Notes, other apps' extensions): each original as it was taken, under its
  own name, downloaded only when the service asks for it, and removed once the service says it is done.
- **Create Link…**: the link sheet for these photos, with its description, password, expiry and what visitors may do;
  once made, its address with Copy Link, Share and Done.
- **Add to Link…**: the account's links to chosen photos (not album links); the photos join the one picked, and its
  address follows as after Create Link….
- The two link actions download nothing. They show for the account's own photos, where the server has shared links,
  and not in Recently Deleted; a partner's photos are shared to services alone, and the Locked Folder has no Share.

## Verso in Messages

Verso on the iPhone and the iPad is in Messages' list of apps (the + beside the message field; ARCHITECTURE.md, "Verso
in Messages").
- **Compact:** Recents, the newest photos of the timeline (partners' too where the timeline shows them), with Albums and
  Search.
- **Expanded:** Recents, Favorites and Albums under a segmented control, and Search Your Library (by meaning where the
  server has smart search, else by file name); an album opens its photos, newest first. Photos only: videos, the Locked
  Folder and the trash are left out.
- **A tap** puts Immich's preview of the photo (about 1440 pixels, as JPEG, HEIC or PNG; WebP becomes JPEG), named after
  the original, into the message field, or the original with its metadata, such as where it was taken, while
  **Original** is on at the picker's top (kept for the next time); the expanded picker then gives way to the compact
  one, so the field shows. Messages gives an app one item in the field, so the next tap's photo takes the place of the
  one before. Several photos go to Messages together from Verso itself: selected in a grid, Share, Messages. Nothing
  goes until the person sends.
- **No sign-in of its own:** it uses Verso's account, read again each time Messages opens it. Signed out, or refused by
  the server, it says so, with **Open Verso**.

## The app icon on the Mac, the iPhone and the iPad

The Apple apps offer the app icon's seven designs as Linux does, each on Day or Night paper with its lens in colour or
in graphite (DESIGN.md, "The picture's designs"), each design by its icon and its name, Mist first. By default the icon
is Mist in colour, the app icon itself, Day as its light appearance and Night as its dark one, which the Mac shows in
dark mode and the iPhone where the Home Screen's icons are dark. Verso Dev offers the same looks in its own drawings,
with the blue DEV corner, so it stays told apart from a release whatever is chosen. `app.icon` and `app.icon_dark` are
Linux's alone: neither app keeps the choice in `config.toml`.
- **iPhone and iPad:** **App Icon** under On This iPhone (On This iPad) in the account's sheet, showing the design and
  lens in use ("Sand", "Sand, Graphite"), opens Color and Graphite as a segmented control above the seven in a grid,
  four to a row, with a tick under the one in use; each picture is the icon, its Night look while the app is in dark
  mode. A tap on a design, or on the other lens, makes it the app's icon on the Home Screen, in Spotlight and
  in Settings (an alternate icon; Mist in color is the app icon itself), and iOS says so in a notice of its own ("You
  have changed the icon for “Verso”."). Under the grid: "Verso's icon on the Home Screen, in Spotlight and in Settings.
  Where the Home Screen's icons are dark, it shows its night version, on dark paper." Each icon is its design's Day
  look and, as its dark appearance, its Night look, which the Home Screen shows where its icons are set to Dark (its
  Customize menu: Dark, always or in dark mode; with Default every icon stays light); the tinted and clear looks are
  iOS's own. iOS keeps the choice,
  across launches and updates; Verso keeps no setting of its own for it, and the app installed again starts at Mist.
  The picture of the icon on the sign-in page and in About Verso is the design and lens in use. The row is left out
  where iOS offers no alternate icons.
- **Mac:** **App Icon** in Settings, General: a row for Light Mode and one for Dark Mode, each the seven designs side
  by side in that row's paper and lens, the chosen one ringed in the accent colour, and under them two small segmented
  controls, Day or Night and Color or Graphite; any of the 28 looks in either mode. Under the rows: "The Dock and the
  app switcher show them while Verso runs, as the Mac is in light or dark mode. Finder and Launchpad keep Mist." The
  look of the system's appearance is Verso's icon in the Dock and the app switcher while Verso runs, set as it starts,
  at once when chosen, and again when the appearance changes, and the picture of its icon in the About window, the
  sign-in window and the heading of Verso's own notifications. Finder, Launchpad, System Settings and the Dock while
  Verso is not running show the bundle's own icon: Mist, Day in light mode and, from macOS 26, Night in dark mode. The
  choices are user defaults of the app's, `appIcon.light` and `appIcon.dark`, each a look as Linux names it (`mist`,
  `sand-night`, `sky-night-graphite`; unset, `mist` and `mist-night`), as Show the Menu Bar Icon in Color is.

## Errors seen by programs using the mount

| Condition | Error code | Service behaviour |
|---|---|---|
| Server unreachable | Cached answer if any (a folder visited before lists as it was, after a restart too, and also when the server stops answering mid-request), otherwise `EIO` at once | State `offline` and one notification; requests fail fast until the next change poll succeeds |
| The server's certificate not trusted, or not the one trusted for it | As when the server is unreachable | State `offline` and one notification, "Immich's certificate is not trusted"; nothing is sent until the certificate is trusted in Verso or with `login` |
| Signed out (401) | `EACCES` | State `signed-out`; one notification |
| Missing permission (403) | `EACCES` | `status` and `doctor` name the missing permission |
| Asset gone (404, or 400 `Not found`) | A read fails with `EIO` (the kernel reports any failed page read so, though the service answers `ENOENT`); looking it up again fails with `ENOENT` | The folder it was read from is listed again on its next visit, without it |
| Server busy (408, 429, 5xx) | Retried within the deadline, then the cached listing if any, else `EIO` | Backs off, honouring `Retry-After` |
| Size mismatch, or a range past the end | `EIO` for that read | The folder it was read from is listed again on its next visit, with the new size |

## The non-affiliation notice

Shown in the README, the About window on Linux and the Mac and About Verso on the iPhone and the iPad, the first
screen of the iPhone's and the iPad's sign-in, the AppStream metadata and every package description:

> Verso is an independent, unofficial project. It is not affiliated with, endorsed by, or sponsored by the Immich
> project or FUTO. "Immich" is used only to describe the server this software works with, and remains the mark of
> its owner.
