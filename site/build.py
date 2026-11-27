#!/usr/bin/env python3
"""Build Verso's page (jakob.hviid.phd/verso; DESIGN.md, "The website") for the releases there are: site/index.html
with the latest release's version and download links, its pictures, style, icons and photo credits, written into an
output folder to be served as it is. Standard library only.

    gh api 'repos/jakobhviid/verso/releases?per_page=30' > releases.json
    site/build.py releases.json OUTPUT [--app-store URL] [--testflight URL]

site/build-latest.sh gathers releases.json and runs this. Linux's files come from the newest published release that
carries the tarball, and the Mac's disk image from the newest one that carries a disk image (ARCHITECTURE.md,
"Verso's releases"); without one, the page shows the Mac as coming, so it never offers a file that is not there. With
the disk image's update file beside it (ci/sign-mac-update.sh), the page also carries appcast.xml, Sparkle's feed. The
iPhone and the iPad come from the App Store and TestFlight, never from GitHub: their links are given here once they
exist.

Each {{shot NAME|ALT}} in index.html is the picture site/screenshots/NAME.webp (or .png), with NAME-dark beside it for
the dark appearance where there is one; a picture not taken yet is a place marked for it, and the build lists them.
"""

import argparse
import email.utils
import html
import json
import re
import shutil
import struct
import sys
import urllib.request
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SITE = ROOT / "site"
PAGE = "https://jakob.hviid.phd/verso/"
REPOSITORY = "https://github.com/jakobhviid/verso"
RELEASES = REPOSITORY
TARBALL = "verso-x86_64.tar.gz"
FLATPAK = "verso-x86_64.flatpak"
# The same Verso as one file with its libraries inside, for the systems the Flatpak is for (linux/packaging/verso-appimage.sh).
APPIMAGE = "verso-x86_64.AppImage"
# The rpm and the deb of a release (linux/packaging/verso-packages.sh), named by its version.
RPM = "verso-{version}.x86_64.rpm"
DEB = "verso_{version}_amd64.deb"
DISK_IMAGE = r"(?i)verso[-_ ].*\.dmg"
# Verso's public TestFlight link, for the iPhone and the iPad until the App Store has Verso.
TESTFLIGHT = "https://testflight.apple.com/join/7z1ppMM8"

# The brand and each platform's icon for that platform (DESIGN.md, "The website"): Mist on Day paper in both
# appearances, as people know the icon from their system.
ICONS = {
    # Verso's own: the app icon's design, Mist on Day paper, which every platform's icon is drawn from.
    "icon.svg": "linux/packaging/icons/dev.hviid.Verso.svg",
    "icon-linux.svg": "linux/packaging/icons/dev.hviid.Verso.svg",
    "icon-mac.png": "mac/Verso/Verso/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png",
    "icon-ios.png": "ios/Verso/Assets.xcassets/AppIconImage.imageset/AppIconImage@3x.png",
}


def published(releases):
    """The published releases, newest first: no drafts, no pre-releases."""
    kept = [release for release in releases if not release.get("draft") and not release.get("prerelease")]
    return sorted(kept, key=lambda release: release.get("published_at") or "", reverse=True)


def newest_with(releases, pattern):
    """The newest release with an asset whose name matches `pattern`, and that asset's address; or (None, None)."""
    for release in releases:
        for asset in release.get("assets", []):
            if re.fullmatch(pattern, asset["name"]):
                return release, asset["browser_download_url"]
    return None, None


def asset_url(release, name):
    for asset in (release or {}).get("assets", []):
        if asset["name"] == name:
            return asset["browser_download_url"]
    return None


