# WORKFLOWS

What you run. [SPEC.md](SPEC.md) is the contract behind each step, and [ARCHITECTURE.md](ARCHITECTURE.md) explains why
it works this way. Where a step is not built yet, it says so.

## 1. Install

Verso is one app with two programs, installed together: **Verso** (`verso`), the window you open from the app grid,
and its service (`verso-service`), which runs the top bar icon and Verso Drive from login, and is the command line.
Verso runs on x86_64 Linux with GTK 4.18 and libadwaita 1.8 or later (Fedora 44 or similar), made for GNOME.

**With Homebrew** (any Linux that has it, such as Bazzite; nothing is layered onto an atomic system):

```sh
brew install jakobhviid/tap/verso
```

Then open **Verso** from the app grid and sign in (section 2): signing in sets up the service, with nothing to start
by hand. Verso Drive needs FUSE 3 (`fuse3`, from your distribution), Verso's menu in Files needs nautilus-python, and
the top bar icon needs a tray: on GNOME, the AppIndicator extension.

**Upgrades:** `brew upgrade verso`. Once nothing on the drive is open or uploading, the service restarts into the new
version by itself, within seconds; the drive is gone for a moment then, so a Files window showing it may leave it.
An open Verso window closes and the new version opens on the page it showed, once any import has finished.
**Uninstalling:** `brew uninstall verso`, with `--zap` to remove the settings and caches too. About two and a half
minutes after the program is gone, the service unmounts the drive and turns itself off, and an open window closes.

**As a Flatpak** (a test build): download `verso-x86_64.flatpak` from the release, then:

```sh
flatpak install --user verso-x86_64.flatpak
flatpak run dev.hviid.Verso
```

It fetches the GNOME runtime from Flathub. The Flatpak is Verso without what needs access outside its sandbox: no
Verso Drive (Preferences points to the Homebrew version, which has it), one **Show in Another App…** in place of an
item per app, no taking over Immich Mount's account, and your desktop asks the first time you sign in whether Verso
may start at login.

**From source**, on Fedora 44 or in a Fedora 44 toolbox, with `gcc`, `cargo`, `rust`, `gtk4-devel`,
`libadwaita-devel`, `libshumate-devel`, `blueprint-compiler` and `fuse3`:

```sh
cargo build --release -p verso -p verso-service
target/release/verso
```

The window finds `verso-service` beside itself, and writes the user service for it as you sign in. Single sign-on in
the browser hands back to Verso through its desktop entry, which registers the `app.immich` scheme:

```sh
sed "s|@BINDIR@|$PWD/target/release|" linux/packaging/desktop/dev.hviid.Verso.desktop.in \
  > ~/.local/share/applications/dev.hviid.Verso.desktop
update-desktop-database ~/.local/share/applications
```

`linux/packaging/verso-tarball.sh out` builds what the release tarball holds into `out/verso`: both programs, the
icons, the desktop entry, Verso's menu in Files (`verso-nautilus.py`) and the third-party licenses. A debug build
decodes pictures slowly; `cargo build -p verso --config 'profile.dev.package."*".opt-level=2'` optimises the
dependencies only.

**Coming:** rpm and deb packages of Verso's own.

**On the Mac** (macOS 15 or later), Verso has no release yet: it is built from source with Xcode (AGENTS.md,
"Development environment").

## 2. Sign in

**In Verso:** open **Verso** from the app grid.
1. Enter the **Server Address**, then **Continue**.
2. Choose a sign-in method:
   - **The server's single sign-on button** opens your browser. Sign in there as usual, with your passkey or
     password manager, and the browser hands you back to Verso.
   - **Email and Password**, if the server allows it.
   - **Use an API Key Instead.**

You sign in once; the credential is kept in your keyring across reboots. Signing in starts Verso's service, with its
top bar icon, and has it start at every login. Verso Drive stays off until you switch it on (section 3).

**Where Immich Mount is signed in** on this computer, the first page offers **Use Immich Mount's Account**: Verso
signs in to the same server with a sign-in of its own, takes Immich Mount's settings but the drive's place and name,
and switches Verso Drive on at `~/Verso`. Immich Mount is left as it is; signing out of one leaves the other signed
in. The Flatpak does not offer it.

**Headless, or from a terminal:**

```sh
verso-service login --server https://photos.example.org                # OIDC: prints a URL, then asks for the final URL
verso-service login --server https://photos.example.org --password     # prompts for email and password
printf '%s' "$KEY" | verso-service login --server https://photos.example.org --api-key   # key from stdin
```

