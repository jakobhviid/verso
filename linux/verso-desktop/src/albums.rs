//! The albums' view settings as Linux remembers them, in `gallery.json`, and the sidebar's two album sections; the
//! arrangement itself, which albums show, their groups, their order and the groups collapsed, is the core's
//! (`verso_core::albums`), as on the Mac and the iPhone. Titles and owners' names go by their lower-case letters.

use immich_api::Album;
use verso_core::albums::{is_ascending, order_code, sidebar, AlbumFacts, Arrangement, Collapsed, Filter, GroupBy, Header, SortBy, View};
use verso_core::names::caseless;

use crate::settings::Settings;

/// The view options remembered, Immich's defaults where none were; an order not remembered is the choice's own.
pub fn load(settings: &Settings) -> Arrangement {
    let defaults = Arrangement::default();
    let get = |key: &str| settings.get(&format!("albums.{key}"));
    let group_by = get("groupBy").and_then(|code| GroupBy::from_code(&code)).unwrap_or(defaults.group_by);
    let sort_by = get("sortBy").and_then(|code| SortBy::from_code(&code)).unwrap_or(defaults.sort_by);
    Arrangement {
        filter: get("filter").and_then(|code| Filter::from_code(&code)).unwrap_or(defaults.filter),
        view: get("view").and_then(|code| View::from_code(&code)).unwrap_or(defaults.view),
        group_by,
        groups_ascending: get("groupOrder").map_or(group_by.default_ascending(), |order| is_ascending(&order)),
        sort_by,
        ascending: get("sortOrder").map_or(sort_by.default_ascending(), |order| is_ascending(&order)),
    }
}

pub fn save(arrangement: &Arrangement, settings: &Settings) {
    settings.set("albums.filter", Some(arrangement.filter.code()));
    settings.set("albums.view", Some(arrangement.view.code()));
    settings.set("albums.groupBy", Some(arrangement.group_by.code()));
    settings.set("albums.groupOrder", Some(order_code(arrangement.groups_ascending)));
    settings.set("albums.sortBy", Some(arrangement.sort_by.code()));
    settings.set("albums.sortOrder", Some(order_code(arrangement.ascending)));
}

/// A group of albums, as the Albums page shows it.
#[derive(Debug, Clone, PartialEq)]
pub struct Group {
    /// Stable across reads, for remembering which groups are collapsed.
    pub id: String,
    pub header: Option<Header>,
    pub albums: Vec<Album>,
}

/// The albums shown, filtered, grouped, and sorted within each group.
pub fn groups(arrangement: &Arrangement, albums: &[Album], user_id: Option<&str>) -> Vec<Group> {
    let facts: Vec<AlbumFacts> = albums.iter().map(AlbumFacts::from).collect();
    arrangement
        .groups(&facts, user_id, caseless)
        .into_iter()
        .map(|group| Group { id: group.id, header: group.header, albums: group.albums.into_iter().map(|index| albums[index].clone()).collect() })
        .collect()
}

/// A grouping's collapsed groups, kept under a key of its own, a group a line.
pub fn collapsed(group_by: GroupBy, settings: &Settings) -> Collapsed {
    Collapsed::from_lines(group_by, &settings.get(&collapsed_key(group_by)).unwrap_or_default())
}

/// Collapse a group, or expand it.
pub fn set_collapsed(group_by: GroupBy, id: &str, collapsing: bool, settings: &Settings) {
    let mut collapsed = collapsed(group_by, settings);
    if collapsed.is_collapsed(id, group_by) != collapsing {
        collapsed.toggle(id, group_by);
    }
    settings.set(&collapsed_key(group_by), collapsed.lines(group_by).as_deref());
}

fn collapsed_key(group_by: GroupBy) -> String {
    format!("albums.collapsedGroups.{}", group_by.code())
}

/// A sidebar album section: your own albums ("My Albums") or the shared ones.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Section {
    Mine,
    Shared,
}

/// How many albums a section lists: all, or the first few.
pub const SHOW_COUNTS: [Option<usize>; 7] = [None, Some(5), Some(10), Some(15), Some(20), Some(30), Some(50)];

