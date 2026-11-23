//! The albums' view settings (Immich's web app's albums page, album-utils.ts and AlbumsList.svelte, after Immich
//! Gallery's `AlbumsArrangement`): which albums show (all, the account's own, the shared ones), grouped by the year of
//! their photos or by owner, each grouping in its own order at first, and sorted by one of six keys, each in its own
//! order at first; which groups are collapsed, for each grouping; and the first albums of a sidebar section. Linux's
//! window, the Mac and the iPhone (through `verso-bridge`) all arrange here, and keep the choices by the same codes.
//! The order of titles and owners' names is the platform's (`names`).

use std::cmp::Ordering;
use std::collections::BTreeMap;

use chrono::{DateTime, Datelike, Utc};

/// Which albums show.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Filter {
    #[default]
    All,
    Owned,
    Shared,
}

/// How albums are grouped: not at all, by the year of their photos, or by owner.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum GroupBy {
    None,
    #[default]
    Year,
    Owner,
}

/// The keys albums are sorted by.
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

/// Immich's Cover and List views.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum View {
    #[default]
    Covers,
    List,
}

/// Each choice's codes, Immich's names, which the settings keep on Linux, the Mac and the iPhone alike.
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

/// The code an order is kept by: `asc` or `desc`.
pub fn order_code(ascending: bool) -> &'static str {
    if ascending { "asc" } else { "desc" }
}

/// Whether an order kept by its code is ascending: `asc` is, and anything else is not.
pub fn is_ascending(code: &str) -> bool {
    code == "asc"
}

impl GroupBy {
    /// The order a grouping takes when chosen: the newest year first, owners A to Z.
    pub fn default_ascending(self) -> bool {
        self != GroupBy::Year
    }
}

impl SortBy {
    /// The order a key takes when chosen: titles A to Z, counts and dates biggest and newest first.
    pub fn default_ascending(self) -> bool {
        self == SortBy::Title
    }
}

/// An album, as the arrangement reads it.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct AlbumFacts {
    pub title: String,
    /// Its owner's id; none where the server named no owner.
    pub owner_id: Option<String>,
    /// Its owner's name, empty where the server named no owner.
    pub owner_name: String,
    /// Shared with other people, in either direction.
    pub shared: bool,
    pub asset_count: u64,
    pub created_at: Option<DateTime<Utc>>,
    pub updated_at: Option<DateTime<Utc>>,
    /// When its oldest and its newest photo were taken, the wall clock where each was, written as UTC as Immich sends
    /// it; none for an album without photos.
    pub start_date: Option<DateTime<Utc>>,
    pub end_date: Option<DateTime<Utc>>,
}

impl From<&immich_api::Album> for AlbumFacts {
    fn from(album: &immich_api::Album) -> AlbumFacts {
        AlbumFacts {
            title: album.name.clone(),
            owner_id: album.owner().map(|owner| owner.id.clone()),
            owner_name: album.owner().map(|owner| owner.name.clone()).unwrap_or_default(),
            shared: album.shared,
            asset_count: album.asset_count,
            created_at: Some(album.created_at),
            updated_at: Some(album.updated_at),
            start_date: album.start_date,
            end_date: album.end_date,
        }
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

/// A group of albums, with its albums by their index in the list arranged.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Group {
    /// Stable across reads, for remembering which groups are collapsed: `albums`, `year-<year>`, `year-unknown`,
    /// `owner-mine` or `owner-<id>`.
    pub id: String,
    /// None for the albums ungrouped.
    pub header: Option<Header>,
    pub albums: Vec<usize>,
}

/// The Albums page's view options.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Arrangement {
    pub filter: Filter,
    pub view: View,
    pub group_by: GroupBy,
    pub groups_ascending: bool,
    pub sort_by: SortBy,
    pub ascending: bool,
}

/// Immich's: all albums as covers, by the year of their newest photo, the newest year and photo first.
impl Default for Arrangement {
    fn default() -> Arrangement {
        Arrangement { filter: Filter::All, view: View::Covers, group_by: GroupBy::Year, groups_ascending: false, sort_by: SortBy::MostRecentPhoto, ascending: false }
    }
}

