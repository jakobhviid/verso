//! How the gallery arranges what it shows, worked out in the core for the Mac and the iPhone as for Linux's window
//! (ARCHITECTURE.md, "Verso on the Mac"): the Library's Years and Months (`verso_core::overview`), the map's clusters
//! (`verso_core::map`), the Duplicates page's order (`verso_core::duplicates`), which shared links show
//! (`verso_core::shared_links`), People's filter (`verso_core::people`), Places' groups and order
//! (`verso_core::places`) and the albums' view settings (`verso_core::albums`). The Swift side names a timeline's
//! months by their bucket (`2025-03-01`), as its grid does, and gets them back the same way; a choice kept in its
//! settings goes by its code, the same on Linux, and a list it sorts or filters comes back as the places of its items.

use std::cmp::Ordering;
use std::collections::HashMap;
use std::time::SystemTime;

use chrono::{DateTime, Utc};
use immich_api::map::MapMarker;
use immich_api::timeline::YearMonth;
use immich_api::{ServerVersion, SharedLink, SharedLinkKind};
use verso_core::duplicates::{self, Measure, SortBy};
use verso_core::shared_links::{self, Arrangement, Filter};
use verso_core::names::caseless;
use verso_core::{albums, map, overview, people, places};

use crate::gallery::GalleryVersion;

/// A month of the timeline, as the grid has it: its bucket and how many photos it holds.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct OverviewMonth {
    pub bucket: String,
    pub count: u32,
}

/// A year of the Library's Years.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct OverviewYear {
    /// The year, `2025`.
    pub id: String,
    /// Its months' buckets, in the grid's order.
    pub months: Vec<String>,
    /// The bucket of the month its card shows a photo from: its fullest (the first of them on a tie).
    pub key_month: String,
}

/// A photo of a month, as the mosaic picks from it.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct OverviewPhoto {
    pub id: String,
    /// When it was taken: the wall clock where it was taken, written as UTC, as the timeline's dates are.
    pub taken: Option<SystemTime>,
    pub is_video: bool,
}

/// A photo picked for a month's mosaic, and the day of the month it shows (none for a photo without a date).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct OverviewPick {
    pub id: String,
    pub day: Option<u32>,
}

/// The Library's years, from the timeline's months in the grid's order, each year where it first comes. Sections that
/// are not a month (a search's) are left out.
#[uniffi::export]
pub fn overview_years(months: Vec<OverviewMonth>) -> Vec<OverviewYear> {
    let mut buckets: HashMap<YearMonth, String> = HashMap::new();
    let mut counted: Vec<(YearMonth, u32)> = Vec::new();
    for month in months {
        let Some(parsed) = YearMonth::parse(&month.bucket) else { continue };
        buckets.entry(parsed).or_insert(month.bucket);
        counted.push((parsed, month.count));
    }
    let bucket = |month: &YearMonth| buckets.get(month).cloned().unwrap_or_else(|| month.bucket_key());
    overview::years(&counted)
        .into_iter()
        .map(|year| OverviewYear {
            id: format!("{:04}", year.year),
            months: year.months.iter().map(bucket).collect(),
            key_month: bucket(&year.key_month),
        })
        .collect()
}

/// A month's mosaic: one photo from each of up to `limit` days, spread over the month, in the grid's order; within a
/// day the photo in the middle, and a still before a video (`verso_core::overview::picks`).
#[uniffi::export]
pub fn overview_picks(photos: Vec<OverviewPhoto>, limit: u32) -> Vec<OverviewPick> {
    let photos: Vec<overview::Photo> = photos
        .into_iter()
        .map(|photo| overview::Photo {
            id: photo.id,
            taken: photo.taken.map(|taken| DateTime::<Utc>::from(taken).naive_utc()),
            is_video: photo.is_video,
        })
        .collect();
    overview::picks(&photos, limit as usize).into_iter().map(|pick| OverviewPick { id: pick.id, day: pick.day }).collect()
}

/// A photo on the map, as the clusters gather it.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct MapPhoto {
    pub id: String,
    pub latitude: f64,
    pub longitude: f64,
}

/// Photos close together on the map, shown as one pin.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct MapCluster {
    /// The first photo's id, by id order: it names the cluster and gives its picture.
    pub id: String,
    pub latitude: f64,
    pub longitude: f64,
    /// Every photo in it, by id.
    pub assets: Vec<String>,
    /// The box that holds its photos, a hair wider, as Immich's timeline takes it (`bbox`: west, south, east, north).
    pub bbox: String,
}

/// The clusters of the photos in a view centred on (`latitude`, `longitude`) and `latitude_span` by `longitude_span`
/// degrees, in cells whose edges stay put as the view moves, by id (`verso_core::map::clusters`). Photos whose place
/// is not on the map are left out, and a view that is not a number has none.
#[uniffi::export]
pub fn map_clusters(photos: Vec<MapPhoto>, latitude: f64, longitude: f64, latitude_span: f64, longitude_span: f64) -> Vec<MapCluster> {
    let markers: Vec<MapMarker> =
        photos.into_iter().map(|photo| MapMarker { id: photo.id, lat: photo.latitude, lon: photo.longitude, ..MapMarker::default() }).collect();
    map::clusters(&markers, latitude, longitude, latitude_span, longitude_span)
        .into_iter()
        .map(|cluster| {
            let bbox = cluster.bounds.bbox();
            MapCluster { id: cluster.id, latitude: cluster.latitude, longitude: cluster.longitude, assets: cluster.assets, bbox }
        })
        .collect()
}

/// A photo of a group of duplicates, as the page's order and its first choice read it.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct DuplicatesPhoto {
    pub id: String,
    /// The bytes of its original; none when Immich told none.
    pub size: Option<u64>,
}

