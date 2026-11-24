---
name: lab-immich-server
description: Use when a test needs a real Immich server - contract tests, Verso's window or Verso Drive against real data (in a lab VM, on this host or on the Mac), sign-in with OIDC, checking an API behaviour, or a version-floor check - or a library that looks like a person's own, for the website's and the App Store's screenshots and for what Immich's demo cannot show (edits, ratings, comments and likes, a partner, the Locked Folder, memories, named people, uploads and backups, the iPhone Simulator or a real iPhone). Builds a disposable, seeded Immich server on the Incus lab host with lab/immich-server/, and explains what is in it and how to reach it.
---

# A disposable Immich server

Read AGENTS.md, "Testing on Erebus", first: its rules (the `ind-` prefix, the `lab` project, disposable instances kept warm for a session,
throwaway credentials, no personal photos) apply to everything here.

## Build it

```sh
lab/immich-server/up.sh --lan     # or no flag for NAT; IMMICH_VERSION=v3.2.0 for the version floor
lab/immich-server/seed.sh         # admin, two API keys, 50 fixture photos and the edge cases below
lab/immich-server/oidc.sh         # optional: Dex as the OIDC provider, for browser sign-in
```

- **With machine learning:** `lab/immich-server/up.sh --ml` and `seed.sh --ml` build `ind-immich-ml` beside the
  plain server (its credentials in `.env.ind-immich-ml.local`, with `IMMICH_ML=1`). Smart search, face detection,
  OCR and duplicate detection then work; seeding waits for their jobs, and the first build downloads the models.
  Faces are detected, so its people differ from the plain seed: the general contract tests expect the plain
  server, and the tests that need machine learning run only where `IMMICH_ML=1`.
- **A library that looks like a person's own,** for screenshots and for the iPhone: `ind-immich-show`, "The showcase
  server" below.
- **The version floor beside the current one:** `IMMICH_INSTANCE=ind-immich-32 IMMICH_VERSION=v3.2.0 up.sh`, then
  `seed.sh` with the same `IMMICH_INSTANCE`. Each server needs its own tunnel port from this host.
- **In CI:** `lab/immich-server/ci.sh <version>` runs the same seed in a runner's own Docker (the `contract` job in
  `.github/workflows/ci.yml`, which runs once GitHub Actions is switched on in this repository); `fixtures.sh`
  downloads the fixtures for both.

- `up.sh` takes about 90 s; `seed.sh` about 90 s with cached fixtures, about 160 s from an empty cache.
- **Warm in NAT mode** (AGENTS.md, "Testing on Erebus"): `seed.sh` ends by taking a snapshot of the seeded server,
  and every later `up.sh` restores it, so each check starts from the same seed, uploads of earlier checks gone;
  `seed.sh` then has nothing to do. `--fresh` builds it again. A LAN-mode server is never kept warm. Dex is not in
  the snapshot: run `oidc.sh` again after each `up.sh` that needs it.
- Everything lands in the git-ignored `lab/immich-server/.env.local` (`.env.<instance>.local` for another
  `IMMICH_INSTANCE`, so two servers can run side by side): `IMMICH_URL`, a full-access and a read-only key, the
  throwaway admin login, and after `oidc.sh` the Dex user (`DEX_EMAIL`, `DEX_PASSWORD`).
- Tear down with `lab/immich-server/down.sh`, always, and before anything else in a LAN-mode run: LAN mode exposes
  the server and its throwaway login to the whole LAN.

## Reach it

| From | NAT (default) | LAN (`--lan`, or `lan.sh on`) |
|---|---|---|
| this host | only through a tunnel: `IMMICH_INSTANCE=<name> SHOWCASE_PORT=<port> lab/immich-server/tunnel.sh open` (by hand: `apt-get install socat` in the container, then `socat TCP-LISTEN:2283,bind=127.0.0.1,reuseaddr,fork EXEC:"$EREBUS_DIR/bin/incus exec ind-immich-srv -- socat STDIO TCP\:127.0.0.1\:2283"`) | its LAN address, which changes between runs (`.env.local` has it) |
| another lab instance on NAT | `http://ind-immich-srv.incus:2283` | its LAN address; the `.incus` name does not resolve |
| the Mac (and its iPhone Simulator) | `tunnel.sh open --mac`: the same tunnel, forwarded on to the Mac's own loopback over SSH | its LAN address |
| a real iPhone | not at all: switch to LAN mode for the session | its LAN address |

The lab project forbids proxy devices, so NAT mode has no port forward. Prefer LAN mode when this host runs Verso's
window or service; NAT mode when only lab VMs talk to the server. The Mac reaches a NAT-mode server through the same
tunnel, forwarded on over SSH (the `mac-dev` skill, "The server").

