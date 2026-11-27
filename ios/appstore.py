#!/usr/bin/env python3
"""Verso's App Store listing (DESIGN.md, "The App Store listing"): sends the texts, the review details and the
screenshots in ios/AppStore to App Store Connect, into the version being prepared for the iPhone and the iPad (IOS) and
for the Apple TV (TV_OS), and TestFlight's beta description, review details and the newest builds' What to Test. It
fills in what App Store Connect's API reaches; App Privacy, pricing and the submission are the maintainer's, in App
Store Connect. Python's standard library and openssl only, so it runs on the Mac and on a CI runner as it is.

    ios/appstore.py check                                         the texts' lengths and the screenshots, offline
    ios/appstore.py medium                                        the medium iPhone's pictures, from the large one's
    ios/appstore.py push [--version X.Y.Z] [--platform ios|tvos|all] [--no-screenshots]
    ios/appstore.py beta [--platform ios|tvos|all]           the beta channel: each newest build to TestFlight's
                                                              external groups, and to its beta review
    ios/appstore.py submit [--version X.Y.Z] [--platform ...] the stable channel: the version's newest build, the one
                                                              TestFlight tested, attached and sent to App Review

push reads the API key as ios/release.sh does: ASC_KEY_ID, ASC_ISSUER_ID, and the key file (ASC_KEY_FILE, else
~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8). The review contact comes from ios/AppStore/contact.local
(git-ignored; `first_name=`, `last_name=`, `email=`, `phone=`, one a line) and is left out where it is missing. The
version is ci/version.sh's unless --version names one.
"""
import argparse
import base64
import hashlib
import json
import os
import struct
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LISTING = ROOT / "ios/AppStore"
LOCALE = "en-US"
BUNDLE_ID = "dev.hviid.Verso"
API = "https://api.appstoreconnect.apple.com"
URLS = {
    "supportUrl": "https://github.com/jakobhviid/verso/issues",
    "marketingUrl": "https://jakob.hviid.phd/verso/",
    "privacyPolicyUrl": "https://jakob.hviid.phd/verso/privacy.html",
}
CATEGORY = "PHOTO_AND_VIDEO"
# Immich's public demo, which App Review and TestFlight's review sign in to (review_notes.txt says how).
DEMO = ("demo@immich.app", "demo")

# Each platform's version, and its screenshots: the folder in ios/AppStore/screenshots and App Store Connect's display
# type, with the sizes it takes (either way round).
PLATFORMS = {
    # App Store Connect names the iPhone's by display: "iPhone with Dynamic Island, medium display" (APP_IPHONE_61,
    # 1206 x 2622), which it asks for and shows in search results, and the large display (APP_IPHONE_67, 1320 x 2868).
    "ios": {"api": "IOS", "shots": {"iphone-medium": "APP_IPHONE_61", "iphone": "APP_IPHONE_67",
                                    "ipad": "APP_IPAD_PRO_3GEN_129",
                                    # Verso in Messages, which the listing's iMessage App section shows.
                                    "imessage-iphone-medium": "IMESSAGE_APP_IPHONE_61",
                                    "imessage-iphone": "IMESSAGE_APP_IPHONE_67",
                                    "imessage-ipad": "IMESSAGE_APP_IPAD_PRO_3GEN_129"}},
    "tvos": {"api": "TV_OS", "shots": {"tv": "APP_APPLE_TV"}},
}
SIZES = {
    "APP_IPHONE_61": {(1179, 2556), (1206, 2622)},
    "IMESSAGE_APP_IPHONE_61": {(1179, 2556), (1206, 2622)},
    "APP_IPHONE_67": {(1290, 2796), (1320, 2868)},
    "APP_IPAD_PRO_3GEN_129": {(2048, 2732), (2064, 2752)},
    "APP_APPLE_TV": {(1920, 1080), (3840, 2160)},
    "IMESSAGE_APP_IPHONE_67": {(1290, 2796), (1320, 2868)},
    "IMESSAGE_APP_IPAD_PRO_3GEN_129": {(2048, 2732), (2064, 2752)},
}
# The texts, by file, with App Store Connect's limits (keywords count bytes).
LIMITS = {"name": 30, "subtitle": 30, "promotional_text": 170, "keywords": 100, "description": 4000,
          "whats_new": 4000}
