# ARCHITECTURE

How Verso is built and why. [SPEC.md](SPEC.md) is the contract (what it does), and [PRINCIPLES.md](PRINCIPLES.md)
holds the invariants. This file is the model and the reasoning: every design choice is stated with its reason, and
where a question tends to come back, the alternative that lost is named with the reason it lost.

It goes by layer: what Verso is; the shared core (`immich-api`, `verso-core`, `verso-bridge`); Linux (the window, the
service and the drive, the Files extension, packaging); the Mac (the app, and Verso Drive's extension); and what runs
across the platforms (the icon, translations, releases, testing).

A claim marked *verified* was observed on a real system, in the lab AGENTS.md describes ("Testing on Erebus"); many of
the drive's were observed with Immich Mount, whose drive Verso Drive is ("What Verso is").

## What Verso is

Verso ("Verso for Immich") is one app for an Immich library, with three parts that know each other:
- **The gallery:** browse, search and organise the library in a window, as Immich's web app does, and as Immich
  Gallery does on the Mac.
- **Verso Drive:** the library as a folder in the file manager and in every file dialog, with server thumbnails,
  downloading an original only when something reads it. Files copied into its Upload folder are uploaded. It is off
  until switched on.
- **The tray** on Linux and the menu bar item on the Mac: the state at a glance, and the way to the gallery and the
  drive without a window open.

One sign-in, one set of preferences and one install serve all three.

Verso Drive comes from Immich Mount, the maintainer's earlier app, which shows an Immich library as a drive and goes
on in a repository of its own. Immich Mount was inspired by
[Kartax/immich-desktop-app](https://github.com/Kartax/immich-desktop-app), which does the same on macOS through Apple's
File Provider. Verso's Mac app is built from [Immich Gallery](https://github.com/IGOLz/ImmichGallery), Alessandro
Craciun's native Mac client ("Verso on the Mac").

Order of platforms:
1. **Linux, on GNOME** (GTK 4 and libadwaita, and Files for the drive) first.
2. **macOS** next: Immich Gallery's app made Verso's, with Verso Drive through Apple's File Provider ("The Mac";
   ROADMAP, M8).
3. **iOS** later, on the same crates and the one version line ("Verso's releases").

**On KDE Plasma, Verso runs as on GNOME: the GTK window, and the drive without Plasma's integration.** Without a
maintainer who uses KDE every day there is no Plasma interface (ROADMAP, M9). The drive's Plasma integration
(Dolphin's Places entry, the doctor's check of Dolphin's remote previews, KDE's thumbnail sizes, Plasma's notifications
and Klipper for copied links) lives in Immich Mount's repository, where its KDE edition has it, for a native KDE
frontend, a Kirigami window over `verso-desktop`, to take if one comes (ROADMAP, "Parked on purpose"). Starting KWallet's Secret
Service, where a Plasma login has not, is built: the GTK window's sign-in needs it there (Security and privacy). There
is no Windows edition; a separate project, ImmichDrive, covers Windows with the Cloud Files API.

The library is never mirrored. Libraries run to 300 GB and more, and downloading them is never acceptable: the gallery
shows Immich's thumbnails and previews, and the drive fetches an original only when a program reads it.

**Not the drive's job:**
- syncing
- editing, renaming, moving or deleting Assets through the file manager
- managing albums

The gallery changes the library (Verso's window, "What changes in Immich"); the drive stays a read-only view with one
folder that takes new files ("Uploads").

## The shared core

What more than one platform uses lives in `shared/`, and what one platform alone uses lives in its own folder
(`linux/`, `mac/`), named by where it runs (ROADMAP, M9). The shared crates hold the Immich client, Verso Drive's
model of the library (the tree, its names, its store, content and uploads), links, sign-in and the settings table.

### Crates: a portable core with platform adapters

| Crate | Runs on | Kind | Holds |
|---|---|---|---|
| `immich-api` | every platform | lib | The Immich REST client and models ("The Immich API layer") |
| `verso-core` | every platform | lib | The library model, naming, membership, metadata store and its change journal, content cache, upload logic, links, the sign-in flow, the settings table and config, the product's names (`product`), and what the gallery arranges alike on every platform: the Library's Years and Months (`overview`), the map's clusters (`map`), the Duplicates page's order (`duplicates`), which shared links show (`shared_links`), People's filter (`people`), Places' groups and order (`places`) and the date scroller (`rail`) |
| `verso-bridge` | the Mac | lib | The bridge the Mac's Swift code calls through uniffi: Verso Drive's items by identifier, listings, whole originals, thumbnails, changes and uploads, the drive's settings, the gallery's calls (`ApiConnection`) and the core's arrangements (`arrangements`, and the date scroller's `rail`) |
| `verso-linux` | Linux | lib | FUSE adapter (inode table, kernel invalidation, staging), freedesktop thumbnail seeding, Secret Service, notifications, translations, the D-Bus service and the tray: what the service and the window share, without GTK |
| `verso-service` | Linux | bin | The service: the drive's daemon, the tray and the command line (`verso-service`), each command resolving its inputs, calling one core function and rendering the result |
| `verso-desktop` | Linux | lib | What the window does, without a toolkit: sign-in and the credential, the service and the drive's switch, the account, the library as sections of tiles, the grid's justified layout, ThumbHash placeholders, the picture cache, imports, notifications, the changes made in Immich, the settings pages' layout |
| `verso` | Linux (GNOME) | bin | Verso's window, GTK 4 / libadwaita, over `verso-desktop`, with Verso Drive's settings pages ("Verso's window") |

The Mac's Swift is in `mac/`: the app (`mac/Verso/`), Verso Drive's extension (`mac/FileProvider/`) and what both
read (`mac/Shared/`) ("The Mac").

**`verso-linux` has no GTK** so that the service, which links it, loads no toolkit (Linux, "The window and the
service"). The drive's settings pages, which are GTK, live in the window's crate, and what the window does without a
toolkit is `verso-desktop` (ROADMAP, M9).

**Why a portable core:** each platform has its own native way to show a remote library as files.

| Platform | Mechanism | Who caches content | Identity |
|---|---|---|---|
| Linux | FUSE | We do | Inode numbers handed out per mount |
| macOS | File Provider | The OS | String item identifiers, sync anchors |

Logic written in FUSE terms (inodes, `readdir`, `flush`) would make Verso Drive on the Mac a rewrite, so the core
speaks an identifier-based model: stable `NodeKey` identities, serialisable to strings; listings with final names;
attributes; byte-range reads; thumbnail bytes; uploads with duplicate semantics; and changes as the folders they touch
(`LibraryChanges`), whose listings Linux forgets and which the Mac's extension turns into per-item records with
sequence numbers, its sync anchors ("Verso Drive on the Mac"). OS services (secrets, notifications, directories, the
clock) come in through traits.

**What keeps the boundary honest:**
- The core is compiled for `aarch64-apple-darwin` without a Mac (the green gate's portability check, AGENTS.md),
  and the Mac's build links it.
- The core's integration tests run through a small in-memory adapter, so the core always has a consumer that is not
  FUSE.

**Key dependencies:**

| Area | Crates |
|---|---|
| Core | `tokio`, `reqwest` (in `immich-api`; rustls with the system's root certificates, and the certificate trusted for the server), `serde`, `redb` (pure Rust), `sha1`, `sha2`, `toml_edit`, `log`, `thiserror` |
| Linux adapter | `fuser` (pure Rust, mounts through `fusermount3` with no libfuse), `zbus`, `oo7`, `image` + `png` |
| Command line | `clap` (with `clap_complete` and `clap_mangen`), `anyhow` |
| Window | `gtk4`, `libadwaita`, `libshumate` |
| Mac bridge | `uniffi`, `oslog` (Apple's systems, for the unified log of macOS and iOS) |

`fuser` calls the `Filesystem` trait synchronously; answers that need the network move the reply object into a
tokio task. Its async-native alternative, `fuse3`, is less used: switch only if that reply pattern gets ugly.

**The Mac:** Verso's SwiftUI app and Verso Drive's File Provider extension on this core, through `uniffi` bindings
("The Mac").

**Error types:** the core uses typed errors (`thiserror`), because the FUSE adapter must map each kind (offline,
signed out, gone, transient, protocol) to an error code. `anyhow` with context is used at the edges, in the command
line and the daemon's wiring.

### The Immich API layer

`immich-api` holds the client and models for Immich's API: the endpoints the drive uses, and the rest of the API a
full client needs (albums and their members, changing Assets, the trash, edits, people and faces, tags, stacks,
duplicates, memories, the map, search, folders, downloads, sharing, the account, and administration). The drive
calls only its own part; the gallery calls the rest, on Linux directly and on the Mac through the bridge's typed calls
("Verso on the Mac"), so every part of Verso is built on the same tested layer (the maintainer's choice).
The drive's endpoints are copied from [immich-rs](https://github.com/boul2gom/immich-rs) (MIT, generated from the
Immich v3.3.5 OpenAPI spec, commit `60d1eb3`) and adapted; the rest are written here from the OpenAPI spec, with the
choice of endpoints and their request shapes learned from two clients: ImmichGallery (MIT) and Mimick (GPL-3.0, read,
never copied). From then on all of it is our own code.

**How the whole API is kept honest:**
- **One table** (`immich_api::endpoints()`) lists every endpoint the crate calls with the API-key permission Immich
  requires, and each method's documentation names the same permission.
- **The spec check** (`tests/contract_spec.rs`) reads the server's own `/api/spec.json` against each supported
  version and fails when an endpoint is missing or needs another permission, so a renamed or removed endpoint shows
  up before a user meets it; it prints the deprecated endpoints still in use.
- **A contract test per endpoint** against the lab server (`tests/contract*.rs`), except the OIDC callback, which
  `lab/immich-server/oidc-sign-in.py` checks with Dex. Tests that change the library put it back before they end,
  even when an assertion fails halfway.
- **The read-only key** is refused the changes of every area, aimed at ids no server holds, and the test checks
  that the server names the permission the table names.
- **A lost answer is not a second change.** Creating, rotating a key, changing a password or PIN code, and shifting
  dates by an amount are resent only when the first attempt cannot have taken effect (`retry.rs`).
- **A connection the server let go is not an error.** Immich's server (Node) closes an idle connection after 5 s, and
  reqwest keeps one for 90 s by default, so a request after a pause can go out on a connection being closed and fail
  with "connection closed before message completed". The client lets idle connections go after 4 s (`POOL_IDLE`), and
  a call that may be sent twice is sent again after a connection closed before its answer, as after a failed
  connection; one that may not, is not.
- **Secrets stay out of logs:** API key values, session tokens, passwords, PIN codes and shared link keys are
  `Secret`s, whose `Debug` output is redacted, and a transport error's message has its URL's query cut.
- **Deprecated endpoints** are used where v3.2 has nothing else (`PUT /assets/{id}`, `PUT /tags/{id}`, and others);
  the spec check lists them, and they move when the floor does.
- **New models** decode with a struct-level `serde(default)`, and `null` counts as missing, so a field absent on one
  version or `null` on another never breaks an answer. An enum keeps a value it does not know. A model's id may
  decode empty, so the client refuses an empty path segment before sending: `/albums/{id}` can never become
  `/albums/`.

**Left out on purpose,** until something needs them: cluster groups, workflows, plugins, database backups,
maintenance mode, the system configuration, licenses, onboarding, admin email templates, asset files, and the HLS
video stream (`/video/playback` serves players that read ranges). Each is a module and a contract test away.

**Not chosen: a client generated from the OpenAPI spec.** The spec marks fields required that older servers leave
out, knows none of the quirks below, and would give every caller generated types instead of the error kinds and
models the drive branches on.

**What is copied:** the models for the timeline buckets (with album and person filters), search, people, albums and
suggestions; the sync stream and ack types; the OAuth authorize and callback types; auth with API keys and bearer
tokens; multipart uploads with SHA-1; and the retry policy (429 and 502 to 504 everywhere, 500 only on idempotent
methods, honouring `Retry-After`).

**Why copy instead of depending on it:** the crate was young, with one author, and carries far more than we use (the
whole API, WASM, OpenTelemetry, Socket.IO). What is copied is held to rustls only and no unused features, and our
contract tests catch API drift.

**Version policy:** the current and previous Immich minor release, with the floor moving forward deliberately.
- Only the current search dialect is implemented (`filter`, `orderBy`, `cursor`); smart, random and counting
  searches take the same `filter`. Smart search has no paging there (`page` is deprecated and cannot sit beside
  `filter`, and there is no cursor), so it returns its best matches, up to 1000. The one exception is the deprecated
  `POST /search/large-assets`, whose few filters go in the query string.
- Every search sets `filter.trashedAt: {eq: null}`, because that dialect includes trashed Assets by default.
- `/server/version` is read once per connection, and version-specific behaviour lives in one place.
- **v3.2 and v3.3** agree on the parts of the OpenAPI spec the client uses. v3.2 differs in what the code and tests
  know: its reverse-geocoding data names the United States "United States of America", merging people made by hand
  merges nothing (that version merges by person group), and a tag taken off an Asset while its sidecar job is pending
  comes back on it (`tag.rs`).
- **Not chosen:** a floor as old as v1.135.0, with the deprecated search dialect: two dialects, older upload fields
  and a larger test matrix, for a new app whose users tend to upgrade Immich often.

**Names and sizes without a session.** With an API key there is no sync stream. The details for a month's ids
(names, sizes) then come from a search over the month's UTC range widened by 14 hours on each side, filtered to
the bucket's ids.

**The account namespace.**
- A session knows its user id from the sign-in response, so caches are keyed by the URL plus the user id.
- A scoped API key cannot read `/users/me`, and `/api-keys/me` returns no user id, so API-key connections are keyed
  by the URL plus a hash of the key.
- `status` shows the account's email only when the credential can read it.

What the API does, all of which the client encodes:
- **Sizes:** `withExif: true` on every search; without it there is no `exifInfo` at all, so no sizes.
- **Visibility:** searches and buckets outside albums, favorites and the archive restrict visibility to the
  timeline, since the defaults include archived Assets.
- **Albums:** album contents come from search by `albumIds`. The album response has no asset list.
- **The connection probe** is `/api-keys/me` for keys, which needs no scope. `/users/me` needs `user.read`, which
  scoped keys lack.
- **Thumbnail sizes:** `thumbnail` is a 250 px WebP and `preview` a 1440 px JPEG. `fullsize` redirects to the
  original (a video's, to its preview), so it is never used.
- **Uploads:** they need `assetData`, `fileCreatedAt` and `fileModifiedAt`. The checksum is base64 SHA-1, and
  `bulk-upload-check` accepts hex or base64. A duplicate of a trashed Asset returns the trashed id, and the Asset
  stays trashed.
- **Error codes:** an unknown or deleted Asset id gives 400 `Not found or no asset.read access`, not 404. A missing
  or inaccessible Asset is not proof of deletion.
- **Keys stay out of URLs:** `?apiKey=` also authenticates, but is never used. An API key sent as `Bearer` is
  refused (401).
- **Ranges on originals:** byte-exact 206 answers with `Content-Range`, HEAD included. A multi-range request gets
  the whole file (200), and a range past the end gets 404, not 416. The weak ETag (size and mtime in hex) is the
  same for every range, and `Last-Modified` is the Asset's `fileModifiedAt`.
- **Timeline buckets** are columnar JSON: ids and a few fields, with no names or sizes. Their `fileCreatedAt` has
  no `Z`, and a malformed `timeBucket` gets a 500.
- **Value formats:** `duration` is in milliseconds (null for images), and `localDateTime` is wall-clock time with a
  misleading `Z`.
- **The search dialect** (`filter`, `orderBy`, `cursor`) cannot be mixed with the deprecated fields (400).
  `visibility {ne: archive}` needs elevated permission, since it would include locked Assets, so the client asks
  for `{eq: timeline}`.
- **Defaults that surprise:** a `size` parameter on buckets is ignored, not rejected; `GET /assets/{id}` has no
  `status` field; search defaults include archived (and, in the new dialect, trashed) Assets.

### Signing in

**Sign-in is a button that opens the user's own browser, like Immich's mobile app.**
1. Verso reads `/server/features` (`oauth`, `oauthAutoLaunch`, `passwordLogin`) and `/server/config`
   (`oauthButtonText`) to know what to offer. Neither needs authentication.
2. `POST /oauth/authorize` with `{redirectUri, state, codeChallenge}` (PKCE S256) returns the identity provider's
   URL, opened through the OpenURI portal.
3. The user signs in there with passkeys, password managers, or whatever they normally use.
4. The provider redirects to `app.immich:///oauth-callback`. Verso's launcher entry is registered as the handler for
   that scheme. On servers with Immich's "mobile redirect override", the provider redirects to
   `https://<server>/api/oauth/mobile-redirect` instead, which bounces to the same `app.immich:` URL.
5. `POST /oauth/callback` with `{url, state, codeVerifier}` returns a session token.

The flow is the server's own (`server/src/services/auth.service.ts`, `oauth.repository.ts`, `dtos/auth.dto.ts`;
verified with Dex as the identity provider).

**Why this design:**
- **Reusing the mobile app's redirect URI** means sign-in works with no server or identity-provider changes,
  wherever mobile sign-in already works.
- **The Immich server is the OIDC client:** it holds the secret and does the exchange, so we register nothing
  anywhere.
- **PKCE and state make an intercepted code useless.** If another program on the same machine claimed the
  `app.immich` scheme, the worst outcome is a failed sign-in, not a leak.

**Who runs it:** on Linux the window, as GTK's single-instance application, so the redirect reaches the process that
holds the PKCE verifier. It makes itself the default handler of `app.immich` as it opens the browser, since Immich
Mount's app claims the scheme too (in a Flatpak the exported entry carries the scheme), then stores the credential in
the keyring and restarts the service, which reads it as it starts. Headless, `verso-service login` runs the same
flow, with the redirect URL pasted back.

**The address goes to https, and to plain http only on the local network** (SPEC.md, "Signing in and credentials";
`mac/Verso/Verso/API/ServerAddress.swift` on the Mac and the iPhone; Linux only adds `https://`). Plain http is never
tried after a certificate's error, nor for a server elsewhere: anyone on the way there could make https fail (a
certificate of their own, a blocked port) and read the password and every photo backing up sends. A plain http server
on the local network still connects without its scheme typed, as https to its port fails with a TLS error, not a
certificate's. Not chosen: no fallback at all, which would make every LAN server's address need `http://` typed.

**The session is kept, in the keyring.**
- **Only a session gets the sync stream** (verified), which makes the mount near-live.
- **Revocable in the usual places:** the desktop shows up in Immich's "Authorized devices", and signing out there or
  at the identity provider (back-channel logout) cuts it off. That is what OIDC users expect.
- Sessions have no expiry by default.
- The cost: a session carries the user's full permissions, so least privilege rests on the app's own switches.

Requests send an honest User-Agent, the program and its version (`verso/<version>` from the window,
`verso-service/<version>` from the service, `verso/<version> (macOS)` from the Mac), so the "Authorized devices"
entry is recognisable.

**Email and password** is offered when the server allows password login, both on the desktop and headless. It yields
a session too, so even a headless machine gets the sync stream. Immich's password login has no two-factor step
(`LoginCredentialDto` is email and password only; immich issue #880 was closed), so two-factor comes through OIDC,
and the form says so.

**API keys** are the advanced option: tests, CI, least-privilege setups, and machines without a browser.

**Not chosen:**
- **An embedded web view:** passkeys and password managers belong in the real browser (RFC 8252 says the same). The
  maintainer uses passkeys.
- **A loopback redirect (`127.0.0.1:port`):** the native-app norm, but the admin would have to register it at the
  identity provider. Parked in ROADMAP.
- **Turning the session into a scoped API key:** least privilege, but it loses the sync stream and identity-provider
  revocation.
- **No password form at all,** with API keys for password-only servers: a clumsy setup and no live changes, for the
  main use case (desktops).

The core holds the Immich side of sign-in (`verso_core::sign_in`). Catching the redirect is per platform: a scheme
handler on Linux, and `ASWebAuthenticationSession` on macOS.

### A certificate of the server's own

A home server often presents a certificate of its own: self-signed, or from a private authority the system does not
know. Verso connects to one only after the person has looked at that certificate and chosen to trust it, never by
itself (the maintainer's rule). SPEC.md, "Signing in and credentials", has what the person sees.

**Trust is a pin: one certificate, for one server.** The pin is the SHA-256 of the leaf certificate's DER, kept with
the server's address (on Linux `server.certificate_sha256` beside `server.url`, SPEC.md, "Configuration"). Signing in
to a server writes its pin or removes the one there, so a pin never vouches for another server.

**The verifier** (`immich_api::certificate`) is in every client's TLS configuration:
1. The system's own verification runs first, as for any server: on Linux webpki over the roots `rustls-native-certs`
   lists, read afresh for each client, so an authority installed in the system's trust store counts at the next sign-in;
   on the Mac and iOS the system's own verifier (`rustls-platform-verifier`, which the bridge hands over with
   `certificate::set_system_verifier`). A certificate the system trusts is trusted, whatever is pinned.
2. Only a refusal that a server's own certificate gives can be overruled: an issuer the system does not trust (webpki's
   `UnknownIssuer`; its `CaUsedAsEndEntity` for openssl's default self-signed certificate, which marks itself an
   authority; Apple's "not trusted"), a certificate made for another name, or one outside its dates. A certificate
   that cannot be read, or that its authority revoked, is refused whatever is pinned.
3. Then the leaf's fingerprint is compared with the pin. Equal, the certificate is accepted. Otherwise it is refused,
   and what the person needs to decide travels inside rustls' error to the client's (`CertificateRefusal`: the
   fingerprint, subject, issuer, validity, whether it is self-signed, and the pin compared with):
   `ApiError::UntrustedCertificate` with nothing pinned, `ApiError::CertificateChanged` with another certificate
   pinned.
4. The handshake's signatures are still verified with the presented certificate's key (rustls'
   `verify_tls12_signature` and `verify_tls13_signature`, with the provider's algorithms), so a server that presents
   the pinned certificate must hold its key.

A refused certificate is not retried (`retry.rs`), and no request reaches the server: the handshake ends first.

**An expired certificate is still that certificate.** A pin trusts the exact bytes the person accepted, and the dates
of a certificate no authority vouches for are only what its maker wrote; a home server's own certificate also tends to
outlive its dates unnoticed. So the question shows the dates and says when one has expired, and a pinned certificate
stays trusted past its end date. A renewed certificate is another certificate, and is asked about.

**A pin never follows a change by itself.** Another certificate from the same server is refused as changed, with a
stronger warning, until the person trusts the new one, which then replaces the pin. A server that renews often asks
at every renewal (Caddy's `tls internal` gives a leaf 12 hours): for one like that, its authority belongs in the
system's trust store, which Verso follows (SECURITY.md).

**Every connection on Linux takes the pin:**

| What connects | How it takes the pin |
|---|---|
| The window's sign-in: the server check, the browser sign-in, email and password, an API key | `verso_desktop::session`'s steps over a client trusting the certificate accepted for that address (`Window::trusted_for`), else the one kept for it; `store_credential` keeps it with the server |
| The window's library: pages, thumbnails, previews, originals, downloads, imports, edits, the account, notifications, and videos | `connection::connect` builds the window's one client from `server.url` and `server.certificate_sha256`. Videos and Live Photos are downloaded through it into the cache and played from the file, so GStreamer never connects |
| The service: Verso Drive's listings, reads and uploads, the sync stream, and the tray's state | `online::daemon` builds its client from the same keys, at its start; the window restarts it once a certificate is trusted or forgotten |
| The command line: `login`, `status`, `doctor`, and `logout`'s ending of the session | `online::client` with the kept pin; `login` asks on a terminal, or takes `--trust-certificate` |
| Not the server: the map's tiles (OpenStreetMap, through libshumate), the update check (the download page), and Open in Immich (the browser, which asks its own question) | The system's trust alone |

Verso opens no websocket to the server.

**What the person sees** is the platform's own: on Linux an Adwaita question with the certificate's details, Cancel
first, and Trust This Certificate as the destructive choice; in the library, a banner and the same question when the
certificate changes, and the trusted certificate with Forget on Preferences' Account page; a notification from the
service, whose drive serves what it holds meanwhile, as while the server cannot be reached; a question on the
terminal from `login`. The wording lives in `verso_desktop::session::certificate_question`, translated.

**Not chosen:**
- **Accepting every certificate** (a switch that skips verification): anyone on the way, a hotel's network or a
  hacked router, would read the password, the session and every photo.
- **Trusting a whole authority** for Verso alone: an authority signs for any name, so one decision would vouch for
  every server it ever signs for. The system's trust store already does that, deliberately, for those who want it.
- **Trusting the first certificate seen** (trust on first use, without asking): the first connection is exactly the one
  someone in between can catch, and a silent pin would hide it.
- **Pinning the public key** rather than the certificate: it would survive a renewal with the same key, but a person
  cannot compare a key's hash with what `openssl x509 -fingerprint` shows them, and it trusts every certificate ever
  made for that key.

**Flatpak impact:** none. The pin lives in the sandbox's own `config.toml`, the verifier runs in Verso's process, and
no permission is added; the host's trust store is read as the runtime has it.

**The Apple step** (ROADMAP.md) plugs into the same core. The bridge already hands the system's verifier to
`set_system_verifier`, so the bridge's clients (Verso Drive's extension, the gallery's `ApiConnection`, the backup)
refuse an untrusted certificate with the same `CertificateRefusal`. What remains:
- keep the pin with the account, as `server.certificate_sha256` in the App Group's `config.toml`, which the extensions
  read too, and build the bridge's clients with it (`Client::trusting`);
- carry the refusal across uniffi (a `BridgeError` with its details), so the sign-in asks the same question in SwiftUI,
  and the library shows the same banner;
- the app's own requests (`ImmichClient`'s `URLSession`, the image pipeline, the server check) answer the session's
  server-trust challenge as the verifier does: `SecTrustEvaluateWithError` first, then the leaf's SHA-256
  (`SecTrustCopyCertificateChain`, `SecCertificateCopyData`) against the pin, accepted with `URLCredential(trust:)`;
- AVPlayer streams through `AVURLAsset`, outside the app's session: its resource loader's delegate answers the same
  challenge, or where AVFoundation does not ask it, the video comes through a scheme of the app's own, served by the
  app's session.

### The tree

#### Identity and inodes

```rust
enum NodeKey {
    Root, Timeline, TimelineYear(Year), TimelineMonth(YearMonth), TimelineDay(Date),
    AlbumsRoot, Album(AlbumId), PeopleRoot, Person(PersonId),
    PlacesRoot, Country(String), City { country: String, city: String },
    DateGroupYear { base: Box<NodeKey>, year: Year },
    DateGroupMonth { base: Box<NodeKey>, month: YearMonth },
    Asset { parent: Box<NodeKey>, asset: AssetId },   // one per Appearance
    Staging(StagingId), Virtual(VirtualFile),   // a receipt is a staged file after its upload
}
```

- **One node per Appearance.** The parent is part of the identity, so one Asset can live in its month, its albums,
  its persons and its city at once.
- **Shared content:** Appearances of one Asset share the content cache, keyed by asset id.
- **Inodes:** the Linux adapter keeps a two-way table between `NodeKey` and inode, hands out inode numbers in
  sequence for the life of a mount, and drops entries when the kernel's `forget` brings their lookup count to zero.
  Inode numbers are not stable across remounts; FUSE does not need them to be. Each mount uses a non-zero
  `generation`.
- **No hard links:** `st_nlink` is 1. Copy tools would otherwise deduplicate Appearances, and "delete one link" has
  no meaning here.

#### Membership comes from Immich

Folder membership is whatever Immich's own endpoints say (the table in SPEC.md, "Membership: Immich decides"). The
month folders use the same timeline buckets the Immich web app uses, and albums, people and cities hold exactly the
Assets Immich's searches return for them.

Why: Immich groups the timeline by **local** capture time, while its search filters on **UTC** `fileCreatedAt`.
Recomputing months from search results puts a photo taken at 00:30 on 1 March in a UTC+2 zone into February,
while Immich's timeline shows it in March. Any grouping logic we write ourselves is a chance to disagree with Immich;
using its answers means following it automatically.

Date groups inside albums, people and cities are computed from the folder's own Asset list, by each Asset's
`localDateTime`: the same ids the timeline's `albumId` and `personId` buckets return, without a second round of
requests, and cities have no timeline filter anyway. Day folders in busy months work the same way, as Immich's web
timeline draws its day headers from `localDateTime`. That is Immich's rule, applied to Immich's values.

**Not chosen:** months from the first seven characters of `fileCreatedAt` with UTC search ranges, which is wrong
at month boundaries.

#### Favorites and the archive

Favorites and Archive are sections like People: one search each, fetched in pages of 1,000, whose year and month
folders reuse the one list. Each asks what Immich's own page asks for (SPEC.md, "Membership: Immich decides"). A
read-only API key may ask for both: only `visibility {ne: archive}` needs elevated permission.
- **Off by default,** because many libraries hardly use them, and a folder nobody opens is clutter.
- **Date groups always** (`grouping.favorites`, `grouping.archive`): both mostly grow, and with `atLeast500` every
  path in one would change the day it reached 500 Assets.
- **The cost** is that a first visit waits for the whole list, since a listing must be complete: 5,000 archived
  photos are five requests, 30,000 are thirty. A large album costs the same.
- **Not chosen: Photos' layout,** from Immich's buckets (`isFavorite=true`, `visibility=archive`), a month at a
  time. It keeps a first visit cheap at any size, but needs its own folder kinds and change tracking per month;
  worth it only for tens of thousands of favorites or archived photos.

#### Names

The rules are in SPEC.md, "Names". FUSE needs unique, stable names, and Immich provides neither: shots in the same
second, `IMG_0001.JPG` from two cameras, two people with the same name, and free-text album names all clash.

**Files are named by date and time by default** (`2024-03-15 14.32.07.jpg`), the local capture time Immich's
timeline uses: camera file names (`IMG_1234`) are counters Immich hardly shows, while date-time names sort
chronologically in every folder and give copies meaningful names. Dots stand for colons, which are invalid on exFAT,
NTFS and SMB and which Finder shows as slashes (Dropbox's camera uploads do the same). Original names remain a
setting.

**Clashes get a counter, assigned in upload order and remembered** (`-1`, `-2`). The Asset uploaded first keeps the
plain name, so a new duplicate never takes an existing one, and assigned names live in the metadata store, so a
counter never moves to another Asset while its holder exists; deleting one leaves a gap (principle 8). A fresh
installation computes the same names from server data, but for gaps deletions left. Comparison is case-insensitive
after NFC normalisation, so copies to exFAT, NTFS or macOS volumes do not collide, and an NFD name from an iPhone
matches its NFC twin.

**Not chosen:**
- **Milliseconds in the name.** Most cameras and all screenshots record only whole seconds, so bursts would still
  collide, and names would sometimes carry milliseconds and sometimes not.
- **Counters recomputed on every listing.** Deleting one Asset would renumber the rest, so a path could open a
  different photo than yesterday. Remembering the assignment is what makes counters safe.
- **An id suffix** (`IMG_0001 (3f9a2c1b).JPG`): stable, but noisy.
- **Leaving clashes to the platform.** The File Provider renames by arrival order, and FUSE has no such mechanism.

#### The metadata store

redb, a pure-Rust embedded database with crash-safe transactions, one database per account, holding:
- listings with their fetch times
- Assets and their Appearances, with the names assigned to them
- the change cursor

The seeded-thumbnail ledger is the exception: a plain list of URIs beside the store (`seeded-thumbnails`), appended
as seeds are written. `verso-service logout` must read it to clean up, and a plain file can be read while the
daemon holds the database's lock, or after a crash left the database unreadable.

Why: FUSE forgets everything at unmount, and Linux has nothing like the File Provider framework's own database of
items, which lets Finder show folders at once after a reboot; the store does both jobs. Folders still open after a
restart when the server cannot answer in time, listings work offline, assigned names stay stable, and writes are
incremental. A folder's first visit after a restart still waits for the server when it answers (ROADMAP,
"Performance": "Kept listings at once after a restart").

The store carries a format version and is migrated in code, with tests.

**Not chosen: SQLite** (`rusqlite` with its bundled C library). Everything stored is key-value shaped, and compiling
SQLite's C for every target would complicate the static builds and the macOS check of the portable core, which
matters more than inspecting the store with SQLite's command-line tool.

#### Freshness

The kernel caches whatever it is told to, for as long as it is told. inotify never sees changes that originate on
the server, so freshness is our job:

1. **Stale-while-revalidate.** A listing older than its window is answered at once, and fetched again in the
   background; the next visit shows the fresh one. A listing the change poll forgot, because Immich changed, is
   fetched before the folder answers, so a known change is never answered stale.
   Nothing is pushed to the kernel (`notify_inval_entry` and the like): its timeouts are short (60 s), the daemon
   answers every `readdir` itself, and Files would not redraw on a push anyway. Files watches an open folder with
   inotify, which sees nothing of a change made on the server, so F5 or entering the folder again shows it.

   | What | Window |
   |---|---|
   | Root, timeline, years | 5 min |
   | Current month | 1 min |
   | Older months | 1 h |
   | Album, person and place lists and contents | 10 min |
   | An Asset's attributes | 24 h |

   Kernel entry and attribute timeouts are 60 s for folders and files alike, so a name freed by a deletion and given
   to another Asset stops pointing at the old one quickly (principle 8).
2. **The change feed** depends on the credential:
   - **A session** (browser or password sign-in) follows `/sync/stream` with acks. It gets exact, resumable deltas,
     including permanent deletes and album membership, so the mount is close to live.
   - **An API key with the `all` permission** can use the websocket (`/api/socket.io`, key in the `x-api-key`
     header), which sends `on_upload_success`, `on_asset_update`, `on_album_update`, `on_asset_trash`,
     `on_asset_restore` and `on_asset_delete`. Each event refreshes the folders it touches.
   - **A scoped API key** can only poll. ETags on `/timeline/buckets`, `/timeline/bucket` and `/albums` make that
     cheap: a 304 when nothing changed. `/sync/*` refuses every API key, and the websocket refuses scoped keys.
     Asset fields alone cannot track changes: adding an Asset to an album leaves its `updatedAt` alone, and a
     permanent delete leaves no trace but a missing id.

   The feed is chosen automatically. The freshness windows always stay on, as the safety net for connection gaps.

   **Built so far: ETag polling for every credential,** every 10 seconds: `/timeline/buckets` and `/albums` with
   `If-None-Match`, so an unchanged library costs two 304s. A month whose count changed, and an album whose count
   or update time changed, are forgotten, with the folders above them; the next visit (or F5 in Files) reads them
   again. Swaps that keep a month's count are left to the freshness windows.

   **Shown Favorites and Archive are polled too,** each while it is on: `/timeline/buckets` with `isFavorite=true` or
   `visibility=archive` and `If-None-Match`, one more 304 while nothing changed. When a section's month counts change,
   its folders are forgotten. Without it, any month change would have to touch the archive, so every upload would read
   it all again (at once on macOS, whose poll lists changed folders again itself), and marking a favorite changes no
   timeline count at all. A section switched on starts by taking note, as a first poll does.

   **Sessions also follow the sync stream** in the same poll (`AssetsV2`, `AlbumToAssetsV1`): a changed Asset marks
   its month, album membership marks its album, and a permanent delete or a reset refreshes every folder, since its
   place is unknown. The first stream of a run only sets the baseline and is acked. On a large library that first
   stream is the whole library, so it is read over several polls: each reads it for at most 15 seconds, the baseline
   is acked every 5,000 records, and running out of time is not counted as being offline.

   **Not chosen, for now: the websocket for `all` keys.** With every credential polled every 10 seconds, a change
   already shows within seconds; the websocket would save those seconds for one kind of key, at the price of a
   socket.io client and a second connection to keep alive. Parked in ROADMAP.
3. **Our own uploads** invalidate the affected folders at once.

#### Directory listings are complete

FUSE has no paging towards the kernel: a listing is complete or it is wrong. A large album is fetched in full
(about 1,000 per page) before its first `readdir` answers. Date groups keep the visible folders small, and the
metadata store makes later visits instant.

### Content: blocks fetched with range requests

Originals are fetched in 2 MiB blocks with HTTP range requests, and kept as one sparse file per Asset plus a block
map beside it (`<id>.blocks`, a line per block), which survives restarts:
- **Single flight:** each folder listing, content block and Asset's edges (below) is fetched once, however many FUSE
  calls wait for it, and an Asset's server thumbnail once, however many folders being seeded want it (then kept on
  disk by Asset id).
- **Read-ahead:** sequential reads widen a read-ahead window from 2 blocks to 16 (32 MiB); random access resets it.
  It runs below reads someone is waiting for (two fetches at once), and only after 4 MiB of sequential reading, so a
  program peeking at a header (a type sniffer, a thumbnailer) never pulls a block.
- **Peeks are served from the edges.** A peek is a read into bytes the cache does not hold, in a run of reads that
  stays within 64 KiB, of a file larger than that; past 64 KiB of run, reads fetch whole blocks. A peek within an
  original's first 64 KiB or last 16 KiB fetches both at once (two requests, 80 KB) and keeps them as the Asset's
  edges (`<id>.edges`), which count towards `cache.limit`, go with the Asset's blocks, survive restarts, and carry a
  checksum instead of being synced (a torn one is merely fetched again); any other peek fetches exactly its range and
  caches nothing.
  - **Why:** Bazzite's file managers load rom-properties, which reads the first 8 KiB and last partial page of every
    file in a folder they show, one after another, from their main thread (the `lab-bazzite-vm` skill, "Traps").
    Whole blocks per peek fetched every original whole; edges fetched one by one as read cost a round trip each on
    Files' main thread, 7 to 9 s for a month of 450 photos, against under a second with the prefetch.
  - **The prefetch:** once a program has peeked at three files of one folder within 10 s, the edges of the rest of
    the folder, up to 1,000 files (80 MB), are fetched ahead of it, eight files at a time; a single peek (a properties
    dialog) prefetches nothing. It is the one place the mount fetches bytes no program has opened yet, against the
    letter of principle 2: never an original, only the ends of files a program is reading one after another and
    reaches within seconds; whether the principle should say so is open (ROADMAP, "Performance"). rom-properties
    after 2.9 skips unknown FUSE filesystems as remote.
- **Crash safety:** a block counts as present only after it is written and synced, so a crash never serves zeros.
- **Validation:** the block map records the original's size and its weak ETag (`W/"<size>-<mtime>"`, the same for
  every range). Another size in a listing, another ETag on a block or a range shorter than the size allows drops the
  cached blocks and lists the folder again; a read that overlapped the change reads again. An Asset's block writes
  take turns, and the map is emptied and synced before the data file, so a crash never lists old blocks over an
  emptied file. An original replaced at the same size with every block cached goes unnoticed until a block is
  fetched again, since nothing is asked of the server.
- **Page cache:** files are opened with `FOPEN_KEEP_CACHE`, so repeated reads never reach the daemon, unless the
  cache dropped the original's blocks since the last open: then the kernel's pages go too.
- **Eviction:** whole Assets, least recently used first, past `cache.limit` or once the disk is down to its last
  tenth. Free space is asked of the platform (`statvfs` on Linux) at most every 30 seconds: btrfs shows freed space
  only after a commit, so asking after every eviction would evict ever more. An Asset being read is pinned; an idle
  open file can be evicted, and its next read fetches again. Offline albums, if built (ROADMAP), would be exempt.
  Server thumbnails (`server-thumbnails/`) are not counted.

**Trash checks.** `open` never waits. If an Asset's active state has not been checked recently, `open` starts a
background check, and the result applies to later reads.

**Concurrency** is bounded per kind of work: listings 4, thumbnails 8 to 16, content 4, uploads 2, over one HTTP/2
connection pool. *(Built so far: thumbnails, 12 small for a folder being shown, 4 for folders seeded ahead and 4
previews, each with its own budget so the background never holds up a listing; listings started by probes, 4; edge
prefetches, 8, since the server answers small ranges about three times faster eight at a time than one at a time.)*

Why blocks:
- **Many readers touch only part of a file:** content-type sniffing reads the first KB, EXIF readers read the
  header, and video players seek. A whole-file cache would download a multi-GB video because something wanted
  64 KB of it.
- **Immich answers range requests** byte-exact for images and videos, HEAD included.

Two quirks are handled:
- multi-range requests return the whole file, so only single ranges are sent
- a range past the end returns 404, not 416, which means our size is stale

`If-Range` works on the server, but HTTP forbids weak ETags in it, so it is not relied on. Whole-file download
remains only as the fallback for a server that refuses ranges.

**Never hang.** Every task that answers a FUSE request has a deadline:
- listings: about 10 s, then an older listing if there is one, else `EIO` (the fetch continues for the next visit).
  A listing that ran out marks the server silent for 30 s, and listings then wait at most 1 s: rom-properties (on
  Bazzite) probes every folder Files shows from Files' main thread, so at 10 s a name a server that drops requests
  would freeze Files for minutes. A probed name (SPEC, "Files the mount answers") waits for nothing: it is answered
  from the listing at hand, however old, or absent at once and not remembered, while the folder is listed in the
  background (four at a time, as a folder of hundreds of albums is probed album by album). The mount tests
  (`linux/verso-linux/tests/mount.rs`) hold this against a library whose listings never answer.
- reads: 30 s without progress, then `EIO`
- uploads on close: their own limit (Uploads)

The FUSE session thread never blocks. Handlers answer from memory, or move the reply object into a tokio task.

### Uploads

**One folder takes new files: `Upload`, at the root.** Every other folder is a read-only view built from the
library's metadata (SPEC.md, "Uploads").
- **Not Photos and its date folders:** a date folder is computed from each photo's own date, so a drop into
  `2024/03 March` suggests a placement that cannot be kept; and a copy pasted beside its source (Ctrl+C, Ctrl+V)
  adds nothing to Immich and would leave a name that cannot be deleted. In Upload such a paste says so in a
  notification and leaves like any upload.
- **The lock** (`access()`) then reads simply: everything is read-only but Upload, and uploads do not depend on the
  Photos section being shown.
- **Flatpak impact:** none; it is the mount's own layout.

**The upload runs inside FUSE `FLUSH`, which is what `close()` waits on.** `close()` succeeds only after the server
has the file, and GIO checks the destination's close before deleting a moved file's source, so a move never loses
its source early in a program that checks `close()` (principle 6). KIO, Dolphin's file layer, does not: it counts the
permissions it then cannot set as a mere warning and deletes the source of a move whose upload failed, hence the
not-uploaded folder (below). The cost: Files' progress bar sits at 100% during the upload (a notification covers long
ones), and the kernel cannot interrupt a `flush`, so a program killed while its close waits stays until the upload
ends. The wait is bounded: 30 minutes in total and 2 without progress, temporary failures retried with backoff inside
that. *(Built so far: the 30-minute limit, and the client's own brief retries.)*

**Not chosen:** uploading after `release`, which returns at once: the kernel discards release errors, so failures
would be invisible and moves could lose files.

**What is accepted:** image and video files judged by extension against the server's media types (RAW included),
from `/server/media-types` at start, with a built-in list when the server cannot be asked; a refused extension fails
at `create`, before any bytes are copied. Folders are taken ("Folders copied into Upload", below).

**The upload sequence:**
1. Stream SHA-1 over the staging file.
2. `POST /assets/bulk-upload-check`. A trashed duplicate is restored (`POST /trash/restore/assets`) with no upload
   (the maintainer's choice): copying a photo into Upload is the plainest way to say it is wanted, and it comes back
   as it was, its date, albums and faces. Restoring needs `asset.delete`; without it the upload fails, saying so.
   **Not chosen:** refusing, which keeps a deletion standing against the copy's plain wish; asking in the album
   question, one more choice in one dialog.
3. A streamed multipart `POST /assets` with `assetData`, `fileCreatedAt` and `fileModifiedAt`. `fileCreatedAt` is
   the capture date, falling back to the mtime, then to now. *(Built so far: the staged file's mtime at close; the
   client does not parse EXIF, since the server does. GIO may set the source's mtime only after closing, so a file
   without its own date is filed under the copy time.)*
4. 201 is a new Asset, and 200 `duplicate` is Already in library, or restored from the trash.

A lost response is retried safely: the checksum turns a second upload into a duplicate, not a second Asset.

**Details that need care:**
- **Upload once per round of writing, from a writer:** `flush` runs on every close of every descriptor, readers
  included (a thumbnailer). Each `open` gets a handle that knows whether it may write; only a writer's close starts
  an upload, a close during one waits for its result, and a close after a failed one gets the failure. A handle
  opened before an upload cannot write after it (`EIO`); a fresh open is a new round.
- **Cut-short copies are refused:** a writer killed by a signal (`PF_SIGNALED`) does not upload, and every file's own
  structure is checked first (`verso_core::uploads::completeness`: each format's end marker, declared length or
  index, data appended after a whole image allowed). A cancelled copy in Files closes the file before deleting it, so
  this check is what keeps it from becoming an Asset. What cannot be judged uploads: MPEG transport streams, and
  Matroska written live, which declares no size.
- **Temporary names:** GIO's `.goutputstream-XXXXXX` and rsync's `.name.XXXXXX` are staged and upload under their
  real name. GIO renames before closing, so the close uploads and the folder is never locked for an upload; rsync
  renames after closing, so its rename uploads, holding the folder's lock meanwhile. Any hidden name that is not a
  photo (`.IMG_1.JPG` is) is refused, so nothing is staged and then silently dropped.
- **Receipts:** the written name stays about 10 seconds, because GIO, KIO and rsync set its times (GIO its mode
  too) right after closing it; deleting it changes nothing in Immich, and writing to it again is a new upload.
- **Free space:** `statfs` reports the staging filesystem's, so the file manager's space check means something.
- **Kernel request timeouts:** since Linux 6.14 the kernel aborts a whole FUSE connection when one request outlasts
  `fs.fuse.default_request_timeout` (off by default), an upload in `flush` included. So the daemon reads the limit at
  mount, warns once, and ends every wait of its own a second before it: a longer upload fails its `close()`, a read or
  a listing fails with `EIO`, and the mount survives; `doctor` reports the setting. **Not chosen:** a longer limit of
  our own (`FUSE_REQUEST_TIMEOUT` in the init reply), which fuser 0.18 cannot send; worth adopting once it can.
- **Unmounting during an upload** fails with "target is busy" while a writer holds the file; once `close()` has
  returned, the upload is finished.
- **After a failed upload,** the staged file is moved to `~/.local/share/verso/not-uploaded/` once its last handle
  closes, never deleted: a program that ignores `close()`'s error (KIO's move) has deleted its source by then. Staging
  files a dead daemon left are kept the same way at the next start, named from the name file beside each. Only what
  the user dropped is deleted (SPEC.md, "Uploads").
- **Flatpak impact:** the folder follows `XDG_DATA_HOME`, which a Flatpak maps into its own data directory; the
  notification names the real path either way.

#### Folders copied into Upload

A folder copied into Upload uploads every photo and video in it as it arrives, and once the copy has settled its
folders may become albums named by their paths (SPEC.md, "Folders copied into Upload").
- **Uploads first, the overview after.** No file manager says a copy is coming (Files, Dolphin and Finder send a
  folder one file at a time), and each upload runs at its file's close so a move keeps its source until Immich has
  it (principle 6). Immich adds an Asset to an album at any time, so the albums come out the same. **Not chosen:** the
  whole overview before any upload, which would hold every close until the last file arrived, or let a move delete its
  sources first.
- **Settled** is nothing new for 5 seconds (the maintainer's choice) and nothing in the copy being
  written or uploaded, so a slow copy or a long upload never counts as finished early. Linux looks every 2 seconds;
  macOS's extension looks again just after the settling time following each upload. A copy that pauses longer
  (Files asking about a file Immich does not take) may be asked about early, and what arrives after joins it. A copy
  with nothing uploaded yet waits for its first photo, since Files may ask before it, and is forgotten after 10
  minutes without one.
- **One portable record** (`verso_core::folder_uploads`: the copies, their folders' paths with the Asset ids uploaded
  in each, each copy's state and the albums made), plain data: macOS keeps it in its store, as the system
  stops the extension between requests, and Linux in the account's cache, written at once after an answer and after
  each step of album work, so a restarted daemon asks again what it was asking (closing its old notification, whose
  buttons would answer nobody), and asks nothing twice.
- **Album work records each step as it happens,** the name chosen before the album is made, so work done again finds
  its album by that name and the folder's first photo and no second, dated album follows. Only an unreachable or busy
  server is tried again. On macOS the work runs in a task of its own, not in the poll, which the system cancels once
  it stops waiting, leaving the work half done.
- **Names:** the path joined with ` › `, which reads the same in Immich and in the mount's Albums folder (a `/` would
  show as `_` there; SPEC.md, "Sanitising"). A taken name gets the day's date, then a counter (the maintainer's
  choice): it says when, where `Trip 2` says nothing. **Not chosen:** adding to an album of that name, which mixes a
  new trip into an old one; refusing folders inside folders, which the path names make unnecessary.
- **One album per folder that holds photos,** with only its own: the timeline has them all, and a parent's album
  would repeat its children's.
- **The question needs an answer, so it is hard to miss:** a plain notification is not (GNOME files one straight into
  the message list while another is on screen, and on the Mac it is easily ignored).
  - **On Linux** the daemon asks with an urgent notification, which GNOME and Plasma keep on screen until a button is
    pressed, over one session connection that both shows it and hears `ActionInvoked` (the desktop sends it to the
    connection that showed the notification). The connection is made when the first question is due, since the user
    service often starts before the desktop serves notifications. The notification's `default` action answers
    nothing and asks again: without it GNOME closes the notification as dismissed, which reads as Timeline Only. GNOME
    shows the body on one line, so its parts are set apart with ` · `. **Not chosen:** a dialog, which the daemon has
    no window for, or Verso's window, which may not be open.
  - **On macOS** the extension can show nothing, so the app asks; Verso's app does not ask yet (ROADMAP, M8, "Verso
    Drive"). The question it is to ask: a dialog floating above other apps until one of its two buttons is clicked,
    neither answering to a key, so it is never answered by someone typing elsewhere; and asking never waits on the
    notifications that tell what came of albums, whose permission prompt would hold up every later question. Copy
    numbers start from the time in a new store, so an answer meant for a copy before a sign-out never reaches a later
    one. **Not chosen:** a notification with buttons, which Notification Center and Focus hide away.
- **Timeline Only is the way out, and a change of mind is another copy:** by the time it asks, the photos are in
  Immich, so the only choice left is whether albums follow; copying the folder in again costs nothing, since Immich
  recognises what it has. **Not chosen** (the maintainer's choice): a Cancel that takes the uploads back;
  the mount never deletes from the library (principles 4 and 5), and it would take photos that were in Immich before.
- **On macOS the question passes through files** in the App Group's `Library/`: the extension writes the questions
  after each poll, the app each answer to a file of its own, which the extension takes and removes, and the extension
  leaves a file per album outcome for the app to tell. Only the extension opens the store (redb allows one process),
  and with a file per answer neither side rewrites what the other wrote. The bridge has the app's side
  (`folder_questions`, `answer_folder_question`, `take_folder_notices`).
- **Folders in the system's terms (macOS):** a copied folder is an item of its own (`upload-folder|Trip|Day 1`), kept
  in the store and listed in its parent and the working set until it leaves. It leaves 20 seconds after its last
  file, once it holds nothing the extension knows of and nothing in macOS's pending set, read before each poll:
  Finder may still be writing a large file into it, which the extension hears of only once it is whole, and taking
  the folder from under it would fail the copy. It stays at least as long as macOS takes to bring that set up to date,
  and 10 seconds more; where macOS does not say within 5 seconds, or says its list is full, 10 minutes. **Not
  chosen:** 10 minutes always, which leaves empty folders long enough to puzzle (the maintainer's choice). Upload and
  the copied folders accept changes to their times and keep them as they are: refused, the system marks Upload as
  failing and retries without end. Finder's `.DS_Store` is no photo and keeps no folder.
- **Folders on Linux** go per copy, not folder by folder, once none of the copy's folders holds a file and nothing
  arrived in any for 5 seconds: Dolphin and rsync make every folder of a copy before its first file, so a folder
  waiting its turn would go while the copy is busy elsewhere. A gone folder is remembered for 10 minutes, unseen, and
  a path lookup brings it back, since Files stops at a file Immich does not take until someone answers Skip All, and
  the rest of the copy would fail with "No such file or directory". **Not chosen:** showing the empty folders for those
  10 minutes (the maintainer's choice, as on the Mac). A file that did not upload is kept under its folder's path in
  `not-uploaded/`, so two `IMG_0001.JPG` from two folders stay apart, and no name leads out of that folder. Times and
  modes set on a folder (`cp -a`, GIO) are taken and ignored, as a staged file's are.
- **Settings:** `uploads.folders` (ask, timeline only, albums) is the Upload section's own row under its switch in
  Verso's Preferences on Linux, and in the Mac's Settings under Verso Drive, Names and Uploads.
- **Flatpak impact:** the question needs notifications with buttons and their answers: a Flatpak would call the
  Notification portal (`AddNotification`, and its `ActionInvoked`) in place of `org.freedesktop.Notifications`. The
  record follows `XDG_CACHE_HOME`.

### Links to Immich

Open in Immich and Copy Immich Link take an item from the file manager to its page in Immich's web app (SPEC.md,
"Links to Immich").

- **The map is in the core** (`shared/verso-core/src/links.rs`): a key to its Immich path, the path to a web address
  and to a crosslink (ROADMAP.md, "Open in Immich, and links between apps"). Every platform asks it, so an item gives
  the same link in Files, Finder, the gallery and the terminal, and the tests cover it once.
  - **The key is enough:** an Asset's key holds the folder it is listed in (`asset|<folder key>|<id>`), so a photo's
    link keeps its album, person or city without asking Immich anything.
  - **Immich's own paths, not ours:** they are what Immich's web app and its mobile app's deep links already take,
    and they are Immich Crosslink's, so one map serves the browser and the other apps.
  - **The search is Immich's JSON byte for byte** (`JSON.stringify`, then `encodeURIComponent`), tested against what
    a browser writes. The country is added to a city's search, which Immich's Places page leaves out, because the
    folder knows it and two cities of one name differ.
  - **Folders without a page have no link,** rather than the nearest page: a month folder's link opening the whole
    timeline would look like a failure.
- **Reading links back** is in the same module: a crosslink reads to one of Immich Crosslink's three results (show,
  cannot show, invalid) before anything is fetched, and a web address on the signed-in server to its item. The
  protocol's own test links (`shared/verso-core/tests/crosslink-links.json`, copied at the commit its test names) run
  as they are.
- **Each platform's part:** on Linux the service answers the Files extension's menu and receives crosslinks for
  Verso Drive (Linux, "Links on Linux, and the Files extension"); on the Mac, Verso Drive's extension offers Finder's
  actions ("Verso Drive on the Mac", "Finder's actions"). The gallery reads and makes links with the same map on
  Linux (`verso_core::links`), and with its own Swift (`Crosslink`, from Immich Gallery) on the Mac.
- **Not on the iPhone and the iPad,** for now (the maintainer's choice): iOS lets no app list the others, several
  apps that register `immich-crosslink:` get its links as iOS picks one, and no iOS app sends crosslinks. So Verso on
  iOS registers no crosslink scheme, never taking a link it would not show, and offers Open in Immich and Copy Link,
  which work there. It comes back with an iOS app to link with, which would need a scheme of its own.
- **Show in _app_** offers an item to the other apps that take part in Immich Crosslink, each found by its platform's
  own means (Linux, "Links on Linux, and the Files extension"; the Mac, "Finder's actions"), by the same rules
  (SPEC.md, "Show in other apps"):
  - **Off is the lasting choice, and Forget is for an app not found,** as pairing works, with pairing automatic. An
    installed app is found whether or not it ever started, from the announcement installed with it (on the Mac its
    Info.plist, the only thing one sandboxed app can read of another's), so an entry is either there and switched
    off, or Not found, where Forget clears it. An app not found stays listed for 30 days so one switched off stays off
    when it comes back, and then ages out (test apps, uninstalled ones). It reads **Not found**, not "not installed":
    it may be installed and not announcing, a deleted copy Launch Services still lists, or out of a sandbox's reach.
    What was seen is state, not a setting, as the protocol leaves to each app.
    - **Not chosen: Forget on every app:** an installed app is found again at once and comes back switched on, so
      Forget would seem to do nothing, and on an app switched off only turn it on.
  - **No app set apart.** Verso offers and names only apps that announce themselves, whoever made them, so the
    protocol it publishes is the one it follows. Immich Gallery is one participant among them.
- **Web links can be switched off** (`web.links`), apart from Immich Crosslink, as the protocol asks of every
  participant: the daemon leaves the web address out of `Links` and `WebLink`, and the menus offer Show in *app*
  alone. One switch for both items, since one opens the address the other copies.

### One layout for every settings window

**The settings have one place each, decided once, and Linux and the Mac draw the same pages each their own way.**
- **One settings table:** every setting is in the core's table (`verso_core::settings`), the same one behind
  `verso-service configure`, so the windows and the command line never disagree about which settings exist or what
  values are valid. Verso's own defaults are the table's.
- **The places:** the core's `settings::PANES` gives each setting its pane: General, Folders, Other Apps, or the
  command line only, and a test fails when a setting has no place. `verso-desktop`'s `PAGES` says how the Linux pages
  read (groups, rows, which setting a section shows with its switch), and a test fails when a page shows a setting
  its pane does not place there, or leaves one out. The Mac's Settings window is tested against the same places, less
  what means nothing on a Mac.
- **On Linux the drive's pages are pages of Verso's Preferences,** in its sidebar under Verso Drive (Status, Drive,
  Folders), shown while the drive is on, beside Verso's own (Verso's window, "Preferences"): a sidebar, as GNOME
  Settings has, has room for many pages, where a view switcher fits two to five. On the Mac, Settings has a Verso
  Drive pane ("Verso Drive on the Mac", "Settings").
- **What is out of the windows:** the server (set by signing in), the apps left out of Show in (each app's own
  switch), the headless credential file, and `thumbnails.safety_net`: off, a thumbnailer may download every original
  it is shown, gigabytes for icons, and no one could judge that from a switch; it stays in `config.toml` and
  `verso-service configure`. Verso's windows also leave out what Verso has no use for (`Product::hidden_settings`:
  `mount.at_login`, since the service starts at login while signed in, and `updates.check`), and show Verso's own
  settings (the drive's switch, the tray's, the Crosslink switches) on its own pages.
- **Each setting as the platforms show its kind:** a section's switch and its date folders together, a folder in the
  system's folder chooser, and the cache's size as a choice of 5, 10, 25, 50 and 100 GB, in decimal units, as Files
  and Dolphin count; a size set by hand in `config.toml` shows as itself.
  - **Not chosen: a slider** for the cache: snapped to steps it is a list without the list's clarity, and free it
    gives sizes like 13.7 GB; neither platform's slider shows its value by itself.
- **The daemon reads its settings as it starts,** so the window restarts it once the user leaves a page where
  something changed, or closes the window, rather than at each switch.
- **Not chosen: a Preferences dialog generated from the table:** one long page in the table's order, its descriptions
  as labels and internals beside choices, growing with every setting.

### The date scroller

**One arithmetic places a timeline's date scroller on every platform** (`verso_core::rail`, the maintainer's
choice): Linux's scrubber (`scrubber`), the Mac's rail (`TimelineRail`) and the iPhone's pill (`DateScroller`) ask
the core where each month is, which years to label, the month at a point, and the exact place in the grid a point
stands for, and back. The Mac and the iPhone call it through the bridge (`rail`: `date_rail`, whose `DateRail`
answers for one layout of the grid, and `months_are_dated`); `DateRailCache` in `VersoCore` makes it again only when
the months, the layout or the part in view change, as the scroller draws again on every scroll.
- **Layout-true:** a month takes the room the grid gives it, its header and `ceil(count / columns)` rows, from the
  months' photo counts, so a month not loaded yet takes its true room. Where months flow on in the same rows without
  headers (the iPhone), a month's rows are those that start with one of its photos, and a month whose photos all
  share a row with others takes none. Each platform gives the core its grid's columns, row height (with the space
  below it) and header: the Mac's square cells and 50-point headers, Linux's rows and 52-pixel headings, the iPhone's
  tiles and no headers.
- **A point is a fraction of the grid's scrolling,** from its top in view (0) to its end in view (1). The scroller
  stands for the grid's height less the part in view, so a drag down the whole scroller goes through the whole grid
  and the mark stays under the pointer to the end. The months of the last screen share the scroller's foot, as the
  grid cannot bring them to the top; a grid that fits in view spreads its months over the whole scroller.
- **A click or a drag lands where it points,** partway into a month as readily as at its start: a point is a month, a
  row in it (or its header) and how far into that. The iPhone and the Mac scroll to the point
  (`GridScroller.scrollTo(y:)`, `PhotoGridScroller.scrollTo(monthsY:)`; "The photo grid on the Mac"), Linux to the
  row. A drag scrolls again only when the place reaches another point
  (another row, where rows are the unit). The mark comes from the grid's own offset, or its first row in view, through
  the same arithmetic. On the Mac a click on a year's label, below its tick, goes to the year's first month; a drag
  over it does not stop there.
- **The years** are labelled where they begin, at their oldest month (their January, where the library has one), so
  the newest photos' year is never read as Now. They are taken from Now outwards, so the labels are the same whichever
  end the newest photos are at. The newest photos' year is always labelled (the maintainer's choice): where it began
  nearer to Now than a label's room (the Mac's 34 points, Linux's label and two pixels, the iPhone's 24 points), its
  label goes just past Now's, so a short track never leaves it out. An older year nearer than that to the year before
  it is left out.
- **Now** marks the end with the newest photos, as Immich's scroller does (the maintainer's choice): the top where
  the newest come first, the foot where they come last. The core finds that end from the order of the months.
