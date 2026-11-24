//! A photo page's view options (after Immich Gallery's `GridArrangement`, in the style of Apple Photos; Immich's web app
//! has none for these pages): favorites alone, photos or videos alone, by date taken or date added, newest or oldest
//! first; on Assign Location, the photos without a place alone; on the Library, the account's own photos alone. Each
//! page keeps its own, under `grid.<page>.<option>`, and offers only what it can. Linux's window, the Mac and the iPhone
//! (through `verso-bridge`) all read them here, each showing the options it shows.
//!
//! The codes written are Linux's, lower-case (`favorites`, `photos`, `added`); the spelling the Mac and the iPhone kept
//! before, Immich's names (`Favorites`, `IMAGE`, `createdAt`), is read too, so no platform's kept options need
//! migrating.
//!
//! The timeline API narrows to favorites and orders, by date taken or date added (Immich v3.0); it has no media type, so
//! photos or videos alone read through the search API instead, which orders by date taken and groups by the month taken.
//! The query a page reads with its options is made here too ([`Arrangement::query`]): Linux's window reads it as its
//! grid's source, the Mac and the iPhone through the typed timeline calls or their search.

use chrono::{DateTime, Utc};
use immich_api::{AssetKind, AssetQuery, TimelineOptions, TimelineScope, Visibility};

/// The pages with view options.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GridPage {
    Library,
    Favorites,
    Archive,
    /// A partner's photos.
    Partner,
    Person,
    Tag,
    Locked,
    Videos,
    LargeFiles,
    /// Assign Location: the photos to give a place.
    Geolocation,
}

impl GridPage {
    pub const ALL: [GridPage; 10] = [
        GridPage::Library,
        GridPage::Favorites,
        GridPage::Archive,
        GridPage::Partner,
        GridPage::Person,
        GridPage::Tag,
        GridPage::Locked,
        GridPage::Videos,
        GridPage::LargeFiles,
        GridPage::Geolocation,
    ];

    /// The page's name in its settings' keys.
    pub fn name(self) -> &'static str {
        match self {
            GridPage::Library => "library",
            GridPage::Favorites => "favorites",
            GridPage::Archive => "archive",
            GridPage::Partner => "partner",
            GridPage::Person => "person",
            GridPage::Tag => "tag",
            GridPage::Locked => "locked",
            GridPage::Videos => "videos",
            GridPage::LargeFiles => "largeFiles",
            GridPage::Geolocation => "geolocation",
        }
    }

    pub fn from_name(name: &str) -> Option<GridPage> {
        GridPage::ALL.into_iter().find(|page| page.name() == name)
    }

    /// Where the page keeps an option: `grid.<page>.<option>`.
    pub fn key(self, option: &str) -> String {
        format!("grid.{}.{option}", self.name())
    }

    /// A favorites filter adds nothing on Favorites, a partner's favorites are their own, and Assign Location filters by
    /// place instead.
    pub fn offers_favorites(self) -> bool {
        !matches!(self, GridPage::Favorites | GridPage::Partner | GridPage::Geolocation)
    }

    /// Photos or videos alone: videos are videos already, a timeline reads them through search, which cannot search a
    /// partner's library, and Assign Location stays on the timeline, whose coordinates its place filter needs.
    pub fn offers_media_type(self) -> bool {
        !matches!(self, GridPage::Videos | GridPage::Partner | GridPage::Geolocation)
    }

    /// Assign Location alone: the photos the map leaves out, those without coordinates.
    pub fn offers_location(self) -> bool {
        self == GridPage::Geolocation
    }

    /// Assign Location is for finding the photos without a place, so it starts with those alone.
    pub fn default_location(self) -> Location {
        if self.offers_location() { Location::Missing } else { Location::All }
    }

    /// Date added orders the timeline only; search, which Videos and Large Files read, has no upload-date order.
    pub fn offers_sort_by(self) -> bool {
        !matches!(self, GridPage::Videos | GridPage::LargeFiles)
    }

    /// Large Files is always largest first.
    pub fn offers_order(self) -> bool {
        self != GridPage::LargeFiles
    }

    /// The account's own photos alone, without partners' (Photos' Captured by Me): only the Library mixes partners'
    /// photos into the account's.
    pub fn offers_owner(self) -> bool {
        self == GridPage::Library
    }
}