- **`tunnel.sh`** (`open [--mac]`, `check [--mac]`, `status`, `close`) runs both tunnels detached, so they outlive the
  shell that opened them, and checks `/api/server/ping` through each (on the Mac with `curl`, the only command it
  runs there besides the forward). It needs `MAC_HOST` (`user@address`, private) and `MAC_SSH_OPTIONS` (`-i <key> -o
  IdentitiesOnly=yes`) for `--mac`. Defaults: the showcase server, port 2290 on both ends; another server needs a port
  of its own (`SHOWCASE_PORT`), and 2283 may already be taken on this host. One `incus exec` per connection costs
  about 0.1 s, which an app's few kept-alive connections hardly notice. Close the tunnels when the session ends.
  A server's tunnels on this host are one pair, shared by every agent here (their state is in
  `$XDG_RUNTIME_DIR/verso-lab-tunnel/<instance>/`): `open` reuses what is open, and `close` closes them for everyone,
  so close them only when no other agent of the session still uses the server.
- **`lan.sh on`** puts a warm NAT-mode server on the LAN for a session (stop, the `lan` profile added, start; about
  10 s), keeping its data, and writes `IMMICH_LAN_URL` into its `.env` file; **`lan.sh off`** puts it back on NAT
  (about 10 s; the server stays reachable from this host while on).
  The whole LAN then reaches the server and its throwaway logins, so LAN mode is never left up unattended: `off`
  before the session ends, or before leaving it. `up.sh`'s restore puts it back on NAT too (the snapshot was taken on
  NAT), and no script takes a snapshot in LAN mode.
- **A server that cannot be reached is checked two ways:** with its packets dropped (silence, no refusal: the hardest
  case, which the service's 25-second poll limit and the window's 12-second wait cover) and with it stopped (refused
  at once). ARCHITECTURE.md, "When the server cannot be reached", says how soon each shows.

## What is in it

Contract tests (`shared/immich-api/tests/contract*.rs`; run them with `cargo test -p immich-api --tests -- --ignored
--test-threads=1` after sourcing `.env.local`) and the bridge's lab tests (`shared/verso-bridge/tests/lab.rs`:
`set -a; . lab/immich-server/.env.local; set +a`, then `cargo test -p verso-bridge --test lab -- --ignored`) assert
these numbers, so a change to the seed changes them. Tests that change the library put it back before they end:
- **52 uploads:** 51 not trashed (47 images, 4 videos), 50 on the timeline; 40 month buckets across 1970 and
  2008-2025; 7 countries and 11 cities; 10 photos with a date but no GPS.
- **One archived** ("Gargoyle water spouts 2") and **one trashed** ("Besættelsesmuseet - Dagligstue").
- **Albums:** "Holiday Mix" (5, one WebM) and "Persons" (3), named like a top-level folder on purpose.
- **One person,** made by hand (no machine learning): `POST /people`, then `POST /faces`.
- **Edge cases:** three different photos uploaded as `IMG_0001.JPG`; `no-date.jpg` with all metadata stripped
  (Immich puts it in 1970-01); Unicode and punctuation names (`タテ弁 01.jpg`, `Loew's State Theatre.jpg`, a `…`).
- **Cities are GeoNames' nearest place,** not the obvious one: Times Square is Weehawken, Tokyo Station Hatchōbori.

Machine learning is off (a compose override keeps its container out, and `seed.sh` turns it off in the system
config), so faces are never detected and smart search is unavailable, unless the server was built with `--ml`.

## The showcase server

A second server, `ind-immich-show`, whose library looks like a person's own: for the website's and the App Store's
screenshots, and for what Immich's public demo cannot show (it is read-only, and others keep changing it): saving an
edit, ratings, comments and likes, a partner, the Locked Folder, memories, named people, uploads, Verso Drive's
uploads and the iPhone's backup. It runs beside the contract tests' server, never instead of it.

```sh
IMMICH_INSTANCE=ind-immich-show lab/immich-server/up.sh --ml    # about 2 min; later runs restore the snapshot
lab/immich-server/showcase.sh                                  # about 3 min with a warm fixture cache
lab/immich-server/tunnel.sh open --mac                         # optional: this host and the Mac reach it
```

- **Warm** like the others (`showcase.sh` ends with the `fresh` snapshot, `up.sh` restores it), so its "on this day"
  memories are the seed day's: on a later day, `up.sh --ml --fresh` and `showcase.sh` again (about 5 minutes) for
  memories of today.
