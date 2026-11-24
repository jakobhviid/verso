#!/usr/bin/env python3
"""Regenerate the showcase's manifest.json and ATTRIBUTION.md from the Wikimedia Commons API.

The showcase server (showcase.sh) is a library that looks like a person's own: trips, home, food, animals, old
portraits, a partner's photos. Every file is CC0 or public domain, so the website's and the App Store's pictures may
use them without credits; ATTRIBUTION.md credits them all the same. Run only to change the selection; showcase.sh
uses the committed, pinned manifest.json. Usage:  WIKIMEDIA_UA='...' python3 -I fixtures/showcase/build-manifest.py

Built as fixtures/build-manifest.py is: photos are Commons' standard-size renditions (1920 px wide, or the largest
standard width below the original's), which carry no EXIF, so the original's camera make and model are pinned in "exif" and written
back at seed time. Dates and places are the story's, not the photographers': each entry names a place (coordinates
and time zone below) and a local time, and the manifest pins the EXIF that showcase-container.sh writes. Videos are
the originals (WebM), transcoded to H.264 MP4 at seed time. Each rendition is downloaded once into cache/
(git-ignored) to pin its sha1 and sha256; the videos are pinned by Commons' sha1, and fixtures.sh downloads them.

People: Marketing must not show a recognisable living person without a model release. So no photo here shows one
up close: the named people are sitters of 19th-century photographs and of old paintings, all long dead and in the
public domain, which face detection finds and groups. "people" in each entry says what a photo shows, and
"marketing" whether the website and the App Store may use it ("yes", or "check" where people are small, turned away or
on a poster, so look first). Immich's face detection, run over the whole library, found no other person's face.
"""
import datetime, hashlib, html, json, os, re, sys, time, urllib.error, urllib.parse, urllib.request
from zoneinfo import ZoneInfo

UA = os.environ.get("WIKIMEDIA_UA",
     "Verso-lab-showcase/0.1 (showcase fixtures for a private development lab; low volume)")
API = "https://commons.wikimedia.org/w/api.php"
HERE = os.path.dirname(os.path.abspath(__file__))
STEPS = (500, 960, 1280, 1920)   # Commons' standard rendition widths; photos get the largest below the original's

# name: (latitude, longitude, IANA time zone). Coordinates of the sight, so Places groups them as a visitor's would.
PLACES = {
    "nyhavn": (55.6798, 12.5907, "Europe/Copenhagen"), "christianshavn": (55.6736, 12.5917, "Europe/Copenhagen"),
    "islands-brygge": (55.6647, 12.5773, "Europe/Copenhagen"), "botanical-garden": (55.6873, 12.5736, "Europe/Copenhagen"),
    "copenhagen-zoo": (55.6726, 12.5215, "Europe/Copenhagen"), "smk": (55.6888, 12.5784, "Europe/Copenhagen"),
    "frederiksberg": (55.6786, 12.5320, "Europe/Copenhagen"), "nordhavn": (55.7100, 12.5950, "Europe/Copenhagen"),
    "amager-strand": (55.6560, 12.6460, "Europe/Copenhagen"), "torvehallerne": (55.6838, 12.5698, "Europe/Copenhagen"),
    "indre-by": (55.6786, 12.5762, "Europe/Copenhagen"), "dyrehaven": (55.7915, 12.5660, "Europe/Copenhagen"),
    "thingvellir": (64.2559, -21.1299, "Atlantic/Reykjavik"), "skogafoss": (63.5321, -19.5114, "Atlantic/Reykjavik"),
    "dyrholaey": (63.4021, -19.1290, "Atlantic/Reykjavik"), "jokulsarlon": (64.0484, -16.1794, "Atlantic/Reykjavik"),
    "myvatn": (65.6039, -16.9961, "Atlantic/Reykjavik"), "hvitserkur": (65.6061, -20.6369, "Atlantic/Reykjavik"),
    "snaefellsnes": (64.8700, -23.0400, "Atlantic/Reykjavik"), "kirkjufell": (64.9416, -23.3074, "Atlantic/Reykjavik"),
    "leknes": (68.1476, 13.6110, "Europe/Oslo"), "reine": (67.9324, 13.0887, "Europe/Oslo"),
    "hovedoya": (59.8957, 10.7330, "Europe/Oslo"), "flam": (60.8628, 7.1137, "Europe/Oslo"),
    "naeroyfjord": (60.8820, 6.8370, "Europe/Oslo"),
    "kinkakuji": (35.0394, 135.7292, "Asia/Tokyo"), "fushimi-inari": (34.9671, 135.7727, "Asia/Tokyo"),
    "arashiyama": (35.0170, 135.6713, "Asia/Tokyo"), "philosophers-path": (35.0270, 135.7944, "Asia/Tokyo"),
    "kyoto-station": (34.9875, 135.7592, "Asia/Tokyo"), "roppongi": (35.6605, 139.7292, "Asia/Tokyo"),
    "tokyo-tower": (35.6586, 139.7454, "Asia/Tokyo"), "shibuya": (35.6595, 139.7005, "Asia/Tokyo"),
    "meiji-jingu": (35.6764, 139.6993, "Asia/Tokyo"), "asakusa": (35.7148, 139.7967, "Asia/Tokyo"),
    "ueno": (35.7156, 139.7745, "Asia/Tokyo"), "kanda": (35.6917, 139.7709, "Asia/Tokyo"),
    "watagataki": (36.3403, 136.6358, "Asia/Tokyo"), "kamakura": (35.3090, 139.5450, "Asia/Tokyo"),
    "montparnasse": (48.8421, 2.3220, "Europe/Paris"), "trocadero": (48.8616, 2.2893, "Europe/Paris"),
    "louvre": (48.8606, 2.3376, "Europe/Paris"), "abbesses": (48.8844, 2.3386, "Europe/Paris"),
    "marais": (48.8590, 2.3620, "Europe/Paris"), "tuileries": (48.8635, 2.3275, "Europe/Paris"),
    "paris-aquarium": (48.8622, 2.2910, "Europe/Paris"), "montmartre": (48.8867, 2.3431, "Europe/Paris"),
    "notre-dame": (48.8530, 2.3499, "Europe/Paris"),
    "pantheon": (41.8986, 12.4769, "Europe/Rome"), "colosseum": (41.8902, 12.4922, "Europe/Rome"),
    "colle-oppio": (41.8925, 12.4950, "Europe/Rome"), "trastevere": (41.8897, 12.4695, "Europe/Rome"),
    "vittoriano": (41.8946, 12.4831, "Europe/Rome"), "monti": (41.8955, 12.4930, "Europe/Rome"),
    "rialto": (45.4380, 12.3358, "Europe/Rome"), "san-marco": (45.4330, 12.3410, "Europe/Rome"),
    "accademia": (45.4316, 12.3289, "Europe/Rome"), "cannaregio": (45.4445, 12.3290, "Europe/Rome"),
    "top-of-the-rock": (40.7593, -73.9794, "America/New_York"), "flatiron": (40.7411, -73.9897, "America/New_York"),
    "chrysler": (40.7516, -73.9755, "America/New_York"), "dumbo": (40.7033, -73.9881, "America/New_York"),
    "soho": (40.7233, -74.0030, "America/New_York"), "national-gallery": (38.8913, -77.0200, "America/New_York"),
    "bica": (38.7096, -9.1465, "Europe/Lisbon"), "baixa": (38.7106, -9.1366, "Europe/Lisbon"),
    "alfama": (38.7114, -9.1300, "Europe/Lisbon"), "principe-real": (38.7165, -9.1490, "Europe/Lisbon"),
    "belem": (38.6916, -9.1771, "Europe/Lisbon"), "caparica": (38.6400, -9.2380, "Europe/Lisbon"),
    "grand-canyon": (36.0544, -112.1401, "America/Phoenix"), "cattle-point": (48.4507, -122.9622, "America/Los_Angeles"),
    "wallabi-beach": (-32.0018, 152.5550, "Australia/Sydney"),
}