/// Each option's values with the code written, and the spelling the Mac and the iPhone kept before where it differs,
/// read too.
macro_rules! codes {
    ($kind:ident: $($variant:ident = $code:literal $(| $earlier:literal)?),+) => {
        impl $kind {
            pub const ALL: &'static [$kind] = &[$($kind::$variant),+];
            /// The code written, Linux's.
            pub fn code(self) -> &'static str { match self { $($kind::$variant => $code),+ } }
            /// The value kept by a code, written by any platform.
            pub fn from_code(code: &str) -> Option<$kind> {
                match code { $($code $(| $earlier)? => Some($kind::$variant),)+ _ => None }
            }
        }
    };
}

/// All items, or the favorites alone.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Show {
    #[default]
    All,
    Favorites,
}

/// Photos and videos, or one of them alone.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum MediaType {
    #[default]
    All,
    Photos,
    Videos,
}

/// By the date a photo was taken, or added to Immich.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum SortBy {
    #[default]
    DateTaken,
    DateAdded,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Order {
    #[default]
    NewestFirst,
    OldestFirst,
}

/// Assign Location's filter: every item, or those without a place alone.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Location {
    #[default]
    All,
    Missing,
}

/// Whose photos: everyone's the page asks for, or the account's own alone.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Owner {
    #[default]
    Anyone,
    Mine,
}

codes!(Show: All = "all" | "All", Favorites = "favorites" | "Favorites");
codes!(MediaType: All = "all" | "ALL", Photos = "photos" | "IMAGE", Videos = "videos" | "VIDEO");
codes!(SortBy: DateTaken = "taken" | "takenAt", DateAdded = "added" | "createdAt");
codes!(Order: NewestFirst = "desc", OldestFirst = "asc");
codes!(Location: All = "all" | "All", Missing = "missing" | "Missing");
codes!(Owner: Anyone = "anyone" | "Anyone", Mine = "mine" | "Mine");

impl MediaType {
    /// The kind of asset Immich's search is asked for, none for both.
    pub fn kind(self) -> Option<AssetKind> {
        match self {
            MediaType::All => None,
            MediaType::Photos => Some(AssetKind::Image),
            MediaType::Videos => Some(AssetKind::Video),
        }
    }
}

/// The names the options are kept by, after the page's name: `grid.<page>.<option>`.
pub const OPTIONS: [&str; 6] = ["show", "mediaType", "sortBy", "order", "location", "owner"];

/// What a timeline page reads with its view options.
#[derive(Debug, Clone, PartialEq)]
pub enum Query {
    /// Its timeline, narrowed and ordered.
    Timeline(TimelineScope, TimelineOptions),
    /// Photos or videos alone, through the search API, newest or oldest first by date taken.
    Search(Box<AssetQuery>),
}

/// One page's view options.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Arrangement {
    pub show: Show,
    pub media_type: MediaType,
    pub sort_by: SortBy,
    pub order: Order,
    pub location: Location,
    pub owner: Owner,
}

impl Arrangement {
    /// A page's options as kept, each read by `kept` from its name (`OPTIONS`) in either spelling, limited to those the
    /// page offers: an option it does not offer, or one kept by a code no platform writes, is the page's default.
    pub fn read(page: GridPage, kept: impl Fn(&str) -> Option<String>) -> Arrangement {
        fn chosen<T: Default>(offered: bool, code: Option<String>, from_code: fn(&str) -> Option<T>) -> Option<T> {
            if offered { code.and_then(|code| from_code(&code)) } else { Some(T::default()) }
        }
        Arrangement {
            show: chosen(page.offers_favorites(), kept("show"), Show::from_code).unwrap_or_default(),
            media_type: chosen(page.offers_media_type(), kept("mediaType"), MediaType::from_code).unwrap_or_default(),
            sort_by: chosen(page.offers_sort_by(), kept("sortBy"), SortBy::from_code).unwrap_or_default(),
            order: chosen(page.offers_order(), kept("order"), Order::from_code).unwrap_or_default(),
            location: chosen(page.offers_location(), kept("location"), Location::from_code).unwrap_or(page.default_location()),
            owner: chosen(page.offers_owner(), kept("owner"), Owner::from_code).unwrap_or_default(),
        }
    }

