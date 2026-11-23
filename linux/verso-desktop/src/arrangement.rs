//! A photo page's view options as Linux remembers them, under `grid.<page>.<option>` in `gallery.json`, and the source a
//! page reads with them; the options themselves, which a page offers and how each is kept, are the core's
//! (`verso_core::grid_options`), as on the Mac and the iPhone. Linux's window shows favorites alone, photos or videos
//! alone, by date taken or date added, newest or oldest first.
//!
//! The timeline API narrows to favorites and orders; it has no media type, so photos or videos only reads through the
//! search API instead, which orders by date taken and groups by the month taken.

use immich_api::search::AssetQuery;
use immich_api::{AssetKind, TimelineOptions, TimelineScope, Visibility};
use verso_core::grid_options::{Arrangement, GridPage, MediaType, Order, Show, SortBy};

use crate::library::Source;
use crate::settings::Settings;

/// The page's remembered options, limited to those it offers.
pub fn load(page: GridPage, settings: &Settings) -> Arrangement {
    Arrangement::read(page, |option| settings.get(&page.key(option)))
}

/// Remember the options Linux's window shows; each at its default is remembered as no choice.
pub fn save(arrangement: &Arrangement, page: GridPage, settings: &Settings) {
    settings.set(&page.key("show"), (arrangement.show != Show::All).then_some(arrangement.show.code()));
    settings.set(&page.key("mediaType"), (arrangement.media_type != MediaType::All).then_some(arrangement.media_type.code()));
    settings.set(&page.key("sortBy"), (arrangement.sort_by != SortBy::DateTaken).then_some(arrangement.sort_by.code()));
    settings.set(&page.key("order"), (arrangement.order != Order::NewestFirst).then_some(arrangement.order.code()));
}

/// The source a page reads with these options, from the one it reads without them; date added only on servers that
/// have it.
pub fn source(arrangement: &Arrangement, base: &Source, server_has_date_added: bool) -> Source {
    match base {
        Source::Timeline(scope) | Source::Arranged(scope, _) => match searched(arrangement, scope) {
            Some(query) => Source::Search(Box::new(query)),
            None => {
                let options = TimelineOptions {
                    favorites_only: arrangement.favorites_only(),
                    oldest_first: arrangement.oldest_first(),
                    by_date_added: server_has_date_added && arrangement.sorts_by_date_added(),
                    ..TimelineOptions::default()
                };
                if options == TimelineOptions::default() { Source::Timeline(scope.clone()) } else { Source::Arranged(scope.clone(), options) }
            }
        },
        Source::Search(query) => {
            let mut query = (**query).clone();
            query.favorites_only = query.favorites_only || arrangement.favorites_only();
            if let Some(kind) = arrangement.media_type.kind() {
                query.kind = Some(kind);
            }
            query.oldest_first = arrangement.oldest_first();
            Source::Search(Box::new(query))
        }
        Source::LargeFiles { .. } => Source::LargeFiles { favorites_only: arrangement.favorites_only(), kind: arrangement.media_type.kind() },
        other => other.clone(),
    }
}

/// Photos or videos only: the search API's query for a timeline, if it can express the scope.
fn searched(arrangement: &Arrangement, scope: &TimelineScope) -> Option<AssetQuery> {
    let kind: AssetKind = arrangement.media_type.kind()?;
    let mut query = AssetQuery { kind: Some(kind), favorites_only: arrangement.favorites_only(), oldest_first: arrangement.oldest_first(), ..AssetQuery::default() };
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn options_are_remembered_per_page_in_linuxs_codes_and_only_those_a_page_offers() {
        let folder = tempfile::tempdir().unwrap();
        let settings = Settings::open(&folder.path().join("settings.json"));
        let chosen = Arrangement { show: Show::Favorites, media_type: MediaType::Photos, sort_by: SortBy::DateAdded, order: Order::OldestFirst, ..Arrangement::default() };
        save(&chosen, GridPage::Library, &settings);
        assert_eq!(load(GridPage::Library, &settings), chosen);
        let kept: Vec<Option<String>> = ["show", "mediaType", "sortBy", "order"].iter().map(|option| settings.get(&GridPage::Library.key(option))).collect();
        assert_eq!(kept, [Some("favorites".to_owned()), Some("photos".to_owned()), Some("added".to_owned()), Some("asc".to_owned())]);
        assert_eq!(load(GridPage::Archive, &settings), Arrangement::default(), "each page its own");
        save(&chosen, GridPage::Videos, &settings);
        let videos = load(GridPage::Videos, &settings);
        assert_eq!((videos.media_type, videos.sort_by, videos.order), (MediaType::All, SortBy::DateTaken, Order::OldestFirst));
        save(&Arrangement::default(), GridPage::Library, &settings);
        assert_eq!(settings.get("grid.library.show"), None, "a default is remembered as no choice");
    }

    #[test]
    fn options_the_mac_kept_in_its_spelling_read_the_same() {
        let folder = tempfile::tempdir().unwrap();
        let settings = Settings::open(&folder.path().join("settings.json"));
        for (option, code) in [("show", "Favorites"), ("mediaType", "VIDEO"), ("sortBy", "createdAt"), ("order", "asc")] {
            settings.set(&GridPage::Person.key(option), Some(code));
        }
        let read = load(GridPage::Person, &settings);
        assert_eq!(read, Arrangement { show: Show::Favorites, media_type: MediaType::Videos, sort_by: SortBy::DateAdded, order: Order::OldestFirst, ..Arrangement::default() });
    }

    #[test]
    fn a_timeline_narrows_and_orders_and_media_type_reads_through_search() {
        let library = Source::Timeline(TimelineScope::LibraryStacked);
        assert!(matches!(source(&Arrangement::default(), &library, true), Source::Timeline(_)));
        let favorites_oldest = Arrangement { show: Show::Favorites, order: Order::OldestFirst, ..Arrangement::default() };
        match source(&favorites_oldest, &library, true) {
            Source::Arranged(_, options) => assert!(options.favorites_only && options.oldest_first && !options.by_date_added),
            other => panic!("{other:?}"),
        }
        let added = Arrangement { sort_by: SortBy::DateAdded, ..Arrangement::default() };
        assert!(matches!(source(&added, &library, false), Source::Timeline(_)), "an older server keeps date taken");
        match source(&added, &library, true) {
            Source::Arranged(_, options) => assert!(options.by_date_added),
            other => panic!("{other:?}"),
        }
        let videos = Arrangement { media_type: MediaType::Videos, show: Show::Favorites, ..Arrangement::default() };
        match source(&videos, &Source::Timeline(TimelineScope::Person("p".into())), true) {
            Source::Search(query) => {
                assert_eq!(query.kind, Some(AssetKind::Video));
                assert!(query.favorites_only);
                assert_eq!(query.person_ids.as_deref(), Some(&["p".to_owned()][..]));
            }
            other => panic!("{other:?}"),
        }
        let videos_added = Arrangement { sort_by: SortBy::DateAdded, ..videos };
        assert!(matches!(source(&videos_added, &Source::Timeline(TimelineScope::Partner("p".into())), true), Source::Arranged(_, options) if !options.by_date_added), "a partner's photos are not searched");
    }
}