# (Commons title without "File:", place or None, local time "YYYY-MM-DD HH:MM[:SS]", roles, caption or "").
# place None: the original's own GPS if it has one, else none (scans). Roles drive showcase-container.sh:
#   partner              the partner's photo (else the admin's)
#   trip=<name>          an album of that name, and the tag Travel/<country> from tags below
#   album=<name>         also in that album         tag=<a/b>   a tag, nested with "/"
#   favorite             rating=<1-5>               archive / trash / locked
#   stack=<group>        stacked with the others of the group; "stack=<group>:primary" is the cover
#   memory=<n>           taken on the seed day's month and day, n years earlier (Immich's "on this day")
#   person=<name>        a sitter, named after face detection   artwork: a photo of a painting
#   people=incidental    people in it, small, turned away or on a poster: look before using it in marketing
#   scan                 an old photograph, named SCAN_nnnn.JPG; its date is the photograph's, approximate
#   video                a video (transcoded to MP4 at seed time)
SELECTION = [
    # Paris, May 2014
    ("Map of Paris (Unsplash).jpg", "indre-by", "2014-05-14 21:10", ["archive", "tag=Travel/France"], "Planning the Paris trip"),
    ("Paris skyline view (Unsplash).jpg", "montparnasse", "2014-05-16 10:12", ["trip=Paris 2014", "rating=4"], "Paris from the Montparnasse tower"),
    ("Louvre Pyramid (Unsplash).jpg", "louvre", "2014-05-16 15:40", ["trip=Paris 2014", "tag=Architecture"], ""),
    ("Unexpected Moment (Unsplash).jpg", "trocadero", "2014-05-16 19:05", ["trip=Paris 2014", "favorite"], "Pigeons with a view"),
    ("Metro sign in Paris (Unsplash).jpg", "abbesses", "2014-05-17 09:30", ["trip=Paris 2014", "rating=3"], ""),
    ("A teal door in Paris (Unsplash).jpg", "marais", "2014-05-17 11:05", ["trip=Paris 2014", "rating=3"], ""),
    ("Ferris Wheel in Paris, France - by tranmautritam (Unsplash).jpg", "tuileries", "2014-05-17 16:20", ["trip=Paris 2014"], ""),
    ("Meduser in Paris aquarium (Unsplash).jpg", "paris-aquarium", "2014-05-18 11:45", ["trip=Paris 2014", "tag=Animals"], "Jellyfish at the aquarium"),
    ("Montmartre streets at dusk (Unsplash).jpg", "montmartre", "2014-05-18 20:55", ["trip=Paris 2014", "tag=Night", "people=incidental"], ""),
    ("Notre Dame View (Unsplash).jpg", "notre-dame", "2014-05-19 10:10", ["trip=Paris 2014", "tag=Architecture"], ""),
    # New York, October 2015, and a day in Washington
    ("Sunset in New York City (Unsplash).jpg", "top-of-the-rock", "2015-10-08 18:32", ["trip=New York 2015", "favorite", "rating=4"], "Sunset from Top of the Rock"),
    ("New York lights (Unsplash).jpg", "top-of-the-rock", "2015-10-08 19:10", ["trip=New York 2015", "tag=Night"], ""),
    ("The best triangle-shaped building in New York (Unsplash).jpg", "flatiron", "2015-10-09 10:20", ["trip=New York 2015", "tag=Architecture"], "The Flatiron"),
    ("Top of the Chrysler Building in New York City (Unsplash).jpg", "chrysler", "2015-10-09 13:05", ["trip=New York 2015", "tag=Architecture"], ""),
    ("Food Sign (Unsplash).jpg", "soho", "2015-10-09 13:40", ["archive", "tag=Travel/USA"], ""),
    ("New York in black and white (Unsplash).jpg", "dumbo", "2015-10-09 21:40", ["trip=New York 2015", "tag=Night"], ""),
    ("Fall in New York City (Unsplash).jpg", "soho", "2015-10-10 11:15", ["trip=New York 2015", "rating=1"], ""),
    ("Fast Food for Lunch (Unsplash).jpg", "soho", "2015-10-10 13:10", ["trip=New York 2015", "tag=Food"], ""),
    ("New York skyline with light trails (Unsplash).jpg", "dumbo", "2015-10-10 19:45", ["trip=New York 2015", "tag=Night"], ""),
    ("Gargoyle windows in new york (Unsplash).jpg", "chrysler", "2015-10-11 09:50", ["trip=New York 2015"], ""),
    ("Rembrandt van Rijn - Self-Portrait - Google Art Project.jpg", "national-gallery", "2015-10-12 14:00",
     ["album=Old Portraits", "tag=Portraits/Paintings", "artwork", "person=Rembrandt van Rijn"], "Rembrandt's self-portrait of 1659, National Gallery of Art"),
    # Lisbon, June 2016
    ("Tram in Lisbon (Unsplash).jpg", "bica", "2016-06-10 16:05", ["trip=Lisbon 2016", "favorite", "rating=4", "people=incidental"], "Elevador da Bica"),
    ("Lisbon, Portugal (Unsplash dRNT zPMZ6k).jpg", "baixa", "2016-06-10 18:20", ["trip=Lisbon 2016"], ""),
    ("Old city (Unsplash).jpg", "alfama", "2016-06-11 10:40", ["trip=Lisbon 2016", "tag=Architecture"], ""),
    ("Lisbon, Portugal (Unsplash hq8s4zjhj3I).jpg", "principe-real", "2016-06-11 12:30", ["trip=Lisbon 2016", "tag=Architecture"], ""),
    ("Lisbon suspension bridge sunset. (Unsplash).jpg", "belem", "2016-06-11 21:15", ["trip=Lisbon 2016"], ""),
    ("Lisbon beach featuring boat (Unsplash).jpg", "caparica", "2016-06-12 14:20", ["trip=Lisbon 2016"], "Costa da Caparica"),
    ("Lisbon, Portugal (Unsplash YOYRGRytq7s).jpg", "alfama", "2016-06-13 11:00", ["trip=Lisbon 2016"], ""),
    ("Lisbon lines (Unsplash).jpg", "baixa", "2016-06-13 12:00", ["trash", "tag=Travel/Portugal"], ""),
    # The American West, August 2017 (videos)
    ("Grand Canyon National Park- Timelapse Video - Summer Clouds (7775362134).webm", "grand-canyon", "2017-08-14 11:16",
     ["video", "tag=Travel/USA"], "Clouds over the South Rim"),
    ("Sunny waves at Cattle Point (40789227201).webm", "cattle-point", "2017-08-20 08:40", ["video", "tag=Travel/USA"], ""),
    # Iceland, September 2018
    ("Iceland trip (Unsplash).jpg", "thingvellir", "2018-09-14 15:30", ["trip=Iceland Road Trip"], "Day one, and a rainbow"),
    ("Waterfalls in Iceland (Unsplash).jpg", "skogafoss", "2018-09-15 11:20", ["trip=Iceland Road Trip", "favorite", "rating=5", "tag=Nature/Waterfalls"], "Skógafoss"),
    ("The Dyrhólaey lighthouse Iceland (Unsplash).jpg", "dyrholaey", "2018-09-15 17:45", ["trip=Iceland Road Trip"], ""),
    ("Iceland icebergs in water (Unsplash).jpg", "jokulsarlon", "2018-09-16 18:10", ["trip=Iceland Road Trip"], ""),
    ("Iceland shoreline sunset. (Unsplash).jpg", "jokulsarlon", "2018-09-16 19:40", ["trip=Iceland Road Trip"], "Diamond Beach at sunset"),
    ("Northern Lights above Iceland (Unsplash).jpg", "myvatn", "2018-09-18 23:05:12",
     ["trip=Iceland Road Trip", "favorite", "rating=5", "stack=aurora:primary", "tag=Nature/Northern Lights", "tag=Night"], "Northern lights by Mývatn"),
    ("Iceland lake Northern Lights (Unsplash).jpg", "myvatn", "2018-09-18 23:09:40",
     ["trip=Iceland Road Trip", "stack=aurora", "tag=Nature/Northern Lights", "tag=Night"], ""),
    ("Hvitserkur, Iceland (Unsplash).jpg", "hvitserkur", "2018-09-19 10:30", ["trip=Iceland Road Trip", "rating=4"], "Hvítserkur"),
    ("Grazing horses in Iceland (Unsplash).jpg", "snaefellsnes", "2018-09-20 11:40", ["trip=Iceland Road Trip", "tag=Animals"], ""),
    ("White horse in Iceland (Unsplash).jpg", "snaefellsnes", "2018-09-20 12:15", ["trip=Iceland Road Trip", "tag=Animals"], ""),
    ("Wild Iceland (Unsplash).jpg", "kirkjufell", "2018-09-20 16:50", ["trip=Iceland Road Trip", "tag=Nature/Waterfalls"], "Kirkjufell"),
    # Lofoten and Oslo, March 2019
    ("Lofoten, Norway (Unsplash).jpg", "leknes", "2019-03-02 22:40", ["trip=Norway", "favorite", "rating=5", "tag=Nature/Northern Lights", "tag=Night"], ""),
    ("Reine, Norway (Unsplash).jpg", "reine", "2019-03-03 06:15", ["trip=Norway", "favorite", "rating=5"], "Reine before sunrise"),
    ("Hovedøya, Norway (Unsplash).jpg", "hovedoya", "2019-03-06 08:30", ["trip=Norway", "tag=Animals"], "A fox on Hovedøya"),
    # Japan, April 2019
    ("Kyoto Station, Kyoto, Japan (Unsplash).jpg", "kyoto-station", "2019-04-04 17:20", ["trip=Japan 2019", "rating=2"], ""),
    ("Kinkaku in Kyoto.jpg", "kinkakuji", "2019-04-05 09:40", ["trip=Japan 2019", "favorite", "rating=5", "tag=Architecture"], "Kinkaku-ji"),
    ("20181110 Fushimi Inari Torii 12.jpg", "fushimi-inari", "2019-04-06 08:10", ["trip=Japan 2019", "rating=3"], ""),
    ("20181110 Fushimi Inari shrine 4.jpg", "fushimi-inari", "2019-04-06 08:32:21", ["trip=Japan 2019", "stack=fox:primary"], "Fox guardians at Fushimi Inari"),
    ("20181110 Fushimi Inari shrine 3.jpg", "fushimi-inari", "2019-04-06 08:32:14", ["trip=Japan 2019", "stack=fox"], ""),
    ("Orange hallway leading to Kyoto Prefecture (Unsplash).jpg", "fushimi-inari", "2019-04-06 08:50", ["trip=Japan 2019"], "Ten thousand torii"),
    ("Concrete wall in Kyoto (Unsplash).jpg", "fushimi-inari", "2019-04-06 13:10", ["trash", "tag=Travel/Japan"], ""),
    ("Arashiyama Bamboo Forest, Kyoto, Japan (Unsplash).jpg", "arashiyama", "2019-04-07 07:30", ["trip=Japan 2019", "rating=4"], ""),
    ("Arashiyama, Kyoto, Japan (Unsplash).jpg", "arashiyama", "2019-04-07 09:15", ["trip=Japan 2019", "tag=Architecture"], ""),
    ("Kyoto, Japan (Unsplash kEgfUDQP-Os).jpg", "philosophers-path", "2019-04-07 15:10", ["trip=Japan 2019", "tag=Nature/Cherry Blossom"], ""),
    ("Watagataki Falls (Video).webm", "watagataki", "2019-04-08 13:00", ["trip=Japan 2019", "video", "tag=Nature/Waterfalls", "people=incidental"], "Watagataki Falls"),
    ("Sunset over Tokyo (Unsplash).jpg", "roppongi", "2019-04-09 17:55", ["trip=Japan 2019"], ""),
    ("Shiba-koen, aerial view on Tokyo Tower at dusk (Unsplash).jpg", "tokyo-tower", "2019-04-09 18:40", ["trip=Japan 2019", "tag=Night"], ""),
    ("Tokyo, Japan (Unsplash mEaYSkucTys).jpg", "ueno", "2019-04-10 11:00", ["trip=Japan 2019", "tag=Nature/Cherry Blossom"], ""),
    ("Kanda Tokyo Metro Subway station (Unsplash).jpg", "kanda", "2019-04-10 12:20", ["archive", "tag=Travel/Japan"], ""),
    ("Local restaurant in Tokyo (Unsplash).jpg", "asakusa", "2019-04-10 19:30", ["trip=Japan 2019", "people=incidental"], ""),
    ("Eating Asian Noodles (Unsplash).jpg", "asakusa", "2019-04-10 20:05", ["trip=Japan 2019", "tag=Food"], "Udon in Asakusa"),
    ("Tokyo, Japan (Unsplash yiptq3TFiX8).jpg", "meiji-jingu", "2019-04-11 10:20", ["trip=Japan 2019"], "Sake barrels at Meiji Jingu"),
    ("Tokyo crosswalk (Unsplash).jpg", "shibuya", "2019-04-11 16:00", ["trip=Japan 2019", "people=incidental"], ""),
    # Fjords, July 2020
    ("Cabin Window (Unsplash).jpg", "flam", "2020-07-17 09:00", ["album=Norway", "tag=Travel/Norway"], ""),
    ("Norwegian fiords on a sunny day (Unsplash).jpg", "naeroyfjord", "2020-07-18 13:20", ["album=Norway", "tag=Travel/Norway"], "Nærøyfjord"),
    ("Bremanger, Norway (Unsplash).jpg", "naeroyfjord", "2020-07-18 15:00", ["album=Norway", "tag=Travel/Norway"], ""),
    # Rome and Venice, May 2022
    ("Rome colesium (Unsplash).jpg", "colosseum", "2022-05-20 16:45", ["trip=Italy 2022", "tag=Architecture"], ""),
    ("The majestic Colosseum in Rome. (Unsplash).jpg", "colle-oppio", "2022-05-20 17:30", ["trip=Italy 2022", "rating=4"], ""),
    ("Rome, Roma, Italy (Unsplash).jpg", "pantheon", "2022-05-21 11:02:10", ["trip=Italy 2022", "favorite", "stack=pantheon:primary", "tag=Architecture"], "The Pantheon's oculus"),
    ("Dennis Mayk 2015 (Unsplash).jpg", "pantheon", "2022-05-21 11:02:40", ["trip=Italy 2022", "stack=pantheon"], ""),
    ("Rome Altare della Patria (Unsplash).jpg", "vittoriano", "2022-05-21 17:50", ["trip=Italy 2022"], ""),
    ("Red Vespa (Unsplash).jpg", "trastevere", "2022-05-22 10:15", ["trip=Italy 2022", "rating=3"], ""),
    ("Orange vintage beetle (Unsplash).jpg", "trastevere", "2022-05-22 10:40", ["trip=Italy 2022"], ""),
    ("Rome, Italy (Unsplash).jpg", "trastevere", "2022-05-22 11:20", ["trip=Italy 2022", "tag=Architecture"], ""),
    ("Food cutlery and beer (Unsplash).jpg", "trastevere", "2022-05-22 13:30", ["trip=Italy 2022", "tag=Food"], "Lunch in Trastevere"),
    ("Metropolitan City of Rome, Italy (Unsplash NKsDKNLxVRI).jpg", "monti", "2022-05-23 09:30", ["trip=Italy 2022"], ""),
    ("Pub food for the Win (Unsplash).jpg", "monti", "2022-05-23 20:15", ["trip=Italy 2022", "tag=Food"], ""),
    ("Venice, Italy (Unsplash).jpg", "cannaregio", "2022-05-25 21:30", ["trip=Italy 2022", "tag=Night"], ""),
    ("Venice, Italy (Unsplash YXZnE1jFdFo).jpg", "san-marco", "2022-05-26 08:20", ["trip=Italy 2022", "favorite", "rating=5"], "Gondolas, San Giorgio Maggiore behind"),
    ("Lost in Venice (Unsplash).jpg", "rialto", "2022-05-26 12:10", ["trip=Italy 2022"], "The Grand Canal"),
    ("The city awakes (Unsplash).jpg", "accademia", "2022-05-26 20:40", ["trip=Italy 2022"], ""),
    ("Venice, Italy (Unsplash VJIRcLOlEQA).jpg", "cannaregio", "2022-05-27 10:05", ["trip=Italy 2022"], ""),
    ("Venice (Unsplash).jpg", "rialto", "2022-05-27 11:30", ["trip=Italy 2022", "tag=Architecture"], ""),
    ("Bricks (Unsplash).jpg", "cannaregio", "2022-05-27 11:35", ["trash", "tag=Travel/Italy"], ""),
    # Copenhagen, at home, over the years
    ("The Red Building (Unsplash).jpg", "christianshavn", "2017-08-12 14:20", ["album=Copenhagen", "tag=Architecture"], ""),
    ("Beautiful building in Copenhagen (Unsplash).jpg", "nordhavn", "2018-04-21 12:30", ["album=Copenhagen", "tag=Architecture"], ""),
    ("Red kayaks on a wall (Unsplash).jpg", "islands-brygge", "2019-06-15 10:45", ["album=Copenhagen"], ""),
    ("Copenhagen, Denmark (Unsplash P262k20wgLM).jpg", "nordhavn", "2020-01-18 19:20", ["album=Copenhagen", "tag=Night"], ""),
    ("Copenhagen, Denmark (Unsplash lJByObbNxP4).jpg", "islands-brygge", "2021-02-06 18:30", ["album=Copenhagen", "tag=Night"], ""),
    ("Copenhagen, Denmark (Unsplash -A3Kb429mgY).jpg", "islands-brygge", "2021-02-06 18:45", ["album=Copenhagen", "tag=Night"], ""),
    ("Wedding In Copenhagen at the Botanical Gardens (Unsplash).jpg", "botanical-garden", "2023-05-14 13:10", ["album=Copenhagen"], "The Palm House"),
    ("Biscuits, cakes, nuts and chestnuts (Unsplash).jpg", "frederiksberg", "2023-12-17 15:30", ["tag=Food"], ""),
    ("Frans I Hals, René Descartes 1596-1650, DEP7, Statens Museum for Kunst.jpg", "smk", "2024-02-11 14:05",
     ["album=Old Portraits", "tag=Portraits/Paintings", "artwork", "person=René Descartes"], "Frans Hals's Descartes at SMK"),
    ("Healthy breakfast (Unsplash).jpg", "frederiksberg", "2024-03-10 09:15", ["tag=Food"], ""),
    ("Copenhagen, Denmark (Unsplash hP yCg3MgsI).jpg", "nyhavn", "2024-06-22 11:45", ["album=Copenhagen"], ""),
    ("Fresh Salad (Unsplash).jpg", "frederiksberg", "2025-07-05 12:40", ["tag=Food"], ""),
    ("Fruit Platter (Unsplash).jpg", "frederiksberg", "2025-07-06 10:05", ["tag=Food"], ""),
    ("Torvehallerne, Copenhagen, Denmark (Unsplash Eo9ZNtEUH Y).jpg", "torvehallerne", "2025-09-12 18:10", ["album=Copenhagen", "tag=Food"], ""),
    ("Vilhelm Hammershøi Double Portrait. The Artist and His Wife.jpg", None, None,
     ["album=Old Portraits", "tag=Portraits/Paintings", "artwork", "person=Ida Hammershøi"], "Hammershøi's double portrait of himself and Ida"),
    ("Draped (Unsplash).jpg", "indre-by", "2025-11-02 16:20", ["locked", "people=incidental"], ""),
    ("Beautiful technology (Unsplash).jpg", "indre-by", "2026-01-09 11:05", ["locked"], ""),
    # On this day: the seed day's month and day, 1, 3 and 6 years before
    ("Nyhavn, Denmark (Unsplash).jpg", "nyhavn", "2000-01-01 18:40", ["album=Copenhagen", "memory=6", "favorite", "tag=Night"], "Nyhavn on a cold evening"),
    ("Nyhavn, Copenaghen, Danemark (Unsplash).jpg", "nyhavn", "2000-01-01 13:15", ["album=Copenhagen", "memory=6"], ""),
    ("Bike on street Copenhagen (Unsplash).jpg", "christianshavn", "2000-01-01 10:20", ["album=Copenhagen", "memory=3"], ""),
    ("On your bike! (Unsplash).jpg", "indre-by", "2000-01-01 11:05", ["album=Copenhagen", "memory=3"], ""),
    ("Copenhagen, Denmark (Unsplash).jpg", "indre-by", "2000-01-01 08:30", ["memory=1", "tag=Food"], "First coffee of the day"),
    # Copenhagen Zoo, August 2023
    ("Tiger in a zoo (Unsplash).jpg", "copenhagen-zoo", "2023-08-12 11:05", ["album=Copenhagen Zoo", "favorite", "rating=4", "tag=Animals/Zoo"], ""),
    ("Penguin in artic (Unsplash).jpg", "copenhagen-zoo", "2023-08-12 11:40", ["album=Copenhagen Zoo", "tag=Animals/Zoo"], ""),
    ("Bird On A Perch (Unsplash).jpg", "copenhagen-zoo", "2023-08-12 12:20", ["album=Copenhagen Zoo", "tag=Animals/Zoo"], ""),
    ("Copenhagen Zoo, Frederiksberg, Denmark (Unsplash u3xyNcPIntQ).jpg", "copenhagen-zoo", "2023-08-12 13:10", ["album=Copenhagen Zoo", "tag=Animals/Zoo"], ""),
    ("Lioness on logs (Unsplash).jpg", "copenhagen-zoo", "2023-08-12 13:25", ["album=Copenhagen Zoo", "tag=Animals/Zoo"], ""),
    ("Copenhagen Zoo, Frederiksberg, Denmark (Unsplash pn TY-8 Pbk).jpg", "copenhagen-zoo", "2023-08-12 14:00", ["album=Copenhagen Zoo", "tag=Animals/Zoo"], ""),
    # Dogs of friends, and further afield
    ("Happy dog at Anjuna Beach (Unsplash).jpg", "amager-strand", "2024-08-03 10:20", ["tag=Animals/Dogs"], ""),
    ("Dog on a beach (Unsplash).jpg", "amager-strand", "2024-08-03 10:35", ["tag=Animals/Dogs"], ""),
    ("Kamakura underwater fireworks 2.webm", "kamakura", "2024-07-17 20:10", ["video", "tag=Travel/Japan", "tag=Night", "people=incidental"], "Underwater fireworks in Kamakura"),
    ("Dog on a log (Unsplash).jpg", "dyrehaven", "2025-04-19 15:00", ["tag=Animals/Dogs"], ""),
    # Old photographs (scans), dated as the photographs are; the sitters died long ago
    ("Frederick Douglass (1840s).jpg", None, "1847-06-15 12:00", ["scan", "album=Old Portraits", "tag=Portraits/Historic", "person=Frederick Douglass"], "Frederick Douglass, 1840s"),
    ("Frederick Douglass MET DT1144.jpg", None, "1855-06-15 12:00", ["scan", "album=Old Portraits", "tag=Portraits/Historic", "person=Frederick Douglass"], ""),
    ("Florence Nightingale by Goodman, 1858-crop.jpg", None, "1858-06-15 12:00", ["scan", "album=Old Portraits", "tag=Portraits/Historic", "person=Florence Nightingale"], ""),
    ("Florence Nightingale (H Hering NPG x82368).jpg", None, "1860-06-15 12:00", ["scan", "album=Old Portraits", "tag=Portraits/Historic", "person=Florence Nightingale"], "Florence Nightingale by Henry Hering"),
    ("Hans Christian Andersen 2.jpg", None, "1860-06-15 12:00", ["scan", "album=Old Portraits", "tag=Portraits/Historic", "person=Hans Christian Andersen"], ""),
    ("Abraham Lincoln MET DT1652.jpg", None, "1863-08-09 10:00", ["scan", "album=Old Portraits", "tag=Portraits/Historic", "person=Abraham Lincoln"], ""),
    ("Abraham Lincoln O-74 by A Gardner, 1863.jpg", None, "1863-08-09 10:20", ["scan", "album=Old Portraits", "tag=Portraits/Historic", "person=Abraham Lincoln"], ""),
    ("Abraham Lincoln head on shoulders photo portrait.jpg", None, "1863-11-08 11:00", ["scan", "album=Old Portraits", "tag=Portraits/Historic", "person=Abraham Lincoln"], "Abraham Lincoln by Alexander Gardner"),
    ("Hans Christian Andersen - Det Kongelige Bibliotek (501669).jpg", None, "1865-06-15 12:00", ["scan", "album=Old Portraits", "tag=Portraits/Historic", "person=Hans Christian Andersen"], ""),
    ("Charles Darwin 01.jpg", None, "1869-06-15 12:00", ["scan", "album=Old Portraits", "tag=Portraits/Historic", "person=Charles Darwin"], ""),
    ("Hans Christian Andersen by Thora Hallager 1869.jpg", None, "1869-10-10 12:00", ["scan", "album=Old Portraits", "tag=Portraits/Historic", "person=Hans Christian Andersen", "favorite"], "H.C. Andersen by Thora Hallager"),
    ("Mark Twain from American Portraits.jpg", None, "1872-06-15 12:00", ["scan", "album=Old Portraits", "tag=Portraits/Historic", "person=Mark Twain"], ""),
    ("Frederick Douglass (circa 1879).jpg", None, "1879-06-15 12:00", ["scan", "album=Old Portraits", "tag=Portraits/Historic", "person=Frederick Douglass"], ""),
    ("Charles Darwin photograph by Herbert Rose Barraud, 1881 2.jpg", None, "1881-06-15 12:00", ["scan", "album=Old Portraits", "tag=Portraits/Historic", "person=Charles Darwin"], ""),
    ("Charles Darwin in 1881.jpg", None, "1881-06-20 12:00", ["scan", "album=Old Portraits", "tag=Portraits/Historic", "person=Charles Darwin"], "Charles Darwin, 1881"),
    ("Mark Twain by AF Bradley.jpg", None, "1907-06-15 12:00", ["scan", "album=Old Portraits", "tag=Portraits/Historic", "person=Mark Twain"], "Mark Twain by A. F. Bradley"),
    ("Mark Twain LCCN2004672770.jpg", None, "1907-06-20 12:00", ["scan", "album=Old Portraits", "tag=Portraits/Historic", "person=Mark Twain"], ""),
    # The partner's library (shared with the admin as a partner), at home in Frederiksberg
    ("A male cat grooms a female kitten 2021-08-25 August 25.webm", "frederiksberg", "2021-08-25 18:30",
     ["partner", "video", "album=Our Cats", "tag=Animals/Cats"], "Grooming the kitten"),
    ("Cat portrait (Unsplash).jpg", "frederiksberg", "2021-09-04 10:15", ["partner", "album=Our Cats", "tag=Animals/Cats", "favorite"], ""),
    ("Cat napping by the window (Unsplash).jpg", "frederiksberg", "2021-11-21 14:30", ["partner", "album=Our Cats", "tag=Animals/Cats"], ""),
    ("Breakfast table with pancakes (Unsplash).jpg", "frederiksberg", "2022-02-13 10:00", ["partner", "tag=Food"], "Sunday pancakes"),
    ("Ginger long-haired cat (Unsplash).jpg", "frederiksberg", "2022-08-07 17:45", ["partner", "album=Our Cats", "tag=Animals/Cats"], ""),
    ("Fruit Platter 1 (Unsplash).jpg", "frederiksberg", "2023-06-24 15:00", ["partner", "tag=Food"], ""),
    ("Cat face in sunlight (Unsplash).jpg", "frederiksberg", "2023-10-01 16:50", ["partner", "album=Our Cats", "tag=Animals/Cats", "favorite"], ""),
    ("Gaspard the too big cat (Unsplash).jpg", "frederiksberg", "2024-01-14 12:10", ["partner", "album=Our Cats", "tag=Animals/Cats"], ""),
    ("Southern Wallabi Beach surf conditions and recreational surfing, Saltwater National Park, New South Wales.webm",
     "wallabi-beach", "2024-01-26 07:30", ["partner", "video", "tag=Travel/Australia", "people=incidental"], "Morning surf at Wallabi Beach"),
    ("Cat in a bay (Unsplash).jpg", "nordhavn", "2024-09-08 11:20", ["partner", "album=Our Cats", "tag=Animals/Cats"], ""),
    ("Pieces of Watermelon (Unsplash).jpg", "frederiksberg", "2025-07-19 15:30", ["partner", "tag=Food"], ""),
    ("Cat resting on a couch (Unsplash).jpg", "frederiksberg", "2025-12-28 13:00", ["partner", "album=Our Cats", "tag=Animals/Cats"], ""),
    ("Wide-eyed tiger cat (Unsplash).jpg", "frederiksberg", "2026-02-22 09:40", ["partner", "album=Our Cats", "tag=Animals/Cats"], ""),
]