impl Arrangement {
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

    /// The grouping shown: the one chosen, or none where the sort key turns it off.
    pub fn effective_group_by(&self) -> GroupBy {
        if self.allows(self.group_by) { self.group_by } else { GroupBy::None }
    }

    /// Whether the filter shows an album, for the account `user_id`.
    pub fn shows(&self, album: &AlbumFacts, user_id: Option<&str>) -> bool {
        match self.filter {
            Filter::All => true,
            Filter::Owned => album.owner_id.as_deref() == user_id,
            Filter::Shared => album.shared,
        }
    }

    /// The albums shown, filtered, grouped, and sorted within each group, titles and owners' names ordered by `names`:
    /// all of them in one group without a header; a group for each year of their photos (the newest photo's, or
    /// sorting by the oldest, the oldest's), the albums without photos last; or a group for each owner, by name, the
    /// account's own first in ascending order and last in descending.
    pub fn groups(&self, albums: &[AlbumFacts], user_id: Option<&str>, names: impl Fn(&str, &str) -> Ordering) -> Vec<Group> {
        let shown: Vec<usize> = (0..albums.len()).filter(|index| self.shows(&albums[*index], user_id)).collect();
        if shown.is_empty() {
            return Vec::new();
        }
        let groups = match self.effective_group_by() {
            GroupBy::None => vec![Group { id: "albums".to_owned(), header: None, albums: shown }],
            GroupBy::Year => {
                let year = |index: usize| {
                    let album = &albums[index];
                    (if self.sort_by == SortBy::OldestPhoto { album.start_date } else { album.end_date }).map(|date| date.year())
                };
                let mut years: Vec<Option<i32>> = Vec::new();
                for index in &shown {
                    if !years.contains(&year(*index)) {
                        years.push(year(*index));
                    }
                }
                years.sort_by(|first, second| keyed(*first, *second, self.groups_ascending, |first, second| first.cmp(second)));
                years
                    .into_iter()
                    .map(|key| Group {
                        id: key.map_or("year-unknown".to_owned(), |year| format!("year-{year}")),
                        header: Some(key.map_or(Header::UnknownYear, Header::Year)),
                        albums: shown.iter().copied().filter(|index| year(*index) == key).collect(),
                    })
                    .collect()
            }
            GroupBy::Owner => {
                let mine = |index: usize| user_id.is_some() && albums[index].owner_id.as_deref() == user_id;
                let owner = |index: usize| albums[index].owner_id.as_deref().unwrap_or_default();
                // Each other owner where their first album comes, by the name it gives them.
                let mut owners: Vec<(&str, &str)> = Vec::new();
                for index in shown.iter().copied().filter(|index| !mine(*index)) {
                    if !owners.iter().any(|(known, _)| *known == owner(index)) {
                        owners.push((owner(index), albums[index].owner_name.as_str()));
                    }
                }
                owners.sort_by(|(_, first), (_, second)| directed(names(first, second), self.groups_ascending));
                let others = owners.into_iter().map(|(id, name)| Group {
                    id: format!("owner-{id}"),
                    header: Some(Header::Owner(name.to_owned())),
                    albums: shown.iter().copied().filter(|index| !mine(*index) && owner(*index) == id).collect(),
                });
                let own: Vec<usize> = shown.iter().copied().filter(|index| mine(*index)).collect();
                let own = (!own.is_empty()).then(|| Group { id: "owner-mine".to_owned(), header: Some(Header::Mine), albums: own });
                if self.groups_ascending { own.into_iter().chain(others).collect() } else { others.chain(own).collect() }
            }
        };
        groups
            .into_iter()
            .map(|mut group| {
                group.albums = self.order(group.albums, albums, &names);
                group
            })
            .collect()
    }

    /// The albums (by index) in the chosen order, titles ordered by `names`; an album without the date sorted by goes
    /// last in either order, as Immich's albums without photos do, and albums alike keep the list's order.
    pub fn sorted(&self, albums: &[AlbumFacts], names: impl Fn(&str, &str) -> Ordering) -> Vec<usize> {
        self.order((0..albums.len()).collect(), albums, &names)
    }

