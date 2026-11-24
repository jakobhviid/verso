//! A photo page's view options, as in the Mac gallery (`GridArrangement`): favorites only, photos or videos only,
//! by date taken or date added, newest or oldest first. Each page keeps its own, under `grid.<page>.<option>`.
//!
//! The timeline API narrows to favorites and orders; it has no media type, so photos or videos only reads through the
//! search API instead, which orders by date taken and groups by the month taken.

use immich_api::search::AssetQuery;
use immich_api::{AssetKind, TimelineOptions, TimelineScope, Visibility};

use crate::library::Source;
use crate::settings::Settings;

/// The pages with view options.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GridPage {
    Library,
    Favorites,
    Archive,
    Person,
    Tag,
    Locked,
    Videos,
    LargeFiles,
}

impl GridPage {
    fn name(self) -> &'static str {
        match self {
            GridPage::Library => "library",
            GridPage::Favorites => "favorites",
            GridPage::Archive => "archive",
            GridPage::Person => "person",
            GridPage::Tag => "tag",
            GridPage::Locked => "locked",
            GridPage::Videos => "videos",
            GridPage::LargeFiles => "largeFiles",
        }
    }

    /// A favorites filter adds nothing on Favorites.
    pub fn offers_favorites(self) -> bool {
        self != GridPage::Favorites
    }

    /// Videos are videos already.
    pub fn offers_media_type(self) -> bool {
        self != GridPage::Videos
    }

    /// Date added orders the timeline only; search, which Videos and Large Files read, has no upload-date order.
    pub fn offers_sort_by(self) -> bool {
        !matches!(self, GridPage::Videos | GridPage::LargeFiles)
    }

    /// Large Files is always largest first.
    pub fn offers_order(self) -> bool {
        self != GridPage::LargeFiles
    }

    fn key(self, option: &str) -> String {
        format!("grid.{}.{option}", self.name())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum MediaType {
    #[default]
    All,
    Photos,
    Videos,
}

impl MediaType {
    pub const ALL: [MediaType; 3] = [MediaType::All, MediaType::Photos, MediaType::Videos];

    pub fn code(self) -> &'static str {
        match self {
            MediaType::All => "all",
            MediaType::Photos => "photos",
            MediaType::Videos => "videos",
        }
    }

    pub fn from_code(code: &str) -> Option<MediaType> {
        MediaType::ALL.into_iter().find(|kind| kind.code() == code)
    }
}

/// One page's view options.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Arrangement {
    pub favorites_only: bool,
    pub media_type: MediaType,
    pub by_date_added: bool,
    pub oldest_first: bool,
}

impl Arrangement {
    /// The page's remembered options, limited to those it offers.
    pub fn load(page: GridPage, settings: &Settings) -> Arrangement {
        let value = |option: &str| settings.get(&page.key(option));
        Arrangement {
            favorites_only: page.offers_favorites() && value("show").as_deref() == Some("favorites"),
            media_type: if page.offers_media_type() { value("mediaType").and_then(|code| MediaType::from_code(&code)).unwrap_or_default() } else { MediaType::All },
            by_date_added: page.offers_sort_by() && value("sortBy").as_deref() == Some("added"),
            oldest_first: page.offers_order() && value("order").as_deref() == Some("asc"),
        }
    }

    pub fn save(&self, page: GridPage, settings: &Settings) {
        settings.set(&page.key("show"), self.favorites_only.then_some("favorites"));
        settings.set(&page.key("mediaType"), (self.media_type != MediaType::All).then_some(self.media_type.code()));
        settings.set(&page.key("sortBy"), self.by_date_added.then_some("added"));
        settings.set(&page.key("order"), self.oldest_first.then_some("asc"));
    }

    /// Whether anything is left out: the View Options button shows it.
    pub fn is_filtered(&self) -> bool {
        self.favorites_only || self.media_type != MediaType::All
    }

