# Security

## Reporting a vulnerability

Please report security problems privately, not in a public issue: use **Report a vulnerability** on the
repository's Security tab, or email jakob@hviid.phd. Say what you found, how to reproduce it, and which version you
ran (Verso's About window, or `verso-service --version`). Reports are answered as soon as possible, fixed in a new
release, and credited in it if you want.

Only the latest release gets fixes.

Problems in the Immich server itself belong to the Immich project:
[its security policy](https://github.com/immich-app/immich/security/policy).

## What Verso holds

- **The credential** for your Immich server: a session token or an API key, never your password. On Linux it is
  kept in the keyring (the Secret Service, such as GNOME Keyring). Without one it is a file readable only by you
  (`~/.config/verso/credential`, mode 0600), which the service refuses if anyone else can read it. It never appears
  in logs. On the Mac, the iPhone and the iPad it is kept in the Keychain, on that device only: readable after its
  first unlock, and never carried to another device by a backup, Quick Start or Migration Assistant, so a new device
  signs in once. With Verso Drive on, its extension reads it from a Keychain group only Verso and its extension
  share. The Apple TV keeps a key of its own in its Keychain, the same way: one the iPhone's Set Up Apple TV made for
  it, allowed only to read, which the person never sees. Sign Out on the TV forgets it; the key itself stays in Immich
  until Forget on the iPhone's Apple TV page, or deleting it in Immich, ends it, as a read-only key may not delete
  itself. The key never opens the Locked Folder. With the Locked Folder shown in the TV's Settings, the TV opens it
  only through the iPhone, each time: Verso on the iPhone asks, with Face ID or the PIN, makes the TV a session of its
  own that the server ends within the hour, unlocks it with the PIN and sends its token alone, so the TV never learns
  the PIN. The TV keeps that token in memory, never on disk, keeps the folder's pictures in memory and out of the Top
  Shelf, and ends the session as it leaves the folder or the front; Lock on the iPhone's Apple TV page ends it too.
  Unlike the key, the session is not limited to reading, as Immich gives sessions no narrower scope; Verso on the TV
  changes nothing with it.
- **The Locked Folder's PIN,** where Touch ID or Face ID opens the folder, once the PIN has been typed. On the Mac it
  is kept in the login keychain, on that Mac only, and given back only after the app's own Touch ID check, with the
  fingerprints enrolled when it was kept. On the iPhone and the iPad it is kept in the Keychain, on that device only,
  behind Face ID (or Touch ID) itself: the Keychain asks for one of the faces or fingers enrolled when it was kept
  before it gives the PIN back, and the device's passcode never does. Beside it, without Face ID, a note says that a PIN
  is kept and which faces were enrolled then, and nothing more. Enrolling another face or finger, a PIN the
  server turns down, signing out and turning the setting off forget it (Unlock with Touch ID in the Mac's Settings,
  Security; Unlock with Face ID in the account's sheet on the iPhone and the iPad). On Linux it is typed each time and
  kept nowhere.
- **Copies of your photos:** server thumbnails, the gallery's pictures and the parts of originals that were read, in
  your cache directory (`~/.cache/verso`), and thumbnails in the desktop's thumbnail cache. Signing out (**Sign Out…**
  in Verso, or `verso-service logout`) removes them. On the Mac, the iPhone and the iPad the viewer keeps the original
  movies of the last 40 Live Photos it played or fetched ahead, in the app's caches folder, and signing out removes
  them. The Apple TV keeps, for its Top Shelf, the previews of the rows its Settings chooses (today's memories' first
  photos and the newest photos until changed; the albums' covers, the newest favorites and people's faces once turned
  on; none from the Locked Folder), in a caches folder of the App Group it shares with its Top Shelf extension, written
  again each time it starts and as the rows change, and removed by Sign Out. Files that could not be uploaded are kept in
  `~/.local/share/verso/not-uploaded/`; they are yours, and signing out leaves them. On the iPhone and the iPad,
  originals opened through Verso Drive stay in iOS's copy of its location until iOS removes them, or until turning the
  drive off or signing out removes the location whole, files in its Upload folder not yet uploaded included (Verso asks
  first). Backing the iPhone up keeps, on the device, each photo's local and iCloud identifiers, the fingerprints
  (SHA-1) of its parts, and its Immich asset and state; a photo's bytes only briefly, in an upload's body or an iCloud
  download, removed once it is sent and kept out of the device's own backup. Verso in Messages keeps no credential (it
  reads the app's account from the Keychain group the app shares with its extensions); it keeps thumbnails in a cache
  of its own (up to 100 MB on disk), and each photo it puts into the message field, a preview or, when chosen, the
  original with its metadata, in a temporary folder for a day. It connects only to the server the app is signed in
  to, and changes nothing there. Copy and Save to Photos download originals into a temporary folder, removed once they
  are on the pasteboard or in the photo library; Save to Photos asks only to add to the library, and reads nothing
  from it. Share downloads an original only when the app chosen in the share sheet asks for it, into a folder of the
  temporary directory (the Locked Folder's into its own), removed when the sheet closes, and any left from before at
  the next share; on the Mac the same, from its share picker, removed once the service chosen says it is done, and any
  left an hour later at the next share or launch. Create Link… and Add to Link… download nothing. A link makes its
  photos visible to anyone who has its address (and its password, where it has one) until it expires or is deleted.
- **Its network use:** it talks to the Immich server you sign in to, over https unless you choose otherwise: an
  address typed without `https://` or `http://` is tried with https, and with plain http after that only for a server
  on your local network and never after a certificate's error (on Linux, never), so nobody on the way can turn a
  connection to a server elsewhere into an unencrypted one. An address typed with `http://` is reached as typed.
  Verso trusts the certificates your system trusts (its trust store, where you can add a private authority; on the
  iPhone and the iPad, a profile). A server's own certificate the system does not trust (self-signed, or from a
  private authority) is never accepted by itself: Verso shows it, with its SHA-256 fingerprint to compare with the
  server's, and trusts exactly that certificate, for that server alone, only once you choose Trust This Certificate
  (or give its fingerprint to `verso-service login`). On Linux the fingerprint is kept with the server's address in
  `config.toml`; on the Mac, the iPhone and the iPad with the account in the Keychain, and Verso Drive's copy beside
  the server's address in the App Group. A certificate the server presents later that is not that one is refused and
  asked about again, and nothing is sent to the server until you decide; the account's page (Preferences, Account on
  Linux) forgets it, and on the Mac, the iPhone and the iPad signing out does too. Videos from such a server play
  through Verso's own connection, which checks the same certificate. Verso never accepts every certificate, nor
  trusts an authority for you. On Linux the map comes from where your Immich
  server's map setting points, as Immich's web app's does: its style, its icons and its tiles, from Immich's own
  `tiles.immich.cloud` and `static.immich.cloud` unless the server's admin chose other hosts, which learn the areas
  you look at; nothing is fetched until a map shows, the style's fonts are never fetched (Verso writes the map's
  names in your computer's fonts), and the tiles are kept in `~/.cache/shumate` (up to 100 MB), which signing out
  leaves. On the Mac, the iPhone and the iPad the map is Apple's, where a place search when you adjust a photo's
  location also sends the words you type to Apple's maps (Linux searches through your Immich server). On the
  iPhone and the iPad, **Look Up Place Names with Apple Maps** (Account, On This iPhone; off until you switch it on)
  sends the location of each photo you open to Apple, to name the landmark or street in its title; off, places are named
  from your Immich server alone, and photos in the Locked Folder are never looked up. Verso's rpm and deb look for a
  newer release once a day (`updates.check`, Check for Updates in Preferences, on until you switch it off): the
  service reads `https://jakob.hviid.phd/verso/latest.json`, sending nothing but the request and Verso's name and
  version as its User-Agent. An install by Homebrew, the tarball, the Flatpak or the AppImage never looks.
- **What it changes on the server:** the gallery changes your library only when you ask it to (a favorite, a rating, an
  album, a tag, a comment or a like, a date or a place, a crop or a turn, a stack, the archive, the trash, sharing, an
  import).
  Backing the iPhone up, once switched on, uploads the device's photos, stacks them and sets the date and place Photos
  has on the assets it made, and with each photo never edited, its iCloud identifier, when it was taken and where, as
  Immich's own app does, so that app knows it; it never deletes on the server, and never backs up to Immich's public
  demo. Hidden photos go into your Locked Folder, never your timeline; freeing them unlocks its session with your PIN,
  typed, or given by Face ID where the Locked Folder keeps it, and locks it again after. Free Up Space deletes photos from the phone
  only after you review them and iOS asks, and only those whose every part Immich holds, checked as the review opens
  and again right before (the same checksum and size, the original readable on the server); they go to Recently
  Deleted for 30 days, while Verso checks Immich for them. Verso Drive uploads files you copy into its Upload folder,
  and never edits, moves or deletes what is already in your library.
  Signing out ends Verso's own session.

SPEC.md, "Files on disk", lists every file it writes.
