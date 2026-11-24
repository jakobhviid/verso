//! How the gallery arranges what it shows, worked out in the core for the Mac and the iPhone as for Linux's window
//! (ARCHITECTURE.md, "Verso on the Mac"): the Library's Years and Months (`verso_core::overview`), the map's clusters
//! (`verso_core::map`), the Duplicates page's order (`verso_core::duplicates`), which shared links show
//! (`verso_core::shared_links`) and People's filter (`verso_core::people`). The Swift side names a timeline's months by
//! their bucket (`2025-03-01`), as its grid does, and gets them back the same way; a choice kept in its settings goes
//! by its code, the same on Linux, and a list it sorts or filters comes back as the places of its items.

use std::collections::HashMap;
use std::time::SystemTime;

use chrono::{DateTime, Utc};
use immich_api::map::MapMarker;
use immich_api::timeline::YearMonth;
use immich_api::{ServerVersion, SharedLink, SharedLinkKind};
use verso_core::duplicates::{self, Measure, SortBy};
use verso_core::shared_links::{self, Arrangement, Filter};
use verso_core::{map, overview, people};

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
}