def mac_notes(releases):
    """The update window's notes: the macOS section of each release with a disk image, newest first (the latest
    three), as one small page in the system's font, for Sparkle to show as it is. Empty when none has one."""
    parts = []
    for release in [r for r in releases if any(re.fullmatch(DISK_IMAGE, a["name"]) for a in r.get("assets", []))][:3]:
        body = release.get("body") or ""
        found = re.search(r"^## macOS\s*\n(.*?)(?=^## |\Z)", body, re.M | re.S)
        if not found:
            continue
        blocks = []
        for block in re.split(r"\n\s*\n", found.group(1).strip()):
            lines = [line for line in block.splitlines() if line.strip()]
            inline = lambda text: re.sub(r"`([^`]+)`", r"<code>\1</code>", html.escape(text))
            if lines and all(line.lstrip().startswith("- ") for line in lines):
                blocks.append("<ul>" + "".join(f"<li>{inline(line.lstrip()[2:])}</li>" for line in lines) + "</ul>")
            else:
                blocks.append(f"<p>{inline(' '.join(lines))}</p>")
        parts.append(f"<h3>Verso {html.escape(release['tag_name'].lstrip('v'))}</h3>" + "".join(blocks))
    if not parts:
        return ""
    style = ("<style>:root{color-scheme:light dark}body{font:13px -apple-system,sans-serif;margin:8px 10px}"
             "h3{font-size:13px;margin:12px 0 4px}h3:first-child{margin-top:0}p,ul{margin:4px 0}"
             "code{font:12px ui-monospace,monospace}</style>")
    return '<!doctype html><meta charset="utf-8">' + style + "".join(parts)


def appcast_item(mac, disk_image, notes="", channel=None):
    """One update in Sparkle's feed, from the disk image's update file (ci/sign-mac-update.sh): the version Sparkle
    compares is the build number, and the disk image's size and signature are what the app checks before installing
    it; a beta's carries Sparkle's `beta` channel, which only a beta's build takes (mac/Verso/Verso/App/Updates.swift).
    None when the release carries no update file."""
    name = disk_image.rsplit("/", 1)[-1]
    update_url = asset_url(mac, name + ".update")
    if update_url is None:
        return None
    with urllib.request.urlopen(update_url, timeout=60) as response:
        text = response.read().decode()
    update = dict(line.split("=", 1) for line in text.split() if "=" in line)
    size = next(asset["size"] for asset in mac["assets"] if asset["name"] == name)
    version = mac["tag_name"].lstrip("v")
    published = datetime.fromisoformat(mac["published_at"].replace("Z", "+00:00"))
    # CDATA keeps the notes' HTML as it is; their text is escaped, so "]]>" cannot occur in it.
    description = f"      <description><![CDATA[{notes}]]></description>\n" if notes else ""
    beta = f"      <sparkle:channel>{html.escape(channel)}</sparkle:channel>\n" if channel else ""
    return f"""    <item>
      <title>Verso {html.escape(version)}</title>
      <pubDate>{email.utils.format_datetime(published)}</pubDate>
      <sparkle:version>{html.escape(update["build"])}</sparkle:version>
      <sparkle:shortVersionString>{html.escape(version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
{beta}{description}      <enclosure url="{html.escape(disk_image)}" length="{size}" type="application/octet-stream"
                 sparkle:edSignature="{html.escape(update["signature"])}"/>
    </item>
"""


def appcast(items):
    """Sparkle's feed: the stable release's update, and the newest beta's where it is newer, on the beta channel."""
    if not items:
        return None
    return f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Verso</title>
    <link>{PAGE}</link>
{"".join(items)}  </channel>
</rss>
"""


def newest_beta(every, after):
    """The newest beta (a published pre-release) with a disk image, where it came out after `after`, the stable
    release: the beta channel's update. (None, None) otherwise."""
    betas = [release for release in every if release.get("prerelease") and not release.get("draft")]
    betas.sort(key=lambda release: release.get("published_at") or "", reverse=True)
    beta, image = newest_with(betas, DISK_IMAGE)
    if beta and (after is None or (beta.get("published_at") or "") > (after.get("published_at") or "")):
        return beta, image
    return None, None


def link(url, text):
    if url is None:
        return f'<span class="missing">{html.escape(text)}</span>'
    return f'<a href="{html.escape(url)}">{html.escape(text)}</a>'


def packages(release, version):
    """The release's rpm and deb, each with the command that installs it, where the release carries them: a release
    from before them offers none, so the page never offers a file that is not there."""
    items = []
    for kind, name, system, command in (("rpm", RPM, "Fedora 43 and newer", "sudo dnf install ./"),
                                        ("deb", DEB, "Ubuntu 26.04 and newer, and Debian 14", "sudo apt install ./")):
        file = name.format(version=version)
        url = asset_url(release, file)
        if url:
            items.append(f'<li>{link(url, f"The {kind}, {file}")}<span>For {system}: '
                         f'<code>{html.escape(command + file)}</code>. Verso tells you when a new version is out.'
                         '</span></li>\n            ')
    return "".join(items)