Without a terminal, `login` never prompts. Browser sign-in still prints the address to open on stderr, and reads
the address the browser ends on from stdin; the other methods read their secrets from stdin. For Verso Drive, an API
key needs `album.read`, `asset.read`, `asset.view`, `asset.download` and `person.read`, plus `asset.upload` for
uploads, `album.create` and `albumAsset.create` for albums of folders copied into Upload, `asset.delete` to restore a
photo copied in while it is in Immich's trash, and `user.read` for Verso and `status` to name the account. In Verso's
window, a key's permissions limit what you can change.

## 3. Verso Drive

- **Switch it on** in Verso's Preferences, under Verso Drive, Status, with the **Verso Drive** switch, or from a
  terminal:

  ```sh
  verso-service configure set mount.enabled true
  verso-service mount
  ```

- It appears at `~/Verso` and in Files' sidebar as **Verso**, with an unmount button. Preferences, Drive, has its
  location and its name ("Verso", "Verso Drive" or "Immich"), and **Bookmark Instead of Drive**, which lists it as a
  bookmark, without the unmount button.
- **On Fedora's atomic desktops and Bazzite** (a home reached through the `/home` symlink, `$HOME` being
  `/home/you` while the folder is `/var/home/you`), Files lists no mount in the home folder by itself, ours or any
  other. The service sets GVfs up as it mounts, so it is a drive with an unmount button there too; the setting is a
  drop-in for GVfs's volume monitor (SPEC.md, "Files on disk"), and `logout` removes it.
- While it is on, it mounts at every login, with the service.
- **Unmount** on the Status page, **Unmount Verso Drive** in the top bar menu, Files' unmount button, or
  `verso-service unmount` takes it out until the next login, or until **Mount** on the Status page, **Mount Verso
  Drive** in the top bar menu, or `verso-service mount`. The switch stays on, and so does the top bar icon. A Files
  window showing the drive does not stop it; the window keeps what it showed until it is refreshed (F5). A copy into
  Upload still uploading does: unmount when it is done.
- **Switching it off** takes it out of Files, with its bookmark and its empty folder.

Browse it like any folder: Photos by year and month (busy months by day), Albums (`2023 - Summer trip`),
People and Places. Files are named by when they were taken (`2024-03-15 14.32.07.jpg`). Thumbnails come from the
server, and an original is downloaded only when something opens it.

Your favorites are in **Favorites**, and what you archived in **Archive**, by year and month, once you switch them
on: in Preferences, Verso Drive, Folders, or `verso-service configure set sections.favorites true` (and
`sections.archive`). They follow Immich within seconds: a photo you mark or archive there appears, and leaves when
you unmark or unarchive it. Favorites holds archived favorites too, as Immich's Favorites page does.

**Open in Immich** and **Copy Immich Link** take a photo, album, person or place from the drive, or from Verso's
window, to its page in Immich's web app (SPEC.md, "Links to Immich"). A photo opens where you found it: in its album,
person or city, or in the timeline from Photos. From a terminal:

```sh
verso-service web ~/Verso/Albums/2023\ -\ Summer\ trip            # opens the album in the browser
verso-service web --copy ~/Verso/People/Alice/2024-03-15\ 14.32.07.jpg   # puts its address on the clipboard
verso-service web --json ~/Verso/Places/Denmark/Aarhus
```

```json
{
  "path": "/home/you/Verso/Places/Denmark/Aarhus",
  "url": "https://photos.example.org/search?query=%7B%22city%22%3A%22Aarhus%22%2C%22country%22%3A%22Denmark%22%7D"
}
```

Photos' year, month and day folders, the year folders above albums, and Upload have no page in Immich, so they
have no link; `web` says so and exits non-zero, as it does for a path outside the drive or when the drive is not
mounted.

