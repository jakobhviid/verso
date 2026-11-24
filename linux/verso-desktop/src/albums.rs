//! The albums' view settings, as Immich's web app and the Mac gallery have them (`AlbumsArrangement`): which albums
//! (all, your own, shared), grouped by year or owner, sorted by one of six keys; and the sidebar's two album sections.

use std::cmp::Ordering;

use chrono::{DateTime, Datelike, Utc};
use immich_api::Album;

use crate::settings::Settings;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Filter {
    #[default]
    All,
    Owned,
    Shared,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum GroupBy {
    None,
    #[default]
    Year,
    Owner,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum SortBy {
    Title,
    ItemCount,
    DateModified,
    DateCreated,
    #[default]
    MostRecentPhoto,
    OldestPhoto,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum View {
    #[default]
    Covers,
    List,
}

macro_rules! codes {
    ($kind:ty: $($variant:ident = $code:literal),+) => {
        impl $kind {
            pub const ALL: &'static [$kind] = &[$(<$kind>::$variant),+];
            pub fn code(self) -> &'static str { match self { $(<$kind>::$variant => $code),+ } }
            pub fn from_code(code: &str) -> Option<$kind> { Self::ALL.iter().copied().find(|value| value.code() == code) }
        }
    };
}
codes!(Filter: All = "All", Owned = "Owned", Shared = "Shared");
codes!(GroupBy: None = "None", Year = "Year", Owner = "Owner");
codes!(SortBy: Title = "Title", ItemCount = "ItemCount", DateModified = "DateModified", DateCreated = "DateCreated", MostRecentPhoto = "MostRecentPhoto", OldestPhoto = "OldestPhoto");
codes!(View: Covers = "Cover", List = "List");

impl GroupBy {
    pub fn default_ascending(self) -> bool {
        self != GroupBy::Year
    }
}

impl SortBy {
    /// Titles A to Z; counts and dates biggest and newest first.
    pub fn default_ascending(self) -> bool {
        self == SortBy::Title
    }
}

/// A group's heading.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Header {
    Year(i32),
    UnknownYear,
    Mine,
    Owner(String),
}

#[derive(Debug, Clone, PartialEq)]
pub struct Group {
    /// Stable across reads, for remembering which groups are folded.
    pub id: String,
    pub header: Option<Header>,
    pub albums: Vec<Album>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Arrangement {
    pub filter: Filter,
    pub view: View,
    pub group_by: GroupBy,
    pub groups_ascending: bool,
    pub sort_by: SortBy,
    pub ascending: bool,
}

impl Default for Arrangement {
    fn default() -> Arrangement {
        Arrangement { filter: Filter::All, view: View::Covers, group_by: GroupBy::Year, groups_ascending: false, sort_by: SortBy::MostRecentPhoto, ascending: false }
    }
}

impl Arrangement {
    pub fn load(settings: &Settings) -> Arrangement {
        let defaults = Arrangement::default();
        let get = |key: &str| settings.get(&format!("albums.{key}"));
        let group_by = get("groupBy").and_then(|code| GroupBy::from_code(&code)).unwrap_or(defaults.group_by);
        let sort_by = get("sortBy").and_then(|code| SortBy::from_code(&code)).unwrap_or(defaults.sort_by);
        Arrangement {
            filter: get("filter").and_then(|code| Filter::from_code(&code)).unwrap_or(defaults.filter),
            view: get("view").and_then(|code| View::from_code(&code)).unwrap_or(defaults.view),
            group_by,
            groups_ascending: get("groupOrder").map_or(group_by.default_ascending(), |order| order == "asc"),
            sort_by,
            ascending: get("sortOrder").map_or(sort_by.default_ascending(), |order| order == "asc"),
        }
    }

    pub fn save(&self, settings: &Settings) {
        let order = |ascending: bool| if ascending { "asc" } else { "desc" };
        settings.set("albums.filter", Some(self.filter.code()));
        settings.set("albums.view", Some(self.view.code()));
        settings.set("albums.groupBy", Some(self.group_by.code()));
        settings.set("albums.groupOrder", Some(order(self.groups_ascending)));
        settings.set("albums.sortBy", Some(self.sort_by.code()));
        settings.set("albums.sortOrder", Some(order(self.ascending)));
    }

    /// Choosing a sort key takes that key's own order, as Immich does.
    pub fn sorted_by(mut self, sort_by: SortBy) -> Arrangement {
        self.sort_by = sort_by;
        self.ascending = sort_by.default_ascending();
        self
    }

    /// Choosing a grouping takes its own order.
    pub fn grouped_by(mut self, group_by: GroupBy) -> Arrangement {
        self.group_by = group_by;
        self.groups_ascending = group_by.default_ascending();
        self
    }

    /// Immich turns year groups off while sorting by the albums' own dates, which say nothing of the photos' years.
    pub fn allows(&self, group_by: GroupBy) -> bool {
        group_by != GroupBy::Year || !matches!(self.sort_by, SortBy::DateCreated | SortBy::DateModified)
    }

    pub fn effective_group_by(&self) -> GroupBy {
        if self.allows(self.group_by) { self.group_by } else { GroupBy::None }
    }

    /// The albums shown, filtered, grouped, and sorted within each group.
    pub fn groups(&self, albums: &[Album], user_id: Option<&str>) -> Vec<Group> {
        let shown: Vec<Album> = albums
            .iter()
            .filter(|album| match self.filter {
                Filter::All => true,
                Filter::Owned => owner_id(album) == user_id,
                Filter::Shared => album.shared,
            })
            .cloned()
            .collect();
        if shown.is_empty() {
            return Vec::new();
        }
        let groups = match self.effective_group_by() {
            GroupBy::None => vec![Group { id: "albums".into(), header: None, albums: shown }],
            GroupBy::Year => {
                let year = |album: &Album| (if self.sort_by == SortBy::OldestPhoto { album.start_date } else { album.end_date }).map(|date| date.year());
                let mut years: Vec<Option<i32>> = shown.iter().map(year).collect();
                years.sort();
                years.dedup();
                let mut keyed: Vec<Option<i32>> = years;
                ordered(&mut keyed, self.groups_ascending, |year| *year, |a, b| a.cmp(b));
                keyed
                    .into_iter()
                    .map(|key| Group {
                        id: key.map_or("year-unknown".into(), |year| format!("year-{year}")),
                        header: Some(key.map_or(Header::UnknownYear, Header::Year)),
                        albums: shown.iter().filter(|album| year(album) == key).cloned().collect(),
                    })
                    .collect()
            }
            GroupBy::Owner => {
                let mut owners: Vec<(String, String)> = Vec::new();
                for album in &shown {
                    let id = owner_id(album).unwrap_or_default().to_owned();
                    if Some(id.as_str()) != user_id && !owners.iter().any(|(known, _)| *known == id) {
                        owners.push((id, album.owner().map(|owner| owner.name.clone()).unwrap_or_default()));
                    }
                }
                ordered(&mut owners, self.groups_ascending, |(_, name)| Some(name.to_lowercase()), |a, b| a.cmp(b));
                let others: Vec<Group> = owners
                    .into_iter()
                    .map(|(id, name)| Group { id: format!("owner-{id}"), header: Some(Header::Owner(name)), albums: shown.iter().filter(|album| owner_id(album) == Some(id.as_str())).cloned().collect() })
                    .collect();
                let mine: Vec<Album> = shown.iter().filter(|album| user_id.is_some() && owner_id(album) == user_id).cloned().collect();
                let mine = (!mine.is_empty()).then(|| Group { id: "owner-mine".into(), header: Some(Header::Mine), albums: mine });
                // Your own come first in ascending order and last in descending.
                match (mine, self.groups_ascending) {
                    (Some(mine), true) => std::iter::once(mine).chain(others).collect(),
                    (Some(mine), false) => others.into_iter().chain(std::iter::once(mine)).collect(),
                    (None, _) => others,
                }
            }
        };
        groups
            .into_iter()
            .map(|mut group| {
                group.albums = self.sorted(group.albums);
                group
            })
            .collect()
    }

    pub fn sorted(&self, mut albums: Vec<Album>) -> Vec<Album> {
        let date = |value: Option<DateTime<Utc>>| value;
        match self.sort_by {
            SortBy::Title => ordered(&mut albums, self.ascending, |album| Some(album.name.to_lowercase()), |a, b| a.cmp(b)),
            SortBy::ItemCount => ordered(&mut albums, self.ascending, |album| Some(album.asset_count), |a, b| a.cmp(b)),
            SortBy::DateModified => ordered(&mut albums, self.ascending, |album| Some(album.updated_at), |a, b| a.cmp(b)),
            SortBy::DateCreated => ordered(&mut albums, self.ascending, |album| Some(album.created_at), |a, b| a.cmp(b)),
            SortBy::MostRecentPhoto => ordered(&mut albums, self.ascending, |album| date(album.end_date), |a, b| a.cmp(b)),
            SortBy::OldestPhoto => ordered(&mut albums, self.ascending, |album| date(album.start_date), |a, b| a.cmp(b)),
        }
        albums
    }
}

fn owner_id(album: &Album) -> Option<&str> {
    album.owner().map(|owner| owner.id.as_str())
}

/// A stable sort; elements without a key stay last in either order, like Immich's albums without photos.
fn ordered<T, K>(elements: &mut [T], ascending: bool, key: impl Fn(&T) -> Option<K>, compare: impl Fn(&K, &K) -> Ordering) {
    elements.sort_by(|a, b| match (key(a), key(b)) {
        (Some(x), Some(y)) => {
            let order = compare(&x, &y);
            if ascending { order } else { order.reverse() }
        }
        (Some(_), None) => Ordering::Less,
        (None, Some(_)) => Ordering::Greater,
        (None, None) => Ordering::Equal,
    });
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
    /// gallery splits them.
    pub fn albums(self, albums: &[Album], sort_by: SortBy, limit: Option<usize>) -> (Vec<Album>, bool) {
        let members: Vec<Album> = albums.iter().filter(|album| album.shared == (self == Section::Shared)).cloned().collect();
        let total = members.len();
        let mut sorted = Arrangement::default().sorted_by(sort_by).sorted(members);
        if let Some(limit) = limit {
            sorted.truncate(limit);
        }
        let cut = sorted.len() < total;
        (sorted, cut)
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
    use chrono::TimeZone;
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
        let groups = Arrangement::default().groups(&albums, Some("me"));
        let headers: Vec<_> = groups.iter().map(|group| group.header.clone()).collect();
        assert_eq!(headers, [Some(Header::Year(2025)), Some(Header::Year(2023)), Some(Header::UnknownYear)]);
        assert_eq!(names(&groups[0].albums), ["b", "d"], "a stable sort keeps ties in order");
    }

    #[test]
    fn filters_split_your_own_from_the_shared_and_owner_groups_put_yours_first_ascending() {
        let albums = [album("mine", "me", false, Some(2024), 1), album("ours", "me", true, Some(2024), 1), album("theirs", "ann", true, Some(2024), 1)];
        let owned = Arrangement { filter: Filter::Owned, ..Arrangement::default() };
        assert_eq!(names(&owned.groups(&albums, Some("me"))[0].albums), ["mine", "ours"]);
        let shared = Arrangement { filter: Filter::Shared, group_by: GroupBy::None, ..Arrangement::default() };
        assert_eq!(names(&shared.groups(&albums, Some("me"))[0].albums), ["ours", "theirs"]);
        let by_owner = Arrangement::default().grouped_by(GroupBy::Owner);
        let headers: Vec<_> = by_owner.groups(&albums, Some("me")).into_iter().map(|group| group.header).collect();
        assert_eq!(headers, [Some(Header::Mine), Some(Header::Owner("ANN".into()))]);
    }

    #[test]
    fn sorting_by_the_albums_own_dates_turns_year_groups_off_and_a_key_takes_its_order() {
        let arrangement = Arrangement::default().sorted_by(SortBy::DateModified);
        assert_eq!(arrangement.effective_group_by(), GroupBy::None);
        assert!(!arrangement.ascending);
        assert!(Arrangement::default().sorted_by(SortBy::Title).ascending);
        let albums = vec![album("b", "me", false, None, 1), album("a", "me", false, None, 3)];
        assert_eq!(names(&Arrangement::default().sorted_by(SortBy::Title).sorted(albums.clone())), ["a", "b"]);
        assert_eq!(names(&Arrangement::default().sorted_by(SortBy::ItemCount).sorted(albums)), ["a", "b"]);
    }

    #[test]
    fn sidebar_sections_split_by_sharing_and_say_when_they_are_cut() {
        let albums: Vec<Album> = (0..12).map(|index| album(&format!("a{index:02}"), "me", index % 3 == 0, Some(2000 + index), 1)).collect();
        let (mine, cut) = Section::Mine.albums(&albums, SortBy::Title, Some(5));
        assert_eq!((mine.len(), cut), (5, true));
        assert!(mine.iter().all(|album| !album.shared));
        let (shared, cut) = Section::Shared.albums(&albums, SortBy::Title, None);
        assert_eq!((shared.len(), cut), (4, false));
        let folder = tempfile::tempdir().unwrap();
        let settings = Settings::open(&folder.path().join("settings.json"));
        assert_eq!(Section::Mine.load(&settings), (Some(10), SortBy::DateModified));
        Section::Mine.save(&settings, None, SortBy::Title);
        assert_eq!(Section::Mine.load(&settings), (None, SortBy::Title));
    }
}