/// A group of duplicates: its photos, in Immich's order, and those Immich suggests keeping.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct DuplicatesGroup {
    pub photos: Vec<DuplicatesPhoto>,
    pub suggested_keep: Vec<String>,
}

/// The places of the groups (given in the server's order) in the order chosen, by its code: `Default`, the server's;
/// `ItemCount`, most photos first; `TotalSize`, largest first. Ties keep the server's order, and a code it does not
/// know is the server's order (`verso_core::duplicates`).
#[uniffi::export]
pub fn duplicates_order(groups: Vec<DuplicatesGroup>, sort_by: String) -> Vec<u32> {
    let measured: Vec<Measure> = groups.iter().map(|group| Measure::of_sizes(group.photos.iter().map(|photo| photo.size))).collect();
    SortBy::from_code(&sort_by).unwrap_or_default().order(&measured).into_iter().map(|place| place as u32).collect()
}

/// The photos a group keeps at first: those Immich suggests that are in it, or else its first.
#[uniffi::export]
pub fn duplicates_kept_at_first(group: DuplicatesGroup) -> Vec<String> {
    let photos: Vec<&str> = group.photos.iter().map(|photo| photo.id.as_str()).collect();
    duplicates::kept_at_first(&photos, &group.suggested_keep)
}

/// A shared link, as the Shared Links page's filter reads it.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SharedLinkFacts {
    /// Immich's type for it: `ALBUM` or `INDIVIDUAL`.
    pub kind: String,
    /// When it stops working; none when it never does.
    pub expires_at: Option<SystemTime>,
}

/// The places of the links shown (given in the server's order) with a filter, by its code, Immich's tab names: `all`,
/// `album` or `individual` (a code it does not know shows all); without the expired ones when `hide_expired`
/// (`verso_core::shared_links`).
#[uniffi::export]
pub fn shared_links_shown(links: Vec<SharedLinkFacts>, filter: String, hide_expired: bool) -> Vec<u32> {
    let arrangement = Arrangement { filter: Filter::from_code(&filter).unwrap_or_default(), hide_expired };
    let now = Utc::now();
    links
        .into_iter()
        .enumerate()
        .filter(|(_, link)| arrangement.shows(&shared_link(link.kind.clone(), link.expires_at), now))
        .map(|(place, _)| place as u32)
        .collect()
}

/// Whether a link that works until `expires_at` is past it, so it no longer opens.
#[uniffi::export]
pub fn shared_link_expired(expires_at: Option<SystemTime>) -> bool {
    shared_links::is_expired(&shared_link(String::new(), expires_at), Utc::now())
}

/// A link with what the filter reads of it.
fn shared_link(kind: String, expires_at: Option<SystemTime>) -> SharedLink {
    SharedLink { kind: SharedLinkKind::from(kind), expires_at: expires_at.map(DateTime::<Utc>::from), ..SharedLink::default() }
}

/// The People page's view options: whom it shows, by the code the settings keep it by (`All`, `Favorites` or
/// `Hidden`, the same on Linux; a code it does not know shows all), and whether hidden people show beside the others.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PeopleOptions {
    pub show: String,
    pub include_hidden: bool,
}

/// What the People page's options mean, for asking Immich and for the page.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct PeopleFilter {
    /// Whether the options leave some people out.
    pub is_filtered: bool,
    /// Whether hidden people are asked for: when they show beside the others, or alone.
    pub with_hidden: bool,
    /// Whether the server is asked for favorites alone, which Immich v3.3 and later understand.
    pub favorites_only: bool,
    /// Whether the server is asked for hidden people alone, which Immich v3.3 and later understand.
    pub hidden_only: bool,
}

/// A person, as the People page's filter reads them.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PeoplePerson {
    /// None from a server that does not tell.
    pub is_favorite: Option<bool>,
    pub is_hidden: bool,
}

fn people_arrangement(options: &PeopleOptions) -> people::Arrangement {
    people::Arrangement { show: people::Show::from_code(&options.show).unwrap_or_default(), include_hidden: options.include_hidden }
}

/// What the People page's options mean with a server of this version, none when it is not known
/// (`verso_core::people`).
#[uniffi::export]
pub fn people_filter(options: PeopleOptions, server: Option<GalleryVersion>) -> PeopleFilter {
    let arrangement = people_arrangement(&options);
    let server = server.map(|version| ServerVersion { major: version.major, minor: version.minor, patch: version.patch });
    let asked = arrangement.server_filter(server.as_ref());
    PeopleFilter {
        is_filtered: arrangement.is_filtered(),
        with_hidden: arrangement.with_hidden(),
        favorites_only: asked.favorites_only,
        hidden_only: asked.hidden_only,
    }
}

/// The places of the people the options show, of a page given in the server's order.
#[uniffi::export]
pub fn people_shown(options: PeopleOptions, people: Vec<PeoplePerson>) -> Vec<u32> {
    let arrangement = people_arrangement(&options);
    people
        .iter()
        .enumerate()
        .filter(|(_, person)| arrangement.includes(person.is_favorite == Some(true), person.is_hidden))
        .map(|(place, _)| place as u32)
        .collect()
}

/// A city of Places, as their groups and order read it.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PlacesCity {
    pub name: String,
    /// Its country; none, or blank, where Immich knows none.
    pub country: Option<String>,
    /// When it was last visited, the date of its newest photo (the wall clock where it was taken, written as UTC, as
    /// the timeline's dates are); none when not known.
    pub visit: Option<SystemTime>,
}

/// Places' view options, by the codes the settings keep them by: cities alone (`None`) or grouped by `Country`, and
/// sorted by `RecentVisit`, `OldestVisit` or `Name`. A code the core does not know is the first of each.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PlacesOptions {
    pub group_by: String,
    pub sort_by: String,
}