def day(timestamp):
    """A release's day as people write it: 23 November 2026."""
    when = datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
    return f"{when.day} {when:%B %Y}"


def picture_size(path):
    """A PNG's or a WebP's width and height, from its header."""
    data = path.read_bytes()[:40]
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        return struct.unpack(">II", data[16:24])
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        kind = data[12:16]
        if kind == b"VP8X":
            return int.from_bytes(data[24:27], "little") + 1, int.from_bytes(data[27:30], "little") + 1
        if kind == b"VP8L":
            bits = int.from_bytes(data[21:25], "little")
            return (bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1
        if kind == b"VP8 ":
            return (int.from_bytes(data[26:28], "little") & 0x3FFF,
                    int.from_bytes(data[28:30], "little") & 0x3FFF)
    sys.exit(f"{path} is neither a PNG nor a WebP")


def find_shot(name):
    for suffix in (".webp", ".png"):
        path = SITE / "screenshots" / f"{name}{suffix}"
        if path.is_file():
            return path
    return None


class Shots:
    """The page's pictures: each {{shot NAME|ALT}} made a <picture>; one not taken yet leaves its place out."""

    def __init__(self):
        self.used = []
        self.missing = []

    def __call__(self, match):
        name, alt = match.group(1), match.group(2).strip()
        light = find_shot(name)
        if light is None:
            self.missing.append(name)
            return "<!-- to come -->"
        dark = find_shot(f"{name}-dark")
        self.used += [path for path in (light, dark) if path]
        width, height = picture_size(light)
        # The first picture is the hero's, wanted at once; the others load as they come near.
        loading = 'fetchpriority="high"' if len(self.used) <= 2 else 'loading="lazy"'
        source = (f'<source srcset="screenshots/{dark.name}" media="(prefers-color-scheme: dark)">' if dark else "")
        return (f'<picture>{source}<img src="screenshots/{light.name}" alt="{html.escape(alt)}" width="{width}" '
                f'height="{height}" {loading} decoding="async"></picture>')


def photo_credits():
    """The photos' page: every work in the showcase server's library, which the pictures are taken from
    (lab/immich-server/fixtures/showcase/), with its author and licence."""
    manifest = json.loads((ROOT / "lab/immich-server/fixtures/showcase/manifest.json").read_text())
    rows = []
    for work in manifest["files"]:
        title = re.sub(r"\.(jpe?g|png|webm|ogv|tiff?)$", "", work["title"].removeprefix("File:"), flags=re.I)
        licence = (f'<a href="{html.escape(work["licenseUrl"])}">{html.escape(work["license"])}</a>'
                   if work.get("licenseUrl") else html.escape(work.get("license", "")))
        rows.append(f'<tr><td><a href="{html.escape(work["pageUrl"])}">{html.escape(title)}</a></td>'
                    f'<td>{html.escape(work.get("author") or "Unknown")}</td><td>{licence}</td></tr>')
    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <script>try {{ const chosen = localStorage.getItem("appearance"); if (chosen) document.documentElement.dataset.theme = chosen; }} catch {{}}</script>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>The photos in Verso's pictures</title>
  <meta name="color-scheme" content="light dark">
  <link rel="icon" href="mark.svg" type="image/svg+xml">
  <link rel="stylesheet" href="style.css">
</head>
<body>
  <nav class="bar wrap" aria-label="Verso">
    <a class="brand" href="./"><img src="icon.svg" alt="" width="34" height="34"><span>Verso</span><span class="for">for Immich</span></a>
  </nav>
  <main class="wrap credits-page">
    <h1>The photos in Verso's pictures</h1>
    <p class="intro">The pictures on Verso's page show a library made for them: {len(rows)} photos and videos from
      Wikimedia Commons, each CC0 or in the public domain, with dates and places written in for the story. Thanks to
      the photographers who share their work.</p>
    <div class="print credits-table">
      <table>
        <thead><tr><th>Work</th><th>Author</th><th>Licence</th></tr></thead>
        <tbody>
          {"".join(rows)}
        </tbody>
      </table>
    </div>
  </main>
</body>
</html>
"""


def privacy_page():
    """Verso's privacy policy, for the App Store, TestFlight and everyone: what Verso keeps, where it connects, and
    that it collects nothing. SECURITY.md has the details it stands on."""
    return """<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <script>try { const chosen = localStorage.getItem("appearance"); if (chosen) document.documentElement.dataset.theme = chosen; } catch {}</script>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Privacy: Verso for Immich</title>
  <meta name="color-scheme" content="light dark">
  <link rel="icon" href="mark.svg" type="image/svg+xml">
  <link rel="stylesheet" href="style.css">
</head>
<body>
  <nav class="bar wrap" aria-label="Verso">
    <a class="brand" href="./"><img src="icon.svg" alt="" width="34" height="34"><span>Verso</span><span class="for">for Immich</span></a>
  </nav>
  <main class="wrap credits-page">
    <h1>Privacy</h1>
    <p class="intro">Verso for Immich is an app for your own Immich server. It collects nothing about you: no
      analytics, no tracking, no advertising, and no account with us. Your photos and your sign-in stay between your
      devices and your server.</p>
    <div class="print">
      <h2>What Verso connects to</h2>
      <ul>
        <li><strong>Your Immich server,</strong> the one you sign in to, and nothing else for your library.</li>
        <li><strong>Maps:</strong> on the iPhone, the iPad and the Mac, Apple's maps; on Linux, the map your Immich
          server's settings name (Immich's own unless its admin chose another), which learns the areas you look at.</li>
        <li><strong>Place names with Apple Maps,</strong> on the iPhone and the iPad, only if you switch it on: the
          location of a photo you open is sent to Apple to name the place. Off by default; never for the Locked
          Folder.</li>
        <li><strong>Updates:</strong> Verso on the Mac, and Verso's rpm and deb on Linux, check this page for a newer
          version, sending nothing but the request and Verso's version.</li>
      </ul>
      <h2>What Verso keeps on your device</h2>
      <ul>
        <li><strong>Your sign-in,</strong> a session or an API key (never your password), in the Keychain on Apple's
          devices and the keyring on Linux.</li>
        <li><strong>Copies of your photos</strong> it has shown, in the cache, which signing out removes.</li>
        <li><strong>Backing up the iPhone:</strong> each photo's identifiers and fingerprints, to know what is already
          on your server; a photo's bytes only while it is being sent.</li>
      </ul>
      <h2>What Verso changes on your server</h2>
      <p>Only what you ask it to: a favourite, an album, a share link, an upload, the trash, and the like.</p>
      <h2>Questions</h2>
      <p>Ask on <a href="https://github.com/jakobhviid/verso/issues">Verso's issues</a>, or write to
        <a href="mailto:jakob@hviid.phd">jakob@hviid.phd</a>. The full account of what Verso holds, sends and changes is
        in <a href="https://github.com/jakobhviid/verso/blob/main/SECURITY.md">SECURITY.md</a>. Verso is an
        independent, unofficial project, not affiliated with the Immich project or FUTO.</p>
    </div>
  </main>