    fn order(&self, mut members: Vec<usize>, albums: &[AlbumFacts], names: &impl Fn(&str, &str) -> Ordering) -> Vec<usize> {
        let dates = |first: Option<DateTime<Utc>>, second: Option<DateTime<Utc>>| keyed(first, second, self.ascending, |first, second| first.cmp(second));
        members.sort_by(|first, second| {
            let (first, second) = (&albums[*first], &albums[*second]);
            match self.sort_by {
                SortBy::Title => directed(names(&first.title, &second.title), self.ascending),
                SortBy::ItemCount => directed(first.asset_count.cmp(&second.asset_count), self.ascending),
                SortBy::DateModified => dates(first.updated_at, second.updated_at),
                SortBy::DateCreated => dates(first.created_at, second.created_at),
                SortBy::MostRecentPhoto => dates(first.end_date, second.end_date),
                SortBy::OldestPhoto => dates(first.start_date, second.start_date),
            }
        });
        members
    }
}

/// A sidebar section's albums (by index): the first `limit` of them, or all without one, sorted by `sort_by` in its own
/// order, newest first for dates.
pub fn sidebar(albums: &[AlbumFacts], sort_by: SortBy, limit: Option<usize>, names: impl Fn(&str, &str) -> Ordering) -> Vec<usize> {
    let mut sorted = Arrangement::default().sorted_by(sort_by).sorted(albums, names);
    if let Some(limit) = limit {
        sorted.truncate(limit);
    }
    sorted
}

/// An order made ascending or descending.
fn directed(order: Ordering, ascending: bool) -> Ordering {
    if ascending { order } else { order.reverse() }
}

/// Two keys in the chosen order, a missing one last in either order.
fn keyed<K>(first: Option<K>, second: Option<K>, ascending: bool, compare: impl Fn(&K, &K) -> Ordering) -> Ordering {
    match (first, second) {
        (Some(first), Some(second)) => directed(compare(&first, &second), ascending),
        (Some(_), None) => Ordering::Less,
        (None, Some(_)) => Ordering::Greater,
        (None, None) => Ordering::Equal,
    }
}

/// The groups collapsed on the Albums page, kept for each grouping by its code, as Immich's web app keeps them
/// (`collapsedGroups`). Without a grouping nothing collapses.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Collapsed {
    groups: BTreeMap<String, Vec<String>>,
}

impl Collapsed {
    /// As the Mac and the iPhone keep them, every grouping's in one value: `{"Owner":["owner-zoe"],"Year":["year-2024"]}`.
    /// What is not that holds none.
    pub fn from_json(stored: &str) -> Collapsed {
        Collapsed { groups: serde_json::from_str(stored).unwrap_or_default() }
    }

    /// Every grouping's, as the Mac and the iPhone keep them, its groupings in the order of their codes; `{}` for none.
    pub fn json(&self) -> String {
        serde_json::to_string(&self.groups).unwrap_or_else(|_| "{}".to_owned())
    }

    /// One grouping's, as Linux keeps them under a key of the grouping's own: a group a line.
    pub fn from_lines(group_by: GroupBy, stored: &str) -> Collapsed {
        let mut collapsed = Collapsed::default();
        collapsed.set(stored.split('\n').filter(|id| !id.is_empty()).map(str::to_owned).collect(), group_by);
        collapsed
    }

    /// One grouping's, as Linux keeps them; none when none of its groups is collapsed.
    pub fn lines(&self, group_by: GroupBy) -> Option<String> {
        let ids = self.ids(group_by);
        (!ids.is_empty()).then(|| ids.join("\n"))
    }

    /// A grouping's collapsed groups.
    pub fn ids(&self, group_by: GroupBy) -> &[String] {
        Self::key(group_by).and_then(|key| self.groups.get(key)).map_or(&[], Vec::as_slice)
    }