/// A group's heading: a country, or the places without one.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum PlacesHeader {
    Country { name: String },
    UnknownCountry,
}

/// A group of Places' cities.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PlacesSection {
    /// Stable across reads: `places`, `country-<name>` or `country-unknown`.
    pub id: String,
    /// None for the cities ungrouped.
    pub header: Option<PlacesHeader>,
    /// Its cities, by their places in the list given, in the order chosen.
    pub cities: Vec<u32>,
}

fn places_of(cities: Vec<PlacesCity>) -> Vec<places::Place> {
    cities
        .into_iter()
        .map(|city| places::Place { city: city.name, country: city.country, visit: city.visit.map(|visit| DateTime::<Utc>::from(visit).naive_utc()) })
        .collect()
}

/// Names in the order `names` gives them: each name by its place in the person's language's order, names alike there
/// sharing one. A name it does not hold goes after those it does, by its lower-case letters.
fn named(names: &HashMap<String, u32>) -> impl Fn(&str, &str) -> Ordering + '_ {
    move |first, second| match (names.get(first), names.get(second)) {
        (Some(first), Some(second)) => first.cmp(second),
        (Some(_), None) => Ordering::Less,
        (None, Some(_)) => Ordering::Greater,
        (None, None) => caseless(first, second),
    }
}

/// Places' cities (given in the server's order) grouped and sorted with the options (`verso_core::places`): all of
/// them in one group without a header, or a group for each country, ordered by its visit or by name, the cities
/// without a country last. `names` holds each city's and country's name by its place in the order of the person's
/// language, names alike there sharing one, an order only the platform knows.
#[uniffi::export]
pub fn places_sections(cities: Vec<PlacesCity>, options: PlacesOptions, names: HashMap<String, u32>) -> Vec<PlacesSection> {
    let arrangement = places::Arrangement {
        group_by: places::GroupBy::from_code(&options.group_by).unwrap_or_default(),
        sort_by: places::SortBy::from_code(&options.sort_by).unwrap_or_default(),
    };
    arrangement
        .groups(&places_of(cities), named(&names))
        .into_iter()
        .map(|group| PlacesSection {
            id: group.id,
            header: group.header.map(|header| match header {
                places::Header::Country(name) => PlacesHeader::Country { name },
                places::Header::UnknownCountry => PlacesHeader::UnknownCountry,
            }),
            cities: group.places.into_iter().map(|place| place as u32).collect(),
        })
        .collect()
}

/// The places of the cities (given in the server's order) sorted by the code given (`RecentVisit`, also for a code it
/// does not know, `OldestVisit` or `Name`): a city whose visit is not known goes last, and cities alike keep the
/// server's order. `names` is as for `places_sections`.
#[uniffi::export]
pub fn places_sorted(cities: Vec<PlacesCity>, sort_by: String, names: HashMap<String, u32>) -> Vec<u32> {
    let arrangement = places::Arrangement { sort_by: places::SortBy::from_code(&sort_by).unwrap_or_default(), ..places::Arrangement::default() };
    arrangement.sorted(&places_of(cities), named(&names)).into_iter().map(|place| place as u32).collect()
}

/// An album, as the Albums page's arrangement reads it.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AlbumFacts {
    pub title: String,
    /// Its owner's id; none where the server named no owner.
    pub owner_id: Option<String>,
    /// Its owner's name, empty where the server named no owner.
    pub owner_name: String,
    /// Shared with other people, in either direction.
    pub shared: bool,
    pub asset_count: u64,
    pub created_at: Option<SystemTime>,
    pub updated_at: Option<SystemTime>,
    /// When its oldest and its newest photo were taken (the wall clock where each was, written as UTC, as Immich sends
    /// it); none for an album without photos.
    pub start_date: Option<SystemTime>,
    pub end_date: Option<SystemTime>,
}

/// The Albums page's view options, by the codes the settings keep them by, the same on Linux: which albums (`All`,
/// `Owned`, `Shared`), grouped by `None`, `Year` or `Owner` in a group order (`asc` or `desc`), sorted by `Title`,
/// `ItemCount`, `DateModified`, `DateCreated`, `MostRecentPhoto` or `OldestPhoto` in an album order. A code the core
/// does not know is Immich's default (`All`, `Year`, `MostRecentPhoto`), an order not `asc` descending.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AlbumsOptions {
    pub filter: String,
    pub group_by: String,
    pub group_order: String,
    pub sort_by: String,
    pub sort_order: String,
}

/// A group's heading: a year of the albums' photos, or none for the albums without photos; the account's own albums,
/// or another owner's.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum AlbumsHeader {
    Year { year: i32 },
    UnknownYear,
    Mine,
    Owner { name: String },
}

/// A group of the Albums page.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AlbumsSection {
    /// Stable across reads, for remembering which groups are collapsed: `albums`, `year-<year>`, `year-unknown`,
    /// `owner-mine` or `owner-<id>`.
    pub id: String,
    /// None for the albums ungrouped.
    pub header: Option<AlbumsHeader>,
    /// Its albums, by their places in the list given, in the order chosen.
    pub albums: Vec<u32>,
}

fn albums_arrangement(options: &AlbumsOptions) -> albums::Arrangement {
    albums::Arrangement {
        filter: albums::Filter::from_code(&options.filter).unwrap_or_default(),
        view: albums::View::default(),
        group_by: albums::GroupBy::from_code(&options.group_by).unwrap_or_default(),
        groups_ascending: albums::is_ascending(&options.group_order),
        sort_by: albums::SortBy::from_code(&options.sort_by).unwrap_or_default(),
        ascending: albums::is_ascending(&options.sort_order),
    }
}