    /// Whether anything is left out: the View Options button shows it.
    pub fn is_filtered(&self) -> bool {
        self.show != Show::All || self.media_type != MediaType::All || self.location != Location::All || self.owner != Owner::Anyone
    }

    /// The favorites alone, on the timeline and in search.
    pub fn favorites_only(&self) -> bool {
        self.show == Show::Favorites
    }

    /// Photos or videos alone on a timeline page read through the search API, as the timeline API has no media type.
    /// Search groups into the months taken and leaves out partners' photos.
    pub fn searches_timeline(&self) -> bool {
        self.media_type != MediaType::All
    }

    /// Sorting by date added, which the timeline API alone can (on servers that have it), so not while searching.
    pub fn sorts_by_date_added(&self) -> bool {
        self.sort_by == SortBy::DateAdded && !self.searches_timeline()
    }

    pub fn oldest_first(&self) -> bool {
        self.order == Order::OldestFirst
    }

    /// Assign Location: the timeline API cannot filter by place, so the grid leaves out the photos with one itself. As
    /// on Immich's map, a photo has a place when it has both a latitude and a longitude.
    pub fn hides_located(&self) -> bool {
        self.location == Location::Missing
    }

    /// Without partners the timeline is the account's own photos.
    pub fn own_photos_only(&self) -> bool {
        self.owner == Owner::Mine
    }

    /// The query a timeline page reads with these options, from the scope it shows and the options it reads it with
    /// without them, which are each platform's (the Mac and the iPhone read every timeline stacked, and an album in its
    /// order); by date added only on servers that have it. Photos or videos alone read through search where it can say
    /// the scope, which it cannot for the trash or a partner's library; the account's own photos alone leave the
    /// partners' out of the Library and keep its stacks.
    pub fn query(&self, scope: &TimelineScope, options: TimelineOptions, server_has_date_added: bool) -> Query {
        if let Some(query) = self.search(scope) {
            return Query::Search(Box::new(query));
        }
        let mut options = TimelineOptions {
            favorites_only: options.favorites_only || self.favorites_only(),
            oldest_first: options.oldest_first || self.oldest_first(),
            by_date_added: options.by_date_added || (server_has_date_added && self.sorts_by_date_added()),
            stacked: options.stacked,
        };
        let scope = match scope {
            TimelineScope::LibraryStacked if self.own_photos_only() => {
                options.stacked = true;
                TimelineScope::Library
            }
            other => other.clone(),
        };
        Query::Timeline(scope, options)
    }

    /// Photos or videos alone: the search for a timeline's scope, if search can say it.
    fn search(&self, scope: &TimelineScope) -> Option<AssetQuery> {
        let kind = self.media_type.kind()?;
        let mut query = AssetQuery { kind: Some(kind), favorites_only: self.favorites_only(), oldest_first: self.oldest_first(), ..AssetQuery::default() };
        match scope {
            TimelineScope::Library | TimelineScope::LibraryStacked => query.visibility = Some(Visibility::Timeline),
            TimelineScope::Archive => query.visibility = Some(Visibility::Archive),
            TimelineScope::Locked => query.visibility = Some(Visibility::Locked),
            TimelineScope::Favorites => query.favorites_only = true,
            TimelineScope::Person(id) => {
                query.person_ids = Some(vec![id.clone()]);
                query.visibility = Some(Visibility::Timeline);
            }
            TimelineScope::Tag(id) => query.tag_ids = Some(vec![id.clone()]),
            TimelineScope::Album(id) => query.album_ids = Some(vec![id.clone()]),
            TimelineScope::Trash | TimelineScope::Partner(_) => return None,
        }
        Some(query)
    }