**From other apps:** Verso takes part in [Immich Crosslink](https://jakob.hviid.phd/immich-crosslink/) twice. An Immich
app that takes part can show a photo, album, person or place in **Verso Gallery**, which opens it in Verso's window,
or in **Verso Drive**, which opens Files on it, selected, while the drive is on. When Verso Drive cannot show it
(another server, something the drive does not show), a notification says why. Preferences, Crosslink, has the
**Immich Crosslink** switch and one each for Verso Gallery and Verso Drive; Verso's menus, and its menu in Files, offer
**Show in** for the other apps that take part. From a terminal, for a crosslink or an address of Immich's web app:

```sh
verso 'immich-crosslink:///albums/0f8c2b4a-7d6e-4f1a-8b9c-3e2d1a0b9c8d?server=https%3A%2F%2Fphotos.example.org'   # in Verso's window
verso-service show 'https://photos.example.org/albums/0f8c2b4a-7d6e-4f1a-8b9c-3e2d1a0b9c8d'                          # in Files
verso-service show --json 'immich-crosslink:///people/5b7d9f1e-3a2c-4e6b-8d0f-1c3e5a7b9d2f?server=https%3A%2F%2Fphotos.example.org'
```

```json
{
  "link": "immich-crosslink:///people/5b7d9f1e-3a2c-4e6b-8d0f-1c3e5a7b9d2f?server=https%3A%2F%2Fphotos.example.org",
  "result": "show",
  "path": "/home/you/Verso/People/Alice",
  "message": null
}
```

`result` is `show`, or why not: `invalid`, `cannot-show`, `other-server`, `other-user`, `not-found`, `off`,
`no-drive` or `unreachable`, with `message` saying it in a sentence.

**On the Mac,** Verso Drive is a location in Finder's sidebar. Switch it on in Settings, Verso Drive, or with **Turn
On Verso Drive** in the menu bar item's menu, then click **Enable** at the top of its Finder window (or switch it on in
System Settings, General, Login Items & Extensions, File Providers). Finder offers **Open in Immich** and **Copy
Immich Link** on its items.

## 4. Status

**At a glance:** while you are signed in, Verso's icon sits in GNOME's top bar, where the AppIndicator extension is on
(Ubuntu and Bazzite have it). The icon changes while the server cannot
be reached, while you are signed out, and while the drive is on but unmounted. A click shows the menu: whether it is
connected, to which server and as whom, **Try Again Now** while the server cannot be reached, then **Open Verso**,
**Open in Files** and **Unmount Verso Drive** (or **Mount Verso Drive**), **Preferences…**, then **Sign Out…** and
**Quit Verso**, which closes Verso and stops its service until the next login or until you open Verso. A double click
opens Verso, or what Preferences, General, **Double-Click Opens** chooses. On the Mac the menu bar item has its own
menu. Without a tray, Preferences, Verso Drive, Status says the same.

```sh
verso-service status
verso-service status --json
```

```json
{
  "state": "online",
  "detail": null,
  "server": { "url": "https://photos.example.org", "version": "3.3.5" },
  "account": { "email": "me@example.org", "credential": "session" },
  "change_feed": "sync-stream",
  "mount": { "path": "/home/me/Verso", "mounted": true, "stale": false },
  "cache": { "used_bytes": 734003200, "limit_bytes": 10737418240 },
  "fetched": { "bytes": 160172, "requests": 9 }
}
```

`fetched` is what the running service has fetched of originals since the drive was mounted (absent when no service
answers): what browsing has cost the network. Opening a folder costs a few range requests per file; opening a file
fetches it.

`state` is one of `unconfigured`, `online`, `offline`, `signed-out`, `missing-permission` or `unmounted` (signed in,
with the drive off or not mounted); `detail` says why when it is not `online`.
`change_feed` is `sync-stream` (signed in with a session) or `polling` (an API key); either way, changes show
within about 10 seconds. `account.email` appears only when the credential may read it.

## 5. Doctor

`verso-service doctor` is a read-only health check. It changes nothing. Each check reports `ok`, `warning`,
`problem` or `skipped`, with what to do:

| Check | Looks for |
|---|---|
| FUSE | `/dev/fuse` is accessible, and `fusermount3` exists and is setuid |
| Kernel timeout | `fs.fuse.default_request_timeout` is off (otherwise long uploads could abort the mount) |
| Mount | Mounted where configured; no stale mount ("Transport endpoint is not connected"). With the drive off, it warns that nothing is mounted |
| Location | The mount point is under `$HOME` and not hidden (otherwise it will not show in the sidebar), and that Files lists it: by itself, or as a bookmark where home is reached through a symlink |
| Thumbnails | `$HOME/.cache/thumbnails` is writable |
| Server | Answers, and which Immich version it runs |
| Credential | Found (in the keyring or the credential file) and accepted by the server, with the permissions the drive needs. A locked or missing keyring shows here |

The loop for scripts: act, run `verso-service doctor --json`, decide from the counts, act again.

## 6. Settings

```sh
verso-service configure list                       # every setting and its effective value
verso-service configure set albums.layout year-folders     # Albums/2023/Summer trip/
verso-service configure set files.naming original          # IMG_1234.JPG instead of the date and time
verso-service configure set cache.limit 25GB
verso-service configure set app.icon sand          # the app icon with Sand's picture, in the app grid and the dash
verso-service configure unset thumbnails.sharp      # back to the default
```