# trip album -> country tag (Travel/<country>)
TRIPS = {"Paris 2014": "France", "New York 2015": "USA", "Lisbon 2016": "Portugal", "Iceland Road Trip": "Iceland",
         "Norway": "Norway", "Japan 2019": "Japan", "Italy 2022": "Italy"}


def api(params):
    params.update(format="json", formatversion="2")
    request = urllib.request.Request(API + "?" + urllib.parse.urlencode(params), headers={"User-Agent": UA})
    for attempt in range(6):
        try:
            return json.load(urllib.request.urlopen(request, timeout=60))
        except urllib.error.HTTPError as error:
            if error.code != 429:
                raise
            time.sleep(int(error.headers.get("Retry-After") or 0) or 10 * (attempt + 1))
    sys.exit("Commons API keeps answering 429")


def fetch(url, destination):
    request = urllib.request.Request(url, headers={"User-Agent": UA})
    for attempt in range(5):
        try:
            data = urllib.request.urlopen(request, timeout=300).read()
            with open(destination, "wb") as handle:
                handle.write(data)
            return data
        except urllib.error.HTTPError as error:
            if error.code != 429:
                raise
            wait = int(error.headers.get("Retry-After") or 0) or 30
            print(f"429 on {url}, waiting {wait}s", file=sys.stderr)
            time.sleep(wait)
    sys.exit(f"{url} keeps answering 429")


