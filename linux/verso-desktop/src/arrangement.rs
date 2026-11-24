//! A photo page's view options as Linux remembers them, under `grid.<page>.<option>` in `gallery.json`, and the source a
//! page reads with them; the options themselves, which a page offers and how each is kept, and the query a timeline page
//! reads with them, are the core's (`verso_core::grid_options`), as on the Mac and the iPhone. Linux's window shows
//! favorites alone, photos or videos alone, by date taken or date added, newest or oldest first.

use immich_api::TimelineOptions;
use verso_core::grid_options::{Arrangement, GridPage, MediaType, Order, Query, Show, SortBy};

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

/// The source a page reads with these options, from the one it reads without them, a timeline's by the core's query
/// (`Arrangement::query`); date added only on servers that have it.
pub fn source(arrangement: &Arrangement, base: &Source, server_has_date_added: bool) -> Source {
    match base {
        Source::Timeline(scope) | Source::Arranged(scope, _) => match arrangement.query(scope, TimelineOptions::default(), server_has_date_added) {
            Query::Search(query) => Source::Search(query),
            Query::Timeline(scope, options) if options == TimelineOptions::default() => Source::Timeline(scope),
            Query::Timeline(scope, options) => Source::Arranged(scope, options),
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

#[cfg(test)]
mod tests {
    use super::*;
    use immich_api::{AssetKind, TimelineScope};

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
