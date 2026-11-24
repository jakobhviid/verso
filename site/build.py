#!/usr/bin/env python3
"""Build Verso's page (jakob.hviid.phd/verso; DESIGN.md, "The website") for the releases there are: site/index.html
with the latest release's version and download links, its pictures, style, icons and photo credits, written into an
output folder to be served as it is. Standard library only.

    gh api 'repos/jakobhviid/verso-releases/releases?per_page=30' > releases.json
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
# The public repository the releases are mirrored to while Verso's own is private (ci/release.sh).
RELEASES = "https://github.com/jakobhviid/verso-releases"
TARBALL = "verso-x86_64.tar.gz"
FLATPAK = "verso-x86_64.flatpak"
# The rpm and the deb of a release (linux/packaging/verso-packages.sh), named by its version.
RPM = "verso-{version}.x86_64.rpm"
DEB = "verso_{version}_amd64.deb"
DISK_IMAGE = r"(?i)verso[-_ ].*\.dmg"

# Each platform's icon for that platform (DESIGN.md, "A platform's icon only where that platform is meant"): Mist on Day
# paper, and on Night paper for the dark appearance.
ICONS = {
    "icon-linux.svg": "linux/packaging/icons/dev.hviid.Verso.svg",
    "icon-linux-night.svg": "linux/packaging/icons/dev.hviid.Verso-mist-night.svg",
    "icon-mac.png": "mac/Verso/Verso/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png",
    "icon-mac-night.png": "mac/Verso/Verso/Assets.xcassets/AppIcon-MistNight.appiconset/icon_128x128@2x.png",
    "icon-ios.png": "ios/Verso/Assets.xcassets/AppIconImage.imageset/AppIconImage@3x.png",
    "icon-ios-night.png": "ios/Verso/Assets.xcassets/AppIconImage.imageset/AppIconImage-dark@3x.png",
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


def appcast(mac, disk_image):
    """Sparkle's feed with the one update, from the disk image's update file (ci/sign-mac-update.sh): the version
    Sparkle compares is the build number, and the disk image's size and signature are what the app checks before
    installing it. None when the release carries no update file."""
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
    return f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Verso</title>
    <link>{PAGE}</link>
    <item>
      <title>Verso {html.escape(version)}</title>
      <pubDate>{email.utils.format_datetime(published)}</pubDate>
      <sparkle:version>{html.escape(update["build"])}</sparkle:version>
      <sparkle:shortVersionString>{html.escape(version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>{html.escape(mac["html_url"])}</sparkle:releaseNotesLink>
      <enclosure url="{html.escape(disk_image)}" length="{size}" type="application/octet-stream"
                 sparkle:edSignature="{html.escape(update["signature"])}"/>
    </item>
  </channel>
</rss>
"""


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
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>The photos in Verso's pictures</title>
  <meta name="color-scheme" content="light dark">
  <link rel="icon" href="mark.svg" type="image/svg+xml">
  <link rel="stylesheet" href="style.css">
</head>
<body>
  <nav class="bar wrap" aria-label="Verso">
    <a class="brand" href="./"><img src="mark.svg" alt="" width="30" height="30"><span>Verso</span><span class="for">for Immich</span></a>
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


def main(releases_file, output, app_store=None, testflight=None):
    releases = published(json.loads(Path(releases_file).read_text()))
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
            if testflight else "",
        ])
    else:
        ios = (
            '<p><span class="status soon">Coming</span></p>'
            '<p>Verso for the iPhone and the iPad will come through TestFlight first, then the App Store.</p>'
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
        "macos": macos,
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
    # What a Linux package from this page looks at to tell of a newer release (ARCHITECTURE.md, "Updates on Linux").
    (output / "latest.json").write_text(json.dumps({"version": version, "page": PAGE}) + "\n")
    feed = appcast(mac, disk_image) if disk_image else None
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
    parser.add_argument("releases", help="the releases, as gh api repos/jakobhviid/verso-releases/releases writes them")
    parser.add_argument("output")
    parser.add_argument("--app-store", help="Verso's page in the App Store, once it is there")
    parser.add_argument("--testflight", help="Verso's public TestFlight link, once there is one")
    arguments = parser.parse_args()
    main(arguments.releases, arguments.output, arguments.app_store, arguments.testflight)