</body>
</html>
"""


def main(releases_file, output, app_store=None, testflight=TESTFLIGHT):
    every = json.loads(Path(releases_file).read_text())
    releases = published(every)
    linux, tarball = newest_with(releases, re.escape(TARBALL))
    if linux is None:
        sys.exit(f"no published release in {releases_file} carries {TARBALL}")
    mac, disk_image = newest_with(releases, DISK_IMAGE)
    version = linux["tag_name"].lstrip("v")

    if disk_image:
        macos = (
            '<p>One app for the Mac, signed and notarized by Apple. Verso Drive appears in Finder\'s sidebar once you '
            'switch it on.</p>'
            f'<p><a class="button" href="{html.escape(disk_image)}">Download for the Mac</a></p>'
            '<p>Or with <a href="https://brew.sh">Homebrew</a>:</p>'
            '<pre class="command"><code>brew install --cask jakobhviid/tap/verso</code></pre>'
            f'<p class="small">Version {html.escape(mac["tag_name"].lstrip("v"))}. Open the disk image and drag Verso '
            'into Applications.</p>'
        )
    else:
        macos = (
            '<p><span class="status soon">Coming</span></p>'
            '<p>Verso for the Mac is being finished, and is not released yet. It will come as a disk image, signed '
            'and notarized by Apple, and with Homebrew.</p>'
        )
    if app_store or testflight:
        ios = "".join([
            f'<p><a class="button" href="{html.escape(app_store)}">Download on the App Store</a></p>' if app_store else "",
            f'<p>Or try the next version first, in <a href="{html.escape(testflight)}">TestFlight</a>.</p>'
            if testflight and app_store else "",
            f'<p><a class="button" href="{html.escape(testflight)}">Join the beta in TestFlight</a></p>'
            '<p class="small">Install Apple\'s TestFlight app, open the link on the iPhone or the iPad, and accept. On '
            'an Apple TV signed in to the same Apple Account, Verso is then in its TestFlight app too.</p>'
            if testflight and not app_store else "",
        ])
    else:
        ios = (
            '<p><span class="status soon">Coming</span></p>'
            '<p>Verso for the iPhone, the iPad and the Apple TV will come through TestFlight first, then the App Store.</p>'
        )

    values = {
        "page": PAGE,
        "repository": REPOSITORY,
        "releases_url": f"{RELEASES}/releases",
        "version": html.escape(version),
        "published": html.escape(day(linux["published_at"])),
        "release_url": html.escape(linux["html_url"]),
        "packages": packages(linux, version),
        "tarball": link(tarball, f"The tarball, {TARBALL}"),
        "flatpak": link(asset_url(linux, FLATPAK), f"The Flatpak, {FLATPAK}"),
        "appimage": link(asset_url(linux, APPIMAGE), f"The AppImage, {APPIMAGE}"),
        "macos": macos,
        "ios_status": ('<span class="status out">App Store</span>' if app_store
                       else '<span class="status out">TestFlight</span>' if testflight
                       else '<span class="status soon">Coming</span>'),
        "mac_status": '<span class="status out">Released</span>' if disk_image else '<span class="status soon">Coming</span>',
        "ios": ios,
    }
    page = (SITE / "index.html").read_text()
    shots = Shots()
    page = re.sub(r"\{\{shot ([a-z0-9-]+)\|([^}]*)\}\}", shots, page)
    # A published page shows no empty frame: a picture's place, and the frame around it, wait for the picture.
    page = re.sub(r'<div class="shot[^"]*"><!-- to come --></div>\n?\s*', "", page)
    for name, value in values.items():
        page = page.replace("{{" + name + "}}", value)
    left = re.findall(r"\{\{[^}]*\}\}", page)
    if left:
        sys.exit(f"index.html has values build.py does not fill: {', '.join(sorted(set(left)))}")

    output = Path(output)
    if output.exists():
        shutil.rmtree(output)
    (output / "screenshots").mkdir(parents=True)
    (output / "index.html").write_text(page)
    (output / "photos.html").write_text(photo_credits())
    (output / "privacy.html").write_text(privacy_page())
    # What a Linux package from this page looks at to tell of a newer release (ARCHITECTURE.md, "Updates on Linux").
    (output / "latest.json").write_text(json.dumps({"version": version, "page": PAGE}) + "\n")
    items = [appcast_item(mac, disk_image, mac_notes(releases))] if disk_image else []
    beta, beta_image = newest_beta(every, mac)
    if beta:
        items.append(appcast_item(beta, beta_image, mac_notes([beta]), channel="beta"))
    feed = appcast([item for item in items if item])
    if feed:
        (output / "appcast.xml").write_text(feed)
    for name in ("style.css", "mark.svg", "llms.txt"):
        shutil.copy(SITE / name, output / name)
    social = SITE / "social-preview.png"
    if social.is_file():
        shutil.copy(social, output / social.name)
    for name, source in ICONS.items():
        shutil.copy(ROOT / source, output / name)
    for path in shots.used:
        shutil.copy(path, output / "screenshots" / path.name)
    # A renamed picture or icon would leave a broken image rather than fail, so every local link is checked.
    local = re.findall(r'(?:src|href|srcset)="([^"#:]+)"', page)
    broken = [path for path in local if not (output / path).is_file() and not (output / path).is_dir()]
    if broken:
        sys.exit(f"index.html links files the page does not have: {', '.join(sorted(set(broken)))}")
    print(f"built the page for Verso {version} (Linux) in {output}")
    if shots.missing:
        print(f"pictures to come ({len(shots.missing)}): {', '.join(shots.missing)}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("releases", help="the releases, as gh api repos/jakobhviid/verso/releases writes them")
    parser.add_argument("output")
    parser.add_argument("--app-store", help="Verso's page in the App Store, once it is there")
    parser.add_argument("--testflight", default=TESTFLIGHT, help="Verso's public TestFlight link")
    arguments = parser.parse_args()
    main(arguments.releases, arguments.output, arguments.app_store, arguments.testflight)