Verso's Preferences (Ctrl+, in Verso, or **Preferences…** in the top bar menu) edit the same settings, on the pages in
its sidebar: **Account**, **General** (the app icon, Open in Immich and Copy Immich Link, the top bar icon's double
click and colour), **Crosslink**, **Features** (your account's Immich preferences), then under **Verso Drive**: **Status** (the
switch, Mount, Unmount and Open in Files), **Drive** (location, name, bookmark instead of drive, cache size, sharp
thumbnails) and **Folders** (each section with its date folders, Upload, album and file names); and for a server's
admins, **Administration**. A change to the drive's settings reaches it when you leave the page or close Preferences.
The keys are listed in SPEC.md; `thumbnails.safety_net` is set here only. On the Mac, Settings has a Verso Drive pane
with the drive's switch, its sections and its names.

**Updates.** Homebrew updates Verso with `brew upgrade verso`, and Flatpak updates the Flatpak. Verso does not look for
new versions itself.

**Language.** Verso Drive's settings pages, the top bar icon's menu, the notifications and Verso's menu in Files
follow the desktop's language (`LANGUAGE`, then `LC_ALL`, `LC_MESSAGES` and `LANG`, as every gettext program does),
in English or one of 20 other languages; the rest of Verso's window and the command line are in English. To see Verso
in another language once: `LANGUAGE=da verso`. The folders in the drive keep their English names.

## 7. Uploading

- Copy or move photos and videos into **Upload**, at the top of the drive, in Files. Each file uploads unchanged,
  leaves Upload a few seconds later, and appears in Photos under its own date. Every other folder is a read-only view
  of your library, built from its dates, albums, people and places: nothing is pasted there.
- **A move never loses a photo.** In Files, the source is deleted only after the server has the file: if an upload
  fails, Files reports an error and the source stays where it was. A program that deletes the source even then still
  loses nothing: any file that could not be uploaded is kept in `~/.local/share/verso/not-uploaded/`, and the
  notification says so.
- **Already in library:** a file whose content already exists counts as done, adds nothing, and a notification says
  so (a photo copied from the drive itself, say). A file matching something in the Immich trash is restored from
  the trash, as it was (the API key needs `asset.delete`; without it the file is refused).
- Non-media files are refused, with a notification explaining why; hidden folders (a thumbnail cache) are refused
  too.
- **Folders** go in whole: copy a folder (with folders inside it, if you like) into Upload, and every photo and video
  in it uploads as it arrives. Once the copy has finished, Verso asks whether to make albums of it too, in a
  notification that stays on screen:
  **Make Albums** gives each folder that holds photos an album named by its path (`Trip`, `Trip › Day 1`), dated if
  the name is taken (`Trip - 2026-11-09`); **Timeline Only**, or dismissing it, makes none. Files stops at a file
  Immich does not take and asks: choose **Skip All** to go on with the photos. The folders leave Upload soon after
  their photos. To decide once for all copies:

  ```sh
  verso-service configure set uploads.folders albums      # always make the albums; `timeline` never; `ask` asks
  ```

  Preferences have it on the Folders page, with Upload, and the Mac's Settings in its Verso Drive pane. Making albums
  needs an API key with `album.read`, `album.create` and `albumAsset.create`; without them a notification says so, and
  the photos stay in the timeline. On the Mac, Verso does not ask yet: choose `albums` there to have the albums made.
  Timeline Only changes nothing more: the photos are already in Immich (delete one there if it was a mistake). Changed
  your mind? Copy the folder in again: Immich recognises its photos, so nothing is sent twice, and you are asked again.
- **Cancelling a copy** keeps the part already copied out of Immich: each file's own structure shows whether it
  arrived whole. MTS and M2TS videos cannot tell, so a cut-short one does upload; delete it in Immich. Empty files
  and macOS's `._` companion files are never uploaded.

## 8. Troubleshooting