    pub fn is_collapsed(&self, id: &str, group_by: GroupBy) -> bool {
        self.ids(group_by).iter().any(|known| known == id)
    }

    /// Collapse a group, or expand it when it is collapsed.
    pub fn toggle(&mut self, id: &str, group_by: GroupBy) {
        let mut ids = self.ids(group_by).to_vec();
        match ids.iter().position(|known| known == id) {
            Some(place) => {
                ids.remove(place);
            }
            None => ids.push(id.to_owned()),
        }
        self.set(ids, group_by);
    }

    /// A grouping's collapsed groups, all of them at once: none to expand them all.
    pub fn set(&mut self, ids: Vec<String>, group_by: GroupBy) {
        let Some(key) = Self::key(group_by) else { return };
        if ids.is_empty() {
            self.groups.remove(key);
        } else {
            self.groups.insert(key.to_owned(), ids);
        }
    }

    fn key(group_by: GroupBy) -> Option<&'static str> {
        (group_by != GroupBy::None).then(|| group_by.code())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::names::caseless;
    use chrono::TimeZone;

    fn day(year: i32, month: u32, day: u32) -> Option<DateTime<Utc>> {
        Some(Utc.with_ymd_and_hms(year, month, day, 0, 0, 0).unwrap())
    }

    /// The Mac's check's albums: a, b and c with photos, d without; b is shared by me with Zoe, c shared by Zoe with
    /// me, d by Adam.
    fn albums() -> Vec<AlbumFacts> {
        let album = |title: &str, owner: (&str, &str), shared: bool, count: u64, dates: [Option<DateTime<Utc>>; 4]| AlbumFacts {
            title: title.to_owned(),
            owner_id: Some(owner.0.to_owned()),
            owner_name: owner.1.to_owned(),
            shared,
            asset_count: count,
            created_at: dates[0],
            updated_at: dates[1],
            start_date: dates[2],
            end_date: dates[3],
        };
        vec![
            album("beach", ("me", "Me"), false, 5, [day(2020, 1, 1), day(2026, 1, 3), day(2023, 6, 1), day(2025, 1, 1)]),
            album("Alps", ("me", "Me"), true, 9, [day(2021, 1, 1), day(2026, 1, 1), day(2024, 12, 1), day(2024, 12, 31)]),
            album("Cats", ("zoe", "Zoe"), true, 2, [day(2022, 1, 1), day(2026, 1, 2), day(2022, 3, 1), day(2025, 7, 1)]),
            album("Empty", ("adam", "Adam"), true, 0, [day(2023, 1, 1), day(2026, 1, 4), None, None]),
        ]
    }

    fn titles(albums: &[AlbumFacts], indices: &[usize]) -> Vec<String> {
        indices.iter().map(|index| albums[*index].title.clone()).collect()
    }

    fn headers(groups: &[Group]) -> Vec<Option<Header>> {
        groups.iter().map(|group| group.header.clone()).collect()
    }

    fn arrangement(group_by: GroupBy, groups_ascending: bool, sort_by: SortBy, ascending: bool) -> Arrangement {
        Arrangement { group_by, groups_ascending, sort_by, ascending, ..Arrangement::default() }
    }

    #[test]
    fn by_default_albums_group_by_the_year_of_their_newest_photo_newest_first_and_those_without_photos_last() {
        let albums = albums();
        let groups = Arrangement::default().groups(&albums, Some("me"), caseless);
        assert_eq!(headers(&groups), [Some(Header::Year(2025)), Some(Header::Year(2024)), Some(Header::UnknownYear)]);
        assert_eq!(groups.iter().map(|group| titles(&albums, &group.albums)).collect::<Vec<_>>(), [vec!["Cats", "beach"], vec!["Alps"], vec!["Empty"]]);
        assert_eq!(groups.iter().map(|group| group.id.as_str()).collect::<Vec<_>>(), ["year-2025", "year-2024", "year-unknown"]);
    }