fn album_facts(albums: Vec<AlbumFacts>) -> Vec<albums::AlbumFacts> {
    let date = |time: Option<SystemTime>| time.map(DateTime::<Utc>::from);
    albums
        .into_iter()
        .map(|album| albums::AlbumFacts {
            title: album.title,
            owner_id: album.owner_id,
            owner_name: album.owner_name,
            shared: album.shared,
            asset_count: album.asset_count,
            created_at: date(album.created_at),
            updated_at: date(album.updated_at),
            start_date: date(album.start_date),
            end_date: date(album.end_date),
        })
        .collect()
}

/// Indices, as the places of the items Swift gave.
fn positions(indices: Vec<usize>) -> Vec<u32> {
    indices.into_iter().map(|index| index as u32).collect()
}

/// The albums (given in the server's order) the options show for the account `user_id`, filtered, grouped and sorted
/// within each group (`verso_core::albums`): all of them in one group without a header; a group for each year of their
/// photos, the albums without photos last; or a group for each owner, by name, the account's own first in ascending
/// order and last in descending. Year groups are none while sorting by the albums' own dates. `names` holds each
/// title and owner's name by its place in the order of the person's language, names alike there sharing one.
#[uniffi::export]
pub fn albums_sections(albums: Vec<AlbumFacts>, options: AlbumsOptions, user_id: Option<String>, names: HashMap<String, u32>) -> Vec<AlbumsSection> {
    albums_arrangement(&options)
        .groups(&album_facts(albums), user_id.as_deref(), named(&names))
        .into_iter()
        .map(|group| AlbumsSection {
            id: group.id,
            header: group.header.map(|header| match header {
                albums::Header::Year(year) => AlbumsHeader::Year { year },
                albums::Header::UnknownYear => AlbumsHeader::UnknownYear,
                albums::Header::Mine => AlbumsHeader::Mine,
                albums::Header::Owner(name) => AlbumsHeader::Owner { name },
            }),
            albums: positions(group.albums),
        })
        .collect()
}

/// The places of the albums (given in the server's order) sorted by the options' key and album order, whatever their
/// filter and grouping: an album without the date sorted by goes last in either order, and albums alike keep the
/// server's order. `names` is as for `albums_sections`.
#[uniffi::export]
pub fn albums_sorted(albums: Vec<AlbumFacts>, options: AlbumsOptions, names: HashMap<String, u32>) -> Vec<u32> {
    positions(albums_arrangement(&options).sorted(&album_facts(albums), named(&names)))
}

/// The places of a sidebar section's albums: the first `limit` of them (all without one), sorted by the key given, by
/// its code, in its own order, titles A to Z and the rest newest or largest first. `names` is as for
/// `albums_sections`.
#[uniffi::export]
pub fn albums_sidebar(albums: Vec<AlbumFacts>, sort_by: String, limit: Option<u32>, names: HashMap<String, u32>) -> Vec<u32> {
    let sort_by = albums::SortBy::from_code(&sort_by).unwrap_or_default();
    positions(albums::sidebar(&album_facts(albums), sort_by, limit.map(|limit| limit as usize), named(&names)))
}

/// The grouping the options show, by its code: the one chosen, or `None` where sorting by the albums' own dates turns
/// year groups off.
#[uniffi::export]
pub fn albums_grouping(options: AlbumsOptions) -> String {
    albums_arrangement(&options).effective_group_by().code().to_owned()
}

/// Whether the options' sort key allows a grouping, by its code: year groups need the photos' dates, so sorting by the
/// albums' own turns them off, as Immich does.
#[uniffi::export]
pub fn albums_allows_grouping(options: AlbumsOptions, group_by: String) -> bool {
    albums::GroupBy::from_code(&group_by).is_none_or(|group_by| albums_arrangement(&options).allows(group_by))
}

/// The group order a grouping takes when chosen, by its code: `desc` for years, the newest first, `asc` for owners and
/// for none.
#[uniffi::export]
pub fn albums_group_order_by_default(group_by: String) -> String {
    albums::order_code(albums::GroupBy::from_code(&group_by).unwrap_or_default().default_ascending()).to_owned()
}

/// The album order a sort key takes when chosen, by its code: `asc` for titles, `desc` for counts and dates, the
/// largest and newest first.
#[uniffi::export]
pub fn albums_sort_order_by_default(sort_by: String) -> String {
    albums::order_code(albums::SortBy::from_code(&sort_by).unwrap_or_default().default_ascending()).to_owned()
}

/// The groups collapsed in a grouping, by its code, from what the settings keep for every grouping
/// (`{"Year":["year-2024"]}`, as Immich's web app keeps them); none for `None`, or from what is not that.
#[uniffi::export]
pub fn albums_collapsed(stored: String, group_by: String) -> Vec<String> {
    match albums::GroupBy::from_code(&group_by) {
        Some(group_by) => albums::Collapsed::from_json(&stored).ids(group_by).to_vec(),
        None => Vec::new(),
    }
}

/// What the settings keep once a group of a grouping is collapsed, or expanded where it was collapsed. Without a
/// grouping (`None`, or a code the core does not know) nothing changes.
#[uniffi::export]
pub fn albums_collapse_toggled(stored: String, group_id: String, group_by: String) -> String {
    let mut collapsed = albums::Collapsed::from_json(&stored);
    if let Some(group_by) = albums::GroupBy::from_code(&group_by) {
        collapsed.toggle(&group_id, group_by);
    }
    collapsed.json()
}