impl Section {
    fn key(self) -> &'static str {
        match self {
            Section::Mine => "sidebar.myAlbums",
            Section::Shared => "sidebar.sharedAlbums",
        }
    }

    /// The section's albums: unshared ones for My Albums, shared ones (yours too) for Shared Albums, as the Mac
    /// gallery splits them; and whether the limit left some out.
    pub fn albums(self, albums: &[Album], sort_by: SortBy, limit: Option<usize>) -> (Vec<Album>, bool) {
        let members: Vec<&Album> = albums.iter().filter(|album| album.shared == (self == Section::Shared)).collect();
        let facts: Vec<AlbumFacts> = members.iter().map(|album| AlbumFacts::from(*album)).collect();
        let listed: Vec<Album> = sidebar(&facts, sort_by, limit, caseless).into_iter().map(|index| members[index].clone()).collect();
        let cut = listed.len() < members.len();
        (listed, cut)
    }

    /// The section's remembered count (default 10) and order (default by date modified, newest first).
    pub fn load(self, settings: &Settings) -> (Option<usize>, SortBy) {
        let limit = match settings.get(&format!("{}.show", self.key())).as_deref() {
            Some("all") => None,
            Some(count) => count.parse().ok().or(Some(10)),
            None => Some(10),
        };
        let sort_by = settings.get(&format!("{}.sortBy", self.key())).and_then(|code| SortBy::from_code(&code)).unwrap_or(SortBy::DateModified);
        (limit, sort_by)
    }

    pub fn save(self, settings: &Settings, limit: Option<usize>, sort_by: SortBy) {
        settings.set(&format!("{}.show", self.key()), Some(&limit.map_or("all".to_owned(), |count| count.to_string())));
        settings.set(&format!("{}.sortBy", self.key()), Some(sort_by.code()));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::{TimeZone, Utc};
    use immich_api::{AlbumMember, AlbumRole, User};

    fn album(name: &str, owner: &str, shared: bool, newest: Option<i32>, count: u64) -> Album {
        let member = AlbumMember { user: User { id: owner.into(), name: owner.to_uppercase(), ..User::default() }, role: AlbumRole::Owner };
        Album {
            id: name.into(),
            name: name.into(),
            shared,
            asset_count: count,
            end_date: newest.map(|year| Utc.with_ymd_and_hms(year, 6, 1, 0, 0, 0).unwrap()),
            start_date: newest.map(|year| Utc.with_ymd_and_hms(year, 1, 1, 0, 0, 0).unwrap()),
            members: vec![member],
            ..Album::default()
        }
    }

    fn names(albums: &[Album]) -> Vec<&str> {
        albums.iter().map(|album| album.name.as_str()).collect()
    }

    #[test]
    fn albums_group_by_year_newest_first_with_the_undated_last() {
        let albums = [album("a", "me", false, Some(2023), 1), album("b", "me", false, Some(2025), 2), album("c", "me", false, None, 0), album("d", "me", false, Some(2025), 5)];
        let groups = groups(&Arrangement::default(), &albums, Some("me"));
        let headers: Vec<_> = groups.iter().map(|group| group.header.clone()).collect();
        assert_eq!(headers, [Some(Header::Year(2025)), Some(Header::Year(2023)), Some(Header::UnknownYear)]);
        assert_eq!(names(&groups[0].albums), ["b", "d"], "a stable sort keeps ties in order");
    }

    #[test]
    fn filters_split_your_own_from_the_shared_and_owner_groups_put_yours_first_ascending() {
        let albums = [album("mine", "me", false, Some(2024), 1), album("ours", "me", true, Some(2024), 1), album("theirs", "ann", true, Some(2024), 1)];
        let owned = Arrangement { filter: Filter::Owned, ..Arrangement::default() };
        assert_eq!(names(&groups(&owned, &albums, Some("me"))[0].albums), ["mine", "ours"]);
        let shared = Arrangement { filter: Filter::Shared, group_by: GroupBy::None, ..Arrangement::default() };
        assert_eq!(names(&groups(&shared, &albums, Some("me"))[0].albums), ["ours", "theirs"]);
        let by_owner = Arrangement::default().grouped_by(GroupBy::Owner);
        let headers: Vec<_> = groups(&by_owner, &albums, Some("me")).into_iter().map(|group| group.header).collect();
        assert_eq!(headers, [Some(Header::Mine), Some(Header::Owner("ANN".into()))]);
    }

    #[test]
    fn the_view_options_are_remembered_and_an_order_not_remembered_is_the_choices_own() {
        let folder = tempfile::tempdir().unwrap();
        let settings = Settings::open(&folder.path().join("settings.json"));
        assert_eq!(load(&settings), Arrangement::default());
        let chosen = Arrangement { filter: Filter::Shared, view: View::List, ..Arrangement::default().grouped_by(GroupBy::Owner).sorted_by(SortBy::Title) };
        save(&chosen, &settings);
        assert_eq!(load(&settings), chosen);
        assert_eq!(settings.get("albums.view").as_deref(), Some("List"));
        assert_eq!((settings.get("albums.groupOrder").as_deref(), settings.get("albums.sortOrder").as_deref()), (Some("asc"), Some("asc")));
        settings.set("albums.groupOrder", None);
        settings.set("albums.sortOrder", None);
        settings.set("albums.groupBy", Some("Year"));
        let loaded = load(&settings);
        assert!(!loaded.groups_ascending && loaded.ascending, "the newest year first, titles A to Z");
    }

    #[test]
    fn collapsed_groups_are_kept_for_each_grouping_a_line_each() {
        let folder = tempfile::tempdir().unwrap();
        let settings = Settings::open(&folder.path().join("settings.json"));
        set_collapsed(GroupBy::Year, "year-2024", true, &settings);
        set_collapsed(GroupBy::Year, "year-unknown", true, &settings);
        set_collapsed(GroupBy::Year, "year-2024", true, &settings);
        set_collapsed(GroupBy::Owner, "owner-ann", true, &settings);
        assert_eq!(settings.get("albums.collapsedGroups.Year").as_deref(), Some("year-2024\nyear-unknown"));
        assert!(collapsed(GroupBy::Owner, &settings).is_collapsed("owner-ann", GroupBy::Owner));
        assert!(!collapsed(GroupBy::Owner, &settings).is_collapsed("year-2024", GroupBy::Owner));
        set_collapsed(GroupBy::Year, "year-2024", false, &settings);
        set_collapsed(GroupBy::Year, "year-unknown", false, &settings);
        assert_eq!(settings.get("albums.collapsedGroups.Year"), None);
        set_collapsed(GroupBy::None, "albums", true, &settings);
        assert_eq!(settings.get("albums.collapsedGroups.None"), None, "without a grouping nothing collapses");
    }

    #[test]
    fn sidebar_sections_split_by_sharing_and_say_when_they_are_cut() {
        let albums: Vec<Album> = (0..12).map(|index| album(&format!("a{index:02}"), "me", index % 3 == 0, Some(2000 + index), 1)).collect();
        let (mine, cut) = Section::Mine.albums(&albums, SortBy::Title, Some(5));
        assert_eq!((mine.len(), cut), (5, true));
        assert!(mine.iter().all(|album| !album.shared));
        assert_eq!(names(&mine), ["a01", "a02", "a04", "a05", "a07"]);
        let (shared, cut) = Section::Shared.albums(&albums, SortBy::Title, None);
        assert_eq!((shared.len(), cut), (4, false));
        let (newest, _) = Section::Shared.albums(&albums, SortBy::MostRecentPhoto, Some(2));
        assert_eq!(names(&newest), ["a09", "a06"]);
        let folder = tempfile::tempdir().unwrap();
        let settings = Settings::open(&folder.path().join("settings.json"));
        assert_eq!(Section::Mine.load(&settings), (Some(10), SortBy::DateModified));
        Section::Mine.save(&settings, None, SortBy::Title);
        assert_eq!(Section::Mine.load(&settings), (None, SortBy::Title));
    }
}