- **Credentials** are in the git-ignored `lab/immich-server/.env.ind-immich-show.local`, which never leaves this host
  (not to the Mac either: a test there gets them passed on by whoever runs it): `IMMICH_URL` (from Erebus' instances),
  `IMMICH_LOCAL_URL` and `IMMICH_MAC_URL` (`http://127.0.0.1:2290`, through `tunnel.sh`'s tunnels on this host and on
  the Mac, where the iPhone Simulator shares the Mac's loopback), `IMMICH_LAN_URL` while `lan.sh on`, the admin's
  `IMMICH_ADMIN_NAME`, `_EMAIL`, `_PASSWORD` and `_PIN` (the Locked Folder), `IMMICH_API_KEY_FULL` and
  `IMMICH_API_KEY_READONLY` (the admin's), the partner's `IMMICH_PARTNER_NAME`, `_EMAIL`, `_PASSWORD` and
  `IMMICH_PARTNER_API_KEY_FULL`, the two shared links' keys (`IMMICH_SHARED_LINK_ALBUM_KEY`, `_PHOTO_KEY`), and
  `IMMICH_ML=1`, `IMMICH_SHOWCASE=1`. `.assets.ind-immich-show.tsv` maps manifest ids to asset ids.
- **A real iPhone** reaches it only in LAN mode: `lan.sh on` at the start of the session (it prints
  `http://<LAN address>:2283`, which the phone signs in to), `lan.sh off` at its end. Never leave it on unattended.

What `showcase.sh` seeds (`fixtures/showcase/build-manifest.py` has the story, `showcase-container.sh` the calls):
- **Two users:** the admin, Maja Holm (`maja@example.com`), and Jonas Holm (`jonas@example.com`), her partner, who
  shares his library with her; she shows it on her timeline. Storage labels `maja` and `jonas` and the storage
  template on, so Folders shows `maja/2019/2019-04-05/`.
- **147 uploads:** the admin's 134 (130 photos, 4 videos) and the partner's 13 (11 photos, 2 videos), every one CC0
  or public domain. Upload names as a camera's: `IMG_1001.JPG` on, the partner's `PXL_20210904_101500.jpg`, the old
  photographs `SCAN_0001.JPG`. Videos are transcoded to H.264 MP4, at most 15 s.
- **Dates from 1847 to 2026:** trips to Paris (2014), New York (2015), Lisbon (2016), the American West (2017, two
  videos), Iceland (2018), Lofoten (2019), Japan (2019), the fjords (2020), Rome and Venice (2022), fireworks in
  Kamakura (2024, a video), home in Copenhagen across the years, a zoo day, food, friends' dogs, a museum in Madrid
  (2026); the partner's cats and a surf video from Australia; and 17 scans of old photographs (1847 to 1907) at their
  own dates. The story's time zone is in each photo (`OffsetTimeOriginal`).
- **Places in 11 countries** as GeoNames names them: Australia, Denmark, France, Iceland, Italy, Japan, Norway,
  Portugal, Spain, United States and Vatican (a Rome photo's nearest place). The scans have no GPS.
- **Memories:** five photos taken on the seed day's month and day, 1, 3 and 6 years before, and Immich's memory job
  run: three "on this day" memories.
- **Favourites** (13 and the partner's 2), **ratings** 1 to 5 on 19 photos (the ratings preference on), **21 tags**
  for the admin and 5 for the partner, nested (`Travel/Japan`, `Nature/Northern Lights`, `Animals/Cats`), and 44
  **descriptions**.
- **Albums:** one per trip, "Copenhagen", "Copenhagen Zoo", "Old Portraits", each with a favourite as its cover.
  "Japan 2019" is shared with the partner as editor and "Iceland Road Trip" as viewer; the partner's "Our Cats" is
  shared with the admin. Comments and likes from both users (6 comments, 5 likes) on those three.
- **Shared links:** the Iceland album (download allowed) and one photo (Reine).
- **Stacks:** three pairs (the Fushimi Inari foxes taken seven seconds apart, the Pantheon, the northern lights),
  the first of each its cover.
- **Archived 3, trashed 3, and 2 in the Locked Folder,** behind the admin's PIN.
- **Named people, after face detection:** nine sitters of old photographs and paintings: Hans Christian Andersen,
  Abraham Lincoln, Mark Twain, Charles Darwin and Frederick Douglass (three photos each), Florence Nightingale (two),
  Rembrandt, René Descartes and Ida Hammershøi (one painting each). Every face becomes a person (minimum faces 1),
  detection's minimum score is 0.5 (at the default 0.7 two of Darwin's and Douglass's daguerreotype had no face),
  a sitter's faces are merged into one named person, and the faces nobody named are hidden.
- **Everything on in both accounts:** ratings, tags, folders, memories, people and shared links.
- **Not seeded:** Live Photos (a still and its motion clip need a licensed pair taken together; the API could link
  any still to any video, which would be a fake), an edited photo (left to the tests that save one), and an avatar
  picture (it would be a face).

**For marketing:** `fixtures/showcase/ATTRIBUTION.md` lists every file and says which the website and the App Store
may use. No photo shows a recognisable living person; eight show people small, turned away or on a poster (marked
"check"); the named people are long-dead sitters of public-domain works. Face detection over the whole library found
no other person's face.

## A large library

`lab/immich-server/bulk.sh 1997-01:450 1998:10` adds generated photos (ffmpeg's test pattern, so no licences and no
personal photos): 450 in January 1997, and 10 in each month of 1998. It waits until Immich has made their
thumbnails, about a minute for a thousand. Use it to measure how folders of many files behave in Verso Drive
(`lab-bazzite-vm`, "How long Files is busy"), each measurement on a month the service has not seen. The seeded
snapshot does not keep them: run it again after each `up.sh`. Keep months under 500 photos to measure a folder of
files: from 500, Photos splits a month into day folders (`grouping.photos`). The contract tests' numbers count only
the seed, so run them before adding a bulk library, or on a server restored by `up.sh`.

## Fixtures

`fixtures/manifest.json` pins 50 Wikimedia Commons files (CC0, public domain, CC BY, CC BY-SA) with their URLs,
checksums, authors and licenses; `fixtures/ATTRIBUTION.md` is generated from it. The downloads go to the
git-ignored `fixtures/cache/`, which can be deleted at any time.
- **Commons' standard-size renditions, not originals:** `upload.wikimedia.org` answers bulk original downloads with
  429 and `Retry-After: 600`. Renditions carry no EXIF, so the manifest pins each original's camera metadata and
  `seed-container.sh` writes it back before uploading.
- **A checksum mismatch** means Wikimedia re-rendered a file: run `fixtures/build-manifest.py` to regenerate the
  manifest. Set `WIKIMEDIA_UA` to a descriptive User-Agent, as their policy asks.
- **Never add personal photos.** New fixtures are Creative Commons or public domain, added through the manifest.
- **The showcase's own manifest,** `fixtures/showcase/manifest.json` (its `ATTRIBUTION.md` and `build-manifest.py`
  beside it, its downloads in the git-ignored `fixtures/showcase/cache/`), is built the same way, CC0 and public
  domain only, mostly Commons' copies of Unsplash's photos from before June 2017, when Unsplash's licence was CC0.
  Each entry names the story's place and time (pinned as the EXIF the seed writes), says what people it shows
  (`people`) and whether marketing may use it (`marketing`). `fixtures.sh` serves both (`FIXTURES_DIR`).
- **Commons' original host** (`upload.wikimedia.org`) answered Python's `urllib` with 429 every time while `curl` got
  the same file at once, so the builders pin originals (the videos) by Commons' own sha1 and leave
  their download to `fixtures.sh`; photos come from the rendition host (`thumb.wikimedia.org`), at Commons' standard
  widths only (500, 960, 1280, 1920).

## Sign-in with OIDC

`oidc.sh` runs Dex beside the server with one static user (`admin@example.com`, so OIDC lands on the seeded
admin) and points Immich's OAuth settings at it. Dex's issuer is plain http, which Immich refuses unless the OAuth
setting `allowInsecureRequests` is on; the script sets it. Real servers use https.

`lab/immich-server/oidc-sign-in.py <path/to/verso-service>` plays the person at the browser: it runs `<program>
login --server <url> --json` with a private HOME, fills in Dex's form, and hands the `app.immich:///oauth-callback`
redirect back. It fails unless the CLI signs in and `status` reaches the library (`online`, or `unmounted` with
Verso Drive off) with a session. Give it Verso's program, `target/release/verso-service`, say: its default,
`immich-mount`, is Immich Mount's.

## Traps

- Source `$EREBUS_DIR/lib/erebus.sh` from bash, never zsh (it needs `BASH_SOURCE`).
- Docker runs in the unprivileged container with `security.nesting=true` alone. Immich supports Docker Compose
  only, not Podman.
- The server's own OpenAPI spec is at `$IMMICH_URL/api/spec.json`; check a field there before guessing.
- **Waiting for a job just started can pass at once:** the queues are idle until the job is queued, so `idle` right
  after `PUT /jobs/<name>` proves nothing. The showcase seed therefore never re-runs face recognition by hand; it
  merges the persons that recognition on upload made for one sitter.
- **Immich's face detection takes a dog's face, and a server's fans, for faces.** Unnamed persons are hidden, so
  they never reach the People page; count faces per asset (`GET /faces?id=`) when judging what a photo shows.