    #[test]
    fn ascending_years_keep_the_albums_without_photos_last_and_sorting_by_the_oldest_photo_groups_by_its_year() {
        let albums = albums();
        let mut oldest = arrangement(GroupBy::Year, true, SortBy::OldestPhoto, true);
        let headers = headers(&oldest.groups(&albums, Some("me"), caseless));
        assert_eq!(headers, [Some(Header::Year(2022)), Some(Header::Year(2023)), Some(Header::Year(2024)), Some(Header::UnknownYear)]);
        oldest.group_by = GroupBy::None;
        assert_eq!(titles(&albums, &oldest.groups(&albums, Some("me"), caseless)[0].albums), ["Cats", "beach", "Alps", "Empty"]);
    }

    #[test]
    fn sorting_by_the_albums_own_dates_turns_year_groups_off() {
        let albums = albums();
        for sort_by in [SortBy::DateCreated, SortBy::DateModified] {
            let sorted = Arrangement { sort_by, ..Arrangement::default() };
            assert!(!sorted.allows(GroupBy::Year) && sorted.allows(GroupBy::Owner) && sorted.allows(GroupBy::None));
            assert_eq!(sorted.effective_group_by(), GroupBy::None);
            assert_eq!(headers(&sorted.groups(&albums, Some("me"), caseless)), [None]);
        }
        let created = arrangement(GroupBy::None, false, SortBy::DateCreated, false);
        assert_eq!(titles(&albums, &created.sorted(&albums, caseless)), ["Empty", "Cats", "Alps", "beach"]);
        let modified = arrangement(GroupBy::None, false, SortBy::DateModified, false);
        assert_eq!(titles(&albums, &modified.sorted(&albums, caseless)), ["Empty", "beach", "Cats", "Alps"]);
    }

    #[test]
    fn owners_put_the_accounts_own_first_ascending_then_the_others_by_name_and_reverse_descending() {
        let albums = albums();
        let owners = arrangement(GroupBy::Owner, true, SortBy::Title, true);
        let groups = owners.groups(&albums, Some("me"), caseless);
        assert_eq!(headers(&groups), [Some(Header::Mine), Some(Header::Owner("Adam".to_owned())), Some(Header::Owner("Zoe".to_owned()))]);
        assert_eq!(groups.iter().map(|group| group.id.as_str()).collect::<Vec<_>>(), ["owner-mine", "owner-adam", "owner-zoe"]);
        assert_eq!(titles(&albums, &groups[0].albums), ["Alps", "beach"]);
        let descending = Arrangement { groups_ascending: false, ..owners };
        let headers = headers(&descending.groups(&albums, Some("me"), caseless));
        assert_eq!(headers, [Some(Header::Owner("Zoe".to_owned())), Some(Header::Owner("Adam".to_owned())), Some(Header::Mine)]);
    }

    #[test]
    fn without_an_account_every_owner_is_another_and_an_album_without_one_keeps_a_group() {
        let mut albums = albums();
        albums.push(AlbumFacts { title: "Nobody's".to_owned(), ..AlbumFacts::default() });
        let owners = arrangement(GroupBy::Owner, true, SortBy::Title, true);
        let groups = owners.groups(&albums, None, caseless);
        assert_eq!(headers(&groups)[0], Some(Header::Owner(String::new())), "a name that is empty first");
        assert_eq!(groups[0].id, "owner-");
        assert_eq!(titles(&albums, &groups[0].albums), ["Nobody's"]);
        assert!(!headers(&groups).contains(&Some(Header::Mine)));
        assert_eq!(groups.iter().map(|group| group.albums.len()).sum::<usize>(), albums.len());
    }