    /// The month a photo falls in, as a bucket's first seven characters (`2026-11`): by date added the month it was
    /// uploaded, in UTC, none when that is not known; by date taken the month on its own clock, from `local_date_time`
    /// (the wall clock where it was taken, written as UTC, as Immich sends it).
    pub fn month(&self, local_date_time: &str, created_at: Option<DateTime<Utc>>) -> Option<String> {
        if self.sorts_by_date_added() {
            created_at.map(|created| created.format("%Y-%m").to_string())
        } else {
            Some(local_date_time.chars().take(7).collect())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;
    use std::collections::HashMap;

    fn read(page: GridPage, kept: &[(&str, &str)]) -> Arrangement {
        let kept: HashMap<String, String> = kept.iter().map(|(option, code)| ((*option).to_owned(), (*code).to_owned())).collect();
        Arrangement::read(page, |option| kept.get(option).cloned())
    }

    fn arrangement(show: Show, media_type: MediaType, sort_by: SortBy, order: Order) -> Arrangement {
        Arrangement { show, media_type, sort_by, order, ..Arrangement::default() }
    }

    #[test]
    fn options_are_read_per_page_in_the_spelling_written_and_the_one_the_mac_kept_before() {
        assert_eq!(read(GridPage::Library, &[]), Arrangement::default());
        let linux = [("show", "favorites"), ("mediaType", "photos"), ("sortBy", "added"), ("order", "asc")];
        let mac = [("show", "Favorites"), ("mediaType", "IMAGE"), ("sortBy", "createdAt"), ("order", "asc")];
        let chosen = arrangement(Show::Favorites, MediaType::Photos, SortBy::DateAdded, Order::OldestFirst);
        assert_eq!(read(GridPage::Library, &linux), chosen);
        assert_eq!(read(GridPage::Library, &mac), chosen);
        assert_eq!(read(GridPage::Library, &[("mediaType", "VIDEO")]).media_type, MediaType::Videos);
        assert_eq!(read(GridPage::Library, &[("mediaType", "ALL"), ("sortBy", "takenAt"), ("order", "desc")]), Arrangement::default());
        let assign = [("location", "All")];
        assert_eq!(read(GridPage::Geolocation, &assign).location, Location::All);
        assert_eq!(read(GridPage::Geolocation, &[("location", "Missing")]).location, Location::Missing);
        assert_eq!(read(GridPage::Geolocation, &[("location", "all")]).location, Location::All);
        assert_eq!(read(GridPage::Library, &[("owner", "Mine")]).owner, Owner::Mine);
        assert_eq!(read(GridPage::Library, &[("owner", "mine")]).owner, Owner::Mine);
    }

    #[test]
    fn each_code_is_read_in_both_spellings_and_written_in_linuxs() {
        assert_eq!((Show::from_code("Favorites"), Show::from_code("All")), (Some(Show::Favorites), Some(Show::All)));
        assert_eq!((Show::Favorites.code(), Show::All.code()), ("favorites", "all"));
        assert_eq!(MediaType::from_code("IMAGE"), Some(MediaType::Photos));
        assert_eq!(MediaType::from_code("VIDEO"), Some(MediaType::Videos));
        assert_eq!(MediaType::from_code("ALL"), Some(MediaType::All));
        assert_eq!((MediaType::Photos.code(), MediaType::Videos.code(), MediaType::All.code()), ("photos", "videos", "all"));
        assert_eq!(SortBy::from_code("createdAt"), Some(SortBy::DateAdded));
        assert_eq!(SortBy::from_code("takenAt"), Some(SortBy::DateTaken));
        assert_eq!((SortBy::DateAdded.code(), SortBy::DateTaken.code()), ("added", "taken"));
        assert_eq!((Order::from_code("asc"), Order::from_code("desc")), (Some(Order::OldestFirst), Some(Order::NewestFirst)));
        assert_eq!((Location::from_code("Missing"), Location::Missing.code()), (Some(Location::Missing), "missing"));
        assert_eq!((Owner::from_code("Mine"), Owner::from_code("Anyone"), Owner::Mine.code()), (Some(Owner::Mine), Some(Owner::Anyone), "mine"));
        for show in Show::ALL {
            assert_eq!(Show::from_code(show.code()), Some(*show));
        }
        for media_type in MediaType::ALL {
            assert_eq!(MediaType::from_code(media_type.code()), Some(*media_type));
        }
        for sort_by in SortBy::ALL {
            assert_eq!(SortBy::from_code(sort_by.code()), Some(*sort_by));
        }
        for location in Location::ALL {
            assert_eq!(Location::from_code(location.code()), Some(*location));
        }
        for owner in Owner::ALL {
            assert_eq!(Owner::from_code(owner.code()), Some(*owner));
        }
        assert_eq!(Show::from_code("FAVORITES"), None);
        assert_eq!(MediaType::from_code("Image"), None);
    }

    #[test]
    fn a_page_reads_only_the_options_it_offers_and_a_code_nobody_writes_is_the_default() {
        let everything = [("show", "favorites"), ("mediaType", "videos"), ("sortBy", "added"), ("order", "asc"), ("location", "all"), ("owner", "mine")];
        assert_eq!(read(GridPage::Archive, &[]), Arrangement::default(), "each page its own");
        assert_eq!(read(GridPage::Videos, &everything), Arrangement { show: Show::Favorites, order: Order::OldestFirst, ..Arrangement::default() });
        assert_eq!(read(GridPage::LargeFiles, &everything), Arrangement { show: Show::Favorites, media_type: MediaType::Videos, ..Arrangement::default() });
        assert!(!read(GridPage::Favorites, &[("show", "Favorites")]).is_filtered());
        assert!(!read(GridPage::Partner, &[("show", "Favorites"), ("mediaType", "VIDEO")]).is_filtered());
        assert_eq!(read(GridPage::Partner, &[("sortBy", "createdAt"), ("order", "asc")]).sort_by, SortBy::DateAdded);
        assert_eq!(read(GridPage::Tag, &[("order", "Nonsense")]).order, Order::NewestFirst);
        assert_eq!(read(GridPage::Person, &[("owner", "Mine")]).owner, Owner::Anyone, "only the Library reads whose photos");
        assert_eq!(read(GridPage::Library, &[("location", "Missing")]).location, Location::All, "other pages ignore a place filter");
        let located = read(GridPage::Geolocation, &[]);
        assert_eq!(located, Arrangement { location: Location::Missing, ..Arrangement::default() });
        assert!(located.hides_located() && located.is_filtered() && !located.searches_timeline());
        let everything_located = read(GridPage::Geolocation, &everything);
        assert_eq!(everything_located, Arrangement { sort_by: SortBy::DateAdded, order: Order::OldestFirst, ..Arrangement::default() });
        assert_eq!(read(GridPage::Geolocation, &[("location", "Nonsense")]).location, Location::Missing, "a code nobody writes is the page's default");
    }

    #[test]
    fn pages_offer_what_they_can() {
        let favorites: Vec<GridPage> = GridPage::ALL.into_iter().filter(|page| page.offers_favorites()).collect();
        assert_eq!(favorites, [GridPage::Library, GridPage::Archive, GridPage::Person, GridPage::Tag, GridPage::Locked, GridPage::Videos, GridPage::LargeFiles]);
        let media: Vec<GridPage> = GridPage::ALL.into_iter().filter(|page| page.offers_media_type()).collect();
        assert_eq!(media, [GridPage::Library, GridPage::Favorites, GridPage::Archive, GridPage::Person, GridPage::Tag, GridPage::Locked, GridPage::LargeFiles]);
        assert!(!GridPage::Videos.offers_sort_by() && !GridPage::LargeFiles.offers_sort_by() && GridPage::Partner.offers_sort_by());
        assert!(!GridPage::LargeFiles.offers_order() && GridPage::Videos.offers_order());
        assert_eq!((GridPage::Geolocation.default_location(), GridPage::Library.default_location()), (Location::Missing, Location::All));
        assert!(GridPage::Library.offers_owner() && !GridPage::Archive.offers_owner());
        for page in GridPage::ALL {
            assert_eq!(GridPage::from_name(page.name()), Some(page));
        }
        assert_eq!(GridPage::LargeFiles.key("order"), "grid.largeFiles.order");
    }

    #[test]
    fn photos_or_videos_alone_search_and_then_sort_by_date_taken() {
        let videos = arrangement(Show::All, MediaType::Videos, SortBy::DateAdded, Order::NewestFirst);
        assert!(videos.searches_timeline() && videos.is_filtered() && !videos.sorts_by_date_added());
        assert_eq!(videos.media_type.kind(), Some(AssetKind::Video));
        assert_eq!(MediaType::Photos.kind(), Some(AssetKind::Image));
        assert_eq!(MediaType::All.kind(), None);
        let added = arrangement(Show::All, MediaType::All, SortBy::DateAdded, Order::OldestFirst);
        assert!(added.sorts_by_date_added() && added.oldest_first() && !added.is_filtered());
        let mine = Arrangement { owner: Owner::Mine, sort_by: SortBy::DateAdded, ..Arrangement::default() };
        assert!(mine.is_filtered() && mine.own_photos_only() && !mine.searches_timeline() && !mine.favorites_only());
        assert!(arrangement(Show::Favorites, MediaType::All, SortBy::DateTaken, Order::NewestFirst).favorites_only());
    }

    #[test]
    fn months_go_by_the_photos_own_clock_or_by_date_added_the_upload_in_utc() {
        let taken = "2026-01-01T00:30:00.000Z";
        let uploaded = Some(Utc.with_ymd_and_hms(2025, 12, 31, 23, 30, 0).unwrap());
        assert_eq!(Arrangement::default().month(taken, uploaded).as_deref(), Some("2026-01"));
        let added = arrangement(Show::All, MediaType::All, SortBy::DateAdded, Order::OldestFirst);
        assert_eq!(added.month(taken, uploaded).as_deref(), Some("2025-12"));
        assert_eq!(added.month(taken, None), None);
        let videos = Arrangement { media_type: MediaType::Videos, ..added };
        assert_eq!(videos.month(taken, uploaded).as_deref(), Some("2026-01"), "search groups by the month taken");
    }

    fn timeline(query: Query) -> (TimelineScope, TimelineOptions) {
        match query {
            Query::Timeline(scope, options) => (scope, options),
            Query::Search(query) => panic!("a search: {query:?}"),
        }
    }

    fn search(query: Query) -> AssetQuery {
        match query {
            Query::Search(query) => *query,
            Query::Timeline(scope, options) => panic!("a timeline: {scope:?} {options:?}"),
        }
    }

    #[test]
    fn a_timeline_narrows_and_orders_and_media_type_reads_through_search() {
        let library = TimelineScope::LibraryStacked;
        let none = TimelineOptions::default();
        assert_eq!(Arrangement::default().query(&library, none, true), Query::Timeline(library.clone(), none));
        let favorites_oldest = Arrangement { show: Show::Favorites, order: Order::OldestFirst, ..Arrangement::default() };
        let (_, options) = timeline(favorites_oldest.query(&library, none, true));
        assert!(options.favorites_only && options.oldest_first && !options.by_date_added);
        let added = Arrangement { sort_by: SortBy::DateAdded, ..Arrangement::default() };
        assert_eq!(added.query(&library, none, false), Query::Timeline(library.clone(), none), "an older server keeps date taken");
        assert!(timeline(added.query(&library, none, true)).1.by_date_added);
        let videos = Arrangement { media_type: MediaType::Videos, show: Show::Favorites, ..Arrangement::default() };
        let query = search(videos.query(&TimelineScope::Person("p".into()), none, true));
        assert_eq!(query.kind, Some(AssetKind::Video));
        assert!(query.favorites_only);
        assert_eq!(query.person_ids.as_deref(), Some(&["p".to_owned()][..]));
        assert_eq!(query.visibility, Some(Visibility::Timeline));
        let videos_added = Arrangement { sort_by: SortBy::DateAdded, ..videos };
        let (scope, options) = timeline(videos_added.query(&TimelineScope::Partner("p".into()), none, true));
        assert_eq!(scope, TimelineScope::Partner("p".into()), "a partner's photos are not searched");
        assert!(!options.by_date_added);
        assert!(matches!(videos.query(&TimelineScope::Trash, none, true), Query::Timeline(TimelineScope::Trash, _)), "nor the trash");
    }

    #[test]
    fn photos_or_videos_alone_search_each_scope_as_its_timeline_shows_it() {
        let photos = Arrangement { media_type: MediaType::Photos, order: Order::OldestFirst, ..Arrangement::default() };
        let none = TimelineOptions::default();
        let searched = |scope: TimelineScope| search(photos.query(&scope, none, true));
        for scope in [TimelineScope::Library, TimelineScope::LibraryStacked] {
            let query = searched(scope);
            assert_eq!((query.kind, query.visibility, query.oldest_first, query.favorites_only), (Some(AssetKind::Image), Some(Visibility::Timeline), true, false));
        }
        assert_eq!(searched(TimelineScope::Archive).visibility, Some(Visibility::Archive));
        assert_eq!(searched(TimelineScope::Locked).visibility, Some(Visibility::Locked));
        let favorites = searched(TimelineScope::Favorites);
        assert!(favorites.favorites_only && favorites.visibility.is_none(), "the favorites, archived ones included");
        let tag = searched(TimelineScope::Tag("t".into()));
        assert_eq!((tag.tag_ids.as_deref(), tag.visibility), (Some(&["t".to_owned()][..]), None));
        let album = searched(TimelineScope::Album("a".into()));
        assert_eq!((album.album_ids.as_deref(), album.visibility), (Some(&["a".to_owned()][..]), None));
        let newest = Arrangement { media_type: MediaType::Videos, ..Arrangement::default() };
        assert!(!search(newest.query(&TimelineScope::Library, none, true)).oldest_first);
    }

    #[test]
    fn the_accounts_own_photos_leave_the_partners_out_and_keep_the_stacks() {
        let none = TimelineOptions::default();
        let mine = Arrangement { owner: Owner::Mine, ..Arrangement::default() };
        let stacked = TimelineOptions { stacked: true, ..none };
        assert_eq!(mine.query(&TimelineScope::LibraryStacked, none, true), Query::Timeline(TimelineScope::Library, stacked));
        let mine_favorites = Arrangement { show: Show::Favorites, sort_by: SortBy::DateAdded, ..mine };
        assert_eq!(
            mine_favorites.query(&TimelineScope::LibraryStacked, none, true),
            Query::Timeline(TimelineScope::Library, TimelineOptions { favorites_only: true, by_date_added: true, ..stacked })
        );
        assert_eq!(Arrangement::default().query(&TimelineScope::LibraryStacked, none, true), Query::Timeline(TimelineScope::LibraryStacked, none));
    }

    #[test]
    fn a_platforms_own_options_are_kept() {
        let stacked_oldest = TimelineOptions { stacked: true, oldest_first: true, ..TimelineOptions::default() };
        let album = TimelineScope::Album("a".into());
        assert_eq!(Arrangement::default().query(&album, stacked_oldest, true), Query::Timeline(album.clone(), stacked_oldest), "an album in its order");
        let favorites = Arrangement { show: Show::Favorites, ..Arrangement::default() };
        let (scope, options) = timeline(favorites.query(&TimelineScope::Archive, TimelineOptions { stacked: true, ..TimelineOptions::default() }, true));
        assert_eq!(scope, TimelineScope::Archive);
        assert!(options.stacked && options.favorites_only && !options.oldest_first);
    }
}