EDITABLE = {"PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED", "INVALID_BINARY"}


def text(name, platform=None, required=True):
    """A text of the listing: the platform's own (en-US/tvos/description.txt) where it has one, else the shared one."""
    for folder in ([LISTING / LOCALE / platform] if platform else []) + [LISTING / LOCALE, LISTING]:
        path = folder / f"{name}.txt"
        if path.is_file():
            return path.read_text().strip()
    if required:
        sys.exit(f"missing ios/AppStore/{LOCALE}/{name}.txt")
    return None


def png_size(path):
    data = path.read_bytes()[:24]
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        sys.exit(f"{path} is not a PNG")
    return struct.unpack(">II", data[16:24])


def screenshots(platform):
    """Each display type's pictures, in their names' order."""
    found = {}
    for folder, display in PLATFORMS[platform]["shots"].items():
        files = sorted((LISTING / "screenshots" / folder).glob("*.png"))
        if files:
            found[display] = files
    return found


def medium():
    """The medium display's pictures (1206 x 2622) from the large one's (1320 x 2868), whose shape they share to a
    tenth of a percent, as App Store Connect would scale them: with sips on the Mac, Pillow elsewhere."""
    for large, small in (("iphone", "iphone-medium"), ("imessage-iphone", "imessage-iphone-medium")):
        target = LISTING / "screenshots" / small
        if target.exists():
            for old in target.glob("*.png"):
                old.unlink()
        for path in sorted((LISTING / "screenshots" / large).glob("*.png")):
            target.mkdir(parents=True, exist_ok=True)
            out = target / path.name
            if sys.platform == "darwin":
                subprocess.run(["sips", "-z", "2622", "1206", str(path), "--out", str(out)], check=True,
                               capture_output=True)
            else:
                from PIL import Image
                Image.open(path).convert("RGB").resize((1206, 2622), Image.LANCZOS).save(out)
            print(f"{out.relative_to(ROOT)}")


def check():
    problems = []
    for platform in PLATFORMS:
        for name, limit in LIMITS.items():
            value = text(name, platform, required=name != "whats_new")
            if value is None:
                continue
            length = len(value.encode()) if name == "keywords" else len(value)
            print(f"{platform:5} {name:17} {length:5} / {limit}")
            if length > limit:
                problems.append(f"{platform} {name} is {length}, over {limit}")
        for display, files in screenshots(platform).items():
            if len(files) > 10:
                problems.append(f"{display} has {len(files)} pictures, over 10")
            for path in files:
                width, height = png_size(path)
                if (width, height) not in SIZES[display] and (height, width) not in SIZES[display]:
                    problems.append(f"{path.relative_to(ROOT)} is {width}x{height}, not a size {display} takes")
            print(f"{platform:5} {display:22} {len(files)} pictures")
    for problem in problems:
        print(f"problem: {problem}", file=sys.stderr)
    return not problems


# The API.