    #[test]
    fn titles_ignore_case_counts_go_largest_first_and_filters_split_the_accounts_own_from_the_shared() {
        let albums = albums();
        let titled = arrangement(GroupBy::None, false, SortBy::Title, true);
        assert_eq!(titles(&albums, &titled.sorted(&albums, caseless)), ["Alps", "beach", "Cats", "Empty"]);
        let counted = arrangement(GroupBy::Year, false, SortBy::ItemCount, false);
        assert_eq!(titles(&albums, &counted.sorted(&albums, caseless)), ["Alps", "beach", "Cats", "Empty"]);
        let owned = Arrangement { filter: Filter::Owned, ..titled };
        assert_eq!(titles(&albums, &owned.groups(&albums, Some("me"), caseless)[0].albums), ["Alps", "beach"]);
        let shared = Arrangement { filter: Filter::Shared, ..titled };
        assert_eq!(titles(&albums, &shared.groups(&albums, Some("me"), caseless)[0].albums), ["Alps", "Cats", "Empty"]);
        assert!(shared.groups(&[], Some("me"), caseless).is_empty());
        assert!(Arrangement::default().groups(&[], None, caseless).is_empty());
    }

    #[test]
    fn titles_go_in_the_order_the_platform_gives_names_and_alike_keep_the_lists_order() {
        let album = |title: &str| AlbumFacts { title: title.to_owned(), ..AlbumFacts::default() };
        let albums = [album("Ål"), album("Zebra"), album("ape"), album("Ape")];
        let titled = arrangement(GroupBy::None, false, SortBy::Title, true);
        assert_eq!(titles(&albums, &titled.sorted(&albums, caseless)), ["ape", "Ape", "Zebra", "Ål"], "Å after Z, as Danish has it");
        let english = |first: &str, second: &str| caseless(&first.replace('Å', "A"), &second.replace('Å', "A"));
        assert_eq!(titles(&albums, &titled.sorted(&albums, english)), ["Ål", "ape", "Ape", "Zebra"], "Å beside A, as English has it");
        let descending = Arrangement { ascending: false, ..titled };
        assert_eq!(titles(&albums, &descending.sorted(&albums, caseless)), ["Ål", "Zebra", "ape", "Ape"], "alike keep the list's order");
    }

    #[test]
    fn choosing_a_key_or_a_grouping_takes_its_own_order() {
        assert!(Arrangement::default().sorted_by(SortBy::Title).ascending);
        assert!(!Arrangement::default().sorted_by(SortBy::ItemCount).ascending);
        assert!(!Arrangement::default().sorted_by(SortBy::DateModified).ascending);
        assert!(Arrangement::default().grouped_by(GroupBy::Owner).groups_ascending);
        assert!(!Arrangement::default().grouped_by(GroupBy::Year).groups_ascending);
        let default = Arrangement::default();
        assert_eq!((default.filter, default.view, default.group_by, default.sort_by), (Filter::All, View::Covers, GroupBy::Year, SortBy::MostRecentPhoto));
        assert!(!default.groups_ascending && !default.ascending);
    }

    #[test]
    fn a_sidebar_section_lists_its_first_albums_in_the_keys_own_order() {
        let albums = albums();
        assert_eq!(titles(&albums, &sidebar(&albums, SortBy::DateModified, Some(2), caseless)), ["Empty", "beach"]);
        assert_eq!(titles(&albums, &sidebar(&albums, SortBy::MostRecentPhoto, Some(3), caseless)), ["Cats", "beach", "Alps"]);
        assert_eq!(titles(&albums, &sidebar(&albums, SortBy::Title, None, caseless)), ["Alps", "beach", "Cats", "Empty"]);
        assert_eq!(sidebar(&albums, SortBy::Title, Some(10), caseless).len(), albums.len());
    }

    #[test]
    fn the_choices_are_kept_by_immichs_names() {
        for filter in Filter::ALL {
            assert_eq!(Filter::from_code(filter.code()), Some(*filter));
        }
        for group_by in GroupBy::ALL {
            assert_eq!(GroupBy::from_code(group_by.code()), Some(*group_by));
        }
        for sort_by in SortBy::ALL {
            assert_eq!(SortBy::from_code(sort_by.code()), Some(*sort_by));
        }
        assert_eq!(GroupBy::from_code("Year"), Some(GroupBy::Year));
        assert_eq!(SortBy::from_code("MostRecentPhoto"), Some(SortBy::MostRecentPhoto));
        assert_eq!(Filter::from_code("Owned"), Some(Filter::Owned));
        assert_eq!((View::from_code("List"), View::from_code("Cover")), (Some(View::List), Some(View::Covers)));
        assert_eq!(View::from_code("Covers"), None);
        assert_eq!((order_code(true), order_code(false)), ("asc", "desc"));
        assert!(is_ascending("asc") && !is_ascending("desc") && !is_ascending("up"));
    }