- **A drag ticks at each month it crosses,** none as it starts: the iPhone's pill with the selection haptic, the Mac's
  rail with a Force Touch trackpad's alignment tick (`NSHapticFeedbackManager`), which other trackpads and mice do not
  give. Linux's scrubber has none.
- **Not chosen:** months placed by their photo counts alone: a month of a few photos still takes a header and a row,
  so such a scroller drifts from the grid, most where months are many and small. Nor landing at a month's start, from
  which a long month can never be entered partway.
- **Flatpak impact:** none; the window's scrubber reads nothing new.

## Linux

On Linux, Verso is two programs from one package, made for GNOME: the window (`verso`) and the service
(`verso-service`). Their code is in `linux/`: the two programs' crates, `verso-desktop` and `verso-linux` beneath
them, the Files extension (`linux/files-extension/`) and the packaging (`linux/packaging/`).

### The window and the service

```
 Files, file dialogs, players ──▶ kernel FUSE (~/Verso, shown as "Verso"), while Verso Drive is on
                                         │ /dev/fuse
 ┌───────────────────────────────────────▼─────────────────────────────────────────┐
 │ verso-service daemon     systemd user service, no display and no toolkit needed │
 │   FUSE adapter ─▶ tree (names, inodes) ─▶ metadata store (redb)                  │
 │        ├─▶ content cache (blocks, range reads)    thumbnail seeder ─▶ ~/.cache/thumbnails
 │        └─▶ upload staging ─▶ uploader                                            │
 │   change feed (sync stream / polling)   D-Bus service   tray   notifications     │
 │   immich-api (reqwest, tokio) ──────────────────────────────────────────────────┼─▶ Immich
 └───────────────────────────────────────▲─────────────────────────────────────────┘
                                         │ session D-Bus (status, ShowLink, CheckNow)
 verso (GTK 4 + libadwaita): sidebar, grid, viewer, Preferences (the drive's pages too)
   verso-desktop: the library, layout, pictures, actions, sign-in, the credential, drive status
   immich-api ─────────────────────────────────────────────────────────────────────▶ Immich
```