def token():
    key_id, issuer = os.environ.get("ASC_KEY_ID"), os.environ.get("ASC_ISSUER_ID")
    if not key_id or not issuer:
        sys.exit("ASC_KEY_ID and ASC_ISSUER_ID are needed")
    key = Path(os.environ.get("ASC_KEY_FILE") or Path.home() / f".appstoreconnect/private_keys/AuthKey_{key_id}.p8")
    if not key.is_file():
        sys.exit(f"no API key at {key}")

    def encoded(value):
        raw = value if isinstance(value, bytes) else json.dumps(value, separators=(",", ":")).encode()
        return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()

    now = int(time.time())
    signing = encoded({"alg": "ES256", "kid": key_id, "typ": "JWT"}) + "." + encoded(
        {"iss": issuer, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"})
    der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", str(key)], input=signing.encode(),
                         capture_output=True, check=True).stdout
    # openssl gives the signature as DER (a sequence of r and s); a JWT carries the two numbers, 32 bytes each.
    numbers, at = [], 2 + (1 if der[1] & 0x80 else 0)
    for _ in range(2):
        length = der[at + 1]
        numbers.append(int.from_bytes(der[at + 2:at + 2 + length], "big").to_bytes(32, "big"))
        at += 2 + length
    return signing + "." + encoded(b"".join(numbers))


class Connect:
    def __init__(self):
        self.token = token()

    def call(self, method, path, body=None, params=None):
        url = path if path.startswith("http") else API + path
        if params:
            url += "?" + urllib.parse.urlencode(params)
        request = urllib.request.Request(url, method=method, data=json.dumps(body).encode() if body else None,
                                         headers={"Authorization": f"Bearer {self.token}",
                                                  "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                raw = response.read()
                return json.loads(raw) if raw else None
        except urllib.error.HTTPError as error:
            detail = error.read().decode(errors="replace")
            try:
                detail = "; ".join(f"{item.get('title')}: {item.get('detail')}" for item in json.loads(detail)["errors"])
            except (ValueError, KeyError):
                pass
            raise RuntimeError(f"{method} {path}: {error.code} {detail}") from None

    def get(self, path, **params):
        return self.call("GET", path, params=params or None)

    def all(self, path, **params):
        """Every item of a list, page by page."""
        items, answer = [], self.get(path, **params)
        while True:
            items += answer.get("data") or []
            following = (answer.get("links") or {}).get("next")
            if not following:
                return items
            answer = self.call("GET", following)

    def one(self, path):
        """A to-one relationship's item, or None."""
        try:
            return (self.get(path) or {}).get("data")
        except RuntimeError as error:
            if " 404 " in str(error):
                return None
            raise

    def patch(self, kind, identifier, attributes=None, relationships=None):
        data = {"type": kind, "id": identifier}
        if attributes:
            data["attributes"] = attributes
        if relationships:
            data["relationships"] = relationships
        return self.call("PATCH", f"/v1/{kind}/{identifier}", {"data": data})

    def create(self, kind, attributes, relationships):
        return self.call("POST", f"/v1/{kind}", {"data": {"type": kind, "attributes": attributes,
                                                          "relationships": relationships}})["data"]


def related(kind, identifier):
    return {"data": {"type": kind, "id": identifier}}


def contact():
    path = LISTING / "contact.local"
    fields = {}
    if path.is_file():
        for line in path.read_text().splitlines():
            if "=" in line and not line.lstrip().startswith("#"):
                key, value = line.split("=", 1)
                fields[key.strip()] = value.strip()
    names = {"first_name": "contactFirstName", "last_name": "contactLastName", "email": "contactEmail",
             "phone": "contactPhone"}
    return {names[key]: value for key, value in fields.items() if key in names and value}


def localized(connect, path, kind, parent_kind, parent, attributes):
    """The en-US localization under `parent`, updated, or made where it has none; its id."""
    found = next((item for item in connect.all(path) if item["attributes"].get("locale") == LOCALE), None)
    if found:
        connect.patch(kind, found["id"], attributes)
        return found["id"]
    relationship = parent_kind[0].lower() + parent_kind[1:-1]  # appInfos -> appInfo
    return connect.create(kind, {"locale": LOCALE, **attributes}, {relationship: related(parent_kind, parent)})["id"]


def step(what, action):
    """One part of the listing: said when it is done, and said, not fatal, when App Store Connect turns it down."""
    try:
        action()
        print(f"  {what}")
        return True
    except RuntimeError as error:
        print(f"  {what}: not done: {error}", file=sys.stderr)
        return False


def push(version, platforms, with_screenshots):
    connect = Connect()
    apps = connect.get("/v1/apps", **{"filter[bundleId]": BUNDLE_ID})["data"]
    if not apps:
        sys.exit(f"no app {BUNDLE_ID} in App Store Connect")
    app = apps[0]["id"]
    print(f"Verso in App Store Connect, version {version}")
    ok = True

    # The app's information, shared by its platforms: its name, subtitle, privacy policy, category and age rating.
    infos = connect.all(f"/v1/apps/{app}/appInfos")
    info = next((item for item in infos if item["attributes"].get("appStoreState") in EDITABLE
                 or item["attributes"].get("state") in {"PREPARE_FOR_SUBMISSION", "WAITING_FOR_REVIEW"}), infos[0])
    ok &= step("name, subtitle and privacy policy", lambda: localized(
        connect, f"/v1/appInfos/{info['id']}/appInfoLocalizations", "appInfoLocalizations", "appInfos", info["id"],
        {"name": text("name"), "subtitle": text("subtitle"), "privacyPolicyUrl": URLS["privacyPolicyUrl"]}))
    ok &= step("category: Photo & Video", lambda: connect.patch(
        "appInfos", info["id"], relationships={"primaryCategory": related("appCategories", CATEGORY)}))

    def age_rating():
        declaration = connect.one(f"/v1/appInfos/{info['id']}/ageRatingDeclaration")
        if not declaration:
            raise RuntimeError("App Store Connect has no age rating to fill in yet")
        none = dict.fromkeys(["alcoholTobaccoOrDrugUseOrReferences", "contests", "gamblingSimulated",
                              "horrorOrFearThemes", "matureOrSuggestiveThemes", "medicalOrTreatmentInformation",
                              "profanityOrCrudeHumor", "sexualContentGraphicAndNudity", "sexualContentOrNudity",
                              "violenceCartoonOrFantasy", "violenceRealistic",
                              "violenceRealisticProlongedGraphicOrSadistic"], "NONE")
        none["gunsOrOtherWeapons"] = "NONE"
        # Verso shows the person's own library on their own server, and what the people they share albums with add to
        # it (photos, comments and likes in a shared album): no public content, no strangers, no chat of its own.
        # DESIGN.md, "The App Store listing", has the reasons; the maintainer confirms them in App Store Connect.
        no = dict.fromkeys(["gambling", "unrestrictedWebAccess", "lootBox", "ageAssurance", "advertising",
                            "healthOrWellnessTopics", "socialMedia", "userGeneratedContent", "messagingAndChat",
                            "parentalControls"], False)
        connect.patch("ageRatingDeclarations", declaration["id"], {**none, **no})
    ok &= step("age rating: none of the questions apply (4+)", age_rating)

    review = {"demoAccountName": DEMO[0], "demoAccountPassword": DEMO[1], "demoAccountRequired": True,
              "notes": text("review_notes"), **contact()}
    on_sale = any(item["attributes"].get("appStoreState") == "READY_FOR_SALE"
                  for item in connect.all(f"/v1/apps/{app}/appStoreVersions"))

    for platform in platforms:
        api = PLATFORMS[platform]["api"]
        print(f"{api}:")
        versions = connect.all(f"/v1/apps/{app}/appStoreVersions", **{"filter[platform]": api})
        editable = next((item for item in versions if item["attributes"].get("appStoreState") in EDITABLE), None)
        copyright = f"{time.gmtime().tm_year} Jakob Hviid"
        if editable is None:
            editable = connect.create("appStoreVersions", {"platform": api, "versionString": version,
                                                           "copyright": copyright}, {"app": related("apps", app)})
            print(f"  made version {version}")
        else:
            attributes = {"copyright": copyright}
            if editable["attributes"].get("versionString") != version:
                attributes["versionString"] = version
            ok &= step(f"version {version}", lambda: connect.patch("appStoreVersions", editable["id"], attributes))
        attributes = {"description": text("description", platform), "keywords": text("keywords", platform),
                      "promotionalText": text("promotional_text", platform),
                      "marketingUrl": URLS["marketingUrl"], "supportUrl": URLS["supportUrl"]}
        whats_new = text("whats_new", platform, required=False)
        if on_sale and whats_new:
            attributes["whatsNew"] = whats_new
        holder = {}

        def version_texts():
            holder["localization"] = localized(
                connect, f"/v1/appStoreVersions/{editable['id']}/appStoreVersionLocalizations",
                "appStoreVersionLocalizations", "appStoreVersions", editable["id"], attributes)
        ok &= step("description, keywords, promotional text and links", version_texts)

        def review_details():
            if len(contact()) < 4:
                raise RuntimeError("App Review needs its contact: first_name, last_name, email and phone (with + and "
                                   "the country code) in ios/AppStore/contact.local")
            found = connect.one(f"/v1/appStoreVersions/{editable['id']}/appStoreReviewDetail")
            if found:
                connect.patch("appStoreReviewDetails", found["id"], review)
            else:
                connect.create("appStoreReviewDetails", review,
                               {"appStoreVersion": related("appStoreVersions", editable["id"])})
        ok &= step("App Review's notes, demo account and contact", review_details)
        if with_screenshots and "localization" in holder:
            for display, files in screenshots(platform).items():
                ok &= step(f"{display}: {len(files)} pictures",
                           lambda: upload_set(connect, holder["localization"], display, files))

    # TestFlight: what Verso is, how to review it, and what to test in each platform's newest build.
    print("TestFlight:")
    beta = {"description": text("beta_description"), "marketingUrl": URLS["marketingUrl"],
            "privacyPolicyUrl": URLS["privacyPolicyUrl"]}
    if contact().get("contactEmail"):
        beta["feedbackEmail"] = contact()["contactEmail"]
    ok &= step("beta description", lambda: localized(
        connect, f"/v1/apps/{app}/betaAppLocalizations", "betaAppLocalizations", "apps", app, beta))

    def beta_review():
        found = connect.one(f"/v1/apps/{app}/betaAppReviewDetail")
        if found:
            connect.patch("betaAppReviewDetails", found["id"], review)
    ok &= step("beta review's notes and demo account, and the contact where contact.local has it", beta_review)
    for platform in platforms:
        api = PLATFORMS[platform]["api"]
        builds = connect.get("/v1/builds", **{"filter[app]": app, "filter[preReleaseVersion.platform]": api,
                                              "sort": "-uploadedDate", "limit": 1})["data"]
        if builds:
            build = builds[0]
            ok &= step(f"What to Test in {api} build {build['attributes'].get('version')}", lambda: localized(
                connect, f"/v1/builds/{build['id']}/betaBuildLocalizations", "betaBuildLocalizations", "builds",
                build["id"], {"whatsNew": text("what_to_test", platform)}))
    return ok


def newest_build(connect, app, api, version=None):
    """A platform's newest build, of `version` where one is named; None where there is none."""
    params = {"filter[app]": app, "filter[preReleaseVersion.platform]": api, "sort": "-uploadedDate", "limit": 1}
    if version:
        params["filter[preReleaseVersion.version]"] = version
    builds = connect.get("/v1/builds", **params)["data"]
    return builds[0] if builds else None


def beta(platforms):
    """The beta channel (AGENTS.md, "Versioning"): each platform's newest build in every external TestFlight group,
    the public link's among them, and sent to TestFlight's beta review, which the first build of a version needs."""
    connect = Connect()
    app = connect.get("/v1/apps", **{"filter[bundleId]": BUNDLE_ID})["data"][0]["id"]
    groups = [group for group in connect.all(f"/v1/apps/{app}/betaGroups")
              if not group["attributes"].get("isInternalGroup")]
    ok = True
    for platform in platforms:
        api = PLATFORMS[platform]["api"]
        build = newest_build(connect, app, api)
        if build is None:
            print(f"{api}: no build")
            continue
        number = build["attributes"].get("version")
        print(f"{api} build {number} ({build['attributes'].get('processingState')}):")
        for group in groups:
            ok &= step(f"in {group['attributes'].get('name')}", lambda group=group: connect.call(
                "POST", f"/v1/betaGroups/{group['id']}/relationships/builds",
                {"data": [{"type": "builds", "id": build["id"]}]}))

        def review():
            try:
                connect.create("betaAppReviewSubmissions", {}, {"build": related("builds", build["id"])})
            except RuntimeError as error:
                # A build TestFlight already reviewed, or one whose version passed beta review before, needs none.
                if " 409 " not in str(error):
                    raise
        ok &= step("sent to TestFlight's beta review where it needs one", review)
    return ok


def submit(version, platforms):
    """The stable channel (PRINCIPLES.md, 15): the version's newest build, the one TestFlight tested, attached to the
    App Store version and sent to App Review; releasing it once approved stays the maintainer's, in App Store Connect."""
    connect = Connect()
    app = connect.get("/v1/apps", **{"filter[bundleId]": BUNDLE_ID})["data"][0]["id"]
    ok = True
    for platform in platforms:
        api = PLATFORMS[platform]["api"]
        versions = connect.all(f"/v1/apps/{app}/appStoreVersions", **{"filter[platform]": api})
        editable = next((item for item in versions if item["attributes"].get("appStoreState") in EDITABLE
                         and item["attributes"].get("versionString") == version), None)
        if editable is None:
            print(f"{api}: no version {version} being prepared (ios/appstore.py push --version {version} makes it)")
            ok = False
            continue
        build = newest_build(connect, app, api, version)
        if build is None or build["attributes"].get("processingState") != "VALID":
            print(f"{api}: no processed build of {version} in TestFlight")
            ok = False
            continue
        print(f"{api} {version}, build {build['attributes'].get('version')}:")
        ok &= step("the build attached", lambda: connect.call(
            "PATCH", f"/v1/appStoreVersions/{editable['id']}/relationships/build",
            {"data": {"type": "builds", "id": build["id"]}}))

        def review():
            submission = connect.create("reviewSubmissions", {"platform": api}, {"app": related("apps", app)})
            connect.create("reviewSubmissionItems", {}, {
                "reviewSubmission": related("reviewSubmissions", submission["id"]),
                "appStoreVersion": related("appStoreVersions", editable["id"])})
            connect.patch("reviewSubmissions", submission["id"], {"submitted": True})
        ok &= step("sent to App Review", review)
    return ok


def upload_set(connect, localization, display, files):
    """A display type's pictures, in order, sent again only where they changed."""
    sets = connect.all(f"/v1/appStoreVersionLocalizations/{localization}/appScreenshotSets")
    found = next((item for item in sets if item["attributes"].get("screenshotDisplayType") == display), None)
    if found is None:
        found = connect.create("appScreenshotSets", {"screenshotDisplayType": display},
                               {"appStoreVersionLocalization": related("appStoreVersionLocalizations", localization)})
    shots = connect.all(f"/v1/appScreenshotSets/{found['id']}/appScreenshots")
    wanted = [(path.name, hashlib.md5(path.read_bytes()).hexdigest()) for path in files]
    if [(item["attributes"].get("fileName"), item["attributes"].get("sourceFileChecksum")) for item in shots] == wanted:
        return
    for item in shots:
        connect.call("DELETE", f"/v1/appScreenshots/{item['id']}")
    order = []
    for path in files:
        data = path.read_bytes()
        reserved = connect.create("appScreenshots", {"fileName": path.name, "fileSize": len(data)},
                                  {"appScreenshotSet": related("appScreenshotSets", found["id"])})
        for operation in reserved["attributes"]["uploadOperations"]:
            part = data[operation["offset"]:operation["offset"] + operation["length"]]
            headers = {header["name"]: header["value"] for header in operation.get("requestHeaders") or []}
            request = urllib.request.Request(operation["url"], data=part, method=operation["method"], headers=headers)
            with urllib.request.urlopen(request, timeout=120):
                pass
        connect.patch("appScreenshots", reserved["id"],
                      {"uploaded": True, "sourceFileChecksum": hashlib.md5(data).hexdigest()})
        order.append({"type": "appScreenshots", "id": reserved["id"]})
    connect.call("PATCH", f"/v1/appScreenshotSets/{found['id']}/relationships/appScreenshots", {"data": order})


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("check")
    commands.add_parser("medium")
    for name in ("beta", "submit"):
        channel = commands.add_parser(name)
        channel.add_argument("--platform", choices=["ios", "tvos", "all"], default="all")
        if name == "submit":
            channel.add_argument("--version")
    pushing = commands.add_parser("push")
    pushing.add_argument("--version")
    pushing.add_argument("--platform", choices=["ios", "tvos", "all"], default="all")
    pushing.add_argument("--no-screenshots", action="store_true")
    arguments = parser.parse_args()
    if arguments.command == "check":
        sys.exit(0 if check() else 1)
    if arguments.command == "medium":
        medium()
        return
    if arguments.command == "beta":
        chosen = list(PLATFORMS) if arguments.platform == "all" else [arguments.platform]
        sys.exit(0 if beta(chosen) else 1)
    if arguments.command == "submit":
        chosen = list(PLATFORMS) if arguments.platform == "all" else [arguments.platform]
        version = arguments.version or subprocess.run([str(ROOT / "ci/version.sh")], capture_output=True, text=True,
                                                      check=True).stdout.strip()
        sys.exit(0 if submit(version.split("-")[0], chosen) else 1)
    if not check():
        sys.exit("the listing has problems: nothing was sent")
    version = arguments.version or subprocess.run([str(ROOT / "ci/version.sh")], capture_output=True, text=True,
                                                  check=True).stdout.strip()
    platforms = list(PLATFORMS) if arguments.platform == "all" else [arguments.platform]
    sys.exit(0 if push(version, platforms, not arguments.no_screenshots) else 1)


if __name__ == "__main__":
    main()