    #[test]
    fn collapsed_groups_are_kept_for_each_grouping_as_immich_keeps_them() {
        let mut collapsed = Collapsed::from_json("");
        assert!(!collapsed.is_collapsed("year-2024", GroupBy::Year));
        collapsed.toggle("year-2024", GroupBy::Year);
        collapsed.toggle("owner-zoe", GroupBy::Owner);
        assert!(collapsed.is_collapsed("year-2024", GroupBy::Year) && !collapsed.is_collapsed("year-2024", GroupBy::Owner));
        assert_eq!(collapsed.json(), r#"{"Owner":["owner-zoe"],"Year":["year-2024"]}"#);
        assert!(Collapsed::from_json(&collapsed.json()).is_collapsed("owner-zoe", GroupBy::Owner));
        collapsed.toggle("year-2024", GroupBy::Year);
        collapsed.set(Vec::new(), GroupBy::Owner);
        assert_eq!(collapsed.json(), "{}");
        collapsed.toggle("albums", GroupBy::None);
        assert!(!collapsed.is_collapsed("albums", GroupBy::None) && collapsed.json() == "{}", "without a grouping nothing collapses");
        collapsed.set(vec!["year-2025".to_owned(), "year-unknown".to_owned()], GroupBy::Year);
        assert!(collapsed.is_collapsed("year-unknown", GroupBy::Year));
        assert!(!Collapsed::from_json("not json").is_collapsed("year-2025", GroupBy::Year));
        let kept = Collapsed::from_json(r#"{"Country":["country-Denmark"],"Year":["year-2025"]}"#);
        let mut changed = kept.clone();
        changed.toggle("year-2024", GroupBy::Year);
        assert_eq!(changed.json(), r#"{"Country":["country-Denmark"],"Year":["year-2025","year-2024"]}"#, "a grouping it does not know stays");
    }

    #[test]
    fn linux_keeps_each_groupings_collapsed_groups_a_line_each() {
        let collapsed = Collapsed::from_lines(GroupBy::Owner, "owner-zoe\n\nowner-adam");
        assert_eq!(collapsed.ids(GroupBy::Owner), ["owner-zoe", "owner-adam"]);
        assert!(collapsed.ids(GroupBy::Year).is_empty());
        assert_eq!(collapsed.lines(GroupBy::Owner).as_deref(), Some("owner-zoe\nowner-adam"));
        let mut collapsed = Collapsed::from_lines(GroupBy::Year, "year-2024");
        collapsed.toggle("year-2024", GroupBy::Year);
        assert_eq!(collapsed.lines(GroupBy::Year), None);
        assert_eq!(Collapsed::from_lines(GroupBy::Year, ""), Collapsed::default());
        assert!(Collapsed::from_lines(GroupBy::None, "albums").ids(GroupBy::None).is_empty());
    }

    #[test]
    fn an_album_from_immich_reads_its_owner_from_its_members() {
        use immich_api::{AlbumMember, AlbumRole, User};
        let member = |id: &str, role: AlbumRole| AlbumMember { user: User { id: id.to_owned(), name: id.to_uppercase(), ..User::default() }, role };
        let album = immich_api::Album { name: "Alps".to_owned(), shared: true, asset_count: 9, members: vec![member("zoe", AlbumRole::Editor), member("me", AlbumRole::Owner)], ..immich_api::Album::default() };
        let facts = AlbumFacts::from(&album);
        assert_eq!((facts.title.as_str(), facts.owner_id.as_deref(), facts.owner_name.as_str()), ("Alps", Some("me"), "ME"));
        assert!(facts.shared && facts.asset_count == 9 && facts.created_at.is_some() && facts.end_date.is_none());
        assert_eq!(AlbumFacts::from(&immich_api::Album::default()).owner_id, None);
    }
}