**The service** (`verso-service daemon`, run by the user service `verso.service`) owns the tray and, while Verso
Drive is on, the mount, the metadata store, the caches, thumbnail seeding and uploads. **The window** (`verso`) is the
gallery: it reads and changes the library through `immich-api` itself, signs in, and shows Preferences, the drive's
status and settings among them. Closing it never stops the drive or the tray.

**One package, two programs:** one install and one version, one app, one tray icon, one Preferences and one sign-in.
The service runs from login while signed in: the tray, and the drive when it is on. Why two programs:
- **The drive must outlive the window.** When the program behind a FUSE mount ends, every program with a file open on
  it gets "Transport endpoint is not connected" and the mount must be undone by hand; a stalled FUSE process freezes
  everything that touches the mount (Files, file dialogs, shells).
- **The window is the code that changes fastest,** and a crash there must not take the drive with it.
- **The drive must not depend on a display or on GTK.** The service loads no toolkit (`verso-linux` has none), so it
  runs headless too, and systemd restarts it and starts it at login with no window.

The cost is a D-Bus interface (SPEC.md), which also gives the command line for free. **Not chosen: one process,**
FUSE and the tray inside a GTK window kept running: it puts the mount at the mercy of a display session and a toolkit,
in the one process that must never hang, and rewrites the daemon's life around GTK's main loop for nothing a person
sees.

- **Its names come from one place** (`verso_core::product`), first thing in each program: its folders, keyring items,
  D-Bus name, user service, program, tray, notifications, translation domain and the drive's defaults (SPEC.md,
  "Files on disk" and "The daemon's D-Bus interface"). The switch knows Verso, Verso as a Flatpak (`VERSO_FLATPAK`),
  and Immich Mount (`IMMICH_MOUNT`), described only so Verso can read its settings and keyring to take its account
  over ("Taking Immich Mount's account over"); nothing runs as it. No name is shared, so Immich Mount and Verso can be
  installed at once, both drives on; only the volume monitor's private fstab is one per session, so then one drive
  keeps its icon in Files ("The drive's icon").