def text(value):
    return re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", "", value or ""))).strip()


def query(titles, **extra):
    """imageinfo for titles, keyed by the title as written here."""
    found = {}
    for start in range(0, len(titles), 25):
        result = api({"action": "query", "titles": "|".join(titles[start:start + 25]), "prop": "imageinfo", **extra})
        normalized = {item["to"]: item["from"] for item in result["query"].get("normalized", [])}
        for page in result["query"]["pages"]:
            if "imageinfo" not in page:
                sys.exit(f"missing on Commons: {page['title']}")
            found[normalized.get(page["title"], page["title"])] = page
        time.sleep(2)
    return found


def main():
    titles = ["File:" + entry[0] for entry in SELECTION]
    if len(set(titles)) != len(titles):
        sys.exit("a title is selected twice")
    info = query(titles, iiprop="url|size|sha1|mime|extmetadata|metadata",
                 iiextmetadatafilter="LicenseShortName|LicenseUrl|AttributionRequired|Artist|Credit|Restrictions")
    thumbs = {width: query(titles, iiprop="url", iiurlwidth=str(width)) for width in STEPS}
    os.makedirs(os.path.join(HERE, "cache"), exist_ok=True)
    entries, counters = [], {"admin": 1001, "partner": 0, "scan": 1}
    # Upload names follow the order things were taken, as a camera's do (a memory counts n years before 2026).
    def taken(index):
        when, roles = SELECTION[index][2], SELECTION[index][3]
        years = next((int(role[7:]) for role in roles if role.startswith("memory=")), None)
        return f"{2026 - years}-11" if years else (when or "2026-03-27")
    names = {}
    for index in sorted(range(len(SELECTION)), key=lambda index: (taken(index), index)):
        title, _, when, roles, _ = SELECTION[index]
        extension = ".MP4" if "video" in roles else ".JPG"
        if "scan" in roles:
            names[index] = f"SCAN_{counters['scan']:04d}.JPG"
            counters["scan"] += 1
        elif "partner" in roles:
            digits = re.sub(r"\D", "", when) + "00"
            names[index] = f"PXL_{digits[:8]}_{digits[8:14]}{extension.lower()}"
        else:
            names[index] = f"IMG_{counters['admin']}{extension}"
            counters["admin"] += 1
    for number, (title, place, when, roles, caption) in enumerate(SELECTION, 1):
        page = info["File:" + title]
        image_info = page["imageinfo"][0]
        meta = image_info["extmetadata"]
        licence = meta.get("LicenseShortName", {}).get("value", "")
        if meta.get("AttributionRequired", {}).get("value") != "false" or not re.search(r"CC0|[Pp]ublic domain", licence):
            sys.exit(f"not CC0 or public domain: {title} ({licence})")
        metadata = {item["name"]: item["value"] for item in (image_info.get("metadata") or []) if isinstance(item, dict)}
        is_video = image_info["mime"].startswith("video/")
        # Originals come from upload.wikimedia.org, which answers more than a few with 429 and Retry-After; the
        # renditions come from thumb.wikimedia.org. So only videos are originals.
        if is_video:
            url, variant = image_info["url"].split("?")[0], "original"
        else:
            width = max(step for step in STEPS if step < image_info["width"])
            url = thumbs[width]["File:" + title]["imageinfo"][0]["thumburl"].split("?")[0]
            variant = f"thumbnail-{width}px"
        extension = os.path.splitext(url)[1].lower() or ".jpg"
        cache_name = f"s{number:03d}{extension}"
        cache_path = os.path.join(HERE, "cache", cache_name)
        if variant == "original":
            # upload.wikimedia.org answers this script with 429 where curl gets the file, so Commons' own sha1 pins
            # an original and fixtures.sh downloads it.
            data = None
        else:
            data = open(cache_path, "rb").read() if os.path.exists(cache_path) else fetch(url, cache_path)
            time.sleep(1)
        # The story's time and place.
        exif, gps_source = {}, "none"
        if place:
            latitude, longitude, zone = PLACES[place]
            # A little spread, so photos at one sight do not sit on one point.
            jitter = int(hashlib.sha1(title.encode()).hexdigest()[:8], 16)
            latitude += ((jitter % 1000) / 1000 - 0.5) * 0.002
            longitude += (((jitter // 1000) % 1000) / 1000 - 0.5) * 0.002
            gps_source = "place"
        elif metadata.get("GPSLatitude") is not None:
            latitude, longitude, zone = metadata["GPSLatitude"], metadata["GPSLongitude"], "Europe/Copenhagen"
            gps_source = "original"
        else:
            latitude = longitude = None
            zone = "Europe/Copenhagen"
        if when is None:   # the original's own date (the Hammershøi photo, taken in a museum)
            when = metadata["DateTimeOriginal"].replace(":", "-", 2)
        local = datetime.datetime.fromisoformat(when if len(when) > 16 else when + ":00")
        offset = local.replace(tzinfo=ZoneInfo(zone)).strftime("%z")
        offset = f"{offset[:3]}:{offset[3:]}"
        exif["DateTimeOriginal"] = local.strftime("%Y:%m:%d %H:%M:%S")
        if "scan" not in roles:
            exif["OffsetTimeOriginal"] = offset
        for key in ("Make", "Model"):
            if key in metadata and not is_video and "scan" not in roles:
                exif[key] = str(metadata[key]).strip()
        if latitude is not None:
            exif.update(GPSLatitude=round(abs(latitude), 6), GPSLatitudeRef="N" if latitude >= 0 else "S",
                        GPSLongitude=round(abs(longitude), 6), GPSLongitudeRef="E" if longitude >= 0 else "W")
        people = ("sitter of a painting" if "artwork" in roles else "sitter of an old photograph") \
            if any(role.startswith("person=") for role in roles) else \
            ("small, turned away or on a poster" if "people=incidental" in roles else "none")
        entries.append({
            "id": f"s{number:03d}",
            "owner": "partner" if "partner" in roles else "admin",
            "roles": roles,
            "uploadName": names[number - 1],
            "description": caption,
            "title": page["title"],
            "pageUrl": image_info["descriptionurl"],
            "url": url,
            "variant": variant,
            "originalUrl": image_info["url"].split("?")[0],
            "originalSha1": image_info["sha1"],
            "author": text(meta.get("Artist", {}).get("value")) or "unknown",
            "credit": text(meta.get("Credit", {}).get("value"))[:200],
            "license": licence,
            "licenseUrl": meta.get("LicenseUrl", {}).get("value", ""),
            "restrictions": meta.get("Restrictions", {}).get("value", ""),
            "people": people,
            "marketing": "check" if "people=incidental" in roles else "yes",
            "optional": False,
            "sha1": hashlib.sha1(data).hexdigest() if data else image_info["sha1"],
            "sha256": hashlib.sha256(data).hexdigest() if data else None,
            "bytes": len(data) if data else image_info["size"],
            "mime": image_info["mime"],
            "width": image_info["width"],
            "height": image_info["height"],
            # Local time of the story; for memory=<n> the date is the seed day's, n years before.
            "dateTaken": exif["DateTimeOriginal"],
            "timeZoneOffset": offset,
            "timeZone": zone,
            "gps": gps_source,
            "exif": exif,
            "cacheName": cache_name,
        })
        print(f"{number:3d} {cache_name} {variant} {(len(data) if data else image_info['size']) // 1000} kB {title[:60]}", file=sys.stderr)
    with open(os.path.join(HERE, "manifest.json"), "w") as handle:
        json.dump({"source": "Wikimedia Commons", "generatedBy": "fixtures/showcase/build-manifest.py",
                   "trips": TRIPS, "files": entries}, handle, ensure_ascii=False, indent=1)
        handle.write("\n")
    write_attribution(entries)
    print(f"{len(entries)} entries, {sum(entry['bytes'] for entry in entries) / 1e6:.1f} MB")


def write_attribution(entries):
    check = [entry["id"] for entry in entries if entry["marketing"] == "check"]
    sitters = sorted({role[7:] for entry in entries for role in entry["roles"] if role.startswith("person=")})
    with open(os.path.join(HERE, "ATTRIBUTION.md"), "w") as handle:
        handle.write(
            "# Showcase attribution\n\nGenerated from `manifest.json` by `build-manifest.py`; do not edit.\n"
            "The showcase server's library (`showcase.sh`). The files are downloaded at seed time from Wikimedia Commons and\n"
            "are not in this repository. Every one is CC0 or public domain, so the website and the App Store may use them\n"
            "without credits; this file credits them all the same. Photos are Commons' standard-size renditions (a scaled\n"
            "rendition of the work), with the original's camera make and model kept and the story's date and place written\n"
            "in; videos are the originals, transcoded to MP4 at seed time.\n\n"
            "## For the website and the App Store\n\n"
            f"- **Yes:** every file not listed below. No photo shows a recognisable living person.\n"
            f"- **Check first ({len(check)}):** {', '.join(check)}. People are in them, small, turned away or on a poster; look before use.\n"
            f"- **The named people** ({', '.join(sitters)}) are sitters of 19th-century photographs and of old paintings,\n"
            "  all long dead, the works in the public domain. They are what Verso's People page shows. Prefer the Danish ones\n"
            "  (Hans Christian Andersen, Ida Hammershøi) and the paintings for screenshots of faces: the famous sitters could\n"
            "  read as an endorsement.\n"
            "- Brands are visible in a few (a Vespa, a Volkswagen Beetle, shop signs in Tokyo and New York).\n\n"
            "| # | Work | Author | Licence | Owner | People | Marketing | Use in the showcase |\n|---|---|---|---|---|---|---|---|\n")
        for entry in entries:
            licence = f"[{entry['license']}]({entry['licenseUrl']})" if entry["licenseUrl"] else entry["license"]
            handle.write(f"| {entry['id']} | [{entry['title'][5:]}]({entry['pageUrl']}) | {entry['author'].replace('|', '/')[:80]} | "
                         f"{licence} | {entry['owner']} | {entry['people']} | {entry['marketing']} | "
                         f"{', '.join(entry['roles'])} |\n")


main()