/// What the settings keep once a grouping's collapsed groups are these, all at once: none to expand them all.
#[uniffi::export]
pub fn albums_collapsed_set(stored: String, group_ids: Vec<String>, group_by: String) -> String {
    let mut collapsed = albums::Collapsed::from_json(&stored);
    if let Some(group_by) = albums::GroupBy::from_code(&group_by) {
        collapsed.set(group_ids, group_by);
    }
    collapsed.json()
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::*;

    fn month(bucket: &str, count: u32) -> OverviewMonth {
        OverviewMonth { bucket: bucket.to_owned(), count }
    }

    /// The day and hour of March 2024, as the timeline writes them: the wall clock as UTC.
    fn march(day: u64, hour: u64) -> Option<SystemTime> {
        let first = 1_709_251_200; // 2024-03-01T00:00:00Z
        Some(SystemTime::UNIX_EPOCH + Duration::from_secs(first + (day - 1) * 86_400 + hour * 3_600))
    }

    fn photo(id: &str, taken: Option<SystemTime>, is_video: bool) -> OverviewPhoto {
        OverviewPhoto { id: id.to_owned(), taken, is_video }
    }

    fn pick(id: &str, day: Option<u32>) -> OverviewPick {
        OverviewPick { id: id.to_owned(), day }
    }

    #[test]
    fn years_name_their_months_by_the_buckets_given_and_leave_other_sections_out() {
        let years = overview_years(vec![
            month("2024-03-01", 5),
            month("2024-01-01T00:00:00.000Z", 9),
            month("2023-12-01", 2),
            month("2023-11-01", 2),
            month("results", 3),
        ]);
        assert_eq!(years.iter().map(|year| year.id.as_str()).collect::<Vec<_>>(), ["2024", "2023"]);
        assert_eq!(years[0].months, ["2024-03-01", "2024-01-01T00:00:00.000Z"]);
        assert_eq!(years[0].key_month, "2024-01-01T00:00:00.000Z");
        assert_eq!(years[1].key_month, "2023-12-01", "on a tie, the first");
        assert!(overview_years(Vec::new()).is_empty());
    }

    #[test]
    fn picks_read_the_day_of_the_wall_clock_written_as_utc() {
        let photos = vec![
            photo("a", march(20, 20), false),
            photo("b", march(20, 10), false),
            photo("c", march(20, 8), false),
            photo("v", march(9, 12), true),
            photo("d", march(9, 12), false),
            photo("w", march(3, 12), true),
        ];
        assert_eq!(overview_picks(photos, 4), [pick("b", Some(20)), pick("d", Some(9)), pick("w", Some(3))]);
        let late = vec![photo("night", march(31, 23), false)];
        assert_eq!(overview_picks(late, 4), [pick("night", Some(31))], "never the next day in another time zone");
    }

    #[test]
    fn more_days_than_tiles_spread_over_the_month_and_the_undated_still_show() {
        let many: Vec<OverviewPhoto> = (1..=10).rev().map(|day| photo(&format!("p{day}"), march(day, 12), false)).collect();
        let days = |limit: u32| overview_picks(many.clone(), limit).into_iter().map(|pick| pick.day).collect::<Vec<_>>();
        assert_eq!(days(4), [Some(10), Some(7), Some(4), Some(1)]);
        assert_eq!(days(1), [Some(10)]);
        assert!(days(0).is_empty());
        assert!(overview_picks(Vec::new(), 4).is_empty());
        assert_eq!(overview_picks(vec![photo("x", None, false)], 4), [pick("x", None)]);
    }

    fn place(id: &str, latitude: f64, longitude: f64) -> MapPhoto {
        MapPhoto { id: id.to_owned(), latitude, longitude }
    }

    #[test]
    fn the_maps_clusters_carry_their_photos_and_the_box_to_ask_immich_for() {
        let photos = vec![place("b", 45.01, 9.01), place("a", 45.02, 9.02), place("c", 46.0, 10.0), place("nowhere", f64::NAN, 0.0)];
        let clusters = map_clusters(photos.clone(), 45.0, 9.0, 10.0, 10.0);
        let pair = clusters.iter().find(|cluster| cluster.id == "a").unwrap();
        assert_eq!(pair.assets, ["a", "b"]);
        assert!((pair.latitude - 45.015).abs() < 1e-9 && (pair.longitude - 9.015).abs() < 1e-9);
        let bbox: Vec<f64> = pair.bbox.split(',').map(|number| number.parse().unwrap()).collect();
        assert!(bbox[0] < 9.01 && bbox[1] < 45.01 && bbox[2] > 9.02 && bbox[3] > 45.02, "{}", pair.bbox);
        assert!(bbox[2] - bbox[0] < 0.0101, "a hair wider, no more: {}", pair.bbox);
        assert_eq!(clusters.iter().map(|cluster| cluster.assets.len()).sum::<usize>(), 3);
        let mut reversed = photos;
        reversed.reverse();
        assert_eq!(map_clusters(reversed, 45.0, 9.0, 10.0, 10.0), clusters, "the server's order changes nothing");
        assert!(map_clusters(vec![place("a", 45.0, 9.0)], f64::NAN, 9.0, 10.0, 10.0).is_empty());
    }

    fn duplicates(id: &str, sizes: &[Option<u64>]) -> DuplicatesGroup {
        let photos = sizes.iter().enumerate().map(|(index, size)| DuplicatesPhoto { id: format!("{id}{index}"), size: *size }).collect();
        DuplicatesGroup { photos, suggested_keep: Vec::new() }
    }

    #[test]
    fn duplicates_come_back_in_the_order_chosen_by_its_code() {
        let groups = vec![
            duplicates("a", &[Some(10), Some(10)]),
            duplicates("b", &[Some(5), Some(5), Some(5)]),
            duplicates("c", &[Some(900), Some(100)]),
            duplicates("d", &[Some(1), Some(1), None]),
        ];
        let order = |code: &str| duplicates_order(groups.clone(), code.to_owned());
        assert_eq!(order("Default"), [0, 1, 2, 3]);
        assert_eq!(order("ItemCount"), [1, 3, 0, 2], "ties keep the server's order");
        assert_eq!(order("TotalSize"), [2, 0, 1, 3]);
        assert_eq!(order("Largest"), [0, 1, 2, 3], "a code it does not know is the server's order");
        assert!(duplicates_order(Vec::new(), "TotalSize".to_owned()).is_empty());
    }

    #[test]
    fn a_group_keeps_immichs_suggestion_of_its_photos_or_its_first() {
        let mut group = duplicates("a", &[Some(1), Some(2), Some(3)]);
        assert_eq!(duplicates_kept_at_first(group.clone()), ["a0"]);
        group.suggested_keep = vec!["a2".to_owned(), "gone".to_owned()];
        assert_eq!(duplicates_kept_at_first(group.clone()), ["a2"]);
        group.suggested_keep = vec!["gone".to_owned()];
        assert_eq!(duplicates_kept_at_first(group), ["a0"]);
        assert!(duplicates_kept_at_first(DuplicatesGroup { photos: Vec::new(), suggested_keep: vec!["gone".to_owned()] }).is_empty());
    }

    #[test]
    fn shared_links_show_by_immichs_tabs_and_without_the_expired() {
        let past = Some(SystemTime::UNIX_EPOCH + Duration::from_secs(1_767_225_600)); // 2026-01-01
        let future = Some(SystemTime::now() + Duration::from_secs(365 * 86_400));
        let link = |kind: &str, expires_at: Option<SystemTime>| SharedLinkFacts { kind: kind.to_owned(), expires_at };
        let links = vec![link("ALBUM", None), link("INDIVIDUAL", past), link("ALBUM", future)];
        let shown = |filter: &str, hide_expired: bool| shared_links_shown(links.clone(), filter.to_owned(), hide_expired);
        assert_eq!(shown("all", false), [0, 1, 2]);
        assert_eq!(shown("album", false), [0, 2]);
        assert_eq!(shown("individual", false), [1]);
        assert_eq!(shown("all", true), [0, 2]);
        assert!(shown("individual", true).is_empty());
        assert_eq!(shown("everything", false), [0, 1, 2], "a code it does not know shows all");
        assert!(shared_link_expired(past) && !shared_link_expired(future) && !shared_link_expired(None));
    }

    fn options(show: &str, include_hidden: bool) -> PeopleOptions {
        PeopleOptions { show: show.to_owned(), include_hidden }
    }

    #[test]
    fn people_show_by_their_options_and_a_favorite_untold_is_not_one() {
        let person = |is_favorite: Option<bool>, is_hidden: bool| PeoplePerson { is_favorite, is_hidden };
        let people = vec![person(Some(true), false), person(None, false), person(Some(false), true), person(Some(true), true)];
        let shown = |show: &str, include_hidden: bool| people_shown(options(show, include_hidden), people.clone());
        assert_eq!(shown("All", false), [0, 1]);
        assert_eq!(shown("All", true), [0, 1, 2, 3]);
        assert_eq!(shown("Favorites", false), [0]);
        assert_eq!(shown("Favorites", true), [0, 3]);
        assert_eq!(shown("Hidden", false), [2, 3]);
        assert_eq!(shown("Everyone", false), [0, 1], "a code it does not know shows all");
    }

    #[test]
    fn people_ask_the_server_to_filter_only_where_immich_understands_it() {
        let version = |major: u32, minor: u32| Some(GalleryVersion { major, minor, patch: 0 });
        let filter = |show: &str, server: Option<GalleryVersion>| people_filter(options(show, false), server);
        assert_eq!(filter("All", version(3, 3)), PeopleFilter { is_filtered: false, with_hidden: false, favorites_only: false, hidden_only: false });
        assert_eq!(filter("Favorites", version(3, 3)), PeopleFilter { is_filtered: true, with_hidden: false, favorites_only: true, hidden_only: false });
        assert_eq!(filter("Hidden", version(4, 0)), PeopleFilter { is_filtered: true, with_hidden: true, favorites_only: false, hidden_only: true });
        assert_eq!(filter("Favorites", version(3, 2)), PeopleFilter { is_filtered: true, with_hidden: false, favorites_only: false, hidden_only: false });
        assert!(!filter("Hidden", None).hidden_only);
        assert!(people_filter(options("All", true), None).with_hidden);
    }

    /// Places' cities as the server sends them, by name, with the days after a first each was last visited.
    fn cities() -> Vec<PlacesCity> {
        let first = 1_700_000_000; // 2023-11-14T22:13:20Z
        let city = |name: &str, country: Option<&str>, days: Option<u64>| PlacesCity {
            name: name.to_owned(),
            country: country.map(str::to_owned),
            visit: days.map(|days| SystemTime::UNIX_EPOCH + Duration::from_secs(first + days * 86_400)),
        };
        vec![
            city("Aarhus", Some("Denmark"), Some(1)),
            city("Atlantis", None, None),
            city("Bologna", Some("Italy"), Some(9)),
            city("Copenhagen", Some("Denmark"), Some(5)),
            city("Ys", Some(""), Some(3)),
            city("Århus", Some("australia"), Some(7)),
        ]
    }

    /// The names' order as a language gives it, names alike sharing a place.
    fn ranked(names: &[&[&str]]) -> HashMap<String, u32> {
        names.iter().enumerate().flat_map(|(place, alike)| alike.iter().map(move |name| ((*name).to_owned(), place as u32))).collect()
    }

    fn places_options(group_by: &str, sort_by: &str) -> PlacesOptions {
        PlacesOptions { group_by: group_by.to_owned(), sort_by: sort_by.to_owned() }
    }

    #[test]
    fn places_group_by_country_and_follow_their_most_recent_city() {
        let names = ranked(&[&["Aarhus"], &["Atlantis"], &["australia"], &["Bologna"], &["Copenhagen"], &["Denmark"], &["Italy"], &["Ys"], &["Århus"]]);
        let sections = |group_by: &str, sort_by: &str| places_sections(cities(), places_options(group_by, sort_by), names.clone());
        let country = |name: &str| Some(PlacesHeader::Country { name: name.to_owned() });
        let recent = sections("Country", "RecentVisit");
        let headers: Vec<_> = recent.iter().map(|section| section.header.clone()).collect();
        assert_eq!(headers, [country("Italy"), country("australia"), country("Denmark"), Some(PlacesHeader::UnknownCountry)]);
        assert_eq!(recent[2].cities, [3, 0]);
        assert_eq!(recent[3].cities, [4, 1], "an empty country is none, and a visit not known goes last");
        let ids: Vec<String> = sections("Country", "Name").into_iter().map(|section| section.id).collect();
        assert_eq!(ids, ["country-australia", "country-Denmark", "country-Italy", "country-unknown"]);
        let all = sections("None", "RecentVisit");
        assert_eq!(all, [PlacesSection { id: "places".to_owned(), header: None, cities: vec![2, 5, 3, 4, 0, 1] }]);
        assert_eq!(sections("Continent", "Distance"), all, "codes it does not know are the first of each");
        assert!(places_sections(Vec::new(), places_options("Country", "Name"), names.clone()).is_empty());
    }

    #[test]
    fn places_sort_by_visit_or_by_name_in_the_order_the_language_gives() {
        let danish = ranked(&[&["Aarhus"], &["Atlantis"], &["Bologna"], &["Copenhagen"], &["Ys"], &["Århus"]]);
        let english = ranked(&[&["Aarhus"], &["Århus"], &["Atlantis"], &["Bologna"], &["Copenhagen"], &["Ys"]]);
        assert_eq!(places_sorted(cities(), "OldestVisit".to_owned(), danish.clone()), [0, 4, 3, 5, 2, 1]);
        assert_eq!(places_sorted(cities(), "Name".to_owned(), danish.clone()), [0, 1, 2, 3, 4, 5], "Å after Z in Danish");
        assert_eq!(places_sorted(cities(), "Name".to_owned(), english), [0, 5, 1, 2, 3, 4], "Å beside A in English");
        let mut reversed = cities();
        reversed.reverse();
        assert_eq!(places_sorted(reversed, "Name".to_owned(), danish), [5, 4, 3, 2, 1, 0]);
        let twins = vec![cities()[0].clone(), PlacesCity { name: "AARHUS".to_owned(), ..cities()[0].clone() }];
        assert_eq!(places_sorted(twins.clone(), "Name".to_owned(), ranked(&[&["Aarhus", "AARHUS"]])), [0, 1], "names alike keep the server's order");
        assert_eq!(places_sorted(twins, "Name".to_owned(), HashMap::new()), [0, 1], "names it is not given go by their lower-case letters");
    }

    /// A day of a year, at UTC midnight, as Immich sends an album's dates.
    fn on(year: i32, month: u32, day: u32) -> Option<SystemTime> {
        use chrono::TimeZone;
        Some(Utc.with_ymd_and_hms(year, month, day, 0, 0, 0).unwrap().into())
    }

    /// The Mac's check's albums, as the server sends them: a, b and c with photos, d without; b shared by me with Zoe,
    /// c shared by Zoe with me, d by Adam.
    fn album_list() -> Vec<AlbumFacts> {
        let album = |title: &str, owner: &str, shared: bool, count: u64, dates: [Option<SystemTime>; 4]| AlbumFacts {
            title: title.to_owned(),
            owner_id: Some(owner.to_lowercase()),
            owner_name: owner.to_owned(),
            shared,
            asset_count: count,
            created_at: dates[0],
            updated_at: dates[1],
            start_date: dates[2],
            end_date: dates[3],
        };
        vec![
            album("beach", "Me", false, 5, [on(2020, 1, 1), on(2026, 1, 3), on(2023, 6, 1), on(2025, 1, 1)]),
            album("Alps", "Me", true, 9, [on(2021, 1, 1), on(2026, 1, 1), on(2024, 12, 1), on(2024, 12, 31)]),
            album("Cats", "Zoe", true, 2, [on(2022, 1, 1), on(2026, 1, 2), on(2022, 3, 1), on(2025, 7, 1)]),
            album("Empty", "Adam", true, 0, [on(2023, 1, 1), on(2026, 1, 4), None, None]),
        ]
    }

    /// The titles' and owners' order as Finder gives it in English.
    fn album_names() -> HashMap<String, u32> {
        ranked(&[&["Adam"], &["Alps"], &["beach"], &["Cats"], &["Empty"], &["Me"], &["Zoe"]])
    }

    fn albums_options(filter: &str, group_by: &str, group_order: &str, sort_by: &str, sort_order: &str) -> AlbumsOptions {
        AlbumsOptions { filter: filter.to_owned(), group_by: group_by.to_owned(), group_order: group_order.to_owned(), sort_by: sort_by.to_owned(), sort_order: sort_order.to_owned() }
    }

    #[test]
    fn albums_group_by_year_or_owner_and_come_back_as_their_places() {
        let sections = |options: AlbumsOptions| albums_sections(album_list(), options, Some("me".to_owned()), album_names());
        let years = sections(albums_options("All", "Year", "desc", "MostRecentPhoto", "desc"));
        let headers: Vec<_> = years.iter().map(|section| section.header.clone()).collect();
        assert_eq!(headers, [Some(AlbumsHeader::Year { year: 2025 }), Some(AlbumsHeader::Year { year: 2024 }), Some(AlbumsHeader::UnknownYear)]);
        assert_eq!(years.iter().map(|section| section.albums.clone()).collect::<Vec<_>>(), [vec![2, 0], vec![1], vec![3]]);
        let owners = sections(albums_options("All", "Owner", "asc", "Title", "asc"));
        let headers: Vec<_> = owners.iter().map(|section| section.header.clone()).collect();
        let owner = |name: &str| Some(AlbumsHeader::Owner { name: name.to_owned() });
        assert_eq!(headers, [Some(AlbumsHeader::Mine), owner("Adam"), owner("Zoe")]);
        assert_eq!(owners[0], AlbumsSection { id: "owner-mine".to_owned(), header: Some(AlbumsHeader::Mine), albums: vec![1, 0] });
        let shared = sections(albums_options("Shared", "None", "desc", "Title", "asc"));
        assert_eq!(shared, [AlbumsSection { id: "albums".to_owned(), header: None, albums: vec![1, 2, 3] }]);
        assert_eq!(sections(albums_options("Mine", "Decade", "up", "Colour", "down")), years, "codes it does not know are Immich's defaults");
        assert!(albums_sections(Vec::new(), albums_options("All", "Year", "desc", "Title", "asc"), None, album_names()).is_empty());
    }

    #[test]
    fn albums_sort_by_a_key_and_a_sidebar_section_takes_its_first_in_the_keys_own_order() {
        let sorted = |sort_by: &str, sort_order: &str| albums_sorted(album_list(), albums_options("All", "None", "asc", sort_by, sort_order), album_names());
        assert_eq!(sorted("Title", "asc"), [1, 0, 2, 3]);
        assert_eq!(sorted("ItemCount", "desc"), [1, 0, 2, 3]);
        assert_eq!(sorted("DateCreated", "desc"), [3, 2, 1, 0]);
        assert_eq!(sorted("OldestPhoto", "asc"), [2, 0, 1, 3], "an album without photos last in either order");
        assert_eq!(sorted("OldestPhoto", "desc"), [1, 0, 2, 3]);
        let sidebar = |sort_by: &str, limit: Option<u32>| albums_sidebar(album_list(), sort_by.to_owned(), limit, album_names());
        assert_eq!(sidebar("DateModified", Some(2)), [3, 0]);
        assert_eq!(sidebar("MostRecentPhoto", Some(3)), [2, 0, 1]);
        assert_eq!(sidebar("Title", None), [1, 0, 2, 3]);
        assert_eq!(sidebar("Title", Some(10)).len(), 4);
        let danish = ranked(&[&["Alps"], &["beach"], &["Zoe"], &["Ålborg"]]);
        let english = ranked(&[&["Ålborg"], &["Alps"], &["beach"], &["Zoe"]]);
        let titled = |titles: &[&str], names: HashMap<String, u32>| {
            let albums = titles.iter().map(|title| AlbumFacts { title: (*title).to_owned(), ..album_list()[0].clone() }).collect();
            albums_sidebar(albums, "Title".to_owned(), None, names)
        };
        assert_eq!(titled(&["Ålborg", "Zoe", "Alps"], danish), [2, 1, 0], "Å after Z in Danish");
        assert_eq!(titled(&["Ålborg", "Zoe", "Alps"], english), [0, 2, 1], "Å beside A in English");
    }

    #[test]
    fn albums_turn_year_groups_off_by_the_albums_own_dates_and_each_choice_takes_its_order() {
        let options = |sort_by: &str| albums_options("All", "Year", "desc", sort_by, "desc");
        for sort_by in ["DateCreated", "DateModified"] {
            assert_eq!(albums_grouping(options(sort_by)), "None");
            assert!(!albums_allows_grouping(options(sort_by), "Year".to_owned()));
            assert!(albums_allows_grouping(options(sort_by), "Owner".to_owned()) && albums_allows_grouping(options(sort_by), "None".to_owned()));
            let sections = albums_sections(album_list(), options(sort_by), Some("me".to_owned()), album_names());
            assert_eq!(sections.iter().map(|section| section.header.clone()).collect::<Vec<_>>(), [None]);
        }
        assert_eq!(albums_grouping(options("OldestPhoto")), "Year");
        assert_eq!(albums_grouping(albums_options("All", "Owner", "asc", "DateCreated", "desc")), "Owner");
        assert_eq!(albums_group_order_by_default("Year".to_owned()), "desc");
        assert_eq!(albums_group_order_by_default("Owner".to_owned()), "asc");
        assert_eq!(albums_sort_order_by_default("Title".to_owned()), "asc");
        for sort_by in ["ItemCount", "DateModified", "DateCreated", "MostRecentPhoto", "OldestPhoto"] {
            assert_eq!(albums_sort_order_by_default(sort_by.to_owned()), "desc");
        }
    }

    #[test]
    fn albums_keep_their_collapsed_groups_for_each_grouping_as_immich_does() {
        let stored = albums_collapse_toggled(String::new(), "year-2024".to_owned(), "Year".to_owned());
        let stored = albums_collapse_toggled(stored, "owner-zoe".to_owned(), "Owner".to_owned());
        assert_eq!(stored, r#"{"Owner":["owner-zoe"],"Year":["year-2024"]}"#);
        assert_eq!(albums_collapsed(stored.clone(), "Year".to_owned()), ["year-2024"]);
        assert!(albums_collapsed(stored.clone(), "None".to_owned()).is_empty());
        assert_eq!(albums_collapse_toggled(stored.clone(), "albums".to_owned(), "None".to_owned()), stored, "without a grouping nothing changes");
        let stored = albums_collapse_toggled(stored, "year-2024".to_owned(), "Year".to_owned());
        assert_eq!(albums_collapsed_set(stored, Vec::new(), "Owner".to_owned()), "{}");
        let all = albums_collapsed_set("{}".to_owned(), vec!["year-2025".to_owned(), "year-unknown".to_owned()], "Year".to_owned());
        assert_eq!(albums_collapsed(all, "Year".to_owned()), ["year-2025", "year-unknown"]);
        assert!(albums_collapsed("not json".to_owned(), "Year".to_owned()).is_empty());
    }
}