- **Verso Drive is off until switched on** (`mount.enabled`, Verso's default `false`). Off, the service serves its
  D-Bus interface and the tray alone (`daemon::serve_without_drive`), takes the drive's bookmark and empty folder
  away, and the menus leave Show in Files out. The switch writes the setting and restarts the service, and the Status
  page reads Mounting until the drive is up. What Verso hides takes Verso's own value, whatever is stored.
- **Unmounting only unmounts.** Files' unmount button, and Unmount on the Status page or the tray's menu, leave the
  switch on, and the service goes on without the drive (the tray, the D-Bus interface), its bookmark and folder kept;
  **Mount** restarts the service, which mounts, and so does the next login.
- **Upgrades** close the old Verso and open the new one in its place (the service: "The daemon's lifecycle", step
  6). The window watches its own program the same way (`upgrade`), or, behind the tarball's launcher, the launcher, by
  the path the desktop starts it by (Homebrew's `bin/verso`; "Packaging"): replaced, it closes, once any import is
  done, and the new version opens on the page it showed (`verso:show:<page>`), started from a scope of its own once
  this process has gone, since one started sooner would hand itself to the old one and leave. Uninstalled, the window
  closes. Not from the cask: Homebrew runs a cask's steps in a sandbox (Landlock, no network, a home of its own), and
  what they start stays in it. A Flatpak is updated by Flatpak and runs on until closed.
- **One sign-in.** The window reads the server and the credential the service uses (`config.toml`, then the
  credential file or the keyring, as the daemon looks), and Sign Out signs both out through `verso-service logout`.
  Signing in stores the credential and starts the service (`session::start_service`); opening the window starts it
  again if the tray was quit (`session::wake_service`).

### The daemon's lifecycle

1. **Start:**
   - Read the config and the credential. A locked keyring brings up the system's unlock prompt.
   - Detach a stale mount left by a crash (`fusermount3 -uz`). Staleness is asked with `statfs`, which always reaches
     the daemon: `stat` of the root is answered from the kernel's attribute cache for a minute, and takes a dead mount
     for another daemon's.
   - Ask the server's version with a limit of its own, 10 s, not the client's retries, which last four minutes when
     the server drops requests, with the mount point an empty folder all along.
   - Mount, and answer from the metadata store at once; the server connection comes up in the background. *(Built so
     far: the daemon asks for the version and media types first, up to about ten seconds each, then mounts; listings
     kept in the metadata store answer offline.)*
2. **Server unreachable:** stay mounted. Serve cached listings and content, fail uncached reads fast, notify once.
3. **Eject from the file manager:** respected ("Unmounting only unmounts"); the daemon notices within two seconds and
   unmounts cleanly. Mount and Unmount on the Status page and the tray's menu, which matter where Files shows a
   bookmark with no eject button, run the command line's `mount` and `unmount`, so every way in takes the same steps.
4. **Server or account change:** refused while uploads are staged or in flight. Otherwise unmount, switch to the
   new account's cache namespace, and remount. Old namespaces are deleted.
5. **Stop** (logout, `systemctl --user stop`): finish or cancel in-flight work, then unmount cleanly.
6. **Upgrade and uninstall.** Homebrew, rpm and dpkg put a new file in a running program's place, and the daemon
   keeps its old file until it exits: left alone it would serve the old version against the new window until the
   next login, and after an uninstall keep the mount up and its service enabled, failing at every login. So the
   daemon looks every 5 seconds (`ProgramWatch`) at the path it was started from (`argv[0]`, absolute under systemd):
   - **A different file there** is an upgrade. The daemon leaves once nothing on the mount is open or uploading,
     with status 75: the unit's `RestartForceExitStatus=75` starts the new version, and `SuccessExitStatus=75` keeps
     it from counting as a failure.
   - **Nothing there for two minutes** is an uninstall; the grace is for a Homebrew upgrade, which removes the old
     version before it adds the new one. The daemon leaves once idle and disables the unit it runs in, named by its
     own control group, and takes away what points at a mount that will not come back, as `logout` does (Verso's
     Crosslink entries, the bookmark, the GVfs drop-in, the seeded thumbnails). The credential and the caches stay:
     an uninstall may be a reinstall.
   - **Not chosen: restarting from the packages** (`%systemd_user_postun_with_restart`, a postinst, a cask
     postflight): it restarts at once, with a copy into Upload in flight or a video open, and needs three channels
     to get right, Homebrew's steps running in a sandbox. **Flatpak impact:** none; Flatpak updates a Flatpak, which
     runs on until closed.

**The user service** is `verso.service` (`linux/packaging/systemd/verso.service.in`: `Type=simple`,
`Restart=on-failure`, and the exit status 75 of an upgrade), which the packages install. Where none is installed (the
tarball, Homebrew's cask, a build from source), signing in, the drive's switch and `verso-service mount` write it into
`~/.config/systemd/user`, running the `verso-service` they find, and start it, so nobody starts a service by hand.
They look first in the `bin` of the Homebrew prefix they run from, whose links survive an upgrade, never in one
version's folder. The service starts at login while signed in, drive on or not, so Verso hides `mount.at_login`. A
daemon that finds the mount already served by another leaves cleanly, so systemd does not restart it every few
seconds. **Flatpak impact:** a Flatpak cannot write that unit; Verso's Flatpak starts its service through the Flatpak
portal and asks the Background portal for login ("Verso as a Flatpak").

### Why FUSE

The library has to appear as real files to Files, to every file dialog, to sandboxed apps through the portals, and
to plain programs, with content arriving on demand. On Linux that is FUSE:
- **Every program sees real paths.** Flatpak apps reach files through the document portal, itself a FUSE filesystem.
- **No privileges, and no GNOME release cycle.** An unprivileged per-user daemon mounts through `fusermount3`, and
  the same mount works in KDE and elsewhere.
- **The kernel side keeps improving:** passthrough, io_uring transport, request timeouts.
- **The cost:** we own what the OS owns on macOS: the content cache, thumbnails and freshness.

Not chosen (GNOME integration says why): a GNOME Online Accounts provider with a GVfs backend, a Nautilus extension,
fanotify pre-content events, a sync folder.

### GNOME integration

- **Modes are what copies get; `access()` is what the mount allows.** Files are `0644` and folders `0755`, and the
  mount has no `default_permissions`: the daemon refuses each change itself, and answers `access()`, from which Files
  draws its read-only lock and greys out Rename and Move to Trash. Only the mounting user reaches the mount (no
  `allow_other`). A copy takes its source's mode bits, with `cp` and in Files alike, so read-only modes would make
  every photo copied out read-only, and every copied album a folder nothing could be added to.
  - **Not chosen: writable modes with `default_permissions`.** The kernel then answers `access()` from the modes, so
    Files would offer Rename and Move to Trash everywhere, show no lock, and each would fail.
- **The mount lives in home, at `~/Verso` by default,** where Files' sidebar shows a FUSE mount as its own volume,
  with a drive icon and an eject button; a mount under `/run/user` is invisible unless bookmarked. Its name comes from
  `/.xdg-volume-info`, with its full-colour icon; the sidebar's symbol comes another way ("The drive's icon").
  - **Except in a home reached through a symlink** (Fedora's atomic desktops and Bazzite: `HOME=/home/me`, `/home` a
    link to `/var/home`): GVfs's volume monitor (`should_include`) lists a FUSE mount under `$HOME`, `/media` or
    `/run/media/$USER`, comparing the kernel's resolved path (`/var/home/me/Verso`) with `$HOME` as written, so no
    mount in such a home is listed, sshfs and rclone's included. **The daemon gives the volume monitor the resolved
    home** as it starts: a drop-in for that one user service
    (`~/.config/systemd/user/gvfs-udisks2-volume-monitor.service.d/verso.conf`, `Environment=HOME=/var/home/me`), then
    a restart of the monitor, which a running Files follows. No root is needed, it reaches every install, and nothing
    else reads that service's `$HOME`; `logout` removes it. Other FUSE mounts in such a home (sshfs, rclone) are then
    listed in Files too, as they are everywhere else. Where the monitor is not a user service, GVfs's own rule
    decides, and `doctor` applies that rule to say which case a machine is in. A bookmark of the drive titled with one
    of its names goes once the drive is listed (an untitled one the user made stays). **Flatpak impact:** a Flatpak
    could not write the drop-in; Verso's Flatpak has no drive.
    - **Not chosen: the `x-gvfs-show` mount option.** Only root may record a user-space option, so it reaches GVfs
      only through `fusermount3`, from fuse3 3.17 and only into a `/run/mount/utab` that already exists, which it does
      not where nothing has mounted a drive since boot; an older `fusermount3` hands it to the kernel, which refuses
      the mount. Nor a mount point under `/run/media/$USER`, which only root may create.
    - **The fix belongs in GVfs** (and GLib's `g_unix_mount_entry_guess_should_display`, which compares the same
      way): resolving `$HOME` first would list every such mount and make the drop-in unneeded.
  - **Eject** really unmounts, taken as the user's choice ("The daemon's lifecycle", step 3). gvfs ignores a quick
    unmount-and-remount, so the daemon waits for the old mount to disappear before mounting again.
  - **No `DCIM` folder at the root:** gvfs scans new mounts for camera layouts *(untested)*.
- **File dialogs:** GTK and portal file choosers show the mount, and should show the seeded thumbnails; Flatpak apps
  reach the files through the document portal *(both untested)*.
- **Indexers and crawlers:** GNOME's indexer (localsearch, which indexes all of `$HOME`) has not entered the mount,
  for reasons not found, so the hidden `.nomedia` and `.trackerignore` stay as protection, also where someone mounts
  inside `~/Pictures`. A search typed in Files crawls the tree
  (listings only), slow the first time, as People and Places multiply it; GNOME Shell's overview search does not enter
  the mount. `updatedb` and `plocate` run as root, and root cannot enter a mount without `allow_other`. Backup tools
  that walk `$HOME` (Déjà Dup, restic, borg) would see it; WORKFLOWS says how to exclude it.
- **The tray** shows only where the AppIndicator extension is on ("The tray"); elsewhere status lives in the window
  and in notifications. The service is a user service, so it needs neither the Background portal nor a tray.
- **Notifications** cover only what the user cannot otherwise see:
  - a refused or failed upload
  - a long upload
  - the server unreachable (once), and the first original that cannot be fetched then
  - signed out
  - a locked keyring
  - the question about folders copied into Upload, and what came of their albums

  They carry the name and the symbolic icon, and no `desktop-entry`: GNOME 50 drops a notification whose
  `desktop-entry` names an app it did not come from, and the daemon is not the app. GNOME 50 draws every header icon in
  one colour, so the app's icon in colour is the notification's picture (`image-path`), which shows the notification
  is ours. The Files extension does the same.
- **Not chosen:**
  - **A GNOME Online Accounts provider plus a GVfs backend,** as GNOME did for OneDrive in GNOME 46: C code in GNOME's
    repositories, on its release cycle, GNOME-only; GIO marks such locations remote (no thumbnails by default), and
    non-GIO apps reach it only through gvfs's own FUSE bridge.
  - **A Nautilus extension:** extensions add menus and columns, not locations.
  - **fanotify pre-content events** (Linux 6.14+): placeholder files filled on first access, the closest Linux match
    to macOS's placeholders, but they need `CAP_SYS_ADMIN`.

#### The drive's icon

The drive shows its icon (`dev.hviid.Verso.Drive`, "The icon") wherever a file manager lets a mount have one, each
place its own way:
- **Files' sidebar draws only symbolic icons,** and GVfs gives a FUSE mount a fixed one (`drive-removable-media`)
  unless the mount has a volume. A volume comes only from an fstab entry, whose `x-gvfs-symbolic-icon`, `x-gvfs-icon`
  and `x-gvfs-name` it honours; neither a mount's own options nor `/.xdg-volume-info` set the symbol. So the daemon
  points GVfs's volume monitor, through its drop-in, at a private copy of `/etc/fstab` (`LIBMOUNT_FSTAB`, which GLib's
  libmount reads and watches) and lists the mount there while it runs; a line left for an unmounted folder would show
  a volume that cannot mount.
  - **The copy is written once, with the line, as the daemon starts,** before it mounts and restarts the monitor: a
    line added moments after the copy goes unnoticed, and a running Files then lists the drive twice, with the generic
    symbol. The daemon writes the copy without the line once it stops, replaces a line a killed daemon left, and leaves
    the copy alone when another daemon serves the mount. Eject still works (the monitor's `umount` is setuid and
    ignores the variable), and the line's `x-gvfs-show` also lists the mount where home is reached through a symlink.
  - **The cost:** `LIBMOUNT_FSTAB` is libmount's own testing switch, not a promise GVfs makes, and the copy follows
    `/etc/fstab` only as each daemon starts. Should GVfs stop honouring it, the drive keeps the generic symbol;
    nothing else depends on it. It works only where the volume monitor is a user service.
  - **Without its unmount button** (`mount.unmount_button` off, **Bookmark Instead of Drive** in Preferences): a mount
    GVfs lists always has one, so the line says `x-gvfs-hide`, and the daemon bookmarks the drive instead. It changes
    the bookmark only when the setting changes (`sidebar-entry` in its state), so a bookmark the user removed stays
    removed. GNOME Files only: Dolphin lists no FUSE mount as a device.
  - **Not chosen:** a line in `/etc/fstab` (written by root for each user, and a volume that cannot mount whenever the
    drive is not mounted); GVfs's options in the mount table (`/run/mount/utab`, where GVfs reads only `x-gvfs-show`
    and `x-gvfs-hide`, written by fusermount3 only from fuse3 3.17, into a utab that may not exist); a remote volume
    monitor of our own (installed into `/usr/share/gvfs/remote-volume-monitors`, speaking GVfs's private D-Bus
    interface).
- **Files' views** draw the mount point with the folder's custom icon (`metadata::custom-icon-name`, kept by
  gvfsd-metadata, as Properties' Change Icon sets it), which the daemon sets with `gio` as it starts and once mounted,
  since GVfs keeps it apart for the folder unmounted and mounted. One the user resets comes back at the next start.
- **Dolphin's views** draw a folder with the `Icon` of its `.directory`, which the mount serves at its root, but for
  a remote folder (to KDE, every FUSE mount without a `/dev` source) only with previews of remote folders on
  (`[PreviewSettings] EnableRemoteFolderThumbnail`). That switch is KDE-wide and previews every remote folder, the
  mount's albums included, so Verso leaves it to the user.

### Thumbnails

#### The problem (verified)

On a FUSE mount, GNOME is aggressive:
- **GIO treats our mount as local.** It reports `filesystem::type fuse` (from the statfs magic, so a `fuse.immich`
  subtype is invisible) and `filesystem::remote FALSE`. Every `local-only` default applies.
- **Opening a folder makes `glycin-thumbnailer` read every file in it to the end, viewport or not,** a folder of 400
  files within seconds. Only files over the 50 MB `thumbnail-limit` are skipped.
- **A search typed in Files crawls the tree, and then thumbnails every hit.**

Without countermeasures, opening one month downloads all of it.

#### Seeding the freedesktop cache

Nautilus never reads an original if a valid thumbnail exists, in any bucket. It uses the largest bucket present,
accepts PNGs smaller than the bucket as they are, and a valid thumbnail wins over a recorded failure. So:

1. **Before `readdir` answers** (budget 10 s; 8 to 16 fetches in parallel), every Appearance in the folder gets
   `x-large/` (512) from Immich's small `thumbnail`: a WebP with a short side of 250 px, so it fits without
   resampling, at 5 to 25 KB each. This alone stops every original from being read; a month of 1,000 photos costs
   about 20 MB on its first visit, and nothing after.
2. **In the background,** with sharp thumbnails on by default, `xx-large/` (1024) is made from Immich's `preview`
   (40 to 520 KB each). Nautilus shows it the next time the folder is drawn.
3. **Server thumbnails are cached by asset id,** so writing them for more Appearances, or rewriting them after a
   name change, needs no network.
4. **A thumbnail is found by its URI,** so where home is reached through a symlink each file is seeded under both
   paths a file manager reaches it by: the resolved one, which GVfs's drive opens (`/var/home/me/Verso`), and the
   configured one, which browsing from Home and Verso's **Open in Files** use (`/home/me/Verso`).
5. **Each server thumbnail is decoded once, and scaled once per bucket,** for every path it is written to, and the
   PNG is compressed fast: at the default level the encoder takes 100 of the 130 ms a 1024-pixel seed costs, enough to
   slow the file manager over a month of photos; fast takes 3 ms, for a file 15 to 40 percent larger. Previews are
   rendered two at a time, so the sharp pass never takes every core while the file manager draws the folder.

**Counts are seeded ahead, not waited for.** Files and Dolphin count the items of every subfolder of a folder they
show by listing each in turn, and Files' GIO workers then look up every file in it, so opening a year would list and
seed all its months, previews included. A listing is taken for a count when its parent's listing, or another count in
it, ended less than 3 s before, a sibling was listed since, and it was not listed itself in that time: a counter lists
siblings in a row, while a file dialog or a script opening one subfolder lists none. A count answers at once, and its
small seeds are written in the background (four fetches and one render at a time, no previews), so the visit, often
the next click, finds them waiting. A subfolder opened within those 3 s is listed again, which counts as the visit;
one opened before it was counted is promoted at its first `access()`, since a file manager asks a file's access rights
right before it looks for its thumbnail and a count asks none. This relies on the mount having no
`default_permissions`, so that the kernel passes every `access()` to the daemon (GNOME integration).

**Not chosen, for now: prefetching beyond what file managers list.** Seeding ahead covers the folders one level
below, since file managers list them anyway; going further fetches thumbnails for folders nobody shows, multiplied by
People and Places. ROADMAP, "Performance", weighs it with the other options.

The URI that keys the cache file must match `g_filename_to_uri` byte for byte; a unit test compares our encoder with
GLib's for awkward names (spaces, `#`, `%`, `?`, `[`, non-ASCII, combining characters). GLib is only a test
dependency.

**Indexer walks do not trigger seeding either.** Baloo (`baloo_file`) and GNOME's miners list every folder they
index; on a mount with People and Places, one walk would fetch a server thumbnail for every photo.

**Search crawls do not trigger seeding.** FUSE reports the calling thread, and Files' crawl runs on one named
`nautilus-search`. Their hits fall to the safety net and show generic icons until the folder is opened normally.

**Not chosen:**
- **Small thumbnails only:** cheaper, but soft at larger zoom levels and on HiDPI screens.
- **Seeding for search crawls:** one search could fetch thumbnails for the whole library. Seeding them lazily,
  with a cap per minute, remains the fallback if crawl detection proves unreliable.

#### The safety net

Seeding can lose a race or hit its budget. So when a known thumbnailer opens an original, it gets `EIO` at once:
- **Identifying the caller:** FUSE reports the calling thread; its process (`Tgid` in `/proc/<id>/status`) and that
  process's ancestors are matched by `/proc/<pid>/comm`. The thread's own name is not enough: glycin reads from a
  worker thread named `blocking-1`.
  - On GNOME 50 that is `glycin-thumbnailer` under `bwrap`. `comm` is truncated to 15 characters, so the match is
    on `glycin-thumbnai`.
  - Videos go to `gst-video-thumbnailer` (`gst-video-thumb`), also under `bwrap`.
  - Also recognised: `gdk-pixbuf-thumbnailer`, `totem-video-thumbnailer`, `ffmpegthumbnailer`, and KDE's
    `thumbnail.so` worker.
- **What follows:** GNOME's thumbnail factory records a failure for the file (`thumbnails/fail/`), and Files shows a
  generic icon for it, F5 included, until Files is started again, when the seed written meanwhile wins over the
  failure. This happens only when seeding could not run, with the server unreachable, so WORKFLOWS tells users to
  reopen Files once it is back.

**Indexers are kept out too, always.** Baloo indexes only Documents, Pictures, Videos and Music by default, but once
the mount is among its folders (added, or mounted inside Pictures), its extractor reads every original. Its extractor
and GNOME's get `EIO` at open, whatever the safety-net setting, and their file-name indexing goes on. GNOME is also
kept out by `.trackerignore`; KDE has no such file.

**Not chosen:** feeding the thumbnailer the preview's bytes instead of the original's. The same path would then return
different bytes depending on who asks, the size would not match, and a misidentified program (a backup tool, an
editor) would silently get a small JPEG instead of the photo (principle 3).

#### Privacy

Seeds are small copies of private photos in a shared directory. Every seeded file is recorded, and deleted when
signing out, together with any `fail/` entries for our URIs. Signing out also sweeps the thumbnail cache for any entry
whose `Thumb::URI` lies under the mount, by either of its paths, including thumbnails a thumbnailer made there and
failure records for search hits that were never seeded, since those URIs carry album and person names.

### The tray

The Mac's menu bar item on Linux (DESIGN.md, "The apps' interfaces"): a glance at the connection, and the way to the
window and the drive, without opening a window. **The service serves it,** as a StatusNotifierItem with a
`com.canonical.dbusmenu` menu (SPEC.md, "The daemon's D-Bus interface", has the menu line by line), and it anchors
the work in the background: closing the window leaves it, the cache and the drive running.
- **D-Bus alone,** so the service carries no toolkit, and the icon lives as long as the service, which runs from login
  while signed in and already holds the session bus and knows the state.
- **GNOME** shows it where the AppIndicator extension is on (Ubuntu and Bazzite ship it); stock GNOME has no tray, and
  its guidelines want none, so there the window and Files' sidebar are the way in. KDE Plasma shows it in its system
  tray. Where no tray watches, the registration fails quietly, and is made again whenever a tray starts.
- **The menu is the Mac's,** and a click shows it, as on the Mac (`ItemIsMenu`); a double click opens what
  `tray.double_click` says. **Quit Verso** closes the window (its own `quit` action, through
  `org.freedesktop.Application`) and stops the service, which unmounts; opening the window starts it again. KDE's own
  tray items end with Quit, and so do the apps' that use GNOME's AppIndicator.
- **What the tray opens runs on its own:** the window, the file manager or a browser, each in a scope of its own
  (`systemd-run --user --scope`), and reaped. As the service's children they would be in its service's group, which
  systemd stops whole, so a window the tray opened would close with every stop of the service (signing out, Quit, a
  change of settings).
- **Preferences… and Sign Out… open in the window,** since the service has no window to ask in and signing out is
  never done without asking: the tray hands the window `verso:settings` or `verso:sign-out`, addresses no other
  program claims, and the window runs them once it shows its account (`Window::when_ready`); sooner, Preferences
  misses the account and GNOME places it partly off screen.
- **The icon** is Verso's symbolic one (DESIGN.md, "The icon family"), which trays recolour to the panel's text, and
  shows the state ("When the server cannot be reached").
- **One top bar icon:** what served the drive stops with it (`tray::show` returns the task that keeps the icon
  registered), so a service that goes on without the drive leaves no second item holding the old D-Bus connection.
- **Flatpak impact:** the sandbox needs `--talk-name=org.kde.StatusNotifierWatcher` to register; the item itself is
  served on the app's own connection, by object path. In a Flatpak the tray opens the window through `flatpak-spawn`,
  so it does not close with the service ("Verso as a Flatpak").
- **Not chosen:** the GTK window holding the icon (it would have to run at every login, and GTK 4 has no tray at all);
  `libayatana-appindicator` (a C library, and GTK 3, in a service that links no toolkit).

### When the server cannot be reached

Each part says so and keeps working with what it has, and nothing waits out a timeout, also where the network drops
packets silently rather than refusing.
- **The service** asks the server every 10 seconds (`CHANGE_POLL`: its change poll with the drive, `check` without),
  at once on a change of network (the NetworkMonitor portal, which a Flatpak reaches too, and again 3 seconds later),
  and on the window's Try Now (`CheckNow`) and the menu's **Try Again Now** (`daemon::check_now`). A refused
  connection shows within 10 seconds, dropped packets within the poll's 25-second limit. The server answering again
  turns the state back without a notification. The states: SPEC.md, "The daemon's D-Bus interface".
- **The top bar's icon** (`tray::icon_for`) speaks the sync apps' shared iconography (Nextcloud, OneDrive, Dropbox):
  faded and struck through while the server cannot be reached, faded with a key while it refuses the sign-in, a pause
  badge while Verso Drive is on and unmounted; a problem shows before a choice. In colour (`tray.colour`) the lens's
  ring has Immich's five colours, which the faded states lose, so the colour itself says the server is out of reach;
  colour means something only on a coloured print, so the one-colour set has no coloured badges. A change of the
  setting has the service draw the icon again (`RefreshIcon`) without a restart. `linux/packaging/icons/sources/states.py`
  draws them; a later state (syncing, an error, not allowed, a warning) is drawn there once it is built.
- **The drive** serves the folders visited and the originals in its cache; any other original fails at once with
  `EIO`, and the first such read of an outage shows one notification naming the file (`notify::offline_read`; SPEC.md,
  "Content"), as a program shows only "Input/output error".
- **The window** keeps its own view of the server (`connectivity`), as a Flatpak's window may run before the
  service: it asks (`Client::ping`, one attempt within 10 seconds) when a request fails for want of the server or has
  waited 12 seconds (a network that dropped without a word), on a change of network or of the service's state, on Try
  Now, and every 10 seconds while the server is out of reach, and tells the client (`Client::set_reachable`), so
  requests fail at once and a page stops waiting. A banner under each page's header says so ("*host* is not
  reachable. Verso keeps trying."), with Try Now; what is shown stays, a page that cannot load says Could Not Load
  with Try Again, and failures because of the server go to the banner, not a toast each (`Window::load_failed`); other
  failures toast at most once every 5 seconds (`TOAST_GAP`). When
  the server answers again, the banner goes and the page shown is read again if anything failed meanwhile.
- **The client** (`immich-api`) pings an HTTP/2 connection with requests waiting every 10 seconds, so a dropped
  connection fails its requests in seconds rather than at their 60-second timeout; plain HTTP has no such ping, which
  the window's 12 seconds cover.

### Links on Linux, and the Files extension

On Linux the service answers for the drive's items, since it alone knows which key a path means; the Files extension
asks it, and Verso takes part in Immich Crosslink as two participants. The map, the protocol's rules and the
settings are the core's ("Links to Immich").

- **The daemon answers** (`Links`, and `WebLink` for older menus, on its D-Bus interface), through the names it
  handed out: it walks the path from the mount point through the folder listings it has, however old
  (`Tree::key_at`), and reads a folder from Immich only when it has none, since the file manager asking has just shown
  the folder and names are kept per folder. A menu therefore costs no request to the server. A path that reaches the
  mount through a symlink in its parent folders (`/home` to `/var/home`) counts; the daemon resolves only the folders
  outside the mount, never the mount itself, which it serves.
  - **Not chosen: an extended attribute on each file** (`user.immich.url`): every file manager would read it on
    every item it lists, and folders would need one too, where the daemon is asked only for the item right-clicked.
- **The command** (`verso-service web`) asks the running daemon, as the menus do, and opens the address with
  `xdg-open`. **Copying** from a command that ends at once is the hard part: on Wayland and X11 the program that set
  the clipboard serves it, and the text is gone when it exits, so the command hands the text to a program that stays:
  `wl-copy`, `xclip` or `xsel`. A file manager extension sets
  the clipboard itself.
- **Files: a Nautilus extension in C** (`linux/files-extension/verso-nautilus.c`, on `libnautilus-extension-4` and
  GTK 4, which Nautilus has loaded already). It sends one selected `file://` item to the daemon's `Links` (250 ms
  limit, `NO_AUTO_START`) and offers the items when an address comes back, so the daemon alone decides what is in the
  mount. Files asks on its main thread at every selection, so after a call that timed out the extension does not ask
  again for 30 seconds: a stuck daemon costs one wait, not one per click. It opens through GIO with GDK's launch
  context, so the browser comes to the front on Wayland, and copies with GDK's clipboard, which it owns for as long as
  Files runs.
  - **Built by each distribution's package,** against its own Nautilus (`build.sh`; ROADMAP, M9, step 6): the
    extension folder differs, each package builds on its distribution anyway, and an API change then fails that build
    rather than a menu at run time.
  - **The tarball and Homebrew's cask: the same in Python** (`verso-nautilus.py`). Nautilus loads C extensions only
    from its own folder in `/usr`, read-only on Bazzite and the atomic desktops; nautilus-python, which Bazzite ships,
    loads from the home folder, so the cask installs it there. It asks for Nautilus 4.1 (Bazzite has only that
    typelib), falls back to 4.0, and stays quiet where the C extension is installed, so a machine with both shows one
    pair. Its type is its own, so it shares Files with Immich Mount's extension.
- **Receiving a crosslink for Verso Drive:** its entry takes the scheme, so a link starts `verso-service app %u`,
  which hands it to the daemon's `ShowLink` and ends; the window never opens. The daemon reads it with the core's
  `receive` (the protocol's checks, the server, the user), finds the item where the drive shows it (`Tree::locate`: a
  photo's date folders from the Asset's details, an archived photo of the timeline in Archive), names its path
  (`Tree::path_of`) and asks the file manager to select it through `org.freedesktop.FileManager1.ShowItems`, which
  Files and Dolphin both answer.
  - **The daemon, not the window:** it alone knows the names it handed out, and it already runs while the drive is
    mounted; starting a GUI to select a file would flash a window.
  - **Only showing:** any web page can open a registered scheme, so a link is a stranger's. The daemon fetches the
    folder listings and a photo's details and nothing else, and every way it ends is a selection or a sentence.
  - **The user** is read with the email at start (`GET /users/me`), so a link from another account's view is not
    shown as if it were this one's; an API key that may not read the account skips that check, as the protocol
    allows. The setting is read at start, and the window restarts the daemon when it changes.
- **Show in _app_:** the menus find the apps themselves, through GIO's index of desktop entries
  (`g_app_info_get_all_for_type`), and read the announcement from the entry, so an app's name and icon are the
  system's and the link goes to that app alone, as the protocol asks. The daemon gives what only it knows, in one call
  (`Links`): the item's web address, crosslink and kind, and the apps switched off. The settings list the apps from the
  same entries (`crosslink_apps.rs`, by the desktop entry specification's rules), so Preferences show what the menus
  offer ("Links to Immich").
  - **Not chosen: Verso as the scheme's default handler.** Apps that take part never use the default, so it matters
    only to links opened in a browser or with `xdg-open`, where with two apps installed the choice is the user's; a
    package taking it over would also take it from the other app's users.
- **Immich Crosslink, as two participants** (`participants`): Verso Gallery (a link opens the item in the window) and
  Verso Drive (it shows the item's file or folder in Files), which send to each other as to any participant. Each is a
  hidden desktop entry of its own (`NoDisplay`), written by the service at each start while its switch is on and
  removed otherwise (SPEC.md, "Links from other apps (Immich Crosslink)"); the app grid's entry announces nothing. The
  folder's MIME cache is brought up to date whenever it lacks an entry, as senders find participants there. `Exec`
  names the program unquoted where it can: GIO hands a program back with its quotes, and a sender that checks it can
  start (as the Files extension does) would leave both participants out.
- **An older daemon** answers `Links` with an unknown method; the menus then ask `WebLink` and offer no Show in
  items, so a newer extension never breaks against a daemon not yet restarted after an upgrade.
- **Flatpak impact:** the D-Bus members and the command work from a Flatpak (the command needs the session bus and
  `xdg-open`, which the OpenURI portal answers); the Files extension is a file on the host, which a Flatpak cannot
  install, so Verso's Flatpak, without a drive, has none. Its exported entry takes crosslinks as Verso Gallery ("Verso
  as a Flatpak"); a drive in a Flatpak would need `--talk-name=org.freedesktop.FileManager1` to select an item.

### Verso's window

The gallery (`linux/verso/`, over `verso-desktop`): browse, search and organise the library, as Immich Gallery does on
the Mac, whose pages it follows. SPEC.md, "Verso's window on Linux", says what each page offers, and this section why;
ROADMAP, M8, has its status and what is still to come; DESIGN.md, "The apps' interfaces", has its look.

- **Native, GNOME first.** The route chosen for Linux (principle 9): a native interface over a toolkit-free crate that
  holds the state and the behaviour, so an interface in another toolkit would cost its widgets, not the logic. GTK and
  libadwaita bring what a gallery needs: a list view that builds only the rows on screen, GStreamer behind `GtkVideo`,
  a map (libshumate), drag and drop with Files, and screen readers.
  - **Not chosen: one Rust toolkit for both desktops** (iced and libcosmic, Slint, GPUI): foreign on both desktops,
    with video, maps, drag and drop with other programs and accessibility each built from parts (as of Slint 1.17,
    dragging works inside the app only).
- **gtk4-rs and libadwaita,** with the window's frame in **Blueprint** (`window.blp`), compiled to GtkBuilder XML at
  build time through gtk4-rs's `blueprint` feature; the pages are built in Rust. Many GNOME Circle apps and some core
  apps use Blueprint, so it is the direction GNOME's own apps are taking. It still calls itself experimental, and GTK
  5's way of defining interfaces is undecided (the April 2026 GTK planning call kept Blueprint out of GTK's tree); it
  holds one file, so a migration would be cheap.
  - **Not chosen: Relm4:** less boilerplate, but an extra layer, and not what GNOME's documentation or its own Rust
    apps (Loupe, Snapshot) use.
- **Preferences** are a window of their own with a sidebar of pages: the account, General, Crosslink, Features (the
  account's Immich preferences), the drive's pages while the drive is on (drawn by `drive_preferences.rs` from the
  layout every edition shares: "One layout for every settings window"), and Administration for the server's admins.
  The daemon restarts when a drive page where something changed is left, or the window closes. The drive's pages show
  Verso's defaults and leave out what Verso has no use for (`Product::hidden_settings`).
- **Each thing in one place,** as GNOME arranges an app: the main menu holds what is app-wide (New Window, New Album,
  Import, Edit Sidebar, Preferences, Keyboard Shortcuts, About), a grid's toolbar what concerns the photos shown, and
  the selection's bar and the right-click menu the photos' actions. Size and squares are one setting for every grid
  (`grid.size`, `grid.squares`), as on the Mac. Every command keeps its shortcut, listed in Keyboard Shortcuts.
  - **Not chosen: the Mac's menu bar** (File, Edit, View) in the main menu: on GNOME it puts the photos' view in the
    app's menu, beside the same buttons on the toolbar.
- **The window** opens at the size it was last closed at, maximised if it was (`window.width`, `window.height`,
  `window.maximized`), as GNOME's apps do; Wayland leaves its place to the compositor. The first time it takes three
  quarters of the screen, as any fixed size is small on a large screen.
- **Motion, as the Mac's** (`motion`), only for what the user does to what is on screen. Opening a photo zooms it out
  of its grid square while the page it leaves fades, and closing flies it back, on the Mac's smooth spring (0.35 s).
  Pages switch in place, the viewer's too: GNOME's slide reads as motion for its own sake. The fading page is a still
  Verso draws itself once the click's own frame is drawn, as GTK's still of a page, or one taken before the
  selection's layout, comes out empty. Stepping slides the next photo in (0.48 s on the Mac's curve; 0.36 s reads as
  too fast), and a touchpad's sideways swipe follows the fingers, going on past a quarter of the width or when flung
  (finishing in up to 0.4 s). Zoomed in, a video, Full Screen and the slideshow only fade or switch.
- **A width that settles lays out once:** the Info panel sliding in, or a resize, changes the grid's width on every
  frame, and laying out every row of a big library each time makes the panel lag; the rows are laid out 120 ms after
  the width stops changing.
- **The grid** lays photos out in justified rows at their own shape (`layout::justified`), or as squares, under a
  heading per month. A timeline's months come first with their counts (`GET /timeline/buckets`); a month's photos are
  read before its rows come into view, and until then its rows are grey placeholders at a typical shape, so the scroll
  bar is about right. The bucket's columns carry each photo's shape and ThumbHash, so a row is laid out and drawn
  before any thumbnail arrives.
  - **Months are read ahead both ways,** about three screens of rows above and below the rows the list binds: a
    month's real rows rarely match its placeholders, and one read in view changes size there, which slides the view
    when scrolling up. A month's heading row stays the same row when it is read.
  - **A jump keeps its row at the top.** GTK's list holds what it last scrolled to at the edge it came in at, and a jump
    down comes in at the bottom, so months read in between push the row down; the jump goes just past the row and
    back, which holds it at the top. A jump into a month not read yet lands on its placeholders, and again on the row
    with the same photo once the month is read, if the month is still at the top.
  - **Thumbnails queue on the main thread,** a few at a time, those on screen first; one whose tile moved on to
    another photo is dropped before it is fetched. A list view binds far more rows than it shows, and without the
    queue the viewer's preview waits behind hundreds of thumbnails.
  - **Pictures as edited:** the gallery asks for thumbnails and previews with `edited=true`, so a photo turned or
    cropped in Immich shows as Immich's web app shows it; without it the server serves the unedited picture. The drive
    asks without it, its files being the unedited originals. Rotate and Crop change the steps of the photo's
    non-destructive edits (`actions::rotated`, `actions::cropped`), never the original, and only for one's own still
    photos (`actions::can_edit_picture`): a rotation one turn at a time, a crop first, in the original's pixels.
    Immich applies the steps in their order, so a mirror after the rotation step turns its direction around.
  - **The cache** keeps thumbnails (250 px WebP), previews (1440 px JPEG), faces, played videos and opened originals on
    disk per account under `$XDG_CACHE_HOME/verso/gallery/<account>/`, each trimmed least recently used first to a
    budget of its own, at the start and every half hour; in memory, about 400 decoded thumbnails and the 8 previews
    around the photo shown. Originals are never fetched for the grid or the viewer (principle 2); Open With and a drag
    fetch one when the drive cannot give it, and videos play the server's playback file. Every file is written under a
    name of its own and linked into place only when whole (copied where the file system has no hard links), so two
    writers of one photo never corrupt it. Thumbnails and previews are kept under the photo's ThumbHash as well as its
    id, so a photo whose picture changed in Immich is fetched again: Immich makes the hash again with the picture.
    Locking the Locked Folder again removes what memory and the cache hold of its photos.
- **The map** shows every photo with a place through libshumate (GNOME Maps' widget, OpenStreetMap's tiles), in
  clusters made in the cells of a grid whose size doubles with each zoom out, so a cluster keeps its edges and its
  picture as the view moves (`verso_core::map::clusters`, which the Mac's and the iPhone's maps use too, ported from
  Immich Gallery's). The view's spans come from the zoom level by Web Mercator's arithmetic (`verso_desktop::map`).
  A cluster is a pin standing by its tail's tip on the spot, and opens its photos, read by id.
  - **Privacy and tiles:** the tiles come from OpenStreetMap's own servers, libshumate's default source, which learn
    the areas viewed. A release needs a tile service that allows an app's traffic (OpenStreetMap's tile usage policy),
    or the user's own, before it ships.
  - **The map's date range and filters** are the Mac gallery's, not remembered; the markers are read again for each
    change, and the first read fits the map to them.
- **Stacks** show as their primary photo in the Library, with a badge (`TimelineScope::LibraryStacked`, `withStacked`,
  a scope of the gallery's own, so the drive keeps listing every photo). A stack's page (`Source::Stack`) works as the
  Mac gallery's stack browser; a photo kept while the others go to Recently Deleted is made the primary first, so the
  stack never shows a photo in the trash. Stack Together heads a new stack with the first photo in the grid's order.
- **The viewer** opens beside the sidebar, over the page it came from, and shows the thumbnail at once and the preview
  when it comes. Its details are a scroll below the photo, as the Mac gallery has them (`info::info_groups`), read a
  moment after a photo shows, so stepping fast reads none on the way; Down and Up go through them, so a photo is read
  from the keys alone. Copy as File downloads the original into the cache's clipboard folder, which keeps only the
  last, and never for the Locked Folder. Face Names are drawn on the photo by a widget of its own (`faces`) so they
  zoom and scroll with it, and none on an edited photo, as Immich measures the unedited one. Loop Video has no speed
  beside it: GTK's media streams have no playback speed. **Full Screen and the slideshow** (`slideshow`) hide their
  controls after 2.5 seconds without the pointer moving, keep their settings under the Mac gallery's keys, and fold
  the sidebar away while they run. Space, which opens the ringed photo from the grid, goes back again, as in the Mac's
  Photos.
- **Through the drive:** Show in Files, Open With and dragging photos out ask the daemon for each photo's path
  (`ShowLink`, with the photo's crosslink), so another program reads the original from the drive as it reads any file,
  and nothing is downloaded first; without the drive, the originals are downloaded to the cache. A drag asks only when
  the drop wants the files (a `GdkContentProvider` that writes `text/uri-list` on request), so starting a drag costs
  nothing.
- **The sidebar** keeps its fixed pages at the top and the albums last, as the Mac gallery does, in two sections, My
  Albums and Shared Albums, each as many and in the order chosen in its heading's menu. **Edit Sidebar** arranges it
  as the Mac's `SidebarLayout` does (`sidebar::Layout`, the same format): the sections in order, the built-in ones by
  their English heading, the user's own as `custom-N` with a name, and each page with its section, in order; the
  albums' two sections take no pages. A page or section it does not know is left out, and a new one joins its own
  section at the end. **The account** sits at the bottom of the sidebar, as on the Mac, lit only under the pointer: a
  panel at rest reads as an outline too many.
- **The scrubber** (`scrubber`), at the right edge of a grid of months, as Immich's web app and the Mac gallery have
  one, goes to exactly the place a click or a drag points at. The arithmetic is the core's ("The date scroller"), given
  the grid's layout of a month not read yet (placeholders at a typical shape, or squares), which a month read comes
  near; its rows land on the grid's by the photo at a row's start, and the mark follows the row at the top. The
  toolbar's Date Scroller toggle hides it on every grid (`grid.dateScroller`), as on the Mac.
- **View Options** on the photo pages follow the Mac gallery's `GridArrangement` (`arrangement`), each page remembering
  its own and offering only what it can. The timeline API narrows to favorites and orders (`isFavorite`, `order`,
  `orderBy=createdAt`) but has no media type, so photos or videos alone read through the search API, which orders by
  date taken.
- **Cards** (`cards`) are how Shared Links, Countries, Memories and Albums show: one to three photos edge to edge carry
  the title and the rest on a fade at their foot, so no space goes to a block of text under them; only a link's
  buttons go under its photos. Five sizes (220 to 440 pixels wide at least, widened to fill a line, never more than
  five a line; `cards.size`) size the square tiles too (People's faces, the cities). What the page's list leaves out (a
  country's years, an album's other photos) is read as a card first shows and filled in through a weak hold, as the
  card itself is not kept.
- **The Albums page** (`albums`), after Immich's and the Mac gallery's, shows an album's description only while the
  pointer or the focus is on its card (`Card::note`, never in the way of a click), and has no Year grouping while
  sorting by the albums' own dates. Back from an album, it reads its albums again and redraws them, where it was, only
  if one changed.
- **Places** shows cities as square tiles, as People's faces are, since they are often many, and countries as cards,
  whose years are two searches made as the card first shows, both by name (`verso_core::places`, which arranges them
  for the Mac and the iPhone too, where they also go by when each was last visited).
- **Remembered choices** live in `$XDG_CONFIG_HOME/verso/gallery.json` (`settings`), beside the drive's `config.toml`,
  written at each change.
- **Years, Months and All Photos:** the Library's header switches between them, as Photos and the Mac gallery do
  (`verso_core::overview`, which arranges them for the Mac and the iPhone too, after Immich Gallery's
  `LibraryOverviewArrangement`): Years shows each year by a photo from its fullest month, Months each month by one
  large photo and up to three from different days, a still before a video. Months are read as they come into view (or
  taken from the grid), and their pictures are previews decoded no larger than 720 pixels, four at a time, those moved
  on dropped before they are fetched.
  Selecting waits for All Photos, and the Date Scroller is the way to jump far. **New Window** (Ctrl+N) opens another
  window on the same account.
- **Selecting and the Info panel:** a click selects, a double click, Return or Space opens, as in Files and the Mac
  gallery. Info (Ctrl+I, remembered) shows the selected photo's details beside the grid, the viewer's own pane (`info`).
  Favorite is one switch for the selection: on while every photo is a favorite; pressed, they all become favorites, or
  none when they all are. A favorite is a heart wherever it shows (`verso-heart-symbolic`), as on the Mac, so a star
  only ever means a rating.
- **Search**, after the Mac gallery's (`search`): smart search, file names, descriptions or the text in photos, and
  filters, each list narrowed by the one above it; filters alone search too. A date order sorts smart search's best
  250; twenty recent searches are kept for each account. The filters go in the dialect Immich speaks since v3.2
  (`hasAlbums`, `rating`, `originalFileName` and `description` with `like`, `ocr` with `matches`). Their people show
  the first twelve in Immich's order, with Show All for the rest, and only the faces shown are made, so a library naming
  hundreds reads twelve pictures.
- **Assign Location** (Utilities) lists the photos without a place, or every photo, to see which have one, and sets the
  place of those selected; the grid reads again once Immich has named it. The timeline's months carry each photo's
  coordinates only when asked (`withCoordinates`; without it every photo reads as having none), so every month is read,
  eight at a time, as the Mac gallery does.
- **An album's page** (`album_page`), as the Mac gallery's, names how far the album reaches beside its icon (Private,
  Shared with 2 people, Shared with a password, Shared publicly), so the icons are known again on the cards. Its photos
  are in the order the album keeps. **Choosing photos to add** (`photo_picker`) is the Library's grid in a dialog,
  selecting from the start, from the page of the album or link they go to.
- **What a failure says** (`verso_desktop::errors::said`): when Immich turns a request down with a reason of its own (a
  400 or 409, `ApiError::refusal`), the reason, as "Immich says: …", never the raw HTTP answer; a plain sentence for a
  refused sign-in, a missing permission (named), something gone from Immich, and a busy server. An unreachable server
  keeps its words, which the window recognises (`immich_api::is_offline_text`) to show its banner.
- **Sharing an album** has one way in and one picture (`sharing`). How far an album reaches is the widest of its people
  and its working links (`Audience`): Private (a padlock), People, a link with a password (the globe with a padlock) and
  a public link (the globe), each icon the same wherever it shows. The Share dialog has People and Links; after each
  change it reads the album again, and the album's page and the Albums page show the new reach.
- **People** (`verso_core::people`, which filters for the Mac and the iPhone too), as the Mac gallery's: each face a
  rounded square, as a person is and an account is not (DESIGN.md, "The apps' interfaces"). **A person's page**
  (`people_page`) edits the name in place.
- **Memories** (`memories`), as the Mac gallery's: Immich's memories newest first, a hundred at a time, a flat list, as
  each card carries its day and the list holds a month or so. A memory is kept with a bookmark (`isSaved`,
  `verso-keep-symbolic`, as a star means a rating and a heart a favorite), since Immich's cleanup removes a memory
  after 30 days unless it is kept. The Locked Folder's photos stay out of a memory playing.
- **Find Similar Photos**, as the Mac gallery's sheet (`similar` in both crates), in the user's own still photos on
  the timeline or in the archive, not in a stack, at most 2000. Photos split into runs where the pause between shots is
  longer than chosen (5, 10 or 30 seconds), then group by the Mac's rules: complete link, never more than a minute or
  20 photos. Where the Mac compares Apple Vision's feature prints, each thumbnail here gives a 256-bit gradient hash,
  compared by the share of differing bits (strict, normal and loose are starting points, not yet tuned on real
  bursts), and a sharpness that, after a favorite, picks the suggested cover.
- **Tags, Partners and Duplicates**, as the Mac gallery's (`utility_pages`): tags as a tree (`tags::tree`), a partner's
  page of photos only to look at and download (`TimelineScope::Partner`, `Kind::Partner`), and duplicates sorted and
  suggested by `verso_core::duplicates`, which does so for the Mac and the iPhone too. A row's menu is made when it is
  first opened, as GTK roots each menu's actions slowly and thousands of tags would make thousands of menus.
- **Shared Links** (`links_page`), the links as cards. Its icon is three linked dots of Verso's own
  (`verso-share-symbolic`), as GNOME's `emblem-shared` draws a square around them. Immich lists each link with its first
  photo only and its album without a count, so a card reads the rest once shown (`complete`). **The link editor** keeps
  a password unless it is changed, as the server never sends it back. View Options filter the links through
  `verso_core::shared_links`, as on the Mac and the iPhone. **A link to chosen photos has a page of its own**, as an
  album has (`link_page`, `Kind::Link`), where its photos are taken out of the link, never moved to the trash, as they
  are the library's.
- **The photo menu** (right click), after the Mac gallery's (`menu_actions`), offers only what applies: the trash's
  photos only come back or go for good, and the Locked Folder's offer moving out.
- **Adjust Date and Time** works on every photo selected (`dates`), which Immich's web app does not: **Shift** moves
  each by an amount (a camera with its clock wrong), and **Set To** gives them all one date. Each photo is moved on its
  own clock: its local time at its own UTC offset, written back at that offset. Months go by the calendar first
  (January 31 and a month later is February's last day), then the exact rest. Immich writes a moved photo's zone as its
  offset ("UTC-4" where it had "America/New_York"), as it does for any date set through its API.
- **The keyboard** moves a focus ring through the grid, reading a month not read yet and landing once it is here. As
  in Files, the ringed photo is the selection outside selection mode, so a key acts on what the ring is on. Delete asks
  first, naming one photo by its date, as it may be off screen; in the trash it deletes for good, so only from the
  grid, never from the trash's viewer.
- **Immich Crosslink:** Verso Gallery's desktop entry announces the gallery (`X-Immich-Crosslink-*`) and takes
  `immich-crosslink` links ("Links on Linux, and the Files extension"), opening the photo, album, person or place they
  name; Open in Immich and Copy Immich Link use the drive's own paths (`verso_core::links`), so both name an item alike.
- **What changes in Immich** is what the Mac gallery changes: favorites, the archive, the trash (deleting for good only
  from the trash), albums, the Locked Folder (with its PIN; Set Up gives an account without one its first), dates and
  places, descriptions, ratings, people's names and merging, sharing albums with people on the server, and comments and
  likes in shared albums. What cannot be undone, and moving to the trash or the Locked Folder, asks first. An action
  that answers late takes out the photo it was done to, by id, whichever photo is shown by then.
  - **Dates** keep the offset of the photo's own clock (`actions::offset_of`). Immich stores the offset, not the zone's
    name: a photo taken in `Atlantic/Reykjavik` reads `UTC+0` once its date is changed, as it does when changed in
    Immich's web app, even with a bulk update naming the zone.
  - **Unlocking the Locked Folder elevates the session** the gallery and the drive share. The drive never asks for
    locked photos, so nothing locked reaches Files; Lock, or choosing another section, ends the elevation. Opening a
    photo keeps it, the viewer being over the whole window.
- **Imports** check each file's checksum first, so nothing the library has is sent twice, and upload the file
  unchanged; a duplicate waiting in the trash is restored. Immich reads a new file's date, shape and thumbnail in the
  background (read at once, a new photo shows grey and square), so the grids read again 5 and 20 seconds after an
  import that brought something new. Only files whose extension Immich takes are sent (`GET /server/media-types`),
  dropped folders are walked off the main loop, and a link to a folder inside one is not followed (a link to `..`
  would walk forever).
  - **An import shows at the foot of the sidebar, just above the account,** the same on Linux and the Mac: one place
    that moves no page, with a progress bar and no import button (the maintainer's choice; its look is in DESIGN.md,
    "The apps' interfaces"). A click lists each file (`imports`, `uploads::Queue`) with what became of it; Cancel All
    lets the file being sent finish. Files are sent one at a time on Linux and two at a time on the Mac, whose bar also
    counts bytes; Linux's upload has no progress to read yet.
  - **The words are the same in both apps:** "Looking for files…", "Importing 3 of 12", then "Imported 12", "Nothing
    new" or "Nothing imported" over what else it came to. It **needs a look** when something failed, was cancelled or
    could not be read, or when nothing came in at all.
  - **Once it ended, it goes into the notifications.** It stays 5 seconds (and while its list of files is open), then
    goes into the bell: read when everything came in, as it was seen happening, unread when it needs a look, so the
    bell's count says so. Its cross keeps nothing: it was seen and set aside. A new import first keeps the one shown,
    so a failure dropped on quickly is not lost.
  - **The grid shows what comes in while it comes in:** every two seconds from the first file that arrived, the grids
    read again, keeping each month already read whose count has not changed (`Grid::reread_changed`, the Mac grid's
    `reload(keepingUnchanged:)`), as reading every month whole every two seconds makes the whole grid blink. When the
    import ends, the page shown reads again whole, and the 5 and 20 second readings follow for the thumbnails.
  - **Where imports go** is where they were dropped, the same on Linux and the Mac (the maintainer's choice): to the
    library, and also into an album when dropped on its sidebar row, its card or row on the Albums page, or its page; a
    photo already in the library still joins the album. Import… on an album's page imports into that album, which the
    chooser's title names. GTK's file chooser picks files or folders, never both, so there are Import… and Import
    Folders….
  - **An album the account may only view** refuses a drop rather than let it fall to the library, where it would
    surprise: on Linux the import at the sidebar's foot says why, on the Mac the pointer shows the no-entry sign.
    Import… on its page imports to the library, as the chooser's title shows. An album not listed yet is left to the
    server.
- **Notifications: Verso's own beside Immich's,** in a bell at the foot of the sidebar with how many are unread (on
  Linux a count beside it, as GNOME has no badges), in two sections headed by where they come from, so the two are
  never confused: Verso's own (the imports that ended), and the server's under its address, never under Immich's logo,
  which is not Verso's. An import that left files out opens in place to list them with why (on Linux up to 100, then
  how many more).
  - **Verso's are kept on this computer only,** per account, never sent to Immich: the newest 20, none older than a
    week (on Linux in `gallery.json` under `notifications.verso.<account key>`; on the Mac in its defaults under
    `notifications.verso.<account>`). They stay after signing out, as recent searches do.
  - **The server's** are read when the list opens and every 60 seconds while a window is up, waiting longer after each
    error up to 15 minutes; marked read and deleted on the server (`PUT` and `DELETE /notifications`). A server that
    refuses them (403, a key without the right) or does not know them (404) leaves its section out, and the bell too
    when Verso has none.
  - **Flatpak impact:** none: the settings file and the icons Verso already ships, no new permission.
- **Administration,** a page of Preferences for the server's admins only: the server, its storage, the job queues,
  external libraries and the users; changing users and the server's settings stays in Immich's web app, a button away.
  **The account,** in Preferences: the profile, the password, the devices signed in and API keys. **Features**
  (`account_preferences`, `account_settings`): the account's preferences in Immich, read from the server's whole answer
  so a row shows only where the server has its value; each change goes as a patch of that value alone, a moment after
  the last change.
- **Not yet:** translations of the gallery's texts (they use `tr` and stay out of `po/` until the texts settle), and
  packages of its own beyond the tarball and the Flatpak. ROADMAP, M8 and M9, keep the list.
- **Flatpak impact:** the gallery is an ordinary sandboxed app (the network, the Secret portal, the OpenURI and file
  chooser portals); the drive is left out ("Verso as a Flatpak").

### Taking Immich Mount's account over

Where Immich Mount is signed in on the computer, Verso's first page offers its account
(`session::take_over_immich_mount`): Verso makes a session of its own with Immich Mount's (`POST /sessions`; an API key
is shared as it is), so signing out of one leaves the other, and copies the drive's settings but its place, name and
switch, its sign-in, its start at login and its update check. It switches Verso Drive on, as the offer says, in Verso's
own place, so the two drives never mount over each other. Immich Mount is left as it is until it is removed; Verso
reads its settings and keyring through the product switch's description of it, and never writes them.
**Flatpak impact:** not offered in a Flatpak, whose sandbox cannot read Immich Mount's settings or keyring ("Verso as
a Flatpak").

### Updates on Linux

A package downloaded from a release page is never updated: no repository stands behind it. **The service can tell of a
new release** (`updates.check`): while it serves the drive, five minutes after it starts and then every 24 hours, it
reads a `latest.json` (the release's version and the page's address) and tells of a version once, in a notification
(the version told of is kept in `~/.local/state/verso/update-told`), and on the tray's menu ("Get Verso *version*…",
which opens the page) for as long as it runs. It sends nothing but the request and its User-Agent.
- **Off and hidden in Verso** (default `false`, left out by `Product::hidden_settings`): Verso has no download page of
  its own yet, and the look reads Immich Mount's (`linux/verso-service/src/updates.rs`). Once Verso has one, the look
  reads Verso's `latest.json` and is on for the rpm and deb packages, which nothing else updates (ROADMAP, M9).
- **Who looks:** not Homebrew's installs (in its Cellar or a cask's folder, which `brew upgrade` keeps current), not a
  Flatpak (its remote updates it), not a development build (version 0.0.0), and not with `updates.check` off.
- **Never replaced in place:** the packages own `/usr`, and files changed under dpkg or rpm break their package
  database. The user updates the way they installed.
- **Flatpak impact:** none; a Flatpak does not look.
- **Not chosen:** GitHub's releases API (rate-limited without a token, and a second host to name in SECURITY.md); a
  check in the window (it runs only when opened).

### Security and privacy

- **Credentials** live in the keyring (`oo7`, which speaks both the Secret Service and the Secret portal): a credential
  opens a whole photo library, so it belongs in a keychain, not in a plain config file.
  - **KWallet** serves the Secret Service through `ksecretd`, which D-Bus can start only by its own name
    (`org.kde.secretservicecompat`); a Plasma login usually starts it through `pam_kwallet`. Where nothing has, the
    keyring code starts it before asking, so a Plasma install without `pam_kwallet` works the same; its first use
    shows KWallet's "create a wallet" wizard. Not where the Secret Service's own name can be started (GNOME Keyring):
    D-Bus starts that one, and KWallet never takes its place on a machine that has both.
  - **The headless fallback** is a file that must be 0600, or the daemon refuses it. An environment variable is
    accepted only in tests.
  - **Never exposed:** credentials never appear in logs, URLs, D-Bus messages, cache paths or crash reports.
- **Mount options:** `nosuid`, `nodev`, `noexec`, and no `allow_other`, so only the user who mounted it can enter, not
  even root; and no `default_permissions`, so the daemon answers `access()` itself ("GNOME integration"). The filesystem
  type is `fuse.immich`, with source `immich`.
- **Logs** (journald): endpoints and timings. No credentials and no request bodies; Asset ids only at debug level.
- **Cache directories** are 0700 and cleared on disconnect. They are not encrypted at rest; full-disk encryption is the
  user's layer.
- **TLS:** rustls with the system's root certificates (`rustls-native-certs`), so private CAs added to the system trust
  store (with `update-ca-trust`, say) work. A certificate the system does not trust is trusted only once the person
  has chosen to trust that certificate for that server ("A certificate of the server's own"). Plain `http://` is
  allowed for LAN servers. Nothing silently downgrades from https to http.
  - **On macOS and iOS the system judges each certificate** (`rustls-platform-verifier`, which the Apple bridge hands
    `immich-api` through `certificate::set_system_verifier` before its first client): iOS lets no program list its
    trusted roots, so with `rustls-native-certs` every server is refused there ("UnknownIssuer"), and the system's
    verifier also follows the trust settings the user and their profiles give, a private CA installed with a profile
    among them. `immich-api` holds no platform code for it: the bridge chooses.
- **Places are named from Immich** (the asset's city, else its state, else its country), on iOS as on the Mac and
  Linux. Apple's reverse geocoding (`MKReverseGeocodingRequest`), which names landmarks and parks as Photos does, runs
  on iOS only once the person switches on Look Up Place Names with Apple Maps, a setting of the device's own
  (`viewer.lookUpPlaceNames`, off), and never for the Locked Folder: it sends each opened photo's location to Apple,
  and a gallery for one's own server should not do that unasked. SECURITY.md says what goes to Apple.
- **D-Bus:** the session bus is the normal same-user trust boundary. The credential never crosses it.

### The app icon's designs on Linux

Preferences, General, offers the app icon's 28 looks (DESIGN.md, "The picture's designs"), freely, one for the
desktop's light style (`app.icon`, Mist by default) and one for its dark style (`app.icon_dark`, Mist Night): each a
row that opens to the picture's seven designs, Day or Night paper, and a lens in colour or graphite. GNOME shows an
app's icon from its launcher entry: in the app grid, in the dash, and for its window, which GNOME Shell knows by the
window's app ID, `dev.hviid.Verso`, as the entry of that name's. So the choice is made in that entry's `Icon` line
(`verso_linux::app_icon`), which names the look of the desktop's current style; a desktop entry has one `Icon` and no
icon per style.

**Two keys, a look each,** rather than one key holding both: each is one choice of the 28 that the settings table
validates and `configure set` takes as it takes any other key, and a design's name alone is a look of its own (`sand`,
Sand on Day paper in colour), so an `app.icon` that names a design stays valid. A look is named by its design with
`-night` and `-graphite` after it as they apply, as its drawing is (`dev.hviid.Verso-sand-night-graphite.svg`).

**Following the style.** The service watches the desktop's colour scheme through the portal
(`org.freedesktop.portal.Settings`, `org.freedesktop.appearance` `color-scheme`, which GNOME and KDE both provide and
libadwaita itself reads: 1 is dark; 0, no preference, and 2 are light) and names the look of the new style in the entry
at each `SettingChanged`, reading the choice again each time; without a portal it names the light style's look. The
window follows libadwaita's style (`adw::StyleManager`'s `dark`): its own icon, About and the sign-in page turn with it
while open, and it names the look in the entry too, so the entry follows the style while either runs. The app grid
catches up at the next login, as for any change of icon (below).

**What Homebrew does with the entry.** The cask installs the entry and the icons into the user's own folders,
`~/.local/share/applications/dev.hviid.Verso.desktop` and `~/.local/share/icons/hicolor/`, as files it moves there
from the version's folder (`Caskroom/verso/<version>/`), after writing its own path into the entry's `Exec`.
`brew upgrade` moves each back into the old version's folder, which it then deletes, and moves the new version's in:
an edit to them is lost with the old folder, and Homebrew never looks at what they hold. Only a missing one stops it,
as it then has nothing to move back.

**What Verso does:**
- **The install's entry in the user's folder** (Homebrew's, the tarball's, a build of one's own) has its `Icon` line
  changed and nothing else, written through a file beside it renamed into place, so it is never missing. Mist's Day
  look in colour is named by the name every install puts in the icon theme, `dev.hviid.Verso`. Another look is named by
  the path of a copy of its drawing in Verso's own folder (`~/.local/share/verso/icons/`), made from the 27 other
  drawings the install carries among the app's own icons (`icons/` beside the programs): under Homebrew the install's
  folder is one version's, gone at the next upgrade. The folder keeps the copies of both looks chosen, so a change of
  style needs only the `Icon` line, and no other. With the defaults, the dark style names Mist Night's copy.
- **An upgrade puts the install's entry back,** with Mist. The service, which starts the new version after an upgrade
  as at every login, names the chosen look again, and so does the window as it starts: the choice outlives upgrades,
  with Mist in the app grid for the seconds between.
- **Over a package's entry** (in `$XDG_DATA_DIRS`, as Verso's rpm and deb will have it), Verso writes an entry of its
  own under the same name in the user's folder, which comes first: the package's with the `Icon` line changed, marked
  as Verso's by its first line, written again at each start so it follows the package's, and removed while the look
  named is Mist's Day look in colour or once the package's is gone. Left behind by an uninstall, it shows nowhere: GLib
  leaves out an entry whose program is not found.
- **GNOME Shell keeps an app icon it has drawn:** its app grid makes each app's icon once and reuses it, and an icon
  reloads on a change of icon theme from the icon it was made with, not from the entry. So a new look shows at once
  in every icon drawn after it (a search, the window switcher, the dash once Verso starts again), and in the app grid
  from the next login, as Preferences says above the rows; a change of style likewise. Verified in a GNOME 50 VM, with
  the entry as the cask installs it: Sand chosen in Preferences, the shell's app info named Sand's copy at once, a
  search showed Sand and the grid Mist until the next session; the install's entry put back, as an upgrade does, the
  window starting named Sand again; `configure set app.icon mist` left the entry as installed, byte for byte.
- **The window** shows the look chosen for its style as its own icon and in About and the sign-in page, by its name
  among the app's own icons; a notification's picture is the copy of the look of the style last named. Verso Drive's
  badged icon, Verso Gallery's Crosslink entry and the top bar icon keep theirs: they are not the app's window.

**Not chosen:**
- **An entry of Verso's own over the install's, in the user's folder:** Homebrew's is already there under the same
  name, and no folder comes before the user's.
- **The chosen design under the app icon's own name in the icon theme:** those are Homebrew's files, which an upgrade
  puts back, and the cask makes an icon cache of the folder (`gtk-update-icon-cache`), which GTK goes by while the
  theme's folder is no newer than it: a file changed or added further in goes unseen until the cache is made again.
- **The looks in the icon theme under names of their own** (`dev.hviid.Verso-sand`): the same cache hides them, and
  the cask would list six files for each look.
- **An app ID per look:** the app ID is the D-Bus name that keeps the window one instance and brings the browser's
  sign-in back to it.
- **GNOME's own setting for the style** (`org.gnome.desktop.interface` `color-scheme` in GSettings): GNOME's alone,
  where the portal's answers on KDE too, and as libadwaita has it.

**Flatpak impact:** no choice. A sandboxed app cannot change the entry its Flatpak exports, so the Flatpak hides both
rows and reads `app.icon` and `app.icon_dark` as Mist and Mist Night (`VERSO_FLATPAK`'s `hidden_settings`), the
service does not watch the style, and `app_icon::apply` does nothing there. Its window, About and sign-in page show
Mist, and Mist Night in the dark style: the Flatpak carries that one drawing more, in its icon theme
(`dev.hviid.Verso-mist-night.svg`), and exports Mist as its icon.

### Packaging

Verso installs as one package with both programs, from two channels today, with a third to come:
- **The tarball** (`linux/packaging/verso-tarball.sh`, built in the Fedora 44 toolbox for x86_64), which Homebrew's
  `verso` cask installs: `verso`, the launcher in front of the window (below); the window, `libexec/verso`, with the
  libraries a desktop may lack (libshumate, libprotobuf-c) beside it in `libexec/lib/` (its run path is
  `$ORIGIN/lib`); the service; the icons; the catalogs in `share/locale`; the desktop entry made from its template,
  whose `Exec` the cask writes its own path into; and the Files extension in Python ("Links on Linux, and the Files
  extension"). The script checks that each program finds every library.
- **The Flatpak** (`linux/packaging/flatpak/`), for our own builds and testing, without the drive ("Verso as a
  Flatpak").
- **rpm and deb packages** of Verso's own come with releases cut by a tag (ROADMAP, M9, step 6), with the C Files
  extension built for each distribution, and a packaging matrix to check them, built after Immich Mount's
  (`lab/packaging/` in its repository).

What an install carries:
- **One launcher entry,** `dev.hviid.Verso.desktop` (`linux/packaging/desktop/dev.hviid.Verso.desktop.in`), named Verso,
  running `verso %u`, with the keywords `Immich;photos;videos;gallery;albums;people;drive;` and the
  `x-scheme-handler/app.immich` handler ("Signing in"). It announces nothing to Immich Crosslink: Verso's two
  participants are entries of their own, written while they take part ("Links on Linux, and the Files extension"); a
  Flatpak's exported entry announces Verso Gallery itself.
- **The user service unit,** `verso.service`, from `linux/packaging/systemd/verso.service.in`; where an install brings
  none, the window writes it ("The daemon's lifecycle").
- **The icons,** `dev.hviid.Verso`, `dev.hviid.Verso.Drive` and the symbolic ones with the tray's states ("The icon"),
  and among the app's own icons the app icon's 27 other looks ("The app icon's designs on Linux"); the Flatpak, Mist
  Night alone, in its icon theme.
- **The translations,** `verso.mo` for each language ("Translations").
- **The license notices:** `linux/packaging/third-party-licenses.py` writes what a binary package must carry,
  `THIRD-PARTY-NOTICES.md` first, then every crate the package's binaries link (from `cargo tree`) with the license
  files it ships, each distinct text printed once; the tarball carries none yet.

**The window links the system's GNOME libraries, GNOME 49's or newer:** libadwaita 1.8 and GTK 4.18 at least (SPEC.md,
"Supported versions"). Verso is built for the current GNOME: the window uses libadwaita's widgets up to 1.8
(AdwShortcutsDialog from 1.8, AdwToggleGroup from 1.7, AdwSpinner and AdwButtonRow from 1.6) and GTK 4.16's CSS
variables. The tarball needs them on the desktop, and the Flatpak brings them in the GNOME runtime.

**The launcher: a script in front of the window,** so that a system whose libraries are too old says why. A Rust
program binds every symbol as it loads (full RELRO, no PLT), so on Ubuntu 24.04 (libadwaita 1.5, GTK 4.14) the loader
stops the window before `main` (`symbol lookup error: ... undefined symbol: adw_shortcuts_dialog_add`), and someone
who opened it from the app grid or a launcher sees nothing. So the tarball's `verso` is a POSIX `sh` script,
`linux/packaging/verso-launcher.sh`, and the window is `libexec/verso` in the same folder, named so that its process
is `verso`:
- It finds its own folder through links (Homebrew's `bin/verso` links to it), then the libadwaita the loader would
  take: the first in `LD_LIBRARY_PATH`, else the one in the loader's cache (`ldconfig -p`, also from `/sbin` and
  `/usr/sbin`, which may be off a user's PATH), else one in the usual folders. It is new enough when it holds a
  function libadwaita 1.8 added, `adw_shortcuts_dialog_new`, whose name `grep` finds in the library's table of symbols
  with no binutils; libadwaita 1.8 needs GTK 4.18, so the one look covers both.
- Too old or missing, it says why on stderr (SPEC.md, "Supported versions") and, started without a terminal, in
  zenity's dialog where zenity is (Ubuntu's GNOME has it), else in a notification (`notify-send`, else `gdbus` to
  `org.freedesktop.Notifications`), and exits with 1.
- Otherwise it `exec`s the window with the arguments as given, adding none: no process of its own stays, and the
  browser sign-in's `app.immich:` redirect and crosslinks arrive as the desktop entry's `%u`.
- What starts the window by its path starts the launcher: the desktop entry's `Exec` (the cask's `bin/verso`), the
  tray's Open and `verso-service app` (`programs::find`), and Verso Gallery's Crosslink entry, which the service
  writes. The window, in `libexec/`, finds its install's programs, icons and catalogs in the folder above
  (`programs::install_folder`), and watches the launcher for an upgrade (`programs::launcher`, "The window and the
  service"), as its own path is one version's folder under Homebrew.
- The service needs none: it loads no toolkit and links no GNOME library, so the loader has nothing to stop it on.
  On an older system the window, which signs in and sets it up, does not start; its command line is for advanced use.
- rpm and deb packages (ROADMAP, M9, step 6) state the libraries as dependencies, which keeps them off an older
  system, so they need no launcher.
- **Not chosen: lowering the floor to GNOME 46,** Ubuntu 24.04's libraries: it gives up the widgets above for systems
  the Flatpak serves already, and Verso is built for the current GNOME.
- **Not chosen: the check inside the window.** It cannot run there: the loader binds every symbol before `main`.
  Lazy binding, or loading libadwaita by hand (`dlopen`), would change how every widget is linked for one message.
- **Flatpak impact:** none. The Flatpak runs on GNOME's runtime, always new enough, and installs the window as
  `/app/bin/verso`, without the launcher. On a system too old for the tarball it is the way to run Verso, without
  Verso Drive.

**Not chosen: AppImage.** No service or autostart integration, the sign-in scheme handler needs extra desktop
integration, and bundling GTK 4 and libadwaita drifts from the host look.

#### Verso as a Flatpak

One build feature, `flatpak` on both programs (`verso` and `verso-service`), makes the product `VERSO_FLATPAK`: Verso's
names, folders and app ID, with `Product::sandboxed` set, which every part that would reach outside a sandbox asks. The
drive is the reason: mounting needs the host's setuid `fusermount3` through host commands (`flatpak-spawn --host`),
which is no sandbox at all, and Flathub does not accept apps whose core needs host components. So the Flatpak leaves
the drive out rather than ask for that.

**What the Flatpak leaves out,** worded for a store listing:

- **Verso Drive.** Your library as a drive in Files and in every file dialog is not part of the Flatpak: it needs
  access outside the sandbox. Preferences says so where the drive's pages are, and points to the Homebrew version,
  which has it. Without the drive there is no Show in Files, no Verso Drive in other apps' Show in, and no menu of
  Verso's own in Files.
- **Show in other apps (Immich Crosslink)** offers one **Show in Another App…**, where you choose the app, rather than
  an item for each app that takes part: a sandboxed app cannot list the others. Other apps still show items in Verso
  (it takes part as Verso Gallery), and Open in Immich and Copy Immich Link work as in every other build.
- **Taking over Immich Mount's account** on first start is not offered: the sandbox cannot read Immich Mount's
  settings or keyring. You sign in as usual.
- **Starting at login** is asked of you by the desktop the first time you sign in (the Background portal), and can be
  changed in its settings; the top bar icon then starts with your session.

Everything else is the same: the gallery, the viewer, editing, sharing, importing (files from the file chooser or
dropped in), the account's and server's settings, and the top bar icon.

**How each part works in the sandbox:**

- **The service** (tray and D-Bus interface) has no systemd unit. The window starts it as an instance of the app's
  sandbox of its own through the Flatpak portal (`flatpak-spawn verso-service daemon`), which outlives the window; a
  second instance whose D-Bus name is taken leaves at once, so there is one tray. It stops on its D-Bus `Quit` (signing
  out, a change of its settings, which restarts it), as the window cannot signal a process in another instance
  (`verso_desktop::sandbox`). The tray opens the window through `flatpak-spawn` too, so it does not close with the
  service. At sign-in the window asks the Background portal to start the service at every login.
- **The drive's settings** are hidden and read as their defaults, the drive off for good (`VERSO_FLATPAK`'s
  `hidden_settings`); `session::set_drive` refuses, `drive_enabled` is false.
- **Crosslink:** no participant entries are written (`participants::sync` does nothing); the Flatpak's exported desktop
  entry carries the scheme and the announcement of Verso Gallery (`X-Immich-Crosslink-Version=0.2`,
  `X-Immich-Crosslink-Shows=asset;album;person;place;page;`), as the protocol's 1.1 has it for a Flatpak. Show in sends
  through the OpenURI portal with `ask` (`crosslink::ANOTHER_APP`), the protocol's second way.
- **Signing in** with the browser comes back through the exported entry's `x-scheme-handler/app.immich`; the window
  does not try to make itself the default handler, which a sandbox cannot.
- **The keyring** is `oo7`'s, which in a sandbox keeps the credential through the Secret portal, apart from the host's
  keyring (a Flatpak signs in afresh), and reads, looks for and removes it there too: the host's Secret Service is out
  of the sandbox's sight.

**What the manifest grants** (`finish-args`): `--share=network`, `--share=ipc`, `--socket=wayland`,
`--socket=fallback-x11`, `--device=dri`, `--talk-name=org.kde.StatusNotifierWatcher` (the tray),
`--talk-name=org.freedesktop.Notifications` (the service's notifications). The D-Bus name `dev.hviid.Verso.Daemon` is
under the app ID, which a Flatpak may own. No filesystem access is needed: imports come through the file chooser and
drag and drop (the document portal), and downloads through the save dialog. Flathub's rules (2026-11): the manifest and
the submission are written by the maintainer, without AI tools, and the AI-written code is disclosed with its extent.

#### The drive in a Flatpak: kept possible

Verso's Flatpak leaves the drive out ("Verso as a Flatpak"). A drive inside one stays possible, parked as too much work
for now, and the rules at the end of this section keep it cheap.

A Flatpak can mount FUSE the way Pika Backup (a GNOME Circle app) and Vorta do on Flathub: it builds its own libfuse
(`-Duseroot=false`); a `fusermount` wrapper runs the host's `fusermount3` through `flatpak-spawn --host`, forwarding the
FUSE file descriptor; it needs `--device=all` and `--talk-name=org.freedesktop.Flatpak`; and it mounts at a path both
sides see (Pika uses `xdg-run/pika-backup:create`). The mount is then a normal host mount, served from inside the
sandbox. Verso's would also need `--filesystem=~/Verso:create` and `--filesystem=xdg-cache/thumbnails` (the host's
cache), and would lose the safety net: FUSE reports host process ids, which the sandbox's `/proc` cannot see.

The host-command permission is effectively no sandbox, so such a Flatpak would be a delivery channel, not a security
boundary. Flathub's linter flags it as a warning (`finish-args-flatpak-spawn-access`), not an error, and acceptance is
at the reviewers' discretion (Pika Backup ships with it); but Flathub does not accept apps whose core needs host
components, so a Flatpak with the drive would ship from our own Flatpak repository.

**Comparison: Nextcloud.** Nextcloud's client is on Flathub with ordinary permissions (`--filesystem=host:rw`, the
keyring, a tray) because on Linux it **syncs real files** into a local folder: no FUSE, no host commands. Its Files
menu items come from a separate distribution package (`nautilus-nextcloud`), not from the Flatpak.

**Not chosen: a sandboxed Flatpak that syncs instead of mounting.** Flathub-friendly, but an unprivileged app has no
placeholder files that fill on read (sparse files read as zeros), so **every file would have to be the downloaded
original**; **syncing everything** means downloading the library, which is never acceptable; **selective sync** breaks
the "any photo from any file dialog" use case; and **freeing space** could only delete local copies, so photos would
vanish from the folder.

These rules keep a future Flatpak cheap:

| Rule | Why it matters inside a Flatpak |
|---|---|
| Mounting goes through one replaceable **mounter**: `fusermount3` natively, a host wrapper later | The sandbox cannot run the setuid helper |
| The daemon's logic never assumes **systemd**; startup lives in packaging, and `sd_notify` is optional | A Flatpak starts in the background through the Background portal |
| Every path goes through the **`Dirs` trait**, and the thumbnail cache is addressed as the host's `$HOME/.cache/thumbnails` | Flatpak remaps `XDG_CACHE_HOME` to a private directory that thumbnail lookups never read |
| Secrets go through **`oo7`** | It speaks both the Secret Service and the Secret portal |
| The browser opens through the **OpenURI portal**, not `xdg-open` | Spawning host programs is unavailable |
| **D-Bus names live under the app ID** | A Flatpak may only own names under its app ID |
| The **safety net is optional** and degrades silently | The sandbox cannot see host processes in `/proc` |
| No host programs besides `fusermount3` | Each would need another host call |

Every design change states its Flatpak impact against this table.

## The Mac

On the Mac, Verso is Immich Gallery's app made Verso's, with Verso Drive's File Provider extension embedded in it,
both over the shared crates through `verso-bridge`. Their code is in `mac/`: the Xcode project's sources
(`mac/Verso/`: the app, its widget and its checks), the extension (`mac/FileProvider/`), what the app and the
extension both read (`mac/Shared/`), and `mac/build-rust.sh`, which builds the bridge for Xcode. They build only on a
Mac (AGENTS.md, "Development environment").

### Verso on the Mac

Verso's Mac app is built from [Immich Gallery](https://github.com/IGOLz/ImmichGallery), Alessandro Craciun's native Mac
client (MIT), taken from the maintainer's fork at `50bb4c3` (CREDITS.md) and made this repository's: named Verso
throughout, its endpoint calls sent through the shared Rust core, built by XcodeGen, versioned on the one line. It links
the bridge (`shared/verso-bridge`, built by `mac/build-rust.sh`). ROADMAP, M8, "Verso on the Mac", has the steps still
to come.

```
 mac/Verso/Verso (SwiftUI: views, app state, ImmichClient and its models, from Immich Gallery)
        │ endpoint calls: ImmichClient.apiData(for:)          media: ImmichClient.data(for:), URLSession
        ▼                                                             │ (its cache keeps thumbnails)
 Verso/Core/CoreTransport ─▶ VersoCore (CoreConnection + the bridge's bindings)
        ▼                                                             │
 verso-bridge (ApiConnection) ─▶ immich-api (Client::send_composed) ─▶ Immich ◀──┘
```

- **The layout follows Immich Gallery's targets:** `Verso/` (the app: `API`, `App`, `Views`, `Support`, its string
  catalogs and assets), `Shared/` (the app and the widget), `Widget/`, `Config/` (Info.plists and entitlements),
  `Tests/` with its runner `check.py`, and `project.yml`, from which `xcodegen` writes `Verso.xcodeproj` (not
  committed). Verso Drive takes the place of Immich Gallery's Finder extension. Not taken: its Xcode project, its
  release, disk image, Homebrew and release-issue tooling, and its design notes (`docs/`): a comment citing
  `docs/FileProvider.md` or the like means that file in the fork at `50bb4c3`.
- **Immich 3.2 and newer,** as on Linux and immich-api: Immich Gallery's code for older servers (v2's separate album
  owner and shared-albums parameter, the upload's device identifiers, the check whether a server sorts by Date Added)
  is not kept, nor its migration from its own earlier installs, which a new app has none of. Sign-in shows an older
  server in orange.
- **Named Verso, with Verso's identity:** Verso's names throughout (types, strings, file names, URL schemes `verso`
  and `verso-dev`, keychain services), Immich Gallery named only in the credit. The bundle identifier is
  `dev.hviid.Verso`, a Debug build's `dev.hviid.Verso.Dev` (Verso Dev), each with an App Group of its own. The About
  panel credits Immich Gallery, Immich Mount and immich-rs, carries the AI disclosure, and has the non-affiliation
  notice as its copyright line (`Config/Info.plist`).
- **Its endpoint calls go through the shared Rust core.** Every endpoint call of Immich Gallery's `ImmichClient` goes
  through `apiData(for:)`. With the core installed (`CoreTransport.install()`, first thing in the app), that hands the
  request to a `CoreConnection`, one per API address and credential, which sends it through the bridge's
  `ApiConnection` and immich-api's `Client::send_composed`: the core adds the credential, the user agent
  (`verso/<version> (macOS)`), retries as the method allows and the reachability gate, and the answer comes back as
  data and an `HTTPURLResponse`, or a `URLError` when none came, so the client's error handling, endpoint methods and
  models stay as they are.
  - **Why the requests and not the endpoints, first:** immich-api's models are reshaped from Immich's wire format (an
    `Album`'s description is a string, never null, its dates typed), so a typed call per endpoint means new Swift
    models and decoding for every page of an app that already works. Composed requests move the whole app onto the
    core at once and change nothing it decodes.
  - **Media stay on the app's URLSession:** thumbnails, originals, videos, profile pictures and archives go through
    `data(for:)` and the account's session, whose `URLCache` keeps them, and through `AVPlayer` and downloads to
    files. The core has no cache of its own for the gallery's pictures on the Mac yet.
  - **The offline checks install no core,** so their URLProtocol fixtures answer through the session; `check-core.sh`
    checks the core's way live.
- **Typed calls, an area at a time,** take the place of composed requests: immich-api's own requests and decoding,
  the Linux gallery's, through typed methods on the bridge's `ApiConnection` and `CoreConnection`, answered into the
  app's models by `CoreTransport`. They are `ImmichTransport`'s optional calls: one the core does not answer goes as
  a request, so the offline checks and any query a typed call does not cover go on as before. Failures keep their
  kind (`CoreError`) and arrive as the client's own errors: a refused session as `ImmichError.unauthorized`, which
  signs out; an unreachable server, or one still busy (5xx) after immich-api's retries, as a `URLError`; a request
  the server turns down with a status of its own (a validation failure's 400, a wrong PIN code's) as
  `ImmichError.http` with that status and the server's reason (the bridge's `BridgeError::Refused`, read by
  immich-api's `ApiError::refusal`).
  - **Typed:** the timeline, for every query one of immich-api's scopes asks exactly (`TypedTimeline.call`), the
    albums, people, a photo's details, sharing's lists, search (as the flat fields Immich's web app sends, paged by
    number or by cursor), the server's, the account's and Explore's reads, what surrounds a photo, administration's
    lists, and the changes the app makes. Changes to many answer each one's outcome, so a duplicate is still no
    failure. immich-api grew what the app reads: `TimelineOptions::stacked` (the Mac shows every timeline stacked),
    each Asset's country, `Client::people_page`, `Client::flat_search` (its `filter` dialect pages smart search not at
    all), each album's last change, and `ServerFeatures`' switches.
  - **Still requests, each for a reason:** the map's area query, which no scope asks; administration's server
    settings, overview and a library's path check, shown as the server's own JSON; and the account's preferences,
    which immich-api keeps mostly as raw JSON while the app's models read more of them, so a typed call would only
    pass the JSON through.
  - **Signing in with a password and out** go through the core's sign-in, as on Linux (`sign_in_with_password`,
    `end_session`). Finding the server stays the app's: it reads `/.well-known/immich` for the API's address and, for
    an address typed without a scheme, tries `http://` after `https://`, which the core's sign-in does not. So does
    browser sign-in, until it can be checked through the lab's Dex from the Mac.
  - **Checked both ways:** `check-core.sh` asks each source typed and as a request and compares them field by field,
    and with `IMMICH_WRITES=1`, on a lab server only, makes each change typed and reads it back as a request (the
    mac-dev skill).
- **The bindings have a module of their own,** `VersoCore` (a static library target: the bridge's generated Swift
  and `VersoCore/CoreConnection.swift`, in Swift 5's checking, as uniffi writes it), because the bridge's
  `Credential` and `Item` would meet the app's types of the same names in the app's module. The app and the Finder
  extension link it and the bridge's xcframework.
- **What the gallery arranges comes from the core, an area at a time** (ROADMAP, M9, step 8), where Linux's window
  arranges the same in Rust: the bridge's `arrangements` hands the Mac and the iPhone what `verso-core` works out, so
  the three platforms agree, and the core's and the bridge's tests check it on Linux. From the core so far: the
  Library's Years and Months (`verso_core::overview`); the map's clusters, each with the box Immich's timeline takes
  (`verso_core::map`; fitting the map to the photos stays MapKit's, `ExploreMapFit`); the Duplicates page's order and
  what each group keeps at first; which shared links show, and whether one has expired; People's filter, with what
  Immich v3.3 and later filter themselves; Places' cities alone or by country, by visit or by name
  (`verso_core::places`); and the date scroller (`rail`; "The date scroller"). The views hand over plain records
  (buckets with their counts, photos with their dates, ids and coordinates, choices by the codes the settings keep
  them by, which are Linux's) and get places back by index; the records are `Identifiable` for SwiftUI's lists
  (`VersoCore/CoreConnection.swift`).
  - **The order of names is the platform's,** in the person's language, which the core does not know: the Mac and the
    iPhone hand each name over with its place in Finder's order (`localizedStandardCompare`, names alike sharing one),
    so Å comes after Z in Danish and beside A in English, and Linux's window orders by lower-case letters
    (`places::caseless`). Not chosen: a collator in the core (ICU4X's), a large dependency whose order would still
    differ from the system's here and there.
- **An album's name and description are text on its page,** changed with Edit Album (`AlbumActionsView`), never in
  place: a field in the header takes the keys the grid answers (Space, the arrows) while one types. A person's name is
  edited in place on their page.
- **Signing in** is to one account, as on Linux: a password, an API key or single sign-on, kept in the app's Keychain
  (`AccountVault`, one item), which the next sign-in replaces and Sign Out forgets. Immich Gallery's saved accounts
  are left out: Verso is one person's library on one server, and its drive and its menu bar item follow the one
  account. Settings' Account names the sign-in only for an API key: a session from a password and one from a browser
  look the same afterwards.
  - **Signing out closes the account's connection without invalidating it at once** (`ImmichClient.close`): new
    requests on it stop as cancelled, and it is invalidated half a minute later, as URLSession aborts the app when a
    task is made on an invalidated session, which a thumbnail still loading as the grid goes would do.
  - **Kept on the device:** the account and the drive's credential are
    `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: readable after the first unlock, as the extension and backing
    up in the background need, and never carried to another device by a backup, Quick Start or Migration Assistant,
    as either opens the whole library; the cost is one sign-in on a new device. On the Mac that means the data
    protection Keychain (`kSecUseDataProtectionKeychain`): the login Keychain, where a Mac app's items go unless it
    asks, ignores the setting and travels with Time Machine and Migration Assistant. An item kept otherwise is
    converted as it is read (on the Mac, moved out of the login Keychain, which Sign Out also clears).
- **Dragging originals out,** as Photos does: a photo in the selection brings the whole selection, in the grid's
  order, one outside it only itself; nothing is downloaded before a receiver asks for the file. The grid ("The photo
  grid on the Mac") drags as AppKit drags files, on macOS 15 and 26 alike: each photo a promised file
  (`OriginalFilePromise`, an `NSFilePromiseProvider`), its original in its own format under Immich's name, then the
  in-app marker (`dev.hviid.Verso.original-drag`, declared in the app's Info.plist) and its ID for album drops. An open
  photo drags its own original (`OriginalTransfer`; on macOS 15 `legacyAssetDrag`).
  - The timeline has no names, so a drag reads its photos' details as it starts (`OriginalDrag`: 16 at a time, waited
    for at most a second), and one whose details have not arrived is named after its asset. A name an earlier photo
    in the drag already has, whatever its case, gets a number before its extension, as Finder numbers a copy
    ("IMG_0001 2.HEIC"), so a drop never has two files of one name. A Live Photo brings its still, every photo its
    unedited original.
- **Share opens the system's share picker at once** (`NSSharingServicePicker`, `Views/Sharing/SharingActions.swift`;
  SPEC.md, "Sharing from the Mac"), as Finder's Share… opens it and the iPhone's Share its sheet. Each photo is a
  promise of its original (an `NSItemProvider` that downloads only when the chosen service loads it), answered with
  the downloaded file's own address in the share's folder of the temporary directory, as on the iPhone; the file goes
  when the service says it is done or failed, and one a service never closes is swept an hour later, at the next share
  or launch. Each item carries its header (`NSPreviewRepresentingActivityItem`, with a thumbnail already in memory),
  so the picker draws without loading a photo. Create Link… and Add to Link… are custom `NSSharingService`s its
  delegate adds. Not chosen: a menu with Share Original Files…, which downloads every original before the picker
  opens.
- **Rotate and Crop change Immich's edit list as Linux does** (`MetadataEditList` in `Models+Metadata.swift`, the rules
  of `actions::rotated` and `cropped`): one rotate step, turned as the photo is seen (a mirror after it reverses its
  direction), added last and removed at zero; the crop first, in the upright original's pixels; a mirror made in
  Immich's web app stays. The Mac's Rotate and Crop and iOS's editor share the one implementation, which
  `verify-metadata.swift` checks for every list of up to four turns and mirrors, with and without a crop.
- **Live Photos move as the iPhone's** ("The viewer on the iPhone", "Live Photos";
  `Views/Viewer/ViewerLivePhoto.swift`): stepped to, a Live Photo plays the iPhone's glimpse, the 0.6 s of its motion
  up to the key photo, without sound, the last 0.17 s slower, then a 0.25 s fade into the photo, from the same cached
  original (`LiveMotions` and its timing, which both apps compile) over its whole coded frame (`.encodedPixels`), drawn
  on the photo so it zooms, pans and turns with it. Opened from the grid, nothing moves.
  - The glimpse starts as the step does and comes to rest a moment after the photo lands, as Photos' does: the step's
    slide, which covers the viewer for 0.36 s, carries the motion over the photo's picture (`slideLayer`, a second
    layer on the same player). A swipe starts it once the photo coming in is 65% across, and stops it if the swipe
    goes back.
  - Each viewer keeps the motions of its photo and of the two beside it (`LivePhotos`) downloaded and cued in a
    player, so a step finds its motion ready. One not ready within 0.1 s of the step does not play: a photo moving as
    it lands or after would be content moving as it loads. Each photo gets a new viewer, so which photo a viewer
    showed tells a step from an opening.
  - ⌥Space and the toolbar's Live play the photo whole, as a press does on the iPhone, back at the still in 0.3 s.
    The LIVE badge is the iPhone's one switch for every Live Photo, kept under the iPhone's key
    (`viewer.livePhotosStill`); with Reduce Motion on it reads OFF.
  - Not chosen: the transcoded video Immich plays, which shows the Camera's stabilised crop, 10% too large, and jumps
    where it meets the photo.
- **No in-app updates yet:** Immich Gallery updates itself with Sparkle from its own feed, signed with its own key, so
  a copy keeping it would install Immich Gallery over Verso. Sparkle waits for a feed of Verso's own Mac releases
  ("Verso's releases").
- **The map goes under the toolbar as content that does not scroll** (`ExploreMapView`): laid out in the window's
  safe area, its edges carried on under the toolbar and the sidebar as a mirrored, blurred copy
  (`backgroundExtensionEffect`), so its top has the light blur with no edge the scrolling pages have. Under the
  toolbar `MKMapView` puts an `NSScrollPocket` of the hard style over its top (a more opaque band with a hard edge),
  the titlebar then has none, and SwiftUI's `scrollEdgeEffectStyle` reaches only scroll views; laid out in the safe
  area, that band is clipped away, and MapKit still keeps its controls and Legal label clear of the toolbar and the
  sidebar. On macOS 15 the map runs under the toolbar's own background. Not chosen: the map in a scroll view that
  does not scroll, as Apple keeps the edge effect for content that scrolls (Human Interface Guidelines, "Scroll
  views").
- **Pages after Linux's designs,** where Linux's work better than Immich Gallery's (the maintainer's choice), each in
  the Mac's own controls:
  - **A link to chosen photos has a page of its own,** as an album has (`SharedLinkDetailView`), rather than a list of
    its files; ⌫ there takes photos out of the link and never deletes them, as they are the library's.
  - **Shared Links are cards** (`SharedLinkCard`) showing some of what each shares; a link's chosen photos are read
    whole as the card first shows (`LinkPreviews`), as Immich lists a link with its first photo only.
  - **Search's people** show the first twelve in Immich's order with any already picked, and Show All for the rest;
    a name typed asks the server (`people_page` with a name), so it finds anyone. Only the faces shown are read.
  - **Imports go where they were dropped,** as on Linux (Verso's window, "Where imports go"): on the library, or on an
    album's sidebar row, cover or page for the album; File > Import… on an album's page adds to it. On an album the
    account may only view, the pointer refuses the drop, as Finder's does over a folder it cannot write. A row of the
    Albums page's list (`dropDestination` on its `TableRow`) cannot refuse one as it comes, so the import at the
    sidebar's foot says why nothing was imported.
  - **An import shows at the foot of the sidebar** (`ImportSidebarStatus` over `ImportStatusRow`, which takes a plain
    `ImportStatus` so `check.py` can render every state), as on Linux (Verso's window, "An import shows at the foot of
    the sidebar"), so a drop always shows what it came to; Immich Gallery's import, a toolbar item hidden by default,
    showed nothing. The queue (`UploadQueue`) hands what an import came to to the bell. The bell is orange while a
    notification asks something of the person, by one rule and one count for both apps
    (`App/NotificationCount.swift`), so the Mac's bell and the iPhone's ring agree.
  - **The window keeps a toolbar of its own** (`GlobalToolbar`), which every page adds its items to; its one item,
    Import, is hidden by default. With a toolbar for each page, macOS 27 swapping them as the page changes ends in an
    assertion in AppKit's toolbar layout (`NSToolbarItemViewer minSize`), a crash.
  - **How far an album or a link reaches** (`SharingReach`) is the widest of its people and its links still working:
    Private, people, a link with a password or a public link, one icon wherever it shows.
  - **An album's, a person's and a link's statuses and actions are a row under their name** (DESIGN.md, "A page
    header's controls are statuses"); their own top bar items are handed to the grid (`gridPageControls`), which shows
    them after its zoom.
  - **An album's order is its own** (`AlbumOrders`, the Mac and iOS alike), newest or oldest first, so a trip reads
    from its start while a work album shows its latest (the maintainer's choice). Its owner's is the one Immich keeps
    with the album (`order`), which every viewer and Immich's web app follow; anyone else may choose one for that
    album on this device, which counts before the owner's, as they cannot change the album. Newest first, Immich's
    default, until someone chooses. **Not chosen:** one order for every album, as the timeline's is: a trip and a
    work album want opposite ends.
  - **Sharing an album has one way in** (`AlbumSharingSheet`): one sheet with People and Links, opening on Links, as
    on Linux, and on People from the + beside the album's people.
  - **Assign Location**, the page's main action, starts with only the photos without a location. **The sidebar's
    albums** list five, by their newest photo, until changed in the section's menu.
  - **A memory is a card** (`MemoryCard`) with a bookmark that keeps it (`isSaved`, through immich-api's
    `update_memory`), as Immich's cleanup removes a memory after 30 days unless it is kept. A memory opens as a
    gallery, as an album does (`MemoryDetailView`; the maintainer's choice): its photos in its order, to open, select
    and take out of it. Opening it marks it seen. One opened from the widget plays in a window of its own.
  - **Cards and tiles have five sizes** (`CardSize`), as on Linux, one for all card pages, remembered (`cards.size`),
    the smallest by default. A step always changes what shows: − and +, ⌘− and ⌘+ and a pinch skip a size that fits
    as many cards in a line as the one shown at the page's width (`CardLayout`, which counts as SwiftUI's adaptive
    columns do), and − or + is off where no size is left that way, so a step never only widens the same cards.
  - **A pinch goes through the card sizes, and the page keeps its place,** as the iPhone's card pages do ("The card
    pages on the iPhone"; `CardZoom`): a size each time the fingers spread or close by a quarter more, laid out at
    once, the card under the fingers kept where it was (under − and +, the card in the middle). The page scrolls to
    the card again once the lazy grid has laid out the new size, as its first guess of the places can be off. Not
    built: the iPhone's motion between sizes, which wants the cards on AppKit's collection view (ROADMAP, M8, "What
    the Mac takes from the iPhone").
  - **An album is a card at every size** (`AlbumCard`), as on the iPhone, its photos read from the album's newest
    months as the card first shows and kept until the album changes (`AlbumPreviews`). Not chosen: Photos' cover,
    with the name and the count under it, at the smallest size, which the iPhone leaves out too, as one page of two
    looks.
  - **A country is a card,** as on Linux, but without the years its photos span: the cities list (one photo per city)
    does not carry them.
  - **Add to Album… opens a chooser** (`AlbumChooser`) with a search field, as Mail's Move to… does, since a submenu
    of every album grows too long to use (the maintainer has some 50).
  - **Places sort by when each was last visited,** most recent first by default (the maintainer's choice); a place's
    last visit is the date of its newest photo (`PlaceVisits`). Immich's list of cities brings one photo for each,
    often the newest but not always, so the page sorts by those at once, reads the exact dates in the background (one
    search for each city's newest photo, six at a time) and takes them all at once, so the cards move once; they are
    kept on disk for the account, so a later visit sorts exactly from the start.
  - **When the server cannot be reached,** a banner under each page's header says so, with Try Now
    (`ServerUnreachableBanner`). As on Linux, a request failing in a way that may mean the server went away has it
    asked (`ping`, at most every 10 seconds), and only no answer makes it unreachable: a busy server (a 5xx, a 429)
    or a slow request has not gone away. Then the core is told (`ApiConnection::set_reachable`), so its requests fail
    at once rather than wait out their timeouts, and the server is pinged every 10 seconds and on a change of network
    until it answers; then what failed reads again, and nothing is rebuilt, so an open sheet stays. A session that
    ends leaves the core's connection, which outlives it, taking the server as reachable. Pictures still go through
    URLSession and are not held.
- **The menu bar item** is Verso's top bar icon on Linux (SPEC.md, "In Finder (Verso Drive on the Mac)"). Its colour
  is an app setting rather than `tray.colour`, as the extension never draws it.
- **The icons are Verso's,** drawn for the Mac from `linux/packaging/icons/dev.hviid.Verso.svg` by `make-icons.py`
  ("The icon").
- **Verso Dev** signs in and out, and switches Verso Drive, from launch arguments (`AppModel.followLaunchArguments`,
  Debug builds only), so a script can drive it; the mac-dev skill has them.
- **Flatpak impact:** none; this is the Mac's.

### Verso Drive on the Mac

The same library in Finder's sidebar and in every file dialog, through Apple's File Provider, on the same core as
Linux: Verso Drive's extension (`mac/FileProvider/`, the target `VersoDrive`), which Verso's app embeds, signs in and
switches on. It is the extension of Immich Mount's Mac edition, shipped in Immich Mount's releases since 2.14.2; what
is still to be checked of it in Verso is in ROADMAP, M8, "Verso Drive", and what it does is SPEC.md, "In Finder
(Verso Drive on the Mac)". A claim marked *verified* was seen with Immich Mount's Mac edition against the lab server,
unless it names Verso.

```
 Finder, file dialogs ──▶ fileproviderd (macOS: the item replica, downloaded originals, eviction)
                                  │ started on demand
            File Provider extension (Swift, sandboxed, NSFileProviderReplicatedExtension)
                                  │ uniffi
            verso-bridge (Rust) ─▶ core: tree, names, metadata store ─▶ immich-api ─▶ Immich
                                  ▲
                                  │ App Group container, Keychain group, signals
            Verso.app (the gallery, its menu bar item, Settings): the account, the drive's switch, settings, status
```

**Why File Provider:** it is how macOS shows remote storage (iCloud Drive, OneDrive, Dropbox): files that download
when opened, eviction under storage pressure, the Finder sidebar and every file dialog, with no kernel extension.

**Not chosen:**
- **macFUSE or FUSE-T.** The Linux adapter would run nearly unchanged, but macFUSE is a kernel extension that Apple
  silicon Macs load only after lowering their boot security, and FUSE-T serves NFS from user space. Neither gives
  Finder's download progress or eviction, and both make users install a third-party filesystem first (principle 9).
- **The extension written in Rust** (through `objc2`'s File Provider bindings). One language, but every call into
  Apple's frameworks becomes unsafe foreign code, and Apple's documentation, samples and error messages speak Swift.
  The Swift layer stays a thin pass-through, so the logic stays in Rust, where Linux tests reach it.

**Two processes, as on Linux,** but macOS decides when the extension runs:
- **The extension** answers the system: listings, item details, originals, thumbnails, changes and uploads. The
  system starts it on demand and stops it when idle.
- **Verso's app** keeps the account for it, switches it on and off, shows its settings and status, and keeps changes
  flowing while it runs (below). Quitting it stops only the change signals; the extension serves Finder on its own.
- **Only the extension opens the metadata store.** redb allows one process, and the extension is the one that needs
  it.
- **Status goes through a file.** The extension writes what it last saw of the server (reachable or not, when, the
  server's version) to `status.json` in the App Group at each change check, and the app reads it each time it wakes
  the extension. A file outlives the extension, which the system stops when idle, and needs no connection. **Not
  chosen:** the File Provider service channel (`NSFileProviderServiceSource`), an XPC connection through one of the
  location's items: it works only while the location is on and the extension answers, and asks more code of both
  sides for a few lines of status.
- **Shared through the App Group container:** `config.toml` (the settings table of Linux), the store and the
  extension's own files. **Shared through a Keychain access group:** the credential. The App Group is team-prefixed
  (`<team>.dev.hviid.Verso`), which needs no provisioning entry; `group.` names do. Both targets read the groups from
  their Info.plists (`VersoAppGroup`, `VersoKeychainGroup`). A free Personal Team provisions the App IDs, the App Group
  and the Keychain group.

**The app's side** (`VersoDrive.swift`, and `VersoCore/DriveCore.swift` over the bridge): off until switched on
(`mount.enabled`, false by Verso's default; the bridge's `drive_switched_on`); switched on and signed in, it keeps the
gallery's account (its session or API key) where the extension reads it and adds the location (one File Provider
domain, `library`), which another account's sign-in replaces, its location and store first removed. It wakes the
extension every ten seconds, soon after a change made in the gallery and as it comes to the front, and has the system
read every item again when the bridge's item format changes ("Content", below). Signing out takes the location away,
keeping files not yet uploaded, which macOS keeps, and forgets the drive's account and store; the switch stays. The
session is the gallery's: the drive never ends it.
- **Not yet** (ROADMAP, M8, "Verso Drive"): Finder's Show in Another App… ("Finder's actions", below), the question
  about folders copied into Upload ("Folders copied into Upload"), unmounting that only unmounts, as on Linux, and
  starting at login while signed in, so changes keep reaching Finder with the app closed.

**Identity.** An item's identifier is its `NodeKey`'s storage key, the text form the store already keys names by;
`NodeKey::Root` is the root container. One item per Appearance, as on Linux. A parent is derived from the key itself
(an Asset's parent is part of its key, a month's is its year), except an album under year folders, whose year is
looked up in the album list.

**Content.** The system asks for an original when something opens the file. The extension downloads it whole into a
file the system then keeps, and evicts under storage pressure; the block cache is not used. Every item's content
policy is to download lazily, from which the system derives the eviction capability (the policy replaces macOS 11's
capability), so Finder offers "Remove Download" on a file or a folder, which frees the local copies and leaves the
library alone. The system keeps the details of items it holds, their capabilities and policy included, so the bridge's
item format is part of every item's version: a release that changes what items carry raises it, and the app, seeing a
new format at launch, has the system read every item again once.
- **A reimport** (after a new item format, or a settings change) drops the system's database: it then finds what is on
  disk again and offers each as a new item, marked "may already exist". The extension answers with the item the
  library has under that name in that folder, so the two are one. **Not chosen:** refusing it, as a read-only folder
  refuses new folders: the system then keeps its own copy beside the library's, renamed ("People 2").
- **The import after a reimport waits on macOS,** which runs it at a priority it defers, on a Mac in use for ten
  minutes and more. Until it runs, everything below the sections is the system's own local copy, not yet matched to
  the library, with no "Remove Download" on it (ROADMAP, M7, has the open question).
- **Partial fetching** (`NSFileProviderPartialContentFetching`, macOS 12.3 and later) would bring range reads back
  for long videos (ROADMAP, M7).

**Thumbnails.** The system asks the extension for each item's thumbnail at a size, and the extension answers with
Immich's small thumbnail (250 pixels on its short side) up to 320 pixels, and its preview (1440) above. Nothing is
seeded, and there is no safety net: QuickLook's thumbnail service, which Finder uses, asks the extension and leaves
the original undownloaded (verified).

**Changes.** The system keeps a replica of every item it was shown, and learns of changes only by asking the working
set what changed since a sync anchor (Apple's documentation):
- **The change journal.** When the tree keeps a folder's new listing, the store compares it with the kept one and
  appends one record per item that appeared or changed, numbered in sequence. What went away departs: its deletion
  is settled once the poll's folders were all listed again, and recorded only if no kept listing holds it then, so
  an album whose year folder changed (the `year-folders` layout keys an album without its parent) is moved, not
  deleted. The anchor is the store's identity and a sequence number. Old records are trimmed past a limit, and an
  anchor older than the oldest record is expired, after which the system enumerates again. Linux does not use the
  journal.
- **Who polls.** The extension owns the poll (the same ETag and sync-stream poll as Linux) and lists again the touched
  folders the system holds, which writes the journal. The touched folders are marked in the store before the poll's
  memory is kept, and leave the mark only once listed from the server (an older listing does not count), so a folder
  the server cannot list now, or one past the poll's 20-second budget, is listed at a later poll; a listing shown
  while a change came is kept and marked the same way. The app signals the working set every 10 seconds, as often as
  Linux polls, which wakes the extension. The poll's ETags and counts are kept in the store, so an extension started
  again still sees what changed while it was stopped; for a session the sync stream's next records are then changes,
  not a baseline. The server is asked only when the system has caught up with the journal.
- **A folder that went away** takes what the store kept below it: its deletion and its contents' are recorded, and
  its kept listing goes, so later polls stop asking for it.

**Settings.** Verso's Settings window has a Verso Drive pane (`VersoDriveSettingsView`): the switch, the status while
the drive is on, then the drive's settings from the bridge's `settings_panes`, generated from the core's settings
table, the entries that mean something on macOS with Linux's labels, held by a test to the layout every edition
shares ("One layout for every settings window"). A change is written to `config.toml` in the App Group, and the app
asks the system to list everything again; the extension follows it at the next folder the system asks for, with a new
tree on the same store. The drive's name (`mount.name`) is not among them: Finder's sidebar shows the extension's name
for a provider's only location, and a location's own name only as a suffix once there are two (verified; Nextcloud
and OneDrive show the same), and Apple offers no way to set it. The location still carries the setting's name, as its
folder's: adding the domain again under a new name renames it in place, items and downloads kept, and the app does so
each time it brings the drive up.

**Uploads.** The Upload folder lets items be added; every other folder stays a read-only view. The system hands the
extension a finished file, which goes through the core's admission (photos and videos only, AppleDouble `._` files
refused), its completeness check and its upload sequence, duplicates included; there is no staging, which Linux
needs because files arrive there in writes. Links and aliases are refused before anything is sent; folders are
taken, and the files in them go the same way ("Folders copied into Upload", above). An uploaded file stays in Upload
for about 10 seconds, as on Linux, then a journal record takes it away: the system must have taken the item before it
hears that it went. Pending departures are kept in the store, so a stopped extension still records them. Until it
leaves, the extension answers for the item from that list; the same bytes added twice under two names are one Asset
and one item, which the system merges. Until the upload succeeds, the system keeps the file and retries.

**Finder's actions.** Open in Immich and Copy Immich Link are the extension's own actions (SPEC.md, "In Finder"),
from the core's map ("Links to Immich"). The extension opens the address and sets the pasteboard itself, as Immich
Mount's Mac edition does, so the actions work while Verso's app is not running. Finder decides from each item's `userInfo` whether to
offer them, so the bridge's items carry `hasWebLink`, which is part of the item format ("Content"). Finder looks the
actions' names up in the extension's own `Localizable.strings` ("Translations").
- **Not chosen: handing the action to the app** (a file in the App Group and a Darwin notification): it would fail
  whenever the app is not running.
- **Show in Another App… is not offered yet.** Its half in the extension is there (`Actions.swift`,
  `mac/Shared/ActionRequest.swift` and `OfferedApps.swift`); the app's is not, so the action is left out of the
  extension's Info.plist. The design: Finder's actions are declared in the Info.plist with fixed names, so a list that
  changes cannot be one action per app, and the Mac takes the protocol's second way to offer Show in, one action for
  every app that takes part: with one app offered for the item it sends straight to it, with several it asks which
  in an alert (**Show in Which App?**). The app finds the apps (an extension may not ask Launch Services about other
  apps' bundles from its sandbox) and writes what is offered to the App Group (`crosslink-apps.json`); the extension
  marks the items Finder offers the action on (`userInfo`, part of each item's version). An extension shows no
  interface, so the action writes the request (the item) into the App Group's `actions/` and opens the app's own URL
  scheme with that request's one-time token alone; the app takes a request once, only while it is fresh, makes the
  link itself from the item, and sends it only to an app offered for that item's kind.
  - **Not chosen: a menu at the pointer,** popped up by the app once Finder's menu has closed: a menu opened from
    nothing, which macOS has no pattern for, taking focus from Finder with no window to show for it.
  - **Not chosen: an action per known app** (Show in Immich Gallery): only an app named in advance could have one.
  - **Not chosen: a Finder Sync extension,** which can build its menus as they open: Apple directs File Provider apps
    to their actions instead, and it would be one more extension for the user to switch on.
  - **Not chosen: the link in the URL.** Any web page can open an app's URL scheme, so a link carried there would let
    a page make the app send something to another app without a click; the App Group is the extension's and the
    app's alone.

**Signing in.** The extension signs in with the account the app keeps for it ("The app's side"), and asks the user
nothing. The app reaches the server before the extension ever runs, so macOS's Local Network prompt (macOS 15 and
later, for a server on the LAN) names the app, and the extension shares the app's answer (Apple's TN3179).

**Build.** Nothing generated is committed. `mac/build-rust.sh` builds the bridge as a static library for both Mac
architectures, joins them with `lipo`, generates the Swift bindings with uniffi and wraps the result as
`VersoBridge.xcframework`; it also writes the translations for Finder's action names and the version for Xcode.
XcodeGen writes the Xcode project from `mac/Verso/project.yml`, so the project is a text file that reviews well. The
team ID stays out of the repository, in the git-ignored `mac/Config/Local.xcconfig`. **CI's `macos` job builds all of
it on GitHub's macOS runner,** unsigned, and runs the core's and the bridge's tests and the app's offline checks, so a
Rust change is checked against the Swift side without a Mac at hand; while Actions is off (ROADMAP, M9), the Mac runs
the same steps (the mac-dev skill).

**The development build** is Verso Dev (`mac/Verso/dev-app.sh`; AGENTS.md, "Development environment"), with an
identity of its own from the Debug configuration (`dev.hviid.Verso.Dev`, with its App Group, Keychain group, URL
schemes, settings and Finder location) and blue icons, so it runs beside an installed release, testing never signs the
maintainer out, and a release never replaces it. It runs under a free Personal Team. The location's folder is in
`~/Library/CloudStorage`, named after the app and the drive (`VersoDev-Verso`); renaming the location moves the folder,
and keeps its items and downloads.

**Signing for release.** No Mac release of Verso has gone out yet ("Verso's releases"). What the drive's earlier Mac
releases settled holds for it: a disk image signed with the maintainer's paid Apple Developer Program team, the app
in it universal, signed with Developer ID, notarized and stapled, so a copy taken out of the disk image passes
Gatekeeper offline too.
- **Developer ID provisioning profiles,** named in the project (`APP_PROFILE`, `EXTENSION_PROFILE`, `WIDGET_PROFILE`;
  empty in a development build, which Xcode signs automatically): the Keychain group the app and the extension share
  is an entitlement only a profile grants (Apple's TN3125), and a manually signed build cannot use profiles Xcode
  manages. The team-prefixed App Group needs none.
- **Only the Account Holder can make the Developer ID certificate.** Xcode shows an individual membership's role as
  Admin and does not offer it, so the certificate is made in the developer portal, from a signing request made in
  Keychain Access.
- **Notarization with an App Store Connect API key** (Developer role), not an Apple ID with an app-specific password:
  it is scoped to the team, and can be revoked on its own.

**Switching the location on:** macOS keeps a new file provider off until someone switches it on, once per app and
user account; the locations the app adds after that come up on. The app adds the location switched off, and until it
is switched on, fileproviderd does not start the extension ("TCC access check failed" in its log), Settings' Verso
Drive pane says where to switch it on, and the menu bar icon shows it waiting.
- **Finder's Enable button is the main way.** Show in Finder shows the location, and while it is off Finder offers
  Enable at the top of the window: one click, where the user is going anyway, with no list to search. Proton Drive's
  setup ends the same way.
- **System Settings is the fallback** (General, Login Items & Extensions, File Providers), where the extension's
  switch shows the app's icon, which the extension carries (`Verso/Assets.xcassets` is among its sources).
- **No program can switch it on,** so the install cannot either. The SDK has no call for it (`userEnabled` is
  read-only), and `pluginkit -e use`, adding the location again and starting the app through Launch Services change
  nothing. The disk image runs no code, and the location exists only once signed in.
- **Not chosen:** System Settings as the main way, where a new app is one row of a long list; and testing mode
  (`NSFileProviderDomainTestingModeAlwaysEnabled`), which switches a location on with nobody asked but needs the
  `com.apple.developer.fileprovider.testing-mode` entitlement, made for testing. Device management can choose the
  apps whose file provider is on from the start (macOS 26.4 and later), on the Macs an organisation manages only.

**Flatpak impact:** none; this is the Mac's.

**Built so far,** beyond the parts above (Finder is checked by hand, as the mac-dev skill says):
- **The bridge** (`verso-bridge`): items by identifier, listings, whole originals and thumbnails, from the core's tree
  over the metadata store, on a tokio runtime of its own. uniffi's Swift does not pass a task's cancellation on to
  Rust, so each request takes a `Cancel`, which the extension calls from the request's progress and an enumerator's
  invalidation. A listing that takes more than 20 seconds is answered from the kept one, or as unreachable. Its tests
  run on Linux through a fake library, and against the lab server (`tests/lab.rs`).
- **The core's part:** `NodeKey::from_storage_key`, the reverse of the storage key, which accepts only the form it
  writes; the tree's `parent_of` and `entry_of`; and the sign-in steps (`sign_in`), which both platforms call.
  `immich-api` streams a whole original into a file.
- **The change journal** in the metadata store (off on Linux), the change poll's memory kept in the store, and the
  bridge's poll, changes and working set.
- **The extension** lists, fetches and answers thumbnails through the bridge, reports changes through the working
  set from the journal, and uploads what is added to Upload. Other changes from Finder are refused.

### The photo grid on the Mac

The Mac's photo grid is AppKit's collection view with a layout of its own (`mac/Verso/Verso/Views/Grid/`:
`PhotoGridCollection`, `PhotoGridLayout`), as the iPhone's is UIKit's (below), so the two grids work and are kept
alike (the maintainer's choice). `PhotoGridGeometry` places everything from the months' photo counts alone: the page's
header (an album's or a person's details, as tall as it draws itself), then each month's 50-point header and its rows
of square tiles two points apart, each month starting a row of its own, which is the date scroller's arithmetic in
the core ("The date scroller"). A row is laid out by `GridTileMetrics`, which both apps compile; the months' headers
are the Mac's own, the iPhone's months flowing on in shared rows (`TimelineLayout`). The content's height is known, so
a scroll to any photo lands on it in a library of any size.
- **On every page of photos** (`AssetGridView`): headers that stay at the top until the next month's pushes them
  away, the tiles' marks, selection and the Aspect Ratio grid, the clicks (with Shift and Command, and a rubber band
  from the space between photos) and keys (Return or a double click opens, Space is Quick Look, ⌫ and ⌘⌫, the arrows
  with and without Shift, Esc, and "." for a favorite), SwiftUI's own menus (through
  `NSHostingMenu`), and the photos running on under the toolbar, kept clear of it at rest by the scroll view's insets.
- **Exact to the point:** the date scroller lands on the point it points at, from the grid's own rows
  (`PhotoGridScroller`), and its mark is the grid's own offset; the arrow keys and Back from the viewer land exactly;
  the grid follows the viewer's photo behind it, so a photo closes into its tile from anywhere; the place holds as Info
  opens, the date scroller shows or the window resizes (the photo in the middle stays there, a grid at its top stays at
  its top).
- **A rubber band** from the space between photos or a header selects what it touches (Shift adding, Command turning
  photos in and out), scrolling the grid on at the view's top and foot; a pinch, ⌘+ and ⌘− zoom the grid as one
  picture ("Pinching between sizes").
- **The tiles are drawn in layers** (`PhotoGridTileView`) and show the picture already in memory for their photo from
  their first frame, as the iPhone's do (`GridTile.thumbnailAtHand`): the thumbnail asked for, the other size, or the
  ThumbHash, so no grey square flashes on a fast scroll or a zoom. Nothing fades in as it loads.
- **A click** selects a photo as it goes down, as Finder does, except on a photo already selected with nothing held,
  which is selected alone as the click comes up, so the selection can be dragged. A click between photos clears it.
- **Dragging originals out** is AppKit's (`OriginalFilePromise`, "Verso on the Mac"), the same on macOS 15 and 26.
- **Photos taken out** do not slide into their new places: the grid is drawn again where it is.
- **Not chosen:** SwiftUI's lazy grid (`LazyVGrid`), which reckons the rows it has not drawn at an estimate, so a deep
  jump lands off and scrolls again, and which cannot follow the viewer's photo while hidden (AppKit's layout loops and
  throws); and SwiftUI tiles in the cells, as AppKit has no hosting configuration for cells and the smallest size
  shows hundreds of tiles at once, which layers draw cheaply.
- **Flatpak impact:** none; this is the Mac's.

### The photo grid on the iPhone

The photo grid is UIKit's collection view, as Photos' grid is (`ios/Verso/Grid/TimelineCollection.swift`), with a
layout of its own that places every tile where `TimelineLayout`'s arithmetic puts it. Every row is one height, so the
content's height is known, and a scroll to any photo (the date scroller's, the viewer's photo kept in view, landing at
the newest) lands on it in a library of any size. `TimelineGrid` keeps what the grid knows and does, and moves it
through `GridScroller`.
- **The tiles stay SwiftUI** (`TimelineTile`, in the cells through `UIHostingConfiguration`), with their menus, their
  anchors for the viewer and their loading as they appear. A tile's cell is always the layout's size and never
  measures its view.
- **The page's header** (an album's or a person's details) is a cell of its own above the tiles, which tells the layout
  its height as it draws itself and again as its details load, as UIKit's own measuring misses it growing.
- **The bars and the page's title** are SwiftUI's safe area, which the grid hands the collection view as its insets,
  so the photos run on under them and rest clear of them: the view ignores the safe area to run under the bars, and
  UIKit then sees none.
- **The date scroller** (`DateScroller`) is a glass pill on the trailing edge of a timeline four screens long or more,
  placed by the core ("The date scroller") from the rows' top in view below the page's header; a drag puts the place
  it points at at the top of the view, to the point. Its track runs the grid's height between the bars, kept clear of
  them by the grid's own insets. Held, it shows the years down its track on a strip of the pill's regular glass, which
  keeps them legible over any photo. A finger moved left of where it came down scrubs finer, as iOS's video scrubbers
  do (half speed past 60 points, a quarter past 120), and the pill follows the finger's movement rather than its place,
  so it never jumps as the speed changes. Its glass is plain: interactive glass grows from its middle when touched,
  which pushes a long month's name past the screen's edge; held, the pill grows from its trailing end.
- **Not chosen:** SwiftUI's lazy stack (`LazyVStack` in a `ScrollView`), which reckons the rows it has not drawn at an
  estimate, so a scroll deep into a large library lands far from its photo, and holds only the rows on screen at one
  level, so a pinch cannot lay the next level's tiles anywhere it likes ("Pinching between sizes").

### The card pages on the iPhone

Albums, People, Memories, Places, a country's places and Shared Links are the same collection view with the pages'
SwiftUI cards in its cells (`ios/Verso/Cards/CardCollection.swift`, `CardGrid`), so a pinch zooms them as it zooms the
photo grid ("Pinching between sizes").
- **Every card on a page is one height at a size,** set by its picture's shape and its lines of text, measured off the
  screen from the tallest of each section's cards, so the layout knows where every card is at every size.
- **Each card is drawn at its cell's size, in a hosting controller of its own without a safe area**
  (`safeAreaRegions` empty): in a hosting configuration, as the photo tiles have, a cell under the bars has its SwiftUI
  laid out less the bars, so a card shrinks or sits off its place there, which neither `ignoresSafeArea` nor the cell's
  margins change.
- **Sections and their headers** (Albums' years, Mine and Shared with Me) are laid out by the grid, the headers in
  cells of their own. They do not fold, as nothing in Photos does, since a folded year hides the albums one looks for
  (the maintainer's choice). The Mac's and Immich's folded sections stay theirs.
- **The search** (Albums' and People's) is a cell above the cards, hidden at rest above the top, as Mail's: a pull
  brings it into view and settles it shown or hidden, a pull further reads the page again, and the content always has
  room to scroll it away. What a page says when it has nothing to show is a cell under the cards, so the search stays
  while nothing matches.

### The map's top on the iPhone and the iPad

Every page's top bar lies over its content with the soft scroll edge effect, a light blur with no edge, asked of each
page's scroll view (`scrollEdgeEffectStyle(.soft, for: .top)`, `PageTitle`). The map is no scroll view: where it is the
page's content, MapKit draws the bars' edge effects inside the map itself, in the automatic style (on iOS 27 the hard
one, a pale band ending in a line), and takes no style from SwiftUI (`scrollEdgeEffectStyle` and
`scrollEdgeEffectHidden` on the map change nothing). So Places holds its map in a scroll view that does not scroll
(`PlacesMap`): the bars take their soft edge effects from it, and MapKit draws none. The map runs on under the bars,
their insets handed to it as its safe area (`safeAreaPadding`), so it fits the photos and keeps its compass, scale and
legal notice clear of them.
- **Not chosen:** a transparent scroll view over the map, which blurs MapKit's band without taking it away; the bar's
  background hidden or shown (`toolbarBackgroundVisibility`), which leaves the band; and glass of our own behind the
  bar's controls, as Apple suggests for a map under a bar, a look no other page has.
- **Flatpak impact:** none; this is the iPhone's and the iPad's.

### The viewer on the iPhone

A photo opens as Photos opens one: the photo alone grows out of its tile while the grid darkens behind it and the
controls fade in where they stand, and it shrinks back into the tile of the photo shown last (ROADMAP.md, M10, item 4).
- **Shown in place, as on the Mac** (`ios/Verso/Viewer/ViewerHost.swift`; the Mac's `AssetGridView`): the viewer is
  drawn over the tabs, not presented, so opening and closing are at once. A picture of the photo flies between its tile
  and its place (`ViewerFlight`, the tile found through its UIKit anchor, `ViewerZoomAnchor`), the page hidden under it
  until it lands, while the backdrop and the controls fade. As Back is pressed the grid takes touches again, and a tile
  tapped while a photo still flies home opens its own at once, keeping Photos' timing. A host over each viewer shows
  the viewers its details' pages open.
- **The controls are the viewer's own:** glass buttons drawn where the system's bars have them (44-point circles 20
  from the edges at the top of the safe area, 48-point ones 28 from the edges reaching 6 points into the bottom one),
  so they fade where they stand and take touches from their first moment; the system's bars slide, and take no touch
  while they do.
- **A video's controls are the viewer's too,** as in Photos (`ViewerVideo.swift`): a glass bar above the bottom bar,
  its ends lined up with it, with Play and Pause, a strip of ten keyframes with a white playhead that a finger or a tap
  takes anywhere, Mute, and the system's route button, all in the bar's white (the route button's accent clashes with
  the video's dark). The time shows over the playhead only while it moves, as the grid's tiles give a video's length.
  The frames are read once from the stream the player plays (`AVAssetImageGenerator`; Immich has no strip) and kept
  for the last few videos. The page hands its player to the viewer's state while shown (`ViewerVideoPlayback`), so the
  bar follows whatever plays. One tap shows or hides it with the rest of the controls; Play fades them a moment after
  and the video's end brings them back, as in Photos.
  - **Not chosen:** AVKit's own controls, which put their scrubber under the bottom bar and toggle on their own tap
    beside the viewer's, so quick taps leave the two sets over each other; the viewer's controls hidden while a video
    plays (no Info, Share or Delete then); the system's full-screen player, which leaves the viewer and its paging; and
    the system's slider, which looks like a setting and takes no tap on its track.
- **A drag down closes it, and so does a pinch:** the photo follows the finger, shrinking to 0.65 of its size half a
  screen down, the grid showing through and the controls gone; let go far enough down or flicked, it flies into its
  tile, else it springs back. Not while the details are up, the photo is zoomed in, or a page the details opened
  shows. A pinch below the fitted size (down to half) shrinks it the same way, and one that ends below 0.8 of the
  fitted size closes the viewer, as the Mac's does.
- **A video zooms and closes as a photo does,** as in Photos. Both pages are one zooming page (`ViewerZoomPage`): the
  picture fitted in a zooming scroll view. A video's picture is its poster, with the video drawn over it by a player
  layer inside that picture once it plays (`ViewerVideoPage`), so it zooms, pans and shrinks with it, playing or
  paused; a drag down or a pinch towards the tile pauses it, let go short it plays on, and closed, its poster flies
  into the tile. The player is the page's own, so the page puts the video in Now Playing itself, with the remote
  commands, through a session of its own (`MPNowPlayingSession`, in `ViewerVideoPlayback`), as AVKit's player view does
  for its player.
- **Now Playing names the video as the viewer does:** the title capsule's title and the poster as artwork, as the
  player item's own details (`AVPlayerItem.nowPlayingInfo`), which the session publishes; a playing item with neither
  shows the app's name beside a blank square. The item's `externalMetadata`, which AVKit's player view hands on, is not
  what a session of one's own reads (WWDC 2022, "Explore media metadata publishing and playback interactions").
  - **Not chosen:** AVKit's player view (`AVPlayerViewController`) over the page or as the zooming picture, a view
    controller's view laid out to its own bounds, which a zooming scroll view would scale from outside; and a pinch of
    the video page's own that only closes it, which leaves a video unzoomable where Photos zooms it.
- **Not chosen: UIKit's zoom transition** (`preferredTransition = .zoom`): its presented screen zooms with the controls
  on it, so they can come only once it has landed, and it reports itself done about 1.0 s after it starts though the
  photo is home at 0.45 s, so a tile tapped before then cannot open and Back answers late.
- **The details scroll with the photo,** as Photos' do: one scroll, the photo going up and off the top with the cards
  as far as they reach, and back to rest first on the way down. Verso's stage is one scroll too, as the Mac's viewer is
  (`AssetViewer`): the pager at the screen's height with the details below it (`ViewerStage`). Scrolled up, the photo
  eases into the top of the screen, fitted there, until the details rest under it, and past that goes up with them. The
  scroll stops at the photo alone or the details at rest (`ViewerDetailsStops`: 40 points up or a flick brings them, 60
  down or a flick sends them away), a spring of 0.22 s taking it there, landing in about 0.3 s as Photos' does in
  0.25 s (the scroll's own momentum takes 1.5 s). The photo's place follows the scroll as it is drawn
  (`visualEffect`), so it is never a frame behind. At the top a drag down is the page's, which closes the viewer, and
  the scroll's bounce there moves nothing; a zoomed photo pans instead of scrolling. The details stay the photo
  shown's, as one inspector reads them, and the next photo's start at rest.
  - **Not chosen:** the details laid over the pager, scrolling on their own, with the photo moved to follow them: a
    frame behind, and past the cards' end its moving changes the layout under the finger, back and forth.
- **Live Photos,** as Photos plays them, matched to it frame by frame (`ios/tools/live/`). Opening one, nothing moves.
  Swiped toward, at 65% across, it plays the 0.6 s before the key photo without sound, the last 0.17 s at 0.7 of its
  speed, ending on the key photo as the page lands, then a 0.25 s fade into the photo (the motion effect Apple's Human
  Interface Guidelines name for Photos' full-screen browser). Held, it plays whole, with its sound, and is back at the
  still in 0.3 s. The next glimpse is cued (sought back to its start) only once the fade is over, or the fade shows its
  first moment instead of the key photo (`ViewerPhotoPage`).
  - **The whole frame,** as Photos plays it: an iPhone's movie is coded at 1920 by 1440, the photo's whole field, and
    marks a stabilised crop of it (its clean aperture, 0.908 of it), which AVFoundation shows by default: stretched
    over the photo it is 10% too large, and drawn at its share a band of the photo shows around it. So Verso plays the
    whole coded frame (`videoApertureMode = .encodedPixels`), lined up with the photo at a scale of 1.00.
  - **The key photo** is where the movie marks it (`com.apple.quicktime.still-image-time`), read from the original
    movie, which a transcoded copy may lose; a mark at the very start is no mark, as a trimmed movie keeps it there.
    Without one (such a movie, or a Google motion photo's), it is the moment whose frame looks most like the photo,
    compared small every 1/30 s; a mark comes first, as the look can miss by 0.3 s. Motions are downloaded once into
    the caches folder, the 40 last used kept, emptied as the account signs out (`LiveMotions`, in the Mac's
    `Support/`, which both apps compile), and the neighbours' are fetched ahead.
  - **The LIVE badge is one switch for all Live Photos** (the maintainer's choice), kept on the device: off, they stay
    still while swiping and still play whole while pressed. Photos' badge is a menu whose Live Off is an edit saved
    into the one photo; Immich has no such edit, so a per-photo Off would be a private list on one device. The badge
    is the viewer's form of the system's Auto-Play Video Previews, which stops the glimpse and leaves the press. On, it
    is yellow, as the Camera's Live, on glass tinted yellow with dark text, which reads on the viewer's light
    background; switching it shows LIVE or LIVE OFF a moment, as the Camera does, so it is plain that it is not the one
    photo's. Where Reduce Motion or Auto-Play Video Previews says no, nothing moves while swiping and the badge reads
    OFF and does not switch.
- **Not chosen either:** SwiftUI's `navigationTransition(.zoom)`, which has no alignment rect, so the whole viewer
  zooms from the tile with a double image in the crossfade. The phone's own tiles (backing up) open their viewer
  (`PhoneViewer`) with it.

### Pinching between sizes

The photo grid's zoom levels (every count a row from 3 to the densest, one level each; `GridZoom`) and the card pages'
card sizes change with a pinch. A phone in portrait shows the counts themselves, as Photos shows 3 or 5 a row on any
iPhone, up to 15 on a 393-point iPhone and 17 on a Pro Max, and so does an iPad in portrait, its tiles larger, as
Photos shows 5 a row on any iPad; a wider grid keeps the tiles' size and shows more of them in a row. The default is
5, Photos'. Photos' grid stays one grid of squares as it zooms: it scales with the fingers
about the photo under them, and each square fades from its photo at the level shown to its photo at the next.
- **The photo grid pinches so** (`ios/Verso/Grid/GridPinch.swift`, `TimelineCollection.swift`): the two levels'
  squares are made the same size and laid on each other at the photo under the fingers, making one grid that scales
  with them and slides that photo from its place at one level to its place at the next. The next level's tiles are the
  grid's own, under a picture of the level shown (a snapshot of each tile) that scales with them and fades, so where
  the picture has shrunk from the edges the next level's photos already fill the squares. The header (an album's
  details) goes to its place at its own size. The view does not scroll until the grid arrives, then takes the scroll
  position that keeps the photo under the fingers.
- **Let go,** the grid finishes the way or goes back, from where it is and as fast as the fingers were going, in about
  half a second, and a pinch that catches it takes it on. One pinch goes through as many levels as the fingers go.
- **The tiles are not drawn again on the way:** each is scaled, and draws itself anew once the grid has its level.
  Every tile shows the picture already in memory for its photo from its first frame (`GridTile`), so the many that
  come into view on a zoom outward are not empty squares.
- **Not chosen:** each photo travelling from its place at one level to its place at the next, which tears the grid into
  bands mid-pinch and opens holes; UIKit's interactive layout transition (`startInteractiveTransition(to:)`), which
  moves them so too and ends on UIKit's timing; and a picture of the whole view scaled, which shrinks into the middle
  with nothing around it.
- **The card pages pinch the same way** (`CardGrid`), through the card sizes, the cells showing the next size's cards
  on the way. View Options' Zoom Out and Zoom In make the same motion about the middle of the view.
- **The Mac's photo grid pinches the same way** (`mac/Verso/Verso/Views/Grid/PhotoGridPinch.swift`; "The photo grid
  on the Mac"), from the same arithmetic (`GridZoomTransition.swift`, which both apps compile). Its levels are its
  sizes (`GridMetrics.steps`) that each show another count a row; the size settled on is kept.
  - **Drawn with AppKit's own magnification:** the next size is the grid's own collection view, its scroll view
    magnified (`NSScrollView.magnification`, its clip view moving past the content's edges) to lie where it shows, and
    the picture of the size shown is a second collection view of the tiles in view, magnified and fading. Both are real
    views, so the months' headers keep their glass and the tiles their marks.
  - **A trackpad pinch** follows the fingers as on the iPhone; ⌘+, ⌘− and the toolbar's − and + make the same motion
    about the middle of the view. A size that shows as many photos a row is taken at once. The grid neither scrolls nor
    answers the keys while the motion runs.
  - **Not chosen:** the iPhone's way of scaling each tile, as AppKit's layout attributes have no transform; resizing
    each tile every frame, hundreds a frame at the smallest size; and a bitmap of the grid as the picture, which loses
    the headers' glass.

### Sharing from the iPhone

Share opens the system's share sheet at once, as Photos' does, with Verso's own Create Link… and Add to Link… beside
the apps (SPEC.md, "Sharing from the iPhone"; `ios/Verso/Grid/ShareSheet.swift`, `ShareLinkActivities.swift`).
- **The originals are promises.** Each photo is an item source (`UIActivityItemSource`) whose item is an
  `NSItemProvider` that downloads the original only when the chosen app loads it, answered with the downloaded file's
  own address in the sheet's folder, kept until the sheet closes. The link actions get an empty item, so nothing
  downloads for a link, and while the sheet draws its header a stand-in of the same type takes each photo's place.
- **Not chosen:** `UIActivityViewController(activityItemsConfiguration:)`, which loads every original before handing
  over to a link action; a file representation (`registerFileRepresentation`), which iOS hands to Save to Files as a
  copy of its own and deletes before Save to Files reads it; and downloading every original before the sheet opens,
  which makes a link wait. The cost: the sheet shows no progress while an original downloads.

### Verso on the iPad

The iPad is the iPhone's app (the maintainer's choice: as little to maintain twice as possible), its views laid out by
the size class where Photos on the iPad lays its own out otherwise, and following the Mac where the Mac solved the same
thing (SPEC.md, "On the iPad"; ROADMAP.md, M10). A window narrower than a regular width (Split View, a small window) is
the iPhone's layout.
- **The tabs at the top, never a sidebar** (`.tabViewStyle(.tabBarOnly)`; the maintainer's choice, as a sidebar made
  the iPad look like another app), with room for one more page.
- **A page's title stands in the navigation bar's row,** found from UIKit's own bar (`NavigationBarRow`, PageTitle):
  iPadOS puts the bar's buttons beside the tab bar in its row, as Photos has them, or in a row of its own under it, and
  the title and its line go where the buttons are, so the line never stands a row away from its title. Where the tab
  bar shares that row and leaves the title too little room (an iPad mini in portrait), the title stands under the
  row, as on a pushed page.
- **A resized window's controls** (Stage Manager, windowed apps) sit at its top leading corner: the system's bars keep
  clear of them on their own, and what Verso draws in the bars' place (a page's title, the viewer's top bar) keeps
  clear of them by UIKit's corner-adapted safe area (`WindowControls`).
- **Five photos a row in portrait,** as Photos shows on every iPad, its tiles larger than a phone's; the counts are
  taken from the grid's shorter side, so landscape and a window wider than tall keep the tiles' size and show more
  (`GridZoom`).
- **Years, Months and All are always at the foot,** in a capsule of the page's own, as Photos has them on an iPad
  (the shrinking tab bar's accessory is a phone's). Backing up's card stands under it, a sheet's width rather than the
  screen's.
- **The viewer's buttons are in its top bar,** as Photos' on an iPad: Back, then Share and Favorite together; Edit,
  Info, Delete and More together at the other end; the filmstrip alone at the foot, and a video's bar a sheet's width
  in its middle. The details are a panel at the trailing side under the top bar, as Photos' Info, the photo staying
  where it is; the cards are the iPhone's (`ViewerDetails`).
  - **Not chosen:** the iPhone's bottom bar, which on a 13-inch iPad puts Share and Delete 1000 points apart; and the
    details scrolling up under the photo, whose cards and lines then run the screen's whole width.
- **The keyboard's commands** are SwiftUI's in the menu bar (`VersoCommands`: Settings…, New Album…, the imports,
  Find, Years, Months and All), each window publishing what they act on (`focusedSceneValue`). The keys of a photo
  open (the arrows, Space, ".", ⌘I, ⌘⌫, Esc) are key commands of a view of UIKit's in the viewer that takes the
  keyboard as the photo opens (`ViewerKeys`), and those of a selection the grid's collection view's while it lasts
  (`GridKeys`); ⌘A is Select All's own button's.
  - **Why not all in the menu bar:** its commands come after the scroll views' own use of the arrows and Space, which
    scroll the pager instead; a key command of the responder's own can ask to come first
    (`wantsPriorityOverSystemBehavior`). And iPadOS's own Edit menu holds ⌘A (Select All, for text): a key the menu
    bar holds twice ends the app as its menu is built ("Replacement elements contain duplicates"), so ⌘A stays with
    text fields and Select All's button; the text styles (Bold, Italic, Underline) go, as Verso has no styled text,
    leaving ⌘I to Show Info.
- **Under the pointer,** cards lift and Collections' rows light up (`hoverEffect`); the system's controls answer it on
  their own.
- **Drag and drop:** a tile drags the Mac's `OriginalTransfer` (both apps compile it): the original, named and typed as
  the server has it, downloaded once the receiving app asks, and the mark of the app's own drags. The Library and an
  album's page take drops of photos and videos from other apps as imports (`importDrops`, `ImportCoordinator`), each
  copied out of the system's loan before the queue sends it, and refuse the app's own drags by their mark.
  - **Not chosen yet:** a selection dragged as one, which needs SwiftUI's drag container across the collection view's
    cells, each a hosting root of its own.
- **Several windows** (`UIApplicationSupportsMultipleScenes`): each window has its own `LibrarySession` and chrome over
  the one account, as each of the Mac's windows has. What one place asks to show (the Backup page, from a card, a
  notification or a Live Activity) opens in the window in front (`BackupCenter.frontWindow`), not in every window.
- **Flatpak impact:** none; this is the iPad's.

### Verso Drive on the iPhone and the iPad

The same extension in the Files app: iOS has the replicated File Provider API the Mac's extension is built on, so
the iOS project's `VersoDrive` target compiles `mac/FileProvider/` (without `Actions.swift`), `mac/Shared/` and the
bridge's bindings, and the app compiles the Mac's `VersoDrive.swift`, which brings the location up and takes it down.
SPEC.md, "In the Files app", has what the person sees. Flatpak impact: none, as it is iOS's alone.
- **The switch is the device's** (the account's sheet, On This iPhone), as the location is in this device's Files app
  and its settings in this device's App Group, not on the server.
- **Identity:** the extension is `<identity>.Drive`; the App Group is `group.` and the identity (an iOS App Group is a
  name registered with the team, where the Mac's is the team's prefix); the Keychain group is the team-prefixed
  identity.
- **A new location waits** until the person turns it on in the Files app, and iOS keeps it on when it is removed and
  added again.
- **Content policy:** `downloadLazilyAndEvictOnRemoteUpdate`, as iOS has no plain lazy policy.
- **Show in Files** opens the Files app at the location through `shareddocuments:` and its user-visible path.
- **Removing the location removes everything:** iOS has no `preserveDirtyUserData`, so switching off and signing out
  count what waits in Upload and ask first.
- **The default location:** iOS needs `NSExtensionFileProviderSupportsEnumeration` to add Verso's location (without
  it, adding fails with -2001), and with it lists the extension's own default location whenever Verso has none, so
  switched off, the drive's location is empty rather than gone (ROADMAP, M10, open).
- **Bringing up and taking down run one at a time** (`VersoDrive.inTurn`), on the Mac too, so a sign-in's bring-up
  cannot overtake a switch-off at launch and add the location back after it was removed.
- **Not on iOS:** Finder's actions (an extension without a view can neither open a web address nor show that it
  copied one) and Show in Another App.

### Verso in Messages

An iMessage app extension (`ios/Messages/`, the target `VersoMessages`), embedded in the app: a picker of the Immich
library's photos that puts one into Messages' field (`MSConversation.insertAttachment`). SPEC.md, "Verso in Messages",
has what the person sees. Flatpak impact: none, as it is iOS's alone.
- **Identity:** `<identity>.Messages`, with the drive extension's App Group and Keychain group.
- **Signing in:** none of its own. It reads the app's own account (`AccountVault`, whose Keychain service is the
  Info.plist key `VersoAppIdentity` where an extension sets it, else the bundle identifier) from the Keychain group the
  app shares with its extensions, each time Messages opens it; a 401 shows Open Verso (`NSExtensionContext.open`). Not
  the drive's account (`mac/Shared/Account.swift`), which the app keeps only while the drive is on.
- **Within an extension's memory:** the API layer's Swift (`mac/Verso/Verso/API`) over its own URLSession, without the
  Rust bridge; Immich's small thumbnails decoded with ImageIO at the tile's size only while a tile shows, a ThumbHash
  until then, in a 24 MB cache the system empties under pressure (2 MB of HTTP cache in memory, 100 MB on disk); the
  copies to send downloaded straight to files, each in a temporary folder of its own, swept after a day.
- **One photo at a time:** Messages gives an app one item in the message field (a second `insertAttachment` takes the
  place of the first; Photos stacks several through an integration of its own), and after a `sendAttachment` it takes
  the app out of the conversation, so a loop of sends stops after the first. So a tap puts one photo in, and several
  go from the app's own Share, where iOS puts them all in the field.
- **The photo library:** the extension has the app's own permission, so it needs no prompt of its own; where the app
  has no access, it sends the person to Verso.

### Backing the iPhone up

Two promises lead it: no photo is lost, and none is uploaded twice, on libraries of 100,000 photos and more. SPEC.md,
"Backing the iPhone up", has what the person sees; ROADMAP, M10, step 8, keeps what is open. Flatpak impact: none, as
it is iOS's alone.
- **Where it lives:** `ios/Verso/Backup/`, a Swift engine with no UIKit or SwiftUI, which moves to VersoKit with M10's
  step 2. PhotoKit, background `URLSession` and BackgroundTasks are Swift's alone, so none of it is in Rust. The server
  and the transport sit behind protocols (`BackupServer`, `BackupSending`), so the system's own upload extension can
  take over (ROADMAP, M10).
- **The store:** SQLite (the system's, in WAL mode) in the App Group's container, `Backup/backup.sqlite`: `photo`, the
  phone's facts; `part`, each stored resource's fingerprint, kept across accounts, so changing servers costs a check,
  not new fingerprints; `remote`, per account and fingerprint, whether Immich has it, in its trash or not, and whether
  Verso sent it or saw it in the trash; `backup`, each photo's state and the person's decision per account; `journal`,
  each step's intent before it and its result after; `meta`, the change token and the runs' marks. About 30 MB at
  100,000 photos, read in pages; every write is a short transaction, closed before Verso is suspended. Not chosen:
  redb (one process, where an extension may need the store), Core Data and SwiftData (slow batch writes at this size).
- **Recovery:** the first pass after a launch works every journal step without a result out again from facts: an
  upload the background session still carries is left to it; any other is checked with the server by its fingerprint,
  and sent again if Immich lacks it, as a resend is only a duplicate; stacking and metadata steps are idempotent and
  done again; a sweep then removes the bodies and downloads nothing uses. A relaunch for the background session's
  events races recovery: a finished task's answer may not be delivered yet, so recovery closes the step as a
  duplicate, and Immich's created answer, coming after, corrects it, or the photo would never be finished (its stack,
  its date and place) as one Verso made.
- **Files on disk:** upload bodies and downloads are kept by paths relative to `Application Support/Backup`, as iOS
  does not promise to keep an app's container in one place across an update or a restore; a download gone by the time
  its upload is written is read from Photos again. The folder is excluded from the device's own backup, as it holds
  copies of what the library holds.
- **Reading the library:** the first run saves the change token, then lists in pages of 500, newest first, resuming
  from the last page's date; later runs read the change history (`fetchPersistentChanges(since:)`), each change saved
  with its token in one transaction; an expired token, lost details or a week since the last reconcile mean a full
  one. Identifiers that vanish are mapped through their stored iCloud identifiers (`PHCloudIdentifier`), as Quick
  Start and iOS updates can change local ones. The user library alone (`.typeUserLibrary`), with every burst frame and
  the hidden photos (a library listed before hidden photos were backed up is reconciled once to list them).
- **Hidden photos** go into Immich's Locked Folder (the upload's `visibility: locked`, which an API key may send).
  Immich's duplicate check sees a locked asset, so nothing goes twice; but a locked asset is out of reach without a
  session unlocked by the account's PIN, so a hidden photo is finished as it arrives (unstacked, with the file's date
  and place), and Free Up Space checks it only once the review has the PIN. The store takes them in by one switch
  (`BackupStore.hiddenIncluded`), and the Library's photos on their way never do. iOS shows hidden photos to apps only
  while Photos' Use Face ID is off.
- **Parts and fingerprints:** every stored resource with its own content is a part (the original, a Live Photo's video,
  RAW+JPEG's second file, an edit's rendering and its video), and a photo is backed up only when all its parts are on
  the server; never a fresh render or export, whose bytes differ every time (immich-app/immich#29543). SHA-1 is taken
  by the same sink that writes the upload's body, so the two agree; an edit's rendering is read again only when its
  adjustment data changes. Up to four parts are read at a time, as a read is mostly waiting on iCloud. An original only
  in iCloud is downloaded once, then uploaded from that file; each download holds 200 MB of the disk budget so several
  never overrun it, and a video's, of unknown size, goes alone, so with Optimize Storage the first run's check stops at
  the budget until Start's uploads free it (hashing without keeping would download every photo new to Immich twice). A
  local original is read twice, for its fingerprint and for its body, the price of checking before uploading; the
  network is the slower part. A failed read is tried again with backoff, never stored as an empty value that blocks
  the photo for good (immich-app/immich#25248), and needs a look only after five tries over three days.
- **Never twice:** nothing is uploaded before its fingerprint has been checked with Immich (`bulk-upload-check`, 500 at
  a time); every upload carries `x-immich-checksum`, so Immich answers "duplicate" before the body is sent; and Immich
  keeps one asset per owner and checksum, so a retry after a lost answer is a duplicate, never a second photo.
- **Immich's own app, compared** (its source at `08fe047`, 3.4.0-rc.0, learned from and not copied): it asks nothing
  before an upload, downloads an iCloud original twice (to hash it, then to upload it), does not refill its queue when
  the background session wakes it, takes no API keys, and keeps no memory of deletions, so once Immich's trash is
  emptied a photo goes again, silently. Verso takes from it the review of what goes, its iCloud identifiers (below) and
  six uploads at a time, and does the rest otherwise.
- **Arrived as read:** Immich keeps each asset under the checksum of the bytes it receives, so before a photo is
  finished, the parts Verso made are asked of it by Verso's own fingerprints (one bulk check for up to ten photos). A
  part it does not hold under its fingerprint arrived otherwise than it was read (a proxy that changes uploads): the
  photo needs a look, never sent again on its own, which would make another asset each time.
- **Known by Immich's own app's iCloud identifiers:** that app keeps with each asset its `mobile-app` metadata (the
  photo's iCloud identifier, when it was taken and last edited, where) and matches a phone's photo to an asset when all
  agree. Verso writes the same with each still or video of a photo never edited, so that app knows Verso's uploads, and
  reads it to take the fingerprint of an original only in iCloud from Immich rather than download it (only the assets
  taken at the photo's second are asked; anything that fails leaves it to the download). Only for photos never edited,
  as that app reads an edit's time through a key of PhotoKit's that is not public. A fingerprint so borrowed is marked
  as Immich's: anything that must know the phone's bytes (freeing space) reads them first.
- **The first run, carefully:** a library may be in Immich already, so nothing is uploaded until the first check's
  tally and the person's Start. Photos Immich has in another form (the same time taken, to the second, and file name,
  other bytes) are for the person to send or skip. Immich's names and times are read cheaply from the account's own
  timeline months (`/timeline/buckets` and `/timeline/bucket` with `userId`, unstacked, the archive included): ids and
  UTC times once per launch for the months within 14 hours of each photo, and an asset's name (`GET /assets/{id}`) only
  on a hit to the second; the same wall-clock second read as UTC matches too, for files without a time zone. Immich's
  sync stream would be exact but refuses API keys.
- **Sending:** one background session (`<bundle>.backup.uploads`), each task's description its journal step and its
  delegate recording the answer without the engine, so uploads go on while Verso is suspended. The bodies are multipart
  files within a disk budget (SPEC.md has its numbers), sent in batches of up to 100, topped up when fewer than 20 are
  on their way, six at a time, as Immich's own app sends them. A file larger than the budget goes alone once what is
  held has gone, or it could never go. An iCloud original downloaded first is the body's source, removed once the body
  is written, so it counts once. A Live Photo's video goes first, hidden, then the still with `livePhotoVideoId`.
  Stacks: an edit's newest rendering on top, then the original, the second file and earlier renderings; RAW+JPEG's
  second file under the first; a burst under the picked frame once every frame is in Immich (`POST /stacks` takes in
  the stacks of the ids it is given). The date and place Photos has are set (`PUT /assets`) only on assets Verso made,
  once Immich has read the file; an asset Immich had already, its date perhaps put right there, is left as it is.
- **One page, and every way to it:** everything about backing up happens on the Backup page, never a trip into settings.
  Its card in the Library sits above the tab bar, by the newest photos where the Library opens, as the title has room
  for one line only. Start is there all along, so the person may start mid-check, as photos found in Immich are never
  sent. To Upload lists what will go, with Don't Send: after a reinstall or on a new phone, a photo deleted in Immich
  long ago cannot be told from a new one, so the person's look is the one safeguard, as in Immich's own app. The page's
  top is one bar for the whole library, split by what each photo waits for, as iPhone Storage splits the device: nothing
  on the phone is unaccounted for, which is what earns trust.
- **Free Up Space:** photos older than the person keeps on the phone, safe in Immich, leave the phone only after the
  person reviews them and iOS asks; nothing deletes on its own. Keep on This iPhone is Forever until the person
  chooses, and the first choice says what deleting means for iCloud Photos and a Shared Library, which no API tells
  apart (as Apple confirmed in June 2026): deleting deletes from every device, and in a Shared Library for everyone.
  It sits on the Backup page, as freeing space is what backing up earns, and its periods follow Messages' Keep
  Messages, Apple's own age-based clearing.
  - **The call to action** is a card in the Library, once a gigabyte or more is ready, as Google Photos has one; the
    Library's line names the size too, but a word in a line reads as a status, not something to press. Not chosen: a
    button beside View Options and Select, clutter for something done about monthly that would move Select under the
    thumb next to a flow that deletes, and as an icon cannot say the size. While Keep on This iPhone is Forever, a
    phone short of space (under 5 GB, or a tenth of it, from `volumeAvailableCapacityForImportantUsage`) gets the card
    once in three months, never a notification, leading to the setting: Verso never chooses a period for the person.
  - **Age** runs from the later of when a photo was taken and when it came to the phone (`PHAsset.addedDate`), so one
    received today is not old for its date.
  - **Always Keep:** the favourites and the albums as Photos has them (a heart given in Photos, not Immich's), as what
    stays on the phone is the phone's matter. Immich's people (the API says nothing of faces being done) and photos or
    videos alone are left out as more to understand than they keep. Always Keep says what it keeps wherever the choice
    is made, as a setting one page deep goes unnoticed.
  - **The safety checks,** when the review opens and again right before deleting (which does not read again what the
    review read), for every part: the duplicate check; the asset itself (the account's own, not in the trash, not an
    external library's, the same checksum and size); its original's first byte read, which proves the file is on the
    server's disk; on the phone, unchanged since it was read; a fingerprint borrowed from Immich read for real. A burst
    goes only with every frame in Immich. A photo that fails stays, listed with why.
  - **Deleting:** one request for the whole selection, so one question from iOS; ProRAW apart, given 90 seconds, as an
    Apple bug can hang the delete of some 48 MP ProRAW photos. For the 30 days the photos are in Recently Deleted,
    Verso checks Immich daily for each and says once if any leaves Immich while it can still be brought back. A photo
    stored only in iCloud makes the review ask a second time, a sign of iCloud Photos.
- **Live Activities:** a run the person starts shows the system's own progress (a continued processing task); backing up
  on its own has Verso's (`ios/Widgets`), for the first run's check and runs of 5 or more items, as fewer go in seconds
  and their tiles' rings show them. iOS lets an app start one only while it is open or from a push (Verso has no push
  server, and Immich sends none), so it starts while Verso is in front and is updated from the background. iOS ends a
  continued task whose progress stops as failed, so the system's ends, done, once nothing more can be done now. Verso's
  stays away while the system's shows and for 10 seconds after a run's request, so the two never appear together.
- **Background:** Back Up Now and the first run are continued processing tasks the person starts (`.backup.now.<UUID>`);
  backing up on its own uses `.backup.overnight` (processing, with network, on external power with Only While Charging,
  at least an hour after the last run) and `.backup.refresh` (about 25 seconds, every 15 minutes or more). A wake-up for
  the background session's answers tops the uploads up first and holds the system's completion until then, for 20
  seconds at most (of about 30): called at once, the completion lets iOS suspend Verso before it hands the session more,
  and no SQLite lock may be held in the shared container while suspended. Where a background task or the person's run is
  under way, or Verso is in front, the pass is theirs and the completion goes at once. Stop, or the system ending a run
  the person started, calls back the background session's uploads too, as iOS's expiration handler does not say which of
  the two it was, and Stop must stop.
- **Not in Immich, without pestering:** weekly, a bulk check of every fingerprint Verso counts as in Immich, as an API
  key hears of no deletions. A photo gone after Verso saw it in the trash, or one the person let go, is Deleted in
  Immich: listed quietly, never sent again on its own. Any other is Missing from Immich, announced once. At least 20
  gone and at least half of what was backed up means a server problem, not deletions: Verso applies nothing until the
  person answers. While in Immich's trash an upload is a duplicate of the trashed asset (and does not restore it); once
  the trash is emptied the same bytes upload as a new asset, and Immich's own record of deletions (`asset_audit`) holds
  asset ids without checksums, for 31 days. So Verso's memory of what it saw in the trash keeps such a photo out, and a
  deletion before Verso first looked, or forgotten with the store, cannot be told from a new photo.
- **Errors, in three tiers,** so the person sees only what they can and must act on (SPEC.md has the words): what
  passes, Verso waits out by itself and says calmly, with when it tries again, never with an exclamation mark or a
  notification (another error than a failure to reach Immich only once it has lasted an hour); what stops the whole
  backup until the person acts (sign in again, a key without upload permission, a full server, most of the library
  gone) is one line, one action, one notification; what one photo needs is Needs a Look, with Retry (always safe, as a
  resend is only a duplicate) and Don't Send, whose word holds, so every exclamation mark can be made to go. A pass
  wakes by itself when the soonest retry is due, or a run would look done while it is not. Too little room is the
  device's state, not the photo's. Nothing the person presses deletes anything, on the phone or in Immich.
- **Failures:** a 403 stops backing up, said once, until Back Up Now or a new sign-in: the duplicate check needs the
  same `asset.upload`, so a 403 on an upload means it was taken away or a proxy refuses, and refusing photo after photo
  would put the whole library under Needs a Look. The switch stays on through a sign-out and waits for the account it
  was switched on for, so backing up never stops unnoticed (a script's sign-out in Verso Dev switches it off); signing
  out calls back the uploads on their way, which carry the account's credential. Another account's sign-in waits for
  the pass under way to end, so no pass asks one account's server about another's photos. A 413 is that file's own
  refusal (too large for the server or a proxy in front of it: nginx's default limit, Cloudflare's 100 MB) and needs a
  look while the others go on; a 5xx or no answer is tried again after half a minute, 2 minutes, then 5 doubling up to
  a day, as one failure is most often a moment's (a proxy's 502 while Immich restarts). Five in a row with no upload
  landing between are an outage (Immich down, or a home server with the phone away): backing up pauses for 15 minutes,
  doubling up to 4 hours, rather than reading body after body for each to fail; after the pause only two go at a time
  until one lands.
- **New photos first:** a photo is new when it came to the phone after backing up was first switched on for the account
  (`onSince.<account>` in the store). Each round of a pass begins with the new photos, and a library change or coming
  to the foreground cuts the backlog's work short. While Verso is open they go through a session of the app's own
  rather than behind the background queue; its tasks are kept in the journal as negative numbers, so recovery never
  takes them for the background session's, and going to the background cancels them to go again through it. A new
  photo is not looked for in another form.
- **The Library's photos on their way** are an iOS layer over the shared grid model, not in it: `AssetGridModel` and
  the Mac's index, selection, viewer and actions all take Immich's ids, so a layer leaves the Mac as it is and keeps
  phone photos out of every other grid. `BackupCenter.libraryTiles` feeds `TimelinePhoneMerge`, which places each
  photo in its month among Immich's by when it was taken, so Immich's photo lands in the same place. An arrival does
  not jump: each upload that lands has the Library read again, at most every two seconds; an arrived tile stays until
  the model has Immich's asset; the model reads a changed month before it publishes it, so a month does not go blank
  (on the Mac too); and Immich's tile shows the phone's picture until Immich's thumbnail exists. A photo on its way
  opens in a viewer of its own (`PhoneViewer`), as the grid's viewer is built on Immich's assets.
- **Never Immich's public demo:** backing up is not offered while signed in to `demo.immich.app`, which anyone can read
  and App Review signs in to.

### The app icon's designs on the Mac, the iPhone and the iPad

The Apple apps offer the app icon's seven designs, each on Day or Night paper with its lens in colour or in graphite, as
Linux does ("The app icon's designs on Linux"; DESIGN.md, "The picture's designs"), each in the build's own drawings: a
release's, or Verso Dev's with the blue DEV corner, so the two stay told apart whatever is chosen.
`mac/Verso/make-icons.py --design <design> [--graphite] [--dev]` draws a design and lens in its Day and Night looks, and
`--all` every one. Mist stays the app icon, the Icon Composer document (`AppIcon.icon`, `AppIconDev.icon`), whose dark
appearance is Mist's Night look: the picture, the lens's barrel, the word, the turned corner and what shows beneath it
each have a dark layer of Night's, and the paper a dark gradient of Night's, so the Mac's and the iPhone's dark icon is
the print in the dark rather than a light picture on dark paper. SPEC.md, "The app icon on the Mac, the iPhone and the
iPad", has what the person sees.
- **On the Mac a look is chosen for each mode; on the iPhone a design and its lens.** An iOS app icon set holds one
  light and one dark picture, which iOS switches itself, by the Home Screen's icon style (its Customize menu: with
  Default every icon is light, with Dark every icon is dark, always or in dark mode), and an alternate icon is one set:
  any look for each mode would take a set for each pair, 28 by 28. So the iPhone offers the 14 designs and lenses, each
  its Day look as the light picture and its Night look as the dark one. The Mac sets the Dock's picture itself, so it
  takes any of the 28 for either mode, and follows dark mode, as macOS's own icons do with its default icon style.
- **The build names them.** Each project lists the others as alternate icons after the build's own app icon,
  `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES: $(APP_ICON)-MistNight ...`: the Mac its 27 other looks
  (AppIcon-SandNightGraphite), the iPhone its 13 other designs and lenses, by their Day looks (AppIcon-SandGraphite);
  AppIconDev-... in Verso Dev. The asset catalog compiler leaves out every app icon set it is not named, so a release
  carries none of Verso Dev's drawings, nor Verso Dev a release's. The code finds the names the same way, after the app
  icon the Info.plist names (`CFBundleIconName`, which the compiler writes; `AppIconLook`), so it needs no `#if DEBUG`.
  `check.py`'s `app-icon-choice` fails when a name has no set or a project does not list the others.
- **The iPhone and the iPad: iOS's alternate icons** (`UIApplication.setAlternateIconName`, nil for Mist in colour),
  the one way an app changes its own icon. The Home Screen, Spotlight and Settings show it, iOS keeps it across
  launches and updates and says so in a notice of its own, and the icon in use is the choice (`alternateIconName`):
  Verso keeps no setting for it.
  - **An alternate is an app icon set of PNGs:** one opaque 1024 picture edge to edge, its Day look as the light
    appearance and its Night look as the dark one (`ios/Verso/Assets.xcassets/AppIcon-Sand.appiconset`), which iOS
    rounds and makes its tinted and clear looks from. Xcode 27 takes an Icon Composer document as an alternate too,
    but compiles it into three flattened 1024 pictures (any, dark, tinted) for the iPhone and three for the iPad, about
    2.8 MB a design on a device. Measured with `actool` on the release's catalog, universal and thinned for an iPhone
    17 Pro as the App Store thins it: the 13 PNG sets add 5.8 MB to the universal catalog and 2.9 MB to an iPhone's,
    and the picker's pictures 2.9 MB and 1.8 MB; with the Night looks the catalog is 4.4 MB larger universal and 2.4 MB
    larger on an iPhone than with the seven designs alone. As Icon Composer documents the 13 would add about 37 MB on
    an iPhone. What a PNG set gives up is the document's own rendering: the lens's glass as a glass layer, and tinted
    and clear made from the layers rather than from the picture.
  - **The picker's pictures** are image sets of the icon's square, Day and Night (`AppIcon-SandImage`,
    `AppIcon-SandGraphiteImage`), as the sign-in's welcome has for Mist, since reading an app icon back with
    `UIImage(named:)` is no API. Both builds carry all 28, as an image set cannot be left out by the build.
- **The Mac: the Dock's picture while Verso runs.** macOS has no alternate app icons. The icon Finder and Launchpad
  show, and the Dock while Verso is not running, is the bundle's: a sandboxed app cannot set a custom icon on its own
  bundle (`NSWorkspace.setIcon` writes to the bundle), and a changed bundle breaks its signature. What an app may change
  is its running icon, `NSApplication.applicationIconImage`: the Dock and the app switcher show it while Verso runs, and
  AppKit's About panel and Verso's own pictures of its icon (the sign-in window, the bell's heading) read it. So the
  choices are user defaults of the app's (`appIcon.light`, `appIcon.dark`), as the menu bar icon's colour is, applied
  as Verso starts, when chosen, and when the system's appearance changes, which the app follows by key-value observing
  `NSApplication.effectiveAppearance` (`AppIconChoice`). Where the look is what the bundle's icon shows in that
  appearance (Mist in light mode, and Mist Night in dark mode from macOS 26, whose Icon Composer document has the dark
  appearance), it sets nil, which gives the Dock the bundle's icon back. Settings says that Finder and Launchpad keep
  Mist.
  - **The pictures are the Mac's PNG sets** (`mac/Verso/Verso/Assets.xcassets/AppIcon-SandNight.appiconset`, the
    drawing macOS 15 shows, a Night look on its dark paper), compiled as alternate icons so that `NSImage(named:)`
    finds them: 7.7 MB for the 27. Compiled from Icon Composer documents, `NSImage(named:)` gives the system's
    flattened light rendering, a picture alike but for the lens's glass, at about 1.9 MB a design.
- **Not chosen:**
  - **Icon Composer documents as alternates,** on either platform: twelve times the size on an iPhone, six on the
    Mac, above.
  - **PNG sets at each size iOS asks for** (the Home Screen's 60 points at 2x and 3x, Spotlight's, Settings' and
    notifications'), rather than one 1024 picture: a fraction of the size, but the Home Screen's large icons would be
    scaled up from 180 pixels.
  - **Any look for each mode on the iPhone:** a set for each pair, 784 of them. Nor a design for each mode with one
    colour or graphite switch: 98 sets, about 22 MB on a phone (5 to 8 MB with the pictures' colours reduced), too
    much for an icon's choice (the maintainer's choice).
  - **On the Mac, the choice in `config.toml` as `app.icon`:** that file is in the App Group, where Verso Drive's
    extension reads it too, and the icon is the app's alone; the app keeps its own choices as user defaults, as the
    menu bar icon's colour is an app setting rather than `tray.colour`.
- **Flatpak impact:** none; the Apple apps alone.

### Privacy manifests

The App Store refuses a build whose bundles call the APIs Apple asks a reason for without one, so each bundle that
calls any has its manifest (`ios/Config/Privacy/<target>/PrivacyInfo.xcprivacy`, copied into its bundle by
`ios/project.yml`). Apple's check reads the symbols a binary uses, the Rust bridge's file calls among them, so what
each bundle declares is read from its built binary (`nm -u`, and `strings` for Objective-C selectors such as
`systemUptime`):
- **Nothing tracked, nothing collected:** what Verso sends goes to the person's own Immich server, never to us or to
  anyone else, which is not collection in Apple's sense.
- **The app:** user defaults, its own settings (`CA92.1`); file times of files in its containers (`C617.1`), the Rust
  bridge's `stat` among them, and of files the person picks to import (`3B52.1`); the time since boot, for upload
  speeds (`35F9.1`); free space, before writing files to upload and for Free Up Space's card (`E174.1`).
- **Verso Drive:** file times in its own and the app group's containers (`C617.1`), the bridge's.
- **Verso in Messages:** user defaults (`CA92.1`), file times in its container (`C617.1`), and the time since boot
  (`35F9.1`), as it shares the API layer.
- **The widgets** call none, and have none.
- **Flatpak impact:** none; iOS alone.

## Across the platforms

### The icon

**Verso's icon is a print:** Verso is the other side of a photo, so its app icon is a print, the square edge to edge
as Linux shows app icons, the lens with Immich's five colours in its picture, Verso written by hand on its strip and
its corner turned over to show the back (`linux/packaging/icons/dev.hviid.Verso.svg`, drawn by
`linux/packaging/icons/sources/app-icon.py` and made into each size by
`linux/packaging/icons/linux-app-icon.py`). It is related to Immich by its colours, never by its shapes: not Immich's
flower logo, which would make Verso look official (principle 11), and nothing of Kartax's app icon. It is drawn for
this project as SVG by a script of our own, and is MIT like the rest. DESIGN.md, "The icon family", has the look.
- **Its picture comes in seven designs,** all kept, and **Mist** is the app icon on every platform (the maintainer's
  choice): the dark picture made the icon heavy, and a light one reads as a print. The others are drawn by the same
  script beside it, so they stay one drawing with one picture changed. A light picture lightens the lens's barrel
  against itself; the small icons, the lens alone, keep its own dark barrel, so they are one lens whatever the design
  (DESIGN.md, "The picture's designs").
- **Each design in four looks:** on Day or Night paper, its lens in colour or in graphite (the maintainer's choice), 28
  drawings (`dev.hviid.Verso-<look>.svg`, `sand-night-graphite`). Night is for a dark desktop: a light print with a
  light picture glares among dark icons, and macOS 26 and iOS darken an icon's background where icons are dark but not a
  picture drawn on it, so without a dark picture of its own Mist is a light picture on dark paper. Graphite is for those
  who want no colour, a monochrome lens that still reads as Verso's. Every platform follows the system's light and dark
  style with the look chosen for each, Mist Day and Mist Night by default: Linux in Preferences, both looks free ("The
  app icon's designs on Linux"), the Mac in Settings for the Dock, both looks free, and the iPhone and the iPad as
  alternate icons, a design and its lens, Day and Night ("The app icon's designs on the Mac, the iPhone and the iPad").
  The looks are drawn by the script, never by hand, so a change to the drawing reaches all 28.
- **The symbolic icon** is the print as one solid shape with the lens, the line on its strip and the turned corner cut
  out (`dev.hviid.Verso-symbolic.svg`), for the tray, notifications and Files' sidebar. The tray's states are
  variants of it, in one colour and in colour ("When the server cannot be reached"). `linux/packaging/icons/sources/`
  draws both, and the tray's states.
- **Verso Drive has an icon of its own,** the app's with a drive's badge in its corner (`dev.hviid.Verso.Drive`,
  `Product::drive_icon`), on its volume, its folder and its Crosslink entry, so a dock showing mounted drives does not
  show two Verso icons alike. Files shows it by the ways it offers ("The drive's icon").
- **The window's own icons** (the Date Scroller's, Square Photos', the stack's, a Live Photo's) sit in `icons` beside
  the program. A Live Photo's (`verso-live-symbolic`) is a dot and a ring inside a ring of the lens's five segments,
  the Mac gallery's Live Photo symbol in Verso's rhythm; repeat arrows would say looping rather than a moment.
- **Flatpak impact:** a Flatpak exports icons named after its own app ID, `dev.hviid.Verso`, so it ships the icon as
  it is.
- **On the Mac** the same print takes Apple's rounded square (`mac/Verso/make-icons.py`, from the same SVG): the asset
  catalog's `AppIcon` for macOS before 26, rendered with `rsvg-convert`, and an Icon Composer document
  (`Verso/AppIcon.icon`), the same drawing in layers the system lights, with a light appearance, Mist's Day look, and a
  dark one, its Night look, which macOS 26 and later show, with their tinted and clear appearances made from these.
  Apple publishes no schema of `icon.json`: its keys follow Xcode's own template and documents saved by Icon Composer.
  The PNGs are committed, since the Mac has no SVG renderer that draws to a given size. The Dev build's icon is the
  release's but for the turned corner's back, blue with DEV on it in white.
  - **Finder's sidebar** shows each location with a one-colour symbol, which the provider names in its extension's
    `CFBundleSymbolName` and ships in its asset catalog, as Nextcloud and OneDrive do (without one, Finder draws a
    generic drive or folder). Verso Drive's is the app icon's lens (`make-symbol.py`): an SF Symbols template (v6.0)
    with its three source weights made from one geometry, so they interpolate. Its segments are layers that ask for
    the ring's colours, so a renderer that draws symbols in colour shows them, and one that does not shows the lens.
  - **The menu bar item** shows the lens in each of the tray's states (`make-menu-bar-icon.py`), the same small icon
    Verso has in Finder's sidebar and in Messages, so the small icons are one lens everywhere and only the app icon
    tells the Dev build apart (the maintainer's choice). In one colour by default, a template image that macOS draws
    in the menu bar's black or white as its neighbours are; in colour where Settings says so, as Linux's top bar icon
    (`tray.colour`). A colour image is drawn as it is, so there what a state adds is mid-grey with white, cut clear of
    the lens, which shows on either bar. PNGs at menu bar icons' size, 18 points with a 16-point lens: a symbol takes
    the text's size and comes out smaller than its neighbours, and the asset catalog's renderer is not sure to draw an
    SVG's masks and filters.

### Translations

Verso's texts on Linux (the service's notifications and tray, the sign-in, Verso Drive's pages and the settings they
show), the Files extension's menu and Finder's action names are in English and 20 other languages. Machine translation
makes a language cheap, so the list follows reach: the most spoken languages by total speakers (Ethnologue's ranking)
that desktops commonly offer, with the Arabic and Chinese varieties under their written standards and languages whose
speakers mostly set another listed one (Javanese, Nigerian Pidgin) left out, and Danish, the maintainer's: Arabic,
Bengali, Chinese (Simplified), Danish, French, German, Hindi, Indonesian, Italian, Japanese, Korean, Marathi,
Portuguese, Russian, Spanish, Tamil, Telugu, Turkish, Urdu and Vietnamese. Portuguese is Brazil's, which both platforms
also offer to Portugal.

- **One source for every platform:** gettext catalogs, `po/<language>.po`, keyed by the English text and made from
  `po/verso.pot`, in the domain `verso`. `po/i18n.py extract` writes the template from the sources and brings every
  catalog in line with it; it finds `tr("...")` in Rust, the Files extension's `dgettext` and `translate`, the rows of a
  table of titles (`("grouping", "Date Folders")`), and the settings table's descriptions and choice labels, which the
  core keeps unmarked. Catalogs are what translation platforms and translators know, and GTK reads them itself.
- **Values are `{name}` placeholders,** filled in after the lookup, the same way on every platform, so a translation may
  move them. No text has plural forms: those with a count are phrased around it ("Files in Upload that have not reached
  Immich: {count}"). `po/i18n.py check` (part of the gate CI runs) fails when the template is stale or a translation
  drops a placeholder; an untranslated text shows in English.
- **The drive's folders keep their names** in every language (SPEC.md, "Names"; folder names in the user's language
  are parked in the ROADMAP), so a switch or a setting that names one (Photos, Albums, People, Places, Favorites,
  Archive, Upload) names it as the drive shows it, in a translated sentence. The extractor leaves the bare names
  out of the catalogs.
- **The core and the command line stay English.** The core holds no translation machinery, so it stays portable; the
  window and the service translate its texts where they show them. The command line's output is a contract (its JSON,
  these docs, `--llm`), and English there is what a search for an error finds. Errors from the server or the system,
  quoted in a message, stay as they come.
- **The gallery's own texts** are not in the catalogs yet. On Linux they go through `tr` (and `_()` in the window's
  Blueprint, under the domain `verso`) and stay out of `po/` until they settle (`po/i18n.py`'s `SOURCES` leave them
  out); the Mac app's are its String Catalogs (`Localizable.xcstrings` and its siblings), taken from Immich Gallery with
  their translations, in Italian, which App Icon's texts in Settings have too. The iPhone app carries no catalog yet,
  so its texts are in English.
- **Linux:** `po/i18n.py mo` compiles the catalogs into `verso.mo`; the tarball keeps them in `share/locale` beside its
  programs (`linux/packaging/verso-tarball.sh`), and the Flatpak in `/app/share/locale`. A program looks beside itself,
  in `share/locale` and then `../share/locale`, which also finds a Flatpak's `/app/share/locale`. `verso-linux`'s
  `i18n::tr` reads them by gettext's rules (`LANGUAGE`, unless the locale is C, then `LC_ALL`, `LC_MESSAGES`, `LANG`)
  without the C library's gettext, so the service translates its notifications and tray with no libintl. The Files
  extension in Python finds the catalogs beside `verso-service`, where the tarball puts them. `po/i18n.py desktop`
  writes a launcher entry's `Comment` and `Keywords` in every language; Verso's entries are not made with it yet.
- **macOS:** `mac/build-rust.sh` runs `po/i18n.py apple`, which writes `<language>.lproj/Localizable.strings` and
  `InfoPlist.strings` into `mac/build/Localization`, which Verso Drive's extension carries, so Finder finds its
  actions' names. An English table is there too, empty, so a Mac whose first language is English and second Danish
  stays in English.
- **Made by an AI model,** and disclosed in the README; corrections from native speakers come as pull requests to
  the language's `.po` file.
- **Flatpak impact:** none. The catalogs travel in the app's own `share/locale`, which the lookup beside the program
  finds; a Flatpak's separate locale extensions are not needed for one small domain.
- **Not chosen:** Fluent (Rust-native, but foreign to GTK, Apple and the translation platforms); an Xcode String
  Catalog as the source of the shared texts (one format per platform, kept in step by hand); the `gettext-rs` crate
  (it links libintl into the service).

### Verso's releases

Verso on every platform (Linux, and the Apple editions to come: macOS and iOS) carries one name, Verso, and lives in
this one repository, on the same crates, with one version line. A version names a tag (`v0.72.0`), not a release of
every platform at once: each platform ships the versions it gets to, and a version in a bug report names the code
whatever the platform. The platforms cannot ship together because the Apple editions need the maintainer at the Mac
(no macOS VMs on Erebus, and the Mac is a laptop used in sessions): building can run on GitHub's Mac runner, but the
check before a release needs a person.

**Releases are cut by a tag** (the maintainer's choice), so the maintainer decides when a release happens and what it
is numbered, and a push releases nothing. `ci/release.sh` suggests the next version from the commit subjects since the
last tag (`ci/version.sh`), tags the number the maintainer agrees to, builds Linux's files from the tag into a
**draft** release, and publishes it after the maintainer's check; AGENTS.md, "Versioning", has the steps and the
version rules. Until Verso goes public, each release is published both here and in the public
`jakobhviid/verso-releases`, which Homebrew's `verso` cask downloads from (ROADMAP, M8, "Going public"). No Mac
release has gone out yet; the Mac's disk image, and the rpm and deb packages, are not part of the release step
(ROADMAP, M9, step 6).

- **Every release carries Linux,** also one whose commits touch only the Apple editions. The newest release then
  always has the Linux files, so GitHub's Latest is right for Linux, and the Mac's version is never ahead of Linux's.
- **An Apple build ships once the maintainer has checked it on the Mac,** and goes on the GitHub release of the tag
  it was built from, normally the newest. A fix made during that session is a new commit, so a new tag and release,
  which Linux goes out with too. Between sessions the Mac stays on its last version while Linux moves on (Mac 3.5.2,
  Linux 3.8.7), and the gap says how far behind the Mac is.
- **The release list says which platforms each release carries:** its title names them ("Verso 3.9.0 (Linux and
  macOS)", "Verso 3.9.1 (Linux)"). A release with a Mac build has a macOS section in its notes, covering everything
  since the previous Mac release (`ci/release-notes.sh` from that release's tag), because Mac users skip the
  Linux-only versions in between.
- **Each platform's newest comes from its own place,** not from the top of the release list: Linux from GitHub's
  Latest; the Mac from the newest release that carries a disk image, which a download page and Sparkle's feed are to
  be made from; iOS from the App Store and TestFlight, never from GitHub.
- **iOS shares the line:** the App Store asks only that each version be higher than the one before, which each tag's
  is, as `ci/release.sh tag` takes only a number after the last. The Mac and iOS apps share their Swift code and live
  together.
- **The Mac's and iOS's build number is the build's UTC time** to the minute (`CURRENT_PROJECT_VERSION =
  20261122.1435`, written by `mac/build-rust.sh`): TestFlight and Sparkle need it to rise with every build, also
  between two builds of one version. A count of the commits would give two builds of one commit the same number, and
  a branch a lower one than main's.
- **Majors stay in step by themselves:** there is one line of tags.
- **Flatpak impact:** none. The Flatpak is a Linux build and goes out with every release, its version in its source
  archive's `VERSION`.
- **Not chosen:**
  - **A release for every push to main, numbered by its commits** (the house guidelines' way): the history would
    decide when a release happens, not the maintainer, the number would say little about what changed, and no release
    would be a draft checked before it goes out.
  - **Releasing every platform together:** Linux would wait for the Mac sessions.
  - **A version line per platform** (`linux-v3.8.7`, `mac-v3.5.2`): a commit to the shared crates would raise every
    platform's version with its subject's bump, also for what one platform's users never get, and a version would name
    the code only together with its platform.
  - **A repository per platform:** the shared crates would become a pinned dependency, a change to them would land in
    several repositories, and CI could not check it against the Mac build before it lands. Worth it only if the halves
    had different owners or visibility.
  - **Leaving Linux out of a release that touches only the Apple editions:** it would put a release without Linux files
    at the top of the list, marked Latest.
  - **A rolling release named "latest,"** its files replaced each time: its tag would not name one build, so a link or
    a bug report could not say which it meant.

### Testing

| Layer | What | Where |
|---|---|---|
| Unit | Naming and clashes (stability as entries come and go, case and NFC clashes, 255-byte cuts), node keys, grouping thresholds, month keys from `localDateTime` around time zones, block arithmetic and read-ahead, the URI encoder against GLib, PNG chunks, error mapping, multipart encoding | `cargo test` in the toolbox |
| Core | The core driven through the in-memory adapter | `cargo test` |
| Contract | `immich-api` against a real server, with both the read-only and the full key, on the floor and the latest release. Run on demand and before milestones, never as part of a normal `cargo test` that would need the LAN | Erebus `lab/immich-server` (`IMMICH_VERSION=...`) |
| Sign-in | The OIDC flow against an identity provider on Erebus: Dex (static users, scriptable) for automated runs, and Pocket ID (passkeys, what the maintainer uses) for a manual check | `lab/immich-server/oidc.sh` (Dex); Pocket ID by hand |
| Mount | The daemon mounted for real: listing, checksums against the server, ranged reads, copies and moves into Upload with the server stopped midway, hang checks with the server down | The development host (`/dev/fuse` is there) or an Erebus container |
| Window | Verso's window driven under GTK's Broadway backend in the development toolbox, against Immich's demo server and the lab server, each change checked through Immich's API | The toolbox |
| Desktop | Files, the sidebar and eject, thumbnails with zero originals read, copies and moves through Files' own operations, a video seeking in a player, the window and the tray in a real session, screenshots | `lab/gnome-vm`, and `lab/bazzite-vm` for Bazzite as its users have it |
| The Mac | The bridge's answers through a fake library on Linux, and the arrangements it hands the gallery; the portable crates' and the bridge's tests, the app and its extensions built unsigned, and the app's offline checks (`check.py`), on a Mac runner or the Mac; the endpoint calls through the core, live (`check-core.sh`); Finder itself on the maintainer's Mac, by hand | `cargo test`; CI's `macos` job; the Mac |
| Packaging | The tarball and the Flatpak, built by hand and run in the GNOME VM; for the rpm and deb packages to come, an install matrix in containers, built after Immich Mount's | Erebus `lab/gnome-vm/` |

Tests also hold the docs to the code:
- SPEC's config example parses
- WORKFLOWS names only real commands
- the D-Bus table in SPEC matches the interface
- every `--json` command writes exactly one JSON document

The skills in `.claude/skills/` say how each lab is driven; AGENTS.md, "The green gate", has the adversarial review
before milestones.

### Prior art

| Project | Relation to this one |
|---|---|
| Kartax/immich-desktop-app (macOS) | Immich Mount's inspiration, and so Verso Drive's: the same idea on macOS, through Apple's File Provider. No code is shared |
| Immich Mount | The maintainer's earlier app, an Immich library as a drive on Linux and macOS: Verso Drive is its drive |
| IGOLz/ImmichGallery (MIT) | Alessandro Craciun's native Mac client: Verso's Mac app is built from it ("Verso on the Mac"), and Verso's window on Linux follows many of its pages |
| boul2gom/immich-rs (MIT) | The API layer started from it. Other Rust clients (`immich` 0.2.0, `immich_api_rs` generated for v1.137, `immich-lib` for duplicates) were stale or too narrow |
| Dynamic-Solutions-Canada/immich-drive (Windows) | The same idea on Windows, through the Cloud Files API. It also has Favorites and Partners sections (ROADMAP, "Parked on purpose") |
| Katy248/immichfs (Go) and AlessandroLorenzi/immich-fuse (Python), both Linux FUSE | Read-only, and without thumbnail handling, so on GNOME both download every original of every folder opened. Thumbnails, sync, sign-in and uploads would be new code there too, so this is a project of its own |
| PersistentCloud/immich-webdav-wrapper | A different model: it runs next to the server, reads Immich's library volume directly, and covers albums only. GNOME treats WebDAV as a remote location, with no thumbnails by default and no volume |

Credits and licenses: [CREDITS.md](CREDITS.md).

## Note for the house guidelines

This project follows the maintainer's house style, `rust-cli-guidelines` (a private guide), which assumes
run-and-exit command-line tools. These are the deviations, and what they suggest for the guidelines:

- **Two binaries on Linux.** The service and the command line (`verso-service`) are one binary with subcommands, as
  the guidelines prefer. The window (`verso`) is a second binary, because it links GTK, which the service must not.
- **`CLAUDE.md` is a symlink** to `AGENTS.md` (the maintainer's choice), rather than the 6-line pointer.
- **Typed errors in the core,** with `anyhow` at the edges, because the FUSE adapter maps error kinds to error codes.
- **Long-running service and desktop app concerns** have no home in the guidelines: a systemd user unit, a D-Bus
  interface and a tray served over it, launcher entries and icons, and packaging that links system libraries. They
  are documented here, and could seed a "daemon + desktop app" chapter in the guidelines.
- **The Mac edition is mostly Swift and Xcode,** outside Cargo: a SwiftUI app, a File Provider extension, a widget and
  an XcodeGen project. Its Rust is a library the Swift code calls, so the guidelines' CLI rules apply to it only as
  far as Rust style goes.
- **The release pipeline** is not the house one: Verso's releases are cut by a tag the maintainer makes, built into a
  draft, and published after a check ("Verso's releases"), where the guidelines release every push to main; so the
  version is the tag's, and the commits since it only suggest the next one. Its channels, a tarball for Homebrew's
  cask and a Flatpak, with rpm and deb packages to come, go beyond the guidelines' CLI binaries.
- **Every release is kept** (the maintainer's choice), where the guidelines prune to the last ten. A busy day cuts more
  than ten releases, so pruning would leave users no version to roll back to, and would break any cask or package
  still pointing at an older version's files. GitHub sets no limit on a repository's release storage (only 2 GiB per
  file). The guidelines could drop the pruning step.