| Symptom | What to do |
|---|---|
| The keyring prompt appeared at login | Unlock it. If it was dismissed, Verso's service did not start (a notification says so): open Verso, or run `systemctl --user start verso` |
| "Signed out of Immich" notification | Open Verso (the top bar menu's **Sign In…**) and sign in again. Caches are kept |
| The top bar icon does not show | Stock GNOME has no tray: turn on the AppIndicator extension. Verso and its drive work without it; Preferences, Verso Drive, Status shows the drive's state |
| An app under Apps That Take Part is not wanted, or reads Not found | Switch it off in Preferences, Crosslink, to leave it out of Show in; an installed app stays listed while it is installed. One that reads **Not found** (removed, moved, or its program gone) has **Forget**, which removes it now; otherwise it goes by itself after 30 days |
| A change made in Immich does not show in an open folder | The drive has it within about 10 seconds, but Files does not redraw an open folder on its own: press F5, or open the folder again |
| Files shows generic icons in a folder opened while the server was unreachable | Once it is reachable again, close Files and open it again: Files remembers the failed thumbnails until then, F5 included |
| Files shows generic icons for some photos | They were search results from folders never opened. Open the folder once |
| The drive is not in Files' sidebar | `verso-service doctor` says why. On an atomic desktop (`$HOME` reached through the `/home` symlink) the service sets GVfs up as it mounts: run `verso-service unmount`, then `verso-service mount`. **Bookmark Instead of Drive** (Preferences, Verso Drive, Drive) lists it as a bookmark instead |
| "Transport endpoint is not connected" | The service died. `verso-service doctor` confirms it; `systemctl --user restart verso` cleans up and remounts |
| A large upload fails with "This computer lets a file operation take at most N seconds" | The system sets `fs.fuse.default_request_timeout`; the drive stops each upload just before that limit so as not to be aborted. Set it to 0 (`sudo sysctl fs.fuse.default_request_timeout=0`) for longer uploads |
| Opening a folder on Bazzite downloads a little of each file (about 80 KB), once | Bazzite's file managers load rom-properties, which reads the start and end of every file they show. The drive fetches each file's start and end ahead of it, a few at a time, and keeps them in the content cache, so the folder costs nothing the next time. Files has no setting to stop it, and rom-properties after 2.9 skips the drive by itself |
| A backup tool wants to copy `~/Verso` | Exclude it: Déjà Dup "Folders to ignore"; restic and borg `--exclude ~/Verso`, or `--one-file-system` |

Logs: `journalctl --user -u verso`. A folder that took longer than a second to open is logged with what took the time
(`… opened in 2300 ms: 450 entries listed in 1900 ms, 900 thumbnail paths seeded in 400 ms`); with
`VERSO_LOG=debug` (`systemctl --user set-environment VERSO_LOG=debug`, then restart the service) every
folder is.

## 9. Sign out and uninstall

- **Sign Out** in Verso's Preferences, on the Account page (the top bar menu's **Sign Out…** opens it, asking first),
  signs Verso and its drive out together, as `verso-service logout` does. It removes:
  - the credential (from the keyring, or the file)
  - the session on the server, so the device leaves Immich's "Authorized devices"
  - the metadata store, the content cache, and Verso's pictures (thumbnails, previews, played videos and opened
    originals)
  - every thumbnail the service seeded
  - the GVfs drop-in and the volume monitor's fstab copy, the drive's bookmark in Files' sidebar where it has one, and
    Verso's entries for Immich Crosslink

  It also turns the user service off, which would otherwise fail at every login without a credential. Signing in
  again in Verso turns it on; after `verso-service login`, opening Verso does, and so does `verso-service mount` while
  the drive is on.
- Settings are kept, and so are files that could not be uploaded (`~/.local/share/verso/not-uploaded/`). Files you
  saved from Verso to a folder of your own stay.
- After that, remove Verso as you installed it: `brew uninstall verso` (`--zap` also removes the settings and the
  caches; signing out first deletes the caches, which hold originals you opened), or `flatpak uninstall
  dev.hviid.Verso`.
- **Uninstalling without signing out first** leaves the credential, the session on the server and the caches, which
  signing out would have removed. The drive itself goes: about two and a half minutes after the program is gone, the
  service unmounts, turns its user service off, and takes the drive's bookmark, its GVfs drop-in, its seeded
  thumbnails and Verso's Crosslink entries away.
- **On the Mac,** signing out of Verso, or turning Verso Drive off, takes Verso Drive's location out of Finder with
  what was downloaded. Files in Upload that have not reached Immich are kept, and Finder opens the folder they are kept
  in. Removing the app runs nothing, so sign out or turn the drive off before you do: an app removed with its drive on
  leaves its location in Finder's sidebar.

## Exit codes and JSON

- Every command accepts `--json` and writes exactly one JSON document to stdout. Progress and warnings go to
  stderr.
- Exit 0 means the command completed. Non-zero means it could not. Problems with individual items show in the
  output, not in the exit code.