    /// Date added applies only while the timeline API reads the page, and only on servers that have it.
    pub fn sorts_by_date_added(&self, server_has_date_added: bool) -> bool {
        server_has_date_added && self.by_date_added && self.media_type == MediaType::All
    }

    /// The source a page reads with these options, from the one it reads without them.
    pub fn source(&self, base: &Source, server_has_date_added: bool) -> Source {
        match base {
            Source::Timeline(scope) | Source::Arranged(scope, _) => match self.searched(scope) {
                Some(query) => Source::Search(Box::new(query)),
                None => {
                    let options = TimelineOptions { favorites_only: self.favorites_only, oldest_first: self.oldest_first, by_date_added: self.sorts_by_date_added(server_has_date_added), ..TimelineOptions::default() };
                    if options == TimelineOptions::default() { Source::Timeline(scope.clone()) } else { Source::Arranged(scope.clone(), options) }
                }
            },
            Source::Search(query) => {
                let mut query = (**query).clone();
                query.favorites_only = query.favorites_only || self.favorites_only;
                if self.media_type != MediaType::All {
                    query.kind = Some(self.kind());
                }
                query.oldest_first = self.oldest_first;
                Source::Search(Box::new(query))
            }
            Source::LargeFiles { .. } => Source::LargeFiles { favorites_only: self.favorites_only, kind: (self.media_type != MediaType::All).then(|| self.kind()) },
            other => other.clone(),
        }
    }

    fn kind(&self) -> AssetKind {
        if self.media_type == MediaType::Videos { AssetKind::Video } else { AssetKind::Image }
    }

    /// Photos or videos only: the search API's query for a timeline, if it can express the scope.
    fn searched(&self, scope: &TimelineScope) -> Option<AssetQuery> {
        if self.media_type == MediaType::All {
            return None;
        }
        let mut query = AssetQuery { kind: Some(self.kind()), favorites_only: self.favorites_only, oldest_first: self.oldest_first, ..AssetQuery::default() };
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
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn options_are_remembered_per_page_and_only_those_a_page_offers() {
        let folder = tempfile::tempdir().unwrap();
        let settings = Settings::open(&folder.path().join("settings.json"));
        let chosen = Arrangement { favorites_only: true, media_type: MediaType::Photos, by_date_added: true, oldest_first: true };
        chosen.save(GridPage::Library, &settings);
        assert_eq!(Arrangement::load(GridPage::Library, &settings), chosen);
        assert_eq!(Arrangement::load(GridPage::Archive, &settings), Arrangement::default(), "each page its own");
        chosen.save(GridPage::Videos, &settings);
        let videos = Arrangement::load(GridPage::Videos, &settings);
        assert_eq!((videos.media_type, videos.by_date_added, videos.oldest_first), (MediaType::All, false, true));
    }

    #[test]
    fn a_timeline_narrows_and_orders_and_media_type_reads_through_search() {
        let library = Source::Timeline(TimelineScope::LibraryStacked);
        assert!(matches!(Arrangement::default().source(&library, true), Source::Timeline(_)));
        let favorites_oldest = Arrangement { favorites_only: true, oldest_first: true, ..Arrangement::default() };
        match favorites_oldest.source(&library, true) {
            Source::Arranged(_, options) => assert!(options.favorites_only && options.oldest_first && !options.by_date_added),
            other => panic!("{other:?}"),
        }
        let added = Arrangement { by_date_added: true, ..Arrangement::default() };
        assert!(matches!(added.source(&library, false), Source::Timeline(_)), "an older server keeps date taken");
        let videos = Arrangement { media_type: MediaType::Videos, favorites_only: true, ..Arrangement::default() };
        match videos.source(&Source::Timeline(TimelineScope::Person("p".into())), true) {
            Source::Search(query) => {
                assert_eq!(query.kind, Some(AssetKind::Video));
                assert!(query.favorites_only);
                assert_eq!(query.person_ids.as_deref(), Some(&["p".to_owned()][..]));
            }
            other => panic!("{other:?}"),
        }
    }
}
